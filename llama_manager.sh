#!/bin/bash
# Dropped global 'set -e' to prevent interactive menu crashes on minor errors.
# Kept 'set -uo pipefail' for safe variable and pipe handling.
set -uo pipefail

# --- Styling ---
B_RED='\033[1;31m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_CYAN='\033[1;36m'
NC='\033[0m'
CLEAR='\033[2J\033[H'
# FIX: Y/N were referenced in ask() and PAUSE() but never defined.
Y="$B_YELLOW"
N="$NC"

# --- FIX: OK/ERR/INFO/WARN/STEP were called throughout but never defined. ---
OK()   { echo -e "${B_GREEN}  ✔  $*${NC}"; }
ERR()  { echo -e "${B_RED}  ✖  $*${NC}" >&2; }
INFO() { echo -e "      $*"; }
WARN() { echo -e "${B_YELLOW}  ⚠  $*${NC}"; }
STEP() { echo -e "${B_CYAN}  ──  $*${NC}"; }

# --- Paths ---
INSTALL_DIR="$HOME/ai_stack/llama.cpp"
BUILD_DIR="$INSTALL_DIR/build"
MODEL_DIR="$HOME/ai_stack/models"
LOG_FILE="$HOME/llama_forensics.log"
SERVER_PID_FILE="/tmp/llama_server.pid"
KEY_FILE="$HOME/llama_api_keys.log"
SERVER_INFO_FILE="/tmp/llama_server.info"   # stores active URL + API key for status display
SETTINGS_FILE="$HOME/ai_stack/settings.env" # persists runtime settings across sessions
DL_DIR="$HOME/ai_stack/.downloads"          # tracks background download progress files

# --- Config (all overridable at runtime via the Settings menu) ---
context_size=8192         # tokens: 1024 2048 4096 8192 16384 32768
visible2network="127.0.0.1"   # 0.0.0.0 = LAN-accessible  127.0.0.1 = localhost only
network_port="8080"
api_key_mode="random"     # "random" | "localtest" | "custom:<value>"

# Persist settings to file so they survive subshell scope issues and script restarts.
save_settings() {
    mkdir -p "$(dirname "$SETTINGS_FILE")" || true
    # Write as plain bash assignments — allows load_settings to use 'source'
    {
        echo "context_size=$context_size"
        echo "visible2network=$visible2network"
        echo "network_port=$network_port"
        echo "api_key_mode=$api_key_mode"
    } > "$SETTINGS_FILE" || WARN "Could not write settings to $SETTINGS_FILE"
}

load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0
    # source executes the file as bash — direct assignment, no parsing, cannot fail silently
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE" || true
}

# Apply any previously saved settings immediately
load_settings

# ================================================================
#  Helpers
# ================================================================
ask() {
    local yn="[Y/n]"; [[ "${2:-y}" == "n" ]] && yn="[y/N]"
    read -rp "$(echo -e "${Y}  ❓  $1 $yn: ${N}")" r
    r="${r:-${2:-y}}"
    [[ "${r,,}" == "y" ]]
}
PAUSE() {
    read -rp "$(echo -e "${Y}  Press Enter to continue…${N}")"
}

# --- Log rotation (keep last 500 lines) ---
rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local lines
        lines=$(wc -l < "$LOG_FILE" || echo 0)
        if (( lines > 500 )); then
            tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

draw_header() {
    echo -e "${CLEAR}${B_CYAN}======================================================"
    echo -e "           🦙 LLAMA COMMAND CENTER (v8.2) 🦙"
    echo -e "           * Universal GPU & Repair Mode *"
    echo -e "======================================================${NC}"
}

