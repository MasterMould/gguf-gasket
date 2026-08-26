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
    "$HOME/Downloads/llama-build-forge-v13/llama-build-forge/bin/llama-forge"
    "$HOME/Downloads/llama-build-forge-v11/llama-build-forge/bin/llama-forge"
    "$HOME/Downloads/llama-build-forge-v10/llama-build-forge/bin/llama-forge"
)

LLAMAFORGE_INSTALL_DIR="$HOME/ai_stack/llama-build-forge"
LLAMAFORGE_ARCHIVE_CANDIDATES=(
    "$HOME/Downloads/llama-build-forge-v13.tar.gz"
    "$HOME/Downloads/llama-build-forge-v12.tar.gz"
    "$HOME/Downloads/llama-build-forge-v11.tar.gz"
    "$HOME/Downloads/llama-build-forge-v10.tar.gz"
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
        echo -e "    Stable path  : $LLAMAFORGE_INSTALL_DIR"
    else
        echo -e "    Forge        : ${B_YELLOW}not found${NC}"
        echo "    Stable path  : $LLAMAFORGE_INSTALL_DIR"
        echo "    Use Install / update Forge to bootstrap it from ~/Downloads."
    fi

    echo -e "    llama.cpp    : ${INSTALL_DIR:-not configured}"

    if [[ -f "${LLAMAFORGE_LOG_FILE}" ]]; then
        echo -e "    Module log   : ${LLAMAFORGE_LOG_FILE}"
    fi
}

_llamaforge_find_archive() {
    local archive
    for archive in "${LLAMAFORGE_ARCHIVE_CANDIDATES[@]}"; do
        [[ -f "$archive" ]] && { printf '%s\n' "$archive"; return 0; }
    done
    find "$HOME/Downloads" -maxdepth 1 -type f -name 'llama-build-forge-v*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | awk 'NR==1 {$1=""; sub(/^ /,""); print}'
}

_llamaforge_install_forge() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Install / update Forge ]${NC}"
    echo ""
    echo "  Install the Forge into a stable Gasket runtime directory."
    echo "  Existing Forge files are backed up before replacement."
    echo ""
    local archive
    archive="$(_llamaforge_find_archive)"
    if [[ -z "$archive" || ! -f "$archive" ]]; then
        WARN "No llama-build-forge archive was found in $HOME/Downloads."
        echo "  Place a llama-build-forge-v*.tar.gz archive there, or configure"
        echo "  an existing Forge launcher with 'Configure Forge path'."
        PAUSE
        return
    fi
    echo "  Source archive : $archive"
    echo "  Install target : $LLAMAFORGE_INSTALL_DIR"
    echo ""
    read -r -p "  Install/update the Forge now? (y/N): " confirm
    [[ "${confirm,,}" == "y" ]] || { WARN "Cancelled."; sleep 1; return; }

    local parent="$HOME/ai_stack" tmp extracted forge_root
    mkdir -p "$parent"
    tmp="$(mktemp -d "$parent/.llama-forge-install.XXXXXX")"
    if ! tar -xzf "$archive" -C "$tmp"; then
        rm -rf "$tmp"; ERR "Could not extract the Forge archive."; PAUSE; return
    fi
    extracted="$(find "$tmp" -maxdepth 3 -type f -path '*/bin/llama-forge' -print -quit 2>/dev/null)"
    if [[ -z "$extracted" ]]; then
        rm -rf "$tmp"; ERR "Archive does not contain bin/llama-forge."; PAUSE; return
    fi
    forge_root="$(cd "$(dirname "$extracted")/.." && pwd)"
    if [[ -d "$LLAMAFORGE_INSTALL_DIR" ]]; then
        local backup="${LLAMAFORGE_INSTALL_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
        mv "$LLAMAFORGE_INSTALL_DIR" "$backup" || { rm -rf "$tmp"; ERR "Could not back up the existing Forge."; PAUSE; return; }
        echo "  Backup created : $backup"
    fi
    mv "$forge_root" "$LLAMAFORGE_INSTALL_DIR" || { rm -rf "$tmp"; ERR "Could not install the Forge."; PAUSE; return; }
    rm -rf "$tmp"
    chmod +x "$LLAMAFORGE_INSTALL_DIR/bin/llama-forge" "$LLAMAFORGE_INSTALL_DIR/bin/refresh-switches" 2>/dev/null || true
    LLAMAFORGE_BIN="$LLAMAFORGE_INSTALL_DIR/bin/llama-forge"
    _llamaforge_save_config
    _llamaforge_log "forge installed from $archive to $LLAMAFORGE_INSTALL_DIR"
    if "$LLAMAFORGE_BIN" --help >/dev/null 2>&1; then
        OK "Forge installed and verified: $LLAMAFORGE_BIN"
    else
        WARN "Forge installed, but its startup check failed."
    fi
    PAUSE
}

