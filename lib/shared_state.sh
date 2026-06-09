#!/bin/bash
# lib/shared_state.sh — runtime state bus for gguf-gasket toolchain
#
# Sourced by: llama_manager.sh, menu_config_manager.sh, menu_arc_fix.sh,
#             menu_server.sh, manager.sh
#
# Provides a single ~/ai_stack/selected.env that every tool reads and writes,
# so a model/config selected in one tool is immediately visible in all others.
# ─────────────────────────────────────────────────────────────────────────────

GASKET_STATE_DIR="${HOME}/ai_stack"
GASKET_STATE_FILE="${GASKET_STATE_DIR}/selected.env"
GASKET_SERVER_PID="${GASKET_STATE_DIR}/server.pid"
GASKET_SERVER_LOG="${GASKET_STATE_DIR}/server.log"
GASKET_ARC_STATUS="${GASKET_STATE_DIR}/arc_status.env"

# In-memory mirrors — populated by state_load
declare -g STATE_MODEL=""      # absolute path to selected .gguf
declare -g STATE_CONFIG=""     # absolute path to selected .ini
declare -g STATE_BINARY=""     # absolute path to llama-server / llama-cli
declare -g STATE_PORT="8080"   # server port (mirrors network_port in settings.env)

# ── I/O ───────────────────────────────────────────────────────────────────────

state_load() {
    [[ -f "$GASKET_STATE_FILE" ]] || return 0
    local key val
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            STATE_MODEL)   STATE_MODEL="$val"  ;;
            STATE_CONFIG)  STATE_CONFIG="$val" ;;
            STATE_BINARY)  STATE_BINARY="$val" ;;
            STATE_PORT)    STATE_PORT="$val"   ;;
        esac
    done < "$GASKET_STATE_FILE"
}

state_save() {
    mkdir -p "$GASKET_STATE_DIR"
    cat > "$GASKET_STATE_FILE" << STATEEOF
# gguf-gasket runtime state — written by shared_state.sh
# Modified: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
STATE_MODEL=${STATE_MODEL}
STATE_CONFIG=${STATE_CONFIG}
STATE_BINARY=${STATE_BINARY}
STATE_PORT=${STATE_PORT}
STATEEOF
}

state_set_model()  { STATE_MODEL="$1";  state_save; }
state_set_config() { STATE_CONFIG="$1"; state_save; }
state_set_binary() { STATE_BINARY="$1"; state_save; }
state_set_port()   { STATE_PORT="$1";   state_save; }
state_clear()      { STATE_MODEL=""; STATE_CONFIG=""; STATE_BINARY=""; state_save; }

# ── Server PID helpers ────────────────────────────────────────────────────────

server_is_running() {
    [[ -f "$GASKET_SERVER_PID" ]] || return 1
    local pid; pid=$(cat "$GASKET_SERVER_PID" 2>/dev/null)
    [[ -n "$pid" ]] && ps -p "$pid" &>/dev/null
}

server_pid() {
    [[ -f "$GASKET_SERVER_PID" ]] && cat "$GASKET_SERVER_PID" 2>/dev/null || echo ""
}

server_stop() {
    local pid; pid=$(server_pid)
    [[ -z "$pid" ]] && return 0
    kill "$pid" 2>/dev/null
    rm -f "$GASKET_SERVER_PID"
    sleep 0.5
}

server_write_pid() { echo "$1" > "$GASKET_SERVER_PID"; }

# ── Status summary (used in main menu header strips) ─────────────────────────

state_summary() {
    state_load
    local model_name="none" config_name="none" binary_name="none"
    [[ -n "$STATE_MODEL"  ]] && model_name="${STATE_MODEL##*/}"
    [[ -n "$STATE_CONFIG" ]] && config_name="${STATE_CONFIG##*/}"
    [[ -n "$STATE_BINARY" ]] && binary_name="${STATE_BINARY##*/}"

    echo "  Selected model  : ${model_name}"
    echo "  Selected config : ${config_name}"
    echo "  llama binary    : ${binary_name}"
    echo "  Server port     : ${STATE_PORT}"

    if server_is_running; then
        echo "  Server status   : RUNNING  (PID $(server_pid))"
    else
        echo "  Server status   : STOPPED"
    fi
}

# Load on source
state_load
