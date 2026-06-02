#!/usr/bin/env bash
# =============================================================================
#  Intel Arc A770 — Driver Purge & llama.cpp Builder
#  Ubuntu 24.04 (Noble) | SYCL / OpenCL / Vulkan backends
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'
CYN=$'\033[0;36m'; BLU=$'\033[1;34m'; MAG=$'\033[0;35m'
DIM=$'\033[2m';    BLD=$'\033[1m';    RST=$'\033[0m'
CHECK="${GRN}✔${RST}"; CROSS="${RED}✘${RST}"; ARROW="${CYN}▶${RST}"

# ── State ────────────────────────────────────────────────────────────────────
BACKEND=""          # sycl | opencl | vulkan
LLAMA_DIR=""        # path to llama.cpp repo
LOG_FILE="/tmp/arc-setup-$(date +%s).log"

# Build flags — defaults
declare -A FLAGS=(
  # Core
  [GGML_NATIVE]=ON
  [GGML_LTO]=OFF
  [GGML_CCACHE]=ON
  [GGML_STATIC]=OFF
  # CPU
  [GGML_AVX]=ON
  [GGML_AVX2]=ON
  [GGML_AVX512]=OFF
  [GGML_AVX512_VBMI]=OFF
  [GGML_AVX512_VNNI]=OFF
  [GGML_AVX512_BF16]=OFF
  [GGML_FMA]=ON
  [GGML_F16C]=ON
  [GGML_AVX_VNNI]=OFF
  # SYCL
  [GGML_SYCL]=OFF
  [GGML_SYCL_F16]=ON
  [GGML_SYCL_GRAPH]=ON
  [GGML_SYCL_HOST_MEM_FALLBACK]=ON
  [GGML_SYCL_SUPPORT_LEVEL_ZERO]=ON
  [GGML_SYCL_DNN]=ON
  # OpenCL
  [GGML_OPENCL]=OFF
  [GGML_OPENCL_PROFILING]=OFF
  [GGML_OPENCL_EMBED_KERNELS]=ON
  # Vulkan
  [GGML_VULKAN]=OFF
  [GGML_VULKAN_CHECK_RESULTS]=OFF
  [GGML_VULKAN_DEBUG]=OFF
  [GGML_VULKAN_MEMORY_DEBUG]=OFF
  [GGML_VULKAN_VALIDATE]=OFF
  # llama
  [LLAMA_BUILD_SERVER]=ON
  [LLAMA_BUILD_EXAMPLES]=ON
  [LLAMA_BUILD_TESTS]=ON
  [LLAMA_OPENSSL]=ON
  # Extra
  [GGML_BLAS]=OFF
  [GGML_BACKEND_DL]=OFF
  [GGML_CPU_REPACK]=ON
)

# ── Helpers ──────────────────────────────────────────────────────────────────
title() { echo -e "\n${BLD}${BLU}╔══════════════════════════════════════════════╗${RST}"; \
          printf "${BLD}${BLU}║${RST}  %-44s${BLD}${BLU}║${RST}\n" "$1"; \
          echo -e "${BLD}${BLU}╚══════════════════════════════════════════════╝${RST}"; }

section() { echo -e "\n${MAG}━━━ $1 ${DIM}────────────────────────────────${RST}"; }

info()    { echo -e "  ${ARROW} $1"; }
ok()      { echo -e "  ${CHECK} $1"; }
warn()    { echo -e "  ${YEL}⚠${RST}  $1"; }
die()     { echo -e "\n  ${CROSS} ${RED}$1${RST}\n"; exit 1; }

confirm() {
  local msg="${1:-Continue?}" default="${2:-n}"
  local prompt
  [[ $default == y ]] && prompt="[Y/n]" || prompt="[y/N]"
  echo -ne "\n  ${YEL}?${RST}  $msg $prompt: "
  read -r ans
  [[ -z $ans ]] && ans=$default
  [[ ${ans,,} == y ]]
}

run() {
  echo -e "  ${DIM}$ $*${RST}"
  "$@" >> "$LOG_FILE" 2>&1 || { echo -e "  ${CROSS} Command failed: $*\n  ${DIM}See $LOG_FILE${RST}"; return 1; }
}

