#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  llama.cpp Config Manager — Setup & Launcher
#  Usage: ./manager.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colours & symbols ─────────────────────────────────────────────────────────
R='\033[0;31m'   # red
G='\033[0;32m'   # green
Y='\033[1;33m'   # yellow
B='\033[0;34m'   # blue
C='\033[0;36m'   # cyan
M='\033[0;35m'   # magenta
W='\033[1;37m'   # bold white
D='\033[0;90m'   # dark grey
N='\033[0m'      # reset
BOLD='\033[1m'

TICK="${G}✔${N}"
CROSS="${R}✘${N}"
WARN="${Y}!${N}"
ARROW="${C}▶${N}"

# ── Script location (so relative paths always work) ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="llamacpp-manager"
BINARY_PATH="$SCRIPT_DIR/$BINARY_NAME"
SOURCE_PATH="$SCRIPT_DIR/main.go"
MOD_PATH="$SCRIPT_DIR/go.mod"
DEFAULT_CONFIG_DIR="$SCRIPT_DIR/configs"
DEFAULT_PORT=7070
MIN_GO_MAJOR=1
MIN_GO_MINOR=22

# State
SELECTED_CONFIG_DIR="$DEFAULT_CONFIG_DIR"
SELECTED_PORT="$DEFAULT_PORT"

# ── Utilities ─────────────────────────────────────────────────────────────────
clear_screen()  { clear; }
press_enter()   { echo; echo -e "${D}Press Enter to continue...${N}"; read -r; }
print_sep()     { echo -e "${D}$(printf '─%.0s' {1..60})${N}"; }

header() {
    clear_screen
    echo
    echo -e "  ${C}${BOLD}🦙  llama.cpp Config Manager${N}"
    echo -e "  ${D}Setup & Launcher${N}"
    echo
    print_sep
    echo
}

# Print a status row:  [✔/✘/!]  label  value/note
status_row() {
    local icon="$1" label="$2" note="${3:-}"
    printf "  %-2s  %-26s %s\n" "$icon" "$label" "$note"
}

# ── Dependency checks ─────────────────────────────────────────────────────────

