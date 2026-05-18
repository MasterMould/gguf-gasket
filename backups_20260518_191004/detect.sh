#!/bin/bash
# lib/detect.sh — Hardware detection and preflight dependency check
# Requires: globals.sh

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
    WARN "The 8B model download is ~5 GB. Ensure you have ~8 GB free total."
    return 0
}

# ================================================================
#  GPU DETECTION WITH DETAILED LOGGING
# ================================================================
detect_gpu_detailed() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null || true)
    
    # Find all GPUs
    local nvidia_gpus=()
    local amd_gpus=()
    local intel_gpus=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ VGA|3D|Display ]]; then
            if echo "$line" | grep -iq "NVIDIA"; then
                nvidia_gpus+=("$line")
            elif echo "$line" | grep -iqE "Advanced Micro Devices|AMD|ATI.*Radeon"; then
                amd_gpus+=("$line")
            elif echo "$line" | grep -iqE "Intel.*(Graphics|UHD|Iris|Arc|HD Graphics)"; then
                intel_gpus+=("$line")
            fi
        fi
    done <<< "$gpu_info"
    
    # Return detailed info
    echo "NVIDIA:${#nvidia_gpus[@]}"
    echo "AMD:${#amd_gpus[@]}"
    echo "INTEL:${#intel_gpus[@]}"
    
    # Print GPU details if any found
    if [[ ${#nvidia_gpus[@]} -gt 0 ]]; then
        for gpu in "${nvidia_gpus[@]}"; do
            echo "NVIDIA_GPU:$gpu"
        done
    fi
    if [[ ${#amd_gpus[@]} -gt 0 ]]; then
        for gpu in "${amd_gpus[@]}"; do
            echo "AMD_GPU:$gpu"
        done
    fi
    if [[ ${#intel_gpus[@]} -gt 0 ]]; then
        for gpu in "${intel_gpus[@]}"; do
            echo "INTEL_GPU:$gpu"
        done
    fi
}

# ================================================================
#  GPU DETECTION - PRIMARY FUNCTION
# ================================================================
detect_gpu() {
    # Check for manual override first
    local override_file="$HOME/ai_stack/gpu_override.txt"
    if [[ -f "$override_file" ]]; then
        local override
        override=$(cat "$override_file" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        case "$override" in
            NVIDIA|AMD|INTEL|CPU)
                echo "$override"
                return 0
                ;;
        esac
    fi
    
    # Auto-detection
    local gpu_info
    gpu_info=$(lspci 2>/dev/null || true)
    
    # Priority order: NVIDIA > AMD > Intel > CPU
    # This order ensures discrete GPUs are preferred over integrated
    
    # Check for NVIDIA (highest priority - usually discrete)
    if echo "$gpu_info" | grep -iq "NVIDIA"; then
        echo "NVIDIA"
        return 0
    fi
    
    # Check for AMD (second priority - usually discrete)
    # IMPROVED: More specific patterns to catch AMD GPUs
    if echo "$gpu_info" | grep -iqE "(Advanced Micro Devices|AMD).*\[(Radeon|VGA|Display|3D)\]"; then
        echo "AMD"
        return 0
    fi
    # Fallback AMD pattern for older naming
    if echo "$gpu_info" | grep -iqE "ATI.*(Radeon|VGA|Display)"; then
        echo "AMD"
        return 0
    fi
    
    # Check for Intel (lowest priority - usually integrated)
    # Only return Intel if NO discrete GPU found
    if echo "$gpu_info" | grep -iqE "Intel.*(Graphics|UHD|Iris|Arc|HD Graphics)"; then
        # Double-check that there's no AMD GPU we missed
        if ! echo "$gpu_info" | grep -iqE "(AMD|ATI).*(Radeon|VGA|Display)"; then
            echo "INTEL"
            return 0
        fi
    fi
    
    # No GPU found
    echo "CPU"
}

# ================================================================
#  GPU SELECTION WITH OVERRIDE OPTION
# ================================================================
select_gpu_with_override() {
    local detected
    detected=$(detect_gpu)
    
    # Get detailed GPU info
    local details
    details=$(detect_gpu_detailed)
    
    # Count GPUs
    local nvidia_count amd_count intel_count
    nvidia_count=$(echo "$details" | grep "^NVIDIA:" | cut -d: -f2)
    amd_count=$(echo "$details" | grep "^AMD:" | cut -d: -f2)
    intel_count=$(echo "$details" | grep "^INTEL:" | cut -d: -f2)
    
    echo ""
    echo -e "${B_CYAN}GPU Detection Results:${NC}"
    echo ""
    
    # Show detected GPUs
    if [[ $nvidia_count -gt 0 ]]; then
        echo -e "  ${B_GREEN}NVIDIA GPUs found: $nvidia_count${NC}"
        echo "$details" | grep "^NVIDIA_GPU:" | cut -d: -f2- | while read -r gpu; do
            echo "    → $gpu"
        done
    fi
    
    if [[ $amd_count -gt 0 ]]; then
        echo -e "  ${B_GREEN}AMD GPUs found: $amd_count${NC}"
        echo "$details" | grep "^AMD_GPU:" | cut -d: -f2- | while read -r gpu; do
            echo "    → $gpu"
        done
    fi
    
    if [[ $intel_count -gt 0 ]]; then
        echo -e "  ${B_YELLOW}Intel GPUs found: $intel_count${NC}"
        echo "$details" | grep "^INTEL_GPU:" | cut -d: -f2- | while read -r gpu; do
            echo "    → $gpu"
        done
    fi
    
    echo ""
    echo -e "${B_CYAN}Auto-detected primary GPU: ${B_YELLOW}$detected${NC}"
    echo ""
    
    # Offer override if multiple GPUs or if Intel was chosen with AMD present
    local total_gpus=$((nvidia_count + amd_count + intel_count))
    
    if [[ $total_gpus -gt 1 ]] || [[ "$detected" == "INTEL" && $amd_count -gt 0 ]]; then
        WARN "Multiple GPUs detected or integrated GPU selected with discrete GPU present."
        echo ""
        echo "  You can override the auto-detection:"
        echo "  1) Use auto-detected ($detected)"
        
        [[ $nvidia_count -gt 0 ]] && echo "  2) Force NVIDIA"
        [[ $amd_count -gt 0 ]] && echo "  3) Force AMD"
        [[ $intel_count -gt 0 ]] && echo "  4) Force Intel"
        echo "  5) Use CPU only (no GPU)"
        echo ""
        
        local choice
        read -r -p "  Select [1-5]: " choice
        
        case $choice in
            2)
                if [[ $nvidia_count -gt 0 ]]; then
                    detected="NVIDIA"
                    echo "NVIDIA" > "$HOME/ai_stack/gpu_override.txt"
                    OK "Forcing NVIDIA GPU"
                fi
                ;;
            3)
                if [[ $amd_count -gt 0 ]]; then
                    detected="AMD"
                    echo "AMD" > "$HOME/ai_stack/gpu_override.txt"
                    OK "Forcing AMD GPU"
                fi
                ;;
            4)
                if [[ $intel_count -gt 0 ]]; then
                    detected="INTEL"
                    echo "INTEL" > "$HOME/ai_stack/gpu_override.txt"
                    OK "Forcing Intel GPU"
                fi
                ;;
            5)
                detected="CPU"
                echo "CPU" > "$HOME/ai_stack/gpu_override.txt"
                OK "Forcing CPU-only mode"
                ;;
            1|*)
                INFO "Using auto-detected: $detected"
                ;;
        esac
    fi
    
    echo ""
    echo -e "  ${B_GREEN}Selected GPU type: $detected${NC}"
    echo ""
    
    # Show override file location
    if [[ -f "$HOME/ai_stack/gpu_override.txt" ]]; then
        local current_override
        current_override=$(cat "$HOME/ai_stack/gpu_override.txt" 2>/dev/null)
        INFO "GPU override active: $current_override"
        INFO "To clear: rm $HOME/ai_stack/gpu_override.txt"
    fi
    
    echo "$detected"
}

# ================================================================
#  SHOW GPU STATUS (for status displays)
# ================================================================
show_gpu_status() {
    local detected
    detected=$(detect_gpu)
    
    local override_file="$HOME/ai_stack/gpu_override.txt"
    if [[ -f "$override_file" ]]; then
        local override
        override=$(cat "$override_file" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        echo -e "  GPU Type   : ${B_YELLOW}$detected${NC} ${B_CYAN}(overridden)${NC}"
    else
        echo -e "  GPU Type   : ${B_GREEN}$detected${NC} ${B_YELLOW}(auto-detected)${NC}"
    fi
    
    # Show lspci GPU line
    local gpu_line
    case "$detected" in
        NVIDIA)
            gpu_line=$(lspci 2>/dev/null | grep -i "nvidia" | grep -i "vga\|3d\|display" | head -1)
            ;;
        AMD)
            gpu_line=$(lspci 2>/dev/null | grep -iE "(amd|ati)" | grep -i "vga\|3d\|display\|radeon" | head -1)
            ;;
        INTEL)
            gpu_line=$(lspci 2>/dev/null | grep -i "intel" | grep -i "vga\|graphics\|display" | head -1)
            ;;
        CPU)
            gpu_line="No GPU acceleration"
            ;;
    esac
    
    if [[ -n "$gpu_line" ]]; then
        # Trim to 70 chars for display
        gpu_line="${gpu_line:0:70}"
        echo -e "  GPU Info   : $gpu_line"
    fi
}
