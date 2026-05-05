#!/bin/bash
# ============================================================
#  lib/menu_YOURMODULE.sh — LLAMA COMMAND CENTER module
#  Replace YOURMODULE with a short lowercase identifier.
# ============================================================
#
#  HOW THIS FILE IS LOADED
#  ───────────────────────
#  llama_manager.sh globs lib/menu_*.sh at startup, sources
#  each file, reads the four MENU_* variables below, then
#  builds the interactive menu automatically.
#
#  No changes to llama_manager.sh or any other file are needed.
#  Just drop this file in lib/ and restart the manager.
#
#  NAMING RULES
#  ────────────
#  • Filename  : lib/menu_<identifier>.sh  (lowercase, no spaces)
#  • Functions : prefix every function with _<identifier>_
#                to avoid clashing with other modules.
#                The single entry-point function is the exception
#                and should be named <identifier>_menu.
#  • Variables : use local inside functions wherever possible.
#                Module-level globals must be prefixed too:
#                  MYMOD_SOME_VAR="value"
# ============================================================

# ── REQUIRED METADATA ─────────────────────────────────────────
# All four variables must be set. The loader skips files that
# are missing MENU_LABEL or MENU_FN.

MENU_LABEL="My Feature Name"        # Shown in the main menu
MENU_FN="mymodule_menu"             # Entry-point function name
MENU_COLOR='${B_CYAN}'              # One of: ${B_CYAN} ${B_GREEN} ${B_YELLOW} ${B_RED}
MENU_ORDER=55                       # Integer — lower appears higher in the menu
                                    # Reserved ranges (leave gaps for your own):
                                    #   10  Build
                                    #   20  Download
                                    #   30  Chat
                                    #   40  Server
                                    #   45  memU
                                    #   50  Settings
                                    #   60  Repair
                                    #   70  Updates
                                    #   80+ free for new modules

# ── AVAILABLE GLOBALS (from lib/globals.sh) ───────────────────
# Read-only — do not reassign these outside save_settings().
#
#   INSTALL_DIR     $HOME/ai_stack/llama.cpp
#   BUILD_DIR       $INSTALL_DIR/build
#   MODEL_DIR       $HOME/ai_stack/models
#   LOG_FILE        $HOME/llama_forensics.log
#   SERVER_PID_FILE /tmp/llama_server.pid
#   KEY_FILE        $HOME/llama_api_keys.log
#   SERVER_INFO_FILE /tmp/llama_server.info
#   SETTINGS_FILE   $HOME/ai_stack/settings.env
#   DL_DIR          $HOME/ai_stack/.downloads
#   context_size    (user-set, integer)
#   visible2network (user-set, IP string)
#   network_port    (user-set, string)
#   api_key_mode    (user-set, string)
#
# ── AVAILABLE FUNCTIONS (from core modules) ───────────────────
#   draw_header      — clears screen and prints the banner
#   load_settings    — re-reads SETTINGS_FILE into globals
#   save_settings    — writes current globals to SETTINGS_FILE
#   rotate_log       — trims LOG_FILE to 500 lines
#   detect_gpu       — prints: NVIDIA | AMD | INTEL | CPU
#   check_deps       — verifies/installs build dependencies
#   OK  "msg"        — green  ✔  message
#   ERR "msg"        — red    ✖  message (to stderr)
#   WARN "msg"       — yellow ⚠  message
#   INFO "msg"       — plain indented message
#   STEP "msg"       — cyan   ──  section header
#   ask "question"   — y/n prompt, returns 0 for yes
#   PAUSE            — "Press Enter to continue…" prompt
#   select_model     — interactive model picker, echoes path
#   prompt_gpu_layers gpu — interactive GPU layer picker, echoes int
#
# ── COLOUR CONSTANTS (from lib/globals.sh) ────────────────────
#   B_RED  B_GREEN  B_YELLOW  B_CYAN  NC  CLEAR

# ============================================================
#  MODULE-LEVEL CONSTANTS
#  Define any paths, filenames, or fixed values your module
#  needs here. Prefix everything with your module identifier.
# ============================================================

