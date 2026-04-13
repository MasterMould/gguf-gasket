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

# --- Paths ---
INSTALL_DIR="$HOME/ai_stack/llama.cpp"
BUILD_DIR="$INSTALL_DIR/build"
MODEL_DIR="$HOME/ai_stack/models"
LOG_FILE="$HOME/llama_forensics.log"
SERVER_PID_FILE="/tmp/llama_server.pid"
KEY_FILE="$HOME/llama_api_keys.log"

# --- Config ---
# for web server
#Set network acessability: 0.0.0.0 = Yes - 127.0.0.1 = No 
visible2network="127.0.0.1"
# change acess port from default 8080 
$network_port="8080"

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
    echo -e "           🦙 LLAMA COMMAND CENTER (v8.1) 🦙"
    echo -e "           * Universal GPU & Repair Mode *"
    echo -e "======================================================${NC}"
}

# --- ✅ PREFLIGHT DEPENDENCY CHECK ---
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
    return 0
    
# validare x86_64 platform
    [[ "$(uname -m)" == "x86_64" ]] || ERR "x86_64 required."

# confirm to proceed
    echo ""
    INFO "Available disk: $(df -h "$HOME" | awk 'NR==2{print $4}') free"
    INFO "System RAM: $(free -h | awk '/Mem:/ {print $2}')"
    WARN "The 8B model download is ~5 GB. Ensure you have ~8 GB free total."
    ask "Continue?" || exit 0
}

# --- 🔍 HARDWARE DETECTION ENGINE ---
detect_gpu() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null || true)

    if echo "$gpu_info" | grep -iq "NVIDIA"; then
        echo "NVIDIA"
    elif echo "$gpu_info" | grep -iqE "(Advanced Micro Devices|ATI).*(VGA|Display|3D|Radeon)"; then
        echo "AMD"
        sudo apt-get install -y libnuma-dev libvulkan-dev:i386 libvulkan-dev wget vulkan-tools glslang-tools libvulkan gnupg2
    
    elif echo "$gpu_info" | grep -iqE "Intel.*(Arc|UHD|Iris|Graphics)"; then
        echo "INTEL"
# Method 1    
        if clinfo | grep -i "Device Name" | grep -iq "Arc"; then
    OK " Intel Arc GPU visible via OpenCL"
    else
        WARN "  Intel Arc GPU NOT fully visible via OpenCL"
    fi
# Method 2    
    if lspci | grep -qi "Arc A770"; then
    OK " Intel Arc A770 detected via lspci"
    else
        WARN "Could not confirm Arc A770 via lspci. Proceeding anyway — verify your GPU."
        lspci | grep -i "VGA\|Display\|3D" || true
    fi
    
    else
        echo "CPU"
    fi
}

# --- 🛠️ UNIVERSAL REPAIR & DEPENDENCY MODULE ---
deep_repair() {
    draw_header
    local current_gpu
    current_gpu=$(detect_gpu)
    echo -e "${B_RED}[!!!] STARTING UNIVERSAL REPAIR [!!!]${NC}"
    echo -e "${B_YELLOW}[!] WARNING: This will modify system drivers. Ensure you have a way to recover.${NC}"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { echo "Repair cancelled."; sleep 1; return; }

    echo "Detected Hardware: $current_gpu" | tee -a "$LOG_FILE"

    # 1. Fix APT/DPKG issues safely (without force-overwrite)
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
                sudo apt-get update && sudo apt-get install -y ubuntu-drivers-common
                sudo ubuntu-drivers autoinstall &>> "$LOG_FILE" || true
            else
                echo "Skipping NVIDIA driver reinstall." | tee -a "$LOG_FILE"
            fi
            ;;
        "AMD")
            echo "Installing AMD ROCm dependencies..." | tee -a "$LOG_FILE"
            sudo apt-get update &>> "$LOG_FILE" || true
            sudo apt-get install -y libnuma-dev libvulkan-dev:i386 libvulkan-dev wget vulkan-tools glslang-tools libvulkan gnupg2 &>> "$LOG_FILE" || true
            sudo apt-get install -y "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)" &>> "$LOG_FILE" || true
            ;;
        "INTEL")
            echo "Installing Intel OneAPI/Compute dependencies..." | tee -a "$LOG_FILE"
            sudo apt-get update &>> "$LOG_FILE" || true
            sudo apt-get install -y intel-opencl-icd intel-level-zero-gpu level-zero &>> "$LOG_FILE" || true
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

# --- 🏗️ SMART BUILD ENGINE ---
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
    sudo apt-get install -y build-essential git curl cmake libcurl4-openssl-dev libssl-dev &>> "$LOG_FILE" || true

    mkdir -p "$HOME/ai_stack"

    if [ ! -d "$INSTALL_DIR/.git" ]; then
        git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR" | tee -a "$LOG_FILE" || { echo "Clone failed."; read -p "Press Enter..."; return 1; }
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

    # Use an array for safe flag handling
    local cmake_flags=()

    case $current_gpu in
        "NVIDIA")
            local arch
            arch=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d '.' | grep -E '^[0-9]+$' | head -n 1 || true)
            [ -z "$arch" ] && arch="all-major"
            echo "Using CUDA architecture: $arch" | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_CUDA=ON" "-DCMAKE_CUDA_ARCHITECTURES=$arch")
            ;;
        "AMD")
            echo "Optimizing for AMD (Vulkan)..." | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_VULKAN=ON")
            ;;
        "INTEL")
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
    cmake .. "${cmake_flags[@]}" 2>&1 | tee -a "$LOG_FILE" || { echo "CMake config failed."; read -p "Press Enter..."; return 1; }
    cmake --build . --config Release -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE" || { echo "CMake build failed."; read -p "Press Enter..."; return 1; }

    rotate_log

    if [ -f "bin/llama-server" ]; then
        echo -e "\n${B_GREEN}✔ Success: Built for $current_gpu!${NC}"
        # Add current user to groups
        echo -e "${B_YELLOW} Adding $USER to render & video groups... ${NC}"
        sudo usermod -aG render $USER
        sudo usermod -aG video $USER
    else
        echo -e "\n${B_RED}✖ Build failed. Check logs with option 6.${NC}"
    fi
    read -p "Press Enter to return..."
}