run_sudo() {
  echo -e "  ${DIM}$ sudo $*${RST}"
  sudo "$@" >> "$LOG_FILE" 2>&1 || { echo -e "  ${CROSS} Command failed: sudo $*\n  ${DIM}See $LOG_FILE${RST}"; return 1; }
}

require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    info "This step requires sudo — enter your password:"
    sudo -v || die "sudo failed"
  fi
  # Keep sudo alive for long operations
  ( while true; do sudo -n true; sleep 50; done ) &
  SUDO_KEEP=$!
  trap 'kill $SUDO_KEEP 2>/dev/null; exit' EXIT INT TERM
}

flag_toggle() {
  local key=$1
  if [[ ${FLAGS[$key]} == ON ]]; then FLAGS[$key]=OFF; else FLAGS[$key]=ON; fi
}

# ── Menus ────────────────────────────────────────────────────────────────────
menu_main() {
  while true; do
    title "Intel Arc A770 — Setup Menu"
    echo -e "  ${BLD}Log:${RST} ${DIM}$LOG_FILE${RST}\n"
    echo -e "  ${CYN}1${RST}  Purge existing drivers"
    echo -e "  ${CYN}2${RST}  Install drivers  ${DIM}(SYCL / OpenCL / Vulkan)${RST}"
    echo -e "  ${CYN}3${RST}  Build llama.cpp"
    echo -e "  ${CYN}4${RST}  Full run  ${DIM}(purge → install → build)${RST}"
    echo -e "  ${CYN}5${RST}  Verify GPU & compute stack"
    echo -e "  ${CYN}q${RST}  Quit\n"
    echo -ne "  Select: "
    read -r choice
    case $choice in
      1) do_purge ;;
      2) menu_backend && do_install ;;
      3) menu_build ;;
      4) menu_backend && do_purge && do_install && menu_build ;;
      5) do_verify ;;
      q|Q) echo ""; exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

menu_backend() {
  section "Select GPU backend"
  echo -e "  ${CYN}1${RST}  SYCL     ${DIM}— Best for Arc; needs oneAPI DPC++ compiler${RST}"
  echo -e "  ${CYN}2${RST}  OpenCL   ${DIM}— Broadest compatibility, no special compiler${RST}"
  echo -e "  ${CYN}3${RST}  Vulkan   ${DIM}— Experimental but no vendor SDK needed${RST}\n"
  echo -ne "  Select [1-3]: "
  read -r b
  case $b in
    1) BACKEND=sycl   ; ok "Backend: SYCL" ;;
    2) BACKEND=opencl ; ok "Backend: OpenCL" ;;
    3) BACKEND=vulkan ; ok "Backend: Vulkan" ;;
    *) warn "Defaulting to SYCL"; BACKEND=sycl ;;
  esac
}

menu_build() {
  [[ -z $BACKEND ]] && menu_backend
  menu_build_options
  do_build
}

menu_build_options() {
  while true; do
    section "llama.cpp Build Options  (backend: ${BLD}${BACKEND^^}${RST})"
    _print_build_menu
    echo -ne "\n  Toggle flag [enter key], (b)uild now, (r)eset, (q)uit build: "
    read -r sel
    case ${sel,,} in
      b) break ;;
      r) _reset_flags_for_backend ;;
      q) menu_main ;;
      *)
        # accept number or exact flag name
        [[ -z $sel ]] && continue 
        local ordered=()
        _get_ordered_keys ordered
        if [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#ordered[@]} )); then
          flag_toggle "${ordered[$((sel-1))]}"
        elif [[ -n ${FLAGS[$sel]+x} ]]; then
          flag_toggle "$sel"
        else
          warn "Unknown selection"
        fi
        ;;
    esac
  done

  # Enforce backend mutual exclusion
  FLAGS[GGML_SYCL]=OFF
  FLAGS[GGML_OPENCL]=OFF
  FLAGS[GGML_VULKAN]=OFF
  case $BACKEND in
    sycl)   FLAGS[GGML_SYCL]=ON ;;
    opencl) FLAGS[GGML_OPENCL]=ON ;;
    vulkan) FLAGS[GGML_VULKAN]=ON ;;
  esac
}

