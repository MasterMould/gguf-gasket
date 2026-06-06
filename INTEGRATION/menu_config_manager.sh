#!/bin/bash
# lib/menu_config_manager.sh — llama.cpp .ini Config Manager
# Menu module — auto-discovered by llama_manager.sh
#
# Drop this file (and the lib/config_manager/ directory beside it) into the
# gguf-gasket lib/ directory.  No changes to llama_manager.sh are needed.
#
# Requires: globals.sh  (MODEL_DIR, LOG_FILE, OK, ERR, WARN, STEP, PAUSE,
#                        ask, draw_header, B_CYAN, B_GREEN, B_YELLOW, B_RED, NC)
# ─────────────────────────────────────────────────────────────────────────────

# ── Module metadata (read by llama_manager.sh auto-discovery) ─────────────────
MENU_LABEL="Config Manager  (INI editor · model browser)"
MENU_FN="cm_menu"
MENU_COLOR='${B_CYAN}'
MENU_ORDER=45

# ── Module-local paths — captured at source time so they survive cd changes ───
_CM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CM_DIR="${_CM_LIB_DIR}/config_manager"
_CM_BIN="${_CM_DIR}/llamacpp-config-mgr"
_CM_SRC="${_CM_DIR}/main.go"
_CM_MOD="${_CM_DIR}/go.mod"
_CM_PID_FILE="/tmp/llama_config_manager.pid"
_CM_SETTINGS="${HOME}/ai_stack/config_manager.env"

# ── Module settings (persisted separately from gasket's settings.env) ─────────
declare -g cm_port=7070
declare -g cm_config_dir="${HOME}/ai_stack/llama_configs"

# ── Settings I/O ─────────────────────────────────────────────────────────────
_cm_save_settings() {
    mkdir -p "$(dirname "$_CM_SETTINGS")"
    {
        echo "cm_port=${cm_port}"
        echo "cm_config_dir=${cm_config_dir}"
    } > "$_CM_SETTINGS" || WARN "Could not write $_CM_SETTINGS"
}

_cm_load_settings() {
    [[ -f "$_CM_SETTINGS" ]] || return 0
    # shellcheck source=/dev/null
    source "$_CM_SETTINGS" || true
}

# Load on source
_cm_load_settings

# ── Go toolchain helpers ──────────────────────────────────────────────────────
_cm_go_ok() {
    command -v go &>/dev/null || return 1
    local ver major minor
    ver=$(go version | grep -oE '[0-9]+\.[0-9]+' | head -1)
    major=$(cut -d. -f1 <<< "$ver")
    minor=$(cut -d. -f2 <<< "$ver")
    [[ "$major" -gt 1 ]] && return 0
    [[ "$major" -eq 1 && "$minor" -ge 22 ]]
}

_cm_install_go() {
    STEP "Attempting Go ≥1.22 installation via apt…"
    sudo apt-get update -qq &>>"$LOG_FILE" || true
    for pkg in golang-1.23-go golang-1.22-go golang-go; do
        if apt-cache show "$pkg" &>/dev/null 2>&1; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" \
                &>>"$LOG_FILE" && break
        fi
    done
    # Versioned installs land in /usr/lib/go-1.XX/bin
    for d in /usr/lib/go-1.*/bin; do
        [[ -x "$d/go" ]] && export PATH="$d:$PATH"
    done
    # Snap fallback
    if ! _cm_go_ok && command -v snap &>/dev/null; then
        STEP "Trying snap install go --classic…"
        sudo snap install go --classic &>>"$LOG_FILE" && \
            export PATH="/snap/bin:$PATH"
    fi
    _cm_go_ok
}