MYMOD_DATA_DIR="$HOME/ai_stack/mymodule"      # example data dir
MYMOD_CONFIG_FILE="$MYMOD_DATA_DIR/config"    # example config file


# ============================================================
#  PRIVATE HELPERS
#  Internal functions that implement logic but are not called
#  directly from the menu. Prefix with _mymodule_.
# ============================================================

# Example: display a status summary at the top of the menu
_mymodule_status() {
    echo -e "  ${B_CYAN}Status:${NC}"
    # Replace with real status logic
    if [[ -f "$MYMOD_CONFIG_FILE" ]]; then
        echo -e "    Config   : ${B_GREEN}found${NC} ($MYMOD_CONFIG_FILE)"
    else
        echo -e "    Config   : ${B_YELLOW}not configured${NC}"
    fi
}

# Example: a sub-action with its own draw/prompt/confirm cycle
_mymodule_do_thing() {
    draw_header
    echo -e "${B_CYAN}[ My Feature — Do Thing ]${NC}"
    echo ""
    echo "  Explain what this action does in plain English."
    echo "  List any side-effects, requirements, or warnings here."
    echo ""

    # Pattern: confirm before any destructive or slow action
    read -r -p "  Proceed? (y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && { WARN "Cancelled."; sleep 1; return; }

    # --- actual work goes here ---
    mkdir -p "$MYMOD_DATA_DIR"
    echo "configured=yes" > "$MYMOD_CONFIG_FILE"

    # Pattern: log everything significant
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] mymodule: did_thing" >> "$LOG_FILE"

    OK "Done."
    sleep 2
}

# Example: a sub-action that persists a user setting
_mymodule_configure() {
    draw_header
    echo -e "${B_CYAN}[ My Feature — Configure ]${NC}"
    echo ""
    echo "  1) Option A"
    echo "  2) Option B"
    echo "  3) Back"
    local choice=""
    read -r -p "  Select [1-3]: " choice

    case $choice in
        1) echo "mode=a" >> "$MYMOD_CONFIG_FILE"; OK "Option A set." ;;
        2) echo "mode=b" >> "$MYMOD_CONFIG_FILE"; OK "Option B set." ;;
        3) return ;;
        *) WARN "Invalid selection." ;;
    esac
    sleep 1
}

# Example: a sub-action that calls a system binary
_mymodule_show_info() {
    draw_header
    echo -e "${B_CYAN}[ My Feature — Information ]${NC}"
    echo ""
    # Pattern: guard before calling any binary that may not be installed
    if ! command -v some_binary &>/dev/null; then
        WARN "some_binary not found. Install it with: sudo apt-get install some-package"
        read -p "Press Enter to return..."
        return
    fi
    some_binary --info 2>&1 | head -20
    echo ""
    read -p "Press Enter to return..."
}

# Example: a cleanup/reset action
_mymodule_reset() {
    draw_header
    echo -e "${B_CYAN}[ My Feature — Reset ]${NC}"
    echo ""
    WARN "This will delete $MYMOD_DATA_DIR and all module data."
    read -r -p "  Type 'yes' to confirm: " conf
    [[ "$conf" != "yes" ]] && { echo "Cancelled."; sleep 1; return; }

    rm -rf "$MYMOD_DATA_DIR"
    OK "Reset complete."
    sleep 2
}


# ============================================================
#  ENTRY POINT — must match MENU_FN above
#  This is the only public function. It is called by the main
#  menu when the user selects this module.
# ============================================================
mymodule_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ ⚙  My Feature Name ]${NC}"
        echo ""

        # Show live status at the top of every menu refresh
        _mymodule_status
        echo ""

        echo -e "------------------------------------------------------"
        echo -e "  1) ${B_GREEN}Do Thing${NC}"
        echo -e "  2) ${B_CYAN}Configure${NC}"
        echo -e "  3) ${B_CYAN}Show Info${NC}"
        echo -e "  4) ${B_RED}Reset${NC}"
        echo -e "  5) Back"
        echo ""
        local choice=""
        read -r -p "  Action: " choice

        case $choice in
            1) _mymodule_do_thing ;;
            2) _mymodule_configure ;;
            3) _mymodule_show_info ;;
            4) _mymodule_reset ;;
            5) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}
