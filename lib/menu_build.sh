#!/bin/bash
# Menu module — auto-discovered by llama_manager.sh
MENU_LABEL="Build AI Engine"
MENU_FN="build_engine"
MENU_COLOR="${B_CYAN}"
MENU_ORDER=10

# lib/build.sh — AI engine build and PATH installation
# Requires: globals.sh, detect.sh, drivers_gpu.sh, drivers_intel.sh

# ================================================================
#  PATH INSTALLER
# ================================================================
install_to_path() {
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"

    local installed_any=0
    for binary in llama-cli llama-server; do
        local src="$INSTALL_DIR/build/bin/$binary"
        local dst="$bin_dir/$binary"
        if [[ ! -f "$src" ]]; then
            WARN "  $binary not found at $src — skipping."
            continue
        fi
        [[ -L "$dst" || -f "$dst" ]] && rm -f "$dst"
        ln -s "$src" "$dst"
        OK "  $binary → $dst (symlink)"
        installed_any=1
    done

    if (( installed_any == 0 )); then
        WARN "No binaries were linked — build may have failed."
        return 1
    fi

    local path_line='export PATH="$HOME/.local/bin:$PATH"  # llama.cpp binaries'
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [[ -f "$rc" ]] || continue
        if ! grep -q "llama.cpp binaries" "$rc" 2>/dev/null; then
            echo "" >> "$rc"
            echo "$path_line" >> "$rc"
            INFO "  Patched $rc with PATH entry."
        fi
    done

    export PATH="$bin_dir:$PATH"

    # Intel SYCL: persist oneAPI runtime lib paths
    local _sycl_lib _mkl_lib
    _sycl_lib=$(find /opt/intel/oneapi/compiler -name "libsycl.so" -type f 2>/dev/null \
        | sort -rV | head -1 | xargs -r dirname) || true
    _mkl_lib=$(find /opt/intel/oneapi/mkl -maxdepth 3 -name "libmkl_core.so" -type f 2>/dev/null \
        | sort -rV | head -1 | xargs -r dirname) || true

    if [[ -n "$_sycl_lib" || -n "$_mkl_lib" ]]; then
        local oneapi_lib_line="export LD_LIBRARY_PATH=\"${_sycl_lib:+$_sycl_lib:}${_mkl_lib:+$_mkl_lib:}\${LD_LIBRARY_PATH:-}\"  # oneAPI runtime"
        for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
            [[ -f "$rc" ]] || continue
            if ! grep -q "oneAPI runtime" "$rc" 2>/dev/null; then
                echo "" >> "$rc"
                echo "$oneapi_lib_line" >> "$rc"
                INFO "  Patched $rc with oneAPI LD_LIBRARY_PATH."
            fi
        done
        [[ -n "$_sycl_lib" ]] && export LD_LIBRARY_PATH="$_sycl_lib:${LD_LIBRARY_PATH:-}"
        [[ -n "$_mkl_lib"  ]] && export LD_LIBRARY_PATH="$_mkl_lib:${LD_LIBRARY_PATH:-}"
    fi

    echo ""
    OK "llama-cli and llama-server are now available system-wide."
    INFO "  Run: llama-cli --help"
    INFO "  Run: llama-server --help"
}

