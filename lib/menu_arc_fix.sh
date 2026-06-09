#!/bin/bash
# lib/menu_arc_fix.sh — Intel Arc A770 diagnostics & repair module
# Auto-discovered by llama_manager.sh
# ─────────────────────────────────────────────────────────────────────────────
MENU_LABEL="Arc GPU  (diagnostics · repair)"
MENU_FN="arc_fix_menu"
MENU_COLOR='${B_RED}'
MENU_ORDER=65

_ARC_FIX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/arc_check.sh"
_ARC_FIX_FULL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../arc-fix.sh"

# Source the check library; fail gracefully if missing
if [[ -f "$_ARC_FIX_LIB" ]]; then
    # shellcheck source=arc_check.sh
    source "$_ARC_FIX_LIB"
else
    # Stub so other modules that call arc_all_ok don't crash
    arc_all_ok()    { return 1; }
    arc_status_line() { echo "arc_check.sh not found"; }
    arc_full_status() { echo "arc_check.sh not found at $_ARC_FIX_LIB"; }
    arc_quick_fix() { return 1; }
fi

# ── Status hook (shown in gasket main menu header) ────────────────────────────
show_arc_status() {
    if arc_detect &>/dev/null; then
        if arc_all_ok; then
            echo -e "  Arc GPU:  ${B_GREEN}✓ $(arc_status_line)${NC}"
        else
            echo -e "  Arc GPU:  ${B_YELLOW}⚠ $(arc_status_line)${NC}"
        fi
    else
        echo -e "  Arc GPU:  ${B_RED}✗ not detected${NC}"
    fi
}

# ── Quick-fix without full interactive session ────────────────────────────────
_arc_auto_fix() {
    draw_header
    echo -e "${B_RED}[ 🔧  ARC AUTO-FIX ]${NC}"
    echo ""

    if ! sudo -v 2>/dev/null; then
        ERR "sudo not available — cannot apply fixes"
        PAUSE; return 1
    fi

    STEP "Applying common fixes…"
    arc_quick_fix
    echo ""
    OK "Fix pass complete — log at: ${ARC_FIX_LOG}"
    echo ""

    # Re-run status
    STEP "Re-checking…"
    echo ""
    arc_full_status

    if arc_all_ok; then
        OK "All critical checks now pass."
    else
        WARN "Some issues remain. Use 'Full interactive report' for details."
    fi
    PAUSE
}

# ── Full interactive report (delegates to arc-fix.sh --auto if present) ───────
_arc_full_report() {
    if [[ -x "$_ARC_FIX_FULL" ]]; then
        bash "$_ARC_FIX_FULL" --auto
    else
        draw_header
        echo -e "${B_RED}[ 🔧  ARC FULL REPORT ]${NC}"
        arc_full_status
        PAUSE
    fi
}

# ── Main entry ────────────────────────────────────────────────────────────────
arc_fix_menu() {
    while true; do
        draw_header
        echo -e "${B_RED}[ 🔧  INTEL ARC A770 DIAGNOSTICS ]${NC}"
        echo ""
        arc_full_status
        echo "  ─────────────────────────────────────────────────"
        echo ""
        echo "  1) Auto-fix common issues  (groups · packages · driver · env)"
        echo "  2) Full interactive report (arc-fix.sh --auto)"
        echo "  3) Back"
        echo ""
        read -p "Select [1-3]: " ch
        case $ch in
            1) _arc_auto_fix ;;
            2) _arc_full_report ;;
            3) return ;;
            *) WARN "Invalid option."; sleep 1 ;;
        esac
    done
}