# ================================================================
#  PREFLIGHT DEPENDENCY CHECK
#  Detects missing tools, offers to auto-install them, re-verifies.
# ================================================================
check_deps() {
    # Map: command -> apt package that provides it
    declare -A PKG_MAP=(
        [git]="git"
        [cmake]="cmake"
        [curl]="curl"
        [openssl]="openssl"
        [lspci]="pciutils"
        [ccache]="ccache"
        [nproc]="coreutils"
        [wget]="wget"
        [gpg]="gnupg2"
    )

    local missing_cmds=() missing_pkgs=()
    for cmd in "${!PKG_MAP[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
            missing_pkgs+=("${PKG_MAP[$cmd]}")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        echo -e "${B_YELLOW}[!] Missing tools: ${missing_cmds[*]}${NC}"
        echo -e "    Packages needed: ${missing_pkgs[*]}"
        echo ""
        read -r -p "    Auto-install missing packages now? (y/n): " do_install
        if [[ "${do_install,,}" == "y" ]]; then
            echo -e "${B_CYAN}  Running apt-get update…${NC}"
            sudo apt-get update -qq &>> "$LOG_FILE" || true
            echo -e "${B_CYAN}  Installing: ${missing_pkgs[*]}…${NC}"
            # De-duplicate package list before installing
            local unique_pkgs
            mapfile -t unique_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
            if sudo apt-get install -y "${unique_pkgs[@]}" &>> "$LOG_FILE"; then
                OK "Packages installed."
            else
                ERR "apt-get install failed — check logs."
                return 1
            fi
            # Re-verify after install
            local still_missing=()
            for cmd in "${missing_cmds[@]}"; do
                command -v "$cmd" &>/dev/null || still_missing+=("$cmd")
            done
            if [[ ${#still_missing[@]} -gt 0 ]]; then
                ERR "Still missing after install: ${still_missing[*]}"
                return 1
            fi
            OK "All dependencies satisfied."
        else
            ERR "Cannot continue without required tools. Install manually and retry."
            return 1
        fi
    fi

    # Validate x86_64 platform
    if [[ "$(uname -m)" != "x86_64" ]]; then
        ERR "x86_64 architecture required. Detected: $(uname -m)"
        return 1
    fi

    echo ""
    INFO "Available disk: $(df -h "$HOME" | awk 'NR==2{print $4}') free"
    INFO "System RAM:     $(free -h | awk '/Mem:/ {print $2}')"
    WARN "The 8B model download is ~5 GB. Ensure you have ~8 GB free total."
    return 0
}

# ================================================================
#  HARDWARE DETECTION ENGINE
#
#  FIX: install_AMD_gpu_drivers() and install_intel_gpu_drivers()
#       were called directly inside detect_gpu(). This caused driver
#       installation to trigger on every single status check and menu
#       refresh — a serious unintended side-effect. Detection now only
#       prints the GPU type; installation is left to build_engine()
#       and deep_repair() where it belongs.
#
#  FIX: The Intel elif block contained orphaned if/else statements
#       (Arc OpenCL and lspci checks) that ran after 'echo "INTEL"'
#       but produced no useful return value and mixed stdout with the
#       detect_gpu output, breaking callers.
# ================================================================
detect_gpu() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null || true)

    if echo "$gpu_info" | grep -iq "NVIDIA"; then
        echo "NVIDIA"
    elif echo "$gpu_info" | grep -iqE "(Advanced Micro Devices|ATI).*(VGA|Display|3D|Radeon)"; then
        echo "AMD"
    elif echo "$gpu_info" | grep -iqE "Intel.*(Arc|UHD|Iris|Graphics)"; then
        echo "INTEL"
    else
        echo "CPU"
    fi
}

# ================================================================
#  GPU DRIVER INSTALLERS
#  These are now called explicitly from build_engine / deep_repair.
# ================================================================

install_Nvidia_gpu_drivers() {
    STEP "Installing NVIDIA CUDA toolkit…"
    sudo apt-get install -y ubuntu-drivers-common nvidia-cuda-toolkit &>> "$LOG_FILE" || true
}

install_AMD_gpu_drivers() {
    STEP "Installing AMD / Vulkan dependencies…"
    sudo apt-get install -y \
        libnuma-dev libvulkan-dev wget vulkan-tools \
        glslang-tools gnupg2 &>> "$LOG_FILE" || true
    # Note: libvulkan-dev:i386 requires multiarch; install separately if needed.
    sudo dpkg --add-architecture i386 2>/dev/null || true
    sudo apt-get update -qq &>> "$LOG_FILE" || true
    sudo apt-get install -y libvulkan-dev:i386 &>> "$LOG_FILE" || true
}

install_intel_gpu_drivers() {
    STEP "Installing Intel Arc GPU drivers (OpenCL + level-zero + oneAPI)…"
    INFO "Checking Intel GPU driver packages…"

    # ── 1. Intel GPU compute-runtime repo (OpenCL ICD + level-zero shim) ──
    # The repo layout changed: Noble (24.04) uses 'ubuntu2404' not 'noble unified'.
    # The key must be fetched with curl (wget -O- has broken pipe issues with gpg).
    if [[ ! -f /etc/apt/sources.list.d/intel-gpu-noble.list ]]; then
        INFO "  Adding Intel GPU repo for Ubuntu 24.04 Noble…"
        curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key \
            | sudo gpg --yes --dearmor \
                --output /usr/share/keyrings/intel-graphics.gpg \
            || { ERR "Failed to import Intel GPU key."; return 1; }
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] \
https://repositories.intel.com/gpu/ubuntu noble client" \
            | sudo tee /etc/apt/sources.list.d/intel-gpu-noble.list > /dev/null
        sudo apt-get update -qq 2>&1 | tee -a "$LOG_FILE" || true
    else
        INFO "  Intel GPU repo already present."
    fi

    # ── 2. Required runtime packages ──
    local PKGS=()

    # OpenCL ICD (userspace OpenCL dispatcher)
    if dpkg -s intel-opencl-icd &>/dev/null 2>&1; then
        INFO "  intel-opencl-icd     ✓ already installed"
    else
        PKGS+=("intel-opencl-icd")
    fi

    # level-zero GPU shim — accept either package name (repo changed it)
    if dpkg -s libze-intel-gpu1 &>/dev/null 2>&1 \
    || dpkg -s intel-level-zero-gpu &>/dev/null 2>&1; then
        INFO "  level-zero GPU shim  ✓ already installed"
    else
        PKGS+=("libze-intel-gpu1")
    fi

    # level-zero ICD loader
    if dpkg -s libze1 &>/dev/null 2>&1; then
        INFO "  libze1               ✓ already installed"
    else
        PKGS+=("libze1")
    fi

    if [[ ${#PKGS[@]} -gt 0 ]]; then
        INFO "  Installing GPU runtime: ${PKGS[*]}"
        sudo apt-get install -y "${PKGS[@]}" 2>&1 | tee -a "$LOG_FILE" || {
            ERR "Failed to install GPU runtime packages."
            WARN "  Try: sudo apt-get update && sudo apt-get install ${PKGS[*]}"
        }
    fi

    # clinfo + level-zero dev headers (optional, non-fatal)
    sudo apt-get install -y --no-install-recommends clinfo libze-dev 2>&1 \
        | tee -a "$LOG_FILE" || true

    OK "Intel GPU runtime packages ready."

    # ── 3. Intel oneAPI SYCL compiler ──
    INFO "Checking Intel oneAPI SYCL compiler…"

    # Check for icx on PATH first before attempting any setvars sourcing.
    # setvars.sh writes "already been run" warnings directly to /dev/tty from
    # sub-scripts — no redirect can suppress this. Only source it when icx is
    # genuinely absent from the session.
    local ICX_BIN=""
    ICX_BIN=$(command -v icx 2>/dev/null) \
        || ICX_BIN=$(find /opt/intel/oneapi -name icx -type f 2>/dev/null | head -1) \
        || true

    if [[ -n "$ICX_BIN" ]]; then
        OK "Intel icx compiler found: $ICX_BIN"
        # Ensure its bin dir is on PATH for sub-processes (cmake etc.)
        export PATH="$(dirname "$ICX_BIN"):$PATH"
    else
        INFO "icx not on PATH — sourcing oneAPI setvars.sh for first-time setup…"

        local SETVARS=""
        SETVARS=$(find /opt/intel/oneapi -name setvars.sh -type f 2>/dev/null | head -1) || true

        if [[ -z "$SETVARS" ]]; then
            # oneAPI not installed at all — add repo and install compiler
            INFO "Installing Intel oneAPI SYCL compiler…"
            if [[ ! -f /etc/apt/sources.list.d/oneAPI.list ]]; then
                curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
                    | sudo gpg --yes --dearmor \
                        --output /usr/share/keyrings/oneapi-archive-keyring.gpg \
                    || { ERR "Failed to import oneAPI GPG key."; return 1; }
                echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] \
https://apt.repos.intel.com/oneapi all main" \
                    | sudo tee /etc/apt/sources.list.d/oneAPI.list > /dev/null
                sudo apt-get update -qq 2>&1 | tee -a "$LOG_FILE" || true
            fi

            # Try package names in order of preference
            local installed_oneapi=0
            for pkg in intel-oneapi-compiler-dpcpp-cpp intel-oneapi-dpcpp-cpp; do
                if sudo apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
                    installed_oneapi=1
                    break
                fi
            done

            if (( installed_oneapi == 0 )); then
                ERR "Could not install any oneAPI SYCL compiler package."
                WARN "  Check: sudo apt-get update && apt-cache search oneapi | grep dpcpp"
                return 1
            fi
        fi

        # Locate icx after install — use find, do NOT re-source setvars
        ICX_BIN=$(command -v icx 2>/dev/null) \
            || ICX_BIN=$(find /opt/intel/oneapi -name icx -type f 2>/dev/null | head -1) \
            || true

        if [[ -n "$ICX_BIN" ]]; then
            export PATH="$(dirname "$ICX_BIN"):$PATH"
            OK "icx ready: $ICX_BIN"
        else
            ERR "icx still not found — check apt output in $LOG_FILE"
            WARN "  Open a new terminal and run: source /opt/intel/oneapi/setvars.sh"
        fi
    fi

    # ── 4. Patch shell profiles so setvars.sh loads at login ──
    # Find setvars path — variable may not be set if icx was already on PATH above
    local SETVARS_FOR_PROFILE=""
    SETVARS_FOR_PROFILE=$(find /opt/intel/oneapi -name setvars.sh -type f 2>/dev/null | head -1) || true
    if [[ -n "$SETVARS_FOR_PROFILE" ]]; then
        local SETVARS_LINE="source \"$SETVARS_FOR_PROFILE\" 2>/dev/null || true  # Intel oneAPI"
        for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [[ -f "$rc" ]] && ! grep -q "Intel oneAPI" "$rc" 2>/dev/null; then
                echo "" >> "$rc"
                echo "$SETVARS_LINE" >> "$rc"
                INFO "  Patched $rc with oneAPI setvars.sh"
            fi
        done
    fi

    # ── 5. Groups + verify ──
    sudo usermod -aG render,video "$USER" 2>/dev/null || true
    OK "User added to render/video groups (re-login to take effect)."

    INFO "Quick GPU visibility check:"
    if command -v clinfo &>/dev/null; then
        clinfo -l 2>/dev/null | grep -i "intel\|Arc" \
            && OK "  Intel GPU visible via OpenCL" \
            || WARN "  Intel GPU NOT visible via OpenCL (may need re-login)"
    fi

    if dpkg -s libze-intel-gpu1 &>/dev/null 2>&1 \
    || dpkg -s intel-level-zero-gpu &>/dev/null 2>&1; then
        OK "  level-zero GPU shim installed — SYCL will see the GPU after re-login"
    else
        WARN "  level-zero shim NOT installed — SYCL will not find the GPU"
    fi
}

# ================================================================
#  UNIVERSAL REPAIR & DEPENDENCY MODULE
# ================================================================
deep_repair() {
    draw_header
    local current_gpu
    current_gpu=$(detect_gpu)
    echo -e "${B_RED}[!!!] STARTING UNIVERSAL REPAIR [!!!]${NC}"
    echo -e "${B_YELLOW}[!] WARNING: This will modify system drivers. Ensure you have a way to recover.${NC}"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { echo "Repair cancelled."; sleep 1; return; }

    echo "Detected Hardware: $current_gpu" | tee -a "$LOG_FILE"

    # 1. Fix APT/DPKG issues safely
    echo -e "\n1. Fixing APT/DPKG state..." | tee -a "$LOG_FILE"
    sudo dpkg --configure -a &>> "$LOG_FILE" || true
    sudo apt-get --fix-broken install -y &>> "$LOG_FILE" || true

    # 2. Hardware-Specific Driver Support
    case $current_gpu in
        "NVIDIA")
            echo -e "${B_RED}[!!!] DANGER: The following step will REMOVE all existing NVIDIA drivers.${NC}"
            echo -e "${B_RED}[!!!] If you are on a Desktop GUI, this may break your display manager!${NC}"
            read -p "Type 'I UNDERSTAND' to proceed with NVIDIA purge, or anything else to skip: " nvidia_confirm
            if [[ "$nvidia_confirm" == "I UNDERSTAND" ]]; then
                echo "Repairing NVIDIA driver fragments..." | tee -a "$LOG_FILE"
                sudo apt-get remove --purge -y '^nvidia-.*' '^libnvidia-.*' &>> "$LOG_FILE" || true
                sudo apt-get autoremove -y &>> "$LOG_FILE" || true
                sudo apt-get update &>> "$LOG_FILE"
                # FIX: install_Nvidia_gpu_drivers() was defined but never called in repair.
                install_Nvidia_gpu_drivers
                sudo ubuntu-drivers autoinstall &>> "$LOG_FILE" || true
            else
                echo "Skipping NVIDIA driver reinstall." | tee -a "$LOG_FILE"
            fi
            ;;
        "AMD")
            echo "Installing AMD ROCm dependencies..." | tee -a "$LOG_FILE"
            sudo apt-get update &>> "$LOG_FILE" || true
            install_AMD_gpu_drivers
            sudo apt-get install -y \
                "linux-headers-$(uname -r)" \
                "linux-modules-extra-$(uname -r)" &>> "$LOG_FILE" || true
            ;;
        "INTEL")
            echo "Installing Intel OneAPI/Compute dependencies..." | tee -a "$LOG_FILE"
            sudo apt-get update &>> "$LOG_FILE" || true
            install_intel_gpu_drivers
            ;;
        *)
            echo "CPU-only mode — no GPU drivers to repair." | tee -a "$LOG_FILE"
            ;;
    esac

    rotate_log
    echo -e "\n${B_GREEN}Repair sequence finished. REBOOT strongly recommended.${NC}"
    read -p "Reboot now? (y/n): " rb
    [[ "$rb" == "y" ]] && sudo reboot
}