_get_ordered_keys() {
  local -n _arr=$1
  _arr=()
  # Group order
  local groups=(
    "GGML_NATIVE" "GGML_LTO" "GGML_CCACHE" "GGML_STATIC" "GGML_BACKEND_DL" "GGML_CPU_REPACK" "GGML_BLAS"
    "GGML_AVX" "GGML_AVX2" "GGML_FMA" "GGML_F16C" "GGML_AVX_VNNI"
    "GGML_AVX512" "GGML_AVX512_VBMI" "GGML_AVX512_VNNI" "GGML_AVX512_BF16"
  )
  case $BACKEND in
    sycl)
      groups+=("GGML_SYCL_F16" "GGML_SYCL_GRAPH" "GGML_SYCL_HOST_MEM_FALLBACK" "GGML_SYCL_SUPPORT_LEVEL_ZERO" "GGML_SYCL_DNN")
      ;;
    opencl)
      groups+=("GGML_OPENCL_PROFILING" "GGML_OPENCL_EMBED_KERNELS")
      ;;
    vulkan)
      groups+=("GGML_VULKAN_CHECK_RESULTS" "GGML_VULKAN_DEBUG" "GGML_VULKAN_MEMORY_DEBUG" "GGML_VULKAN_VALIDATE")
      ;;
  esac
  groups+=("LLAMA_BUILD_SERVER" "LLAMA_BUILD_EXAMPLES" "LLAMA_BUILD_TESTS" "LLAMA_OPENSSL")
  for k in "${groups[@]}"; do
    [[ -n ${FLAGS[$k]+x} ]] && _arr+=("$k")
  done
}

_print_build_menu() {
  local ordered=()
  _get_ordered_keys ordered

  local groups=(
    "Build"           "GGML_NATIVE GGML_LTO GGML_CCACHE GGML_STATIC GGML_BACKEND_DL GGML_CPU_REPACK GGML_BLAS"
    "CPU extensions"  "GGML_AVX GGML_AVX2 GGML_FMA GGML_F16C GGML_AVX_VNNI GGML_AVX512 GGML_AVX512_VBMI GGML_AVX512_VNNI GGML_AVX512_BF16"
  )
  case $BACKEND in
    sycl)   groups+=("SYCL options" "GGML_SYCL_F16 GGML_SYCL_GRAPH GGML_SYCL_HOST_MEM_FALLBACK GGML_SYCL_SUPPORT_LEVEL_ZERO GGML_SYCL_DNN") ;;
    opencl) groups+=("OpenCL options" "GGML_OPENCL_PROFILING GGML_OPENCL_EMBED_KERNELS") ;;
    vulkan) groups+=("Vulkan options" "GGML_VULKAN_CHECK_RESULTS GGML_VULKAN_DEBUG GGML_VULKAN_MEMORY_DEBUG GGML_VULKAN_VALIDATE") ;;
  esac
  groups+=("llama.cpp" "LLAMA_BUILD_SERVER LLAMA_BUILD_EXAMPLES LLAMA_BUILD_TESTS LLAMA_OPENSSL")

  local idx=1
  for (( i=0; i<${#groups[@]}; i+=2 )); do
    local gname="${groups[$i]}"
    read -ra keys <<< "${groups[$((i+1))]}"
    echo -e "\n  ${DIM}── ${gname} ──${RST}"
    for key in "${keys[@]}"; do
      [[ -z ${FLAGS[$key]+x} ]] && continue
      local val="${FLAGS[$key]}"
      local col="${GRN}"; [[ $val == OFF ]] && col="${DIM}"
      local short="${key#GGML_}"; short="${short#LLAMA_}"
      printf "  %s%2d${RST}  %-40s %s%s${RST}\n" "$col" "$idx" "$key" "$col" "$val"
      (( idx++ ))
    done
  done
}

_reset_flags_for_backend() {
  FLAGS[GGML_NATIVE]=ON; FLAGS[GGML_LTO]=OFF; FLAGS[GGML_CCACHE]=ON
  FLAGS[GGML_STATIC]=OFF; FLAGS[GGML_AVX]=ON; FLAGS[GGML_AVX2]=ON
  FLAGS[GGML_FMA]=ON; FLAGS[GGML_F16C]=ON; FLAGS[GGML_CPU_REPACK]=ON
  FLAGS[GGML_BLAS]=OFF; FLAGS[GGML_BACKEND_DL]=OFF
  case $BACKEND in
    sycl)   FLAGS[GGML_SYCL_F16]=OFF; FLAGS[GGML_SYCL_GRAPH]=ON
            FLAGS[GGML_SYCL_HOST_MEM_FALLBACK]=ON
            FLAGS[GGML_SYCL_SUPPORT_LEVEL_ZERO]=ON; FLAGS[GGML_SYCL_DNN]=ON ;;
    opencl) FLAGS[GGML_OPENCL_PROFILING]=OFF; FLAGS[GGML_OPENCL_EMBED_KERNELS]=ON ;;
    vulkan) FLAGS[GGML_VULKAN_CHECK_RESULTS]=OFF; FLAGS[GGML_VULKAN_DEBUG]=OFF
            FLAGS[GGML_VULKAN_MEMORY_DEBUG]=OFF; FLAGS[GGML_VULKAN_VALIDATE]=OFF ;;
  esac
  ok "Flags reset to defaults"
}

