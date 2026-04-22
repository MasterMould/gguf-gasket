#!/usr/bin/env bash
set -uo pipefail

# ================================================================
#  STYLING
# ================================================================
B_RED='\033[1;31m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_CYAN='\033[1;36m'
NC='\033[0m'
CLEAR='\033[2J\033[H'

Y="$B_YELLOW"
N="$NC"

OK()   { echo -e "${B_GREEN}  ✔  $*${NC}"; }
ERR()  { echo -e "${B_RED}  ✖  $*${NC}" >&2; }
INFO() { echo -e "      $*"; }
WARN() { echo -e "${B_YELLOW}  ⚠  $*${NC}"; }
STEP() { echo -e "${B_CYAN}  ──  $*${NC}"; }

# ================================================================
#  PATHS / FILES
# ================================================================
INSTALL_DIR="$HOME/ai_stack/llama.cpp"
BUILD_DIR="$INSTALL_DIR/build"
MODEL_DIR="$HOME/ai_stack/models"
LOG_FILE="$HOME/llama_forensics.log"

SERVER_PID_FILE="/tmp/llama_server.pid"
SERVER_INFO_FILE="/tmp/llama_server.info"
KEY_FILE="$HOME/llama_api_keys.log"

SETTINGS_FILE="$HOME/ai_stack/settings.env"
LAST_MODEL_FILE="$HOME/.llama_last_model"

# ================================================================
#  CONFIG DEFAULTS
# ================================================================
context_size=8192
visible2network="127.0.0.1"
network_port="8080"
EPHEMERAL_KEYS=0

# ================================================================
#  CORE UTILITIES
# ================================================================
run_or_fail() {
    "$@" || { ERR "Command failed: $*"; return 1; }
}

APT_UPDATED=0
ensure_apt_updated() {
    if [[ $APT_UPDATED -eq 0 ]]; then
        sudo apt-get update -qq || true
        APT_UPDATED=1
    fi
}

rotate_log() {
    [[ -f "$LOG_FILE" ]] || return
    local lines
    lines=$(wc -l < "$LOG_FILE" || echo 0)
    (( lines > 500 )) && tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

draw_header() {
    echo -e "${CLEAR}${B_CYAN}============================================="
    echo -e "        🦙 LLAMA COMMAND CENTER 🦙"
    echo -e "=============================================${NC}"
}

# ================================================================
#  SETTINGS
# ================================================================
save_settings() {
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    cat > "$SETTINGS_FILE" <<EOF
context_size=$context_size
visible2network=$visible2network
network_port=$network_port
EPHEMERAL_KEYS=$EPHEMERAL_KEYS
EOF
}

load_settings() {
    [[ -f "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE"
}

load_settings

# ================================================================
#  GPU DETECTION (IMPROVED)
# ================================================================
detect_gpu() {
    local gpu
    gpu=$(lspci -nn | grep -Ei 'vga|3d|display' || true)

    if echo "$gpu" | grep -iq nvidia; then
        echo "NVIDIA"
    elif echo "$gpu" | grep -iq amd; then
        echo "AMD"
    elif echo "$gpu" | grep -iq intel; then
        echo "INTEL"
    else
        echo "CPU"
    fi
}

# ================================================================
#  MODEL SELECTION (FIXED GLOBBING + MEMORY)
# ================================================================
select_model() {
    shopt -s nullglob
    local models=("$MODEL_DIR"/*.gguf)
    shopt -u nullglob

    [[ ${#models[@]} -eq 0 ]] && {
        ERR "No models found."
        sleep 2
        return 1
    }

    if [[ -f "$LAST_MODEL_FILE" ]]; then
        read -p "Use last model? (y/n): " use_last
        if [[ "$use_last" == "y" ]]; then
            cat "$LAST_MODEL_FILE"
            return 0
        fi
    fi

    PS3="Select model: "
    select m in "${models[@]}" "Cancel"; do
        [[ "$m" == "Cancel" ]] && return 1
        [[ -n "$m" ]] && {
            echo "$m" > "$LAST_MODEL_FILE"
            echo "$m"
            return 0
        }
    done
}

# ================================================================
#  SERVER HEALTH CHECK
# ================================================================
check_port_open() {
    ss -tuln | grep -q ":$network_port"
}

# ================================================================
#  SERVER MANAGEMENT (IMPROVED)
# ================================================================
manage_server() {
    draw_header
    load_settings

    if [[ -f "$SERVER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$SERVER_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            OK "Server running (PID $pid)"
            read -p "Stop it? (y/n): " s
            [[ "$s" == "y" ]] && kill "$pid" && rm -f "$SERVER_PID_FILE" "$SERVER_INFO_FILE"
            return
        fi
    fi

    local model
    model=$(select_model) || return

    local api_key
    api_key=$(openssl rand -hex 12)

    "$BUILD_DIR/bin/llama-server" \
        -m "$model" \
        --ctx-size "$context_size" \
        --host "$visible2network" \
        --port "$network_port" \
        --api-key "$api_key" \
        > "$INSTALL_DIR/server.log" 2>&1 &

    local pid=$!
    echo "$pid" > "$SERVER_PID_FILE"

    sleep 2

    if check_port_open; then
        OK "Server is listening on port $network_port"
    else
        WARN "Server may not have started correctly"
    fi

    if [[ $EPHEMERAL_KEYS -eq 0 ]]; then
        echo "[$(date)] PID=$pid KEY=${api_key:0:4}****" >> "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi

    echo "URL: http://$visible2network:$network_port"
    echo "KEY: $api_key"

    read -p "Press Enter..."
}

# ================================================================
#  BUILD ENGINE (SAFE EXEC)
# ================================================================
build_engine() {
    draw_header

    ensure_apt_updated

    run_or_fail sudo apt-get install -y \
        build-essential cmake git curl \
        libssl-dev libcurl4-openssl-dev \
        ocl-icd-libopencl1 &>> "$LOG_FILE" || return

    mkdir -p "$HOME/ai_stack"

    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        run_or_fail git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR" || return
    else
        (cd "$INSTALL_DIR" && git pull) || true
    fi

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR" || return

    cmake .. -DGGML_CURL=ON &>> "$LOG_FILE" || return
    cmake --build . -j"$(nproc)" &>> "$LOG_FILE" || return

    OK "Build complete"
    read -p "Enter to continue"
}

# ================================================================
#  CHAT MODE
# ================================================================
chat_mode() {
    draw_header

    local model
    model=$(select_model) || return

    "$BUILD_DIR/bin/llama-cli" \
        -m "$model" \
        -c "$context_size" \
        -cnv
}

# ================================================================
#  SETTINGS MENU
# ================================================================
settings_menu() {
    while true; do
        draw_header
        echo "1) Context ($context_size)"
        echo "2) Port ($network_port)"
        echo "3) Toggle Ephemeral Keys ($EPHEMERAL_KEYS)"
        echo "4) Back"
        read -p "Choice: " s

        case $s in
            1) read -p "New context: " context_size ;;
            2) read -p "New port: " network_port ;;
            3) EPHEMERAL_KEYS=$((1-EPHEMERAL_KEYS)) ;;
            4) save_settings; return ;;
        esac
    done
}

# ================================================================
#  MAIN LOOP
# ================================================================
while true; do
    draw_header

    echo "GPU: $(detect_gpu)"
    echo "Context: $context_size"
    echo "Port: $network_port"

    echo "1) Build"
    echo "2) Chat"
    echo "3) Server"
    echo "4) Settings"
    echo "5) Exit"

    read -p "Action: " c

    case $c in
        1) build_engine ;;
        2) chat_mode ;;
        3) manage_server ;;
        4) settings_menu ;;
        5) exit 0 ;;
    esac
done
