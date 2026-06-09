#!/bin/bash
# lib/arc_check.sh — sourceable Intel Arc A770 status library
#
# Provides fast, non-interactive check functions that any tool can call.
# Source this file; never execute it directly.
#
# Sourced by: menu_arc_fix.sh, menu_config_manager.sh, menu_build.sh,
#             manager.sh, main.go (via /api/arc/status shell-out)
#
# Public API:
#   arc_detect          → sets ARC_PCI_ADDR, ARC_PCI_ID; returns 0 if Arc found
#   arc_driver_loaded   → returns 0 if xe or i915 is bound to GPU
#   arc_render_access   → returns 0 if /dev/dri/renderD* is accessible
#   arc_opencl_ok       → returns 0 if clinfo shows Intel device
#   arc_levelzero_ok    → returns 0 if Level Zero sees Intel device
#   arc_oneapi_ok       → returns 0 if oneAPI+icpx are functional
#   arc_user_groups_ok  → returns 0 if user is in render+video groups
#   arc_quick_fix       → applies fixes for common issues; logs to ARC_FIX_LOG
#   arc_status_line     → prints a compact one-line status for header strips
#   arc_full_status     → prints a multi-line table; used by menu_arc_fix.sh
#   arc_all_ok          → returns 0 only if all critical checks pass
# ─────────────────────────────────────────────────────────────────────────────

# Arc/DG2 PCI device IDs
_ARC_IDS=("56a0" "56a1" "56a5" "56a6" "5690" "5691" "5692" "56b0" "56b1" "56c0" "56c1")

# Populated by arc_detect
declare -g ARC_PCI_ADDR=""
declare -g ARC_PCI_ID=""

ARC_FIX_LOG="${HOME}/ai_stack/arc_fix.log"

# ── Hardware ──────────────────────────────────────────────────────────────────

arc_detect() {
    command -v lspci &>/dev/null || return 1
    for id in "${_ARC_IDS[@]}"; do
        local line; line=$(lspci -nn 2>/dev/null | grep -i "8086:${id}" | head -1)
        if [[ -n "$line" ]]; then
            ARC_PCI_ADDR=$(awk '{print $1}' <<< "$line")
            ARC_PCI_ID="$id"
            return 0
        fi
    done
    return 1
}

# ── Kernel driver ─────────────────────────────────────────────────────────────

arc_driver_loaded() {
    lsmod 2>/dev/null | grep -qE "^(xe|i915) "
}

arc_driver_name() {
    lsmod 2>/dev/null | grep -oE "^(xe|i915)" | head -1
}

arc_driver_bound() {
    [[ -z "$ARC_PCI_ADDR" ]] && arc_detect
    [[ -z "$ARC_PCI_ADDR" ]] && return 1
    local drv="/sys/bus/pci/devices/0000:${ARC_PCI_ADDR}/driver"
    [[ -L "$drv" ]] && basename "$(readlink "$drv")" | grep -qE "^(xe|i915)$"
}

# ── DRM access ────────────────────────────────────────────────────────────────

arc_render_node() {
    ls /dev/dri/renderD* 2>/dev/null | head -1
}

arc_render_access() {
    local node; node=$(arc_render_node)
    [[ -n "$node" && -r "$node" && -w "$node" ]]
}

# ── User groups ───────────────────────────────────────────────────────────────

arc_user_groups_ok() {
    local user="${USER:-$(whoami)}"
    local ok=true
    for grp in render video; do
        getent group "$grp" &>/dev/null || continue
        id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp" || ok=false
    done
    $ok
}

# ── OpenCL ────────────────────────────────────────────────────────────────────

arc_opencl_ok() {
    command -v clinfo &>/dev/null || return 1
    clinfo 2>/dev/null | grep -qi "device name.*intel\|device name.*arc"
}

arc_opencl_pkg_ok() {
    dpkg -l intel-opencl-icd 2>/dev/null | grep -q '^ii'
}

# ── Level Zero ────────────────────────────────────────────────────────────────

arc_levelzero_ok() {
    dpkg -l libze-intel-gpu1 2>/dev/null | grep -q '^ii' || return 1
    command -v ze_info &>/dev/null || return 0   # pkg ok even without ze_info binary
    ZES_ENABLE_SYSMAN=1 ze_info 2>/dev/null | grep -qi "intel\|arc\|xe"
}

# ── oneAPI / SYCL ─────────────────────────────────────────────────────────────

arc_oneapi_root() {
    for loc in /opt/intel/oneapi /opt/intel/inteloneapi "$HOME/intel/oneapi"; do
        [[ -f "${loc}/setvars.sh" ]] && echo "$loc" && return 0
    done
    command -v icpx &>/dev/null && dirname "$(command -v icpx)" && return 0
    return 1
}

arc_oneapi_ok() {
    local root; root=$(arc_oneapi_root) || return 1
    [[ -f "${root}/setvars.sh" ]] && \
        bash -c "source '${root}/setvars.sh' --force &>/dev/null && command -v icpx &>/dev/null"
}

arc_sycl_sees_gpu() {
    local root; root=$(arc_oneapi_root) || return 1
    [[ -f "${root}/setvars.sh" ]] && \
        bash -c "source '${root}/setvars.sh' --force &>/dev/null && \
            ONEAPI_DEVICE_SELECTOR=level_zero:* sycl-ls 2>/dev/null" \
        | grep -qi "intel\|arc\|xe"
}

# ── Aggregate ─────────────────────────────────────────────────────────────────

# Returns 0 when all hard requirements are met (driver + render access + groups)
arc_all_ok() {
    arc_detect         || return 1
    arc_driver_loaded  || return 1
    arc_render_access  || return 1
    arc_user_groups_ok || return 1
    return 0
}

