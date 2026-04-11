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
MODEL_DIR="$INSTALL_DIR/models"
LOG_FILE="$HOME/llama_forensics.log"
SERVER_PID_FILE="/tmp/llama_server.pid"

draw_header() {
    echo -e "${CLEAR}${B_CYAN}======================================================"
    echo -e "           🦙 LLAMA COMMAND CENTER (v6.0) 🦙"
    echo -e "           * Restored & Sledgehammer Mode *"
    echo -e "======================================================${NC}"
}

# --- 🛠️ THE SLEDGEHAMMER REPAIR MODULE ---
# This handles the specific "dpkg" deadlock automatically.
deep_repair() {
    draw_header
    echo -e "${B_RED}[!!!] STARTING NUCLEAR REPAIR [!!!]${NC}"
    echo "This module will force-overwrite broken packages." | tee -a "$LOG_FILE"
    
    echo -e "\n1. Forcing DPKG configuration..." | tee -a "$LOG_FILE"
    sudo dpkg --configure -a &>> "$LOG_FILE"

    echo "2. Smashing file collisions (The Sledgehammer)..." | tee -a "$LOG_FILE"
    # This targets the specific file collision you saw in your logs
    sudo dpkg -i --force-overwrite /var/cache/apt/archives/libnvidia-cfg*.deb 2>/dev/null | tee -a "$LOG_FILE"
    
    echo "3. Fixing broken APT dependencies..." | tee -a "$LOG_FILE"
    sudo apt-get --fix-broken install -y &>> "$LOG_FILE"
    
    echo "4. Total Purge of NVIDIA conflict fragments..." | tee -a "$LOG_FILE"
    sudo apt-get remove --purge -y '^nvidia-.*' '^libnvidia-.*' &>> "$LOG_FILE"
    sudo apt-get autoremove -y &>> "$LOG_FILE"

    echo "5. Installing Clean Driver via Ubuntu-Drivers..." | tee -a "$LOG_FILE"
    sudo apt-get update &>> "$LOG_FILE"
    sudo apt-get install -y ubuntu-drivers-common &>> "$LOG_FILE"
    sudo ubuntu-drivers autoinstall &>> "$LOG_FILE"
    
    echo "6. Checking Secure Boot..." | tee -a "$LOG_FILE"
    if command -v mokutil &> /dev/null; then
        SB=$(mokutil --sb-state)
        echo "   $SB"
        [[ "$SB" == *"enabled"* ]] && echo -e "${B_RED}⚠ WARNING: DISABLE SECURE BOOT IN BIOS OR DRIVERS WILL NOT LOAD.${NC}"
    fi

    echo -e "\n${B_GREEN}Repair Finished. A REBOOT IS MANDATORY NOW.${NC}"
    read -p "Reboot computer now? (y/n): " rb
    [[ "$rb" == "y" ]] && sudo reboot
}

