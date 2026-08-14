#!/usr/bin/env bash
#
# OpenVINO Runtime manager for Ubuntu 26.04 (x86_64)
# Archive install per: https://docs.openvino.ai/2026/get-started/install-openvino/install-openvino-archive-linux.html
#
# Handles the Ubuntu 26.04 / Python 3.14 mismatch: the archive's compiled
# bindings only ship up to cpython-313, so this builds a venv on a
# supported interpreter (3.10-3.13) rather than touching system Python.
#
# Usage:
#   sudo ./openvino_manager.sh          # interactive menu
#   sudo ./openvino_manager.sh install  # non-interactive
#   sudo ./openvino_manager.sh uninstall
#   sudo ./openvino_manager.sh verify
#
set -euo pipefail

# ---- package metadata (update if you target a different release) ----
OV_VERSION="2026.2.0"
OV_BUILD="21903.52ddc073857"
OV_MAJOR_MINOR="${OV_VERSION%.*}"          # 2026.2
OV_MAJOR="${OV_MAJOR_MINOR%%.*}"           # 2026
INSTALL_PREFIX="/opt/intel"

PKG_NAME="openvino_toolkit_ubuntu24_${OV_VERSION}.${OV_BUILD}_x86_64.tgz"
PKG_URL="https://storage.openvinotoolkit.org/repositories/openvino/packages/${OV_MAJOR_MINOR}/linux/${PKG_NAME}"

INSTALL_DIR="${INSTALL_PREFIX}/openvino_${OV_VERSION}"
LINK_DIR="${INSTALL_PREFIX}/openvino_${OV_MAJOR}"
SETUPVARS="${LINK_DIR}/setupvars.sh"