# ── Actions ──────────────────────────────────────────────────────────────────
do_purge() {
  title "Purge Intel Arc Drivers"
  confirm "This will remove all Intel GPU compute packages. Continue?" y || return 0
  require_sudo

  section "Removing Intel compute stack & OpenCL"
  run_sudo apt-get remove --purge -y \
    intel-opencl-icd \
    intel-level-zero-gpu \
    level-zero \
    level-zero-dev \
    intel-oneapi-runtime-opencl \
    intel-oneapi-runtime-level-zero \
    intel-media-va-driver-non-free \
    libmfx1 libmfxgen1 libvpl2 \
    libigdgmm12 \
    intel-igc-core intel-igc-cm \
    intel-ocloc \
    intel-oneapi-dpcpp-cpp-2025.0 \
    intel-oneapi-compiler-dpcpp-cpp \
    2>/dev/null || true
  ok "Compute stack removed"

  section "Removing GPU firmware & tools"
  run_sudo apt-get remove --purge -y \
    i965-va-driver vainfo intel-gpu-tools 2>/dev/null || true
  ok "Firmware & tools removed"

  section "Removing any Intel-pinned packages"
  local intel_pkgs
  intel_pkgs=$(dpkg -l 2>/dev/null | grep '^ii' | awk '{print $2}' | grep -i 'intel-oneapi\|intel-igc\|intel-level\|intel-opencl' || true)
  if [[ -n $intel_pkgs ]]; then
    run_sudo apt-get remove --purge -y $intel_pkgs 2>/dev/null || true
  fi
  ok "Pinned packages cleaned"

  section "Dropping Intel apt repositories"
  run_sudo rm -f /usr/share/keyrings/intel-graphics.gpg
  run_sudo rm -f /etc/apt/sources.list.d/intel-graphics.list
  run_sudo rm -f /etc/apt/sources.list.d/oneAPI.list
  # Scan for any remaining Intel entries
  local extra
  extra=$(grep -rl 'repositories.intel\|packages.intel' /etc/apt/sources.list.d/ 2>/dev/null || true)
  if [[ -n $extra ]]; then
    warn "Additional Intel repo files found:"
    echo "$extra" | while read -r f; do
      echo -e "    ${DIM}$f${RST}"
      confirm "  Remove $f?" y && run_sudo rm -f "$f"
    done
  fi
  ok "Repositories cleaned"

  section "Autoremoving & cleaning cache"
  run_sudo apt-get autoremove --purge -y
  run_sudo apt-get clean
  run_sudo ldconfig
  ok "Autoremove complete"

  echo ""
  warn "A reboot is recommended before installing new drivers"
  confirm "Reboot now?" n && sudo reboot
}

Clean_System() {
run_sudo apt-get clean
# run_sudo rm /etc/apt/sources.list.d/intel-gpu-noble.list
run_sudo apt-get update
run_sudo apt-get autoremove --purge -y
run_sudo apt --fix-broken install

}

