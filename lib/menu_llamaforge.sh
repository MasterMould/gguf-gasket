#!/bin/bash
# LLAMA COMMAND CENTER: llama.cpp Build Forge integration module
MENU_LABEL="llama.cpp Build Forge"
MENU_FN="llamaforge_menu"
MENU_COLOR='${B_GREEN}'
MENU_ORDER=15

LLAMAFORGE_CONFIG_DIR="$HOME/ai_stack/llama-forge"
LLAMAFORGE_CONFIG_FILE="$LLAMAFORGE_CONFIG_DIR/config"
LLAMAFORGE_LOG_FILE="$LLAMAFORGE_CONFIG_DIR/module.log"
LLAMAFORGE_INSTALL_DIR="$HOME/ai_stack/llama-build-forge"
LLAMAFORGE_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMAFORGE_EMBEDDED_DIR="$LLAMAFORGE_MODULE_DIR/forge"
LLAMAFORGE_BIN="$LLAMAFORGE_INSTALL_DIR/bin/llama-forge"

_llamaforge_log() { mkdir -p "$LLAMAFORGE_CONFIG_DIR"; printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LLAMAFORGE_LOG_FILE"; }
_llamaforge_load_config() { mkdir -p "$LLAMAFORGE_CONFIG_DIR"; [[ -f "$LLAMAFORGE_CONFIG_FILE" ]] && source "$LLAMAFORGE_CONFIG_FILE" 2>/dev/null || true; }
_llamaforge_save_config() { mkdir -p "$LLAMAFORGE_CONFIG_DIR"; printf 'LLAMAFORGE_BIN=%q\n' "${LLAMAFORGE_BIN:-}" > "$LLAMAFORGE_CONFIG_FILE"; }

_llamaforge_find_archive() {
    local a
    for a in "$HOME"/Downloads/llama-build-forge-v*.tar.gz "$HOME"/Downloads/llama-build-forge*.tar.gz; do
        [[ -f "$a" ]] && printf '%s\n' "$a"
    done | sort -V | tail -1
}

_llamaforge_bootstrap_embedded() {
    [[ -x "$LLAMAFORGE_EMBEDDED_DIR/bin/llama-forge" ]] || return 1
    mkdir -p "$LLAMAFORGE_INSTALL_DIR"
    rm -rf "$LLAMAFORGE_INSTALL_DIR.new"
    mkdir -p "$LLAMAFORGE_INSTALL_DIR.new"
    cp -a "$LLAMAFORGE_EMBEDDED_DIR/." "$LLAMAFORGE_INSTALL_DIR.new/"
    mv "$LLAMAFORGE_INSTALL_DIR.new" "$LLAMAFORGE_INSTALL_DIR"
    chmod +x "$LLAMAFORGE_INSTALL_DIR/bin/llama-forge" "$LLAMAFORGE_INSTALL_DIR/bin/refresh-switches" 2>/dev/null || true
    LLAMAFORGE_BIN="$LLAMAFORGE_INSTALL_DIR/bin/llama-forge"
    _llamaforge_save_config
    _llamaforge_log "bootstrapped embedded Forge into $LLAMAFORGE_INSTALL_DIR"
    return 0
}

_llamaforge_install_archive() {
    local archive="$1" tmp root extracted
    tmp="$(mktemp -d "$HOME/ai_stack/.llama-forge.XXXXXX")" || return 1
    if ! tar -xzf "$archive" -C "$tmp"; then rm -rf "$tmp"; return 1; fi
    extracted="$(find "$tmp" -maxdepth 4 -type f -path '*/bin/llama-forge' -print -quit 2>/dev/null)"
    [[ -n "$extracted" ]] || { rm -rf "$tmp"; return 1; }
    root="$(cd "$(dirname "$extracted")/.." && pwd)"
    rm -rf "$LLAMAFORGE_INSTALL_DIR.new"
    cp -a "$root" "$LLAMAFORGE_INSTALL_DIR.new" || { rm -rf "$tmp"; return 1; }
    rm -rf "$LLAMAFORGE_INSTALL_DIR"
    mv "$LLAMAFORGE_INSTALL_DIR.new" "$LLAMAFORGE_INSTALL_DIR"
    rm -rf "$tmp"
    LLAMAFORGE_BIN="$LLAMAFORGE_INSTALL_DIR/bin/llama-forge"
    chmod +x "$LLAMAFORGE_BIN" "$LLAMAFORGE_INSTALL_DIR/bin/refresh-switches" 2>/dev/null || true
    _llamaforge_save_config
    _llamaforge_log "installed Forge archive $archive"
    return 0
}

_llamaforge_find_bin() {
    _llamaforge_load_config
    [[ -x "${LLAMAFORGE_BIN:-}" ]] && { printf '%s\n' "$LLAMAFORGE_BIN"; return 0; }
    if command -v llama-forge >/dev/null 2>&1; then LLAMAFORGE_BIN="$(command -v llama-forge)"; _llamaforge_save_config; printf '%s\n' "$LLAMAFORGE_BIN"; return 0; fi
    [[ -x "$LLAMAFORGE_INSTALL_DIR/bin/llama-forge" ]] && { LLAMAFORGE_BIN="$LLAMAFORGE_INSTALL_DIR/bin/llama-forge"; _llamaforge_save_config; printf '%s\n' "$LLAMAFORGE_BIN"; return 0; }
    [[ -x "$LLAMAFORGE_EMBEDDED_DIR/bin/llama-forge" ]] && { printf '%s\n' "$LLAMAFORGE_EMBEDDED_DIR/bin/llama-forge"; return 0; }
    return 1
}

_llamaforge_ensure() {
    local bin archive
    if bin="$(_llamaforge_find_bin)"; then
        if [[ "$bin" == "$LLAMAFORGE_EMBEDDED_DIR/bin/llama-forge" ]]; then
            echo "  Forge is bundled with this module and is not yet installed."
            echo "  Stable install: $LLAMAFORGE_INSTALL_DIR"
            read -r -p "  Install the bundled Forge now? [Y/n]: " _ans
            [[ -z "$_ans" || "${_ans,,}" == "y" ]] || return 1
            _llamaforge_bootstrap_embedded || { ERR "Bundled Forge installation failed."; return 1; }
            bin="$LLAMAFORGE_BIN"
        fi
        printf '%s\n' "$bin"
        return 0
    fi
    archive="$(_llamaforge_find_archive)"
    if [[ -n "$archive" ]]; then
        echo "  Forge is not installed. Found: $archive"
        read -r -p "  Install it into $LLAMAFORGE_INSTALL_DIR now? [Y/n]: " _ans
        [[ -z "$_ans" || "${_ans,,}" == "y" ]] || return 1
        _llamaforge_install_archive "$archive" || { ERR "Forge installation failed."; return 1; }
        printf '%s\n' "$LLAMAFORGE_BIN"
        return 0
    fi
    echo "  No Forge installation or archive was found."
    echo "  Place llama-build-forge-v*.tar.gz in ~/Downloads, or use Install/Update."
    return 1
}

_llamaforge_status() {
    echo "  Status"
    local b=""; if b="$(_llamaforge_find_bin)"; then
        echo "    Forge        : available"
        echo "    Launcher     : $b"
    else
        echo "    Forge        : not installed"
    fi
    echo "    Stable path  : $LLAMAFORGE_INSTALL_DIR"
    echo "    llama.cpp    : ${INSTALL_DIR:-not configured}"
}

_llamaforge_run() {
    local b="$1"; shift
    _llamaforge_log "run $b $*"
    "$b" "$@"; local rc=$?
    _llamaforge_log "exit=$rc"
    return $rc
}

_llamaforge_action() {
    local title="$1" cmd="$2"; shift 2
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — $title ]${NC}"
    echo ""
    local b
    b="$(_llamaforge_ensure)" || { WARN "Forge is not ready. No action was run."; PAUSE; return; }
    _llamaforge_run "$b" "$cmd" "$@"
    echo ""
    PAUSE
}

