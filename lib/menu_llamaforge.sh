#!/bin/bash
# ============================================================
#  lib/menu_llamaforge.sh — LLAMA COMMAND CENTER module
#  Accelerator-aware llama.cpp build and repair manager.
#
#  Drop this file into lib/ and restart llama_manager.sh.
#  No changes to llama_manager.sh are required.
# ============================================================

# ── REQUIRED METADATA ─────────────────────────────────────────
MENU_LABEL="llama.cpp Build Forge"
MENU_FN="llamaforge_menu"
MENU_COLOR='${B_GREEN}'
MENU_ORDER=15

# ── MODULE CONSTANTS ──────────────────────────────────────────
LLAMAFORGE_CONFIG_DIR="$HOME/ai_stack/llama-forge"
LLAMAFORGE_CONFIG_FILE="$LLAMAFORGE_CONFIG_DIR/config"
LLAMAFORGE_LOG_FILE="$LLAMAFORGE_CONFIG_DIR/module.log"

# Candidate Forge locations, in priority order.  A configured path wins.
LLAMAFORGE_CANDIDATES=(
    "$HOME/ai_stack/llama-build-forge/bin/llama-forge"
    "$HOME/ai_stack/llama-build-forge/llama-forge/bin/llama-forge"
    "$HOME/Downloads/llama-build-forge/bin/llama-forge"
    "$HOME/Downloads/llama-build-forge-v13/llama-build-forge/bin/llama-forge"
    "$HOME/Downloads/llama-build-forge-v12/llama-build-forge/bin/llama-forge"
    "$HOME/Downloads/llama-build-forge-v11/llama-build-forge/bin/llama-forge"
    "$HOME/Downloads/llama-build-forge-v10/llama-build-forge/bin/llama-forge"
)

# ── PRIVATE HELPERS ──────────────────────────────────────────
_llamaforge_load_config() {
    mkdir -p "$LLAMAFORGE_CONFIG_DIR"
    [[ -f "$LLAMAFORGE_CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$LLAMAFORGE_CONFIG_FILE" 2>/dev/null || true
}

_llamaforge_save_config() {
    mkdir -p "$LLAMAFORGE_CONFIG_DIR"
    printf 'LLAMAFORGE_BIN=%q\n' "${LLAMAFORGE_BIN:-}" > "$LLAMAFORGE_CONFIG_FILE"
}

_llamaforge_find_bin() {
    _llamaforge_load_config

    if [[ -n "${LLAMAFORGE_BIN:-}" && -x "$LLAMAFORGE_BIN" ]]; then
        printf '%s\n' "$LLAMAFORGE_BIN"
        return 0
    fi

    local candidate
    for candidate in "${LLAMAFORGE_CANDIDATES[@]}"; do
        if [[ -x "$candidate" ]]; then
            LLAMAFORGE_BIN="$candidate"
            _llamaforge_save_config
            printf '%s\n' "$LLAMAFORGE_BIN"
            return 0
        fi
    done

    # Allow a PATH-installed forge wrapper/script.
    if command -v llama-forge >/dev/null 2>&1; then
        LLAMAFORGE_BIN="$(command -v llama-forge)"
        _llamaforge_save_config
        printf '%s\n' "$LLAMAFORGE_BIN"
        return 0
    fi

    return 1
}

_llamaforge_log() {
    mkdir -p "$LLAMAFORGE_CONFIG_DIR"
    printf '[%s] llamaforge: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LLAMAFORGE_LOG_FILE"
}

_llamaforge_status() {
    echo -e "  ${B_CYAN}Status${NC}"
    local forge_bin=""
    if forge_bin="$(_llamaforge_find_bin)"; then
        echo -e "    Forge        : ${B_GREEN}available${NC}"
        echo -e "    Launcher     : $forge_bin"
    else
        echo -e "    Forge        : ${B_YELLOW}not found${NC}"
        echo "    Expected in ~/ai_stack/llama-build-forge or ~/Downloads/llama-build-forge."
    fi

    echo -e "    llama.cpp    : ${INSTALL_DIR:-not configured}"

    if [[ -f "${LLAMAFORGE_LOG_FILE}" ]]; then
        echo -e "    Module log   : ${LLAMAFORGE_LOG_FILE}"
    fi
}

_llamaforge_require_bin() {
    local forge_bin=""
    if forge_bin="$(_llamaforge_find_bin)"; then
        printf '%s\n' "$forge_bin"
        return 0
    fi

    WARN "llama.cpp Build Forge was not found."
    echo "  Place the Forge in: $HOME/ai_stack/llama-build-forge"
    echo "  Or use Configure Forge Path to select an installed launcher."
    PAUSE
    return 1
}

_llamaforge_run() {
    local forge_bin="$1"
    shift
    _llamaforge_log "run: $forge_bin $*"
    # Preserve the interactive terminal.  The Forge owns its own menu/progress UI.
    "$forge_bin" "$@"
    local rc=$?
    _llamaforge_log "exit=$rc"
    return "$rc"
}

_llamaforge_scan() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Hardware & backend scan ]${NC}"
    echo ""
    echo "  Scans the machine, identifies usable accelerators, and reports"
    echo "  which llama.cpp backend is appropriate. CPU fallback remains disabled."
    echo ""

    local forge_bin
    forge_bin="$(_llamaforge_require_bin)" || return
    _llamaforge_run "$forge_bin" scan
    echo ""
    PAUSE
}

