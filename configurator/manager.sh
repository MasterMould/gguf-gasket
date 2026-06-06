#!/usr/bin/env bash
# =============================================================================
#  llama.cpp Config Manager — Setup, Model Finder & Launcher
# =============================================================================

set -euo pipefail

# ── Colours & symbols ─────────────────────────────────────────────────────────
R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'
C=$'\033[0;36m'; M=$'\033[0;35m'; W=$'\033[1;37m'; D=$'\033[0;90m'; N=$'\033[0m'
BOLD=$'\033[1m'; DIM=$'\033[2m'

TICK="${G}✔${N}"; CROSS="${R}✘${N}"; WARN="${Y}!${N}"; ARROW="${C}▶${N}"

# ── Script constants ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="llamacpp-manager"
BINARY_PATH="$SCRIPT_DIR/$BINARY_NAME"
SOURCE_PATH="$SCRIPT_DIR/main.go"
MOD_PATH="$SCRIPT_DIR/go.mod"
DEFAULT_CONFIG_DIR="$SCRIPT_DIR/configs"
DEFAULT_PORT=7070
MIN_GO_MAJOR=1; MIN_GO_MINOR=22

# ── Shared paths config ───────────────────────────────────────────────────────
# paths.json lives next to the binary and is written by the Go web UI (Paths tab).
# Load it here so both tools always share the same directory lists.
# Falls back to built-in defaults when the file is absent or unparseable.
PATHS_JSON="$SCRIPT_DIR/paths.json"

# ── Built-in defaults (mirror of defaultPaths() in main.go) ──────────────────
# Edit these here AND in main.go → defaultPaths() to keep them in sync,
# OR just use the Paths tab in the web UI which writes paths.json for both.
_DEFAULT_MODEL_DIRS=(
    "/home/first/ai_stack/models"
    "$HOME/ai_stack/models"
    "$HOME/models"
    "$HOME/Downloads"
    "$HOME/.cache/huggingface/hub"
    "$HOME/.cache/lm-studio/models"
    "$HOME/.lmstudio/models"
    "$HOME/.cache/llama.cpp"
    "$HOME/.ollama/models/blobs"
    "$HOME/llama.cpp/models"
    "$HOME/llama/models"
    "/opt/models"
    "/opt/ai/models"
    "/var/lib/models"
    "/srv/models"
    "$SCRIPT_DIR/models"
    "$SCRIPT_DIR/../models"
)

_DEFAULT_BINARY_DIRS=(
    "/home/first/ai_stack"
    "/home/first/ai_stack/llama.cpp"
    "/home/first/ai_stack/llama.cpp/build/bin"
    "$HOME/llama.cpp/build/bin"
    "$HOME/llama.cpp/build"
    "$HOME/llama.cpp"
    "$HOME/llama/build/bin"
    "$HOME/llama/build"
    "/opt/llama.cpp/bin"
    "/opt/llama.cpp"
    "/usr/local/bin"
    "/usr/bin"
    "$SCRIPT_DIR"
)

# ── Parse a JSON array from paths.json (python3 preferred, jq fallback) ──────
_json_array() {
    local key="$1"
    if command -v python3 &>/dev/null; then
        python3 - "$PATHS_JSON" "$key" "$HOME" << 'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    home = sys.argv[3]
    for p in data.get(sys.argv[2], []):
        print(p.replace("~", home))
except Exception:
    pass
PY
    elif command -v jq &>/dev/null; then
        jq -r --arg h "$HOME" --arg k "$key" '.[$k][]? | gsub("~"; $h)' "$PATHS_JSON" 2>/dev/null
    fi
}