# ================================================================
#  PATH INSTALLER
#  Symlinks llama-cli and llama-server into ~/.local/bin and ensures
#  that directory is on PATH in ~/.bashrc and ~/.zshrc persistently.
# ================================================================
install_to_path() {
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"

    local installed_any=0
    for binary in llama-cli llama-server; do
        local src="$BUILD_DIR/bin/$binary"
        local dst="$bin_dir/$binary"
        if [[ ! -f "$src" ]]; then
            WARN "  $binary not found at $src — skipping."
            continue
        fi
        # Remove stale symlink or old copy before re-linking
        [[ -L "$dst" || -f "$dst" ]] && rm -f "$dst"
        ln -s "$src" "$dst"
        OK "  $binary → $dst (symlink)"
        installed_any=1
    done

    if (( installed_any == 0 )); then
        WARN "No binaries were linked — build may have failed."
        return 1
    fi

    # Ensure ~/.local/bin is on PATH in shell profiles
    local path_line='export PATH="$HOME/.local/bin:$PATH"  # llama.cpp binaries'
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [[ -f "$rc" ]] || continue
        if ! grep -q "llama.cpp binaries" "$rc" 2>/dev/null; then
            echo "" >> "$rc"
            echo "$path_line" >> "$rc"
            INFO "  Patched $rc with PATH entry."
        fi
    done

    # Also export into the current session immediately
    export PATH="$bin_dir:$PATH"

    echo ""
    OK "llama-cli and llama-server are now available system-wide."
    INFO "  Run: llama-cli --help"
    INFO "  Run: llama-server --help"
    INFO "  (New terminals will pick this up automatically)"
}