# ── Binary build ──────────────────────────────────────────────────────────────
_cm_build() {
    draw_header
    echo -e "${B_CYAN}[ ⚙  BUILD CONFIG MANAGER ]${NC}"
    echo ""

    if [[ ! -f "$_CM_SRC" || ! -f "$_CM_MOD" ]]; then
        ERR "Source not found: $_CM_DIR"
        ERR "Ensure lib/config_manager/main.go and go.mod are present."
        PAUSE; return 1
    fi

    if ! _cm_go_ok; then
        WARN "Go ≥1.22 not found. Attempting auto-install (requires sudo)…"
        echo ""
        if ! sudo -v 2>/dev/null; then
            ERR "sudo unavailable — install Go manually: https://go.dev/doc/install"
            PAUSE; return 1
        fi
        if ! _cm_install_go; then
            ERR "Could not install Go. Install manually and retry."
            PAUSE; return 1
        fi
        echo ""
    fi

    local gv; gv=$(go version | grep -oE 'go[0-9]+\.[0-9.]+' | head -1)
    STEP "Building with $gv…"
    echo ""

    if (cd "$_CM_DIR" && go build -o "$(basename "$_CM_BIN")" . 2>&1 | tee -a "$LOG_FILE"); then
        echo ""
        OK "Binary built: ${_CM_BIN}"
    else
        echo ""
        ERR "Build failed — see output above or check $LOG_FILE"
        PAUSE; return 1
    fi
    PAUSE
}

# ── Server lifecycle ──────────────────────────────────────────────────────────
_cm_is_running() {
    [[ -f "$_CM_PID_FILE" ]] || return 1
    local pid; pid=$(cat "$_CM_PID_FILE" 2>/dev/null)
    [[ -n "$pid" ]] && ps -p "$pid" &>/dev/null
}

_cm_start() {
    if _cm_is_running; then
        local pid; pid=$(cat "$_CM_PID_FILE")
        WARN "Config manager already running (PID $pid) at http://localhost:${cm_port}"
        PAUSE; return 0
    fi

    if [[ ! -x "$_CM_BIN" ]]; then
        WARN "Binary not found — building now…"
        echo ""
        _cm_build || return 1
    fi

    mkdir -p "$cm_config_dir"

    # Pass MODEL_DIR so the Go binary's model scanner picks up gasket's model dir
    GASKET_MODEL_DIR="$MODEL_DIR" \
        "$_CM_BIN" "$cm_config_dir" "$cm_port" &>>"$LOG_FILE" &
    local pid=$!
    echo "$pid" > "$_CM_PID_FILE"

    # Brief readiness poll
    local i
    printf "  Starting"
    for i in {1..15}; do
        sleep 0.3
        if command -v curl &>/dev/null && \
           curl -sf "http://127.0.0.1:${cm_port}/api/files" &>/dev/null; then
            break
        fi
        printf "."
    done
    echo ""
    echo ""

    if _cm_is_running; then
        OK "Config manager running  →  http://localhost:${cm_port}"
        echo ""
        INFO "Configs stored in: $cm_config_dir"
        INFO "Models served from: $MODEL_DIR"
        echo ""
        # Open browser if available
        if command -v xdg-open &>/dev/null; then
            xdg-open "http://localhost:${cm_port}" &>/dev/null &
        elif command -v open &>/dev/null; then
            open "http://localhost:${cm_port}" &>/dev/null &
        fi
    else
        ERR "Server failed to start — check $LOG_FILE"
        rm -f "$_CM_PID_FILE"
        PAUSE; return 1
    fi
}

_cm_stop() {
    if ! _cm_is_running; then
        WARN "Config manager is not running."
        PAUSE; return 0
    fi
    local pid; pid=$(cat "$_CM_PID_FILE")
    kill "$pid" 2>/dev/null && OK "Stopped (PID $pid)." || WARN "Could not kill PID $pid"
    rm -f "$_CM_PID_FILE"
    sleep 0.5
    PAUSE
}

# ── Status line — called by llama_manager.sh main loop if function exists ─────
show_config_manager_status() {
    if _cm_is_running; then
        local pid; pid=$(cat "$_CM_PID_FILE")
        echo -e "  Config Mgr:    ${B_GREEN}✓ RUNNING (PID $pid) → http://localhost:${cm_port}${NC}"
    else
        echo -e "  Config Mgr:    ${B_RED}✗ STOPPED${NC}"
    fi
}