_llamaforge_install() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Install / update ]${NC}"
    echo ""
    if [[ -x "$LLAMAFORGE_EMBEDDED_DIR/bin/llama-forge" ]]; then
        if ask "Install/update the bundled Forge into $LLAMAFORGE_INSTALL_DIR?"; then
            _llamaforge_bootstrap_embedded && OK "Forge installed and ready."
        fi
    else
        local a="$(_llamaforge_find_archive)"
        [[ -n "$a" ]] || { WARN "No Forge archive found in ~/Downloads."; PAUSE; return; }
        if ask "Install $a into $LLAMAFORGE_INSTALL_DIR?"; then
            _llamaforge_install_archive "$a" && OK "Forge installed and ready."
        fi
    fi
    PAUSE
}

_llamaforge_path() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Configure path ]${NC}"
    _llamaforge_load_config
    echo "  Current: ${LLAMAFORGE_BIN:-auto-detect}"
    echo ""
    local p
    read -r -p "  Forge launcher (Enter to auto-detect): " p
    if [[ -z "$p" ]]; then unset LLAMAFORGE_BIN; _llamaforge_save_config; OK "Automatic discovery restored."; else
        p="${p/#\~/$HOME}"; [[ -x "$p" ]] || { ERR "Not an executable Forge launcher."; PAUSE; return; }
        LLAMAFORGE_BIN="$p"; _llamaforge_save_config; OK "Forge path saved."
    fi
    PAUSE
}

