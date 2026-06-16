#!/bin/bash
# lib/arc_check.sh — sourceable Intel Arc A770 status library
#
# Public API:
#   arc_detect          → sets ARC_PCI_ADDR, ARC_PCI_ID; returns 0 if Arc found
#   arc_driver_loaded   → returns 0 if xe or i915 is bound to GPU
#   arc_render_access   → returns 0 if /dev/dri/renderD* is accessible
#   arc_opencl_ok       → returns 0 if clinfo shows Intel device
#   arc_levelzero_ok    → returns 0 if Level Zero is available (apt OR oneAPI)
#   arc_oneapi_ok       → returns 0 if oneAPI+icpx are functional
#   arc_sycl_sees_gpu   → returns 0 if sycl-ls sees the GPU
#   arc_user_groups_ok  → returns 0 if user is in render+video groups
#   arc_quick_fix       → applies fixes for common issues; logs to ARC_FIX_LOG
#   arc_status_line     → one-line summary, no colour codes
#   arc_full_status     → coloured multi-line table
#   arc_all_ok          → returns 0 only if all critical checks pass
# ─────────────────────────────────────────────────────────────────────────────

# Arc/DG2 PCI device IDs (Alchemist / DG2 family)
_ARC_IDS=("56a0" "56a1" "56a5" "56a6" "5690" "5691" "5692" "56b0" "56b1" "56c0" "56c1")

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

arc_driver_loaded() { lsmod 2>/dev/null | grep -qE "^(xe|i915) "; }
arc_driver_name()   { lsmod 2>/dev/null | grep -oE "^(xe|i915)" | head -1; }

arc_driver_bound() {
    [[ -z "$ARC_PCI_ADDR" ]] && arc_detect
    [[ -z "$ARC_PCI_ADDR" ]] && return 1
    local drv="/sys/bus/pci/devices/0000:${ARC_PCI_ADDR}/driver"
    [[ -L "$drv" ]] && basename "$(readlink "$drv")" | grep -qE "^(xe|i915)$"
}

# ── DRM access ────────────────────────────────────────────────────────────────

arc_render_node()   { ls /dev/dri/renderD* 2>/dev/null | head -1; }
arc_render_access() {
    local node; node=$(arc_render_node)
    [[ -n "$node" && -r "$node" && -w "$node" ]]
}

# ── User groups ───────────────────────────────────────────────────────────────

arc_user_groups_ok() {
    local user="${USER:-$(whoami)}" ok=true
    for grp in render video; do
        getent group "$grp" &>/dev/null || continue
        id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp" || ok=false
    done
    $ok
}

# ── OpenCL ────────────────────────────────────────────────────────────────────

arc_opencl_pkg_ok() {
    dpkg -l intel-opencl-icd 2>/dev/null | grep -q '^ii'
}

# FIX: was grep -qi "...\|..." (BRE alternation — unreliable across distros)
#      now uses grep -Eqi (ERE) where | is proper alternation
arc_opencl_ok() {
    command -v clinfo &>/dev/null || return 1
    clinfo 2>/dev/null | grep -Eqi "Device Name.*(Intel|Arc)"
}

# Returns the Intel device name from clinfo, or empty string
arc_opencl_device_name() {
    command -v clinfo &>/dev/null || return 1
    # clinfo uses whitespace (not colon) as key-value separator:
    #   "  Device Name                                     Intel(R) Arc(TM) A770 Graphics"
    # awk picks the last field(s) by skipping the key prefix
    clinfo 2>/dev/null \
        | grep -Ei "Device Name" \
        | grep -Ei "Intel|Arc" \
        | head -1 \
        | sed 's/^[[:space:]]*//' \
        | awk '{for(i=1;i<=NF;i++) if($i~/Intel|Arc|Xe/) {out=""; for(j=i;j<=NF;j++) out=out" "$j; print out; exit}}'
}

# ── Level Zero ────────────────────────────────────────────────────────────────