# ================================================================
#  SMART BUILD ENGINE (BACKEND-CENTRIC)
# ================================================================
build_engine() {
    draw_header
    if ! check_deps; then
        read -p "Press Enter to return..."
        return
    fi

    local target_backend=""
    local detected_vendor
    detected_vendor=$(select_gpu_with_override 2>/dev/null | tr -d '[:space:]' || echo "UNKNOWN")

    # Map physical hardware probe directly to llama.cpp target backends
    if lspci 2>/dev/null | grep -iE "vga|3d|display" | grep -iqE "amd|ati|radeon|ellesmere"; then
        target_backend="VULKAN"
    elif lspci 2>/dev/null | grep -iE "vga|3d|display" | grep -iq "NVIDIA"; then
        target_backend="CUDA"
    elif lspci 2>/dev/null | grep -iE "vga|3d|display" | grep -iq "Intel"; then
        target_backend="SYCL"
    fi

    # OVERRIDE / SELECTION MENU: Explicitly choose llama.cpp backend flags
    if [[ "$target_backend" != "VULKAN" && "$target_backend" != "CUDA" && "$target_backend" != "HIP" && "$target_backend" != "SYCL" ]]; then
        echo -e "${B_YELLOW}⚠️  Could not automatically map acceleration backend to hardware.${NC}"
        echo -e "Enforcing strict policy: 'Never Build CPU Only'."
        echo -e "\nSelect target llama.cpp execution backend:"
        echo -e "  1) Vulkan  (-DGGML_VULKAN=ON)  --> Recommended for AMD RX 570/580 / Cross-Vendor"
        echo -e "  2) CUDA    (-DGGML_CUDA=ON)    --> NVIDIA GPUs"
        echo -e "  3) HIP     (-DGGML_HIP=ON)     --> AMD ROCm platform"
        echo -e "  4) SYCL    (-DGGML_SYCL=ON)    --> Intel Arc / oneAPI"
        echo -e "  5) Abort Build Sequence"
        echo ""
        read -rp "Enter selection [1-5]: " backend_choice
        case "$backend_choice" in
            1) target_backend="VULKAN" ;;
            2) target_backend="CUDA" ;;
            3) target_backend="HIP" ;;
            4) target_backend="SYCL" ;;
            *) echo -e "${B_RED}❌ Build canceled by user request.${NC}"; read -p "Press Enter to return..."; return 1 ;;
        esac
    fi

    echo -e "${B_CYAN}Configuring build for llama.cpp Backend: $target_backend...${NC}"

    # Standard base system packages
    local base_pkgs=(
        pkg-config ca-certificates unzip file libfuse2
        libwebkit2gtk-4.1-dev libgtk-3-dev gpg-agent
        software-properties-common ocl-icd-libopencl1
        build-essential git curl cmake pciutils
        libcurl4-openssl-dev libssl-dev
    )

    # Attach backend-specific runtime packages
    case "$target_backend" in
        "VULKAN")
            base_pkgs+=(vulkan-tools libvulkan-dev mesa-vulkan-drivers glslc libshaderc-dev spirv-tools)
            ;;
        "HIP")
            base_pkgs+=(hip-runtime-amd rocblas)
            ;;
    esac

    [[ "$target_backend" != "SYCL" ]] && base_pkgs+=(libdnnl-dev)

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${base_pkgs[@]}" &>> "$LOG_FILE" || true

    if [[ "$target_backend" == "SYCL" ]]; then
        if dpkg -s libdnnl-dev &>/dev/null 2>&1; then
            INFO "Removing system libdnnl-dev (incompatible with SYCL — using oneAPI dnnl)…"
            sudo apt-get remove -y libdnnl-dev &>> "$LOG_FILE" || true
        fi
    fi

    OK "System dependencies ready."
    mkdir -p "$HOME/ai_stack"

    if [ ! -d "$INSTALL_DIR/.git" ]; then
        git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR" \
            | tee -a "$LOG_FILE" \
            || { echo "Clone failed."; read -p "Press Enter..."; return 1; }
    else
        echo "Updating existing llama.cpp repository..." | tee -a "$LOG_FILE"
        (cd "$INSTALL_DIR" && git pull) | tee -a "$LOG_FILE" || true
    fi

    cd "$INSTALL_DIR" || { echo -e "${B_RED}Cannot cd into $INSTALL_DIR${NC}"; read -p "Press Enter..."; return 1; }

    local rebuild="n"
    if [ -d "build" ]; then
        read -p "Existing build folder found. Rebuild from scratch? (y/n): " rebuild
        [[ "$rebuild" == "y" ]] && rm -rf build
    fi

    local cmake_flags=()

    # Configure llama.cpp flags based directly on GGML execution targets
    case "$target_backend" in
        "VULKAN")
            echo "Building with Vulkan backend (-DGGML_VULKAN=ON)..." | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_VULKAN=ON" "-DGGML_VULKAN_FLASH_ATTN=ON")
            ;;

        "CUDA")
            install_Nvidia_gpu_drivers 2>/dev/null || true
            local arch
            arch=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
                | tr -d '.' | grep -E '^[0-9]+$' | head -n 1 || true)
            [ -z "$arch" ] && arch="all-major"
            echo "Building with CUDA backend (-DGGML_CUDA=ON, Arch: $arch)..." | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_CUDA=ON" "-DCMAKE_CUDA_ARCHITECTURES=$arch")
            ;;

        "HIP")
            echo "Building with HIP/ROCm backend (-DGGML_HIP=ON)..." | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_HIP=ON" "-DCCACHE=OFF")
            ;;

        "SYCL")
            install_intel_gpu_drivers 2>/dev/null || true
            echo "Building with SYCL backend (-DGGML_SYCL=ON)..." | tee -a "$LOG_FILE"

            local ICX_PATH=""
            ICX_PATH=$(command -v icx 2>/dev/null) || true
            if [[ -n "$ICX_PATH" ]]; then
                local icx_ver newest_ver
                icx_ver=$(echo "$ICX_PATH" | grep -oP '\d{4}(?=\.\d)' | head -1) || true
                newest_ver=$(find /opt/intel/oneapi/compiler -maxdepth 1 -mindepth 1 \
                    -type d 2>/dev/null | grep -oP '\d{4}\.\d[\d.]*' | sort -rV | head -1) || true
                if [[ -n "$newest_ver" && "$icx_ver" != "${newest_ver%%.*}" ]]; then
                    ICX_PATH=$(find /opt/intel/oneapi/compiler/"$newest_ver"/bin \
                        -name icx -type f 2>/dev/null | head -1) || true
                fi
            fi
            [[ -z "$ICX_PATH" ]] && \
                ICX_PATH=$(find /opt/intel/oneapi/compiler -name icx -type f \
                    2>/dev/null | sort -rV | head -1) || true

            if [[ -n "$ICX_PATH" ]]; then
                local icx_bin_dir
                icx_bin_dir=$(dirname "$ICX_PATH")
                export PATH="$icx_bin_dir:$PATH"
                local ICPX_PATH="$icx_bin_dir/icpx"
                [[ ! -f "$ICPX_PATH" ]] && \
                    ICPX_PATH=$(find /opt/intel/oneapi -name icpx -type f 2>/dev/null | head -1) || true

                if [[ -z "$ICPX_PATH" ]]; then
                    ERR "icpx missing — strictly aborting per 'Never Build CPU Only' rule."
                    read -p "Press Enter to return..."; return 1
                else
                    cmake_flags+=("-DGGML_SYCL=ON" "-DCMAKE_CXX_COMPILER=$ICPX_PATH" "-DCMAKE_C_COMPILER=$ICX_PATH")
                fi

                local MKL_CMAKE_DIR=""
                MKL_CMAKE_DIR=$(find /opt/intel/oneapi/mkl -name "MKLConfig.cmake" \
                    -type f 2>/dev/null | head -1 | xargs -r dirname) || true
                if [[ -n "$MKL_CMAKE_DIR" ]]; then
                    cmake_flags+=("-DMKL_DIR=$MKL_CMAKE_DIR" "-DCMAKE_PREFIX_PATH=/opt/intel/oneapi/mkl/latest")
                fi
            else
                ERR "icx compiler not found — strictly aborting per 'Never Build CPU Only' rule."
                read -p "Press Enter to return..."; return 1
            fi
            ;;

        *)
            # HARD STOP: Enforce "Never Build CPU Only" policy
            echo -e "\n${B_RED}❌ Error: Enforced 'Never Build CPU Only' policy. Invalid or unmapped backend target.${NC}" | tee -a "$LOG_FILE"
            read -p "Press Enter to return..."
            return 1
            ;;
    esac

    # Common core feature targets
    cmake_flags+=("-DGGML_CURL=ON" "-DGGML_SERVER_SSL=ON")

    echo "Executing CMake with backend options: ${cmake_flags[*]}" | tee -a "$LOG_FILE"
    
    cmake -B build "${cmake_flags[@]}" 2>&1 | tee -a "$LOG_FILE" \
        || { echo "CMake configuration failed."; read -p "Press Enter..."; return 1; }
        
    cmake --build build --config Release -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE" \
        || { echo "CMake compilation failed."; read -p "Press Enter..."; return 1; }

    rotate_log

    if [ -f "build/bin/llama-server" ]; then
        echo -e "\n${B_GREEN}✔ Success: Built using $target_backend backend!${NC}"
        sudo usermod -aG render "$USER" || true
        sudo usermod -aG video  "$USER" || true
        echo ""
        STEP "Installing binaries to PATH…"
        install_to_path
    else
        echo -e "\n${B_RED}✖ Build failed. Check logs.${NC}"
    fi
    read -p "Press Enter to return..."
}