_llamaforge_deploy() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Deploy completed build ]${NC}"
    echo ""
    echo "  Copies a verified completed Forge build into the Gasket execution directory."
    echo "  The existing runtime bin/ directory is backed up before replacement."
    echo ""
    local b builds_root f status count=0 id name choice idx=0 selected source_bin target_bin backup
    b="$(_llamaforge_ensure)" || { WARN "Forge is not ready."; PAUSE; return; }
    builds_root="$LLAMAFORGE_INSTALL_DIR/builds"
    [[ -d "$builds_root" ]] || { WARN "No Forge builds exist yet."; PAUSE; return; }
    declare -a manifests=()
    while IFS= read -r f; do manifests+=("$f"); done < <(find "$builds_root" -mindepth 2 -maxdepth 2 -type f -name manifest.json -print 2>/dev/null | sort)
    echo "=== SUCCESSFUL BUILDS ==="
    for f in "${manifests[@]}"; do
        status="$(python3 - "$f" <<'PYJSON'
import json,sys
try:
 m=json.load(open(sys.argv[1])); r=(m.get('results') or [{}])[-1]
 print('BUILT' if r.get('exit_code')==0 else 'OTHER')
except Exception: print('OTHER')
PYJSON
)"
        [[ "$status" == BUILT ]] || continue
        count=$((count+1))
        read -r id name < <(python3 - "$f" <<'PYJSON'
import json,sys
m=json.load(open(sys.argv[1])); print(m.get('id',''), m.get('name',m.get('profile_id','')))
PYJSON
)
        printf '  %2d) %-40s %s\n' "$count" "$id" "$name"
    done
    (( count > 0 )) || { WARN "No successful builds are available for deployment."; PAUSE; return; }
    read -r -p "  Successful build [1-$count, 0 to cancel]: " choice
    choice="${choice//[[:space:]]/}"; choice="${choice%.}"
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>0 && choice<=count)) || return
    for f in "${manifests[@]}"; do
        status="$(python3 - "$f" <<'PYJSON'
import json,sys
try:
 m=json.load(open(sys.argv[1])); r=(m.get('results') or [{}])[-1]
 print('BUILT' if r.get('exit_code')==0 else 'OTHER')
except Exception: print('OTHER')
PYJSON
)"
        [[ "$status" == BUILT ]] || continue
        idx=$((idx+1)); [[ "$idx" == "$choice" ]] && { selected="$f"; break; }
    done
    [[ -n "$selected" ]] || { ERR "Could not resolve the selected build."; PAUSE; return; }
    source_bin="$(python3 - "$selected" <<'PYJSON'