# Python versions the 2026.2.0 archive ships compiled bindings for,
# newest first. Adjust if a future archive build adds/drops versions.
SUPPORTED_PY_VERSIONS=(3.13 3.12 3.11 3.10)

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
RC_FILE="${USER_HOME}/.bashrc"
VENV_DIR="${USER_HOME}/.local/share/openvino-venv"
WORK_DIR=""
cleanup_work_dir() { [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"; return 0; }
trap cleanup_work_dir EXIT

# ---- OVMS (OpenVINO Model Server) ----
OVMS_VERSION="2026.2.1"
OVMS_PKG_NAME="ovms_ubuntu24_${OVMS_VERSION}_python_off.tar.gz"
OVMS_PKG_URL="https://github.com/openvinotoolkit/model_server/releases/download/v${OVMS_VERSION}/${OVMS_PKG_NAME}"
OVMS_INSTALL_DIR="/opt/ovms"
OVMS_BIN="${OVMS_INSTALL_DIR}/ovms/bin/ovms"
OVMS_LIB="${OVMS_INSTALL_DIR}/ovms/lib"
MODEL_REPO_DIR="${USER_HOME}/ov-models"
OVMS_CONFIG_PATH="${MODEL_REPO_DIR}/config_all.json"
OVMS_STATE_DIR="${USER_HOME}/.local/share/ovms"
OVMS_PID_FILE="${OVMS_STATE_DIR}/ovms.pid"
OVMS_LOG_FILE="${OVMS_STATE_DIR}/ovms.log"
OVMS_DEFAULT_PORT=8000

# Ubuntu 26.04 dropped the libxml2.so.2 / ICU 74 sonames the ubuntu24
# baremetal tarball links against but doesn't bundle (upstream issue
# openvinotoolkit/model_server#4362). This lists what to check for.
OVMS_KNOWN_MISSING_LIBS=(libxml2.so.2 libicuuc.so.74 libicudata.so.74 libicui18n.so.74)

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run this with sudo."; }

as_user() { sudo -u "$REAL_USER" -H bash -c "$1"; }

# Runs a command in the background and prints a periodic heartbeat while it's
# alive, for steps that can run silently for a long time (apt-get, pip,
# optimum-cli quantization/conversion — which can genuinely take hours on a
# large model). Prints full lines (not \r-overwrites) so it doesn't fight
# with a wrapped tool's own progress bar (curl, ovms's native pull meter).
# Preserves the wrapped command's real exit status.
with_heartbeat() {
    local msg="$1"; shift
    local start=$SECONDS
    "$@" &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 30
        kill -0 "$pid" 2>/dev/null || break
        local elapsed=$((SECONDS - start))
        printf '[*] %s — still running (%dm%02ds elapsed)\n' "$msg" $((elapsed / 60)) $((elapsed % 60))
    done
    local rc
    if wait "$pid"; then rc=0; else rc=$?; fi
    local elapsed=$((SECONDS - start))
    if [[ $rc -eq 0 ]]; then
        printf '[*] %s — done (%dm%02ds)\n' "$msg" $((elapsed / 60)) $((elapsed % 60))
    else
        printf '[!] %s — failed after %dm%02ds (exit %d)\n' "$msg" $((elapsed / 60)) $((elapsed % 60)) "$rc"
    fi
    return $rc
}

# ---------------------------------------------------------------------
# Python detection / venv bootstrap
# ---------------------------------------------------------------------
find_supported_python() {
    for v in "${SUPPORTED_PY_VERSIONS[@]}"; do
        if command -v "python${v}" >/dev/null 2>&1; then
            echo "python${v}"
            return 0
        fi
    done
    return 1
}

install_python_via_deadsnakes() {
    local target="python${SUPPORTED_PY_VERSIONS[1]}"   # 3.12: broad compat
    log "No supported Python found. Installing ${target} via deadsnakes PPA..."
    apt-get update -y
    apt-get install -y software-properties-common
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update -y
    with_heartbeat "apt-get install ${target}" apt-get install -y "${target}" "${target}-venv" "${target}-dev" \
        || die "deadsnakes install failed (PPA may not have this Ubuntu release yet). Install pyenv and a 3.10-3.13 build manually, then re-run."
}

setup_python_env() {
    local py_bin
    py_bin="$(find_supported_python || true)"

    if [[ -z "$py_bin" ]]; then
        need_root
        install_python_via_deadsnakes
        py_bin="$(find_supported_python)" || die "Still no supported Python after install."
    fi
    log "Using ${py_bin} for the OpenVINO venv."

    if [[ ! -d "$VENV_DIR" ]]; then
        log "Creating venv at ${VENV_DIR}"
        as_user "mkdir -p '$(dirname "$VENV_DIR")' && ${py_bin} -m venv '${VENV_DIR}'"
    else
        log "Reusing existing venv at ${VENV_DIR}"
    fi

    log "Installing Python dependencies (numpy, etc.) into venv..."
    local req_file="${INSTALL_DIR}/python/requirements.txt"
    as_user "source '${VENV_DIR}/bin/activate' && pip install --upgrade pip -q"
    if [[ -f "$req_file" ]]; then
        with_heartbeat "pip install requirements" as_user "source '${VENV_DIR}/bin/activate' && pip install -q -r '${req_file}'"
    else
        warn "No requirements.txt at ${req_file}, installing numpy directly."
        with_heartbeat "pip install numpy" as_user "source '${VENV_DIR}/bin/activate' && pip install -q numpy"
    fi
}

# ---------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------
do_install() {
    need_root
    command -v curl >/dev/null || die "curl is required."

    cleanup_work_dir; WORK_DIR="$(mktemp -d)"

    log "Target: OpenVINO ${OV_VERSION} -> ${INSTALL_DIR}"
    log "Package: ${PKG_URL}"

    cd "$WORK_DIR"
    log "Downloading archive..."
    curl -L --fail --progress-bar "$PKG_URL" --output openvino.tgz

    log "Extracting..."
    tar -xf openvino.tgz
    local extracted_dir
    extracted_dir="$(find . -mindepth 1 -maxdepth 1 -type d -name 'openvino_toolkit_*')"
    [[ -n "$extracted_dir" ]] || die "Could not find extracted OpenVINO directory."

    if [[ -d "$INSTALL_DIR" ]]; then
        log "Existing install found, backing up to ${INSTALL_DIR}.bak"
        rm -rf "${INSTALL_DIR}.bak"
        mv "$INSTALL_DIR" "${INSTALL_DIR}.bak"
    fi

    mkdir -p "$INSTALL_PREFIX"
    mv "$extracted_dir" "$INSTALL_DIR"
    log "Installed to ${INSTALL_DIR}"

    local deps_script="${INSTALL_DIR}/install_dependencies/install_openvino_dependencies.sh"
    if [[ -x "$deps_script" ]]; then
        log "Installing system dependencies..."
        with_heartbeat "OpenVINO dependency install" "$deps_script" -y \
            || warn "Dependency script reported issues; continuing."
    else
        warn "No dependency script found at ${deps_script}, skipping."
    fi

    if [[ -L "$LINK_DIR" || -e "$LINK_DIR" ]]; then
        log "Unlinking previous ${LINK_DIR}"
        unlink "$LINK_DIR" 2>/dev/null || rm -rf "$LINK_DIR"
    fi
    ln -s "$INSTALL_DIR" "$LINK_DIR"
    log "Symlinked ${LINK_DIR} -> ${INSTALL_DIR}"

    [[ -f "$SETUPVARS" ]] || die "setupvars.sh not found at ${SETUPVARS} — install incomplete."

    if ! grep -qF "source ${SETUPVARS}" "$RC_FILE" 2>/dev/null; then
        echo "source ${SETUPVARS}" >> "$RC_FILE"
        log "Added 'source ${SETUPVARS}' to ${RC_FILE}"
    else
        log "setupvars already sourced in ${RC_FILE}"
    fi

    setup_python_env

    log "Done. Verify with: sudo ./$(basename "$0") verify"
}

# ---------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------
do_uninstall() {
    need_root
    local removed=0

    if [[ -d "$INSTALL_DIR" ]]; then
        log "Removing ${INSTALL_DIR}"
        rm -rf "$INSTALL_DIR"
        removed=1
    fi
    if [[ -d "${INSTALL_DIR}.bak" ]]; then
        log "Removing ${INSTALL_DIR}.bak"
        rm -rf "${INSTALL_DIR}.bak"
    fi
    if [[ -L "$LINK_DIR" ]]; then
        log "Removing symlink ${LINK_DIR}"
        unlink "$LINK_DIR"
        removed=1
    fi
    if grep -qF "source ${SETUPVARS}" "$RC_FILE" 2>/dev/null; then
        log "Removing setupvars line from ${RC_FILE}"
        sed -i "\#source ${SETUPVARS//\//\\/}#d" "$RC_FILE"
        removed=1
    fi
    if [[ -d "$VENV_DIR" ]]; then
        read -r -p "Remove venv at ${VENV_DIR} too? [y/N] " ans
        if [[ "${ans,,}" == "y" ]]; then
            rm -rf "$VENV_DIR"
            log "Removed ${VENV_DIR}"
        fi
    fi

    if [[ "$removed" -eq 1 ]]; then
        log "Uninstall complete."
    else
        warn "Nothing found to remove."
    fi
}

# ---------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------
do_verify() {
    [[ -f "$SETUPVARS" ]] || die "OpenVINO not installed (no ${SETUPVARS})."
    [[ -d "$VENV_DIR" ]] || die "No venv at ${VENV_DIR}. Run install first."

    log "Checking available devices..."
    # shellcheck disable=SC1090
    as_user "source '${VENV_DIR}/bin/activate' && source '${SETUPVARS}' && python -c \"import openvino as ov; print(ov.Core().available_devices)\""
}

# ---------------------------------------------------------------------
# OVMS: install / uninstall / lib repair
# ---------------------------------------------------------------------
do_ovms_install() {
    need_root
    command -v curl >/dev/null || die "curl is required."

    cleanup_work_dir; WORK_DIR="$(mktemp -d)"
    log "Downloading OVMS ${OVMS_VERSION} (python_off, ubuntu24 build)..."
    curl -L --fail --progress-bar "$OVMS_PKG_URL" --output "${WORK_DIR}/ovms.tar.gz"

    apt-get update -y
    # Best-effort: Ubuntu 26.04 may have renamed/dropped this package
    # (bumped past what's in the repo). Not load-bearing — ovms_repair_libs
    # checks the actual binary via ldd and patches from a container if needed.
    with_heartbeat "apt-get install libxml2/curl" apt-get install -y libxml2 curl \
        || warn "libxml2 not available via apt on this release — will patch via ovms_repair_libs instead."

    if [[ -d "$OVMS_INSTALL_DIR" ]]; then
        log "Existing OVMS found, backing up to ${OVMS_INSTALL_DIR}.bak"
        rm -rf "${OVMS_INSTALL_DIR}.bak"
        mv "$OVMS_INSTALL_DIR" "${OVMS_INSTALL_DIR}.bak"
    fi
    mkdir -p "$OVMS_INSTALL_DIR"
    tar -xzf "${WORK_DIR}/ovms.tar.gz" -C "$OVMS_INSTALL_DIR"
    [[ -x "$OVMS_BIN" ]] || die "OVMS binary not found at ${OVMS_BIN} after extract."

    mkdir -p "$MODEL_REPO_DIR" "$OVMS_STATE_DIR"
    chown -R "${REAL_USER}:${REAL_USER}" "$MODEL_REPO_DIR" "$OVMS_STATE_DIR"

    ovms_repair_libs

    log "OVMS ${OVMS_VERSION} installed at ${OVMS_INSTALL_DIR}."
    log "Models will live in ${MODEL_REPO_DIR}. Pull one, then start the server."
}

do_ovms_uninstall() {
    need_root
    local removed=0
    if ovms_is_running; then
        warn "OVMS is currently running — stopping it first."
        do_ovms_stop
    fi
    if [[ -d "$OVMS_INSTALL_DIR" ]]; then
        rm -rf "$OVMS_INSTALL_DIR" "${OVMS_INSTALL_DIR}.bak"
        log "Removed ${OVMS_INSTALL_DIR}"
        removed=1
    fi
    if [[ -d "$MODEL_REPO_DIR" ]]; then
        read -r -p "Also remove downloaded models in ${MODEL_REPO_DIR}? [y/N] " ans
        if [[ "${ans,,}" == "y" ]]; then
            rm -rf "$MODEL_REPO_DIR"
            log "Removed ${MODEL_REPO_DIR}"
        fi
    fi
    [[ "$removed" -eq 1 ]] && log "OVMS uninstall complete." || warn "Nothing found to remove."
}

# Detects sonames OVMS links against but that Ubuntu 26.04 no longer
# ships (libxml2/ICU version bump), and pulls compatible copies out of
# a throwaway ubuntu:24.04 container into ovms/lib (self-contained,
# doesn't touch the system). No-ops cleanly if nothing is missing.
ovms_repair_libs() {
    need_root
    [[ -x "$OVMS_BIN" ]] || die "OVMS not installed."

    local missing=()
    missing=($(LD_LIBRARY_PATH="$OVMS_LIB" ldd "$OVMS_BIN" 2>/dev/null | awk '/not found/ {print $1}' | sort -u))

    if [[ "${#missing[@]}" -eq 0 ]]; then
        log "ovms binary links cleanly, no missing libs."
        return 0
    fi

    warn "Missing shared libs (known Ubuntu 26.04 issue, model_server#4362): ${missing[*]}"
    command -v docker >/dev/null || die "docker is required to fetch compatible libs. Install docker, or manually drop matching .so files into ${OVMS_LIB}."

    # Single container run: walk the full dependency closure (BFS over ldd
    # of each lib we copy) rather than discovering it one ovms-level ldd
    # pass at a time. libxml2 pulls in ICU as its own transitive deps —
    # this resolves that in one shot instead of needing a second repair pass.
    log "Resolving full dependency closure via a throwaway ubuntu:24.04 container..."
    local want="${missing[*]}"
    with_heartbeat "docker lib-repair container" \
    docker run --rm -v "${OVMS_LIB}:/out" ubuntu:24.04 bash -c "
        set -e
        apt-get update -qq
        apt-get install -y -qq libxml2 libicu74 >/dev/null

        # Base libs every modern glibc host already has — never copy these,
        # doing so would shadow the host's real ones.
        skip='ld-linux-x86-64|libc\\.so|libm\\.so|libpthread\\.so|libdl\\.so|librt\\.so|libresolv\\.so|libutil\\.so|libgcc_s\\.so|linux-vdso'

        seen=\"\"
        queue=\"${want}\"
        while [[ -n \"\$queue\" ]]; do
            next=\"\"
            for f in \$queue; do
                case \" \$seen \" in *\" \$f \"*) continue ;; esac
                seen=\"\$seen \$f\"
                found=\$(find / -xdev -name \"\${f}*\" 2>/dev/null | grep -v '^/out' | head -1)
                if [[ -z \"\$found\" ]]; then
                    echo \"COULD NOT FIND \$f\" >&2
                    continue
                fi
                cp -v \"\$found\" \"/out/\$f\"
                for d in \$(ldd \"\$found\" 2>/dev/null | awk '{print \$1}' | grep -Ev \"\$skip\"); do
                    case \" \$seen \" in *\" \$d \"*) ;; *) next=\"\$next \$d\" ;; esac
                done
            done
            queue=\"\$next\"
        done
    " || die "Docker-based lib fetch failed."

    local still_missing
    still_missing="$(LD_LIBRARY_PATH="$OVMS_LIB" ldd "$OVMS_BIN" 2>/dev/null | awk '/not found/ {print $1}')"
    if [[ -n "$still_missing" ]]; then
        die "Still missing after repair: ${still_missing}. Drop matching .so files into ${OVMS_LIB} manually."
    fi
    log "Libs patched into ${OVMS_LIB}. ovms should now start cleanly."
}

# ---------------------------------------------------------------------
# OVMS: model pull
# ---------------------------------------------------------------------
ovms_run() {
    # Runs ovms as the real user (keeps HF cache / model ownership sane),
    # with the patched lib dir on LD_LIBRARY_PATH.
    as_user "LD_LIBRARY_PATH='${OVMS_LIB}' '${OVMS_BIN}' $1"
}

# Queries the live Hugging Face API, optionally scoped to an org/author and
# a search term, sorted by downloads. Prints
# "index<TAB>model_id<TAB>pipeline_tag<TAB>downloads" per line, or
# "EMPTY" / "ERROR:<msg>" on stderr. Pure-stdlib python3, no extra deps.
hf_search() {
    local term="$1" author="${2:-}"
    local py="${WORK_DIR}/hf_search.py"
    cat > "$py" <<'PYEOF'
import sys, json, urllib.request, urllib.parse

term = sys.argv[1] if len(sys.argv) > 1 else ""
author = sys.argv[2] if len(sys.argv) > 2 else ""
params = {"sort": "downloads", "direction": "-1", "limit": "20"}
if author:
    params["author"] = author
if term:
    params["search"] = term
url = "https://huggingface.co/api/models?" + urllib.parse.urlencode(params)
try:
    with urllib.request.urlopen(url, timeout=15) as r:
        data = json.load(r)
except Exception as e:
    print(f"ERROR:{e}", file=sys.stderr)
    sys.exit(1)

if not data:
    print("EMPTY")
    sys.exit(0)

for i, m in enumerate(data, 1):
    mid = m.get("modelId", "?")
    tag = m.get("pipeline_tag") or "-"
    dl = m.get("downloads", 0)
    print(f"{i}\t{mid}\t{tag}\t{dl}")
PYEOF
    python3 "$py" "$term" "$author"
}

# Rough default for the ovms --task flag based on the HF pipeline_tag,
# since most browsed models are text-generation but a few aren't.
suggest_task() {
    case "$1" in
        *embed*)  echo "embeddings" ;;
        *rerank*) echo "rerank" ;;
        *)        echo "text_generation" ;;
    esac
}

# Fetches the list of .gguf filenames a HF repo actually hosts. We build a
# direct download URL from source_model + gguf_filename, so guessing wrong
# here means a guaranteed 404 (and OVMS has been observed to segfault on
# that error path rather than fail cleanly — so this check isn't optional).
hf_gguf_files() {
    local repo="$1"
    local py="${WORK_DIR}/hf_files.py"
    cat > "$py" <<'PYEOF'
import sys, json, urllib.request, urllib.parse

repo = sys.argv[1]
url = "https://huggingface.co/api/models/" + urllib.parse.quote(repo)
try:
    with urllib.request.urlopen(url, timeout=15) as r:
        data = json.load(r)
except Exception as e:
    print(f"ERROR:{e}", file=sys.stderr)
    sys.exit(1)

for s in data.get("siblings", []):
    fn = s.get("rfilename", "")
    if fn.lower().endswith(".gguf"):
        print(fn)
PYEOF
    python3 "$py" "$repo"
}

# Given a repo's real .gguf file list, resolves which exact filename to use
# as --gguf_filename. Auto-picks if there's only one; otherwise shows a
# picker, flagging whichever remote name shares a quant tag (Q8_0, etc.)
# with the local file. Sets SELECTED_GGUF_FILENAME. Returns 1 if the repo
# hosts no .gguf files at all (caller should treat that as "wrong repo").
pick_remote_gguf_filename() {
    local repo="$1" local_hint="$2"
    local files
    files="$(hf_gguf_files "$repo" 2>&1)"
    if [[ "$files" == ERROR:* ]]; then
        warn "Couldn't list files for ${repo}: ${files#ERROR:}"
        return 1
    fi
    if [[ -z "$files" ]]; then
        warn "${repo} doesn't host any .gguf files — wrong repo for this file."
        return 1
    fi

    local -a arr=()
    local n=0 f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        n=$((n + 1))
        arr[$n]="$f"
    done <<< "$files"

    if [[ $n -eq 1 ]]; then
        SELECTED_GGUF_FILENAME="${arr[1]}"
        log "Using ${SELECTED_GGUF_FILENAME} (only .gguf file in that repo)."
        return 0
    fi

    local quant
    quant="$(grep -oE '[Qq][0-9]_[0-9A-Za-z_]+|IQ[0-9]_[0-9A-Za-z_]+|[Ff]16|[Bb]f16|[Ff]p16' <<< "$local_hint" | head -1)"

    echo
    echo "Multiple .gguf files in ${repo} — which matches your local file?"
    local i
    for ((i = 1; i <= n; i++)); do
        local mark=""
        [[ -n "$quant" && "${arr[$i]}" == *"$quant"* ]] && mark="   <-- matches local quant (${quant})"
        printf '%-4s %s%s\n' "$i" "${arr[$i]}" "$mark"
    done
    read -r -p "Pick a number (or blank to cancel): " pick
    [[ -n "$pick" && -n "${arr[$pick]:-}" ]] || { warn "Cancelled."; return 1; }
    SELECTED_GGUF_FILENAME="${arr[$pick]}"
}

# Runs hf_search, prints a numbered table, and lets the person pick one.
# Sets SELECTED_MODEL / SELECTED_TASK on success. Returns 1 on cancel/empty/error.
hf_search_and_pick() {
    local term="$1" author="${2:-}"
    log "Querying Hugging Face..."
    local raw
    raw="$(hf_search "$term" "$author" 2>&1)" || { warn "Search failed: ${raw}"; return 1; }
    if [[ "$raw" == "EMPTY" ]]; then
        warn "No models found for '${term}'."
        return 1
    fi
    if [[ "$raw" == ERROR:* ]]; then
        warn "Search failed: ${raw#ERROR:}"
        return 1
    fi

    echo
    printf '%-4s %-55s %-20s %s\n' "#" "MODEL" "TASK" "DOWNLOADS"
    local ids=() tags=()
    local idx mid tag dl
    while IFS=$'\t' read -r idx mid tag dl; do
        ids[$idx]="$mid"
        tags[$idx]="$tag"
        printf '%-4s %-55s %-20s %s\n' "$idx" "$mid" "$tag" "$dl"
    done <<< "$raw"
    echo

    read -r -p "Pick a number (or blank to cancel): " pick
    [[ -n "$pick" && -n "${ids[$pick]:-}" ]] || { warn "Cancelled."; return 1; }

    SELECTED_MODEL="${ids[$pick]}"
    SELECTED_TASK="$(suggest_task "${tags[$pick]}")"
}

# Parses a GGUF file's own header (pure stdlib python, reads only the small
# metadata section, never the weights) and prints any key/value whose key
# suggests the original base model — so we can suggest a search term instead
# of requiring the person to already know the exact HF repo id.
gguf_hints() {
    local gguf_path="$1"
    local py="${WORK_DIR}/gguf_meta.py"
    cat > "$py" <<'PYEOF'
import sys, struct

def read_str(f):
    (n,) = struct.unpack('<Q', f.read(8))
    return f.read(n).decode('utf-8', errors='replace')

TYPE_SIZES = {0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1,10:8,11:8,12:8}
TYPE_FMT = {0:'<B',1:'<b',2:'<H',3:'<h',4:'<I',5:'<i',6:'<f',7:'<B',10:'<Q',11:'<q',12:'<d'}

def read_value(f, vtype):
    if vtype == 8:
        return read_str(f)
    if vtype == 9:
        (elem_type,) = struct.unpack('<I', f.read(4))
        (count,) = struct.unpack('<Q', f.read(8))
        return [read_value(f, elem_type) for _ in range(count)]
    if vtype in TYPE_FMT:
        return struct.unpack(TYPE_FMT[vtype], f.read(TYPE_SIZES[vtype]))[0]
    raise ValueError(f"unknown gguf value type {vtype}")

def main():
    path = sys.argv[1]
    with open(path, 'rb') as f:
        if f.read(4) != b'GGUF':
            print("ERROR:not a GGUF file", file=sys.stderr)
            sys.exit(1)
        (version,) = struct.unpack('<I', f.read(4))
        if version >= 2:
            f.read(8)  # tensor_count (uint64)
            (kv_count,) = struct.unpack('<Q', f.read(8))
        else:
            f.read(4)  # tensor_count (uint32, v1)
            (kv_count,) = struct.unpack('<I', f.read(4))

        wanted = ('name', 'basename', 'base_model', 'source', 'repo', 'organization', 'architecture', 'finetune')
        for _ in range(kv_count):
            key = read_str(f)
            (vtype,) = struct.unpack('<I', f.read(4))
            val = read_value(f, vtype)
            if any(w in key.lower() for w in wanted):
                print(f"{key}\t{val}")

if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f"ERROR:{e}", file=sys.stderr)
        sys.exit(1)
PYEOF
    python3 "$py" "$gguf_path"
}

do_model_browse() {
    cleanup_work_dir; WORK_DIR="$(mktemp -d)"
    read -r -p "Search OpenVINO models on Hugging Face (blank = show most downloaded): " term
    hf_search_and_pick "$term" "OpenVINO" || return 1
    SELECTED_MODE="pull"
}


do_model_pull() {
    [[ -x "$OVMS_BIN" ]] || die "Install OVMS first."
    mkdir -p "$MODEL_REPO_DIR"; chown "${REAL_USER}:${REAL_USER}" "$MODEL_REPO_DIR"

    echo "1) Browse popular OpenVINO models (search Hugging Face)"
    echo "2) Enter an HF model id manually (pre-converted OpenVINO IR)"
    echo "3) Convert an arbitrary HF model via optimum-cli (downloads + quantizes)"
    read -r -p "Choice [1-3]: " choice

    local src_model="" task="text_generation" mode="pull"
    case "$choice" in
        1)
            do_model_browse || return 1
            src_model="$SELECTED_MODEL"
            task="$SELECTED_TASK"
            ;;
        2)
            read -r -p "HF source model id: " src_model
            [[ -n "$src_model" ]] || die "No model id given."
            ;;
        3)
            read -r -p "HF source model id: " src_model
            [[ -n "$src_model" ]] || die "No model id given."
            mode="convert"
            ;;
        *) die "Invalid choice." ;;
    esac

    read -r -p "Local model name [${src_model##*/}]: " model_name
    model_name="${model_name:-${src_model##*/}}"
    read -r -p "Target device [GPU]: " device
    device="${device:-GPU}"
    device="${device^^}"
    case "$device" in CPU|GPU|NPU|HETERO|AUTO) ;; *) warn "Unusual device '${device}' — continuing anyway." ;; esac
    read -r -p "Task [${task}]: " task_in
    task="${task_in:-$task}"

    local extra=""
    if [[ "$mode" == "convert" ]]; then
        read -r -p "Weight format (int8/int4/fp16) [int8]: " wf
        wf="${wf:-int8}"
        extra="--weight-format ${wf}"
        echo
        warn "optimum-cli conversion quantizes the model locally — this is real"
        warn "CPU/GPU work, not a download, and can run for a long time (minutes"
        warn "to several hours depending on model size). You'll get a heartbeat"
        warn "line every 30s even if OVMS itself goes quiet."
    fi

    echo
    log "About to pull:"
    echo "    source:  ${src_model}"
    echo "    name:    ${model_name}"
    echo "    device:  ${device}"
    echo "    task:    ${task}"
    [[ -n "$extra" ]] && echo "    extra:   ${extra}"
    read -r -p "Proceed? [Y/n] " go
    [[ "${go,,}" == "n" ]] && { warn "Cancelled."; return 1; }

    log "Pulling ${src_model} -> ${MODEL_REPO_DIR}/${model_name}..."
    with_heartbeat "pull/convert ${model_name}" ovms_run "--pull --source_model \"${src_model}\" --model_repository_path \"${MODEL_REPO_DIR}\" --model_name \"${model_name}\" --target_device \"${device}\" --task \"${task}\" ${extra}" \
        || die "Pull failed (see OVMS output above) — not registering."

    read -r -p "Register in ${OVMS_CONFIG_PATH} for multi-model serving? [Y/n] " reg
    if [[ "${reg,,}" != "n" ]]; then
        ovms_run "--add_to_config --config_path \"${OVMS_CONFIG_PATH}\" --model_name \"${model_name}\" --model_path \"${MODEL_REPO_DIR}/${model_name}\"" \
            || die "Registration failed (see OVMS output above)."
        log "Registered. Start the server to serve all registered models."
    fi
}