do_install() {
  title "Install Drivers for: ${BACKEND^^}"
  require_sudo

# Clean_System

  section "Updating package lists"
  run_sudo apt-get update

  case $BACKEND in
    sycl|opencl)
      section "Adding Intel GPU repository"
      run_sudo apt-get install -y wget gpg
      wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
        sudo gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg
      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] \
https://repositories.intel.com/gpu/ubuntu noble client" | \
        sudo tee /etc/apt/sources.list.d/intel-graphics.list
      run_sudo apt-get update
      ok "Intel GPU repo added"

      section "Installing base compute runtime"
      run_sudo apt-get install -y \
        intel-opencl-icd \
        level-zero \
        intel-media-va-driver-non-free \
        intel-oneapi-mkl-devel libmfxgen1 libvpl2 \
        intel-level-zero-gpu libigc1 libigdfcl1 \
        libigdgmm12 intel-oneapi-dnnl-devel \

      ok "Base runtime installed"
      ;;
  esac

  case $BACKEND in
    sycl)
      section "Installing oneAPI DPC++ compiler"
      # oneAPI repo
      wget -qO - https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | \
        sudo gpg --dearmor -o /usr/share/keyrings/oneapi-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] \
https://apt.repos.intel.com/oneapi all main" | \
        sudo tee /etc/apt/sources.list.d/oneAPI.list
      wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
      sudo gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg

      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] \
  https://repositories.intel.com/gpu/ubuntu noble client" | \
  sudo tee /etc/apt/sources.list.d/intel-graphics.list

      run_sudo apt-get update
      run_sudo apt-get install -y \
        intel-oneapi-dpcpp-cpp-2026.0 \
        intel-oneapi-mkl-devel 
      ok "oneAPI DPC++ installed"
      info "Source oneAPI env with: source /opt/intel/oneapi/setvars.sh"
      ;;

    opencl)
      ok "OpenCL runtime already installed with base runtime"
      ;;

    vulkan)
      section "Installing Vulkan stack"
      run_sudo apt-get install -y \
        libvulkan1 \
        libvulkan-dev \
        vulkan-tools \
        spirv-tools \
        glslang-tools \
        libshaderc-dev
      ok "Vulkan stack installed"
      ;;
  esac

  section "Setting render/video group membership"
  run_sudo usermod -aG render,video "$USER"
  ok "Added $USER to render & video groups"
  warn "Group changes take effect on next login/reboot"

  section "Verifying install"
  do_verify
}

do_verify() {
  title "Verify GPU & Compute Stack"

  section "Kernel modules"
  local mods
  mods=$(lsmod | grep -E '^xe|^i915' | awk '{print $1}') || true
  if [[ -n $mods ]]; then
    ok "Loaded: $mods"
  else
    warn "Neither xe nor i915 module found (expected after reboot)"
  fi

  section "DRM devices"
  if ls /dev/dri/render* &>/dev/null; then
    ok "Render nodes: $(ls /dev/dri/render*)"
    local grps
    grps=$(stat -c '%G' /dev/dri/renderD128 2>/dev/null || echo "unknown")
    info "Owner group: $grps"
    if id -nG "$USER" | grep -qw render; then
      ok "User is in render group"
    else
      warn "User NOT in render group — run: sudo usermod -aG render,video \$USER && newgrp render"
    fi
  else
    warn "No /dev/dri/renderD* nodes found"
  fi

  section "clinfo"
  if command -v clinfo &>/dev/null; then
    local platforms
    platforms=$(clinfo 2>/dev/null | grep -c 'Platform Name' || echo 0)
    if (( platforms > 0 )); then
      ok "$platforms OpenCL platform(s) found"
      clinfo 2>/dev/null | grep -E 'Platform Name|Device Name' | sed 's/^/    /'
    else
      warn "clinfo reports no platforms"
    fi
  else
    warn "clinfo not installed (apt install clinfo)"
  fi

  section "Level Zero"
  if command -v sycl-ls &>/dev/null; then
    ok "sycl-ls output:"; sycl-ls 2>/dev/null | sed 's/^/    /' || true
  else
    info "sycl-ls not available (install oneAPI first)"
  fi

  section "Vulkan"
  if command -v vulkaninfo &>/dev/null; then
    local vdevs
    vdevs=$(vulkaninfo 2>/dev/null | grep 'deviceName' | head -4 || true)
    if [[ -n $vdevs ]]; then
      ok "Vulkan devices:"; echo "$vdevs" | sed 's/^/    /'
    else
      warn "vulkaninfo found no devices"
    fi
  else
    info "vulkaninfo not installed (apt install vulkan-tools)"
  fi
}

