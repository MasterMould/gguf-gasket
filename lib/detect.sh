#!/bin/bash
# lib/detect.sh — Hardware detection with multi-device profile support
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
    WARN "The 8B model download is ~5 GB. Ensure you have ~8 GB free total."
    return 0
}

# ================================================================
#  GPU DETECTION HELPERS
# ================================================================

detect_gpu_detailed() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null || true)
    
    local nvidia_gpus=()
    local amd_gpus=()
    local intel_gpus=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ VGA|3D|Display ]]; then
            if echo "$line" | grep -iq "NVIDIA"; then
                nvidia_gpus+=("$line")
            elif echo "$line" | grep -iqE "Advanced Micro Devices|AMD.*Radeon|ATI.*Radeon"; then
                amd_gpus+=("$line")
            elif echo "$line" | grep -iqE "Intel.*(Graphics|UHD|Iris|Arc|HD Graphics|DG)"; then
                intel_gpus+=("$line")
            fi
        fi
    done <<< "$gpu_info"
    
    echo "NVIDIA:${#nvidia_gpus[@]}"
    echo "AMD:${#amd_gpus[@]}"
    echo "INTEL:${#intel_gpus[@]}"
    
    for gpu in "${nvidia_gpus[@]}"; do echo "NVIDIA_GPU:$gpu"; done
    for gpu in "${amd_gpus[@]}"; do echo "AMD_GPU:$gpu"; done
    for gpu in "${intel_gpus[@]}"; do echo "INTEL_GPU:$gpu"; done
}

# Primary GPU detection - Robust matching for AMD architectures
detect_gpu() {
    # Check for device profile first
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
    
    # Check for manual override
    local override_file="$HOME/ai_stack/gpu_override.txt"
    if [[ -n "$profile_override" ]]; then
        echo "$profile_override"
        return 0
    elif [[ -f "$override_file" ]]; then
        local override
        override=$(cat "$override_file" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        case "$override" in
            NVIDIA|AMD|INTEL|CPU)
                echo "$override"
                return 0
                ;;
        esac
    fi
    
    local gpu_info
    gpu_info=$(lspci 2>/dev/null || true)
    
    # Priority: NVIDIA > AMD > Intel > CPU
    
    # NVIDIA check
    if echo "$gpu_info" | grep -iq "NVIDIA"; then
        echo "NVIDIA"
        return 0
    fi
    
    # AMD checks with multiple patterns
    if echo "$gpu_info" | grep -iqE "(Advanced Micro Devices|AMD).*Radeon"; then
        echo "AMD"
        return 0
    fi
    if echo "$gpu_info" | grep -iqE "ATI.*Radeon"; then
        echo "AMD"
        return 0
    fi
    if echo "$gpu_info" | grep -iqE "AMD.*(VGA|Display|3D)"; then
        echo "AMD"
        return 0
    fi
    
    # Intel check - FIXED PATTERN FOR ARC
    while IFS= read -r line; do
        if echo "$line" | grep -iq "Intel"; then
            if echo "$line" | grep -iqE "VGA|3D|Display|Graphics|Arc|DG"; then
                if ! echo "$gpu_info" | grep -iqE "(AMD|ATI).*(Radeon|VGA|Display|3D)"; then
                    echo "INTEL"
                    return 0
                fi
            fi
        fi
    done <<< "$gpu_info"
    
    echo "CPU"
}