_llamaforge_dependencies() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Dependency resolver ]${NC}"
    echo ""
    echo "  Checks llama.cpp, compiler toolchains, drivers and runtimes."
    echo "  Missing safe APT packages can be offered for installation, then re-verified."
    echo "  Vendor stacks are not guessed or mixed across Ubuntu releases."
    echo ""

    local forge_bin
    forge_bin="$(_llamaforge_require_bin)" || return
    _llamaforge_run "$forge_bin" dependencies
    echo ""
    PAUSE
}

_llamaforge_generate() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Generate accelerator profiles ]${NC}"
    echo ""
    echo "  Creates build configurations for the hardware that is actually present."
    echo "  Blocked profiles are shown with their reason and are not created."
    echo "  No build is run by this action."
    echo ""

    local forge_bin
    forge_bin="$(_llamaforge_require_bin)" || return
    _llamaforge_run "$forge_bin" generate
    echo ""
    PAUSE
}

_llamaforge_build_manager() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Build manager ]${NC}"
    echo ""
    echo "  View target GPU, backend, status, tuning, logs, repair history and actions."
    echo "  Failed builds are preserved for diagnosis and repair."
    echo ""

    local forge_bin
    forge_bin="$(_llamaforge_require_bin)" || return
    _llamaforge_run "$forge_bin"
}

_llamaforge_tune() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Build performance ]${NC}"
    echo ""
    echo "  Tune Ninja jobs, ccache, native optimisation, unity builds and LTO."
    echo "  The Forge displays detected CPU/RAM and explains the trade-offs."
    echo ""

    local forge_bin
    forge_bin="$(_llamaforge_require_bin)" || return
    _llamaforge_run "$forge_bin" performance
    echo ""
    PAUSE
}

_llamaforge_catalogue() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Switch catalogue ]${NC}"
    echo ""
    echo "  Each catalogue item includes what it does, when to use it,"
    echo "  recommendations, cautions and a usage example."
    echo ""

    local forge_bin
    forge_bin="$(_llamaforge_require_bin)" || return
    _llamaforge_run "$forge_bin" catalogue
    echo ""
    PAUSE
}

_llamaforge_configure() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Guided configuration ]${NC}"
    echo ""
    echo "  Use the checkbox editor to change relevant options."
    echo "  Recommendations are tied to the selected accelerator profile."
    echo "  Protected backend/compiler settings cannot be changed accidentally."
    echo ""

    local forge_bin
    forge_bin="$(_llamaforge_require_bin)" || return
    _llamaforge_run "$forge_bin" configure
    echo ""
    PAUSE
}