# ── Load from paths.json, fall back to defaults ───────────────────────────────
load_paths_json() {
    MODEL_SEARCH_DIRS=()
    LLAMA_BINARY_SEARCH=()

    if [[ -f "$PATHS_JSON" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && MODEL_SEARCH_DIRS+=("$line")
        done < <(_json_array "model_search_dirs")

        while IFS= read -r line; do
            [[ -n "$line" ]] && LLAMA_BINARY_SEARCH+=("$line")
        done < <(_json_array "binary_search_dirs")
    fi

    [[ ${#MODEL_SEARCH_DIRS[@]}   -eq 0 ]] && MODEL_SEARCH_DIRS=("${_DEFAULT_MODEL_DIRS[@]}")
    [[ ${#LLAMA_BINARY_SEARCH[@]} -eq 0 ]] && LLAMA_BINARY_SEARCH=("${_DEFAULT_BINARY_DIRS[@]}")
}

# Run on script start; can be re-called after the web UI saves new paths.
load_paths_json

# ── Session state ─────────────────────────────────────────────────────────────
SELECTED_CONFIG_DIR="$DEFAULT_CONFIG_DIR"
SELECTED_PORT="$DEFAULT_PORT"
SELECTED_MODEL=""            # full path to a .gguf file
SELECTED_INI_CONFIG=""       # full path to a .ini config file
SELECTED_LLAMA_BIN=""        # full path to llama-server or llama-cli
MODEL_LIST=()                # populated by scan_models
MODEL_SIZES=()               # parallel array: human-readable sizes
MODEL_QUANTS=()              # parallel array: quantisation label parsed from filename
APP_PID=""

# ── Utilities ─────────────────────────────────────────────────────────────────
clear_screen() { clear; }
press_enter()  { echo; printf "  ${DIM}Press Enter to continue...${N}"; read -r; }
print_sep()    { printf "  ${D}"; printf '─%.0s' {1..66}; printf "${N}\n"; }

header() {
    clear_screen; echo
    printf "  ${C}${BOLD}🦙  llama.cpp Config Manager${N}\n"
    printf "  ${D}Model Finder & Launcher${N}\n"
    echo; print_sep; echo
}

# ── Status row helpers ────────────────────────────────────────────────────────
status_row() {
    local icon="$1" label="$2" note="${3:-}"
    printf "  %-2s  %-30s %b\n" "$icon" "$label" "$note"
}

# ── Dependency checks ─────────────────────────────────────────────────────────
check_go() {
    command -v go &>/dev/null || return 1
    local ver; ver=$(go version | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local major minor
    major=$(cut -d. -f1 <<< "$ver"); minor=$(cut -d. -f2 <<< "$ver")
    [[ "$major" -gt "$MIN_GO_MAJOR" ]] && return 0
    [[ "$major" -eq "$MIN_GO_MAJOR" && "$minor" -ge "$MIN_GO_MINOR" ]]
}
check_binary() { [[ -x "$BINARY_PATH" ]]; }
check_source()  { [[ -f "$SOURCE_PATH" && -f "$MOD_PATH" ]]; }
check_optional(){ command -v "$1" &>/dev/null; }

assess_deps() {
    DEP_GO=false;   check_go              && DEP_GO=true
    DEP_BINARY=false; check_binary        && DEP_BINARY=true
    DEP_SOURCE=false; check_source        && DEP_SOURCE=true
    DEP_CURL=false; check_optional curl   && DEP_CURL=true
    DEP_XDGO=false; check_optional xdg-open && DEP_XDGO=true
    DEP_OPEN=false; check_optional open   && DEP_OPEN=true
    if $DEP_BINARY; then CAN_RUN=true
    elif $DEP_GO && $DEP_SOURCE; then CAN_RUN=true
    else CAN_RUN=false; fi
}

# ── Auto-dependency resolution ────────────────────────────────────────────────

# Print a live step line, overwriting previous with CR.
_step() { printf "  ${C}▶${N} %s\r" "$*"; }
_ok()   { printf "  ${G}✔${N} %-50s\n" "$*"; }
_fail() { printf "  ${R}✘${N} %-50s\n" "$*"; }
_info() { printf "  ${D}  %s${N}\n"    "$*"; }

# Detect package manager
_pm() {
    command -v apt-get &>/dev/null && echo apt   && return
    command -v dnf     &>/dev/null && echo dnf   && return
    command -v yum     &>/dev/null && echo yum   && return
    command -v pacman  &>/dev/null && echo pacman && return
    echo unknown
}

# Silent package install; returns 0 on success.
_pkg_install() {
    local pm; pm=$(_pm)
    case "$pm" in
        apt)
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "$@" \
                2>&1 | grep -E "^(Get:|Unpacking|Setting up|E:)" || true
            ;;
        dnf|yum) sudo "$pm" install -y "$@" 2>&1 | tail -3 ;;
        pacman)  sudo pacman -S --noconfirm "$@" 2>&1 | tail -3 ;;
        *)  printf "  ${Y}!${N} Unknown package manager — install manually: %s\n" "$*"
            return 1 ;;
    esac
}

# Try to make Go ≥1.22 available.
_install_go() {
    local pm; pm=$(_pm)
    _step "Checking apt for Go packages…"

    if [[ "$pm" == "apt" ]]; then
        # Refresh package lists quietly (only if last update > 1 hour ago)
        local stamp="/var/lib/apt/periodic/update-success-stamp"
        if [[ ! -f "$stamp" ]] || (( $(date +%s) - $(stat -c%Y "$stamp" 2>/dev/null||echo 0) > 3600 )); then
            _step "Updating apt cache…"
            sudo apt-get update -qq 2>/dev/null || true
        fi

        # Try versioned packages first (most reliable on Ubuntu 22.04 / Debian)
        for pkg in golang-1.23-go golang-1.22-go golang-go; do
            if apt-cache show "$pkg" &>/dev/null 2>&1; then
                _step "Installing ${pkg}…"
                _pkg_install "$pkg" && {
                    # Versioned installs land in /usr/lib/go-1.XX/bin
                    for d in /usr/lib/go-1.*/bin; do
                        [[ -x "$d/go" ]] && export PATH="$d:$PATH"
                    done
                    check_go && { _ok "Go installed via apt ($pkg)"; return 0; }
                }
            fi
        done
    fi

    # snap fallback (cross-distro, always ships latest)
    if ! check_go && command -v snap &>/dev/null; then
        _step "Installing Go via snap…"
        sudo snap install go --classic 2>/dev/null && {
            export PATH="/snap/bin:$PATH"
            check_go && { _ok "Go installed via snap"; return 0; }
        }
    fi

    # Last resort: download official tarball from go.dev
    if ! check_go; then
        local GOVERSION="1.22.5"
        local ARCH; ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)         ARCH="amd64"  ;;
            aarch64|arm64)  ARCH="arm64"  ;;
            armv*)          ARCH="armv6l" ;;
            *)
                _fail "Unsupported CPU arch: $ARCH — install Go manually from https://go.dev"
                return 1 ;;
        esac

        local URL="https://go.dev/dl/go${GOVERSION}.linux-${ARCH}.tar.gz"
        local TMP="/tmp/go-installer.tar.gz"
        _step "Downloading Go ${GOVERSION} from go.dev…"

        if command -v curl &>/dev/null; then
            curl -fsSL "$URL" -o "$TMP" 2>/dev/null
        elif command -v wget &>/dev/null; then
            wget -q "$URL" -O "$TMP" 2>/dev/null
        else
            _fail "No curl or wget — cannot download Go"
            return 1
        fi

        _step "Extracting to /usr/local…"
        sudo rm -rf /usr/local/go
        sudo tar -C /usr/local -xzf "$TMP" && rm -f "$TMP"
        export PATH="/usr/local/go/bin:$PATH"

        # Persist for future shells
        local profile_snippet='export PATH="/usr/local/go/bin:$PATH"'
        if ! grep -qF "/usr/local/go/bin" /etc/profile.d/*.sh 2>/dev/null; then
            echo "$profile_snippet" | sudo tee /etc/profile.d/go-local.sh > /dev/null
        fi
        # Also add to ~/.bashrc for interactive shells
        grep -qF "/usr/local/go/bin" "$HOME/.bashrc" 2>/dev/null \
            || echo "$profile_snippet" >> "$HOME/.bashrc"

        check_go && { _ok "Go ${GOVERSION} installed from go.dev"; return 0; }
        _fail "Go installation failed — see output above"
        return 1
    fi
}

# Install a single optional tool quietly.
_ensure_tool() {
    local name="$1" pkg="${2:-$1}"
    command -v "$name" &>/dev/null && return 0
    _step "Installing ${pkg}…"
    _pkg_install "$pkg" && _ok "$name installed" || _fail "Could not install $pkg"
}

# Master auto-fix: install everything that's missing and build the binary.
auto_fix_deps() {
    header
    printf "  ${W}${BOLD}Auto-Fix Dependencies${N}\n\n"
    print_sep; echo

    local changed=false sudo_ok=false

    # Acquire sudo once up front
    printf "  ${Y}Sudo is required to install packages.${N}\n"
    if sudo -v 2>/dev/null; then
        sudo_ok=true
        _ok "sudo credentials acquired"
    else
        _fail "sudo not available — cannot install packages automatically"
        press_enter; return
    fi
    echo

    # ── Go toolchain ──
    printf "  ${D}Go toolchain${N}\n"
    if check_go; then
        local gv; gv=$(go version | grep -oE 'go[0-9]+\.[0-9.]+' | head -1)
        _ok "Go already installed ($gv)"
    else
        _install_go
        if check_go; then
            changed=true
        else
            printf "\n  ${R}✘ Could not install Go automatically.${N}\n"
            printf "  ${D}  Install manually: https://go.dev/doc/install${N}\n\n"
        fi
    fi
    echo

    # ── Build binary ──
    printf "  ${D}Config manager binary${N}\n"
    if check_binary; then
        _ok "Binary already present"
    elif check_go && check_source; then
        _step "Building ${BINARY_NAME}…"
        if (cd "$SCRIPT_DIR" && go build -o "$BINARY_NAME" . 2>&1); then
            _ok "Binary built: ${BINARY_PATH}"
            changed=true
        else
            _fail "Build failed — check output above"
        fi
    else
        _fail "Source files missing — cannot build"
        _info "Ensure main.go and go.mod are in: $SCRIPT_DIR"
    fi
    echo

    # ── Optional tools ──
    printf "  ${D}Optional tools${N}\n"
    _ensure_tool curl curl
    _ensure_tool xdg-open xdg-utils
    _ensure_tool bc bc
    echo

    # Re-assess after fixes
    assess_deps
    print_sep; echo

    if $CAN_RUN; then
        printf "  ${G}${BOLD}✔  All requirements met — ready to run.${N}\n"
        $changed && printf "  ${D}  (restart the script or re-open your shell if PATH was updated)${N}\n"
    else
        printf "  ${R}✘  Still not ready.${N}  See failures above.\n"
    fi
    echo; press_enter
}

# ── Model filename parsing ─────────────────────────────────────────────────────
# Extract quantisation tag from a GGUF filename, e.g. Q4_K_M, Q8_0, F16, IQ3_XS
parse_quant() {
    local f="${1##*/}"   # basename
    local q
    # Match common patterns: Q4_K_M, Q5_K_S, Q8_0, IQ3_XS, IQ4_NL, F16, F32, BF16
    q=$(grep -oiE '(IQ[0-9]_[A-Z_]+|Q[0-9]+_[A-Z0-9_]+|BF16|F16|F32)' <<< "$f" | head -1)
    echo "${q:-unknown}"
}