# FIX: old version only checked the apt package (libze-intel-gpu1).
#      oneAPI 2026.x bundles its own Level Zero — installing the apt package
#      alongside it creates two conflicting runtimes and breaks sycl-ls.
#      Now checks apt package OR oneAPI-bundled Level Zero.
arc_levelzero_ok() {
    # Path 1: apt package installed
    if dpkg -l libze-intel-gpu1 2>/dev/null | grep -q '^ii'; then
        # Verify it actually sees the device if ze_info is available
        if command -v ze_info &>/dev/null; then
            ZES_ENABLE_SYSMAN=1 ze_info 2>/dev/null | grep -Eqi "Intel|Arc|Xe" && return 0
            return 1
        fi
        return 0  # package present, ze_info not installed — assume ok
    fi
    # Path 2: oneAPI bundles Level Zero (preferred when oneAPI is installed)
    local root; root=$(arc_oneapi_root 2>/dev/null) || return 1
    [[ -f "${root}/setvars.sh" ]] && \
        bash -c "source '${root}/setvars.sh' --force &>/dev/null && \
                 ZES_ENABLE_SYSMAN=1 ze_info 2>/dev/null | grep -Eqi 'Intel|Arc|Xe'" \
        && return 0
    # oneAPI present but ze_info check failed — SYCL may still work
    return 1
}

# Returns a human-readable Level Zero source
arc_levelzero_source() {
    dpkg -l libze-intel-gpu1 2>/dev/null | grep -q '^ii' && { echo "apt (libze-intel-gpu1)"; return; }
    local root; root=$(arc_oneapi_root 2>/dev/null) && echo "oneAPI (${root})" && return
    echo "not found"
}

# ── oneAPI / SYCL ─────────────────────────────────────────────────────────────

arc_oneapi_root() {
    for loc in /opt/intel/oneapi /opt/intel/inteloneapi "$HOME/intel/oneapi"; do
        [[ -f "${loc}/setvars.sh" ]] && echo "$loc" && return 0
    done
    command -v icpx &>/dev/null && dirname "$(dirname "$(command -v icpx)")" && return 0
    return 1
}

arc_oneapi_ok() {
    local root; root=$(arc_oneapi_root) || return 1
    [[ -f "${root}/setvars.sh" ]] && \
        bash -c "source '${root}/setvars.sh' --force &>/dev/null && command -v icpx &>/dev/null"
}

arc_sycl_sees_gpu() {
    local root; root=$(arc_oneapi_root) || return 1
    [[ -f "${root}/setvars.sh" ]] || return 1
    bash -c "source '${root}/setvars.sh' --force &>/dev/null && \
             ONEAPI_DEVICE_SELECTOR='level_zero:*' sycl-ls 2>/dev/null" \
        | grep -Eqi "Intel|Arc|Xe"
}

# ── Aggregate ─────────────────────────────────────────────────────────────────

# Critical checks only: GPU visible + driver loaded + render accessible + groups
# oneAPI/SYCL/Level Zero are non-critical (GPU still works via Vulkan/OpenCL)
arc_all_ok() {
    arc_detect         || return 1
    arc_driver_loaded  || return 1
    arc_render_access  || return 1
    arc_user_groups_ok || return 1
    return 0
}

# ── Status output helpers ─────────────────────────────────────────────────────

