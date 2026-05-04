#!/bin/bash
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
        local src="$BUILD_DIR/bin/$binary"
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

    # Intel SYCL: persist oneAPI runtime lib paths so binaries work outside the script
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
    INFO "  (New terminals will pick this up automatically)"
}

# ================================================================
#  SMART BUILD ENGINE
# ================================================================
build_engine() {
    draw_header
    if ! check_deps; then
        read -p "Press Enter to return..."
        return
    fi

    local current_gpu
    current_gpu=$(detect_gpu)
    echo -e "${B_CYAN}Building AI Engine for $current_gpu...${NC}"

    # Base packages — libdnnl-dev excluded for Intel (system libdnnl lacks SYCL interop)
    local base_pkgs=(
        pkg-config ca-certificates unzip file libfuse2
        libwebkit2gtk-4.1-dev libgtk-3-dev gpg-agent
        software-properties-common ocl-icd-libopencl1
        build-essential git curl cmake
        libcurl4-openssl-dev libssl-dev
    )
    [[ "$current_gpu" != "INTEL" ]] && base_pkgs+=(libdnnl-dev)

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${base_pkgs[@]}" &>> "$LOG_FILE" || true

    if [[ "$current_gpu" == "INTEL" ]]; then
        if dpkg -s libdnnl-dev &>/dev/null 2>&1; then
            INFO "Removing system libdnnl-dev (incompatible with SYCL — using oneAPI dnnl)…"
            sudo apt-get remove -y libdnnl-dev &>> "$LOG_FILE" || true
        fi
    fi

    OK "System packages installed."
    mkdir -p "$HOME/ai_stack"

    if [ ! -d "$INSTALL_DIR/.git" ]; then
        git clone https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR" \
            | tee -a "$LOG_FILE" \
            || { echo "Clone failed."; read -p "Press Enter..."; return 1; }
    else
        echo "Updating existing llama.cpp repo..." | tee -a "$LOG_FILE"
        (cd "$INSTALL_DIR" && git pull) | tee -a "$LOG_FILE" || true
    fi

    cd "$INSTALL_DIR" || { echo -e "${B_RED}Cannot cd into $INSTALL_DIR${NC}"; read -p "Press Enter..."; return 1; }

    if [ -d "build" ]; then
        read -p "Existing build directory found. Rebuild from scratch? (y/n): " rebuild
        [[ "$rebuild" == "y" ]] && rm -rf build
    fi

    mkdir -p build
    cd build || { echo -e "${B_RED}Cannot cd into build directory${NC}"; read -p "Press Enter..."; return 1; }

    local cmake_flags=()

    case $current_gpu in
        "NVIDIA")
            install_Nvidia_gpu_drivers
            local arch
            arch=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
                | tr -d '.' | grep -E '^[0-9]+$' | head -n 1 || true)
            [ -z "$arch" ] && arch="all-major"
            echo "Using CUDA architecture: $arch" | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_CUDA=ON" "-DCMAKE_CUDA_ARCHITECTURES=$arch")
            ;;

        "AMD")
            install_AMD_gpu_drivers
            echo "Optimizing for AMD (Vulkan)..." | tee -a "$LOG_FILE"
            cmake_flags+=("-DGGML_VULKAN=ON" "-DGGML_VULKAN_FLASH_ATTN=ON")
            ;;

        "INTEL")
            install_intel_gpu_drivers
            echo "Optimizing for Intel Arc (SYCL)..." | tee -a "$LOG_FILE"

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
                echo "OneAPI icx confirmed: $ICX_PATH" | tee -a "$LOG_FILE"

                local ICPX_PATH="$icx_bin_dir/icpx"
                [[ ! -f "$ICPX_PATH" ]] && \
                    ICPX_PATH=$(find /opt/intel/oneapi -name icpx -type f 2>/dev/null | head -1) || true

                if [[ -z "$ICPX_PATH" ]]; then
                    ERR "icpx not found — oneAPI compiler install may be incomplete."
                    read -rp "Continue with CPU fallback? (y/n): " sycl_fallback
                    [[ "${sycl_fallback,,}" != "y" ]] && { read -p "Press Enter..."; return; }
                else
                    echo "icpx confirmed: $ICPX_PATH" | tee -a "$LOG_FILE"
                    cmake_flags+=("-DGGML_SYCL=ON")
                    cmake_flags+=("-DCMAKE_CXX_COMPILER=$ICPX_PATH")
                    cmake_flags+=("-DCMAKE_C_COMPILER=$ICX_PATH")
                fi

                # MKL
                local MKL_CMAKE_DIR=""
                MKL_CMAKE_DIR=$(find /opt/intel/oneapi/mkl -name "MKLConfig.cmake" \
                    -type f 2>/dev/null | head -1 | xargs -r dirname) || true
                if [[ -n "$MKL_CMAKE_DIR" ]]; then
                    cmake_flags+=("-DMKL_DIR=$MKL_CMAKE_DIR")
                    cmake_flags+=("-DCMAKE_PREFIX_PATH=/opt/intel/oneapi/mkl/latest")
                    echo "MKL cmake dir: $MKL_CMAKE_DIR" | tee -a "$LOG_FILE"
                else
                    WARN "MKLConfig.cmake not found — intel-oneapi-mkl-devel may not be installed."
                    read -rp "Continue anyway? cmake will likely fail. (y/n): " mkl_fallback
                    [[ "${mkl_fallback,,}" != "y" ]] && { read -p "Press Enter..."; return; }
                fi

                # Compiler lib dir derived from ICX_PATH — version-safe
                local ICX_VERSION_DIR
                ICX_VERSION_DIR=$(dirname "$(dirname "$ICX_PATH")")
                local ONEAPI_LIB_DIR="$ICX_VERSION_DIR/lib"
                if [[ ! -f "$ONEAPI_LIB_DIR/libsycl.so" ]]; then
                    [[ -f "$ICX_VERSION_DIR/lib64/libsycl.so" ]] \
                        && ONEAPI_LIB_DIR="$ICX_VERSION_DIR/lib64" \
                        || { WARN "libsycl.so not found under $ICX_VERSION_DIR"; ONEAPI_LIB_DIR=""; }
                fi
                echo "SYCL lib dir: $ONEAPI_LIB_DIR" | tee -a "$LOG_FILE"

                local MKL_LIB_DIR=""
                MKL_LIB_DIR=$(find /opt/intel/oneapi/mkl -maxdepth 3 -name "libmkl_core.so" \
                    -type f 2>/dev/null | sort -rV | head -1 | xargs -r dirname) || true

                # TBB
                local TBB_ROOT="" TBB_CMAKE_DIR="" TBB_LIB_DIR=""
                TBB_ROOT=$(find /opt/intel/oneapi/tbb -maxdepth 1 -mindepth 1 \
                    -type d 2>/dev/null | sort -rV | head -1) || true
                if [[ -n "$TBB_ROOT" ]]; then
                    TBB_CMAKE_DIR=$(find "$TBB_ROOT" -name "TBBConfig.cmake" \
                        -type f 2>/dev/null | head -1 | xargs -r dirname) || true
                    TBB_LIB_DIR=$(find "$TBB_ROOT/lib" -name "libtbb.so*" \
                        -type f 2>/dev/null | head -1 | xargs -r dirname) || true
                fi
                echo "TBB root: $TBB_ROOT | cmake: $TBB_CMAKE_DIR | lib: $TBB_LIB_DIR" \
                    | tee -a "$LOG_FILE"

                # ONEAPI_ROOT for cmake SYCL detection
                local ONEAPI_ROOT_DIR
                ONEAPI_ROOT_DIR=$(dirname "$(dirname "$ICX_VERSION_DIR")")
                export ONEAPI_ROOT="$ONEAPI_ROOT_DIR"
                echo "ONEAPI_ROOT: $ONEAPI_ROOT" | tee -a "$LOG_FILE"

                # CMAKE_LIBRARY_PATH
                local oneapi_lib_paths=""
                [[ -n "$ONEAPI_LIB_DIR" ]] && oneapi_lib_paths+="$ONEAPI_LIB_DIR;"
                [[ -n "$MKL_LIB_DIR"    ]] && oneapi_lib_paths+="$MKL_LIB_DIR;"
                [[ -n "$TBB_LIB_DIR"    ]] && oneapi_lib_paths+="$TBB_LIB_DIR;"
                [[ -n "$oneapi_lib_paths" ]] && \
                    cmake_flags+=("-DCMAKE_LIBRARY_PATH=${oneapi_lib_paths%;}")

                [[ -n "$TBB_CMAKE_DIR" ]] && \
                    cmake_flags+=("-DTBB_DIR=$TBB_CMAKE_DIR") || \
                    WARN "TBB cmake config not found — MKL::MKL_SYCL::BLAS may fail."

                # rpath for runtime
                local rpath_flags=""
                [[ -n "$ONEAPI_LIB_DIR" ]] && rpath_flags+="-Wl,-rpath,$ONEAPI_LIB_DIR "
                [[ -n "$MKL_LIB_DIR"    ]] && rpath_flags+="-Wl,-rpath,$MKL_LIB_DIR "
                [[ -n "$TBB_LIB_DIR"    ]] && rpath_flags+="-Wl,-rpath,$TBB_LIB_DIR "
                if [[ -n "$rpath_flags" ]]; then
                    cmake_flags+=("-DCMAKE_SHARED_LINKER_FLAGS=${rpath_flags% }")
                    cmake_flags+=("-DCMAKE_EXE_LINKER_FLAGS=${rpath_flags% }")
                fi

                # oneDNN: use oneAPI bundled if available, else suppress system one
                local DNNL_CMAKE_DIR=""
                DNNL_CMAKE_DIR=$(find /opt/intel/oneapi -name "dnnlConfig.cmake" \
                    -o -name "oneapi-dnnl-config.cmake" -o -name "dnnl-config.cmake" \
                    2>/dev/null | head -1 | xargs -r dirname) || true
                if [[ -n "$DNNL_CMAKE_DIR" ]]; then
                    cmake_flags+=("-Ddnnl_DIR=$DNNL_CMAKE_DIR")
                    echo "oneAPI dnnl dir: $DNNL_CMAKE_DIR" | tee -a "$LOG_FILE"
                else
                    cmake_flags+=("-DCMAKE_DISABLE_FIND_PACKAGE_DNNL=ON")
                    cmake_flags+=("-DCMAKE_DISABLE_FIND_PACKAGE_oneDNN=ON")
                    WARN "oneAPI dnnl not found — disabling oneDNN (DNNL/oneDNN find suppressed)."
                fi

                [[ -n "$ONEAPI_LIB_DIR" ]] && export LD_LIBRARY_PATH="$ONEAPI_LIB_DIR:${LD_LIBRARY_PATH:-}"
                [[ -n "$MKL_LIB_DIR"    ]] && export LD_LIBRARY_PATH="$MKL_LIB_DIR:${LD_LIBRARY_PATH:-}"
                [[ -n "$TBB_LIB_DIR"    ]] && export LD_LIBRARY_PATH="$TBB_LIB_DIR:${LD_LIBRARY_PATH:-}"
            else
                echo -e "${B_RED}[!] icx compiler not found. SYCL build will fail.${NC}" | tee -a "$LOG_FILE"
                read -rp "Continue with CPU fallback? (y/n): " sycl_fallback
                [[ "${sycl_fallback,,}" != "y" ]] && { read -p "Press Enter..."; return; }
            fi
            ;;

        *)
            echo "No supported GPU found. Building for CPU only." | tee -a "$LOG_FILE"
            ;;
    esac

    cmake_flags+=("-DGGML_CURL=ON" "-DGGML_SERVER_SSL=ON")

    echo "CMake flags: ${cmake_flags[*]}" | tee -a "$LOG_FILE"
    cmake .. "${cmake_flags[@]}" 2>&1 | tee -a "$LOG_FILE" \
        || { echo "CMake config failed."; read -p "Press Enter..."; return 1; }
    cmake --build . --config Release -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE" \
        || { echo "CMake build failed."; read -p "Press Enter..."; return 1; }

    rotate_log

    if [ -f "bin/llama-server" ]; then
        echo -e "\n${B_GREEN}✔ Success: Built for $current_gpu!${NC}"
        echo -e "${B_YELLOW} Adding $USER to render & video groups…${NC}"
        sudo usermod -aG render "$USER" || true
        sudo usermod -aG video  "$USER" || true
        echo ""
        STEP "Installing binaries to PATH…"
        install_to_path
    else
        echo -e "\n${B_RED}✖ Build failed. Check logs with option 8.${NC}"
    fi
    read -p "Press Enter to return..."
}