# Returns 0 if Go is installed and meets the minimum version, else 1.
check_go() {
    if ! command -v go &>/dev/null; then return 1; fi
    local ver; ver=$(go version | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    [[ "$major" -gt "$MIN_GO_MAJOR" ]] && return 0
    [[ "$major" -eq "$MIN_GO_MAJOR" && "$minor" -ge "$MIN_GO_MINOR" ]] && return 0
    return 1
}

# Returns 0 if the pre-built binary exists and is executable.
check_binary() {
    [[ -x "$BINARY_PATH" ]]
}

# Returns 0 if source files exist.
check_source() {
    [[ -f "$SOURCE_PATH" && -f "$MOD_PATH" ]]
}

# Check for optional but useful tools.
check_optional() {
    local name="$1"
    command -v "$name" &>/dev/null
}

# Collect overall dependency status into globals.
assess_deps() {
    DEP_GO=false;      check_go              && DEP_GO=true
    DEP_BINARY=false;  check_binary          && DEP_BINARY=true
    DEP_SOURCE=false;  check_source          && DEP_SOURCE=true
    DEP_CURL=false;    check_optional curl   && DEP_CURL=true
    DEP_XDGO=false;    check_optional xdg-open && DEP_XDGO=true
    DEP_OPEN=false;    check_optional open   && DEP_OPEN=true  # macOS

    # Can we run the app?
    if $DEP_BINARY; then
        CAN_RUN=true
    elif $DEP_GO && $DEP_SOURCE; then
        CAN_RUN=true   # will build first
    else
        CAN_RUN=false
    fi
}

# ── Dependency report screen ──────────────────────────────────────────────────
show_deps() {
    header
    echo -e "  ${W}${BOLD}Dependency Check${N}"
    echo
    assess_deps

    # ── Required ──
    echo -e "  ${D}Required${N}"
    echo

    # Binary
    if $DEP_BINARY; then
        local bsize; bsize=$(du -sh "$BINARY_PATH" 2>/dev/null | cut -f1)
        status_row "$TICK" "Pre-built binary" "${G}found${N} ${D}(${bsize})${N}"
    else
        status_row "$CROSS" "Pre-built binary" "${D}not found at $BINARY_NAME${N}"
    fi

    # Go toolchain
    if $DEP_GO; then
        local gver; gver=$(go version | grep -oE 'go[0-9]+\.[0-9.]+' | head -1)
        status_row "$TICK" "Go toolchain" "${G}${gver}${N}"
    else
        if command -v go &>/dev/null; then
            local gver; gver=$(go version | grep -oE 'go[0-9]+\.[0-9.]+' | head -1)
            status_row "$WARN" "Go toolchain" "${Y}${gver} — need ≥${MIN_GO_MAJOR}.${MIN_GO_MINOR}${N}"
        else
            status_row "$CROSS" "Go toolchain" "${D}not installed${N}"
        fi
    fi

    # Source files
    if $DEP_SOURCE; then
        status_row "$TICK" "Source files" "${G}main.go + go.mod${N}"
    else
        status_row "$CROSS" "Source files" "${D}main.go / go.mod missing${N}"
    fi

    echo
    echo -e "  ${D}Optional${N}"
    echo

    if $DEP_CURL; then
        status_row "$TICK" "curl" "${D}health-check support enabled${N}"
    else
        status_row "$WARN" "curl" "${D}not found (health checks disabled)${N}"
    fi

    if $DEP_XDGO || $DEP_OPEN; then
        local opener; $DEP_XDGO && opener="xdg-open" || opener="open"
        status_row "$TICK" "Browser opener" "${D}${opener} available${N}"
    else
        status_row "$WARN" "xdg-open / open" "${D}browser won't auto-open${N}"
    fi

    echo
    print_sep
    echo

    if $CAN_RUN; then
        if ! $DEP_BINARY && $DEP_GO && $DEP_SOURCE; then
            echo -e "  ${WARN}  Binary not found — ${Y}will be built automatically when you start.${N}"
        else
            echo -e "  ${TICK}  All required dependencies met. Ready to run."
        fi
    else
        echo -e "  ${CROSS}  ${R}Cannot run:${N} need either the pre-built binary ${W}or${N} Go ≥${MIN_GO_MAJOR}.${MIN_GO_MINOR} + source files."
        echo
        echo -e "  ${D}To install Go:  https://go.dev/doc/install${N}"
        echo -e "  ${D}Ensure main.go and go.mod are in the same directory as this script.${N}"
    fi

    echo
    press_enter
}

# ── Build ─────────────────────────────────────────────────────────────────────
build_binary() {
    header
    echo -e "  ${W}${BOLD}Building binary…${N}"
    echo
    print_sep
    echo

    if ! $DEP_SOURCE; then
        echo -e "  ${CROSS} Source files not found. Cannot build."
        press_enter; return 1
    fi
    if ! $DEP_GO; then
        echo -e "  ${CROSS} Go toolchain not available or too old."
        press_enter; return 1
    fi

    echo -e "  ${ARROW} Running: ${C}go build -o ${BINARY_NAME} .${N}"
    echo

    if (cd "$SCRIPT_DIR" && go build -o "$BINARY_NAME" . 2>&1); then
        DEP_BINARY=true
        CAN_RUN=true
        echo
        echo -e "  ${TICK} ${G}${BOLD}Build successful!${N}  →  ${W}${BINARY_PATH}${N}"
    else
        echo
        echo -e "  ${CROSS} ${R}Build failed.${N} Check the errors above."
        press_enter; return 1
    fi

    press_enter
}

# ── Config directory picker ───────────────────────────────────────────────────
pick_config_dir() {
    header
    echo -e "  ${W}${BOLD}Select Config Directory${N}"
    echo
    echo -e "  Current: ${C}${SELECTED_CONFIG_DIR}${N}"
    echo

    # List candidate directories (script dir + subdirs containing *.ini files)
    declare -a CANDIDATES=()
    CANDIDATES+=("$DEFAULT_CONFIG_DIR")

    # Add any dirs found under script dir that contain .ini files (depth 2)
    while IFS= read -r d; do
        [[ "$d" != "$DEFAULT_CONFIG_DIR" ]] && CANDIDATES+=("$d")
    done < <(find "$SCRIPT_DIR" -maxdepth 2 -name "*.ini" -printf '%h\n' 2>/dev/null | sort -u)

    # Deduplicate
    declare -a UNIQUE=()
    declare -A SEEN=()
    for c in "${CANDIDATES[@]}"; do
        [[ -z "${SEEN[$c]+x}" ]] && { UNIQUE+=("$c"); SEEN[$c]=1; }
    done

    echo -e "  ${D}Known locations:${N}"
    echo
    local i=1
    for d in "${UNIQUE[@]}"; do
        local count=0
        [[ -d "$d" ]] && count=$(find "$d" -maxdepth 1 -name "*.ini" 2>/dev/null | wc -l)
        local note
        if [[ "$d" == "$SELECTED_CONFIG_DIR" ]]; then
            note="${G}← current${N}"
        elif [[ -d "$d" ]]; then
            note="${D}${count} .ini file(s)${N}"
        else
            note="${D}(will be created)${N}"
        fi
        echo -e "  ${W}[$i]${N}  $d  $note"
        (( i++ ))
    done

    echo
    echo -e "  ${W}[c]${N}  Enter a custom path"
    echo -e "  ${W}[b]${N}  Back"
    echo
    print_sep
    echo
    read -rp "  Choice: " choice

    case "$choice" in
        [bB]) return ;;
        [cC])
            echo
            read -rp "  Enter path: " custom
            custom="${custom/#\~/$HOME}"   # expand ~
            if [[ -n "$custom" ]]; then
                SELECTED_CONFIG_DIR="$custom"
                echo -e "  ${TICK} Set to: ${C}${SELECTED_CONFIG_DIR}${N}"
                sleep 0.6
            fi
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#UNIQUE[@]} )); then
                SELECTED_CONFIG_DIR="${UNIQUE[$((choice-1))]}"
                echo -e "  ${TICK} Set to: ${C}${SELECTED_CONFIG_DIR}${N}"
                sleep 0.6
            else
                echo -e "  ${WARN} Invalid choice."
                sleep 0.8
            fi
            ;;
    esac
}

