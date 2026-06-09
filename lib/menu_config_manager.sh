#!/bin/bash
# lib/menu_config_manager.sh — llama.cpp .ini Config Manager
# Auto-discovered by llama_manager.sh
# ─────────────────────────────────────────────────────────────────────────────
MENU_LABEL="Config Manager  (INI editor · model browser · server)"
MENU_FN="cm_menu"
MENU_COLOR='${B_CYAN}'
MENU_ORDER=45

_CM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CM_DIR="${_CM_LIB_DIR}/config_manager"
_CM_BIN="${_CM_DIR}/llamacpp-config-mgr"
_CM_SRC="${_CM_DIR}/main.go"
_CM_MOD="${_CM_DIR}/go.mod"
_CM_PID_FILE="/tmp/llama_config_manager.pid"
_CM_SETTINGS="${HOME}/ai_stack/config_manager.env"

# Source integration libraries if available
[[ -f "${_CM_LIB_DIR}/shared_state.sh" ]] && source "${_CM_LIB_DIR}/shared_state.sh"
[[ -f "${_CM_LIB_DIR}/arc_check.sh"    ]] && source "${_CM_LIB_DIR}/arc_check.sh"

# Module settings
declare -g cm_port=7070
declare -g cm_config_dir="${HOME}/ai_stack/llama_configs"

# ── Settings ──────────────────────────────────────────────────────────────────
_cm_save_settings() {
    mkdir -p "$(dirname "$_CM_SETTINGS")"
    { echo "cm_port=${cm_port}"; echo "cm_config_dir=${cm_config_dir}"; } > "$_CM_SETTINGS"
}
_cm_load_settings() { [[ -f "$_CM_SETTINGS" ]] && source "$_CM_SETTINGS" || true; }
_cm_load_settings

# ── Go toolchain ──────────────────────────────────────────────────────────────
_cm_go_ok() {
    command -v go &>/dev/null || return 1
    local v m n
    v=$(go version | grep -oE '[0-9]+\.[0-9]+' | head -1)
    m=$(cut -d. -f1 <<< "$v"); n=$(cut -d. -f2 <<< "$v")
    [[ "$m" -gt 1 ]] || [[ "$m" -eq 1 && "$n" -ge 22 ]]
}

_cm_install_go() {
    STEP "Installing Go ≥1.22 via apt…"
    sudo apt-get update -qq &>>"$LOG_FILE" || true
    for pkg in golang-1.23-go golang-1.22-go golang-go; do
        apt-cache show "$pkg" &>/dev/null 2>&1 || continue
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" &>>"$LOG_FILE" && break
    done
    for d in /usr/lib/go-1.*/bin; do [[ -x "$d/go" ]] && export PATH="$d:$PATH"; done
    if ! _cm_go_ok && command -v snap &>/dev/null; then
        sudo snap install go --classic &>>"$LOG_FILE" && export PATH="/snap/bin:$PATH"
    fi
    _cm_go_ok
}

# ── Binary build ──────────────────────────────────────────────────────────────
_cm_build() {
    draw_header
    echo -e "${B_CYAN}[ ⚙  BUILD CONFIG MANAGER ]${NC}"
    echo ""

    # Warn if Arc GPU has issues before building
    if arc_detect &>/dev/null 2>&1 && ! arc_all_ok 2>/dev/null; then
        echo -e "  ${B_YELLOW}⚠ Arc GPU issues detected — run Arc Fix before using SYCL backend${NC}"
        echo ""
    fi

    [[ ! -f "$_CM_SRC" || ! -f "$_CM_MOD" ]] && {
        ERR "Source missing: $_CM_DIR"; PAUSE; return 1; }

    _cm_go_ok || { _cm_install_go || { ERR "Could not install Go"; PAUSE; return 1; }; }

    local gv; gv=$(go version | grep -oE 'go[0-9]+\.[0-9.]+' | head -1)
    STEP "go build  ($gv)…"; echo ""

    if (cd "$_CM_DIR" && go build -o "$(basename "$_CM_BIN")" . 2>&1 | tee -a "$LOG_FILE"); then
        echo ""; OK "Binary: ${_CM_BIN}"
    else
        echo ""; ERR "Build failed — check $LOG_FILE"; PAUSE; return 1
    fi
    PAUSE
}

