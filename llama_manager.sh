#!/bin/bash
# llama_manager.sh — LLAMA COMMAND CENTER entry point
#
# ARCHITECTURE
# ─────────────────────────────────────────────────────────────────
# Core modules (sourced unconditionally, provide shared functions):
#   lib/globals.sh        — vars, paths, save/load settings, helpers
#   lib/detect.sh         — detect_gpu, check_deps
#   lib/drivers_gpu.sh    — NVIDIA and AMD installers
#   lib/drivers_intel.sh  — Intel Arc / oneAPI full installer
#
# Menu modules (auto-discovered — any lib/menu_*.sh is loaded):
#   Each must declare at the top of the file:
#     MENU_LABEL="Human-readable label"
#     MENU_FN="function_to_call"
#     MENU_COLOR='${B_CYAN}'   (colour variable as a string, expanded at print time)
#     MENU_ORDER=10            (integer; lower = higher in the menu)
#
#   To add a new feature, drop a lib/menu_myfeature.sh with those
#   four variables declared and one or more bash functions defined.
#   No changes to this file are needed.
# ─────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# ── 1. Source core infrastructure modules (order matters) ─────────────────
for _core in globals.sh detect.sh drivers_gpu.sh drivers_intel.sh; do
    _p="$LIB_DIR/$_core"
    if [[ ! -f "$_p" ]]; then
        echo "ERROR: Core module not found: $_p" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$_p"
done
unset _core _p

# ── 2. Auto-discover and source all menu_*.sh modules ─────────────────────
# Each module sets MENU_LABEL / MENU_FN / MENU_COLOR / MENU_ORDER.
# We source the file, capture those four values, then clear them so the
# next module starts clean. Collected entries are stored in parallel arrays.

declare -a _MOD_LABELS=()
declare -a _MOD_FNS=()
declare -a _MOD_COLORS=()
declare -a _MOD_ORDERS=()

for _mod_file in "$LIB_DIR"/menu_*.sh; do
    [[ -f "$_mod_file" ]] || continue

    # Reset metadata vars before sourcing
    MENU_LABEL=""
    MENU_FN=""
    MENU_COLOR='${B_CYAN}'
    MENU_ORDER=99

    # shellcheck source=/dev/null
    source "$_mod_file"

    if [[ -z "$MENU_LABEL" || -z "$MENU_FN" ]]; then
        echo "WARNING: $_mod_file is missing MENU_LABEL or MENU_FN — skipped." >&2
        continue
    fi

    _MOD_LABELS+=("$MENU_LABEL")
    _MOD_FNS+=("$MENU_FN")
    _MOD_COLORS+=("$MENU_COLOR")
    _MOD_ORDERS+=("$MENU_ORDER")
done
unset _mod_file MENU_LABEL MENU_FN MENU_COLOR MENU_ORDER

