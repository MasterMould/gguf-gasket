#!/bin/bash
# lib/drivers_intel.sh — Intel Arc GPU driver and oneAPI SYCL compiler installer
# Requires: globals.sh

install_intel_gpu_drivers() {
    STEP "Installing Intel Arc GPU drivers (OpenCL + level-zero + oneAPI)…"
    INFO "Checking Intel GPU driver packages…"

    # ── 1. Intel GPU compute-runtime repo ─────────────────────────────────
    if [[ ! -f /etc/apt/sources.list.d/intel-gpu-noble.list ]]; then
        INFO "  Adding Intel GPU repo for Ubuntu 24.04 Noble…"
        curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key \
            | sudo gpg --yes --dearmor \
                --output /usr/share/keyrings/intel-graphics.gpg \
            || { ERR "Failed to import Intel GPU key."; return 1; }
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] \
https://repositories.intel.com/gpu/ubuntu noble client" \
            | sudo tee /etc/apt/sources.list.d/intel-gpu-noble.list > /dev/null
        sudo apt-get update -qq 2>&1 | tee -a "$LOG_FILE" || true
    else
        INFO "  Intel GPU repo already present."
    fi

    # ── 2. Runtime packages ────────────────────────────────────────────────
    local PKGS=()

    if dpkg -s intel-opencl-icd &>/dev/null 2>&1; then
        INFO "  intel-opencl-icd     ✓ already installed"
    else
        PKGS+=("intel-opencl-icd")
    fi

    if dpkg -s libze-intel-gpu1 &>/dev/null 2>&1 \
    || dpkg -s intel-level-zero-gpu &>/dev/null 2>&1; then
        INFO "  level-zero GPU shim  ✓ already installed"
    else
        PKGS+=("libze-intel-gpu1")
    fi

    if dpkg -s libze1 &>/dev/null 2>&1; then
        INFO "  libze1               ✓ already installed"
    else
        PKGS+=("libze1")
    fi

    if [[ ${#PKGS[@]} -gt 0 ]]; then
        INFO "  Installing GPU runtime: ${PKGS[*]}"
        sudo apt-get install -y "${PKGS[@]}" 2>&1 | tee -a "$LOG_FILE" || {
            ERR "Failed to install GPU runtime packages."
            WARN "  Try: sudo apt-get update && sudo apt-get install ${PKGS[*]}"
        }
    fi

    sudo apt-get install -y --no-install-recommends clinfo libze-dev 2>&1 \
        | tee -a "$LOG_FILE" || true

    # ── MKL ────────────────────────────────────────────────────────────────
    if dpkg -s intel-oneapi-mkl-devel &>/dev/null 2>&1; then
        INFO "  intel-oneapi-mkl-devel ✓ already installed"
    else
        INFO "  Installing intel-oneapi-mkl-devel (required for SYCL cmake)…"
        sudo apt-get install -y intel-oneapi-mkl-devel 2>&1 | tee -a "$LOG_FILE" || {
            ERR "Failed to install intel-oneapi-mkl-devel."
            WARN "  Run manually: sudo apt-get install intel-oneapi-mkl-devel"
        }
    fi

    OK "Intel GPU runtime packages ready."

    # ── 3. SYCL compiler ──────────────────────────────────────────────────
    INFO "Checking Intel oneAPI SYCL compiler…"

    local ICX_BIN=""
    ICX_BIN=$(command -v icx 2>/dev/null) || true

    if [[ -n "$ICX_BIN" ]]; then
        local path_ver newest_installed
        path_ver=$(echo "$ICX_BIN" | grep -oP '\d{4}(?=\.\d)' | head -1) || true
        newest_installed=$(find /opt/intel/oneapi/compiler -maxdepth 1 -mindepth 1 \
            -type d 2>/dev/null | grep -oP '\d{4}\.\d[\d.]*' | sort -rV | head -1) || true
        if [[ -n "$newest_installed" && "$path_ver" != "${newest_installed%%.*}" ]]; then
            ICX_BIN=$(find /opt/intel/oneapi/compiler/"$newest_installed"/bin \
                -name icx -type f 2>/dev/null | head -1) || true
        fi
    fi
    if [[ -z "$ICX_BIN" ]]; then
        ICX_BIN=$(find /opt/intel/oneapi/compiler -name icx -type f \
            2>/dev/null | sort -rV | head -1) || true
    fi

    if [[ -n "$ICX_BIN" ]]; then
        OK "Intel icx compiler found: $ICX_BIN"

        # ── ABI version sync: MKL and compiler must match ──────────────────
        local MKL_MAJOR=""
        MKL_MAJOR=$(find /opt/intel/oneapi/mkl -maxdepth 1 -mindepth 1 -type d \
            2>/dev/null | grep -oP '\d{4}' | sort -rn | head -1) || true

        local ICX_MAJOR=""
        ICX_MAJOR=$(echo "$ICX_BIN" | grep -oP '\d{4}(?=\.\d)' | head -1) || true

        if [[ -n "$MKL_MAJOR" && -n "$ICX_MAJOR" && "$MKL_MAJOR" != "$ICX_MAJOR" ]]; then
            WARN "Version mismatch: MKL ${MKL_MAJOR} vs compiler ${ICX_MAJOR}."
            WARN "  MKL requires libsycl.so from oneAPI ${MKL_MAJOR} compiler."
            WARN "  Upgrading intel-oneapi-compiler-dpcpp-cpp to match…"
            sudo apt-get update -qq &>> "$LOG_FILE" || true
            local upgraded=0
            for pkg in intel-oneapi-compiler-dpcpp-cpp intel-oneapi-dpcpp-cpp; do
                if sudo apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE" | grep -q "upgraded\|newly installed"; then
                    upgraded=1; break
                fi
                if dpkg -s "$pkg" &>/dev/null 2>&1; then
                    sudo apt-get install --only-upgrade -y "$pkg" 2>&1 | tee -a "$LOG_FILE" || true
                    upgraded=1; break
                fi
            done

            ICX_BIN=$(find /opt/intel/oneapi/compiler -name icx -type f 2>/dev/null \
                | sort -rV | head -1) || true
            ICX_MAJOR=$(echo "$ICX_BIN" | grep -oP '\d{4}(?=\.\d)' | head -1) || true

            if [[ "$MKL_MAJOR" == "$ICX_MAJOR" ]]; then
                OK "Compiler upgraded to match MKL ${MKL_MAJOR}."
            else
                WARN "Compiler still at ${ICX_MAJOR} — apt may not have a ${MKL_MAJOR} package yet."
                WARN "  The build may fail with linker errors."
            fi
        fi

        export PATH="$(dirname "$ICX_BIN"):$PATH"
    else
        INFO "icx not on PATH — sourcing oneAPI setvars.sh for first-time setup…"

        local SETVARS=""
        SETVARS=$(find /opt/intel/oneapi -name setvars.sh -type f 2>/dev/null | head -1) || true

        if [[ -z "$SETVARS" ]]; then
            INFO "Installing Intel oneAPI SYCL compiler…"
            if [[ ! -f /etc/apt/sources.list.d/oneAPI.list ]]; then
                curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
                    | sudo gpg --yes --dearmor \
                        --output /usr/share/keyrings/oneapi-archive-keyring.gpg \
                    || { ERR "Failed to import oneAPI GPG key."; return 1; }
                echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] \
https://apt.repos.intel.com/oneapi all main" \
                    | sudo tee /etc/apt/sources.list.d/oneAPI.list > /dev/null
                sudo apt-get update -qq 2>&1 | tee -a "$LOG_FILE" || true
            fi

            local installed_oneapi=0
            for pkg in intel-oneapi-compiler-dpcpp-cpp intel-oneapi-dpcpp-cpp; do
                if sudo apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
                    installed_oneapi=1; break
                fi
            done

            if (( installed_oneapi == 0 )); then
                ERR "Could not install any oneAPI SYCL compiler package."
                WARN "  Check: sudo apt-get update && apt-cache search oneapi | grep dpcpp"
                return 1
            fi
        fi

        ICX_BIN=$(command -v icx 2>/dev/null) \
            || ICX_BIN=$(find /opt/intel/oneapi -name icx -type f 2>/dev/null | head -1) \
            || true

        if [[ -n "$ICX_BIN" ]]; then
            export PATH="$(dirname "$ICX_BIN"):$PATH"
            OK "icx ready: $ICX_BIN"
        else
            ERR "icx still not found — check apt output in $LOG_FILE"
            WARN "  Open a new terminal and run: source /opt/intel/oneapi/setvars.sh"
        fi
    fi

    # ── 4. Patch shell profiles with setvars.sh ────────────────────────────
    local SETVARS_FOR_PROFILE=""
    SETVARS_FOR_PROFILE=$(find /opt/intel/oneapi -name setvars.sh -type f 2>/dev/null | head -1) || true
    if [[ -n "$SETVARS_FOR_PROFILE" ]]; then
        local SETVARS_LINE="source \"$SETVARS_FOR_PROFILE\" 2>/dev/null || true  # Intel oneAPI"
        for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [[ -f "$rc" ]] && ! grep -q "Intel oneAPI" "$rc" 2>/dev/null; then
                echo "" >> "$rc"
                echo "$SETVARS_LINE" >> "$rc"
                INFO "  Patched $rc with oneAPI setvars.sh"
            fi
        done
    fi

    # ── 5. Groups and verify ───────────────────────────────────────────────
    sudo usermod -aG render,video "$USER" 2>/dev/null || true
    OK "User added to render/video groups (re-login to take effect)."

    INFO "Quick GPU visibility check:"
    if command -v clinfo &>/dev/null; then
        clinfo -l 2>/dev/null | grep -i "intel\|Arc" \
            && OK "  Intel GPU visible via OpenCL" \
            || WARN "  Intel GPU NOT visible via OpenCL (may need re-login)"
    fi

    if dpkg -s libze-intel-gpu1 &>/dev/null 2>&1 \
    || dpkg -s intel-level-zero-gpu &>/dev/null 2>&1; then
        OK "  level-zero GPU shim installed — SYCL will see the GPU after re-login"
    else
        WARN "  level-zero shim NOT installed — SYCL will not find the GPU"
    fi
}