_llamaforge_repair() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Diagnose & auto-repair ]${NC}"
    echo ""
    echo "  Re-checks failed builds, diagnoses compiler/linker problems,"
    echo "  and applies only bounded, evidence-based repairs."
    echo "  Repairs are verified with a canary before a full retry."
    echo ""

    local forge_bin
    forge_bin="$(_llamaforge_require_bin)" || return
    _llamaforge_run "$forge_bin" repair
    echo ""
    PAUSE
}

_llamaforge_set_path() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Configure Forge path ]${NC}"
    echo ""
    echo "  Enter the executable launcher path for the Forge."
    echo "  The selected path is saved for future sessions."
    echo ""

    _llamaforge_load_config
    echo "  Current: ${LLAMAFORGE_BIN:-auto-detect}"
    echo ""
    local new_path=""
    read -r -p "  Forge launcher [Enter to auto-detect]: " new_path

    if [[ -z "$new_path" ]]; then
        unset LLAMAFORGE_BIN
        _llamaforge_save_config
        OK "Forge path reset to automatic discovery."
        _llamaforge_log "path reset to auto-detect"
        sleep 1
        return
    fi

    new_path="${new_path/#\~/$HOME}"
    if [[ ! -x "$new_path" ]]; then
        ERR "That path is not an executable Forge launcher."
        PAUSE
        return
    fi

    LLAMAFORGE_BIN="$new_path"
    _llamaforge_save_config
    _llamaforge_log "path configured: $LLAMAFORGE_BIN"
    OK "Forge path saved."
    sleep 1
}

_llamaforge_show_logs() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Module log ]${NC}"
    echo ""
    if [[ -f "$LLAMAFORGE_LOG_FILE" ]]; then
        tail -80 "$LLAMAFORGE_LOG_FILE"
    else
        echo "  No Forge module actions have been logged yet."
    fi
    echo ""
    PAUSE
}

# ── ENTRY POINT ───────────────────────────────────────────────
llamaforge_menu() {
    while true; do
        draw_header
        echo -e "${B_GREEN}[ llama.cpp Build Forge ]${NC}"
        echo ""
        _llamaforge_status
        echo ""
        echo "------------------------------------------------------------"
        echo -e "  1) ${B_GREEN}Hardware & backend scan${NC}"
        echo -e "  2) ${B_GREEN}Dependency resolver${NC}"
        echo -e "  3) ${B_GREEN}Generate build profiles${NC}"
        echo -e "  4) ${B_GREEN}Build manager${NC}"
        echo -e "  5) ${B_GREEN}Guided configuration${NC}"
        echo -e "  6) ${B_GREEN}Build performance tuning${NC}"
        echo -e "  7) ${B_GREEN}Catalogue of CMake options${NC}"
        echo -e "  8) ${B_YELLOW}Diagnose / auto-repair a failed build${NC}"
        echo -e "  9) ${B_YELLOW}Configure Forge path${NC}"
        echo -e " 10) ${B_CYAN}View module log${NC}"
        echo " 11) Back"
        echo ""

        local choice=""
        read -r -p "  Action: " choice
        choice="${choice//[[:space:]]/}"
        choice="${choice%.}"

        case "$choice" in
            1) _llamaforge_scan ;;
            2) _llamaforge_dependencies ;;
            3) _llamaforge_generate ;;
            4) _llamaforge_build_manager ;;
            5) _llamaforge_configure ;;
            6) _llamaforge_tune ;;
            7) _llamaforge_catalogue ;;
            8) _llamaforge_repair ;;
            9) _llamaforge_set_path ;;
            10) _llamaforge_show_logs ;;
            11) return ;;
            *) WARN "Invalid option. Choose one of the displayed numbers."; sleep 1 ;;
        esac
    done
}
