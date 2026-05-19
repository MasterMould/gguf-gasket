#!/bin/bash
# Device Profile Manager for Multi-Device Deployments
# Allows saving and switching between different device configurations

PROFILE_DIR="$HOME/ai_stack/device_profiles"
CURRENT_PROFILE_LINK="$HOME/ai_stack/gpu_override.txt"

B_GREEN='\033[1;32m'
B_RED='\033[1;31m'
B_YELLOW='\033[1;33m'
B_CYAN='\033[1;36m'
NC='\033[0m'

# ================================================================
#  DEVICE PROFILE FUNCTIONS
# ================================================================

create_profile() {
    local profile_name="$1"
    local gpu_type="$2"
    
    mkdir -p "$PROFILE_DIR"
    
    cat > "$PROFILE_DIR/${profile_name}.profile" << EOF
# Device Profile: $profile_name
# Created: $(date)
GPU_TYPE=$gpu_type
HOSTNAME=$(hostname)
CREATED=$(date +%s)
EOF
    
    echo -e "${B_GREEN}✓ Created profile: $profile_name${NC}"
}

list_profiles() {
    if [ ! -d "$PROFILE_DIR" ]; then
        echo -e "${B_YELLOW}No profiles found${NC}"
        return
    fi
    
    echo -e "${B_CYAN}Available Device Profiles:${NC}"
    echo ""
    
    local current_gpu=""
    if [ -f "$CURRENT_PROFILE_LINK" ]; then
        current_gpu=$(cat "$CURRENT_PROFILE_LINK" 2>/dev/null)
    fi
    
    local count=0
    for profile in "$PROFILE_DIR"/*.profile; do
        [ -f "$profile" ] || continue
        count=$((count + 1))
        
        local name=$(basename "$profile" .profile)
        source "$profile"
        
        local marker=""
        if [ "$GPU_TYPE" = "$current_gpu" ]; then
            marker=" ${B_GREEN}(active)${NC}"
        fi
        
        echo -e "  $count) ${B_CYAN}$name${NC} - GPU: ${B_YELLOW}$GPU_TYPE${NC}$marker"
        echo "     Hostname: $HOSTNAME"
        echo ""
    done
    
    if [ $count -eq 0 ]; then
        echo -e "${B_YELLOW}No profiles found${NC}"
    fi
}

activate_profile() {
    local profile_name="$1"
    local profile_file="$PROFILE_DIR/${profile_name}.profile"
    
    if [ ! -f "$profile_file" ]; then
        echo -e "${B_RED}✗ Profile not found: $profile_name${NC}"
        return 1
    fi
    
    source "$profile_file"
    echo "$GPU_TYPE" > "$CURRENT_PROFILE_LINK"
    
    echo -e "${B_GREEN}✓ Activated profile: $profile_name${NC}"
    echo -e "  GPU Type: ${B_YELLOW}$GPU_TYPE${NC}"
}

detect_and_suggest_profile() {
    local current_hostname=$(hostname)
    
    # Check if we have a profile for this hostname
    if [ -d "$PROFILE_DIR" ]; then
        for profile in "$PROFILE_DIR"/*.profile; do
            [ -f "$profile" ] || continue
            source "$profile"
            
            if [ "$HOSTNAME" = "$current_hostname" ]; then
                local name=$(basename "$profile" .profile)
                echo -e "${B_CYAN}Found saved profile for this device: $name${NC}"
                echo -e "GPU Type: ${B_YELLOW}$GPU_TYPE${NC}"
                echo ""
                read -r -p "Use this profile? (y/n): " use_saved
                if [[ "${use_saved,,}" == "y" ]]; then
                    activate_profile "$name"
                    return 0
                fi
            fi
        done
    fi
    
    return 1
}

# ================================================================
#  INTERACTIVE MENU
# ================================================================

device_profile_menu() {
    while true; do
        clear
        echo -e "${B_CYAN}========================================${NC}"
        echo -e "${B_CYAN}   DEVICE PROFILE MANAGER${NC}"
        echo -e "${B_CYAN}========================================${NC}"
        echo ""
        echo -e "Current Device: ${B_YELLOW}$(hostname)${NC}"
        
        local current_gpu="auto-detect"
        if [ -f "$CURRENT_PROFILE_LINK" ]; then
            current_gpu=$(cat "$CURRENT_PROFILE_LINK" 2>/dev/null)
        fi
        echo -e "Current GPU:    ${B_YELLOW}$current_gpu${NC}"
        echo ""
        
        # Show detected GPU
        echo -e "${B_CYAN}Detected Hardware:${NC}"
        lspci | grep -iE "vga|3d|display" | sed 's/^/  /'
        echo ""
        
        list_profiles
        echo ""
        echo "Actions:"
        echo "  1) Create new profile for this device"
        echo "  2) Activate existing profile"
        echo "  3) Delete profile"
        echo "  4) Return to auto-detect"
        echo "  5) Back"
        echo ""
        
        read -r -p "Select [1-5]: " choice
        
        case $choice in
            1)
                echo ""
                read -r -p "Profile name (e.g., thinkcentre_m91p): " pname
                if [ -z "$pname" ]; then
                    echo -e "${B_RED}Invalid name${NC}"
                    sleep 2
                    continue
                fi
                
                echo ""
                echo "Select GPU type for $pname:"
                echo "  1) NVIDIA"
                echo "  2) AMD"
                echo "  3) INTEL"
                echo "  4) CPU (no GPU)"
                read -r -p "Select [1-4]: " gpu_choice
                
                case $gpu_choice in
                    1) create_profile "$pname" "NVIDIA" ;;
                    2) create_profile "$pname" "AMD" ;;
                    3) create_profile "$pname" "INTEL" ;;
                    4) create_profile "$pname" "CPU" ;;
                    *) echo -e "${B_RED}Invalid${NC}" ;;
                esac
                sleep 2
                ;;
            2)
                echo ""
                read -r -p "Profile name to activate: " pname
                activate_profile "$pname"
                sleep 2
                ;;
            3)
                echo ""
                read -r -p "Profile name to delete: " pname
                if [ -f "$PROFILE_DIR/${pname}.profile" ]; then
                    rm "$PROFILE_DIR/${pname}.profile"
                    echo -e "${B_GREEN}✓ Deleted${NC}"
                else
                    echo -e "${B_RED}✗ Not found${NC}"
                fi
                sleep 2
                ;;
            4)
                rm -f "$CURRENT_PROFILE_LINK"
                echo -e "${B_GREEN}✓ Cleared override - will auto-detect${NC}"
                sleep 2
                ;;
            5)
                return
                ;;
            *)
                echo -e "${B_RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# ================================================================
#  QUICK PROFILE SETUP
# ================================================================

quick_setup() {
    echo -e "${B_CYAN}========================================${NC}"
    echo -e "${B_CYAN}   QUICK DEVICE SETUP${NC}"
    echo -e "${B_CYAN}========================================${NC}"
    echo ""
    
    # Try to detect saved profile
    if detect_and_suggest_profile; then
        return 0
    fi
    
    # No saved profile - create one
    echo "No saved profile for this device."
    echo ""
    echo "Detected hardware:"
    lspci | grep -iE "vga|3d|display"
    echo ""
    
    local hostname=$(hostname)
    read -r -p "Create profile for this device? (y/n): " create
    if [[ "${create,,}" != "y" ]]; then
        return 1
    fi
    
    local default_name="${hostname}_profile"
    read -r -p "Profile name [$default_name]: " pname
    pname="${pname:-$default_name}"
    
    echo ""
    echo "Select GPU type:"
    echo "  1) NVIDIA"
    echo "  2) AMD"
    echo "  3) INTEL"
    echo "  4) CPU only"
    echo "  5) Auto-detect (don't save profile)"
    read -r -p "Select [1-5]: " gpu_choice
    
    case $gpu_choice in
        1) create_profile "$pname" "NVIDIA"; activate_profile "$pname" ;;
        2) create_profile "$pname" "AMD"; activate_profile "$pname" ;;
        3) create_profile "$pname" "INTEL"; activate_profile "$pname" ;;
        4) create_profile "$pname" "CPU"; activate_profile "$pname" ;;
        5) echo "Skipping profile creation - will auto-detect" ;;
        *) echo -e "${B_RED}Invalid${NC}" ;;
    esac
}

# ================================================================
#  COMMAND LINE INTERFACE
# ================================================================

if [ $# -eq 0 ]; then
    # Interactive mode
    device_profile_menu
else
    # Command line mode
    case "$1" in
        create)
            if [ $# -lt 3 ]; then
                echo "Usage: $0 create <name> <GPU_TYPE>"
                exit 1
            fi
            create_profile "$2" "$3"
            ;;
        activate|use)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 activate <name>"
                exit 1
            fi
            activate_profile "$2"
            ;;
        list)
            list_profiles
            ;;
        quick)
            quick_setup
            ;;
        menu)
            device_profile_menu
            ;;
        *)
            echo "Usage: $0 {create|activate|list|quick|menu}"
            echo ""
            echo "Examples:"
            echo "  $0 quick                          # Quick setup wizard"
            echo "  $0 create thinkcentre AMD         # Create AMD profile"
            echo "  $0 activate thinkcentre           # Switch to profile"
            echo "  $0 list                           # Show all profiles"
            echo "  $0 menu                           # Interactive menu"
            exit 1
            ;;
    esac
fi