# ---------------------------------------------------------------------
# OVMS: scan for models already on disk (Downloads, HF cache, gguf-gasket
# / llamacpp-config-mgr model dirs, etc.) and register them without a
# re-download.
# ---------------------------------------------------------------------
model_scan_paths() {
    local extra=()
    [[ -f "${OVMS_STATE_DIR}/extra_scan_paths" ]] && mapfile -t extra < "${OVMS_STATE_DIR}/extra_scan_paths"
    printf '%s\n' \
        "$MODEL_REPO_DIR" \
        "${USER_HOME}/.cache/huggingface/hub" \
        "${USER_HOME}/Downloads" \
        "${USER_HOME}/models" \
        "${USER_HOME}/gguf-models" \
        "/opt/models" \
        "${extra[@]}" | awk '!seen[$0]++'
}

do_model_scan() {
    [[ -x "$OVMS_BIN" ]] || die "Install OVMS first."
    cleanup_work_dir; WORK_DIR="$(mktemp -d)"

    read -r -p "Also scan a custom path? (blank to skip): " custom
    if [[ -n "$custom" ]]; then
        mkdir -p "$OVMS_STATE_DIR"
        if ! grep -qxF "$custom" "${OVMS_STATE_DIR}/extra_scan_paths" 2>/dev/null; then
            echo "$custom" >> "${OVMS_STATE_DIR}/extra_scan_paths"
            chown "${REAL_USER}:${REAL_USER}" "${OVMS_STATE_DIR}/extra_scan_paths"
        fi
    fi

    log "Scanning for GGUF files and OpenVINO IR models..."
    local -a f_type=() f_path=() f_name=()
    local n=0 p

    while IFS= read -r p; do
        [[ -d "$p" ]] || continue

        # GGUF: any *.gguf file. Skip additional shards of a split model
        # (only offer the first part — ovms wants that filename).
        while IFS= read -r -d '' g; do
            [[ "$g" =~ -0*[2-9][0-9]*-of-[0-9]+\.gguf$ ]] && continue
            n=$((n + 1))
            f_type[$n]="GGUF"
            f_path[$n]="$g"
            f_name[$n]="$(basename "$g" .gguf)"
        done < <(find "$p" -maxdepth 6 -iname '*.gguf' -type f -print0 2>/dev/null)

        # OpenVINO IR: a *.xml with a same-named *.bin next to it.
        while IFS= read -r -d '' x; do
            local b="${x%.xml}.bin"
            [[ -f "$b" ]] || continue
            n=$((n + 1))
            f_type[$n]="IR"
            f_path[$n]="$(dirname "$x")"
            f_name[$n]="$(basename "$(dirname "$x")")"
        done < <(find "$p" -maxdepth 6 -iname '*.xml' -type f -print0 2>/dev/null)
    done < <(model_scan_paths)

    if [[ $n -eq 0 ]]; then
        warn "Nothing found. Scanned: $(model_scan_paths | tr '\n' ' ')"
        return 1
    fi

    echo
    printf '%-4s %-6s %-30s %s\n' "#" "TYPE" "NAME" "PATH"
    local i
    for ((i = 1; i <= n; i++)); do
        printf '%-4s %-6s %-30s %s\n' "$i" "${f_type[$i]}" "${f_name[$i]}" "${f_path[$i]}"
    done
    echo

    read -r -p "Pick a number to register (or blank to cancel): " pick
    [[ -n "$pick" && -n "${f_path[$pick]:-}" ]] || { warn "Cancelled."; return 1; }

    local sel_type="${f_type[$pick]}" sel_path="${f_path[$pick]}"
    read -r -p "Register as [${f_name[$pick]}]: " model_name
    model_name="${model_name:-${f_name[$pick]}}"

    local dest="${MODEL_REPO_DIR}/${model_name}"
    mkdir -p "$MODEL_REPO_DIR"; chown "${REAL_USER}:${REAL_USER}" "$MODEL_REPO_DIR"

    # "Already correctly placed" means: the file (GGUF) or directory (IR)
    # already lives at exactly $MODEL_REPO_DIR/$model_name/... — not just
    # "somewhere under MODEL_REPO_DIR" (a stray flat .gguf there wouldn't
    # have a directory for --model_path to point at).
    local sel_parent
    sel_parent="$([[ "$sel_type" == "GGUF" ]] && dirname "$sel_path" || echo "$sel_path")"

    if [[ "$sel_parent" == "$dest" ]]; then
        log "Already correctly placed at ${dest}, registering in place."
    elif [[ -e "$dest" ]]; then
        warn "${dest} already exists, registering in place (not re-linking) — verify it's the same model."
    else
        read -r -p "Symlink or copy into ${dest}? [S/c]: " method
        as_user "mkdir -p '${dest}'"
        if [[ "${method,,}" == "c" ]]; then
            log "Copying into ${dest}..."
            if [[ "$sel_type" == "GGUF" ]]; then
                as_user "cp '${sel_path}' '${dest}/'"
            else
                as_user "cp -r '${sel_path}'/. '${dest}/'"
            fi
        else
            log "Symlinking into ${dest}..."
            if [[ "$sel_type" == "GGUF" ]]; then
                as_user "ln -sf '${sel_path}' '${dest}/$(basename "$sel_path")'"
            else
                as_user "find '${sel_path}' -mindepth 1 -maxdepth 1 -exec ln -sf {} '${dest}/' \\;"
            fi
        fi
    fi

    read -r -p "Target device [GPU]: " device
    device="${device:-GPU}"
    device="${device^^}"
    case "$device" in CPU|GPU|NPU|HETERO|AUTO) ;; *) warn "Unusual device '${device}' — continuing anyway." ;; esac
    read -r -p "Task [text_generation]: " task
    task="${task:-text_generation}"

    local src_hint=""
    if [[ "$sel_type" == "GGUF" ]]; then
        echo
        log "Reading embedded GGUF metadata for hints on the source model..."
        local meta guess=""
        meta="$(gguf_hints "$sel_path" 2>&1)"
        if [[ -n "$meta" && "$meta" != ERROR:* ]]; then
            echo "$meta"
            guess="$(awk -F'\t' '
                /base_model.*name/ && !g {g=$2}
                /^general\.basename/ {b=$2}
                /^general\.name/ {n=$2}
                END {if (g) print g; else if (b) print b; else if (n) print n}
            ' <<< "$meta")"
        else
            warn "No usable metadata embedded in this file."
        fi

        echo
        echo "OVMS needs an HF repo id for this GGUF to prepare it for serving."
        echo "It must be a repo that actually hosts .gguf files (look for"
        echo "'-GGUF' in the name) — a plain weights repo will 404."
        echo "NOTE: despite the file already being local, OVMS's --pull has been"
        echo "observed re-fetching the full weights from that HF repo anyway —"
        echo "this is NOT confirmed to skip the download. If the repo you pick"
        echo "hosts a multi-GB file, expect a real download."
        local remote_gguf_filename=""
        while true; do
            read -r -p "Search Hugging Face for the source model [${guess:-type a search term}]: " term
            term="${term:-$guess}"
            [[ -n "$term" ]] || { warn "Need something to search for."; continue; }
            if hf_search_and_pick "$term" ""; then
                if pick_remote_gguf_filename "$SELECTED_MODEL" "$(basename "$sel_path")"; then
                    src_hint="$SELECTED_MODEL"
                    remote_gguf_filename="$SELECTED_GGUF_FILENAME"
                    break
                fi
                warn "That repo won't work for this file — try a different search."
            fi
            read -r -p "Try another search? [Y/n] " again
            [[ "${again,,}" == "n" ]] && { warn "Skipping this model."; return 1; }
        done
    fi

    echo
    log "About to register:"
    echo "    type:    ${sel_type}"
    echo "    name:    ${model_name}"
    echo "    path:    ${dest}"
    echo "    device:  ${device}"
    echo "    task:    ${task}"
    [[ -n "$src_hint" ]] && echo "    source:  ${src_hint} :: ${remote_gguf_filename} (may re-download — see note above)"
    read -r -p "Proceed? [Y/n] " go
    [[ "${go,,}" == "n" ]] && { warn "Cancelled."; return 1; }

    if [[ "$sel_type" == "GGUF" ]]; then
        with_heartbeat "pull ${model_name}" ovms_run "--pull --source_model \"${src_hint}\" --model_repository_path \"${MODEL_REPO_DIR}\" --model_name \"${model_name}\" --target_device \"${device}\" --task \"${task}\" --gguf_filename \"${remote_gguf_filename}\"" \
            || die "Pull failed (see OVMS output above) — not registering. If a partial/broken entry for '${model_name}' is already in ${OVMS_CONFIG_PATH}, remove it first: ovms --remove_from_config --config_path \"${OVMS_CONFIG_PATH}\" --model_name \"${model_name}\""
    fi

    ovms_run "--add_to_config --config_path \"${OVMS_CONFIG_PATH}\" --model_name \"${model_name}\" --model_path \"${dest}\"" \
        || die "Registration failed (see OVMS output above)."
    log "Registered. Start the server to serve all registered models."
}