# ── Port picker ───────────────────────────────────────────────────────────────
pick_port() {
    header
    echo -e "  ${W}${BOLD}Select Port${N}"
    echo
    echo -e "  Current port: ${C}${SELECTED_PORT}${N}"
    echo

    echo -e "  ${W}[1]${N}  7070  ${D}(default)${N}"
    echo -e "  ${W}[2]${N}  8080"
    echo -e "  ${W}[3]${N}  9090"
    echo -e "  ${W}[c]${N}  Custom port"
    echo -e "  ${W}[b]${N}  Back"
    echo
    print_sep
    echo
    read -rp "  Choice: " choice

    case "$choice" in
        1) SELECTED_PORT=7070 ;;
        2) SELECTED_PORT=8080 ;;
        3) SELECTED_PORT=9090 ;;
        [cC])
            echo
            read -rp "  Enter port (1024–65535): " p
            if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1024 && p <= 65535 )); then
                SELECTED_PORT="$p"
            else
                echo -e "  ${WARN} Invalid port. Keeping ${SELECTED_PORT}."
                sleep 0.8
            fi
            ;;
        [bB]) return ;;
        *) echo -e "  ${WARN} Invalid choice."; sleep 0.8 ;;
    esac
    echo -e "  ${TICK} Port set to ${C}${SELECTED_PORT}${N}"
    sleep 0.6
}

# ── Check if port is free ─────────────────────────────────────────────────────
port_in_use() {
    local port="$1"
    # Try ss, then netstat, then /dev/tcp
    if command -v ss &>/dev/null; then
        ss -tlnH "sport = :${port}" 2>/dev/null | grep -q ":${port}" && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    else
        (echo >/dev/tcp/127.0.0.1/"$port") &>/dev/null && return 0
    fi
    return 1
}

# ── Health check (optional, needs curl) ──────────────────────────────────────
wait_for_ready() {
    local port="$1" attempts=12 i
    if ! $DEP_CURL; then sleep 1; return 0; fi
    for (( i=1; i<=attempts; i++ )); do
        if curl -sf "http://127.0.0.1:${port}/api/files" &>/dev/null; then
            return 0
        fi
        sleep 0.3
    done
    return 1
}