# Human-readable file size
human_size() {
    local path="$1"
    local bytes; bytes=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || echo 0)
    if   (( bytes >= 1073741824 )); then printf "%.1fG" "$(echo "scale=1; $bytes/1073741824" | bc 2>/dev/null || echo 0)"
    elif (( bytes >= 1048576    )); then printf "%.0fM" "$(echo "scale=0; $bytes/1048576"    | bc 2>/dev/null || echo 0)"
    else printf "%dK" "$(( bytes / 1024 ))"; fi
}

# ── Model scanner ─────────────────────────────────────────────────────────────
scan_models() {
    MODEL_LIST=(); MODEL_SIZES=(); MODEL_QUANTS=()
    local seen_paths=""

    for dir in "${MODEL_SEARCH_DIRS[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            # deduplicate by resolved path
            local real; real=$(readlink -f "$f" 2>/dev/null || echo "$f")
            grep -qF "$real" <<< "$seen_paths" 2>/dev/null && continue
            seen_paths+="$real"$'\n'
            MODEL_LIST+=("$f")
            MODEL_SIZES+=("$(human_size "$f")")
            MODEL_QUANTS+=("$(parse_quant "$f")")
        done < <(find "$dir" -maxdepth 6 \( -name "*.gguf" -o -name "*.GGUF" \) \
                     -not -path "*/.git/*" -print0 2>/dev/null)
    done
}

# ── Model picker ──────────────────────────────────────────────────────────────
PAGE_SIZE=12

pick_model() {
    header
    printf "  ${W}${BOLD}Select Model${N}\n\n"
    printf "  ${D}Scanning for .gguf files…${N}\n"
    scan_models

    local total=${#MODEL_LIST[@]}

    if [[ $total -eq 0 ]]; then
        printf "\n  ${CROSS} No .gguf models found.\n\n"
        printf "  ${D}Searched:${N}\n"
        for d in "${MODEL_SEARCH_DIRS[@]}"; do
            [[ -d "$d" ]] && printf "    ${G}✔${N} %-50s\n" "$d" \
                          || printf "    ${D}–${N} %-50s ${D}(not found)${N}\n" "$d"
        done
        echo
        printf "  ${W}[a]${N}  Add a custom search path\n"
        printf "  ${W}[b]${N}  Back\n\n"
        print_sep; echo
        read -rp "  Choice: " ch
        case "${ch,,}" in
            a) _add_model_search_path; pick_model; return ;;
            *) return ;;
        esac
    fi

    local page=0 max_page=$(( (total - 1) / PAGE_SIZE ))

    while true; do
        clear_screen; echo
        printf "  ${C}${BOLD}🦙  Select Model${N}\n"
        printf "  ${D}%d model(s) found  •  page %d/%d${N}\n" "$total" "$(( page+1 ))" "$(( max_page+1 ))"
        echo; print_sep; echo

        # Current model highlight
        if [[ -n "$SELECTED_MODEL" ]]; then
            printf "  ${D}Active :${N}  ${G}%s${N}\n\n" "${SELECTED_MODEL##*/}"
        fi

        local start=$(( page * PAGE_SIZE ))
        local end=$(( start + PAGE_SIZE ))
        (( end > total )) && end=$total

        # Column widths
        printf "  ${D}%-4s  %-42s  %7s  %s${N}\n" "#" "Filename" "Size" "Quant"
        print_sep

        local i
        for (( i=start; i<end; i++ )); do
            local fname="${MODEL_LIST[$i]##*/}"
            local size="${MODEL_SIZES[$i]}"
            local quant="${MODEL_QUANTS[$i]}"
            local num=$(( i - start + 1 ))
            local active=""
            [[ "${MODEL_LIST[$i]}" == "$SELECTED_MODEL" ]] && active="${G}← active${N}"

            # Colour quant by precision class
            local qcol="${D}"
            case "${quant^^}" in
                Q2*|IQ1*|IQ2*)   qcol="${R}" ;;
                Q3*|IQ3*)        qcol="${Y}" ;;
                Q4*|IQ4*)        qcol="${C}" ;;
                Q5*|Q6*|Q8*)     qcol="${G}" ;;
                F16|BF16|F32)    qcol="${M}" ;;
            esac

            printf "  ${W}[%2d]${N}  %-42s  ${D}%7s${N}  ${qcol}%-12s${N}  %b\n" \
                   "$num" \
                   "${fname:0:42}" \
                   "$size" \
                   "$quant" \
                   "$active"
        done

        print_sep; echo
        printf "  ${W}[i]${N}  Model info / full path     "
        (( max_page > 0 )) && printf "  ${W}[n]${N} next page  ${W}[p]${N} prev page"
        printf "\n  ${W}[s]${N}  Search by name             "
        printf "  ${W}[r]${N} rescan\n"
        printf "  ${W}[a]${N}  Add search directory        "
        printf "  ${W}[b]${N} back / keep current\n\n"
        read -rp "  Choice: " ch; echo

        case "${ch,,}" in
            b|"") return ;;

            r) scan_models; total=${#MODEL_LIST[@]}
               max_page=$(( (total - 1) / PAGE_SIZE ))
               page=0; continue ;;

            n) (( page < max_page )) && (( page++ )); continue ;;
            p) (( page > 0 )) && (( page-- )); continue ;;

            s) _model_search_filter; return ;;
            a) _add_model_search_path; scan_models
               total=${#MODEL_LIST[@]}; max_page=$(( (total-1)/PAGE_SIZE ))
               page=0; continue ;;

            i) _show_model_info "$start"; continue ;;

            [0-9]|[0-9][0-9])
                local idx=$(( start + ch - 1 ))
                if (( ch >= 1 && idx < end && idx < total )); then
                    SELECTED_MODEL="${MODEL_LIST[$idx]}"
                    printf "  ${TICK} ${G}Selected:${N}  %s\n" "${SELECTED_MODEL##*/}"
                    printf "  ${D}%s${N}\n" "$SELECTED_MODEL"
                    sleep 0.8; return
                else
                    printf "  ${WARN} Invalid number.\n"; sleep 0.6
                fi ;;

            *) printf "  ${WARN} Invalid choice.\n"; sleep 0.5 ;;
        esac
    done
}

