#!/bin/bash

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

draw_header() {
    echo -e "${CLEAR}${B_CYAN}======================================================"
    echo -e "           🦙 LLAMA COMMAND CENTER (v7.0) 🦙"
    echo -e "           * Universal GPU & Repair Mode *"
    echo -e "======================================================${NC}"
}

# --- 🔍 HARDWARE DETECTION ENGINE ---
detect_gpu() {
    if lspci | grep -iq "NVIDIA"; then
        GPU_TYPE="NVIDIA"
    elif lspci | grep -iq "Advanced Micro Devices" || lspci | grep -iq "ATI"; then
        GPU_TYPE="AMD"
    elif lspci | grep -iq "Intel" && lspci | grep -iq "Graphics"; then
        # Check specifically for Arc / Discrete graphics
        GPU_TYPE="INTEL"
    else
        GPU_TYPE="CPU"
    fi
    echo "$GPU_TYPE"
}

# --- 🛠️ UNIVERSAL REPAIR & DEPENDENCY MODULE ---
deep_repair() {
    draw_header
    CURRENT_GPU=$(detect_gpu)
    echo -e "${B_RED}[!!!] STARTING UNIVERSAL REPAIR [!!!]${NC}"
    echo "Detected Hardware: $CURRENT_GPU" | tee -a "$LOG_FILE"
    
    # 1. Clear APT deadlocks (The Sledgehammer)
    echo -e "\n1. Smashing APT/DPKG locks..." | tee -a "$LOG_FILE"
    sudo dpkg --configure -a &>> "$LOG_FILE"
    sudo dpkg -i --force-overwrite /var/cache/apt/archives/*.deb 2>/dev/null
    sudo apt-get --fix-broken install -y &>> "$LOG_FILE"

    # 2. Hardware-Specific Driver Support
    case $CURRENT_GPU in
        "NVIDIA")
            echo "Repairing NVIDIA Driver fragments..." | tee -a "$LOG_FILE"
            sudo apt-get remove --purge -y '^nvidia-.*' '^libnvidia-.*' &>> "$LOG_FILE"
            sudo apt-get update && sudo apt-get install -y ubuntu-drivers-common
            sudo ubuntu-drivers autoinstall &>> "$LOG_FILE"
            ;;
        "AMD")
            echo "Installing AMD ROCm dependencies..." | tee -a "$LOG_FILE"
            sudo apt-get update && sudo apt-get install -y libnuma-dev wget gnupg2
            # Note: Full ROCm install is large; this ensures the kernel headers are ready
            sudo apt-get install -y "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"
            ;;
        "INTEL")
            echo "Installing Intel OneAPI/Compute dependencies..." | tee -a "$LOG_FILE"
            sudo apt-get update && sudo apt-get install -y intel-opencl-icd intel-level-zero-gpu level-zero
            ;;
    esac

    echo -e "\n${B_GREEN}Repair sequence finished. REBOOT recommended.${NC}"
    read -p "Reboot now? (y/n): " rb
    [[ "$rb" == "y" ]] && sudo reboot
}

# --- 🏗️ SMART BUILD ENGINE ---
build_engine() {
    draw_header
    CURRENT_GPU=$(detect_gpu)
    echo -e "${B_CYAN}Building AI Engine for $CURRENT_GPU...${NC}"
    
    # Base Dependencies
    sudo apt-get install -y build-essential git curl cmake libcurl4-openssl-dev libssl-dev

    mkdir -p "$HOME/ai_stack"
    [ ! -d "$INSTALL_DIR" ] && git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR" || (cd "$INSTALL_DIR" && git pull)

    cd "$INSTALL_DIR" || exit
    rm -rf build && mkdir build && cd build

    # Configure Build Flags based on detected GPU
    case $CURRENT_GPU in
        "NVIDIA")
            ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d '.' | grep -E '^[0-9]+$' | head -n 1)
            [ -z "$ARCH" ] && ARCH="all-major"
            CMAKE_FLAGS="-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=$ARCH"
            ;;
        "AMD")
            echo "Optimizing for AMD (HIP/ROCm)..."
            CMAKE_FLAGS="-DGGML_HIPBLAS=ON"
            ;;
        "INTEL")
            echo "Optimizing for Intel Arc (SYCL)..."
            CMAKE_FLAGS="-DGGML_SYCL=ON"
            ;;
        *)
            echo "No supported GPU found. Building for CPU only."
            CMAKE_FLAGS=""
            ;;
    esac

    cmake .. $CMAKE_FLAGS -DGGML_CURL=ON -DGGML_SERVER_SSL=ON
    cmake --build . --config Release -j$(nproc)
    
    if [ -f "bin/llama-server" ]; then
        echo -e "\n${B_GREEN}✔ Success: Built for $CURRENT_GPU!${NC}"
    else
        echo -e "\n${B_RED}✖ Build failed. Check logs.${NC}"
    fi
    read -p "Press Enter to return..."
}

# --- 📥 MODEL BROWSER (Restored) ---
download_menu() {
    draw_header
    echo "Select an AI Brain to download:"
    echo "1) Llama-3-8B (The smartest mid-size)"
    echo "2) Mistral-7B (The industry standard)"
    echo "3) Phi-3-Mini (Tiny but powerful)"
    echo "4) Back"
    read -p "Select [1-4]: " d
    case $d in
        1) U="https://huggingface.co/NousResearch/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct-Q4_K_M.gguf"; F="llama3-8b.gguf" ;;
        2) U="https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf"; F="mistral-7b.gguf" ;;
        3) U="https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF/resolve/main/Phi-3-mini-4k-instruct-Q4_K_M.gguf"; F="phi3.gguf" ;;
        *) return ;;
    esac
    mkdir -p "$MODEL_DIR"
    echo -e "${B_CYAN}Downloading $F...${NC}"
    curl -L -# "$U" -o "$MODEL_DIR/$F"
    read -p "Download finished! Press Enter..."
}

# --- 💬 TERMINAL CHAT (Restored) ---
chat_mode() {
    draw_header
    models=("$MODEL_DIR"/*.gguf)
    [[ ! -e "${models[0]}" ]] && { echo -e "${B_RED}No models found!${NC}"; sleep 2; return; }
    echo "Select a model to talk to:"
    select m in "${models[@]}"; do [ -n "$m" ] && break; done
    "$BUILD_DIR/bin/llama-cli" -m "$m" -cnv --prio 2
}

# --- 🌐 HTTPS WEB SERVER (Restored) ---
manage_server() {
    draw_header
    if [ -f "$SERVER_PID_FILE" ] && ps -p $(cat "$SERVER_PID_FILE") > /dev/null; then
        PID=$(cat "$SERVER_PID_FILE")
        read -p "Server is ON. Stop it? (y/n): " k
        [[ "$k" == "y" ]] && kill $PID && rm "$SERVER_PID_FILE" && echo "Stopped."
        return
    fi
    models=("$MODEL_DIR"/*.gguf)
    [[ ! -e "${models[0]}" ]] && { echo -e "${B_RED}No models found!${NC}"; sleep 2; return; }
    echo "Select model for Web Server:"
    select m in "${models[@]}"; do [ -n "$m" ] && break; done
    [ ! -f "$INSTALL_DIR/server.crt" ] && openssl req -x509 -newkey rsa:2048 -keyout "$INSTALL_DIR/server.key" -out "$INSTALL_DIR/server.crt" -sha256 -days 365 -nodes -subj "/CN=llama.local" &> /dev/null
    KEY=$(openssl rand -hex 12)
    IP=$(hostname -I | awk '{print $1}')
    "$BUILD_DIR/bin/llama-server" -m "$m" --host 0.0.0.0 --port 8080 --ssl-key-file "$INSTALL_DIR/server.key" --ssl-cert-file "$INSTALL_DIR/server.crt" --api-key "$KEY" > "$INSTALL_DIR/server.log" 2>&1 &
    echo $! > "$SERVER_PID_FILE"
    echo -e "\n${B_GREEN}🚀 SERVER LIVE: https://$IP:8080 | Key: $KEY${NC}"
    read -p "Press Enter to return..."
}

# --- MAIN LOOP ---
while true; do
    draw_header
    CUR_GPU=$(detect_gpu)
    echo -e "${B_YELLOW}[ SYSTEM STATUS ]${NC}"
    echo -e "  Detected GPU: ${B_CYAN}$CUR_GPU${NC}"
    [ -f "$BUILD_DIR/bin/llama-server" ] && echo -e "  AI Engine:    ${B_GREEN}✓ INSTALLED${NC}" || echo -e "  AI Engine:    ${B_RED}✗ NOT BUILT${NC}"
    echo -e "------------------------------------------------------"
    echo -e "1) ${B_CYAN}Build AI Engine${NC} (Auto-Detect $CUR_GPU)"
    echo -e "2) ${B_CYAN}Download Models${NC}"
    echo -e "3) ${B_GREEN}Interactive Chat${NC}"
    echo -e "4) ${B_GREEN}Start Web Server${NC}"
    echo -e "5) ${B_RED}DEEP REPAIR${NC} (Fix Drivers/Conflicts)"
    echo -e "6) View Forensic Logs"
    echo -e "7) Exit"
    read -p "Action: " choice
    case $choice in
        1) build_engine ;;
        2) download_menu ;;
        3) chat_mode ;;
        4) manage_server ;;
        5) deep_repair ;;
        6) draw_header; tail -n 50 "$LOG_FILE"; read -p "Press Enter..." ;;
        7) exit 0 ;;
    esac
done
