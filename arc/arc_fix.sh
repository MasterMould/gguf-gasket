#!/usr/bin/env bash
# =============================================================================
#  arc-fix.sh — Intel Arc A770 diagnostic & auto-repair for llama.cpp
#
#  Tests every layer of the GPU stack, reports pass/fail/warn per item,
#  and can automatically fix most common issues.
#
#  Run as a normal user (sudo will be requested only when needed).
#  Usage:  chmod +x arc-fix.sh && ./arc-fix.sh
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'
C='\033[0;36m'; M='\033[0;35m'; W='\033[1;37m'; D='\033[0;90m'; N='\033[0m'
BOLD='\033[1m'

PASS="${G}[PASS]${N}"; FAIL="${R}[FAIL]${N}"; WARN="${Y}[WARN]${N}"
INFO="${B}[INFO]${N}"; FIX="${M}[ FIX]${N}"; SKIP="${D}[SKIP]${N}"

# ── Arc A770 PCI IDs (Intel Alchemist / DG2) ──────────────────────────────────
ARC_PCIIDS=("56a0" "56a1" "56a5" "56a6" "5690" "5691" "5692" "56b0" "56b1" "56c0" "56c1")

# ── Global results tracking ───────────────────────────────────────────────────
declare -a RESULTS=()       # "PASS|WARN|FAIL  description"
declare -a FIXES_APPLIED=() # human-readable log of fixes done
declare -a FIXES_NEEDED=()  # fixes that couldn't be auto-applied
TOTAL_PASS=0; TOTAL_WARN=0; TOTAL_FAIL=0

# ── Helpers ───────────────────────────────────────────────────────────────────
log_result() {
    local lvl="$1" msg="$2"
    RESULTS+=("$lvl  $msg")
    case "$lvl" in
        PASS) (( TOTAL_PASS++ )) ;;
        WARN) (( TOTAL_WARN++ )) ;;
        FAIL) (( TOTAL_FAIL++ )) ;;
    esac
}

record_fix()   { FIXES_APPLIED+=("$1"); }
needs_manual() { FIXES_NEEDED+=("$1"); }

sep()      { echo -e "${D}$(printf '─%.0s' {1..70})${N}"; }
section()  { echo; sep; echo -e "  ${W}${BOLD}$1${N}"; sep; echo; }
print_row() {
    local icon="$1" label="$2" detail="${3:-}"
    printf "  %-8s %-42s %s\n" "$icon" "$label" "$detail"
}

# Run command silently; return its exit code.
quietly() { "$@" &>/dev/null; }

# Run with sudo, caching creds for the session.
SUDO_OK=false
ensure_sudo() {
    if $SUDO_OK; then return 0; fi
    echo -e "\n  ${Y}Some fixes require sudo. Enter your password if prompted.${N}"
    if sudo -v 2>/dev/null; then SUDO_OK=true; return 0; fi
    echo -e "  ${R}sudo not available — skipping fixes that need root.${N}"
    return 1
}

# apt install wrapper — only installs what's missing.
apt_install() {
    local pkgs=("$@")
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" &>/dev/null && dpkg -l "$p" 2>/dev/null | grep -q '^ii' || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    echo -e "  ${FIX} Installing: ${W}${missing[*]}${N}"
    ensure_sudo || { needs_manual "apt install ${missing[*]}"; return 1; }
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${missing[@]}" 2>&1 \
        | grep -E "^(Get:|Unpacking|Setting up|E:)" || true
    record_fix "Installed packages: ${missing[*]}"
}

# ── Section 1: Hardware Detection ────────────────────────────────────────────
check_hardware() {
    section "1 · Hardware Detection"

    # lspci available?
    if ! command -v lspci &>/dev/null; then
        print_row "$WARN" "lspci" "not found — installing pciutils"
        apt_install pciutils || true
    fi

    if ! command -v lspci &>/dev/null; then
        print_row "$FAIL" "lspci" "cannot proceed without PCI enumeration"
        log_result FAIL "lspci not available"
        return
    fi

    # Scan for any Arc/DG2 GPU
    local found_id="" found_line="" pci_addr=""
    for id in "${ARC_PCIIDS[@]}"; do
        local line; line=$(lspci -nn 2>/dev/null | grep -i "8086:${id}" | head -1) || true
        if [[ -n "$line" ]]; then
            found_id="$id"; found_line="$line"
            pci_addr=$(echo "$line" | awk '{print $1}')
            break
        fi
    done

    if [[ -n "$found_id" ]]; then
        print_row "$PASS" "Arc GPU found" "${D}${found_line}${N}"
        log_result PASS "Arc GPU detected: $found_line"
        GPU_PCI_ADDR="$pci_addr"
        GPU_PCI_ID="$found_id"
    else
        # Broader search
        local intel_gpu; intel_gpu=$(lspci -nn 2>/dev/null | grep -iE "VGA|3D|Display" | grep -i "8086" | head -3) || true
        if [[ -n "$intel_gpu" ]]; then
            print_row "$WARN" "Intel GPU found (not A770?)" "${D}${intel_gpu}${N}"
            log_result WARN "Intel GPU found but PCI ID not in Arc A770 list"
            GPU_PCI_ADDR=$(echo "$intel_gpu" | head -1 | awk '{print $1}')
            GPU_PCI_ID="unknown"
        else
            print_row "$FAIL" "No Intel Arc GPU detected" "Check PCIe slot / BIOS"
            log_result FAIL "No Intel Arc GPU found via lspci"
            needs_manual "Verify the Arc A770 is seated in a PCIe x16 slot and the BIOS has iGPU disabled or set to external GPU priority"
            GPU_PCI_ADDR=""; GPU_PCI_ID=""
        fi
    fi

    # BIOS / discrete GPU mode
    local resizable_bar; resizable_bar=$(lspci -vv 2>/dev/null | grep -i "resizable BAR\|ReBAR" | head -1) || true
    if [[ -n "$resizable_bar" ]]; then
        print_row "$INFO" "Resizable BAR" "${D}${resizable_bar}${N}"
    fi

    # lspci verbose — IOMMU group check
    if [[ -n "$GPU_PCI_ADDR" ]]; then
        local iommu_group; iommu_group=$(find /sys/kernel/iommu_groups -name "$GPU_PCI_ADDR*" 2>/dev/null | head -1) || true
        if [[ -n "$iommu_group" ]]; then
            print_row "$PASS" "IOMMU group" "${D}${iommu_group}${N}"
        fi
    fi
}

