#!/bin/bash
# lib/detect.sh — Hardware detection & GGML backend selector
# Requires: globals.sh

PROFILE_DIR="$HOME/ai_stack/device_profiles"

# ================================================================
#  PREFLIGHT DEPENDENCY CHECK
# ================================================================
check_deps() {
    declare -A PKG_MAP=(
        [git]="git"
        [cmake]="cmake"
        [curl]="curl"
        [openssl]="openssl"
        [lspci]="pciutils"
        [ccache]="ccache"
        [nproc]="coreutils"
        [wget]="wget"
        [gpg]="gnupg2"
    )

    local missing_cmds=() missing_pkgs=()
    for cmd in "${!PKG_MAP[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
            missing_pkgs+=("${PKG_MAP[$cmd]}")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        echo -e "${B_YELLOW}[!] Missing tools: ${missing_cmds[*]}${NC}"
        echo -e "    Packages needed: ${missing_pkgs[*]}"
        echo ""
        read -r -p "    Auto-install missing packages now? (y/n): " do_install
        if [[ "${do_install,,}" == "y" ]]; then
            echo -e "${B_CYAN}  Running apt-get update…${NC}"
            sudo apt-get update -qq &>> "$LOG_FILE" || true
            echo -e "${B_CYAN}  Installing: ${missing_pkgs[*]}…${NC}"
            local unique_pkgs
            mapfile -t unique_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
            if sudo apt-get install -y "${unique_pkgs[@]}" &>> "$LOG_FILE"; then
                OK "Packages installed."
            else
                ERR "apt-get install failed — check logs."
                return 1
            fi
            local still_missing=()
            for cmd in "${missing_cmds[@]}"; do
                command -v "$cmd" &>/dev/null || still_missing+=("$cmd")
            done
            if [[ ${#still_missing[@]} -gt 0 ]]; then
                ERR "Still missing after install: ${still_missing[*]}"
                return 1
            fi
            OK "All dependencies satisfied."
        else
            ERR "Cannot continue without required tools. Install manually and retry."
            return 1
        fi
    fi

    if [[ "$(uname -m)" != "x86_64" ]]; then
        ERR "x86_64 architecture required. Detected: $(uname -m)"
        return 1
    fi

    echo ""
    INFO "Available disk: $(df -h "$HOME" | awk 'NR==2{print $4}') free"
    INFO "System RAM:     $(free -h | awk '/Mem:/ {print $2}')"
    WARN "Ensure you have enough disk space for target models."
    return 0
}

# ================================================================
#  GPU & BACKEND DETECTION HELPERS
# ================================================================

detect_gpu_detailed() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null || true)
    
    local nvidia_gpus=()
    local amd_gpus=()
    local intel_gpus=()
    local integrated_gpus=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ VGA|3D|Display ]]; then
            if echo "$line" | grep -iq "NVIDIA"; then
                nvidia_gpus+=("$line")
            elif echo "$line" | grep -iqE "amd|ati|radeon|advanced micro devices|ellesmere"; then
                amd_gpus+=("$line")
            elif echo "$line" | grep -iqE "Intel.*(Graphics|UHD|Iris|Arc|HD Graphics|DG)"; then
                intel_gpus+=("$line")
            fi
            
            # Identify integrated keywords explicitly
            if echo "$line" | grep -iqE "integrated|uhd|iris|vega|raphael|cezanne|renoir"; then
                integrated_gpus+=("$line")
            fi
        fi
    done <<< "$gpu_info"
    
    echo "NVIDIA:${#nvidia_gpus[@]}"
    echo "AMD:${#amd_gpus[@]}"
    echo "INTEL:${#intel_gpus[@]}"
    echo "INTEGRATED:${#integrated_gpus[@]}"
    
    for gpu in "${nvidia_gpus[@]}"; do echo "NVIDIA_GPU:$gpu"; done
    for gpu in "${amd_gpus[@]}"; do echo "AMD_GPU:$gpu"; done
    for gpu in "${intel_gpus[@]}"; do echo "INTEL_GPU:$gpu"; done
    for gpu in "${integrated_gpus[@]}"; do echo "INTEGRATED_GPU:$gpu"; done
}