# ── Status output helpers ─────────────────────────────────────────────────────

# One-liner for header strips — no colour codes, trimmed for narrow terminals
arc_status_line() {
    if ! arc_detect; then
        echo "Arc GPU: NOT DETECTED"
        return
    fi
    local issues=0
    arc_driver_loaded  || (( issues++ ))
    arc_render_access  || (( issues++ ))
    arc_user_groups_ok || (( issues++ ))
    if (( issues == 0 )); then
        echo "Arc A770: OK  (driver=$(arc_driver_name)  render=$(arc_render_node))"
    else
        echo "Arc A770: ${issues} issue(s) — run Arc Fix from menu"
    fi
}

# Multi-line coloured table — used by menu_arc_fix.sh
arc_full_status() {
    # Use gasket colours if available, fall back to ANSI literals
    local G="${B_GREEN:-$'\033[0;32m'}"
    local R="${B_RED:-$'\033[0;31m'}"
    local Y="${B_YELLOW:-$'\033[1;33m'}"
    local C="${B_CYAN:-$'\033[0;36m'}"
    local D="${NC:-$'\033[0m'}"

    _row() {
        local ok="$1" label="$2" detail="${3:-}"
        if $ok; then
            printf "  ${G}✔${D}  %-32s %s\n" "$label" "$detail"
        else
            printf "  ${R}✘${D}  %-32s %s\n" "$label" "${Y}${detail}${D}"
        fi
    }

    echo
    arc_detect
    if [[ -n "$ARC_PCI_ADDR" ]]; then
        _row true  "Arc GPU detected"      "$ARC_PCI_ADDR  [${ARC_PCI_ID}]"
    else
        _row false "Arc GPU detected"      "not found — check PCIe slot / BIOS"
    fi

    arc_driver_loaded  && drv_ok=true  || drv_ok=false
    arc_driver_bound   && bnd_ok=true  || bnd_ok=false
    _row $drv_ok "Kernel driver loaded"   "$(arc_driver_name || echo 'none')"
    _row $bnd_ok "Driver bound to GPU"    ""

    local rnode; rnode=$(arc_render_node)
    [[ -n "$rnode" ]] && rnode_ok=true || rnode_ok=false
    arc_render_access  && acc_ok=true  || acc_ok=false
    _row $rnode_ok "Render node present"  "${rnode:-/dev/dri/renderD* missing}"
    _row $acc_ok   "Render node writable" "$(arc_user_groups_ok || echo 'add user to render+video groups')"

    arc_opencl_pkg_ok  && cl_ok=true   || cl_ok=false
    arc_opencl_ok      && cli_ok=true  || cli_ok=false
    _row $cl_ok  "intel-opencl-icd pkg"   ""
    _row $cli_ok "OpenCL device visible"  "$(clinfo 2>/dev/null | grep -i 'device name' | grep -i intel | head -1 | sed 's/.*: //' || echo 'none')"

    arc_levelzero_ok   && ze_ok=true   || ze_ok=false
    _row $ze_ok  "Level Zero runtime"     ""

    local oneapi_root; oneapi_root=$(arc_oneapi_root 2>/dev/null) || true
    arc_oneapi_ok      && oa_ok=true   || oa_ok=false
    arc_sycl_sees_gpu  && sy_ok=true   || sy_ok=false
    _row $oa_ok  "oneAPI / icpx"          "${oneapi_root:-not installed}"
    _row $sy_ok  "SYCL sees GPU"          ""
    echo
}

# ── Auto-fix (non-interactive, logs to ARC_FIX_LOG) ──────────────────────────

arc_quick_fix() {
    local user="${USER:-$(whoami)}"
    mkdir -p "$(dirname "$ARC_FIX_LOG")"
    {
        echo "arc_quick_fix run: $(date)"

        # Groups
        for grp in render video; do
            if getent group "$grp" &>/dev/null; then
                if ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
                    sudo usermod -aG "$grp" "$user" 2>&1 && \
                        echo "FIXED: added $user to group $grp" || \
                        echo "FAIL: could not add $user to $grp"
                fi
            fi
        done

        # OpenCL + Level Zero packages
        for pkg in intel-opencl-icd libze-intel-gpu1 clinfo; do
            dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' && continue
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>&1 && \
                echo "FIXED: installed $pkg" || echo "FAIL: could not install $pkg"
        done

        # Kernel driver
        if ! arc_driver_loaded; then
            local kver; kver=$(uname -r)
            local kmaj kmin
            kmaj=$(cut -d. -f1 <<< "$kver"); kmin=$(cut -d. -f2 <<< "$kver")
            local drv="i915"
            (( kmaj > 6 || (kmaj == 6 && kmin >= 8) )) && drv="xe"
            sudo modprobe "$drv" 2>&1 && echo "FIXED: loaded $drv" || echo "FAIL: modprobe $drv"
        fi

        # Profile env vars
        local profile="/etc/profile.d/arc-llamacpp.sh"
        if [[ ! -f "$profile" ]]; then
            sudo tee "$profile" > /dev/null << 'ARCENV'
export ONEAPI_DEVICE_SELECTOR=level_zero:0
export ZES_ENABLE_SYSMAN=1
export SYCL_CACHE_PERSISTENT=1
export GGML_SYCL_DEVICE=0
ARCENV
            sudo chmod 644 "$profile"
            echo "FIXED: created $profile"
        fi

        echo "arc_quick_fix done: $(date)"
    } >> "$ARC_FIX_LOG" 2>&1
}

# Silently run arc_detect on source so ARC_PCI_ADDR is populated
arc_detect &>/dev/null || true