# ── Open browser ──────────────────────────────────────────────────────────────
open_browser() {
    local url="$1"
    if $DEP_XDGO; then
        xdg-open "$url" &>/dev/null &
    elif $DEP_OPEN; then
        open "$url" &>/dev/null &
    fi
}

# ── Start application ─────────────────────────────────────────────────────────
start_app() {
    header
    echo -e "  ${W}${BOLD}Start Application${N}"
    echo
    assess_deps

    # Build first if no binary
    if ! $DEP_BINARY; then
        if $DEP_GO && $DEP_SOURCE; then
            echo -e "  ${WARN} Binary not found — building now…"
            echo
            if ! (cd "$SCRIPT_DIR" && go build -o "$BINARY_NAME" . 2>&1); then
                echo
                echo -e "  ${CROSS} ${R}Build failed.${N}"
                press_enter; return
            fi
            DEP_BINARY=true
            echo -e "  ${TICK} Build OK"
            echo
        else
            echo -e "  ${CROSS} ${R}Cannot run:${N} no binary and no Go toolchain/source."
            press_enter; return
        fi
    fi

    # Port check
    if port_in_use "$SELECTED_PORT"; then
        echo -e "  ${WARN} ${Y}Port ${SELECTED_PORT} is already in use.${N}"
        echo
        echo -e "     A previous instance may still be running."
        echo -e "     Change the port in the main menu, or kill the existing process:"
        echo -e "     ${D}kill \$(lsof -ti tcp:${SELECTED_PORT}) 2>/dev/null${N}"
        echo
        press_enter; return
    fi

    # Ensure config dir exists
    mkdir -p "$SELECTED_CONFIG_DIR"

    echo -e "  ${D}Config dir  :${N}  ${C}${SELECTED_CONFIG_DIR}${N}"
    echo -e "  ${D}Port        :${N}  ${C}${SELECTED_PORT}${N}"
    echo -e "  ${D}URL         :${N}  ${C}http://localhost:${SELECTED_PORT}${N}"
    echo
    print_sep
    echo

    # Launch
    echo -e "  ${ARROW} Starting ${W}${BINARY_NAME}${N}…"
    echo
    "$BINARY_PATH" "$SELECTED_CONFIG_DIR" "$SELECTED_PORT" &
    APP_PID=$!
    echo -e "  ${D}PID: ${APP_PID}${N}"
    echo

    # Wait for the server to accept connections
    echo -n "  Waiting for server"
    if wait_for_ready "$SELECTED_PORT"; then
        echo -e "  ${TICK} ${G}Server is ready!${N}"
    else
        echo
        echo -e "  ${WARN} Server may still be starting — check manually."
    fi

    echo
    echo -e "  ${W}Open in browser:${N}  ${B}http://localhost:${SELECTED_PORT}${N}"
    echo

    # Attempt to open browser
    if $DEP_XDGO || $DEP_OPEN; then
        echo -e "  ${ARROW} Opening browser…"
        open_browser "http://localhost:${SELECTED_PORT}"
    fi

    print_sep
    echo
    echo -e "  Press ${W}[q]${N} to stop the server and return to the menu,"
    echo -e "  or ${W}[b]${N} to return while keeping it running in the background."
    echo
    read -rp "  Choice [q/b]: " stopchoice

    case "${stopchoice,,}" in
        q|quit|stop)
            echo
            echo -e "  ${ARROW} Stopping server (PID ${APP_PID})…"
            kill "$APP_PID" 2>/dev/null && echo -e "  ${TICK} Server stopped." || echo -e "  ${WARN} Process already gone."
            sleep 0.5
            ;;
        *)
            echo -e "  ${TICK} Server running in background (PID ${APP_PID})."
            sleep 0.8
            ;;
    esac
}

