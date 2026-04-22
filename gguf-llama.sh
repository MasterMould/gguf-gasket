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

# --- Config (all overridable at runtime via the Settings menu) ---
context_size=16384         # tokens: 1024 2048 4096 8192 16384 32768
visible2network="0.0.0.0"   # 0.0.0.0 = LAN-accessible  127.0.0.1 = localhost only
network_port="8080"

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
# FIX: Unreachable code (platform check, disk info, ask) was placed
#      AFTER 'return 0' and could never execute. Moved above return.
# ================================================================
check_deps() {
    local missing=()
    for cmd in git cmake curl openssl lspci ccache nproc; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${B_RED}[!] Missing required tools: ${missing[*]}${NC}"
        echo -e "    Install with: sudo apt install ${missing[*]}"
        echo -e "    (pciutils provides lspci; coreutils provides nproc)"
        return 1
    fi

    # Validate x86_64 platform (was unreachable before)
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

    # ── Intel compute-runtime (OpenCL ICD + level-zero) ──────────
    INFO "Checking Intel GPU driver packages…"

    if [[ ! -f /etc/apt/sources.list.d/intel-gpu.list ]]; then
        wget -qO - https://repositories.intel.com/gpu/intel-graphics.key \
            | sudo gpg --yes --dearmor \
                -o /usr/share/keyrings/intel-graphics.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] \