_show_model_info() {
    local start="$1"
    read -rp "  Enter number to inspect: " n
    local idx=$(( start + n - 1 ))
    local total=${#MODEL_LIST[@]}
    if [[ "$n" =~ ^[0-9]+$ ]] && (( idx >= 0 && idx < total )); then
        local path="${MODEL_LIST[$idx]}"
        echo
        printf "  ${W}Filename :${N}  %s\n"     "${path##*/}"
        printf "  ${W}Full path:${N}  %s\n"     "$path"
        printf "  ${W}Size     :${N}  %s\n"     "${MODEL_SIZES[$idx]}"
        printf "  ${W}Quant    :${N}  %s\n"     "${MODEL_QUANTS[$idx]}"
        # Try to get modified date
        local mdate; mdate=$(stat -c '%y' "$path" 2>/dev/null | cut -d' ' -f1) || true
        [[ -n "$mdate" ]] && printf "  ${W}Modified :${N}  %s\n" "$mdate"
        echo
        press_enter
    fi
}

_model_search_filter() {
    read -rp "  Search term: " term
    [[ -z "$term" ]] && { pick_model; return; }
    local -a FLIST=() FSIZES=() FQUANTS=()
    for i in "${!MODEL_LIST[@]}"; do
        local fname="${MODEL_LIST[$i]##*/}"
        if grep -qi "$term" <<< "$fname" 2>/dev/null; then
            FLIST+=("${MODEL_LIST[$i]}")
            FSIZES+=("${MODEL_SIZES[$i]}")
            FQUANTS+=("${MODEL_QUANTS[$i]}")
        fi
    done
    if [[ ${#FLIST[@]} -eq 0 ]]; then
        printf "\n  ${WARN} No models matching '${term}'.\n"; sleep 1
        pick_model; return
    fi
    # Temporarily swap into filtered view
    local SAVE_ML=("${MODEL_LIST[@]}") SAVE_MS=("${MODEL_SIZES[@]}") SAVE_MQ=("${MODEL_QUANTS[@]}")
    MODEL_LIST=("${FLIST[@]}"); MODEL_SIZES=("${FSIZES[@]}"); MODEL_QUANTS=("${FQUANTS[@]}")
    pick_model   # recurse with filtered list
    # Restore full list (selected model is already set)
    MODEL_LIST=("${SAVE_ML[@]}"); MODEL_SIZES=("${SAVE_MS[@]}"); MODEL_QUANTS=("${SAVE_MQ[@]}")
}

_add_model_search_path() {
    echo
    read -rp "  Enter directory to add: " newdir
    newdir="${newdir/#\~/$HOME}"
    if [[ -d "$newdir" ]]; then
        MODEL_SEARCH_DIRS+=("$newdir")
        printf "  ${TICK} Added: %s\n" "$newdir"; sleep 0.6
    else
        printf "  ${WARN} Directory not found: %s\n" "$newdir"; sleep 0.8
    fi
}

# ── llama-server binary finder ────────────────────────────────────────────────
find_llama_binaries() {
    local -a found=()
    local -a names=("llama-server" "llama-cli" "llama-bench" "server" "main")
    for dir in "${LLAMA_BINARY_SEARCH[@]}"; do
        [[ -d "$dir" ]] || continue
        for name in "${names[@]}"; do
            local bin="$dir/$name"
            [[ -x "$bin" ]] && found+=("$bin")
        done
    done
    # Also check PATH
    for name in "llama-server" "llama-cli"; do
        local p; p=$(command -v "$name" 2>/dev/null) && found+=("$p")
    done
    # Deduplicate
    local -A seen=()
    local -a unique=()
    for b in "${found[@]}"; do
        local real; real=$(readlink -f "$b" 2>/dev/null || echo "$b")
        [[ -z "${seen[$real]+x}" ]] && { unique+=("$b"); seen[$real]=1; }
    done
    printf '%s\n' "${unique[@]}"
}

pick_llama_binary() {
    header
    printf "  ${W}${BOLD}Select llama.cpp Binary${N}\n\n"
    printf "  ${D}Searching…${N}\n"

    local -a bins=()
    while IFS= read -r line; do bins+=("$line"); done < <(find_llama_binaries)

    if [[ ${#bins[@]} -eq 0 ]]; then
        printf "\n  ${CROSS} No llama-server / llama-cli found.\n\n"
        printf "  ${D}Searched:${N}\n"
        for d in "${LLAMA_BINARY_SEARCH[@]}"; do
            printf "    ${D}%-50s${N}\n" "$d"
        done
        echo
        printf "  ${W}[c]${N}  Enter custom path\n"
        printf "  ${W}[b]${N}  Back\n\n"; print_sep; echo
        read -rp "  Choice: " ch
        case "${ch,,}" in
            c) _custom_binary_path ;;
            *) return ;;
        esac
        return
    fi

    echo; print_sep
    printf "\n  ${D}%-4s  %-22s  %s${N}\n" "#" "Name" "Path"
    print_sep
    local i=1
    for b in "${bins[@]}"; do
        local name="${b##*/}"
        local active=""; [[ "$b" == "$SELECTED_LLAMA_BIN" ]] && active="${G}← active${N}"
        printf "  ${W}[%2d]${N}  %-22s  ${D}%s${N}  %b\n" "$i" "$name" "$b" "$active"
        (( i++ ))
    done
    echo
    printf "  ${W}[c]${N}  Enter custom path\n"
    printf "  ${W}[b]${N}  Back\n\n"; print_sep; echo
    read -rp "  Choice: " ch

    case "${ch,,}" in
        b|"") return ;;
        c)  _custom_binary_path ;;
        [0-9]|[0-9][0-9])
            if (( ch >= 1 && ch <= ${#bins[@]} )); then
                SELECTED_LLAMA_BIN="${bins[$((ch-1))]}"
                printf "  ${TICK} ${G}Selected:${N}  %s\n" "${SELECTED_LLAMA_BIN##*/}"
                sleep 0.7
            else
                printf "  ${WARN} Invalid choice.\n"; sleep 0.6
            fi ;;
        *) printf "  ${WARN} Invalid choice.\n"; sleep 0.6 ;;
    esac
}

_custom_binary_path() {
    echo
    read -rp "  Full path to binary: " p
    p="${p/#\~/$HOME}"
    if [[ -x "$p" ]]; then
        SELECTED_LLAMA_BIN="$p"
        printf "  ${TICK} Set: %s\n" "$p"; sleep 0.6
    else
        printf "  ${WARN} Not found or not executable: %s\n" "$p"; sleep 0.8
    fi
}

# ── INI config picker ─────────────────────────────────────────────────────────
pick_ini_config() {
    header
    printf "  ${W}${BOLD}Select Config (.ini)${N}\n\n"

    local -a ini_files=()
    while IFS= read -r -d '' f; do ini_files+=("$f")
    done < <(find "$SELECTED_CONFIG_DIR" -maxdepth 1 -name "*.ini" -print0 2>/dev/null | sort -z)

    # Also check SCRIPT_DIR/configs if different
    if [[ "$SELECTED_CONFIG_DIR" != "$SCRIPT_DIR/configs" && -d "$SCRIPT_DIR/configs" ]]; then
        while IFS= read -r -d '' f; do ini_files+=("$f")
        done < <(find "$SCRIPT_DIR/configs" -maxdepth 1 -name "*.ini" -print0 2>/dev/null | sort -z)
    fi

    local total=${#ini_files[@]}

    if [[ $total -eq 0 ]]; then
        printf "  ${WARN} No .ini files found in:  ${C}%s${N}\n\n" "$SELECTED_CONFIG_DIR"
        printf "  ${W}[n]${N}  Open config manager to create one (start the web UI)\n"
        printf "  ${W}[b]${N}  Back\n\n"; print_sep; echo
        read -rp "  Choice: " ch
        case "${ch,,}" in n) start_app; return ;; *) return ;; esac
    fi

    print_sep
    printf "\n  ${D}%-4s  %-30s  %s${N}\n" "#" "Config name" "Directory"
    print_sep

    local i=1
    for f in "${ini_files[@]}"; do
        local fname="${f##*/}"
        local dir="${f%/*}"
        local active=""; [[ "$f" == "$SELECTED_INI_CONFIG" ]] && active="${G}← active${N}"
        printf "  ${W}[%2d]${N}  %-30s  ${D}%s${N}  %b\n" "$i" "$fname" "${dir}" "$active"
        (( i++ ))
    done
    echo
    printf "  ${W}[n]${N}  None (use model path only)\n"
    printf "  ${W}[b]${N}  Back\n\n"; print_sep; echo
    read -rp "  Choice: " ch

    case "${ch,,}" in
        b|"") return ;;
        n) SELECTED_INI_CONFIG=""
           printf "  ${TICK} No config file selected.\n"; sleep 0.6 ;;
        [0-9]|[0-9][0-9])
            if (( ch >= 1 && ch <= total )); then
                SELECTED_INI_CONFIG="${ini_files[$((ch-1))]}"
                printf "  ${TICK} ${G}Selected:${N}  %s\n" "${SELECTED_INI_CONFIG##*/}"
                sleep 0.7
            else
                printf "  ${WARN} Invalid.\n"; sleep 0.6
            fi ;;
        *) printf "  ${WARN} Invalid.\n"; sleep 0.6 ;;
    esac
}