# ---------------------------------------------------------------------
# OVMS: start / stop / status
# ---------------------------------------------------------------------
ovms_is_running() {
    [[ -f "$OVMS_PID_FILE" ]] && kill -0 "$(cat "$OVMS_PID_FILE")" 2>/dev/null
}

do_ovms_start() {
    [[ -x "$OVMS_BIN" ]] || die "Install OVMS first."
    ovms_is_running && { warn "OVMS already running (pid $(cat "$OVMS_PID_FILE"))."; return 0; }

    read -r -p "REST port [${OVMS_DEFAULT_PORT}]: " port
    port="${port:-$OVMS_DEFAULT_PORT}"

    local args
    if [[ -f "$OVMS_CONFIG_PATH" ]]; then
        log "Starting OVMS with all registered models (${OVMS_CONFIG_PATH}) on port ${port}..."
        args="--rest_port ${port} --config_path \"${OVMS_CONFIG_PATH}\""
    else
        local latest
        latest="$(find "$MODEL_REPO_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
        [[ -n "$latest" ]] || die "No config and no pulled models found. Pull a model first."
        log "No config_all.json yet — serving single model: ${latest} on port ${port}..."
        args="--rest_port ${port} --model_repository_path \"${MODEL_REPO_DIR}\" --model_name \"$(basename "$latest")\" --model_path \"${latest}\""
    fi

    as_user "LD_LIBRARY_PATH='${OVMS_LIB}' nohup '${OVMS_BIN}' ${args} > '${OVMS_LOG_FILE}' 2>&1 & echo \$! > '${OVMS_PID_FILE}'"
    sleep 2
    if ovms_is_running; then
        log "OVMS started (pid $(cat "$OVMS_PID_FILE"), port ${port}). Log: ${OVMS_LOG_FILE}"
    else
        die "OVMS failed to start — check ${OVMS_LOG_FILE}"
    fi
}