# ── Settings sub-menu ─────────────────────────────────────────────────────────
_cm_settings_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ ⚙  CONFIG MANAGER SETTINGS ]${NC}"
        echo ""
        echo -e "  Web UI port    : ${B_YELLOW}${cm_port}${NC}"
        echo -e "  Configs dir    : ${B_YELLOW}${cm_config_dir}${NC}"
        echo -e "  Models dir     : ${B_YELLOW}${MODEL_DIR}${NC}  (from gasket globals)"
        echo ""
        echo "  1) Change Web UI Port"
        echo "  2) Change Configs Directory"
        echo "  3) Back"
        echo ""
        read -p "Select [1-3]: " s
        case $s in
            1)
                read -p "  Port (1024–65535) [${cm_port}]: " np
                if [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1024 && np <= 65535 )); then
                    declare -g cm_port="$np"
                    _cm_save_settings
                    OK "Port set to $cm_port"
                    sleep 1
                else
                    WARN "Invalid port. Unchanged."
                    sleep 1
                fi ;;
            2)
                read -p "  Config directory [${cm_config_dir}]: " nd
                nd="${nd/#\~/$HOME}"
                if [[ -n "$nd" ]]; then
                    declare -g cm_config_dir="$nd"
                    _cm_save_settings
                    OK "Config dir set to $cm_config_dir"
                    sleep 1
                fi ;;
            3) return ;;
            *) WARN "Invalid option."; sleep 1 ;;
        esac
    done
}

# ── Main entry point (called by llama_manager.sh when user picks this item) ───
cm_menu() {
    _cm_load_settings

    while true; do
        draw_header
        echo -e "${B_CYAN}[ 📁  LLAMA.CPP CONFIG MANAGER ]${NC}"
        echo ""

        # Status
        if _cm_is_running; then
            local pid; pid=$(cat "$_CM_PID_FILE")
            echo -e "  Status  : ${B_GREEN}✓ RUNNING — PID $pid — http://localhost:${cm_port}${NC}"
        else
            echo -e "  Status  : ${B_RED}✗ STOPPED${NC}"
        fi

        local bin_status
        if [[ -x "$_CM_BIN" ]]; then
            local sz; sz=$(du -sh "$_CM_BIN" 2>/dev/null | cut -f1)
            bin_status="${B_GREEN}✓ built (${sz})${NC}"
        else
            bin_status="${B_YELLOW}✗ not built${NC}"
        fi
        echo -e "  Binary  : ${bin_status}"

        local cfg_count=0
        [[ -d "$cm_config_dir" ]] && \
            cfg_count=$(find "$cm_config_dir" -maxdepth 1 -name "*.ini" 2>/dev/null | wc -l)
        local mdl_count=0
        [[ -d "$MODEL_DIR" ]] && \
            mdl_count=$(find "$MODEL_DIR" -maxdepth 6 -name "*.gguf" 2>/dev/null | wc -l)

        echo -e "  Configs : ${B_CYAN}${cfg_count} .ini files in ${cm_config_dir}${NC}"
        echo -e "  Models  : ${B_CYAN}${mdl_count} .gguf files in ${MODEL_DIR}${NC}"
        echo ""
        echo "------------------------------------------------------"
        echo ""

        if _cm_is_running; then
            echo "  1) Open in browser     http://localhost:${cm_port}"
            echo "  2) Stop server"
        else
            echo "  1) Start web UI"
            echo "  2) (server not running)"
        fi
        echo "  3) (Re)build binary"
        echo "  4) Settings  (port, directories)"
        echo "  5) Back to main menu"
        echo ""
        read -p "Select [1-5]: " ch

        case $ch in
            1)
                if _cm_is_running; then
                    if command -v xdg-open &>/dev/null; then
                        xdg-open "http://localhost:${cm_port}" &>/dev/null &
                        OK "Opened http://localhost:${cm_port}"
                        sleep 1
                    elif command -v open &>/dev/null; then
                        open "http://localhost:${cm_port}" &>/dev/null &
                    else
                        INFO "Visit: http://localhost:${cm_port}"
                        PAUSE
                    fi
                else
                    _cm_start
                fi ;;
            2)
                if _cm_is_running; then
                    _cm_stop
                else
                    WARN "Server is not running."
                    sleep 1
                fi ;;
            3) _cm_build ;;
            4) _cm_settings_menu ;;
            5) return ;;
            *) WARN "Invalid option."; sleep 1 ;;
        esac
    done
}