detect_and_recommend() {
  section "Detecting hardware & recommending flags"

  # ── CPU detection ──────────────────────────────────────────
  local cpu_flags
  cpu_flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || echo "")
  local cpu_name
  cpu_name=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)

  info "CPU: $cpu_name"

  # CPU feature → flag mapping
  declare -A cpu_map=(
    [avx]="GGML_AVX"
    [avx2]="GGML_AVX2"
    [fma]="GGML_FMA"
    [f16c]="GGML_F16C"
    [avx512f]="GGML_AVX512"
    [avx512_vbmi]="GGML_AVX512_VBMI"
    [avx512_vnni]="GGML_AVX512_VNNI"
    [avx512_bf16]="GGML_AVX512_BF16"
    [avx_vnni]="GGML_AVX_VNNI"
  )

  local changed=0
  for cpuid_flag in "${!cpu_map[@]}"; do
    local cmake_flag="${cpu_map[$cpuid_flag]}"
    if echo "$cpu_flags" | grep -qw "$cpuid_flag"; then
      if [[ ${FLAGS[$cmake_flag]} != ON ]]; then
        FLAGS[$cmake_flag]=ON
        ok "  Enabled  $cmake_flag  (CPU supports $cpuid_flag)"
        (( changed++ )) || true
      fi
    else
      if [[ ${FLAGS[$cmake_flag]} != OFF ]]; then
        FLAGS[$cmake_flag]=OFF
        warn "  Disabled $cmake_flag  (CPU lacks $cpuid_flag)"
        (( changed++ )) || true
      fi
    fi
  done

  # ── GPU detection ──────────────────────────────────────────
  if [[ $BACKEND == sycl ]] && command -v sycl-ls &>/dev/null; then
    local sycl_out
    sycl_out=$(sycl-ls 2>/dev/null || true)

    # Arc A-series (DG2/Alchemist) → FP16 native support
    if echo "$sycl_out" | grep -qi "Arc"; then
      if [[ ${FLAGS[GGML_SYCL_F16]} == OFF ]]; then
        FLAGS[GGML_SYCL_F16]=ON
        ok "  Enabled  GGML_SYCL_F16  (Arc GPU has native FP16)"
        (( changed++ )) || true
      fi
    fi

    # Check Level Zero is actually working (already confirmed in verify)
    if echo "$sycl_out" | grep -qi "level_zero"; then
      FLAGS[GGML_SYCL_SUPPORT_LEVEL_ZERO]=ON
    fi
  fi

  if [[ $BACKEND == opencl ]] && command -v clinfo &>/dev/null; then
    if clinfo 2>/dev/null | grep -qi "Arc"; then
      ok "  Arc GPU confirmed via clinfo"
    fi
  fi

  # ── ccache ─────────────────────────────────────────────────
  if ! command -v ccache &>/dev/null; then
    if [[ ${FLAGS[GGML_CCACHE]} == ON ]]; then
      FLAGS[GGML_CCACHE]=OFF
      warn "  Disabled GGML_CCACHE  (ccache not installed — apt install ccache)"
      (( changed++ )) || true
    fi
  fi

  [[ $changed -eq 0 ]] && ok "Defaults already match detected hardware" \
                       || info "$changed flag(s) adjusted — review below"
}