# ── Section 2: Kernel Driver ─────────────────────────────────────────────────
check_kernel_driver() {
    section "2 · Kernel Driver"

    local kver; kver=$(uname -r)
    print_row "$INFO" "Kernel" "$kver"

    # Parse major.minor
    local kmaj kmin
    kmaj=$(echo "$kver" | cut -d. -f1)
    kmin=$(echo "$kver" | cut -d. -f2)

    # Kernel ≥ 6.8 → xe driver is default for Arc; older → i915
    local expected_driver="i915"
    if (( kmaj > 6 || (kmaj == 6 && kmin >= 8) )); then
        expected_driver="xe"
    fi
    print_row "$INFO" "Expected driver" "$expected_driver (kernel $kver)"

    # xe loaded?
    local xe_loaded=false i915_loaded=false
    if lsmod 2>/dev/null | grep -q "^xe "; then
        xe_loaded=true
        print_row "$PASS" "xe module loaded" ""
        log_result PASS "xe kernel module loaded"
    else
        print_row "$WARN" "xe module not loaded" ""
    fi

    if lsmod 2>/dev/null | grep -q "^i915 "; then
        i915_loaded=true
        print_row "$PASS" "i915 module loaded" ""
        log_result PASS "i915 kernel module loaded"
    fi

    if ! $xe_loaded && ! $i915_loaded; then
        log_result FAIL "Neither xe nor i915 kernel module is loaded"
        echo -e "  ${FIX} Attempting to load ${expected_driver}…"
        if ensure_sudo; then
            if sudo modprobe "$expected_driver" 2>/dev/null; then
                print_row "$PASS" "modprobe $expected_driver" "loaded successfully"
                record_fix "Loaded kernel module: $expected_driver"
                log_result PASS "Loaded $expected_driver via modprobe"
            else
                print_row "$FAIL" "modprobe $expected_driver failed" "see dmesg"
                log_result FAIL "modprobe $expected_driver failed"
                needs_manual "Check 'dmesg | grep -i xe' and ensure linux-firmware is installed"
            fi
        fi
    fi

    # Driver bound to our GPU
    if [[ -n "${GPU_PCI_ADDR:-}" ]]; then
        local drv_path="/sys/bus/pci/devices/0000:${GPU_PCI_ADDR}/driver"
        if [[ -L "$drv_path" ]]; then
            local drv_name; drv_name=$(basename "$(readlink "$drv_path")")
            if [[ "$drv_name" == "$expected_driver" || "$drv_name" == "i915" || "$drv_name" == "xe" ]]; then
                print_row "$PASS" "Driver bound to GPU" "$drv_name"
                log_result PASS "GPU bound to driver: $drv_name"
            else
                print_row "$WARN" "Driver bound to GPU" "${Y}${drv_name}${N} (expected ${expected_driver})"
                log_result WARN "GPU bound to unexpected driver: $drv_name"
            fi
        else
            print_row "$FAIL" "No driver bound to GPU" "$GPU_PCI_ADDR"
            log_result FAIL "No driver bound to GPU at $GPU_PCI_ADDR"
            needs_manual "Try: echo '0000:${GPU_PCI_ADDR}' | sudo tee /sys/bus/pci/drivers/${expected_driver}/bind"
        fi
    fi

    # Firmware
    local fw_path="/lib/firmware/xe"
    local fw_path2="/lib/firmware/i915"
    if [[ -d "$fw_path" ]] || [[ -d "$fw_path2" ]]; then
        print_row "$PASS" "GPU firmware present" "/lib/firmware/{xe,i915}"
        log_result PASS "GPU firmware directory exists"
    else
        print_row "$FAIL" "GPU firmware missing" ""
        log_result FAIL "GPU firmware not found in /lib/firmware"
        echo -e "  ${FIX} Installing linux-firmware…"
        apt_install linux-firmware && {
            print_row "$PASS" "linux-firmware installed" ""
            record_fix "Installed linux-firmware"
        }
    fi
}

# ── Section 3: DRM / Render Nodes ────────────────────────────────────────────
check_drm_nodes() {
    section "3 · DRM Render Nodes"

    if [[ ! -d /dev/dri ]]; then
        print_row "$FAIL" "/dev/dri" "directory does not exist"
        log_result FAIL "/dev/dri missing — GPU not initialised by kernel driver"
        needs_manual "Ensure the kernel driver loaded (section 2) and reboot"
        return
    fi

    local cards; cards=$(ls /dev/dri/card* 2>/dev/null) || true
    local renders; renders=$(ls /dev/dri/renderD* 2>/dev/null) || true

    if [[ -n "$cards" ]]; then
        for c in $cards; do
            print_row "$PASS" "DRM card node" "$c"
            log_result PASS "DRM card node: $c"
        done
    else
        print_row "$FAIL" "No /dev/dri/card* nodes" ""
        log_result FAIL "No DRM card nodes"
    fi

    if [[ -n "$renders" ]]; then
        for r in $renders; do
            local perms; perms=$(stat -c "%a %G" "$r" 2>/dev/null) || true
            print_row "$PASS" "Render node" "$r  ${D}(${perms})${N}"
            log_result PASS "Render node: $r"
        done
    else
        print_row "$FAIL" "No /dev/dri/renderD* nodes" ""
        log_result FAIL "No DRM render nodes — compute workloads will fail"
        needs_manual "Reboot after loading the kernel driver; render nodes should appear"
    fi

    # Check if GPU is linked to a by-path/by-id symlink (good sign)
    local links; links=$(ls /dev/dri/by-path/ 2>/dev/null | grep -i "pci" | head -3) || true
    if [[ -n "$links" ]]; then
        print_row "$PASS" "PCI symlinks" "${D}${links}${N}"
    fi
}