# ── Config manager web server ─────────────────────────────────────────────────
_cm_is_running() {
    [[ -f "$_CM_PID_FILE" ]] || return 1
    local p; p=$(cat "$_CM_PID_FILE" 2>/dev/null)
    [[ -n "$p" ]] && ps -p "$p" &>/dev/null
}

_cm_start() {
    _cm_is_running && {
        WARN "Config manager already running at http://localhost:${cm_port}"; PAUSE; return 0; }
    [[ ! -x "$_CM_BIN" ]] && { WARN "Binary missing — building…"; echo ""; _cm_build || return 1; }
    mkdir -p "$cm_config_dir"

    # Pass gasket's shared state as environment variables to the Go binary
    GASKET_MODEL_DIR="${STATE_MODEL:+$(dirname "$STATE_MODEL")}${MODEL_DIR:+:${MODEL_DIR}}" \
    GASKET_SERVER_PID_FILE="$GASKET_SERVER_PID" \
    GASKET_STATE_FILE="$GASKET_STATE_FILE" \
        "$_CM_BIN" "$cm_config_dir" "$cm_port" &>>"$LOG_FILE" &
    echo "$!" > "$_CM_PID_FILE"

    printf "  Starting"
    local i; for i in {1..15}; do
        sleep 0.3
        command -v curl &>/dev/null && \
            curl -sf "http://127.0.0.1:${cm_port}/api/files" &>/dev/null && break
        printf "."
    done; echo ""

    _cm_is_running && {
        echo ""; OK "Config manager  →  http://localhost:${cm_port}"
        INFO "Configs : $cm_config_dir"
        INFO "Models  : ${MODEL_DIR}"
        INFO "State   : $GASKET_STATE_FILE"
        command -v xdg-open &>/dev/null && xdg-open "http://localhost:${cm_port}" &>/dev/null &
        return 0
    }
    ERR "Server failed to start — check $LOG_FILE"; rm -f "$_CM_PID_FILE"; PAUSE; return 1
}

_cm_stop() {
    _cm_is_running || { WARN "Config manager is not running."; PAUSE; return 0; }
    local p; p=$(cat "$_CM_PID_FILE")
    kill "$p" 2>/dev/null && OK "Stopped (PID $p)." || WARN "Could not kill PID $p"
    rm -f "$_CM_PID_FILE"; sleep 0.5; PAUSE
}