#
#  FIX 1: 'sudo apt-get install -y' with no packages (bare command)
#          was left on its own line and would error — removed.
#  FIX 2: Continuation backslash had a trailing space ('cmake \ ')
#          which breaks line continuation — fixed.
#  FIX 3: install_AMD/INTEL gpu drivers are now called here during
#          build so the correct stack is present before compiling.
# ================================================================
build_engine() {
    draw_header
    if ! check_deps; then
        read -p "Press Enter to return..."
        return
    fi

    local current_gpu
    current_gpu=$(detect_gpu)
    echo -e "${B_CYAN}Building AI Engine for $current_gpu...${NC}"

    # Base Dependencies
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        pkg-config ca-certificates unzip file libfuse2 \
        libwebkit2gtk-4.1-dev libgtk-3-dev gpg-agent \
        software-properties-common ocl-icd-libopencl1 \
        build-essential git curl cmake \
        libdnnl-dev libcurl4-openssl-dev libssl-dev &>> "$LOG_FILE" || true

    OK "System packages installed."

    mkdir -p "$HOME/ai_stack"

    if [ ! -d "$INSTALL_DIR/.git" ]; then
        git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR" \
            | tee -a "$LOG_FILE" \
            || { echo "Clone failed."; read -p "Press Enter..."; return 1; }
    else
        echo "Updating existing llama.cpp repo..." | tee -a "$LOG_FILE"
        (cd "$INSTALL_DIR" && git pull) | tee -a "$LOG_FILE" || true
    fi

    cd "$INSTALL_DIR" || { echo -e "${B_RED}Cannot cd into $INSTALL_DIR${NC}"; read -p "Press Enter..."; return 1; }

    if [ -d "build" ]; then
        read -p "Existing build directory found. Rebuild from scratch? (y/n): " rebuild
        [[ "$rebuild" == "y" ]] && rm -rf build
    fi

    mkdir -p build
    cd build || { echo -e "${B_RED}Cannot cd into build directory${NC}"; read -p "Press Enter..."; return 1; }

    local cmake_flags=()

    case $current_gpu in
        "NVIDIA")
            install_Nvidia_gpu_drivers
            local arch
            arch=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
                | tr -d '.' | grep -E '^[0-9]+$' | head -n 1 || true)
            [ -z "$arch" ] && arch="all-major"
            echo "Using CUDA architecture: $arch" | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_CUDA=ON" "-DCMAKE_CUDA_ARCHITECTURES=$arch")
            ;;
        "AMD")
            install_AMD_gpu_drivers
            echo "Optimizing for AMD (Vulkan)..." | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_VULKAN=ON" "-DGGML_VULKAN_FLASH_ATTN=ON")
            ;;
        "INTEL")
            install_intel_gpu_drivers
            echo "Optimizing for Intel Arc (SYCL)..." | tee -a "$LOG_FILE"

            # install_intel_gpu_drivers already sourced setvars.sh in this session.
            # Do NOT source it again — setvars.sh writes to /dev/tty directly from
            # sub-scripts, bypassing all stdout/stderr redirects and polluting output.
            # Instead, locate icx on PATH or by find, and export its directory if needed.
            local ICX_PATH=""
            ICX_PATH=$(command -v icx 2>/dev/null) \
                || ICX_PATH=$(find /opt/intel/oneapi -name icx -type f 2>/dev/null | head -1) \
                || true

            if [[ -n "$ICX_PATH" ]]; then
                # Ensure the compiler's bin dir is on PATH for cmake to find it
                local icx_bin_dir
                icx_bin_dir=$(dirname "$ICX_PATH")
                export PATH="$icx_bin_dir:$PATH"
                echo "OneAPI icx confirmed: $ICX_PATH" | tee -a "$LOG_FILE"
                cmake_flags+=("-DGGML_SYCL=ON")
            else
                echo -e "${B_RED}[!] icx compiler not found. SYCL build will fail.${NC}" | tee -a "$LOG_FILE"
                echo -e "${B_YELLOW}    Run: source /opt/intel/oneapi/setvars.sh --force${NC}"
                echo -e "${B_YELLOW}    Then re-run Build AI Engine.${NC}"
                read -rp "Continue anyway with CPU fallback? (y/n): " sycl_fallback
                [[ "${sycl_fallback,,}" != "y" ]] && { read -p "Press Enter..."; return; }
            fi
            ;;
        *)
            echo "No supported GPU found. Building for CPU only." | tee -a "$LOG_FILE"
            ;;
    esac

    cmake_flags+=("-DGGML_CURL=ON" "-DGGML_SERVER_SSL=ON")

    echo "CMake flags: ${cmake_flags[*]}" | tee -a "$LOG_FILE"
    cmake .. "${cmake_flags[@]}" 2>&1 | tee -a "$LOG_FILE" \
        || { echo "CMake config failed."; read -p "Press Enter..."; return 1; }
    cmake --build . --config Release -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE" \
        || { echo "CMake build failed."; read -p "Press Enter..."; return 1; }

    rotate_log

    if [ -f "bin/llama-server" ]; then
        echo -e "\n${B_GREEN}✔ Success: Built for $current_gpu!${NC}"
        echo -e "${B_YELLOW} Adding $USER to render & video groups…${NC}"
        sudo usermod -aG render "$USER" || true
        sudo usermod -aG video  "$USER" || true
        echo ""
        STEP "Installing binaries to PATH…"
        install_to_path
    else
        echo -e "\n${B_RED}✖ Build failed. Check logs with option 7.${NC}"
    fi
    read -p "Press Enter to return..."
}

# ================================================================
#  BACKGROUND DOWNLOAD ENGINE
#  Spawns a new terminal window so downloads don't block the menu.
#  Progress is tracked via per-download state files in DL_DIR.
# ================================================================

# Find best available terminal emulator
find_terminal() {
    for term in x-terminal-emulator gnome-terminal xterm konsole xfce4-terminal lxterminal mate-terminal; do
        command -v "$term" &>/dev/null && echo "$term" && return
    done
    echo ""
}