detect_gpu() {
    local profile_override=""
    if [ -d "$PROFILE_DIR" ]; then
        local current_hostname=$(hostname)
        for profile in "$PROFILE_DIR"/*.profile; do
            [ -f "$profile" ] || continue
            source "$profile"
            if [ "$HOSTNAME" = "$current_hostname" ] && [ -n "$GPU_TYPE" ]; then
                profile_override="$GPU_TYPE"
                break
            fi
        done
    fi
    
    local override_file="$HOME/ai_stack/gpu_override.txt"
    if [[ -n "$profile_override" ]]; then
        echo "$profile_override"
        return 0
    elif [[ -f "$override_file" ]]; then
        local override
        override=$(cat "$override_file" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        case "$override" in
            VULKAN|CUDA|HIP|SYCL|AMD|NVIDIA|INTEL|IGPU)
                [[ "$override" == "AMD" || "$override" == "IGPU" ]] && override="VULKAN"
                [[ "$override" == "NVIDIA" ]] && override="CUDA"
                [[ "$override" == "INTEL" ]] && override="SYCL"
                echo "$override"
                return 0
                ;;
        esac
    fi
    
    local gpu_info
    gpu_info=$(lspci 2>/dev/null || true)
    
    if echo "$gpu_info" | grep -iq "NVIDIA"; then
        echo "CUDA"
        return 0
    fi
    
    if echo "$gpu_info" | grep -iqE "amd|ati|radeon|advanced micro devices|ellesmere"; then
        echo "VULKAN"
        return 0
    fi
    
    while IFS= read -r line; do
        if echo "$line" | grep -iq "Intel"; then
            if echo "$line" | grep -iqE "VGA|3D|Display|Graphics|Arc|DG"; then
                echo "SYCL"
                return 0
            fi
        fi
    done <<< "$gpu_info"
    
    echo "UNKNOWN"
}

select_gpu_with_override() {
    local detected
    detected=$(detect_gpu)
    
    local details
    details=$(detect_gpu_detailed)
    
    local nvidia_count amd_count intel_count integrated_count
    nvidia_count=$(echo "$details" | grep "^NVIDIA:" | cut -d: -f2)
    amd_count=$(echo "$details" | grep "^AMD:" | cut -d: -f2)
    intel_count=$(echo "$details" | grep "^INTEL:" | cut -d: -f2)
    integrated_count=$(echo "$details" | grep "^INTEGRATED:" | cut -d: -f2)
    
    {
        echo ""
        echo -e "${B_CYAN}Device: $(hostname)${NC}"
        echo -e "${B_CYAN}Hardware Scan Results:${NC}"
        echo ""
        
        if [[ $nvidia_count -gt 0 ]]; then
            echo -e "  ${B_GREEN}NVIDIA GPUs detected: $nvidia_count${NC}"
            echo "$details" | grep "^NVIDIA_GPU:" | cut -d: -f2- | while read -r gpu; do echo "    → $gpu"; done
        fi
        
        if [[ $amd_count -gt 0 ]]; then
            echo -e "  ${B_GREEN}AMD Hardware detected: $amd_count${NC}"
            echo "$details" | grep "^AMD_GPU:" | cut -d: -f2- | while read -r gpu; do echo "    → $gpu"; done
        fi
        
        if [[ $intel_count -gt 0 ]]; then
            echo -e "  ${B_GREEN}Intel Hardware detected: $intel_count${NC}"
            echo "$details" | grep "^INTEL_GPU:" | cut -d: -f2- | while read -r gpu; do echo "    → $gpu"; done
        fi
        
        if [[ $integrated_count -gt 0 ]]; then
            echo -e "  ${B_GREEN}Integrated Graphics detected${NC}"
            echo "$details" | grep "^INTEGRATED_GPU:" | cut -d: -f2- | while read -r gpu; do echo "    → $gpu"; done
        fi
        
        echo ""
        echo -e "${B_CYAN}Auto-selected GGML Backend: ${B_YELLOW}$detected${NC}"
    } >&2
    
    local override_file="$HOME/ai_stack/gpu_override.txt"
    local total_gpus=$((nvidia_count + amd_count + intel_count))
    
    {
        WARN "Hardware configuration options:"
        echo ""
        echo "  Select GGML Execution Backend:"
        echo "  1) Use auto-detected ($detected)"
        echo "  2) Force Vulkan       (-DGGML_VULKAN=ON)  [AMD RX / Cross-Vendor / AMD iGPU]"
        echo "  3) Force CUDA         (-DGGML_CUDA=ON)    [NVIDIA dGPU]"
        echo "  4) Force HIP          (-DGGML_HIP=ON)     [AMD ROCm]"
        echo "  5) Force Intel SYCL   (-DGGML_SYCL=ON)    [Intel Arc / Intel Integrated Graphics]"
        echo "  6) Force Integrated iGPU (Vulkan/SYCL)    [Route processing to processor graphics]"
        echo "  7) Save target as device profile"
        echo ""
    } >&2
    
    local choice
    read -r -p "  Select [1-7]: " choice
    
    case "$choice" in
        2) detected="VULKAN"; echo "VULKAN" > "$override_file" ;;
        3) detected="CUDA"; echo "CUDA" > "$override_file" ;;
        4) detected="HIP"; echo "HIP" > "$override_file" ;;
        5) detected="SYCL"; echo "SYCL" > "$override_file" ;;
        6) 
           # Route to SYCL if Intel iGPU is present, otherwise Vulkan for AMD/generic iGPU
           if [[ $intel_count -gt 0 ]]; then
               detected="SYCL"
           else
               detected="VULKAN"
           fi
           echo "$detected" > "$override_file"
           ;;
        7)
            echo "" >&2
            local hostname=$(hostname)
            read -r -p "  Profile name [${hostname}_profile]: " pname
            pname="${pname:-${hostname}_profile}"
            mkdir -p "$PROFILE_DIR"
            cat > "$PROFILE_DIR/${pname}.profile" << EOF
# Device Profile: $pname
# Created: $(date)
GPU_TYPE=$detected
HOSTNAME=$hostname
CREATED=$(date +%s)
EOF
            OK "Created profile: $pname" >&2
            echo "$detected" > "$override_file"
            ;;
        *)
            rm -f "$override_file" 2>/dev/null || true
            INFO "Using auto-detected backend: $detected" >&2
            ;;
    esac
    
    {
        echo ""
        echo -e "  ${B_GREEN}Active llama.cpp Target Backend: $detected${NC}"
        echo ""
    } >&2
    
    echo -n "$detected"
}

show_gpu_status() {
    local detected
    detected=$(detect_gpu)
    
    echo -e "  Target Backend : ${B_GREEN}$detected${NC}"
    local gpu_line
    gpu_line=$(lspci 2>/dev/null | grep -iE "vga|3d|display" | head -1)
    if [[ -n "$gpu_line" ]]; then
        gpu_line="${gpu_line:0:70}"
        echo -e "  GPU Hardware   : $gpu_line"
    fi
}