# Interactive selection with device profile support
select_gpu_with_override() {
    local detected
    detected=$(detect_gpu)
    
    local details
    details=$(detect_gpu_detailed)
    
    local nvidia_count amd_count intel_count
    nvidia_count=$(echo "$details" | grep "^NVIDIA:" | cut -d: -f2)
    amd_count=$(echo "$details" | grep "^AMD:" | cut -d: -f2)
    intel_count=$(echo "$details" | grep "^INTEL:" | cut -d: -f2)
    
    # FIX: Wrap all visual prints into standard error so they don't corrupt captured variable data
    {
        echo ""
        echo -e "${B_CYAN}Device: $(hostname)${NC}"
        echo -e "${B_CYAN}GPU Detection Results:${NC}"
        echo ""
        
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
            echo -e "  ${B_GREEN}Intel GPUs found: $intel_count${NC}"
            echo "$details" | grep "^INTEL_GPU:" | cut -d: -f2- | while read -r gpu; do
                echo "    → $gpu"
            done
        fi
        
        echo ""
        echo -e "${B_CYAN}Auto-detected primary GPU: ${B_YELLOW}$detected${NC}"
    } >&2
    
    # Check for active overrides
    local override_file="$HOME/ai_stack/gpu_override.txt"
    local has_profile=0
    if [ -d "$PROFILE_DIR" ]; then
        local current_hostname=$(hostname)
        for profile in "$PROFILE_DIR"/*.profile; do
            [ -f "$profile" ] || continue
            source "$profile"
            if [ "$HOSTNAME" = "$current_hostname" ]; then
                local pname=$(basename "$profile" .profile)
                INFO "Device profile active: $pname (GPU: $GPU_TYPE)" >&2
                has_profile=1
                break
            fi
        done
    fi
    
    if [[ -f "$override_file" ]] && [[ $has_profile -eq 0 ]]; then
        local current_override
        current_override=$(cat "$override_file" 2>/dev/null)
        INFO "Manual override active: $current_override" >&2
    fi
    
    echo "" >&2
    
    local total_gpus=$((nvidia_count + amd_count + intel_count))
    
    # Always offer override for multi-device scenarios
    if [[ $total_gpus -gt 1 ]] || [[ "$detected" == "CPU" && $total_gpus -gt 0 ]] || [[ "$detected" == "INTEL" && $amd_count -gt 0 ]]; then
        {
            WARN "Multiple GPUs or potential misdetection."
            echo ""
            echo "  Override options:"
            echo "  1) Use auto-detected ($detected)"
            
            local option_num=2
            [[ $nvidia_count -gt 0 ]] && { echo "  $option_num) Force NVIDIA"; ((option_num++)); }
            [[ $amd_count -gt 0 ]] && { echo "  $option_num) Force AMD"; ((option_num++)); }
            [[ $intel_count -gt 0 ]] && { echo "  $option_num) Force Intel"; ((option_num++)); }
            echo "  $option_num) CPU only (no GPU)"
            ((option_num++))
            echo "  $option_num) Save as device profile"
            echo ""
        } >&2
        
        local choice
        read -r -p "  Select [1-$option_num]: " choice
        
        option_num=2
        if [[ $nvidia_count -gt 0 ]]; then
            if [[ "$choice" == "$option_num" ]]; then
                detected="NVIDIA"
                echo "NVIDIA" > "$override_file"
                OK "Forcing NVIDIA GPU" >&2
            fi
            ((option_num++))
        fi
        
        if [[ $amd_count -gt 0 ]]; then
            if [[ "$choice" == "$option_num" ]]; then
                detected="AMD"
                echo "AMD" > "$override_file"
                OK "Forcing AMD GPU" >&2
            fi
            ((option_num++))
        fi
        
        if [[ $intel_count -gt 0 ]]; then
            if [[ "$choice" == "$option_num" ]]; then
                detected="INTEL"
                echo "INTEL" > "$override_file"
                OK "Forcing Intel GPU" >&2
            fi
            ((option_num++))
        fi
        
        if [[ "$choice" == "$option_num" ]]; then
            detected="CPU"
            echo "CPU" > "$override_file"
            OK "Forcing CPU-only mode" >&2
        fi
        ((option_num++))
        
        if [[ "$choice" == "$option_num" ]]; then
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
            # FIX: Fixed logic error where code implicitly stored 'INTEL' to override during profile creations
            echo "$detected" > "$override_file"
        fi
        
        if [[ "$choice" == "1" ]]; then
            rm -f "$override_file" 2>/dev/null || true
            INFO "Using auto-detected: $detected" >&2
        fi
    fi
    
    {
        echo ""
        echo -e "  ${B_GREEN}Selected GPU type: $detected${NC}"
        echo ""
        
        if [[ -f "$override_file" ]]; then
            INFO "Override file: $override_file"
            INFO "To clear: rm $override_file"
        fi
    } >&2
    
    # FIX: Only return the exact structural clean string to standard output stream
    echo -n "$detected"
}

# Status display
show_gpu_status() {
    local detected
    detected=$(detect_gpu)
    
    local override_file="$HOME/ai_stack/gpu_override.txt"
    local has_profile=0
    
    if [ -d "$PROFILE_DIR" ]; then
        local current_hostname=$(hostname)
        for profile in "$PROFILE_DIR"/*.profile; do
            [ -f "$profile" ] || continue
            source "$profile"
            if [ "$HOSTNAME" = "$current_hostname" ]; then
                local pname=$(basename "$profile" .profile)
                echo -e "  GPU Type   : ${B_YELLOW}$detected${NC} ${B_CYAN}(profile: $pname)${NC}"
                has_profile=1
                break
            fi
        done
    fi
    
    if [[ $has_profile -eq 0 ]]; then
        if [[ -f "$override_file" ]]; then
            echo -e "  GPU Type   : ${B_YELLOW}$detected${NC} ${B_CYAN}(overridden)${NC}"
        else
            echo -e "  GPU Type   : ${B_GREEN}$detected${NC} ${B_YELLOW}(auto-detected)${NC}"
        fi
    fi
    
    local gpu_line=""
    case "$detected" in
        NVIDIA)
            gpu_line=$(lspci 2>/dev/null | grep -i "nvidia" | grep -iE "vga|3d|display" | head -1)
            ;;
        AMD)
            gpu_line=$(lspci 2>/dev/null | grep -iE "(amd|ati)" | grep -iE "vga|3d|display|radeon" | head -1)
            ;;
        INTEL)
            gpu_line=$(lspci 2>/dev/null | grep -i "intel" | grep -iE "vga|graphics|display|arc" | head -1)
            ;;
        CPU)
            gpu_line="No GPU acceleration"
            ;;
    esac
    
    if [[ -n "$gpu_line" ]]; then
        gpu_line="${gpu_line:0:70}"
        echo -e "  GPU Info   : $gpu_line"
    fi
}