# Show a one-line summary of any active/completed downloads in the status bar
show_download_status() {
    [[ -d "$DL_DIR" ]] || return 0
    local active=0 done_count=0 failed=0
    for f in "$DL_DIR"/*.status; do
        [[ -f "$f" ]] || continue
        local st
        st=$(cat "$f" 2>/dev/null || echo "")
        case "$st" in
            RUNNING)   (( active++ )) ;;
            DONE)      (( done_count++ )) ;;
            FAILED)    (( failed++ )) ;;
        esac
    done
    (( active > 0 ))      && echo -e "  Downloads:     ${B_YELLOW}⬇  $active in progress${NC}"
    (( done_count > 0 ))  && echo -e "  Downloads:     ${B_GREEN}✔  $done_count completed (clear with option 2)${NC}"
    (( failed > 0 ))      && echo -e "  Downloads:     ${B_RED}✖  $failed failed (check logs)${NC}"
}

# The actual download worker — run inside the spawned terminal
_download_worker() {
    local url="$1" filename="$2" dest="$3" state_file="$4"
    echo "RUNNING" > "$state_file"
    echo ""
    echo "  Downloading: $filename"
    echo "  To:          $dest/$filename"
    echo "  Source:      $url"
    echo ""
    if curl -L --fail --progress-bar "$url" -o "$dest/$filename.part"; then
        mv "$dest/$filename.part" "$dest/$filename"
        echo "DONE" > "$state_file"
        echo ""
        echo "  ✔ Download complete: $dest/$filename"
    else
        echo "FAILED" > "$state_file"
        rm -f "$dest/$filename.part"
        echo ""
        echo "  ✖ Download FAILED for $filename"
        echo "  URL may be invalid, gated, or network issue."
    fi
    echo ""
    read -rp "  Press Enter to close this window..."
}
# Export so the spawned bash -c subshell can call it
export -f _download_worker

spawn_download() {
    local url="$1" filename="$2"
    mkdir -p "$MODEL_DIR" "$DL_DIR"

    if [[ -f "$MODEL_DIR/$filename" ]]; then
        echo -e "${B_YELLOW}[!] $filename already exists. Skipping.${NC}"
        sleep 2; return
    fi

    # Sanitise filename for use as a state-file name (strip slashes etc.)
    local safe_name="${filename//[^a-zA-Z0-9._-]/_}"
    local state_file="$DL_DIR/${safe_name}.status"
    echo "QUEUED" > "$state_file"

    local term
    term=$(find_terminal)

    if [[ -z "$term" ]]; then
        # No terminal emulator found — fall back to background process with log
        WARN "No terminal emulator found. Downloading in background (no progress bar)."
        (
            if curl -L --fail -s "$url" -o "$MODEL_DIR/$filename.part"; then
                mv "$MODEL_DIR/$filename.part" "$MODEL_DIR/$filename"
                echo "DONE" > "$state_file"
            else
                echo "FAILED" > "$state_file"
                rm -f "$MODEL_DIR/$filename.part"
            fi
        ) >> "$LOG_FILE" 2>&1 &
        OK "Download started in background (PID $!). Check status on main menu."
        sleep 2
        return
    fi

    # Build the command that will run inside the new terminal
    local worker_cmd="bash -c '_download_worker \"\$1\" \"\$2\" \"\$3\" \"\$4\"' _ \
        $(printf '%q' "$url") \
        $(printf '%q' "$filename") \
        $(printf '%q' "$MODEL_DIR") \
        $(printf '%q' "$state_file")"

    case "$term" in
        gnome-terminal)
            gnome-terminal -- bash -c "_download_worker $(printf '%q' "$url") $(printf '%q' "$filename") $(printf '%q' "$MODEL_DIR") $(printf '%q' "$state_file")" &
            ;;
        xterm|lxterminal|mate-terminal|xfce4-terminal|konsole)
            "$term" -e "bash -c \"_download_worker $(printf '%q' "$url") $(printf '%q' "$filename") $(printf '%q' "$MODEL_DIR") $(printf '%q' "$state_file")\"" &
            ;;
        x-terminal-emulator)
            x-terminal-emulator -e "bash -c \"_download_worker $(printf '%q' "$url") $(printf '%q' "$filename") $(printf '%q' "$MODEL_DIR") $(printf '%q' "$state_file")\"" &
            ;;
    esac

    OK "Download window opened for $filename — you can continue using the menu."
    sleep 2
}

# ================================================================
#  MODEL BROWSER
# ================================================================
download_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ 📥  MODEL DOWNLOADER ]${NC}"
        echo ""

        # Show active downloads
        if [[ -d "$DL_DIR" ]]; then
            local any_shown=0
            for f in "$DL_DIR"/*.status; do
                [[ -f "$f" ]] || continue
                local name st
                name=$(basename "$f" .status)
                st=$(cat "$f" 2>/dev/null || echo "?")
                case "$st" in
                    RUNNING) echo -e "  ${B_YELLOW}⬇ DOWNLOADING:${NC} $name" ;;
                    DONE)    echo -e "  ${B_GREEN}✔ COMPLETE:${NC}    $name" ;;
                    FAILED)  echo -e "  ${B_RED}✖ FAILED:${NC}      $name" ;;
                    QUEUED)  echo -e "  ${B_CYAN}⏳ QUEUED:${NC}      $name" ;;
                esac
                any_shown=1
            done
            (( any_shown )) && echo ""
        fi

        echo "  Select model to download:"
        echo "  1) Llama-3-8B  (Smart mid-size — NousResearch Q4_K_M ~4.9 GB)"
        echo "  2) Mistral-7B  (Industry standard — TheBloke Q4_K_M ~4.1 GB)"
        echo "  3) Phi-3-Mini  (Tiny but powerful — bartowski Q4_K_M ~2.2 GB)"
        echo "  4) Custom URL  (Paste direct GGUF link)"
        echo "  5) Clear completed/failed status entries"
        echo "  6) Back"
        echo ""
        local d=""
        read -r -p "  Select [1-6]: " d

        local url="" filename=""
        case $d in
            1) url="https://huggingface.co/NousResearch/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf"
               filename="llama3-8b.gguf" ;;
            2) url="https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
               filename="mistral-7b.gguf" ;;
            3) url="https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF/resolve/main/Phi-3-mini-4k-instruct-Q4_K_M.gguf"
               filename="phi3-mini.gguf" ;;
            4)
               read -r -p "  Paste GGUF URL: " url
               read -r -p "  Save as filename (.gguf): " filename
               if [[ -z "$url" || -z "$filename" ]]; then
                   echo -e "${B_RED}Invalid input.${NC}"; sleep 1; continue
               fi
               [[ "$filename" != *.gguf ]] && filename="${filename}.gguf"
               ;;
            5)
               if [[ -d "$DL_DIR" ]]; then
                   for f in "$DL_DIR"/*.status; do
                       [[ -f "$f" ]] || continue
                       local st; st=$(cat "$f" 2>/dev/null || echo "")
                       [[ "$st" == "DONE" || "$st" == "FAILED" ]] && rm -f "$f"
                   done
                   OK "Cleared completed/failed entries."
               fi
               sleep 1; continue
               ;;
            6) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1; continue ;;
        esac

        # Kick off non-blocking download
        spawn_download "$url" "$filename"
    done
}

# ================================================================
#  SETTINGS — Runtime variable selection menus (NEW)
# ================================================================

# NEW: Interactive context size picker
select_context_size() {
    local doubled=$(( context_size * 2 ))
    echo -e "\n${B_CYAN}Select Context Window Size:${NC}"
    echo "  1)  1024  tokens  (minimal RAM, very short conversations)"
    echo "  2)  2048  tokens"
    echo "  3)  4096  tokens"
    echo "  4)  8192  tokens  (default)"
    echo "  5) 16384  tokens"
    echo "  6) 32768  tokens  (large RAM / VRAM required)"
    echo "  7) Double current → ${doubled} tokens"
    echo "  8) Type a number manually"
    local c=""
    read -r -p "Select [1-8] (current: ${context_size}): " c
    case $c in
        1) declare -g context_size=1024 ;;
        2) declare -g context_size=2048 ;;
        3) declare -g context_size=4096 ;;
        4) declare -g context_size=8192 ;;
        5) declare -g context_size=16384 ;;
        6) declare -g context_size=32768 ;;
        7) declare -g context_size=$doubled ;;
        8)
           local custom_ctx=""
           read -r -p "  Enter context size (min 512): " custom_ctx
           if [[ "$custom_ctx" =~ ^[0-9]+$ ]] && (( custom_ctx >= 512 )); then
               declare -g context_size=$custom_ctx
           else
               WARN "Invalid value — must be a number ≥ 512. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    save_settings
    OK "Context size set to $context_size tokens."
    sleep 1
}

# NEW: API key mode picker
select_api_key_mode() {
    echo -e "\n${B_CYAN}Select API Key Mode:${NC}"
    echo "  Current mode: ${B_YELLOW}${api_key_mode}${NC}"
    echo ""
    echo "  1) Random     — new 24-char hex key generated each server start (default)"
    echo "  2) localtest  — fixed key 'localtest' for local curl/dev testing"
    echo "  3) Custom     — type your own key"
    local a=""
    read -r -p "  Select [1-3]: " a
    case $a in
        1) declare -g api_key_mode="random" ;;
        2) declare -g api_key_mode="localtest"
           WARN "Key 'localtest' is predictable — only use on localhost." ;;
        3)
           local custom_key=""
           read -r -p "  Enter API key (min 8 chars): " custom_key
           if [[ ${#custom_key} -ge 8 ]]; then
               declare -g api_key_mode="custom:${custom_key}"
           else
               WARN "Key too short (min 8 chars). Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    save_settings
    local display_mode="$api_key_mode"
    [[ "$api_key_mode" == custom:* ]] && display_mode="custom (${api_key_mode#custom:})"
    OK "API key mode set to: $display_mode"
    sleep 1
}

# NEW: Interactive network binding picker
select_network_binding() {
    echo -e "\n${B_CYAN}Select Network Accessibility:${NC}"
    echo "  1) 127.0.0.1  — Localhost only  (secure default)"
    echo "  2) 0.0.0.0    — All interfaces  (LAN / network accessible)"
    echo "  3) Custom IP"
    local n=""
    read -r -p "Select [1-3]: " n
    case $n in
        1) declare -g visible2network="127.0.0.1" ;;
        2)
           WARN "Server will be reachable on the network. Ensure your firewall is configured."
           declare -g visible2network="0.0.0.0"
           ;;
        3)
           local custom_ip=""
           read -r -p "Enter bind address (e.g. 192.168.1.50): " custom_ip
           if [[ "$custom_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
               declare -g visible2network="$custom_ip"
           else
               WARN "Invalid IP format. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    save_settings
    OK "Network binding set to $visible2network."
    sleep 1
}

# NEW: Interactive port picker
select_server_port() {
    echo -e "\n${B_CYAN}Select Server Port:${NC}"
    echo "  1) 8080  (default)"
    echo "  2) 8443  (HTTPS convention)"
    echo "  3) 9000"
    echo "  4) Custom"
    local p=""
    read -r -p "Select [1-4]: " p
    case $p in
        1) declare -g network_port="8080" ;;
        2) declare -g network_port="8443" ;;
        3) declare -g network_port="9000" ;;
        4)
           local custom_port=""
           read -r -p "Enter custom port (1024–65535): " custom_port
           if [[ "$custom_port" =~ ^[0-9]+$ ]] && (( custom_port >= 1024 && custom_port <= 65535 )); then
               declare -g network_port="$custom_port"
           else
               WARN "Invalid port. Must be 1024–65535. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    save_settings
    OK "Server port set to $network_port."
    sleep 1
}

# NEW: Settings submenu that ties the three pickers together
settings_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ ⚙  RUNTIME SETTINGS ]${NC}"
        echo -e ""
        echo -e "  Current values:"
        echo -e "    Context size  : ${B_YELLOW}$context_size tokens${NC}"
        echo -e "    Network bind  : ${B_YELLOW}$visible2network${NC}"
        echo -e "    Server port   : ${B_YELLOW}$network_port${NC}"
        echo -e "    API key mode  : ${B_YELLOW}$api_key_mode${NC}"
        echo -e ""
        echo -e "  1) Change Context Size"
        echo -e "  2) Change Network Binding"
        echo -e "  3) Change Server Port"
        echo -e "  4) Change API Key Mode"
        echo -e "  5) Back"
        local s=""
        read -r -p "Select [1-5]: " s
        case $s in
            1) select_context_size ;;
            2) select_network_binding ;;
            3) select_server_port ;;
            4) select_api_key_mode ;;
            5) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# ================================================================
#  GPU LAYER OFFLOAD SELECTOR (replaces free-form numeric prompt)
# ================================================================
prompt_gpu_layers() {
    local current_gpu="$1"
    local default_ngl=0
    [[ "$current_gpu" != "CPU" ]] && default_ngl=99

    echo -e "\n${B_CYAN}GPU Layer Offload:${NC}" >&2
    echo -e "  1)  0  — CPU only (no VRAM used)" >&2
    echo -e "  2) 16  — Partial offload (low VRAM, e.g. 4 GB)" >&2
    echo -e "  3) 32  — Moderate offload (e.g. 8 GB VRAM)" >&2
    echo -e "  4) 99  — Full offload  (recommended for GPU)" >&2
    echo -e "  5) Custom" >&2
    local ngl_choice=""
    read -r -p "Select [1-5] (default: $default_ngl layers): " ngl_choice

    case $ngl_choice in
        1) echo "0" ;;
        2) echo "16" ;;
        3) echo "32" ;;
        4) echo "99" ;;
        5)
           local custom_ngl=""
           read -r -p "Enter number of layers: " custom_ngl
           if [[ "$custom_ngl" =~ ^[0-9]+$ ]]; then
               echo "$custom_ngl"
           else
               WARN "Invalid input. Using default ($default_ngl)." >&2
               echo "$default_ngl"
           fi
           ;;
        "") echo "$default_ngl" ;;
        *)  echo "$default_ngl" ;;
    esac
}

# ================================================================
#  MODEL SELECTION HELPER
# ================================================================
select_model() {
    local prompt_text="$1"
    local models_found=0
    for file in "$MODEL_DIR"/*.gguf; do
        [[ -f "$file" ]] && { models_found=1; break; }
    done

    if [[ $models_found -eq 0 ]]; then
        echo -e "${B_RED}No models found in $MODEL_DIR — download one first.${NC}" >&2
        sleep 2
        return 1
    fi

    local models_arr=("$MODEL_DIR"/*.gguf)
    # Prepend a Cancel entry so the user can always escape
    local menu_items=("${models_arr[@]}" "── Cancel / Back ──")
    PS3="$prompt_text"
    local selected
    select selected in "${menu_items[@]}"; do
        if [[ -z "$selected" ]]; then
            echo "Invalid selection. Try again (or pick the last option to cancel)." >&2
        elif [[ "$selected" == "── Cancel / Back ──" ]]; then
            return 1
        else
            break
        fi
    done
    echo "$selected"
}

# ================================================================
#  TERMINAL CHAT
# ================================================================
chat_mode() {
    draw_header
    load_settings   # reload from file — guards against any subshell scope leakage
    local current_gpu
    current_gpu=$(detect_gpu)

    local model
    model=$(select_model "Select model for chat [#]: ") || return

    local ngl
    ngl=$(prompt_gpu_layers "$current_gpu")

    echo -e "${B_CYAN}Launching chat with $(basename "$model")${NC}"
    echo -e "${B_YELLOW}  Context: $context_size tokens | GPU layers: $ngl${NC}"
    echo -e "${B_YELLOW}  (Type /bye to quit or Ctrl+C to force exit)${NC}"
    echo -e "${B_YELLOW}  --no-context-shift: chat will STOP when context window is full${NC}"

    local chat_exit=0
    "$BUILD_DIR/bin/llama-cli" \
        -c "$context_size" \
        -m "$model" \
        -ngl "$ngl" \
        -cnv --prio 2 \
        --no-context-shift \
        || chat_exit=$?

    if (( chat_exit != 0 )); then
        echo -e ""
        echo -e "${B_RED}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${B_RED}║  Chat ended (exit code $chat_exit)$(printf '%*s' $((31 - ${#chat_exit})) '')║${NC}"
        echo -e "${B_RED}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${B_RED}║${NC}  If the session ran long, the context window  ${B_RED}║${NC}"
        echo -e "${B_RED}║${NC}  (${B_YELLOW}$context_size tokens${NC}) was likely full.$(printf '%*s' $((14 - ${#context_size})) '')${B_RED}║${NC}"
        echo -e "${B_RED}║${NC}  Increase it in ${B_YELLOW}Settings → Context Size${NC}.     ${B_RED}║${NC}"
        echo -e "${B_RED}╚══════════════════════════════════════════════╝${NC}"
    fi

    read -p "Press Enter to return to menu..."
}

# ================================================================
#  HTTPS WEB SERVER
# ================================================================
manage_server() {
    draw_header
    load_settings   # reload from file — guards against any subshell scope leakage

    if [[ -f "$SERVER_PID_FILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$existing_pid" ]] && ps -p "$existing_pid" > /dev/null 2>&1; then
            echo -e "${B_GREEN}Server is running (PID $existing_pid).${NC}"
            # Show saved connection info if available
            if [[ -f "$SERVER_INFO_FILE" ]]; then
                echo -e ""
                cat "$SERVER_INFO_FILE"
                echo -e ""
            fi
            read -p "Stop it? (y/n): " k
            if [[ "$k" == "y" ]]; then
                kill "$existing_pid" 2>/dev/null || true
                rm -f "$SERVER_PID_FILE" "$SERVER_INFO_FILE"
                echo -e "${B_YELLOW}Server stopped.${NC}"
            fi
            read -p "Press Enter to return..."
            return
        else
            rm -f "$SERVER_PID_FILE" "$SERVER_INFO_FILE"
        fi
    fi

    local current_gpu
    current_gpu=$(detect_gpu)

    local model
    model=$(select_model "Select model for server [#]: ") || return

    local ngl
    ngl=$(prompt_gpu_layers "$current_gpu")

    # Generate self-signed cert if needed
    local cert_file="$INSTALL_DIR/server.crt"
    local key_file_ssl="$INSTALL_DIR/server.key"
    if [[ ! -f "$cert_file" ]]; then
        echo "Generating self-signed SSL certificate..."
        openssl req -x509 -newkey rsa:2048 \
            -keyout "$key_file_ssl" \
            -out "$cert_file" \
            -sha256 -days 365 -nodes \
            -subj "/CN=llama.local" &> /dev/null \
            || echo "Warning: Failed to generate SSL cert."
    fi

    local api_key
    case "$api_key_mode" in
        "random")    api_key=$(openssl rand -hex 12) ;;
        "localtest") api_key="localtest" ;;
        custom:*)    api_key="${api_key_mode#custom:}" ;;
        *)           api_key=$(openssl rand -hex 12) ;;   # fallback
    esac

    # FIX: Derive the display URL from the actual bind address.
    # If bound to 0.0.0.0 show the LAN IP; otherwise show exactly what
    # the server is listening on so the URL is always reachable.
    local display_ip
    if [[ "$visible2network" == "0.0.0.0" ]]; then
        display_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "$display_ip" ]] && display_ip="0.0.0.0"
    else
        display_ip="$visible2network"
    fi
    local server_url="https://${display_ip}:${network_port}"

    # FIX: Use --ctx-size (llama-server flag); -c is llama-cli only in
    #      recent llama.cpp builds and is silently ignored by the server.
    "$BUILD_DIR/bin/llama-server" \
        -m "$model" \
        -ngl "$ngl" \
        --ctx-size "$context_size" \
        --host "$visible2network" \
        --port "$network_port" \
        --ssl-key-file "$key_file_ssl" \
        --ssl-cert-file "$cert_file" \
        --api-key "$api_key" \
        > "$INSTALL_DIR/server.log" 2>&1 &

    local server_pid=$!
    echo "$server_pid" > "$SERVER_PID_FILE"

    # Wait up to 4 s for the server to confirm it started
    local started=0
    for _ in 1 2 3 4; do
        sleep 1
        if ! ps -p "$server_pid" > /dev/null 2>&1; then
            echo -e "\n${B_RED}✖ Server process died immediately. Check logs:${NC}"
            echo -e "   $INSTALL_DIR/server.log"
            tail -n 20 "$INSTALL_DIR/server.log" 2>/dev/null || true
            rm -f "$SERVER_PID_FILE"
            read -p "Press Enter to return..."
            return 1
        fi
        grep -q "HTTP server listening" "$INSTALL_DIR/server.log" 2>/dev/null && { started=1; break; }
    done

    # Persist connection info for the status display (readable by main loop)
    {
        echo -e "  ${B_GREEN}URL  :${NC} ${B_CYAN}${server_url}${NC}"
        echo -e "  ${B_GREEN}Key  :${NC} ${B_YELLOW}${api_key}${NC}"
        echo -e "  ${B_GREEN}Model:${NC} $(basename "$model")  |  ctx ${context_size}t  |  ${ngl} GPU layers"
    } > "$SERVER_INFO_FILE"
    chmod 600 "$SERVER_INFO_FILE" 2>/dev/null || true

    # Persist to the audit log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PID=$server_pid | $(basename "$model") | ngl=$ngl | ctx=$context_size | bind=$visible2network | url=$server_url | key=$api_key" >> "$KEY_FILE"
    chmod 600 "$KEY_FILE" 2>/dev/null || true

    echo -e ""
    echo -e "${B_GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${B_GREEN}║  🚀  SERVER LIVE                             ║${NC}"
    echo -e "${B_GREEN}╠══════════════════════════════════════════════╣${NC}"
    printf "${B_GREEN}║${NC}  %-12s ${B_CYAN}%-31s${NC} ${B_GREEN}║${NC}\n" "URL:" "$server_url"
    printf "${B_GREEN}║${NC}  %-12s ${B_YELLOW}%-31s${NC} ${B_GREEN}║${NC}\n" "API Key:" "$api_key"
    printf "${B_GREEN}║${NC}  %-12s %-31s ${B_GREEN}║${NC}\n" "Context:" "${context_size} tokens"
    printf "${B_GREEN}║${NC}  %-12s %-31s ${B_GREEN}║${NC}\n" "Bind addr:" "$visible2network:$network_port"
    [[ $started -eq 0 ]] && \
    printf "${B_YELLOW}║${NC}  %-44s ${B_YELLOW}║${NC}\n" "⚠  Startup not confirmed yet — check logs"
    echo -e "${B_GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo -e "   Logs: $INSTALL_DIR/server.log"
    echo -e "   Keys: $KEY_FILE"
    echo -e "   Note: Accept the self-signed cert warning in your browser."
    read -p "Press Enter to return..."
}

# ================================================================
#  MAIN LOOP
# ================================================================
rotate_log

while true; do
    draw_header
    CUR_GPU=$(detect_gpu)

    echo -e "${B_YELLOW}[ SYSTEM STATUS ]${NC}"
    echo -e "  Detected GPU:  ${B_CYAN}$CUR_GPU${NC}"
    echo -e "  Context size:  ${B_CYAN}$context_size tokens${NC}"
    echo -e "  Network bind:  ${B_CYAN}$visible2network:$network_port${NC}"

    if [ -f "$BUILD_DIR/bin/llama-server" ]; then
        echo -e "  AI Engine:     ${B_GREEN}✓ INSTALLED${NC}"
    else
        echo -e "  AI Engine:     ${B_RED}✗ NOT BUILT${NC}"
    fi

    if [[ -f "$SERVER_PID_FILE" ]]; then
        SRV_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$SRV_PID" ]] && ps -p "$SRV_PID" > /dev/null 2>&1; then
            echo -e "  Web Server:    ${B_GREEN}✓ RUNNING (PID $SRV_PID)${NC}"
            if [[ -f "$SERVER_INFO_FILE" ]]; then
                cat "$SERVER_INFO_FILE"
            fi
        else
            echo -e "  Web Server:    ${B_YELLOW}⚠ PID file stale — server not running${NC}"
            rm -f "$SERVER_PID_FILE" "$SERVER_INFO_FILE"
        fi
    else
        echo -e "  Web Server:    ${B_RED}✗ STOPPED${NC}"
    fi

    MODELS_COUNT=$(find "$MODEL_DIR" -name "*.gguf" 2>/dev/null | wc -l || echo 0)
    echo -e "  Models:        ${B_CYAN}$MODELS_COUNT downloaded${NC}"

    echo -e "------------------------------------------------------"
    echo -e "1) ${B_CYAN}Build AI Engine${NC}     (Auto-Detect: $CUR_GPU)"
    echo -e "2) ${B_CYAN}Download Models${NC}     (Includes Custom URL option)"
    echo -e "3) ${B_GREEN}Interactive Chat${NC}"
    echo -e "4) ${B_GREEN}Start / Stop Web Server${NC}"
    echo -e "5) ${B_YELLOW}⚙  Settings${NC}          (Context, Port, Network)"
    echo -e "6) ${B_RED}DEEP REPAIR${NC}         (Fix Drivers/Conflicts)"
    echo -e "7) View Forensic Logs"
    echo -e "8) View Saved API Keys"
    echo -e "9) Exit"
    read -p "Action: " choice

    case $choice in
        1) build_engine ;;
        2) download_menu ;;
        3) chat_mode ;;
        4) manage_server ;;
        5) settings_menu ;;
        6) deep_repair ;;
        7)
            draw_header
            echo -e "${B_CYAN}--- Last 50 lines of $LOG_FILE ---${NC}"
            tail -n 50 "$LOG_FILE" 2>/dev/null || echo "(Log file is empty or missing)"
            read -p "Press Enter to return..."
            ;;
        8)
            draw_header
            echo -e "${B_CYAN}--- Saved API Keys ($KEY_FILE) ---${NC}"
            cat "$KEY_FILE" 2>/dev/null || echo "(No keys saved yet)"
            read -p "Press Enter to return..."
            ;;
        9) echo -e "${B_CYAN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