# --- 📥 MODEL BROWSER ---
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
           read -p "Enter filename to save as (e.g., mymodel.gguf): " filename
           if [[ -z "$url" || -z "$filename" ]]; then
               echo -e "${B_RED}Invalid input.${NC}"
               sleep 1; return
           fi
           # Ensure it ends in .gguf
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

# --- GPU layer helper ---
prompt_gpu_layers() {
    local current_gpu="$1"
    local default_ngl=0
    if [[ "$current_gpu" != "CPU" ]]; then
        default_ngl=99
    fi
    read -p "GPU layers to offload: 0=CPU only, 99=all (Default all if GPU present) [$default_ngl]: " ngl_input
    echo "${ngl_input:-$default_ngl}"
}

# --- Model selection helper ---
select_model() {
    local prompt_text="$1"
    # Need to handle case where no models exist without throwing unbound variable error
    local models_found=0
    for file in "$MODEL_DIR"/*.gguf; do
        if [[ -f "$file" ]]; then models_found=1; break; fi
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

# --- 💬 TERMINAL CHAT ---
chat_mode() {
    draw_header
    local current_gpu
    current_gpu=$(detect_gpu)

    local model
    model=$(select_model "Select model for chat [#]: ") || return

    local ngl
    ngl=$(prompt_gpu_layers "$current_gpu")

    echo -e "${B_CYAN}Launching chat with $(basename "$model") | GPU layers: $ngl${NC}"
    echo -e "${B_YELLOW}(Type /exit to quit or Ctrl+C to force exit)${NC}"
    
    # Armored execution so a segfault or out-of-memory doesn't kill the whole menu script
    "$BUILD_DIR/bin/llama-cli" -m "$model" -ngl "$ngl" -cnv --prio 2 || echo -e "\n${B_RED}Chat process exited (or encountered an error).${NC}"
    
    read -p "Press Enter to return to menu..."
}

# --- 🌐 HTTPS WEB SERVER ---
manage_server() {
    draw_header

    # Handle running server
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
            # Stale PID file
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
            -subj "/CN=llama.local" &> /dev/null || echo "Warning: Failed to generate SSL cert."
    fi

    local api_key
    api_key=$(openssl rand -hex 12)

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="127.0.0.1"

    "$BUILD_DIR/bin/llama-server" \
        -m "$model" \
        -ngl "$ngl" \
        --host "$visible2network" \
        --port "$network_port" \
        --ssl-key-file "$key_file_ssl" \
        --ssl-cert-file "$cert_file" \
        --api-key "$api_key" \
        > "$INSTALL_DIR/server.log" 2>&1 &

    local server_pid=$!
    echo "$server_pid" > "$SERVER_PID_FILE"

    # Persist API key securely
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Server PID=$server_pid | Model=$(basename "$model") | GPU layers=$ngl | Key=$api_key" >> "$KEY_FILE"
    chmod 600 "$KEY_FILE" 2>/dev/null || true

    echo -e "\n${B_GREEN}🚀 SERVER LIVE: https://$ip:$network_port ${NC}"
    echo -e "${B_YELLOW}   API Key: $api_key${NC}"
    echo -e "   Key saved to: $KEY_FILE"
    echo -e "   Logs: $INSTALL_DIR/server.log"
    read -p "Press Enter to return..."
}

# --- MAIN LOOP ---
rotate_log

while true; do
    draw_header
    CUR_GPU=$(detect_gpu)

    echo -e "${B_YELLOW}[ SYSTEM STATUS ]${NC}"
    echo -e "  Detected GPU:  ${B_CYAN}$CUR_GPU${NC}"

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
    echo -e "1) ${B_CYAN}Build AI Engine${NC}  (Auto-Detect: $CUR_GPU)"
    echo -e "2) ${B_CYAN}Download Models${NC}  (Includes Custom URL option)"
    echo -e "3) ${B_GREEN}Interactive Chat${NC}"
    echo -e "4) ${B_GREEN}Start / Stop Web Server${NC}"
    echo -e "5) ${B_RED}DEEP REPAIR${NC}      (Fix Drivers/Conflicts)"
    echo -e "6) View Forensic Logs"
    echo -e "7) View Saved API Keys"
    echo -e "8) Exit"
    read -p "Action: " choice

    case $choice in
        1) build_engine ;;
        2) download_menu ;;
        3) chat_mode ;;
        4) manage_server ;;
        5) deep_repair ;;
        6)
            draw_header
            echo -e "${B_CYAN}--- Last 50 lines of $LOG_FILE ---${NC}"
            tail -n 50 "$LOG_FILE" 2>/dev/null || echo "(Log file is empty or missing)"
            read -p "Press Enter to return..."
            ;;
        7)
            draw_header
            echo -e "${B_CYAN}--- Saved API Keys ($KEY_FILE) ---${NC}"
            cat "$KEY_FILE" 2>/dev/null || echo "(No keys saved yet)"
            read -p "Press Enter to return..."
            ;;
        8) echo -e "${B_CYAN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