# ── Section 4: User / Group Permissions ──────────────────────────────────────
check_permissions() {
    section "4 · User & Group Permissions"

    local user="${USER:-$(whoami)}"
    print_row "$INFO" "Running as" "$user"

    local -a required_groups=("render" "video")

    for grp in "${required_groups[@]}"; do
        if getent group "$grp" &>/dev/null; then
            if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
                print_row "$PASS" "Group: $grp" "user is a member"
                log_result PASS "User in group: $grp"
            else
                print_row "$FAIL" "Group: $grp" "${R}user NOT a member${N}"
                log_result FAIL "User $user not in group $grp"
                echo -e "  ${FIX} Adding $user to group $grp…"
                if ensure_sudo; then
                    sudo usermod -aG "$grp" "$user" && {
                        record_fix "Added $user to group: $grp"
                        print_row "$PASS" "Added to $grp" "${Y}log out & back in to take effect${N}"
                    } || print_row "$FAIL" "usermod failed" ""
                fi
            fi
        else
            print_row "$WARN" "Group: $grp" "${D}group does not exist on this system${N}"
            log_result WARN "Group $grp does not exist"
        fi
    done

    # Check render node ownership/permission for current user
    local rnode; rnode=$(ls /dev/dri/renderD* 2>/dev/null | head -1) || true
    if [[ -n "$rnode" ]]; then
        if [[ -r "$rnode" && -w "$rnode" ]]; then
            print_row "$PASS" "Render node accessible" "$rnode"
            log_result PASS "Render node readable/writable"
        else
            local rnode_grp; rnode_grp=$(stat -c "%G" "$rnode" 2>/dev/null) || true
            print_row "$WARN" "Render node not accessible" "${Y}${rnode} owned by group: ${rnode_grp}${N}"
            log_result WARN "Cannot access $rnode — group membership may not have taken effect yet"
            needs_manual "Log out and back in (or run 'newgrp render') for group membership to take effect"
        fi
    fi
}

# ── Section 5: Compute Runtime (OpenCL + Level Zero) ─────────────────────────
check_compute_runtime() {
    section "5 · Compute Runtime (OpenCL / Level Zero)"

    # Detect whether Intel's own apt repo is configured
    local intel_repo=false
    if grep -rq "intel.com/oneapi\|packages.intel.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        intel_repo=true
        print_row "$PASS" "Intel apt repo" "configured"
        log_result PASS "Intel apt repository configured"
    else
        print_row "$WARN" "Intel apt repo" "${Y}not configured${N} — using Ubuntu universe"
        log_result WARN "Intel apt repo not configured; packages may be older"
        echo
        echo -e "  ${D}  For latest drivers, add Intel's repo:${N}"
        echo -e "  ${D}  https://dgpu-docs.intel.com/driver/installation.html${N}"
        echo
        needs_manual "Add Intel GPU apt repo for latest compute-runtime: https://dgpu-docs.intel.com/driver/installation.html"
    fi

    # ── OpenCL ──
    echo -e "  ${D}OpenCL${N}"

    # ocl-icd-libopencl1 (the ICD loader)
    if dpkg -l ocl-icd-libopencl1 2>/dev/null | grep -q '^ii'; then
        print_row "$PASS" "ocl-icd-libopencl1" "ICD loader present"
        log_result PASS "OpenCL ICD loader installed"
    else
        print_row "$FAIL" "ocl-icd-libopencl1" "missing"
        log_result FAIL "OpenCL ICD loader not installed"
        apt_install ocl-icd-libopencl1 && record_fix "Installed ocl-icd-libopencl1"
    fi

    # intel-opencl-icd (Intel's OpenCL implementation)
    if dpkg -l intel-opencl-icd 2>/dev/null | grep -q '^ii'; then
        local ver; ver=$(dpkg -l intel-opencl-icd | awk '/^ii/{print $3}')
        print_row "$PASS" "intel-opencl-icd" "v${ver}"
        log_result PASS "Intel OpenCL ICD installed"
    else
        print_row "$FAIL" "intel-opencl-icd" "missing"
        log_result FAIL "Intel OpenCL ICD not installed"
        apt_install intel-opencl-icd && record_fix "Installed intel-opencl-icd"
    fi

    # clinfo test
    if ! command -v clinfo &>/dev/null; then
        print_row "$WARN" "clinfo" "not installed"
        apt_install clinfo && record_fix "Installed clinfo"
    fi

    if command -v clinfo &>/dev/null; then
        local cl_platforms; cl_platforms=$(clinfo --list 2>/dev/null | grep -c "Platform #" || echo "0")
        local cl_intel; cl_intel=$(clinfo 2>/dev/null | grep -i "intel\|arc\|xe" | head -3) || true
        if [[ "$cl_platforms" -gt 0 ]]; then
            print_row "$PASS" "clinfo" "${cl_platforms} platform(s) found"
            log_result PASS "OpenCL platforms detected by clinfo"
        else
            print_row "$FAIL" "clinfo" "0 platforms — GPU not visible via OpenCL"
            log_result FAIL "No OpenCL platforms found"
        fi
        if [[ -n "$cl_intel" ]]; then
            print_row "$PASS" "Intel device in clinfo" ""
        fi
    fi

    echo
    echo -e "  ${D}Level Zero${N}"

    # libze-intel-gpu1 (Level Zero Intel GPU plugin)
    if dpkg -l libze-intel-gpu1 2>/dev/null | grep -q '^ii'; then
        local ver; ver=$(dpkg -l libze-intel-gpu1 | awk '/^ii/{print $3}')
        print_row "$PASS" "libze-intel-gpu1" "v${ver}"
        log_result PASS "Level Zero Intel GPU runtime installed"
    else
        print_row "$FAIL" "libze-intel-gpu1" "missing"
        log_result FAIL "Level Zero Intel GPU plugin not installed"
        apt_install libze-intel-gpu1 && record_fix "Installed libze-intel-gpu1"
    fi

    # level-zero / libze1 loader
    local ze_loader_ok=false
    for pkg in libze1 level-zero; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            ze_loader_ok=true
            local ver; ver=$(dpkg -l "$pkg" | awk '/^ii/{print $3}')
            print_row "$PASS" "$pkg" "v${ver}"
            log_result PASS "Level Zero loader ($pkg) installed"
            break
        fi
    done
    if ! $ze_loader_ok; then
        print_row "$FAIL" "Level Zero loader" "libze1 or level-zero not found"
        log_result FAIL "Level Zero loader missing"
        apt_install libze1 2>/dev/null || apt_install level-zero 2>/dev/null || \
            needs_manual "Install level-zero loader: apt install libze1"
    fi

    # intel-igc-opencl (Intel graphics compiler for OpenCL)
    if dpkg -l intel-igc-opencl 2>/dev/null | grep -q '^ii' 2>/dev/null; then
        print_row "$PASS" "intel-igc-opencl" "Intel graphics compiler"
        log_result PASS "Intel IGC OpenCL installed"
    else
        print_row "$WARN" "intel-igc-opencl" "${D}optional compiler package${N}"
        # Try to install; not in all repos
        if apt-cache show intel-igc-opencl &>/dev/null; then
            apt_install intel-igc-opencl 2>/dev/null && record_fix "Installed intel-igc-opencl" || true
        fi
    fi

    # Ze info (level zero device listing)
    if command -v ze_info &>/dev/null; then
        local ze_out; ze_out=$(ZES_ENABLE_SYSMAN=1 ze_info 2>/dev/null) || true
        if echo "$ze_out" | grep -qi "intel\|arc\|xe"; then
            print_row "$PASS" "ze_info" "Intel device visible"
            log_result PASS "Level Zero sees Intel device"
        else
            print_row "$WARN" "ze_info" "no Intel device listed"
            log_result WARN "Level Zero does not list Intel device"
        fi
    fi
}