_llamaforge_deploy_build() {
    draw_header
    echo -e "${B_GREEN}[ llama.cpp Build Forge — Deploy completed build ]${NC}"
    echo ""
    echo "  Copies the complete generated CMake bin/ payload into the Gasket"
    echo "  execution directory, including accelerator backend libraries."
    echo "  Existing binaries are backed up first."
    echo ""
    _llamaforge_require_bin >/dev/null || return
    local builds_root=""
    if [[ -d "$LLAMAFORGE_INSTALL_DIR/builds" ]]; then
        builds_root="$LLAMAFORGE_INSTALL_DIR/builds"
    else
        # Compatibility with a Forge unpacked directly under Downloads.
        for d in "$HOME"/Downloads/llama-build-forge-v*/builds; do
            [[ -d "$d" ]] && builds_root="$d"
        done
    fi
    if [[ -z "$builds_root" || ! -d "$builds_root" ]]; then
        WARN "No Forge build directory was found. Build a successful configuration first."; PAUSE; return
    fi

    local -a manifests=()
    while IFS= read -r f; do manifests+=("$f"); done < <(find "$builds_root" -mindepth 2 -maxdepth 2 -type f -name manifest.json -print | sort)
    local count=0 f status id name
    echo "=== COMPLETED BUILDS ==="
    for f in "${manifests[@]}"; do
        status="$(python3 - "$f" <<'PYJSON'
import json,sys
try:
    m=json.load(open(sys.argv[1])); r=(m.get('results') or [{}])[-1]
    print('BUILT' if r.get('exit_code')==0 else 'OTHER')
except Exception:
    print('OTHER')
PYJSON
)"
        [[ "$status" == "BUILT" ]] || continue
        count=$((count+1))
        read -r id name < <(python3 - "$f" <<'PYJSON'
import json,sys
m=json.load(open(sys.argv[1])); print(m.get('id',''), m.get('name',m.get('profile_id','')))
PYJSON
)
        echo "  $count) $id | $name"
    done
    if (( count == 0 )); then WARN "No successful builds are available for deployment."; PAUSE; return; fi

    local choice=""
    read -r -p "  Successful build number [1-$count, 0 to cancel]: " choice
    choice="${choice//[[:space:]]/}"; choice="${choice%.}"
    [[ "$choice" =~ ^[0-9]+$ ]] || { WARN "Invalid selection."; PAUSE; return; }
    (( choice > 0 && choice <= count )) || return

    local selected="" idx=0
    for f in "${manifests[@]}"; do
        status="$(python3 - "$f" <<'PYJSON'
import json,sys
try:
    m=json.load(open(sys.argv[1])); r=(m.get('results') or [{}])[-1]
    print('BUILT' if r.get('exit_code')==0 else 'OTHER')
except Exception:
    print('OTHER')
PYJSON
)"
        [[ "$status" == "BUILT" ]] || continue
        idx=$((idx+1)); [[ "$idx" == "$choice" ]] && { selected="$f"; break; }
    done
    [[ -n "$selected" ]] || { ERR "Could not resolve the selected build."; PAUSE; return; }

    local source_bin target_bin backup
    source_bin="$(python3 - "$selected" <<'PYJSON'
import json,sys,os
m=json.load(open(sys.argv[1]))
b=os.path.join(m['build_dir'],'bin')
if not os.path.isdir(b): b=os.path.join(m.get('source_dir',''),'build','bin')
print(b)
PYJSON
)"
    target_bin="${BUILD_DIR:-${INSTALL_DIR:-$HOME/ai_stack/llama.cpp/build}}/bin"
    [[ -d "$source_bin" ]] || { ERR "Built binary directory not found: $source_bin"; PAUSE; return; }
    echo ""
    echo "  Source payload : $source_bin"
    echo "  Gasket target  : $target_bin"
    echo ""
    read -r -p "  Deploy this completed build? (y/N): " confirm
    [[ "${confirm,,}" == "y" ]] || { WARN "Cancelled."; PAUSE; return; }

    mkdir -p "$(dirname "$target_bin")"
    if [[ -d "$target_bin" ]]; then
        backup="${target_bin}.backup.$(date +%Y%m%d-%H%M%S)"
        cp -a "$target_bin" "$backup" || { ERR "Could not create deployment backup."; PAUSE; return; }
        echo "  Backup created : $backup"
    fi
    rm -rf "$target_bin"; mkdir -p "$target_bin"
    if ! cp -a "$source_bin/." "$target_bin/"; then
        ERR "Deployment copy failed."; PAUSE; return
    fi
    local cli="$target_bin/llama-cli" server="$target_bin/llama-server" bench="$target_bin/llama-bench"
    [[ -x "$cli" ]] && OK "llama-cli deployed"
    [[ -x "$server" ]] && OK "llama-server deployed"
    [[ -x "$bench" ]] && OK "llama-bench deployed"
    if [[ -x "$cli" && -x "$server" ]]; then
        _llamaforge_log "deployed selected build to $target_bin"
        OK "Deployment complete. Gasket can execute the deployed build from $target_bin."
    else
        WARN "Deployment copied files, but the expected llama.cpp executables were not all found."
    fi
    PAUSE
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
        echo -e "  9) ${B_YELLOW}Install / update Forge${NC}"
        echo -e " 10) ${B_YELLOW}Configure Forge path${NC}"
        echo -e " 11) ${B_CYAN}Deploy completed build to Gasket${NC}"
        echo -e " 12) ${B_CYAN}View module log${NC}"
        echo " 13) Back"
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
            9) _llamaforge_install_forge ;;
            10) _llamaforge_set_path ;;
            11) _llamaforge_deploy_build ;;
            12) _llamaforge_show_logs ;;
            13) return ;;
            *) WARN "Invalid option. Choose one of the displayed numbers."; sleep 1 ;;
        esac
    done
}