do_ovms_stop() {
    if ! ovms_is_running; then
        warn "OVMS is not running."
        rm -f "$OVMS_PID_FILE"
        return 0
    fi
    local pid; pid="$(cat "$OVMS_PID_FILE")"
    log "Stopping OVMS (pid ${pid})..."
    kill "$pid" 2>/dev/null || true
    for _ in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$OVMS_PID_FILE"
    log "Stopped."
}

do_ovms_status() {
    if ovms_is_running; then
        log "OVMS running (pid $(cat "$OVMS_PID_FILE"))."
    else
        warn "OVMS not running."
    fi
    [[ -f "$OVMS_LOG_FILE" ]] && { echo "--- last 20 lines of ${OVMS_LOG_FILE} ---"; tail -n 20 "$OVMS_LOG_FILE"; }
}

# ---------------------------------------------------------------------
# OVMS: list / remove registered models (config_all.json management)
# ---------------------------------------------------------------------
do_model_list() {
    [[ -x "$OVMS_BIN" ]] || die "Install OVMS first."
    [[ -f "$OVMS_CONFIG_PATH" ]] || { warn "No config file at ${OVMS_CONFIG_PATH} yet — nothing registered."; return 1; }
    ovms_run "--list_models --model_repository_path \"${MODEL_REPO_DIR}\""
}