import json,sys,os
m=json.load(open(sys.argv[1])); print(os.path.join(m['build_dir'],'bin'))
PYJSON
)"
    target_bin="${BUILD_DIR:-${INSTALL_DIR:-$HOME/ai_stack/llama.cpp/build}}/bin"
    [[ -d "$source_bin" ]] || { ERR "Completed build bin/ not found: $source_bin"; PAUSE; return; }
    echo ""; echo "  Source : $source_bin"; echo "  Target : $target_bin"; echo ""
    ask "Deploy this completed build to Gasket?" || { WARN "Cancelled."; PAUSE; return; }
    mkdir -p "$(dirname "$target_bin")"
    if [[ -d "$target_bin" ]]; then
        backup="${target_bin}.backup.$(date +%Y%m%d-%H%M%S)"
        cp -a "$target_bin" "$backup" || { ERR "Could not create backup: $backup"; PAUSE; return; }
        echo "  Backup : $backup"
    fi
    rm -rf "$target_bin"; mkdir -p "$target_bin"
    cp -a "$source_bin/." "$target_bin/" || { ERR "Deployment copy failed."; PAUSE; return; }
    [[ -x "$target_bin/llama-cli" ]] && OK "llama-cli verified" || WARN "llama-cli not found"
    [[ -x "$target_bin/llama-server" ]] && OK "llama-server verified" || WARN "llama-server not found"
    [[ -x "$target_bin/llama-bench" ]] && OK "llama-bench verified" || true
    _llamaforge_log "deployed $selected to $target_bin"
    OK "Deployment complete."
    PAUSE
}

llamaforge_menu() {
    while true; do
        draw_header
        echo -e "${B_GREEN}[ llama.cpp Build Forge ]${NC}"; echo ""
        _llamaforge_status; echo ""
        echo "------------------------------------------------------------"
        echo "  1) Hardware & backend scan"
        echo "  2) Dependency resolver"
        echo "  3) Generate build profiles"
        echo "  4) Build manager"
        echo "  5) Guided configuration"
        echo "  6) Build performance tuning"
        echo "  7) Catalogue of CMake options"
        echo "  8) Diagnose / auto-repair a failed build"
        echo "  9) Install / update Forge"
        echo " 10) Configure Forge path"
        echo " 11) Deploy completed build to Gasket"
        echo " 12) View module log"
        echo " 13) Back"; echo ""
        local c=""; read -r -p "  Action: " c; c="${c//[[:space:]]/}"; c="${c%.}"
        case "$c" in
          1) _llamaforge_action "Hardware & backend scan" scan ;;
          2) _llamaforge_action "Dependency resolver" dependencies ;;
          3) _llamaforge_action "Generate accelerator profiles" generate --source "${INSTALL_DIR:-$HOME/ai_stack/llama.cpp}" ;;
          4) _llamaforge_action "Build manager" manager ;;
          5) _llamaforge_action "Guided configuration" configure ;;
          6) _llamaforge_action "Build performance" performance ;;
          7) _llamaforge_action "Switch catalogue" catalogue ;;
          8) _llamaforge_action "Diagnose / auto-repair" repair ;;
          9) _llamaforge_install ;;
          10) _llamaforge_path ;;
          11) _llamaforge_deploy ; PAUSE ;;
          12) _llamaforge_show_log ;;
          13) return ;;
          *) WARN "Invalid option. Choose a displayed number."; sleep 1 ;;
        esac
    done
}

_llamaforge_show_log() { draw_header; echo -e "${B_GREEN}[ llama.cpp Build Forge — Module log ]${NC}"; echo ""; [[ -f "$LLAMAFORGE_LOG_FILE" ]] && tail -100 "$LLAMAFORGE_LOG_FILE" || echo "  No module actions logged yet."; PAUSE; }