# ── llama-server launch using STATE_CONFIG + STATE_MODEL ─────────────────────
_cm_launch_server() {
    draw_header
    echo -e "${B_CYAN}[ ▶  LAUNCH LLAMA-SERVER ]${NC}"
    echo ""
    state_load 2>/dev/null || true

    # Resolve binary
    local bin="$STATE_BINARY"
    if [[ -z "$bin" || ! -x "$bin" ]]; then
        # Search gasket's BUILD_DIR first
        for candidate in \
            "${BUILD_DIR:-}/bin/llama-server" \
            "${BUILD_DIR:-}/llama-server" \
            "${HOME}/ai_stack/llama.cpp/build/bin/llama-server" \
            "/home/first/ai_stack/llama.cpp/build/bin/llama-server"; do
            [[ -x "$candidate" ]] && { bin="$candidate"; break; }
        done
    fi

    if [[ -z "$bin" || ! -x "$bin" ]]; then
        ERR "No llama-server binary found."
        INFO "Use 'Select binary' in manager.sh or set STATE_BINARY in selected.env"
        PAUSE; return 1
    fi

    # Resolve model
    local model="$STATE_MODEL"
    if [[ -z "$model" || ! -f "$model" ]]; then
        ERR "No model selected."
        INFO "Select a model via the Models tab in the web UI, or from manager.sh"
        PAUSE; return 1
    fi

    # Stop existing server if running
    if server_is_running 2>/dev/null; then
        WARN "Stopping existing server (PID $(server_pid))…"
        server_stop
        sleep 0.5
    fi

    # Build argument list from .ini config (if selected)
    local -a args=("--model" "$model")

    if [[ -n "$STATE_CONFIG" && -f "$STATE_CONFIG" ]]; then
        INFO "Applying config: ${STATE_CONFIG##*/}"
        while IFS='=' read -r key val; do
            key="${key%%#*}"; key="${key## }"; key="${key%% }"
            val="${val%%#*}"; val="${val## }"; val="${val%% }"
            [[ -z "$key" || "$key" == \[* || "$key" == "model" ]] && continue
            if [[ "${val,,}" == "true" || "$val" == "1" ]]; then
                args+=("--${key}")
            elif [[ "${val,,}" != "false" && "$val" != "0" && -n "$val" ]]; then
                args+=("--${key}" "$val")
            fi
        done < <(grep -v '^\s*[;#\[]' "$STATE_CONFIG" | grep '=')
    fi

    echo ""
    echo -e "  ${B_CYAN}Binary :${NC}  ${bin##*/}"
    echo -e "  ${B_CYAN}Model  :${NC}  ${model##*/}"
    echo -e "  ${B_CYAN}Config :${NC}  ${STATE_CONFIG:+${STATE_CONFIG##*/}}"
    echo -e "  ${B_CYAN}Args   :${NC}  ${args[*]}"
    echo ""
    read -p "  Launch? [y/N] " yn
    [[ "${yn,,}" != y ]] && return 0

    echo ""
    STEP "Starting ${bin##*/}…"
    nohup "$bin" "${args[@]}" >> "$GASKET_SERVER_LOG" 2>&1 &
    local pid=$!
    server_write_pid "$pid" 2>/dev/null || echo "$pid" > "$GASKET_SERVER_PID"
    sleep 1

    if ps -p "$pid" &>/dev/null; then
        OK "Server started (PID $pid)"
        INFO "Log : $GASKET_SERVER_LOG"
        INFO "URL : http://localhost:${STATE_PORT:-8080}"
    else
        ERR "Server exited immediately — check $GASKET_SERVER_LOG"
    fi
    PAUSE
}

# ── Status hook ───────────────────────────────────────────────────────────────
show_config_manager_status() {
    _cm_is_running && \
        echo -e "  Config Mgr: ${B_GREEN}✓ RUNNING → http://localhost:${cm_port}${NC}" || \
        echo -e "  Config Mgr: ${B_RED}✗ STOPPED${NC}"
    server_is_running 2>/dev/null && \
        echo -e "  llama-svr:  ${B_GREEN}✓ RUNNING (PID $(server_pid))${NC}" || \
        echo -e "  llama-svr:  ${B_RED}✗ STOPPED${NC}"
}

# ── Settings sub-menu ─────────────────────────────────────────────────────────
_cm_settings_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ ⚙  CONFIG MANAGER SETTINGS ]${NC}"; echo ""
        echo -e "  Web UI port    : ${B_YELLOW}${cm_port}${NC}"
        echo -e "  Configs dir    : ${B_YELLOW}${cm_config_dir}${NC}"
        echo -e "  Models dir     : ${B_YELLOW}${MODEL_DIR:-not set}${NC}  (gasket MODEL_DIR)"
        state_load 2>/dev/null || true
        echo -e "  Active model   : ${B_YELLOW}${STATE_MODEL:-none}${NC}"
        echo -e "  Active config  : ${B_YELLOW}${STATE_CONFIG:-none}${NC}"
        echo ""
        echo "  1) Change port            4) Clear active model"
        echo "  2) Change configs dir     5) Clear active config"
        echo "  3) Back"
        echo ""
        read -p "Select [1-5]: " s
        case $s in
            1)  read -p "  Port [${cm_port}]: " np
                [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1024 )) && (( np <= 65535 )) && \
                    { declare -g cm_port="$np"; _cm_save_settings; OK "Port → $cm_port"; } || \
                    WARN "Invalid"; sleep 1 ;;
            2)  read -p "  Directory [${cm_config_dir}]: " nd
                nd="${nd/#\~/$HOME}"
                [[ -n "$nd" ]] && { declare -g cm_config_dir="$nd"; _cm_save_settings
                    OK "Dir → $cm_config_dir"; sleep 1; } ;;
            4)  state_set_model ""; OK "Model cleared"; sleep 1 ;;
            5)  state_set_config ""; OK "Config cleared"; sleep 1 ;;
            3)  return ;;
            *)  WARN "Invalid."; sleep 1 ;;
        esac
    done
}