# ── Dependency report ─────────────────────────────────────────────────────────
show_deps() {
    header; printf "  ${W}${BOLD}Dependency Check${N}\n\n"; assess_deps

    printf "  ${D}Required${N}\n\n"
    if $DEP_BINARY; then
        local sz; sz=$(du -sh "$BINARY_PATH" 2>/dev/null | cut -f1)
        status_row "$TICK" "Config manager binary" "${G}found${N} ${D}(${sz})${N}"
    else
        status_row "$CROSS" "Config manager binary" "${D}not found — will auto-build${N}"
    fi
    if $DEP_GO; then
        local gv; gv=$(go version | grep -oE 'go[0-9]+\.[0-9.]+' | head -1)
        status_row "$TICK" "Go toolchain" "${G}${gv}${N}"
    else
        if command -v go &>/dev/null; then
            local gv; gv=$(go version | grep -oE 'go[0-9]+\.[0-9.]+' | head -1)
            status_row "$CROSS" "Go toolchain" "${Y}${gv} — need ≥${MIN_GO_MAJOR}.${MIN_GO_MINOR}${N}"
        else
            status_row "$CROSS" "Go toolchain" "${R}not installed${N}"
        fi
    fi
    $DEP_SOURCE && status_row "$TICK" "Source files" "${G}main.go + go.mod${N}" \
               || status_row "$CROSS" "Source files" "${R}missing — cannot build${N}"

    printf "\n  ${D}Optional${N}\n\n"
    $DEP_CURL && status_row "$TICK" "curl"           "${D}health-check enabled${N}" \
              || status_row "$WARN" "curl"           "${D}not found${N}"
    if $DEP_XDGO || $DEP_OPEN; then
        local op; $DEP_XDGO && op="xdg-open" || op="open"
        status_row "$TICK" "Browser opener"          "${D}${op}${N}"
    else
        status_row "$WARN" "xdg-open / open"         "${D}browser won't auto-open${N}"
    fi

    # llama-server
    printf "\n  ${D}llama.cpp inference binary${N}\n\n"
    if [[ -n "$SELECTED_LLAMA_BIN" && -x "$SELECTED_LLAMA_BIN" ]]; then
        status_row "$TICK" "llama-server" "${G}${SELECTED_LLAMA_BIN}${N}"
    else
        local found; found=$(find_llama_binaries | head -1)
        if [[ -n "$found" ]]; then
            status_row "$WARN" "llama-server" "${Y}not selected — found: ${found}${N}"
        else
            status_row "$WARN" "llama-server" "${D}not found (optional for inference)${N}"
        fi
    fi

    echo; print_sep; echo
    if $CAN_RUN; then
        printf "  ${TICK}  ${G}All requirements met.${N}\n"
    else
        printf "  ${CROSS}  ${R}Requirements missing.${N}\n\n"
        printf "  ${W}[f]${N}  ${G}${BOLD}Auto-fix now${N}  (install Go + build binary)\n"
        printf "  ${W}[b]${N}  Back\n\n"
        print_sep; echo
        read -rp "  Choice [f/b]: " ch
        case "${ch,,}" in
            f) auto_fix_deps; return ;;
            *) return ;;
        esac
    fi
    echo; press_enter
}