arc_status_line() {
    if ! arc_detect; then
        echo "Arc GPU: NOT DETECTED"; return
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

# Multi-line coloured table
# FIX: was using ${B_GREEN:-$'\033[...]'} which inherits the *parent* shell's
#      B_GREEN variable.  The gasket defines colours with single quotes
#      ('\033[...]') making \033 a literal string, not an ESC byte.
#      Now always defines its own properly-escaped colour constants so the
#      table renders correctly regardless of how the parent script defines them.
arc_full_status() {
    # Always define our own — never inherit from parent shell
    local _G=$'\033[0;32m'   # green
    local _R=$'\033[0;31m'   # red
    local _Y=$'\033[1;33m'   # yellow
    local _C=$'\033[0;36m'   # cyan
    local _D=$'\033[0m'      # reset

    _arc_row() {
        local ok="$1" label="$2" detail="${3:-}"
        if $ok; then
            printf "  ${_G}✔${_D}  %-32s %s\n" "$label" "$detail"
        else
            printf "  ${_R}✘${_D}  %-32s ${_Y}%s${_D}\n" "$label" "$detail"
        fi
    }

    echo
    arc_detect
    if [[ -n "$ARC_PCI_ADDR" ]]; then
        _arc_row true  "Arc GPU detected"       "$ARC_PCI_ADDR  [${ARC_PCI_ID}]"
    else
        _arc_row false "Arc GPU detected"       "not found — check PCIe slot / BIOS"
    fi

    local drv_ok=false bnd_ok=false
    arc_driver_loaded && drv_ok=true
    arc_driver_bound  && bnd_ok=true
    _arc_row $drv_ok "Kernel driver loaded"    "$(arc_driver_name || echo 'none')"
    _arc_row $bnd_ok "Driver bound to GPU"     ""

    local rnode; rnode=$(arc_render_node)
    local rnode_ok=false acc_ok=false
    [[ -n "$rnode" ]]   && rnode_ok=true
    arc_render_access   && acc_ok=true
    _arc_row $rnode_ok "Render node present"   "${rnode:-/dev/dri/renderD* missing}"
    _arc_row $acc_ok   "Render node writable"  \
        "$(arc_user_groups_ok || echo 'add user to render+video groups')"

    local cl_ok=false cli_ok=false
    arc_opencl_pkg_ok && cl_ok=true
    arc_opencl_ok     && cli_ok=true
    _arc_row $cl_ok  "intel-opencl-icd pkg"    ""
    # FIX: use arc_opencl_device_name() which handles clinfo's whitespace format
    local _cl_dev; _cl_dev=$(arc_opencl_device_name)
    _arc_row $cli_ok "OpenCL device visible"   "${_cl_dev:-none}"

    local ze_ok=false
    arc_levelzero_ok && ze_ok=true
    _arc_row $ze_ok  "Level Zero runtime"      "$(arc_levelzero_source)"

    local oneapi_root; oneapi_root=$(arc_oneapi_root 2>/dev/null) || true
    local oa_ok=false sy_ok=false
    arc_oneapi_ok     && oa_ok=true
    arc_sycl_sees_gpu && sy_ok=true
    _arc_row $oa_ok "oneAPI / icpx"            "${oneapi_root:-not installed}"
    _arc_row $sy_ok "SYCL sees GPU"            \
        "$($sy_ok || echo 'SYCL OOM fix: set SYCL_PI_LEVEL_ZERO_USM_ALLOCATOR=1')"

    # Non-critical warning when SYCL is broken but driver/render are fine
    if arc_all_ok && ! $sy_ok; then
        echo ""
        printf "  ${_Y}⚠  SYCL/Level Zero issue — basic GPU use (Vulkan/OpenCL) still works.${_D}\n"
        printf "  ${_Y}   If oneAPI was working before the last fix, check for Level Zero${_D}\n"
        printf "  ${_Y}   conflicts: 'apt list --installed | grep libze'${_D}\n"
    fi
    echo
}

# ── Auto-fix ─────────────────────────────────────────────────────────────────

arc_quick_fix() {
    local user="${USER:-$(whoami)}"
    mkdir -p "$(dirname "$ARC_FIX_LOG")"
    {
        echo "arc_quick_fix run: $(date)"

        # ── Groups ──
        for grp in render video; do
            if getent group "$grp" &>/dev/null; then
                if ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
                    sudo usermod -aG "$grp" "$user" 2>&1 \
                        && echo "FIXED: added $user to group $grp (log out/in to take effect)" \
                        || echo "FAIL: could not add $user to $grp"
                else
                    echo "OK: $user already in group $grp"
                fi
            fi
        done

        # ── OpenCL ICD ──
        # (always safe to install alongside oneAPI)
        for pkg in intel-opencl-icd clinfo; do
            if ! dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>&1 \
                    && echo "FIXED: installed $pkg" \
                    || echo "FAIL: could not install $pkg"
            else
                echo "OK: $pkg already installed"
            fi
        done

        # ── Level Zero — SKIP if oneAPI is installed ──
        # FIX: installing the apt libze-intel-gpu1 alongside oneAPI creates
        #      two competing Level Zero runtimes, which breaks sycl-ls.
        #      oneAPI 2026.x already bundles a compatible Level Zero.
        if arc_oneapi_ok 2>/dev/null; then
            echo "SKIP: libze-intel-gpu1 — oneAPI provides Level Zero (apt version would conflict)"
        else
            if ! dpkg -l libze-intel-gpu1 2>/dev/null | grep -q '^ii'; then
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libze-intel-gpu1 2>&1 \
                    && echo "FIXED: installed libze-intel-gpu1" \
                    || echo "FAIL: could not install libze-intel-gpu1"
            else
                echo "OK: libze-intel-gpu1 already installed"
            fi
        fi

        # ── Refresh dynamic linker after any package installs ──
        sudo ldconfig 2>&1 && echo "FIXED: ldconfig refreshed"

        # ── Kernel driver ──
        if ! arc_driver_loaded; then
            local kver; kver=$(uname -r)
            local kmaj kmin
            kmaj=$(cut -d. -f1 <<< "$kver"); kmin=$(cut -d. -f2 <<< "$kver")
            local drv="i915"
            (( kmaj > 6 || (kmaj == 6 && kmin >= 8) )) && drv="xe"
            sudo modprobe "$drv" 2>&1 \
                && echo "FIXED: loaded $drv" \
                || echo "FAIL: modprobe $drv"
        else
            echo "OK: kernel driver already loaded ($(arc_driver_name))"
        fi

        # ── Environment profile ──
        local profile="/etc/profile.d/arc-llamacpp.sh"
        if [[ ! -f "$profile" ]]; then
            sudo tee "$profile" > /dev/null << 'ARCENV'
# Intel Arc A770 — llama.cpp environment  (written by arc_quick_fix)
export ONEAPI_DEVICE_SELECTOR=level_zero:0
export ZES_ENABLE_SYSMAN=1
export SYCL_CACHE_PERSISTENT=1
export GGML_SYCL_DEVICE=0
# USM memory pool — prevents "could not create a memory object" OOM crashes
export SYCL_PI_LEVEL_ZERO_USM_ALLOCATOR=1
export ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE
ARCENV
            sudo chmod 644 "$profile"
            echo "FIXED: created $profile (source it or log out/in)"
        else
            # Ensure USM pool vars are present in existing profile
            if ! grep -q "SYCL_PI_LEVEL_ZERO_USM_ALLOCATOR" "$profile"; then
                sudo bash -c "cat >> '$profile' << 'ADDENV'
# USM memory pool — added by arc_quick_fix (prevents SYCL OOM)
export SYCL_PI_LEVEL_ZERO_USM_ALLOCATOR=1
export ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE
ADDENV"
                echo "FIXED: added USM pool vars to existing $profile"
            else
                echo "OK: $profile already has USM pool vars"
            fi
        fi

        echo "arc_quick_fix done: $(date)"
        echo "NOTE: if oneAPI/SYCL was working before this fix, run:"
        echo "  source /opt/intel/oneapi/setvars.sh --force"
        echo "  to restore oneAPI environment in your current shell."

    } >> "$ARC_FIX_LOG" 2>&1
}

# Silently populate ARC_PCI_ADDR on source
arc_detect &>/dev/null || true
