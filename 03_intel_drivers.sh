#!/usr/bin/env bash
# Intel Arc 2026 Smart Installer — resilient, interactive, self-healing
# Ubuntu 22.04 / 24.04

set -Eeuo pipefail

STATE_FILE="/var/tmp/intel_arc_install.state"
LOG_FILE="/var/tmp/intel_arc_install.log"

# ---------- logging ----------
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
err(){ log "ERROR: $*"; }
ok(){ log "OK: $*"; }
warn(){ log "WARN: $*"; }

# ---------- state ----------
save_state(){ echo "$1" > "$STATE_FILE"; }
load_state(){ [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo ""; }

# ---------- detection ----------
detect(){
  KERNEL=$(uname -r)
  UBUNTU=$(lsb_release -rs 2>/dev/null || echo unknown)
  GPU=$(lspci | grep -Ei 'intel|vga|display|3d' || true)
  DRIVER=$(lsmod | grep -E 'i915|xe' | awk '{print $1}' | head -1)
}

# ---------- dependency recovery ----------
fix_broken_packages() {
  warn "Deep dependency recovery engaged..."

  sudo apt-mark showhold | tee /tmp/held_pkgs.txt

  # unhold everything (safe in this context)
  if [[ -s /tmp/held_pkgs.txt ]]; then
    warn "Releasing held packages"
    sudo apt-mark unhold $(cat /tmp/held_pkgs.txt) || true
  fi

  # remove known conflict packages
  if dpkg -l | grep -q libmetee4; then
    warn "Force-removing libmetee4 and dependents"
    sudo apt remove --purge -y libmetee4 intel-igc-cm || true
  fi

  # aggressive cleanup
  sudo apt autoremove -y || true
  sudo apt clean

  # repair system
  sudo apt --fix-broken install -y || true
}

safe_apt_install() {
  if ! sudo apt-get install -y "$@"; then
    warn "Install failed → entering recovery mode"
    fix_broken_packages

    if ! sudo apt-get install -y "$@"; then
      err "Second attempt failed → escalating"

      # final brute-force attempt
      sudo dpkg --configure -a || true
      sudo apt --fix-broken install -y || true

      sudo apt-get install -y "$@" || return 1
    fi
  fi
}

# ---------- diagnostics ----------
diagnose(){
  detect
  echo "=== SYSTEM ==="
  echo "Kernel: $KERNEL"
  echo "Ubuntu: $UBUNTU"
  echo "GPU: ${GPU:-not detected}"
  echo "Driver: ${DRIVER:-none}"

  echo "=== RUNTIME ==="
  clinfo -l 2>/dev/null | grep -i intel || echo "OpenCL: FAIL"
  sycl-ls 2>/dev/null | grep -i gpu || echo "SYCL: FAIL"
  vainfo 2>/dev/null | grep -i intel || echo "VAAPI: FAIL"
  vulkaninfo 2>/dev/null | grep -i intel || echo "Vulkan: FAIL"
  xpu-smi discovery 2>/dev/null || echo "xpu-smi: FAIL"
}

detect_repo_conflict() {
  if apt-get install -y intel-gsc 2>&1 | grep -q "libmetee"; then
    warn "Detected repo mismatch (metee conflict)"
    return 0
  fi
  return 1
}

if detect_repo_conflict; then
  warn "Switching to consistent repo mode (removing Intel GPU repo)"

  sudo rm -f /etc/apt/sources.list.d/intel-gpu.list
  sudo apt update
  sudo apt --fix-broken install -y
fi



# ---------- fixes ----------
fix_kernel(){
  log "Ensuring HWE kernel"
  safe_apt_install linux-generic-hwe-24.04
}

fix_graphics(){
  log "Installing graphics stack"
  safe_apt_install \
    mesa-vulkan-drivers \
    mesa-opencl-icd \
    intel-media-va-driver-non-free \
    vainfo libvpl2 intel-gsc xpu-smi
}

fix_compute(){
  log "Installing compute runtime"
  safe_apt_install intel-opencl-icd intel-level-zero-gpu libze1 libze-dev clinfo
}

fix_oneapi(){
  if ! command -v icx >/dev/null; then
    log "Installing oneAPI compiler"
    safe_apt_install intel-oneapi-compiler-dpcpp-cpp
  else
    ok "icx already present"
  fi
}

fix_permissions(){
  sudo usermod -aG render,video "$USER" || true
  warn "Re-login required for GPU access"
}

# ---------- intelligent repair ----------
repair_loop(){
  for i in {1..4}; do
    log "Repair pass $i"

    clinfo >/dev/null 2>&1 || fix_compute
    sycl-ls >/dev/null 2>&1 || fix_oneapi
    vainfo >/dev/null 2>&1 || fix_graphics

    if clinfo >/dev/null 2>&1 && sycl-ls >/dev/null 2>&1; then
      ok "Core compute stack working"
      return
    fi
  done

  err "Automatic repair incomplete"
}

# ---------- install modes ----------
install_stable(){
  save_state "stable"
  fix_kernel
  fix_graphics
  fix_compute
  fix_oneapi
  fix_permissions
  repair_loop
}

install_performance(){
  save_state "performance"
  fix_kernel
  fix_graphics
  fix_compute
  fix_oneapi
  repair_loop
}

install_bleeding(){
  save_state "bleeding"
  log "Enabling experimental stack"
  sudo add-apt-repository -y ppa:kobuk-team/intel-graphics || true
  sudo apt-get update
  install_performance
}

# ---------- resume ----------
resume(){
  state=$(load_state)
  [[ -z "$state" ]] && { warn "No previous state"; return; }
  log "Resuming from $state"
  case $state in
    stable) install_stable ;;
    performance) install_performance ;;
    bleeding) install_bleeding ;;
  esac
}

# ---------- menu ----------
menu(){
  while true; do
    clear
    echo "========================================"
    echo "   Intel Arc Smart Installer (2026)"
    echo "========================================"

    detect
    echo "System Snapshot:"
    echo "  Kernel : $KERNEL"
    echo "  GPU    : ${GPU:-not detected}"
    echo "  Driver : ${DRIVER:-none}"
    echo "========================================"
    echo "Choose an option:"
    echo "  1) 🧠 Smart Install (auto fix everything)"
    echo "  2) 🟢 Stable Setup"
    echo "  3) ⚡ Performance Stack"
    echo "  4) 🔥 Bleeding Edge"
    echo "  5) 🔍 Diagnostics"
    echo "  6) 🛠 Repair"
    echo "  7) 🔁 Resume"
    echo "  8) 🚪 Exit"

    read -rp "Enter choice [1-8]: " choice

    case $choice in
      1) install_stable ;;
      2) install_stable ;;
      3) install_performance ;;
      4) install_bleeding ;;
      5) diagnose ;;
      6) repair_loop ;;
      7) resume ;;
      8) echo "Goodbye"; break ;;
      *) echo "Invalid"; sleep 1 ;;
    esac

    read -rp "Press Enter to continue..."
  done
}

# ---------- entry ----------
detect
menu