# ── Build ─────────────────────────────────────────────────────────────────────
build_binary() {
    header; printf "  ${W}${BOLD}Build Config Manager${N}\n\n"; print_sep; echo
    assess_deps

    if ! $DEP_SOURCE; then
        printf "  ${CROSS} Source files not found in: %s\n\n" "$SCRIPT_DIR"
        press_enter; return
    fi

    # Auto-install Go if missing
    if ! $DEP_GO; then
        printf "  ${WARN} Go toolchain missing — attempting auto-install…\n\n"
        if ! sudo -v 2>/dev/null; then
            printf "  ${CROSS} sudo not available. Install Go manually and retry.\n"
            printf "  ${D}  https://go.dev/doc/install${N}\n"
            press_enter; return
        fi
        _install_go
        assess_deps
        if ! $DEP_GO; then
            printf "\n  ${CROSS} Could not install Go. See messages above.\n"
            press_enter; return
        fi
        echo
    fi

    printf "  ${ARROW} ${C}go build -o %s .${N}\n\n" "$BINARY_NAME"
    if (cd "$SCRIPT_DIR" && go build -o "$BINARY_NAME" . 2>&1); then
        DEP_BINARY=true; CAN_RUN=true
        printf "\n  ${TICK} ${G}${BOLD}Build OK${N}  →  %s\n" "$BINARY_PATH"
    else
        printf "\n  ${CROSS} ${R}Build failed — check compiler output above.${N}\n"
    fi
    press_enter
}

# ── Port checker / picker ─────────────────────────────────────────────────────
port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnH "sport = :${port}" 2>/dev/null | grep -q ":${port}" && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    else
        (echo >/dev/tcp/127.0.0.1/"$port") &>/dev/null && return 0
    fi
    return 1
}

pick_port() {
    header; printf "  ${W}${BOLD}Select Port${N}\n\n"
    printf "  Current: ${C}%s${N}\n\n" "$SELECTED_PORT"
    printf "  ${W}[1]${N}  7070  ${D}(default)${N}\n"
    printf "  ${W}[2]${N}  8080\n"
    printf "  ${W}[3]${N}  9090\n"
    printf "  ${W}[c]${N}  Custom\n"
    printf "  ${W}[b]${N}  Back\n\n"; print_sep; echo
    read -rp "  Choice: " ch
    case "$ch" in
        1) SELECTED_PORT=7070 ;;
        2) SELECTED_PORT=8080 ;;
        3) SELECTED_PORT=9090 ;;
        [cC])
            echo; read -rp "  Port (1024–65535): " p
            if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1024 && p <= 65535 )); then
                SELECTED_PORT="$p"
            else printf "  ${WARN} Invalid.\n"; sleep 0.8; return; fi ;;
        [bB]) return ;;
        *) printf "  ${WARN} Invalid.\n"; sleep 0.8; return ;;
    esac
    printf "  ${TICK} Port → ${C}%s${N}\n" "$SELECTED_PORT"; sleep 0.6
}

pick_config_dir() {
    header; printf "  ${W}${BOLD}Select Config Directory${N}\n\n"
    printf "  Current: ${C}%s${N}\n\n" "$SELECTED_CONFIG_DIR"

    local -a CANDIDATES=("$DEFAULT_CONFIG_DIR")
    while IFS= read -r d; do
        [[ "$d" != "$DEFAULT_CONFIG_DIR" ]] && CANDIDATES+=("$d")
    done < <(find "$SCRIPT_DIR" -maxdepth 2 -name "*.ini" -printf '%h\n' 2>/dev/null | sort -u)

    local -a UNIQUE=(); declare -A SEEN=()
    for c in "${CANDIDATES[@]}"; do
        [[ -z "${SEEN[$c]+x}" ]] && { UNIQUE+=("$c"); SEEN[$c]=1; }
    done

    local i=1
    for d in "${UNIQUE[@]}"; do
        local count=0; [[ -d "$d" ]] && count=$(find "$d" -maxdepth 1 -name "*.ini" 2>/dev/null | wc -l)
        local note
        if [[ "$d" == "$SELECTED_CONFIG_DIR" ]]; then note="${G}← current${N}"
        elif [[ -d "$d" ]]; then note="${D}${count} .ini file(s)${N}"
        else note="${D}(will be created)${N}"; fi
        printf "  ${W}[%d]${N}  %-50s  %b\n" "$i" "$d" "$note"
        (( i++ ))
    done
    echo
    printf "  ${W}[c]${N}  Custom path\n  ${W}[b]${N}  Back\n\n"; print_sep; echo
    read -rp "  Choice: " ch
    case "$ch" in
        [bB]) return ;;
        [cC]) echo; read -rp "  Path: " p; p="${p/#\~/$HOME}"
              [[ -n "$p" ]] && { SELECTED_CONFIG_DIR="$p"; printf "  ${TICK} Set: %s\n" "$p"; sleep 0.6; } ;;
        *)
            if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#UNIQUE[@]} )); then
                SELECTED_CONFIG_DIR="${UNIQUE[$((ch-1))]}"
                printf "  ${TICK} Set: %s\n" "$SELECTED_CONFIG_DIR"; sleep 0.6
            else printf "  ${WARN} Invalid.\n"; sleep 0.8; fi ;;
    esac
}

# ── Health check ──────────────────────────────────────────────────────────────
wait_for_ready() {
    local port="$1" attempts=15 i
    $DEP_CURL || { sleep 1; return 0; }
    for (( i=1; i<=attempts; i++ )); do
        curl -sf "http://127.0.0.1:${port}/api/files" &>/dev/null && return 0
        printf "."
        sleep 0.3
    done
    return 1
}

open_browser() {
    if $DEP_XDGO; then xdg-open "$1" &>/dev/null & return; fi
    if $DEP_OPEN;  then open     "$1" &>/dev/null & return; fi
}