# ── Section 6: Vulkan ────────────────────────────────────────────────────────
check_vulkan() {
    section "6 · Vulkan"

    # mesa vulkan (ANV = Intel Vulkan in Mesa)
    if dpkg -l mesa-vulkan-drivers 2>/dev/null | grep -q '^ii'; then
        local ver; ver=$(dpkg -l mesa-vulkan-drivers | awk '/^ii/{print $3}')
        print_row "$PASS" "mesa-vulkan-drivers" "v${ver} (ANV included)"
        log_result PASS "Mesa Vulkan drivers (ANV) installed"
    else
        print_row "$FAIL" "mesa-vulkan-drivers" "missing"
        log_result FAIL "Mesa Vulkan drivers not installed"
        apt_install mesa-vulkan-drivers && record_fix "Installed mesa-vulkan-drivers"
    fi

    # libvulkan1
    if dpkg -l libvulkan1 2>/dev/null | grep -q '^ii'; then
        print_row "$PASS" "libvulkan1" "Vulkan loader"
        log_result PASS "Vulkan loader installed"
    else
        print_row "$FAIL" "libvulkan1" "Vulkan loader missing"
        log_result FAIL "Vulkan loader not installed"
        apt_install libvulkan1 && record_fix "Installed libvulkan1"
    fi

    # vulkan-tools (optional — for vulkaninfo)
    if ! command -v vulkaninfo &>/dev/null; then
        print_row "$WARN" "vulkaninfo" "not installed (optional)"
        apt_install vulkan-tools 2>/dev/null && record_fix "Installed vulkan-tools" || true
    fi

    # vulkaninfo test
    if command -v vulkaninfo &>/dev/null; then
        local vk_out; vk_out=$(vulkaninfo --summary 2>/dev/null) || true
        if echo "$vk_out" | grep -qi "intel\|arc"; then
            print_row "$PASS" "vulkaninfo" "Intel/Arc device found"
            log_result PASS "Vulkan sees Intel Arc device"
        elif echo "$vk_out" | grep -qi "device"; then
            print_row "$WARN" "vulkaninfo" "${Y}device found but not Intel${N}"
            log_result WARN "Vulkan device found but not identified as Intel Arc"
        else
            print_row "$FAIL" "vulkaninfo" "no Vulkan device"
            log_result FAIL "Vulkan finds no devices"
        fi
    fi

    # ICD configuration
    local icd_dir="/usr/share/vulkan/icd.d"
    if [[ -d "$icd_dir" ]]; then
        local intel_icd; intel_icd=$(ls "$icd_dir"/*intel* "$icd_dir"/*anv* 2>/dev/null) || true
        if [[ -n "$intel_icd" ]]; then
            print_row "$PASS" "Vulkan ICD" "${D}$(basename $intel_icd | head -1)${N}"
            log_result PASS "Intel Vulkan ICD file present"
        else
            print_row "$WARN" "Vulkan ICD" "no Intel ICD in $icd_dir"
            log_result WARN "No Intel Vulkan ICD configuration found"
        fi
    fi
}

# ── Section 7: oneAPI / SYCL ─────────────────────────────────────────────────
check_oneapi() {
    section "7 · Intel oneAPI / SYCL (highest performance backend)"

    # oneAPI root locations
    local oneapi_root=""
    for loc in /opt/intel/oneapi /opt/intel/inteloneapi "$HOME/intel/oneapi"; do
        if [[ -f "${loc}/setvars.sh" ]]; then
            oneapi_root="$loc"
            break
        fi
    done

    if [[ -n "$oneapi_root" ]]; then
        print_row "$PASS" "oneAPI installation" "$oneapi_root"
        log_result PASS "Intel oneAPI found at $oneapi_root"

        # Source setvars to check
        local sycl_ver=""
        if bash -c "source '${oneapi_root}/setvars.sh' --force &>/dev/null && icpx --version 2>/dev/null | head -1"; then
            print_row "$PASS" "icpx compiler" "available"
            log_result PASS "Intel oneAPI SYCL compiler (icpx) available"
        else
            print_row "$WARN" "icpx compiler" "setvars.sh exists but icpx failed"
            log_result WARN "oneAPI found but icpx not working"
        fi

        # sycl-ls: list SYCL devices
        if command -v sycl-ls &>/dev/null || \
           bash -c "source '${oneapi_root}/setvars.sh' --force &>/dev/null && command -v sycl-ls &>/dev/null" 2>/dev/null; then
            local sycl_devs
            sycl_devs=$(bash -c "source '${oneapi_root}/setvars.sh' --force &>/dev/null && \
                ONEAPI_DEVICE_SELECTOR=level_zero:* sycl-ls 2>/dev/null" | grep -i "intel\|arc\|xe" || true)
            if [[ -n "$sycl_devs" ]]; then
                print_row "$PASS" "sycl-ls" "Intel device visible"
                echo -e "       ${D}${sycl_devs}${N}"
                log_result PASS "SYCL/Level Zero sees Intel device"
            else
                print_row "$WARN" "sycl-ls" "no Intel device listed via Level Zero"
                log_result WARN "SYCL cannot see Intel device via Level Zero"
                needs_manual "Verify Level Zero runtime (Section 5) and that GPU driver is loaded (Section 2)"
            fi
        fi

        # Environment profile script
        local env_file="/etc/profile.d/intel-oneapi.sh"
        if [[ -f "$env_file" ]]; then
            print_row "$PASS" "oneAPI env profile" "$env_file"
            log_result PASS "oneAPI environment profile already installed"
        else
            print_row "$WARN" "oneAPI env profile" "${Y}not found at $env_file${N}"
            log_result WARN "oneAPI not sourced automatically for all shells"
            echo -e "  ${FIX} Creating oneAPI environment profile…"
            if ensure_sudo; then
                sudo bash -c "cat > '$env_file' << 'ENVEOF'
# Intel oneAPI environment — auto-generated by arc-fix.sh
if [ -f '${oneapi_root}/setvars.sh' ]; then
    source '${oneapi_root}/setvars.sh' --force > /dev/null 2>&1
fi
export ONEAPI_DEVICE_SELECTOR=level_zero:0
export SYCL_CACHE_PERSISTENT=1
export ZES_ENABLE_SYSMAN=1
ENVEOF"
                sudo chmod 644 "$env_file"
                record_fix "Created $env_file (oneAPI auto-source + env vars)"
                print_row "$PASS" "oneAPI env profile" "created at $env_file"
            fi
        fi

    else
        print_row "$FAIL" "oneAPI not installed" ""
        log_result FAIL "Intel oneAPI not found — SYCL backend unavailable"
        echo
        echo -e "  ${D}  oneAPI is required for the fastest llama.cpp backend on Arc.${N}"
        echo -e "  ${D}  Install instructions:${N}"
        echo -e "  ${D}  https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html${N}"
        echo
        needs_manual "Install Intel oneAPI Base Toolkit: https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html"

        # Check for icpx without oneAPI env
        if command -v icpx &>/dev/null; then
            print_row "$PASS" "icpx in PATH" "$(command -v icpx)"
            log_result PASS "icpx compiler found in PATH (partial oneAPI install?)"
        fi
    fi

    # Key environment variables
    echo
    echo -e "  ${D}SYCL/Level Zero environment variables${N}"
    local -A env_vars=(
        ["ONEAPI_DEVICE_SELECTOR"]="level_zero:0  ${D}(force Level Zero for Arc)${N}"
        ["SYCL_CACHE_PERSISTENT"]="1             ${D}(cache JIT-compiled kernels)${N}"
        ["ZES_ENABLE_SYSMAN"]="1             ${D}(enable GPU management API)${N}"
    )
    for var in "${!env_vars[@]}"; do
        local cur; cur="${!var:-}"
        if [[ -n "$cur" ]]; then
            print_row "$PASS" "$$var" "${D}=${cur}${N}"
            log_result PASS "Env var $var is set"
        else
            print_row "$WARN" "$var" "${Y}not set in current shell${N} — suggested: ${env_vars[$var]}"
            log_result WARN "Env var $var not set (needed for SYCL)"
        fi
    done
}

# ── Section 8: llama.cpp Build ────────────────────────────────────────────────
check_llamacpp_build() {
    section "8 · llama.cpp Build & Binary"

    # Find llama.cpp binaries in common locations
    local -a search_dirs=("$HOME" "$HOME/llama.cpp" "$HOME/llama" "/opt/llama.cpp" "/usr/local/bin" "$(pwd)")
    local -a found_bins=()

    for dir in "${search_dirs[@]}"; do
        while IFS= read -r bin; do
            found_bins+=("$bin")
        done < <(find "$dir" -maxdepth 3 -name "llama-cli" -o -name "llama-server" \
                             -o -name "llama-bench" -o -name "main" \
                             -o -name "server" 2>/dev/null | head -5)
    done

    # Deduplicate
    declare -a unique_bins=()
    declare -A seen_bins=()
    for b in "${found_bins[@]}"; do
        [[ -z "${seen_bins[$b]+x}" ]] && { unique_bins+=("$b"); seen_bins[$b]=1; }
    done

    if [[ ${#unique_bins[@]} -eq 0 ]]; then
        print_row "$WARN" "llama.cpp binary" "not found in common locations"
        log_result WARN "No llama.cpp binary found"
        echo -e "  ${D}  Searched: ${search_dirs[*]}${N}"
        echo -e "  ${D}  Set LLAMA_PATH env var and re-run to test a specific binary.${N}"
    else
        for bin in "${unique_bins[@]}"; do
            print_row "$INFO" "Found binary" "$bin"
        done
    fi

    # Check for a CMakeCache.txt to detect build flags
    local cmake_caches=()
    for dir in "${search_dirs[@]}"; do
        while IFS= read -r f; do cmake_caches+=("$f"); done \
            < <(find "$dir" -maxdepth 4 -name "CMakeCache.txt" 2>/dev/null | head -3)
    done

    if [[ ${#cmake_caches[@]} -gt 0 ]]; then
        for cache in "${cmake_caches[@]}"; do
            echo
            print_row "$INFO" "CMakeCache" "$cache"

            local -A build_flags=(
                ["GGML_SYCL:BOOL=ON"]="SYCL backend"
                ["GGML_VULKAN:BOOL=ON"]="Vulkan backend"
                ["GGML_OPENCL:BOOL=ON"]="OpenCL backend"
                ["LLAMA_SYCL:BOOL=ON"]="SYCL backend (older flag)"
                ["LLAMA_VULKAN:BOOL=ON"]="Vulkan backend (older flag)"
                ["LLAMA_METAL:BOOL=ON"]="Metal backend"
                ["LLAMA_CUBLAS:BOOL=ON"]="CUDA/cuBLAS"
            )

            local gpu_backend_found=false
            for flag in "${!build_flags[@]}"; do
                if grep -qi "$flag" "$cache" 2>/dev/null; then
                    print_row "$PASS" "${build_flags[$flag]}" "${D}${flag}${N}"
                    log_result PASS "llama.cpp built with: ${build_flags[$flag]}"
                    gpu_backend_found=true
                fi
            done

            if ! $gpu_backend_found; then
                print_row "$FAIL" "No GPU backend" "${Y}CPU-only build${N}"
                log_result FAIL "llama.cpp CMakeCache shows no GPU backend enabled"
                _suggest_build_commands
            fi
        done
    else
        if [[ ${#unique_bins[@]} -gt 0 ]]; then
            # Binary found but no CMakeCache — inspect binary for linked libs
            local bin="${unique_bins[0]}"
            if command -v ldd &>/dev/null; then
                local ldd_out; ldd_out=$(ldd "$bin" 2>/dev/null) || true
                local gpu_libs=""
                for lib in libOpenCL libze_loader libvulkan libsycl; do
                    echo "$ldd_out" | grep -q "$lib" && gpu_libs+=" $lib"
                done
                if [[ -n "$gpu_libs" ]]; then
                    print_row "$PASS" "GPU libs linked" "${D}${gpu_libs}${N}"
                    log_result PASS "Binary links GPU libraries:$gpu_libs"
                else
                    print_row "$WARN" "GPU libs" "none detected in binary"
                    log_result WARN "No GPU libraries linked into binary (may be CPU-only)"
                fi
            fi
        else
            print_row "$WARN" "CMakeCache" "not found — cannot check build flags"
            log_result WARN "No CMakeCache.txt found to check build configuration"
            _suggest_build_commands
        fi
    fi

    # If LLAMA_PATH set, run a quick device test
    if [[ -n "${LLAMA_PATH:-}" && -x "$LLAMA_PATH" ]]; then
        echo
        print_row "$INFO" "Testing binary" "$LLAMA_PATH"
        local test_out
        test_out=$("$LLAMA_PATH" --list-devices 2>&1 || "$LLAMA_PATH" -h 2>&1 | head -5) || true
        if echo "$test_out" | grep -qi "arc\|intel\|xe\|gpu\|sycl\|vulkan\|opencl"; then
            print_row "$PASS" "--list-devices" "GPU backend responded"
            log_result PASS "llama.cpp lists GPU devices"
        fi
    fi
}

# Print recommended cmake build commands
_suggest_build_commands() {
    echo
    echo -e "  ${D}  Rebuild llama.cpp with a GPU backend.${N}"
    echo
    echo -e "  ${W}  Option A — SYCL (best for Arc, requires oneAPI):${N}"
    echo -e "  ${C}    source /opt/intel/oneapi/setvars.sh${N}"
    echo -e "  ${C}    cmake -B build -DGGML_SYCL=ON \\${N}"
    echo -e "  ${C}          -DCMAKE_C_COMPILER=icx \\${N}"
    echo -e "  ${C}          -DCMAKE_CXX_COMPILER=icpx${N}"
    echo -e "  ${C}    cmake --build build --config Release -j\$(nproc)${N}"
    echo
    echo -e "  ${W}  Option B — Vulkan (no oneAPI needed):${N}"
    echo -e "  ${C}    cmake -B build -DGGML_VULKAN=ON${N}"
    echo -e "  ${C}    cmake --build build --config Release -j\$(nproc)${N}"
    echo
    needs_manual "Rebuild llama.cpp with GPU backend (see output for cmake commands)"
}

# ── Section 9: Environment & Runtime Config ───────────────────────────────────
check_environment() {
    section "9 · Environment & Runtime Configuration"

    # /etc/profile.d arc vars
    local arc_profile="/etc/profile.d/arc-llamacpp.sh"
    if [[ -f "$arc_profile" ]]; then
        print_row "$PASS" "Arc profile" "$arc_profile"
        log_result PASS "Arc environment profile installed"
    else
        print_row "$WARN" "Arc profile" "${Y}not found${N}"
        log_result WARN "No Arc-specific environment profile"
        echo -e "  ${FIX} Creating ${arc_profile}…"
        if ensure_sudo; then
            sudo bash -c "cat > '$arc_profile' << 'ARCENV'
# Intel Arc A770 — llama.cpp environment variables
# Auto-generated by arc-fix.sh

# Force Level Zero backend (best for Arc)
export ONEAPI_DEVICE_SELECTOR=level_zero:0

# Enable sysman for device metrics
export ZES_ENABLE_SYSMAN=1

# Cache compiled SYCL kernels across runs
export SYCL_CACHE_PERSISTENT=1

# Use the first GPU (index 0); change for multi-GPU
export GGML_SYCL_DEVICE=0

# Vulkan: prefer Intel Vulkan driver
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.x86_64.json

ARCENV"
            sudo chmod 644 "$arc_profile"
            record_fix "Created Arc environment profile: $arc_profile"
            print_row "$PASS" "Arc profile created" "${Y}source it or log out/in${N}"
        fi
    fi

    # Check LD_LIBRARY_PATH contains oneAPI libs
    if echo "${LD_LIBRARY_PATH:-}" | grep -q "intel/oneapi\|oneapi"; then
        print_row "$PASS" "LD_LIBRARY_PATH" "contains oneAPI paths"
        log_result PASS "oneAPI library paths in LD_LIBRARY_PATH"
    else
        print_row "$WARN" "LD_LIBRARY_PATH" "${D}no oneAPI paths${N} (normal if not sourced yet)"
    fi

    # Hugepages — can improve GPU performance
    local hugepages; hugepages=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "?")
    if [[ "$hugepages" =~ ^[0-9]+$ ]] && (( hugepages > 0 )); then
        print_row "$PASS" "Hugepages" "${hugepages} allocated"
        log_result PASS "Hugepages configured: $hugepages"
    else
        print_row "$WARN" "Hugepages" "${D}none (optional, improves GPU throughput)${N}"
    fi

    # CPU governor (performance mode helps)
    local gov; gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    if [[ "$gov" == "performance" ]]; then
        print_row "$PASS" "CPU governor" "performance"
        log_result PASS "CPU in performance mode"
    else
        print_row "$WARN" "CPU governor" "${D}${gov}${N} (consider 'performance' for inference)"
    fi

    # Power supply — Arc A770 needs 225W TDP
    echo
    echo -e "  ${D}Power${N}"
    local psu_check; psu_check=$(lspci -vv 2>/dev/null | grep -A2 -i "power limit\|current power\|LnkCap" | head -6) || true
    if [[ -n "$psu_check" ]]; then
        echo "$psu_check" | while read -r line; do
            print_row "$INFO" "" "${D}${line}${N}"
        done
    fi
    print_row "$INFO" "Arc A770 TDP" "225W — ensure ≥650W PSU & both PCIe power connectors"
    print_row "$INFO" "PCIe connectors" "Arc A770 requires 2× 8-pin or 1× 16-pin PCIe power"
}

# ── Section 10: Quick Smoke Test ──────────────────────────────────────────────
run_smoke_test() {
    section "10 · Quick Smoke Tests"

    # OpenCL via clinfo
    echo -e "  ${D}OpenCL device enumeration${N}"
    if command -v clinfo &>/dev/null; then
        local out; out=$(clinfo 2>/dev/null) || true
        local devices; devices=$(echo "$out" | grep -c "Device Name" || true)
        local intel_dev; intel_dev=$(echo "$out" | grep -i "device name" | grep -i "intel\|arc" | head -1) || true
        if [[ -n "$intel_dev" ]]; then
            print_row "$PASS" "OpenCL: Intel device" "${D}${intel_dev}${N}"
            log_result PASS "OpenCL smoke test: Intel device found"
        elif [[ "$devices" -gt 0 ]]; then
            print_row "$WARN" "OpenCL: ${devices} device(s)" "${Y}but none identified as Intel Arc${N}"
            log_result WARN "OpenCL devices found but not Intel Arc"
        else
            print_row "$FAIL" "OpenCL: 0 devices" ""
            log_result FAIL "OpenCL smoke test: no devices"
        fi
    else
        print_row "$SKIP" "clinfo" "not installed"
    fi

    # Vulkan
    echo -e "  ${D}Vulkan device enumeration${N}"
    if command -v vulkaninfo &>/dev/null; then
        local vkout; vkout=$(vulkaninfo --summary 2>/dev/null) || true
        local vk_intel; vk_intel=$(echo "$vkout" | grep -i "intel\|arc" | head -1) || true
        if [[ -n "$vk_intel" ]]; then
            print_row "$PASS" "Vulkan: Intel device" "${D}${vk_intel}${N}"
            log_result PASS "Vulkan smoke test: Intel device found"
        else
            print_row "$WARN" "Vulkan: no Intel device" ""
            log_result WARN "Vulkan: no Intel Arc device listed"
        fi
    else
        print_row "$SKIP" "vulkaninfo" "not installed"
    fi

    # Level Zero
    echo -e "  ${D}Level Zero device enumeration${N}"
    if command -v ze_info &>/dev/null; then
        local ze; ze=$(ZES_ENABLE_SYSMAN=1 ze_info 2>/dev/null) || true
        if echo "$ze" | grep -qi "intel\|arc\|xe"; then
            print_row "$PASS" "Level Zero: Intel device" ""
            log_result PASS "Level Zero smoke test: Intel device found"
        else
            print_row "$WARN" "Level Zero: no Intel device" ""
            log_result WARN "Level Zero: no Intel device"
        fi
    else
        print_row "$SKIP" "ze_info" "not installed"
    fi

    # /dev/dri accessibility
    echo -e "  ${D}DRM node access${N}"
    local rnode; rnode=$(ls /dev/dri/renderD* 2>/dev/null | head -1) || true
    if [[ -n "$rnode" ]]; then
        if dd if="$rnode" of=/dev/null bs=1 count=1 &>/dev/null; then
            print_row "$PASS" "DRM read test" "$rnode readable"
            log_result PASS "DRM render node accessible"
        else
            print_row "$FAIL" "DRM read test" "$rnode not accessible — check group membership"
            log_result FAIL "Cannot read DRM render node — group membership issue"
        fi
    else
        print_row "$SKIP" "DRM read test" "no render node found"
    fi

    # kernel ring buffer — GPU errors
    echo -e "  ${D}dmesg GPU errors (last 50 lines)${N}"
    local dmesg_errs; dmesg_errs=$(dmesg 2>/dev/null | tail -50 | grep -iE "xe|i915|drm|gpu" | grep -iE "error|fault|fail|warn" | head -5) || true
    if [[ -n "$dmesg_errs" ]]; then
        print_row "$WARN" "dmesg GPU warnings" ""
        echo "$dmesg_errs" | while read -r line; do
            echo -e "       ${D}${line}${N}"
        done
        log_result WARN "dmesg contains GPU-related warnings"
    else
        print_row "$PASS" "dmesg" "no GPU errors in last 50 lines"
        log_result PASS "No GPU errors in dmesg"
    fi
}

# ── Final report ───────────────────────────────────────────────────────────────
print_report() {
    section "Summary Report"

    # Tally
    local pass=0 warn=0 fail=0
    for r in "${RESULTS[@]}"; do
        case "$r" in PASS*) (( pass++ )) ;; WARN*) (( warn++ )) ;; FAIL*) (( fail++ )) ;; esac
    done

    # Score bar
    local total=$(( pass + warn + fail ))
    local pct=0; [[ $total -gt 0 ]] && pct=$(( pass * 100 / total ))

    echo -e "  Score: ${W}${pct}%${N}  (${G}${pass} pass${N} · ${Y}${warn} warn${N} · ${R}${fail} fail${N})"
    echo

    # Grouped failures
    if [[ $fail -gt 0 ]]; then
        echo -e "  ${R}${BOLD}Failures:${N}"
        for r in "${RESULTS[@]}"; do
            [[ "$r" == FAIL* ]] && echo -e "    ${CROSS} ${r#FAIL  }"
        done
        echo
    fi

    if [[ $warn -gt 0 ]]; then
        echo -e "  ${Y}${BOLD}Warnings:${N}"
        for r in "${RESULTS[@]}"; do
            [[ "$r" == WARN* ]] && echo -e "    ${WARN} ${r#WARN  }"
        done
        echo
    fi

    # Fixes applied
    if [[ ${#FIXES_APPLIED[@]} -gt 0 ]]; then
        sep
        echo -e "  ${M}${BOLD}Auto-fixes applied this run:${N}"
        echo
        for f in "${FIXES_APPLIED[@]}"; do
            echo -e "    ${FIX} $f"
        done
        echo
    fi

    # Manual action items
    if [[ ${#FIXES_NEEDED[@]} -gt 0 ]]; then
        sep
        echo -e "  ${Y}${BOLD}Manual actions required:${N}"
        echo
        local n=1
        for f in "${FIXES_NEEDED[@]}"; do
            echo -e "    ${W}[$n]${N} $f"
            (( n++ ))
        done
        echo
    fi

    sep
    echo

    # Overall verdict
    if [[ $fail -eq 0 && $warn -le 2 ]]; then
        echo -e "  ${G}${BOLD}✔  Stack looks healthy — llama.cpp should see the Arc A770.${N}"
        echo
        echo -e "  ${D}Quick start:${N}"
        echo -e "  ${C}  source /etc/profile.d/arc-llamacpp.sh   # load env vars${N}"
        echo -e "  ${C}  ./llama-server -m model.gguf --ngl 999  # offload all layers to GPU${N}"
    elif [[ $fail -gt 3 ]]; then
        echo -e "  ${R}${BOLD}✘  Multiple critical failures — GPU likely not accessible.${N}"
        echo -e "  ${D}  Address failures above, then re-run this script.${N}"
    else
        echo -e "  ${Y}${BOLD}⚠  Partial — some issues remain. Address items above, then re-run.${N}"
    fi

    echo
    echo -e "  ${D}Re-run any time:  bash arc-fix.sh${N}"
    echo -e "  ${D}Save report:      bash arc-fix.sh 2>&1 | tee arc-report.txt${N}"
    echo
}

# ── Interactive menu ───────────────────────────────────────────────────────────
show_menu() {
    clear
    echo
    echo -e "  ${C}${BOLD}🦙  llama.cpp × Intel Arc A770 — Diagnostics${N}"
    echo
    sep
    echo
    echo -e "  ${W}[1]${N}  ${G}Run all checks & auto-fix${N}"
    echo -e "  ${W}[2]${N}  Hardware detection only"
    echo -e "  ${W}[3]${N}  Kernel driver & firmware"
    echo -e "  ${W}[4]${N}  DRM nodes & permissions"
    echo -e "  ${W}[5]${N}  Compute runtime (OpenCL / Level Zero)"
    echo -e "  ${W}[6]${N}  Vulkan"
    echo -e "  ${W}[7]${N}  oneAPI / SYCL"
    echo -e "  ${W}[8]${N}  llama.cpp build check"
    echo -e "  ${W}[9]${N}  Environment & runtime config"
    echo -e "  ${W}[0]${N}  Quick smoke tests"
    echo -e "  ${W}[q]${N}  ${D}Quit${N}"
    echo
    sep
    echo
    read -rp "  Choice: " choice
    echo
    case "${choice,,}" in
        1)  check_hardware
            check_kernel_driver
            check_drm_nodes
            check_permissions
            check_compute_runtime
            check_vulkan
            check_oneapi
            check_llamacpp_build
            check_environment
            run_smoke_test
            print_report
            ;;
        2)  check_hardware;         print_report ;;
        3)  check_kernel_driver;    print_report ;;
        4)  check_drm_nodes; check_permissions; print_report ;;
        5)  check_compute_runtime;  print_report ;;
        6)  check_vulkan;           print_report ;;
        7)  check_oneapi;           print_report ;;
        8)  check_llamacpp_build;   print_report ;;
        9)  check_environment;      print_report ;;
        0)  run_smoke_test;         print_report ;;
        q|quit|exit) echo -e "  ${D}Bye.${N}"; echo; exit 0 ;;
        *)  echo -e "  ${WARN} Invalid choice."; sleep 1; show_menu ;;
    esac

    echo
    read -rp "  Press Enter to return to menu, or q to quit: " again
    [[ "${again,,}" != "q" ]] && show_menu
}

# ── Entry point ────────────────────────────────────────────────────────────────
# If --auto flag passed, skip menu and run everything non-interactively.
if [[ "${1:-}" == "--auto" || "${1:-}" == "-a" ]]; then
    echo -e "\n${C}${BOLD}Arc A770 — Full Auto-Scan${N}\n"
    GPU_PCI_ADDR=""; GPU_PCI_ID=""
    check_hardware
    check_kernel_driver
    check_drm_nodes
    check_permissions
    check_compute_runtime
    check_vulkan
    check_oneapi
    check_llamacpp_build
    check_environment
    run_smoke_test
    print_report
else
    # Default: interactive menu
    GPU_PCI_ADDR=""; GPU_PCI_ID=""
    show_menu
fi