# --- 🩺 SYSTEM HEALTH ---
system_doctor() {
    echo -e "${B_YELLOW}[ SYSTEM STATUS ]${NC}"
    if nvidia-smi &> /dev/null; then
        echo -e "  GPU Driver:  ${B_GREEN}✓ ACTIVE${NC}"
    else
        echo -e "  GPU Driver:  ${B_RED}✗ BROKEN (Run Option 5)${NC}"
    fi
    [ -f "$BUILD_DIR/bin/llama-server" ] && echo -e "  AI Engine:   ${B_GREEN}✓ INSTALLED${NC}" || echo -e "  AI Engine:   ${B_RED}✗ NOT BUILT${NC}"
    M_COUNT=$(ls "$MODEL_DIR"/*.gguf 2>/dev/null | wc -l)
    echo -e "  Models:      ${B_CYAN}$M_COUNT FOUND${NC}"
    echo -e "------------------------------------------------------"
}

# --- 🏗️ BUILD ENGINE ---
build_engine() {
    draw_header
    echo -e "${B_CYAN}Updating Build Tools...${NC}"
    sudo apt-get --fix-broken install -y &>/dev/null
    sudo apt-get install -y build-essential git curl cmake libcurl4-openssl-dev libssl-dev
    
    mkdir -p "$HOME/ai_stack"
    [ ! -d "$INSTALL_DIR" ] && git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR" || (cd "$INSTALL_DIR" && git pull)

    cd "$INSTALL_DIR" || exit
    rm -rf build && mkdir build && cd build
    
    # Auto-detect GPU architecture
    ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d '.' | grep -E '^[0-9]+$' | head -n 1)
    [ -z "$ARCH" ] && ARCH="all-major"
    
    echo -e "${B_GREEN}Building for Architecture: sm_$ARCH${NC}"
    cmake .. -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=$ARCH -DGGML_CURL=ON -DGGML_SERVER_SSL=ON
    cmake --build . --config Release -j$(nproc)
    read -p "Build complete. Press Enter..."
}

# --- 📥 MODEL BROWSER ---
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

# --- 💬 TERMINAL CHAT ---
chat_mode() {
    draw_header
    models=("$MODEL_DIR"/*.gguf)
    [[ ! -e "${models[0]}" ]] && { echo -e "${B_RED}No models found!${NC}"; sleep 2; return; }
    
    echo "Select a model to talk to:"
    select m in "${models[@]}"; do [ -n "$m" ] && break; done
    
    echo -e "${B_GREEN}Starting Interactive Chat... (Type /quit to exit)${NC}"
    "$BUILD_DIR/bin/llama-cli" -m "$m" -cnv --prio 2
}

# --- 🌐 HTTPS WEB SERVER ---
manage_server() {
    draw_header
    if [ -f "$SERVER_PID_FILE" ] && ps -p $(cat "$SERVER_PID_FILE") > /dev/null; then
        PID=$(cat "$SERVER_PID_FILE")
        read -p "Server is already RUNNING. Stop it? (y/n): " k
        [[ "$k" == "y" ]] && kill $PID && rm "$SERVER_PID_FILE" && echo "Server stopped."
        return
    fi

    models=("$MODEL_DIR"/*.gguf)
    [[ ! -e "${models[0]}" ]] && { echo -e "${B_RED}No models found!${NC}"; sleep 2; return; }

    echo "Select model for Web Server:"
    select m in "${models[@]}"; do [ -n "$m" ] && break; done

    [ ! -f "$INSTALL_DIR/server.crt" ] && openssl req -x509 -newkey rsa:2048 -keyout "$INSTALL_DIR/server.key" -out "$INSTALL_DIR/server.crt" -sha256 -days 365 -nodes -subj "/CN=llama.local" &> /dev/null

    KEY=$(openssl rand -hex 12)
    LOCAL_IP=$(hostname -I | awk '{print $1}')

    "$BUILD_DIR/bin/llama-server" -m "$m" --host 0.0.0.0 --port 8080 --ssl-key-file "$INSTALL_DIR/server.key" --ssl-cert-file "$INSTALL_DIR/server.crt" --api-key "$KEY" > "$INSTALL_DIR/server.log" 2>&1 &
    
    echo $! > "$SERVER_PID_FILE"
    echo -e "\n${B_GREEN}🚀 SERVER IS LIVE!${NC}"
    echo -e "Local Address:   ${B_CYAN}https://localhost:8080${NC}"
    echo -e "Network Address: ${B_CYAN}https://$LOCAL_IP:8080${NC}"
    echo -e "Access Key:      ${B_CYAN}$KEY${NC}"
    echo -e "\n(Browser will show security warning; click 'Advanced' -> 'Proceed')${NC}"
    read -p "Press Enter to return to menu..."
}

# --- MAIN LOOP ---
while true; do
    draw_header
    system_doctor
    echo -e "1) ${B_CYAN}Build AI Engine${NC}"
    echo -e "2) ${B_CYAN}Download Models${NC} (Restored)"
    echo -e "3) ${B_GREEN}Interactive Chat${NC} (Restored)"
    echo -e "4) ${B_GREEN}Start Web Server${NC} (HTTPS)"
    echo -e "5) ${B_RED}DEEP REPAIR (Sledgehammer Mode)${NC}"
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