# ── Main menu ─────────────────────────────────────────────────────────────────
cm_menu() {
    _cm_load_settings
    while true; do
        draw_header
        echo -e "${B_CYAN}[ 📁  CONFIG MANAGER ]${NC}"; echo ""

        # Status panel
        _cm_is_running && \
            echo -e "  Web UI  : ${B_GREEN}✓ http://localhost:${cm_port}${NC}" || \
            echo -e "  Web UI  : ${B_RED}✗ STOPPED${NC}"

        server_is_running 2>/dev/null && \
            echo -e "  Server  : ${B_GREEN}✓ RUNNING  PID $(server_pid)${NC}" || \
            echo -e "  Server  : ${B_RED}✗ STOPPED${NC}"

        # Arc status (one line)
        arc_detect &>/dev/null 2>&1 && \
            echo -e "  GPU     : $(arc_status_line)" || \
            echo -e "  GPU     : ${B_RED}Arc not detected${NC}"

        state_load 2>/dev/null || true
        local mname="${STATE_MODEL:+${STATE_MODEL##*/}}"; mname="${mname:-none}"
        local cname="${STATE_CONFIG:+${STATE_CONFIG##*/}}"; cname="${cname:-none}"
        echo -e "  Model   : ${B_YELLOW}${mname}${NC}"
        echo -e "  Config  : ${B_YELLOW}${cname}${NC}"

        local cfg_n=0 mdl_n=0
        [[ -d "$cm_config_dir" ]] && cfg_n=$(find "$cm_config_dir" -maxdepth 1 -name "*.ini" 2>/dev/null | wc -l)
        [[ -d "${MODEL_DIR}" ]]   && mdl_n=$(find "$MODEL_DIR" -maxdepth 6 -name "*.gguf" 2>/dev/null | wc -l)
        echo -e "  Configs : ${cfg_n} files    Models: ${mdl_n} .gguf"

        echo ""; echo "  ──────────────────────────────────────────────────"; echo ""

        if _cm_is_running; then
            echo "  1) Open web UI          http://localhost:${cm_port}"
            echo "  2) Stop web UI"
        else
            echo "  1) Start web UI"
            echo "  2) (not running)"
        fi
        echo "  3) Launch llama-server  (model + config → server)"
        echo "  4) Stop llama-server"
        echo "  5) (Re)build binary"
        echo "  6) Settings"
        echo "  7) Back"
        echo ""
        read -p "Select [1-7]: " ch

        case $ch in
            1)  if _cm_is_running; then
                    if command -v xdg-open &>/dev/null; then
                        xdg-open "http://localhost:${cm_port}" &>/dev/null &
                    else
                        INFO "Visit: http://localhost:${cm_port}"
                    fi
                else
                    _cm_start
                fi ;;
            2)  _cm_is_running && _cm_stop || { WARN "Not running"; sleep 1; } ;;
            3)  _cm_launch_server ;;
            4)  server_is_running 2>/dev/null && { server_stop; OK "Server stopped."; sleep 1; } || \
                { WARN "Server not running."; sleep 1; } ;;
            5)  _cm_build ;;
            6)  _cm_settings_menu ;;
            7)  return ;;
            *)  WARN "Invalid."; sleep 1 ;;
        esac
    done
}