do_model_remove() {
    [[ -x "$OVMS_BIN" ]] || die "Install OVMS first."
    [[ -f "$OVMS_CONFIG_PATH" ]] || { warn "No config file at ${OVMS_CONFIG_PATH} yet — nothing registered."; return 1; }
    do_model_list || true
    echo
    read -r -p "Model name to remove (exact, as listed above): " name
    [[ -n "$name" ]] || { warn "Cancelled."; return 1; }
    read -r -p "Remove '${name}' from ${OVMS_CONFIG_PATH}? [y/N] " go
    [[ "${go,,}" == "y" ]] || { warn "Cancelled."; return 1; }
    ovms_run "--remove_from_config --config_path \"${OVMS_CONFIG_PATH}\" --model_name \"${name}\"" \
        || die "Remove failed (see OVMS output above)."
    log "Removed '${name}' from the config."
}

# ---------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------
show_menu() {
    cat <<EOF

OpenVINO ${OV_VERSION} / OVMS ${OVMS_VERSION} manager (Ubuntu 26.04)
------------------------------------------------------------------
  Runtime
  1) Install OpenVINO Runtime
  2) Uninstall OpenVINO Runtime
  3) Verify OpenVINO Runtime
  4) Repair Python venv (re-run pip deps only)

  Model Server (OVMS)
  5) Install/update OVMS
  6) Uninstall OVMS
  7) Repair OVMS shared libs (libxml2/ICU)
  8) Pull a model (search Hugging Face)
  9) Scan for models already on disk
 10) Start API server
 11) Stop API server
 12) Server status / tail log
 13) List registered models
 14) Remove a registered model

 15) Exit