# Sort modules by MENU_ORDER (insertion sort — N is always small)
_n=${#_MOD_LABELS[@]}
for (( _i=1; _i<_n; _i++ )); do
    _ko=${_MOD_ORDERS[$_i]}
    _kl=${_MOD_LABELS[$_i]}
    _kf=${_MOD_FNS[$_i]}
    _kc=${_MOD_COLORS[$_i]}
    _j=$(( _i - 1 ))
    while (( _j >= 0 && ${_MOD_ORDERS[$_j]} > _ko )); do
        _MOD_ORDERS[$(( _j+1 ))]=${_MOD_ORDERS[$_j]}
        _MOD_LABELS[$(( _j+1 ))]=${_MOD_LABELS[$_j]}
        _MOD_FNS[$(( _j+1 ))]=${_MOD_FNS[$_j]}
        _MOD_COLORS[$(( _j+1 ))]=${_MOD_COLORS[$_j]}
        (( _j-- ))
    done
    _MOD_ORDERS[$(( _j+1 ))]=$_ko
    _MOD_LABELS[$(( _j+1 ))]=$_kl
    _MOD_FNS[$(( _j+1 ))]=$_kf
    _MOD_COLORS[$(( _j+1 ))]=$_kc
done
unset _n _i _j _ko _kl _kf _kc

# ── 3. Boot ───────────────────────────────────────────────────────────────
load_settings
rotate_log

# ================================================================
#  MAIN LOOP
# ================================================================
while true; do
    draw_header
    CUR_GPU=$(detect_gpu)

    # ── Status panel ──────────────────────────────────────────────
    echo -e "${B_YELLOW}[ SYSTEM STATUS ]${NC}"
    echo -e "  Detected GPU:  ${B_CYAN}$CUR_GPU${NC}"
    echo -e "  Context size:  ${B_CYAN}$context_size tokens${NC}"
    echo -e "  Network bind:  ${B_CYAN}$visible2network:$network_port${NC}"

    if [[ -f "$BUILD_DIR/bin/llama-server" ]]; then
        echo -e "  AI Engine:     ${B_GREEN}✓ INSTALLED${NC}"
    else
        echo -e "  AI Engine:     ${B_RED}✗ NOT BUILT${NC}"
    fi

    if [[ -f "$SERVER_PID_FILE" ]]; then
        SRV_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$SRV_PID" ]] && ps -p "$SRV_PID" > /dev/null 2>&1; then
            echo -e "  Web Server:    ${B_GREEN}✓ RUNNING (PID $SRV_PID)${NC}"
            [[ -f "$SERVER_INFO_FILE" ]] && cat "$SERVER_INFO_FILE"
        else
            echo -e "  Web Server:    ${B_YELLOW}⚠ PID file stale — server not running${NC}"
            rm -f "$SERVER_PID_FILE" "$SERVER_INFO_FILE"
        fi
    else
        echo -e "  Web Server:    ${B_RED}✗ STOPPED${NC}"
    fi

    MODELS_COUNT=$(find "$MODEL_DIR" -name "*.gguf" 2>/dev/null | wc -l || echo 0)
    echo -e "  Models:        ${B_CYAN}$MODELS_COUNT downloaded${NC}"

    # show_download_status lives in menu_download.sh — call if loaded
    declare -f show_download_status &>/dev/null && show_download_status

    echo -e "------------------------------------------------------"

    # ── Dynamic menu from discovered modules ──────────────────────
    _mod_count=${#_MOD_LABELS[@]}
    for (( _idx=0; _idx<_mod_count; _idx++ )); do
        _num=$(( _idx + 1 ))
        _color_str="${_MOD_COLORS[$_idx]}"
        _label="${_MOD_LABELS[$_idx]}"
        # Expand the colour variable string (e.g. '${B_CYAN}') into ANSI sequence
        _color_val=$(eval "echo -e \"$_color_str\"")
        echo -e "${_num}) ${_color_val}${_label}${NC}"
    done
    unset _idx _num _color_str _label _color_val

    # ── Fixed utility items (always last) ─────────────────────────
    _log_num=$(( _mod_count + 1 ))
    _key_num=$(( _mod_count + 2 ))
    echo -e "${_log_num}) View Forensic Logs"
    echo -e "${_key_num}) View Saved API Keys"
    echo -e "0) Exit"
    echo ""
    read -p "Action: " choice

    # ── Route: dynamic module or fixed handler ─────────────────────
    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && \
       (( choice >= 1 && choice <= _mod_count )); then
        _fn="${_MOD_FNS[$(( choice - 1 ))]}"
        if declare -f "$_fn" &>/dev/null; then
            "$_fn"
        else
            ERR "Function '$_fn' not found — module may have failed to load."
            sleep 2
        fi
    elif [[ "$choice" == "$_log_num" ]]; then
        draw_header
        echo -e "${B_CYAN}--- Last 50 lines of $LOG_FILE ---${NC}"
        tail -n 50 "$LOG_FILE" 2>/dev/null || echo "(Log file is empty or missing)"
        read -p "Press Enter to return..."
    elif [[ "$choice" == "$_key_num" ]]; then
        draw_header
        echo -e "${B_CYAN}--- Saved API Keys ($KEY_FILE) ---${NC}"
        cat "$KEY_FILE" 2>/dev/null || echo "(No keys saved yet)"
        read -p "Press Enter to return..."
    elif [[ "$choice" == "0" ]]; then
        echo -e "${B_CYAN}Goodbye!${NC}"
        exit 0
    else
        echo -e "${B_RED}Invalid option.${NC}"
        sleep 1
    fi
done
