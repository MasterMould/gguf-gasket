#!/bin/bash
# lib/globals.sh — Shared variables, settings persistence, logging helpers
# Sourced by llama_manager.sh before all other modules.

# ── Styling ────────────────────────────────────────────────────────────────
B_RED='\033[1;31m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_CYAN='\033[1;36m'
NC='\033[0m'
CLEAR='\033[2J\033[H'
Y="$B_YELLOW"
N="$NC"

# ── Logging helpers ────────────────────────────────────────────────────────
OK()   { echo -e "${B_GREEN}  ✔  $*${NC}"; }
ERR()  { echo -e "${B_RED}  ✖  $*${NC}" >&2; }
INFO() { echo -e "      $*"; }
WARN() { echo -e "${B_YELLOW}  ⚠  $*${NC}"; }
STEP() { echo -e "${B_CYAN}  ──  $*${NC}"; }

# ── Paths ──────────────────────────────────────────────────────────────────
INSTALL_DIR="$HOME/ai_stack/llama.cpp"
BUILD_DIR="$INSTALL_DIR/build"
MODEL_DIR="$HOME/ai_stack/models"
LOG_FILE="$HOME/llama_forensics.log"
SERVER_PID_FILE="/tmp/llama_server.pid"
KEY_FILE="$HOME/llama_api_keys.log"
SERVER_INFO_FILE="/tmp/llama_server.info"
SETTINGS_FILE="$HOME/ai_stack/settings.env"
DL_DIR="$HOME/ai_stack/.downloads"

# ── Runtime config (overridable via Settings menu) ─────────────────────────
context_size=8192
visible2network="127.0.0.1"
network_port="8080"
api_key_mode="random"

# ── Settings persistence ───────────────────────────────────────────────────
save_settings() {
    mkdir -p "$(dirname "$SETTINGS_FILE")" || true
    {
        echo "context_size=$context_size"
        echo "visible2network=$visible2network"
        echo "network_port=$network_port"
        echo "api_key_mode=$api_key_mode"
    } > "$SETTINGS_FILE" || WARN "Could not write settings to $SETTINGS_FILE"
}

load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE" || true
}

# ── Log rotation (keep last 500 lines) ────────────────────────────────────
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

# ── Interactive helpers ────────────────────────────────────────────────────
ask() {
    local yn="[Y/n]"; [[ "${2:-y}" == "n" ]] && yn="[y/N]"
    read -rp "$(echo -e "${Y}  ❓  $1 $yn: ${N}")" r
    r="${r:-${2:-y}}"
    [[ "${r,,}" == "y" ]]
}

PAUSE() {
    read -rp "$(echo -e "${Y}  Press Enter to continue…${N}")"
}

draw_header() {
    echo -e "${CLEAR}${B_CYAN}======================================================"
    echo -e "           🦙 LLAMA COMMAND CENTER (v8.2) 🦙"
    echo -e "           * Universal GPU & Repair Mode *"
    echo -e "======================================================${NC}"
}