https://repositories.intel.com/gpu/ubuntu noble unified" \
            | sudo tee /etc/apt/sources.list.d/intel-gpu.list
        sudo apt-get update -qq || true
    fi

    local PKGS=()

    if ! dpkg -l intel-opencl-icd 2>/dev/null | grep -q '^ii'; then
        PKGS+=("intel-opencl-icd")
    else
        INFO "  intel-opencl-icd     ✓ already installed"
    fi

    if dpkg -l libze-intel-gpu1 2>/dev/null | grep -q '^ii' \
    || dpkg -l intel-level-zero-gpu 2>/dev/null | grep -q '^ii'; then
        INFO "  level-zero GPU shim  ✓ already installed"
    else
        PKGS+=("libze-intel-gpu1")
    fi

    if ! dpkg -l libze1 2>/dev/null | grep -q '^ii'; then
        PKGS+=("libze1")
    else
        INFO "  libze1               ✓ already installed"
    fi

    if [[ ${#PKGS[@]} -gt 0 ]]; then
        INFO "  Installing: ${PKGS[*]}"
        sudo apt-get install -y "${PKGS[@]}" &>> "$LOG_FILE" || true
    fi

    sudo apt-get install -y --no-install-recommends clinfo libze-dev &>> "$LOG_FILE" 2>/dev/null || true
    OK "Intel GPU driver packages ready."

    # ── Intel oneAPI — compiler + runtime ─────────────────────────
    INFO "Checking Intel oneAPI compiler…"
    local ICX_BIN=""
    ICX_BIN=$(command -v icx 2>/dev/null) \
        || ICX_BIN=$(find /opt/intel/oneapi -name icx -type f 2>/dev/null | head -1) \
        || true

    if [[ -n "$ICX_BIN" ]]; then
        OK "Intel icx compiler found: $ICX_BIN"
    else
        INFO "Installing Intel oneAPI compiler (intel-oneapi-compiler-dpcpp-cpp)…"
        if [[ ! -f /etc/apt/sources.list.d/oneAPI.list ]]; then
            wget -qO - https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
                | sudo gpg --yes --dearmor \
                    -o /usr/share/keyrings/oneapi-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] \
https://apt.repos.intel.com/oneapi all main" \
                | sudo tee /etc/apt/sources.list.d/oneAPI.list
            sudo apt-get update -qq || true
        fi
        sudo apt-get install -y intel-oneapi-compiler-dpcpp-cpp &>> "$LOG_FILE"
        ICX_BIN=$(command -v icx 2>/dev/null) \
            || ICX_BIN=$(find /opt/intel/oneapi -name icx -type f 2>/dev/null | head -1) \
            || true
        [[ -n "$ICX_BIN" ]] \
            && OK "icx installed: $ICX_BIN" \
            || ERR "icx still not found after install — check apt output above."
    fi

    # ── Groups + verify ───────────────────────────────────────────
    sudo usermod -aG render,video "$USER" 2>/dev/null || true
    OK "User added to render/video groups (re-login to take effect)."

    INFO "GPU visibility check:"
    echo -e "  OpenCL (clinfo):"; clinfo -l 2>/dev/null | grep -i "intel\|Arc" || WARN "  No Intel GPU via OpenCL"
    echo -e "  level-zero backend:"
    if dpkg -l libze-intel-gpu1 2>/dev/null | grep -q '^ii'; then
        OK "  libze-intel-gpu1 installed — SYCL should see the GPU after re-login"
    else
        WARN "  libze-intel-gpu1 NOT installed — SYCL will not find the GPU!"
        WARN "  Run: sudo apt-get install libze-intel-gpu1"
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
#  SMART BUILD ENGINE
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
            if source /opt/intel/oneapi/setvars.sh 2>/dev/null; then
                echo "OneAPI environment loaded." | tee -a "$LOG_FILE"
                cmake_flags+=("-DGGML_SYCL=ON")
            else
                echo -e "${B_RED}[!] Intel OneAPI not found. SYCL build will likely fail.${NC}" | tee -a "$LOG_FILE"
                read -p "Continue anyway with CPU fallback? (y/n): " sycl_fallback
                [[ "$sycl_fallback" != "y" ]] && { read -p "Press Enter..."; return; }
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
    else
        echo -e "\n${B_RED}✖ Build failed. Check logs with option 7.${NC}"
    fi
    read -p "Press Enter to return..."
}

# ================================================================
#  MODEL BROWSER
# ================================================================
download_menu() {
    draw_header
    echo "Select an AI Brain to download:"
    echo "1) Llama-3-8B  (Smart mid-size — NousResearch Q4_K_M)"
    echo "2) Mistral-7B  (Industry standard — TheBloke Q4_K_M)"
    echo "3) Phi-3-Mini  (Tiny but powerful — bartowski Q4_K_M)"
    echo "4) Custom URL  (Paste direct GGUF download link)"
    echo "5) Back"
    read -p "Select [1-5]: " d

    local url filename
    case $d in
        1) url="https://huggingface.co/NousResearch/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf"
           filename="llama3-8b.gguf" ;;
        2) url="https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
           filename="mistral-7b.gguf" ;;
        3) url="https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF/resolve/main/Phi-3-mini-4k-instruct-Q4_K_M.gguf"
           filename="phi3-mini.gguf" ;;
        4)
           read -p "Paste direct GGUF URL: " url
           read -p "Enter filename to save as (e.g., https://huggingface.co/ or mymodel.gguf): " filename
           if [[ -z "$url" || -z "$filename" ]]; then
               echo -e "${B_RED}Invalid input.${NC}"
               sleep 1; return
           fi
           [[ "$filename" != *.gguf ]] && filename="${filename}.gguf"
           ;;
        *) return ;;
    esac

    mkdir -p "$MODEL_DIR"

    if [[ -f "$MODEL_DIR/$filename" ]]; then
        echo -e "${B_YELLOW}[!] $filename already exists. Skipping download.${NC}"
        read -p "Press Enter to return..."
        return
    fi

    echo -e "${B_CYAN}Downloading $filename...${NC}"
    if curl -L --fail --progress-bar "$url" -o "$MODEL_DIR/$filename"; then
        echo -e "${B_GREEN}✔ Download complete: $MODEL_DIR/$filename${NC}"
    else
        echo -e "${B_RED}✖ Download failed. The URL may be invalid or gated.${NC}"
        rm -f "$MODEL_DIR/$filename"
    fi
    read -p "Press Enter to return..."
}

# ================================================================
#  SETTINGS — Runtime variable selection menus (NEW)
# ================================================================

# NEW: Interactive context size picker
select_context_size() {
    echo -e "\n${B_CYAN}Select Context Window Size:${NC}"
    echo "  1)  1024  tokens  (minimal RAM, very short conversations)"
    echo "  2)  2048  tokens"
    echo "  3)  4096  tokens"
    echo "  4)  8192  tokens  (current default)"
    echo "  5) 16384  tokens"
    echo "  6) 32768  tokens  (large RAM / VRAM required)"
    echo "  7) Custom"
    read -p "Select [1-7]: " c
    case $c in
        1) context_size=1024 ;;
        2) context_size=2048 ;;
        3) context_size=4096 ;;
        4) context_size=8192 ;;
        5) context_size=16384 ;;
        6) context_size=32768 ;;
        7)
           read -p "Enter custom context size (min 512): " custom_ctx
           if [[ "$custom_ctx" =~ ^[0-9]+$ ]] && (( custom_ctx >= 512 )); then
               context_size=$custom_ctx
           else
               WARN "Invalid value — must be a number ≥ 512. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    OK "Context size set to $context_size tokens."
    sleep 1
}