do_build() {
  title "Build llama.cpp (${BACKEND^^})"

  # Locate or clone repo
  if [[ -z $LLAMA_DIR ]]; then
    echo -ne "\n  ${YEL}?${RST}  Path to llama.cpp repo [leave blank to clone to ~/llama.cpp]: "
    read -r LLAMA_DIR
    LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
  fi

  if [[ ! -d $LLAMA_DIR ]]; then
    confirm "Clone llama.cpp to $LLAMA_DIR?" y || die "No llama.cpp source available"
    run git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  fi
  ok "Source: $LLAMA_DIR"

  # Source oneAPI for SYCL
  # In do_build, replace the source block:
if [[ $BACKEND == sycl ]]; then
  section "Sourcing oneAPI environment"
  if [[ -f /opt/intel/oneapi/setvars.sh ]]; then
    set +euo pipefail
    # shellcheck disable=SC1091
    source /opt/intel/oneapi/setvars.sh --force >> "$LOG_FILE" 2>&1
    set -euo pipefail
    ok "oneAPI env loaded"
  else
    die "/opt/intel/oneapi/setvars.sh not found — is oneAPI installed?"
  fi
fi

  # Build cmake args
  cmake_args+=("-DDNNL_DIR=${DNNLROOT}/lib/cmake/dnnl")
  local cmake_args=()
  for key in "${!FLAGS[@]}"; do
    cmake_args+=("-D${key}=${FLAGS[$key]}")
  done

  # Compiler selection for SYCL
  if [[ $BACKEND == sycl ]]; then
    cmake_args+=("-DCMAKE_C_COMPILER=icx" "-DCMAKE_CXX_COMPILER=icpx")
  fi

  section "Configuring (cmake)"
  local build_dir="$LLAMA_DIR/build-${BACKEND}"
  info "Build dir: $build_dir"
  info "Flags: ${#cmake_args[@]} options"
  echo ""

  # Print final flag summary
  echo -e "  ${DIM}cmake -B $build_dir \\"
  for a in "${cmake_args[@]}"; do echo -e "    $a \\"; done
  echo -e "    $LLAMA_DIR${RST}\n"

  confirm "Proceed with build?" y || return 0

  mkdir -p "$build_dir"
  cmake -B "$build_dir" "${cmake_args[@]}" "$LLAMA_DIR" >> "$LOG_FILE" 2>&1 && ok "cmake configure OK" || {
    echo -e "  ${CROSS} cmake configure failed — last 30 lines of log:"
    tail -30 "$LOG_FILE" | sed 's/^/    /'
    die "Build aborted"
  }

  section "Compiling"
  local nproc
  nproc=$(nproc)
  info "Using $nproc parallel jobs"
  cmake --build "$build_dir" --config Release -j"$nproc" >> "$LOG_FILE" 2>&1 && ok "Build complete!" || {
    echo -e "  ${CROSS} Build failed — last 40 lines of log:"
    tail -40 "$LOG_FILE" | sed 's/^/    /'
    die "Build failed"
  }

  section "Quick smoke test"
  local bins=("llama-cli" "llama-server")
  for b in "${bins[@]}"; do
    local bin="$build_dir/bin/$b"
    if [[ -x $bin ]]; then
      ok "Binary: $bin"
    fi
  done

  local cli="$build_dir/bin/llama-cli"
  if [[ -x $cli ]]; then
    info "Checking GPU devices visible to llama.cpp:"
    "$cli" --list-devices 2>&1 | head -20 | sed 's/^/    /' || true
  fi

  echo ""
  ok "${BLD}Done!${RST}  Binaries in: ${CYN}$build_dir/bin/${RST}"
  echo -e "  ${DIM}Full build log: $LOG_FILE${RST}"
}

# ── Entry point ──────────────────────────────────────────────────────────────
clear
echo -e "${BLD}${BLU}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════╗
  ║   Intel Arc A770 — Driver & llama.cpp Setup      ║
  ║   Ubuntu 24.04 Noble                             ║
  ╚══════════════════════════════════════════════════╝
BANNER
echo -e "${RST}"
echo -e "  ${DIM}Log file: $LOG_FILE${RST}"

[[ $EUID -eq 0 ]] && die "Do not run as root — script uses sudo internally"
[[ $(lsb_release -rs 2>/dev/null) != "24.04" ]] && \
  warn "This script targets Ubuntu 24.04; detected $(lsb_release -rs 2>/dev/null)"

menu_main
