#!/bin/bash
# llama_manager.sh — LLAMA COMMAND CENTRE entry point
# Sources all lib/ modules then runs the main interactive loop.
#
# Module layout:
#   lib/globals.sh       — vars, settings, logging helpers, draw_header
#   lib/detect.sh        — detect_gpu, check_deps
#   lib/drivers_gpu.sh   — install_Nvidia_gpu_drivers, install_AMD_gpu_drivers
#   lib/drivers_intel.sh — install_intel_gpu_drivers (full Intel Arc / oneAPI stack)
#   lib/build.sh         — build_engine, install_to_path
#   lib/settings.sh      — settings_menu and all select_* functions
#   lib/chat.sh          — select_model, prompt_gpu_layers, chat_mode
#   lib/server.sh        — manage_server
#   lib/download.sh      — download_menu, spawn_download, background workers
#   lib/repair.sh        — deep_repair
#   lib/updates.sh       — check_for_updates

set -uo pipefail

# ── Resolve the directory this script lives in so lib/ paths are absolute ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# ── Source all modules in dependency order ─────────────────────────────────
for _mod in \
    globals.sh \
    detect.sh \
    drivers_gpu.sh \
    drivers_intel.sh \
    build.sh \
    settings.sh \
    chat.sh \
    server.sh \
    download.sh \
    repair.sh \
    updates.sh
do
    _mod_path="$LIB_DIR/$_mod"
    if [[ ! -f "$_mod_path" ]]; then
        echo "ERROR: Required module not found: $_mod_path" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$_mod_path"
done
unset _mod _mod_path

# ── Load persisted settings ────────────────────────────────────────────────
load_settings

# ── Start log rotation ─────────────────────────────────────────────────────
rotate_log

# ================================================================
#  MAIN LOOP
# ================================================================
while true; do
    draw_header
    CUR_GPU=$(detect_gpu)

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

    # Show active download summary if any in-progress
    show_download_status

    echo -e "------------------------------------------------------"
    echo -e "1) ${B_CYAN}Build AI Engine${NC}     (Auto-Detect: $CUR_GPU)"
    echo -e "2) ${B_CYAN}Download Models${NC}     (Includes Custom URL option)"
    echo -e "3) ${B_GREEN}Interactive Chat${NC}"
    echo -e "4) ${B_GREEN}Start / Stop Web Server${NC}"
    echo -e "5) ${B_YELLOW}⚙  Settings${NC}          (Context, Port, Network, API Key)"
    echo -e "6) ${B_RED}DEEP REPAIR${NC}         (Fix Drivers/Conflicts)"
    echo -e "7) 🔄 Check for Script Updates"
    echo -e "8) View Forensic Logs"
    echo -e "9) View Saved API Keys"
    echo -e "0) Exit"
    read -p "Action: " choice

    case $choice in
        1) build_engine ;;
        2) download_menu ;;
        3) chat_mode ;;
        4) manage_server ;;
        5) settings_menu ;;
        6) deep_repair ;;
        7) check_for_updates ;;
        8)
            draw_header
            echo -e "${B_CYAN}--- Last 50 lines of $LOG_FILE ---${NC}"
            tail -n 50 "$LOG_FILE" 2>/dev/null || echo "(Log file is empty or missing)"
            read -p "Press Enter to return..."
            ;;
        9)
            draw_header
            echo -e "${B_CYAN}--- Saved API Keys ($KEY_FILE) ---${NC}"
            cat "$KEY_FILE" 2>/dev/null || echo "(No keys saved yet)"
            read -p "Press Enter to return..."
            ;;
        0) echo -e "${B_CYAN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