EOF
    read -r -p "Select an option [1-15]: " choice || { echo; exit 0; }
    case "$choice" in
        1) ( trap cleanup_work_dir EXIT; do_install )                            || warn "Install did not complete — back at menu." ;;
        2) ( trap cleanup_work_dir EXIT; do_uninstall )                          || warn "Uninstall did not complete — back at menu." ;;
        3) ( trap cleanup_work_dir EXIT; do_verify )                             || warn "Verify failed — back at menu." ;;
        4) ( trap cleanup_work_dir EXIT
             need_root; [[ -f "$SETUPVARS" ]] || die "OpenVINO not installed."; setup_python_env ) \
                                                                                   || warn "Venv repair did not complete — back at menu." ;;
        5) ( trap cleanup_work_dir EXIT; do_ovms_install )                       || warn "OVMS install did not complete — back at menu." ;;
        6) ( trap cleanup_work_dir EXIT; do_ovms_uninstall )                     || warn "OVMS uninstall did not complete — back at menu." ;;
        7) ( trap cleanup_work_dir EXIT; ovms_repair_libs )                      || warn "Lib repair did not complete — back at menu." ;;
        8) ( trap cleanup_work_dir EXIT; do_model_pull )                         || warn "Pull did not complete — back at menu." ;;
        9) ( trap cleanup_work_dir EXIT; do_model_scan )                         || warn "Scan did not complete — back at menu." ;;
        10) ( trap cleanup_work_dir EXIT; do_ovms_start )                        || warn "Server did not start — back at menu." ;;
        11) ( trap cleanup_work_dir EXIT; do_ovms_stop )                         || warn "Stop did not complete — back at menu." ;;
        12) ( trap cleanup_work_dir EXIT; do_ovms_status )                       || warn "Status check failed — back at menu." ;;
        13) ( trap cleanup_work_dir EXIT; do_model_list )                        || warn "List failed — back at menu." ;;
        14) ( trap cleanup_work_dir EXIT; do_model_remove )                      || warn "Remove did not complete — back at menu." ;;
        15) exit 0 ;;
        *) warn "Invalid option." ;;
    esac
}

# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------
case "${1:-}" in
    install)        do_install ;;
    uninstall)       do_uninstall ;;
    verify)          do_verify ;;
    repair)          need_root; [[ -f "$SETUPVARS" ]] || die "OpenVINO not installed."; setup_python_env ;;
    ovms-install)    do_ovms_install ;;
    ovms-uninstall)  do_ovms_uninstall ;;
    ovms-repair)     ovms_repair_libs ;;
    ovms-pull)       do_model_pull ;;
    ovms-scan)       do_model_scan ;;
    ovms-start)      do_ovms_start ;;
    ovms-stop)       do_ovms_stop ;;
    ovms-status)     do_ovms_status ;;
    ovms-list)       do_model_list ;;
    ovms-remove)     do_model_remove ;;
    "")              while true; do show_menu; done ;;
    *)               die "Unknown argument: $1" ;;
esac