# NEW: Interactive network binding picker
select_network_binding() {
    echo -e "\n${B_CYAN}Select Network Accessibility:${NC}"
    echo "  1) 127.0.0.1  — Localhost only  (secure default)"
    echo "  2) 0.0.0.0    — All interfaces  (LAN / network accessible)"
    echo "  3) Custom IP"
    read -p "Select [1-3]: " n
    case $n in
        1) visible2network="127.0.0.1" ;;
        2)
           WARN "Server will be reachable on the network. Ensure your firewall is configured."
           visible2network="0.0.0.0"
           ;;
        3)
           read -p "Enter bind address (e.g. 192.168.1.50): " custom_ip
           if [[ "$custom_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
               visible2network="$custom_ip"
           else
               WARN "Invalid IP format. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
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
    read -p "Select [1-4]: " p
    case $p in
        1) network_port="8080" ;;
        2) network_port="8443" ;;
        3) network_port="9000" ;;
        4)
           read -p "Enter custom port (1024–65535): " custom_port
           if [[ "$custom_port" =~ ^[0-9]+$ ]] && (( custom_port >= 1024 && custom_port <= 65535 )); then
               network_port="$custom_port"
           else
               WARN "Invalid port. Must be 1024–65535. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
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
        echo -e ""
        echo -e "  1) Change Context Size"
        echo -e "  2) Change Network Binding"
        echo -e "  3) Change Server Port"
        echo -e "  4) Back"
        read -p "Select [1-4]: " s
        case $s in
            1) select_context_size ;;
            2) select_network_binding ;;
            3) select_server_port ;;
            4) return ;;
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
    read -p "Select [1-5] (default: $default_ngl layers): " ngl_choice

    case $ngl_choice in
        1) echo "0" ;;
        2) echo "16" ;;
        3) echo "32" ;;
        4) echo "99" ;;
        5)
           read -p "Enter number of layers: " custom_ngl >&2 || true
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
    PS3="$prompt_text"
    local selected
    select selected in "${models_arr[@]}"; do
        [[ -n "$selected" ]] && break
        echo "Invalid selection. Try again."
    done
    echo "$selected"
}

# ================================================================
#  TERMINAL CHAT
# ================================================================
chat_mode() {
    draw_header
    local current_gpu
    current_gpu=$(detect_gpu)

    local model
    model=$(select_model "Select model for chat [#]: ") || return

    local ngl
    ngl=$(prompt_gpu_layers "$current_gpu")

    echo -e "${B_CYAN}Launching chat with $(basename "$model")${NC}"
    echo -e "${B_YELLOW}  Context: $context_size tokens | GPU layers: $ngl${NC}"
    echo -e "${B_YELLOW}  (Type /exit to quit or Ctrl+C to force exit)${NC}"

    "$BUILD_DIR/bin/llama-cli" \
        -c "$context_size" \
        -m "$model" \
        -ngl "$ngl" \
        -cnv --prio 2 \
        || echo -e "\n${B_RED}Chat process exited (or encountered an error).${NC}"

    read -p "Press Enter to return to menu..."
}

# ================================================================
#  HTTPS WEB SERVER
# ================================================================
manage_server() {
    draw_header

    if [[ -f "$SERVER_PID_FILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$existing_pid" ]] && ps -p "$existing_pid" > /dev/null 2>&1; then
            echo -e "${B_GREEN}Server is running (PID $existing_pid).${NC}"
            read -p "Stop it? (y/n): " k
            if [[ "$k" == "y" ]]; then
                kill "$existing_pid" 2>/dev/null || true
                rm -f "$SERVER_PID_FILE"
                echo -e "${B_YELLOW}Server stopped.${NC}"
            fi
            read -p "Press Enter to return..."
            return
        else
            rm -f "$SERVER_PID_FILE"
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
    api_key=$(openssl rand -hex 12)

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="$visible2network"

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

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Server PID=$server_pid | Model=$(basename "$model") | GPU layers=$ngl | Context=$context_size | Key=$api_key" >> "$KEY_FILE"
    chmod 600 "$KEY_FILE" 2>/dev/null || true

    echo -e "\n${B_GREEN}🚀 SERVER LIVE: https://$ip:$network_port ${NC}"
    echo -e "${B_YELLOW}   API Key: $api_key${NC}"
    echo -e "   Context: $context_size tokens"
    echo -e "   Key saved to: $KEY_FILE"
    echo -e "   Logs: $INSTALL_DIR/server.log"
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
        else
            echo -e "  Web Server:    ${B_YELLOW}⚠ PID file stale — server not running${NC}"
            rm -f "$SERVER_PID_FILE"
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