# ── Stop any running instance ─────────────────────────────────────────────────
stop_app() {
    header
    echo -e "  ${W}${BOLD}Stop Running Instance${N}"
    echo

    # Find PIDs of our binary
    local pids
    pids=$(pgrep -f "$BINARY_NAME" 2>/dev/null || true)

    if [[ -z "$pids" ]]; then
        echo -e "  ${D}No running instance of ${BINARY_NAME} found.${N}"
        press_enter; return
    fi

    echo -e "  Found process(es):  ${W}${pids}${N}"
    echo
    read -rp "  Kill them? [y/N] " yn
    if [[ "${yn,,}" == y ]]; then
        echo "$pids" | xargs kill 2>/dev/null && echo -e "  ${TICK} Stopped." || echo -e "  ${WARN} Could not stop all processes."
    else
        echo -e "  ${D}Aborted.${N}"
    fi

    press_enter
}

# ── About ─────────────────────────────────────────────────────────────────────
show_about() {
    header
    echo -e "  ${W}${BOLD}About${N}"
    echo
    echo -e "  llama.cpp Config Manager — a web-based CRUD editor"
    echo -e "  for llama.cpp ${C}.ini${N} configuration files."
    echo
    echo -e "  ${D}Binary   :${N}  $BINARY_PATH"
    echo -e "  ${D}Source   :${N}  $SOURCE_PATH"
    echo -e "  ${D}Go mod   :${N}  $MOD_PATH"
    echo
    print_sep
    echo
    echo -e "  ${W}Keyboard shortcuts (in the web UI):${N}"
    echo
    echo -e "  ${C}Ctrl+S${N}     Save current file"
    echo -e "  ${C}Ctrl+N${N}     New file"
    echo -e "  ${C}Esc${N}        Close modal"
    echo
    print_sep
    echo
    echo -e "  ${W}REST API endpoints:${N}"
    echo
    echo -e "  ${D}GET   ${N} ${C}/api/files${N}          List all config files"
    echo -e "  ${D}GET   ${N} ${C}/api/files/{name}${N}   Read a config file"
    echo -e "  ${D}POST  ${N} ${C}/api/files${N}          Create a new file"
    echo -e "  ${D}PUT   ${N} ${C}/api/files/{name}${N}   Update a file"
    echo -e "  ${D}DELETE${N} ${C}/api/files/{name}${N}   Delete a file"
    echo
    press_enter
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        assess_deps

        header

        # Status strip
        if $DEP_BINARY; then
            echo -e "  ${TICK} Binary      ${G}ready${N}"
        elif $DEP_GO && $DEP_SOURCE; then
            echo -e "  ${WARN} Binary      ${Y}will build on start${N}"
        else
            echo -e "  ${CROSS} Binary      ${R}unavailable${N}"
        fi

        if port_in_use "$SELECTED_PORT"; then
            echo -e "  ${WARN} Port ${SELECTED_PORT}   ${Y}in use (instance may be running)${N}"
        else
            echo -e "  ${TICK} Port ${SELECTED_PORT}   ${D}free${N}"
        fi

        echo -e "  ${ARROW} Config dir  ${C}${SELECTED_CONFIG_DIR}${N}"
        echo
        print_sep
        echo

        echo -e "  ${W}${BOLD}Main Menu${N}"
        echo
        echo -e "  ${W}[1]${N}  ${G}${BOLD}▶  Start Application${N}"
        echo -e "  ${W}[2]${N}  ${C}⊞  Check Dependencies${N}"
        echo -e "  ${W}[3]${N}     Build Binary (from source)"
        echo -e "  ${W}[4]${N}     Select Config Directory"
        echo -e "  ${W}[5]${N}     Select Port"
        echo -e "  ${W}[6]${N}  ${R}■  Stop Running Instance${N}"
        echo -e "  ${W}[7]${N}     About"
        echo -e "  ${W}[q]${N}  ${D}Quit${N}"
        echo
        print_sep
        echo
        read -rp "  Choice: " choice
        echo

        case "${choice,,}" in
            1)   start_app ;;
            2)   show_deps ;;
            3)   build_binary ;;
            4)   pick_config_dir ;;
            5)   pick_port ;;
            6)   stop_app ;;
            7)   show_about ;;
            q|quit|exit) break ;;
            *)
                echo -e "  ${WARN} Invalid choice '${choice}'. Try 1-7 or q."
                sleep 0.8
                ;;
        esac
    done

    echo
    echo -e "  ${D}Goodbye.${N}"
    echo
}

# ── Entry point ───────────────────────────────────────────────────────────────
main_menu