# ── Start config manager (Go web app) ─────────────────────────────────────────
start_app() {
    header; printf "  ${W}${BOLD}Start Config Manager${N}\n\n"; assess_deps

    # ── Ensure binary is available ──
    if ! $DEP_BINARY; then
        if $DEP_GO && $DEP_SOURCE; then
            # Go is here, just build
            printf "  ${WARN} Binary not built yet — building now…\n\n"
            if ! (cd "$SCRIPT_DIR" && go build -o "$BINARY_NAME" . 2>&1); then
                printf "  ${CROSS} Build failed.\n"; press_enter; return
            fi
            DEP_BINARY=true
            printf "  ${TICK} Built successfully.\n\n"
        elif $DEP_SOURCE; then
            # Have source but no Go — auto-install Go then build
            printf "  ${WARN} Go not found — attempting auto-install (requires internet + sudo)…\n\n"
            if ! sudo -v 2>/dev/null; then
                printf "  ${CROSS} sudo unavailable. Run '${W}[7] Check Dependencies${N}' for options.\n"
                press_enter; return
            fi
            _install_go
            assess_deps
            if ! $DEP_GO; then
                printf "  ${CROSS} Could not install Go. See '${W}[7] Check Dependencies → Auto-fix${N}'.\n"
                press_enter; return
            fi
            printf "\n  ${ARROW} Building binary…\n\n"
            if ! (cd "$SCRIPT_DIR" && go build -o "$BINARY_NAME" . 2>&1); then
                printf "  ${CROSS} Build failed.\n"; press_enter; return
            fi
            DEP_BINARY=true
            printf "  ${TICK} Built successfully.\n\n"
        else
            printf "  ${CROSS} No binary, no Go toolchain, and source files missing.\n"
            printf "  ${D}  Place main.go and go.mod in: %s${N}\n" "$SCRIPT_DIR"
            press_enter; return
        fi
    fi

    # ── Port ──
    if port_in_use "$SELECTED_PORT"; then
        printf "  ${WARN} Port %s is already in use.\n" "$SELECTED_PORT"
        printf "  ${D}  Use '${W}[9] Directory & Port${N}${D}' to pick a free port.${N}\n"
        press_enter; return
    fi

    mkdir -p "$SELECTED_CONFIG_DIR"

    printf "  ${D}Config dir :${N}  ${C}%s${N}\n" "$SELECTED_CONFIG_DIR"
    printf "  ${D}Port       :${N}  ${C}%s${N}\n" "$SELECTED_PORT"
    printf "  ${D}URL        :${N}  ${C}http://localhost:%s${N}\n" "$SELECTED_PORT"
    echo; print_sep; echo

    "$BINARY_PATH" "$SELECTED_CONFIG_DIR" "$SELECTED_PORT" &
    APP_PID=$!
    printf "  ${D}PID: %s${N}\n\n" "$APP_PID"

    printf "  Waiting for server"
    if wait_for_ready "$SELECTED_PORT"; then
        printf "\n  ${TICK} ${G}Ready!${N}\n"
    else
        printf "\n  ${WARN} Still starting — check manually.\n"
    fi

    echo
    printf "  ${W}Open:${N}  ${B}http://localhost:%s${N}\n\n" "$SELECTED_PORT"
    ($DEP_XDGO || $DEP_OPEN) && open_browser "http://localhost:${SELECTED_PORT}"

    print_sep; echo
    printf "  ${W}[q]${N}  Stop server & return\n"
    printf "  ${W}[b]${N}  Keep running, return to menu\n\n"
    read -rp "  Choice [q/b]: " ch
    case "${ch,,}" in
        q|quit) kill "$APP_PID" 2>/dev/null && printf "  ${TICK} Stopped.\n" || true; sleep 0.5 ;;
        *)      printf "  ${TICK} Running in background (PID %s).\n" "$APP_PID"; sleep 0.8 ;;
    esac
}

# ── Launch llama-server with selected model + config ──────────────────────────
launch_inference() {
    header; printf "  ${W}${BOLD}Launch llama-server${N}\n\n"

    # Guard: need a binary
    if [[ -z "$SELECTED_LLAMA_BIN" ]] || ! [[ -x "$SELECTED_LLAMA_BIN" ]]; then
        printf "  ${WARN} No llama-server binary selected.\n"
        printf "  ${D}  Use 'Select llama binary' from the menu.${N}\n"
        press_enter; return
    fi

    # Guard: need a model
    if [[ -z "$SELECTED_MODEL" ]] || ! [[ -f "$SELECTED_MODEL" ]]; then
        printf "  ${WARN} No model selected.\n"
        printf "  ${D}  Use 'Select Model' from the menu.${N}\n"
        press_enter; return
    fi

    # Build argument list
    local -a args=()
    args+=("--model" "$SELECTED_MODEL")

    # Fold in the .ini config if one is selected
    if [[ -n "$SELECTED_INI_CONFIG" && -f "$SELECTED_INI_CONFIG" ]]; then
        # Parse key=value pairs from .ini and turn them into CLI flags
        # Skip lines that are blank, comments, or section headers
        while IFS='=' read -r key val; do
            key="${key%%#*}"; key="${key%% *}"; key="${key## *}"
            val="${val%%#*}"; val="${val%%  *}"; val="${val## }"
            [[ -z "$key" || "$key" == \[* ]] && continue
            # Skip 'model' — already set
            [[ "$key" == "model" ]] && continue
            # Boolean flags: true/1 → add flag; false/0 → skip entirely
            if [[ "${val,,}" == "true" || "$val" == "1" ]]; then
                args+=("--${key}")
            elif [[ "${val,,}" == "false" || "$val" == "0" ]]; then
                : # explicitly disabled — omit
            elif [[ -n "$val" ]]; then
                args+=("--${key}" "$val")
            fi
        done < <(grep -v '^\s*[;#\[]' "$SELECTED_INI_CONFIG" 2>/dev/null | grep '=')
    fi

    # Summary
    printf "  ${D}Binary :${N}  ${C}%s${N}\n" "${SELECTED_LLAMA_BIN##*/}"
    printf "  ${D}Model  :${N}  ${C}%s${N}\n" "${SELECTED_MODEL##*/}"
    printf "  ${D}Size   :${N}  ${D}%s${N}\n" "$(human_size "$SELECTED_MODEL")"
    printf "  ${D}Quant  :${N}  ${D}%s${N}\n" "$(parse_quant "$SELECTED_MODEL")"
    if [[ -n "$SELECTED_INI_CONFIG" ]]; then
        printf "  ${D}Config :${N}  ${C}%s${N}\n" "${SELECTED_INI_CONFIG##*/}"
    else
        printf "  ${D}Config :${N}  ${D}(none)${N}\n"
    fi
    echo
    printf "  ${D}Command:${N}\n"
    printf "    ${C}%s" "${SELECTED_LLAMA_BIN##*/}"
    for a in "${args[@]}"; do printf " %s" "$a"; done
    printf "${N}\n\n"

    print_sep; echo
    printf "  ${W}[y]${N}  Launch now\n"
    printf "  ${W}[e]${N}  Edit args before launching\n"
    printf "  ${W}[b]${N}  Back\n\n"
    read -rp "  Choice: " ch

    case "${ch,,}" in
        b|"") return ;;
        e)
            local joined_args="${args[*]}"
            echo
            read -rp "  Args: " -e -i "$joined_args" edited_args
            # shellcheck disable=SC2206
            IFS=' ' read -ra args <<< "$edited_args"
            ;;
        y|"") : ;;  # fall through
        *) printf "  ${WARN} Invalid.\n"; sleep 0.6; return ;;
    esac

    echo
    printf "  ${ARROW} Launching ${W}%s${N}…\n\n" "${SELECTED_LLAMA_BIN##*/}"
    printf "  ${D}Press Ctrl+C to stop.${N}\n\n"
    print_sep; echo

    # Run in foreground so user sees output
    "$SELECTED_LLAMA_BIN" "${args[@]}" || true
    echo; press_enter
}

# ── Stop any running instance ─────────────────────────────────────────────────
stop_app() {
    header; printf "  ${W}${BOLD}Stop Running Instances${N}\n\n"
    local pids; pids=$(pgrep -f "$BINARY_NAME" 2>/dev/null || true)
    local llama_pids=""
    [[ -n "$SELECTED_LLAMA_BIN" ]] && llama_pids=$(pgrep -f "${SELECTED_LLAMA_BIN##*/}" 2>/dev/null || true)

    if [[ -z "$pids" && -z "$llama_pids" ]]; then
        printf "  ${D}No matching processes found.${N}\n"; press_enter; return
    fi

    [[ -n "$pids"       ]] && printf "  Config manager PID(s): ${W}%s${N}\n" "$pids"
    [[ -n "$llama_pids" ]] && printf "  llama-server   PID(s): ${W}%s${N}\n" "$llama_pids"
    echo; read -rp "  Kill all listed? [y/N] " yn
    if [[ "${yn,,}" == y ]]; then
        for p in $pids $llama_pids; do
            kill "$p" 2>/dev/null && printf "  ${TICK} Killed PID %s\n" "$p" || true
        done
    else printf "  ${D}Aborted.${N}\n"; fi
    press_enter
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
    # ── First-run auto-fix: if binary is not ready, offer to fix immediately ──
    assess_deps
    if ! $CAN_RUN; then
        clear
        echo
        printf "  ${C}${BOLD}🦙  llama.cpp Config Manager${N}\n\n"
        printf "  ${Y}${BOLD}First-run setup needed.${N}\n\n"
        if $DEP_SOURCE; then
            printf "  Source files found but Go toolchain / binary missing.\n\n"
            printf "  ${W}[y]${N}  ${G}${BOLD}Auto-install Go and build binary now${N}\n"
            printf "  ${W}[n]${N}  Continue to main menu anyway\n\n"
            read -rp "  Choice [y/n]: " ch
            [[ "${ch,,}" == y ]] && auto_fix_deps
        else
            printf "  ${R}Source files (main.go / go.mod) not found in:${N}\n"
            printf "  ${D}  %s${N}\n\n" "$SCRIPT_DIR"
            printf "  Place the source files there and re-run this script.\n\n"
            read -rp "  Press Enter to continue to menu… " _
        fi
    fi

    while true; do
        assess_deps
        load_paths_json
        header

        # ── Status strip ──
        if $DEP_BINARY; then
            printf "  ${TICK} Config mgr  ${G}ready${N}\n"
        elif $DEP_GO && $DEP_SOURCE; then
            printf "  ${WARN} Config mgr  ${Y}will build on first start${N}\n"
        elif $DEP_SOURCE; then
            printf "  ${CROSS} Config mgr  ${R}Go missing — press 7 to auto-fix${N}\n"
        else
            printf "  ${CROSS} Config mgr  ${R}source not found${N}\n"
        fi

        if port_in_use "$SELECTED_PORT"; then
            printf "  ${WARN} Port %-6s  ${Y}in use${N}\n" "$SELECTED_PORT"
        else
            printf "  ${TICK} Port %-6s  ${D}free${N}\n" "$SELECTED_PORT"
        fi

        if [[ -f "$PATHS_JSON" ]]; then
            printf "  ${TICK} paths.json  ${D}%d model dirs · %d binary dirs${N}\n" \
                "${#MODEL_SEARCH_DIRS[@]}" "${#LLAMA_BINARY_SEARCH[@]}"
        else
            printf "  ${D}  paths.json  using built-in defaults${N}\n"
        fi

        if [[ -n "$SELECTED_MODEL" && -f "$SELECTED_MODEL" ]]; then
            local mname="${SELECTED_MODEL##*/}"
            printf "  ${TICK} Model       ${G}%-34s${N}  ${D}%s  %s${N}\n" \
                "${mname:0:34}" "$(human_size "$SELECTED_MODEL")" "$(parse_quant "$SELECTED_MODEL")"
        else
            printf "  ${WARN} Model       ${D}none selected${N}\n"
        fi

        if [[ -n "$SELECTED_INI_CONFIG" && -f "$SELECTED_INI_CONFIG" ]]; then
            printf "  ${TICK} Config      ${G}%s${N}\n" "${SELECTED_INI_CONFIG##*/}"
        else
            printf "  ${D}  Config      none${N}\n"
        fi

        if [[ -n "$SELECTED_LLAMA_BIN" && -x "$SELECTED_LLAMA_BIN" ]]; then
            printf "  ${TICK} llama bin   ${G}%s${N}\n" "${SELECTED_LLAMA_BIN##*/}"
        else
            printf "  ${D}  llama bin   not selected${N}\n"
        fi

        echo; print_sep; echo
        printf "  ${W}${BOLD}Main Menu${N}\n\n"
        printf "  ${W}[1]${N}  ${M}${BOLD}▶  Select Model (.gguf)${N}\n"
        printf "  ${W}[2]${N}  ${M}   Select Config (.ini)${N}\n"
        printf "  ${W}[3]${N}  ${M}   Select llama binary${N}\n"
        printf "  ${W}[4]${N}  ${G}${BOLD}▶  Launch llama-server${N}\n"
        printf "  ${W}[5]${N}  ${C}⊞  Start Config Manager (web UI)${N}\n"
        printf "  ${W}[6]${N}     Reload paths.json\n"
        printf "  ${W}[7]${N}  ${Y}⚙  Check / Auto-fix Dependencies${N}\n"
        printf "  ${W}[8]${N}     Build Config Manager\n"
        printf "  ${W}[9]${N}     Config Directory / Port\n"
        printf "  ${W}[0]${N}  ${R}■  Stop Running Instances${N}\n"
        printf "  ${W}[q]${N}  ${D}Quit${N}\n"
        echo; print_sep; echo
        read -rp "  Choice: " choice; echo

        case "${choice,,}" in
            1)  pick_model ;;
            2)  pick_ini_config ;;
            3)  pick_llama_binary ;;
            4)  launch_inference ;;
            5)  start_app ;;
            6)  load_paths_json
                printf "  ${TICK} Paths reloaded: ${D}%d model dirs · %d binary dirs${N}\n" \
                    "${#MODEL_SEARCH_DIRS[@]}" "${#LLAMA_BINARY_SEARCH[@]}"
                sleep 1 ;;
            7)  show_deps ;;
            8)  build_binary ;;
            9)  _pick_dir_port_submenu ;;
            0)  stop_app ;;
            q|quit|exit) break ;;
            *)  printf "  ${WARN} Invalid choice.\n"; sleep 0.8 ;;
        esac
    done
    echo; printf "  ${D}Goodbye.${N}\n\n"
}

# ── Config dir / port sub-menu ────────────────────────────────────────────────
_pick_dir_port_submenu() {
    header
    printf "  ${W}${BOLD}Directory & Port${N}\n\n"
    printf "  ${W}[1]${N}  Select Config Directory  ${D}(current: %s)${N}\n" "$SELECTED_CONFIG_DIR"
    printf "  ${W}[2]${N}  Select Port              ${D}(current: %s)${N}\n" "$SELECTED_PORT"
    printf "  ${W}[b]${N}  Back\n\n"; print_sep; echo
    read -rp "  Choice: " ch
    case "${ch,,}" in
        1) pick_config_dir ;;
        2) pick_port ;;
        *) return ;;
    esac
}

# ── Entry ──────────────────────────────────────────────────────────────────────
main_menu
