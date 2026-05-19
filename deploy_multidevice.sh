#!/bin/bash
# Master Deployment Script - Multi-Device Edition
# Deploys all fixes and sets up device profile system

set -e

B_GREEN='\033[1;32m'
B_RED='\033[1;31m'
B_YELLOW='\033[1;33m'
B_CYAN='\033[1;36m'
NC='\033[0m'

echo -e "${B_CYAN}================================================${NC}"
echo -e "${B_CYAN}GGUF-GASKET MULTI-DEVICE DEPLOYMENT${NC}"
echo -e "${B_CYAN}================================================${NC}"
echo ""

# Find repository
REPO_ROOT=""
for path in ~/gguf-gasket ~/ai_stack/gguf-gasket . ..; do
    if [ -f "$path/llama_manager.sh" ] && [ -d "$path/lib" ]; then
        REPO_ROOT="$path"
        break
    fi
done

if [ -z "$REPO_ROOT" ]; then
    echo -e "${B_RED}✗ Could not find gguf-gasket repository${NC}"
    read -r -p "  Enter path to gguf-gasket: " REPO_ROOT
    if [ ! -f "$REPO_ROOT/llama_manager.sh" ]; then
        echo -e "${B_RED}✗ Invalid path${NC}"
        exit 1
    fi
fi

REPO_ROOT=$(cd "$REPO_ROOT" && pwd)
echo -e "${B_GREEN}✓ Repository: $REPO_ROOT${NC}"
echo ""

# Detect current device
CURRENT_HOSTNAME=$(hostname)
echo -e "${B_CYAN}Current Device: ${B_YELLOW}$CURRENT_HOSTNAME${NC}"
echo ""

# Detect GPUs
echo -e "${B_CYAN}Detected Hardware:${NC}"
lspci | grep -iE "vga|3d|display" | sed 's/^/  /'
echo ""

# Create backup
BACKUP_DIR="$REPO_ROOT/backups_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo -e "${B_GREEN}✓ Backup directory: $BACKUP_DIR${NC}"
echo ""

# Check what files are available
AVAILABLE_FIXES=()
[ -f "detect_multidevice.sh" ] && AVAILABLE_FIXES+=("detect")
[ -f "drivers_gpu_fixed_integrated.sh" ] && AVAILABLE_FIXES+=("drivers")
[ -f "menu_mem0_fixed.sh" ] && AVAILABLE_FIXES+=("mem0")
[ -f "menu_searxng_fixed.sh" ] && AVAILABLE_FIXES+=("searxng")
[ -f "menu_download_fixed.sh" ] && AVAILABLE_FIXES+=("download")
[ -f "device_profile_manager.sh" ] && AVAILABLE_FIXES+=("profiles")

echo -e "${B_CYAN}Available fixes in current directory:${NC}"
for fix in "${AVAILABLE_FIXES[@]}"; do
    echo "  ✓ $fix"
done
echo ""

if [ ${#AVAILABLE_FIXES[@]} -eq 0 ]; then
    echo -e "${B_RED}✗ No fix files found in current directory${NC}"
    echo "  Please cd to directory containing the fix files"
    exit 1
fi

read -r -p "Deploy all available fixes? (y/n): " confirm
if [[ "${confirm,,}" != "y" ]]; then
    echo "Cancelled"
    exit 0
fi

echo ""
echo -e "${B_CYAN}================================================${NC}"
echo -e "${B_CYAN}DEPLOYING FIXES${NC}"
echo -e "${B_CYAN}================================================${NC}"
echo ""

# Deploy detect.sh
if [[ " ${AVAILABLE_FIXES[@]} " =~ " detect " ]]; then
    echo -e "${B_CYAN}1. Deploying detect.sh (multi-device support)${NC}"
    [ -f "$REPO_ROOT/lib/detect.sh" ] && cp "$REPO_ROOT/lib/detect.sh" "$BACKUP_DIR/"
    cp detect_multidevice.sh "$REPO_ROOT/lib/detect.sh"
    echo -e "   ${B_GREEN}✓ Installed${NC}"
fi

# Deploy drivers_gpu.sh
if [[ " ${AVAILABLE_FIXES[@]} " =~ " drivers " ]]; then
    echo -e "${B_CYAN}2. Deploying drivers_gpu.sh (comprehensive drivers)${NC}"
    [ -f "$REPO_ROOT/lib/drivers_gpu.sh" ] && cp "$REPO_ROOT/lib/drivers_gpu.sh" "$BACKUP_DIR/"
    cp drivers_gpu_fixed_integrated.sh "$REPO_ROOT/lib/drivers_gpu.sh"
    echo -e "   ${B_GREEN}✓ Installed${NC}"
fi

# Patch menu_build.sh
echo -e "${B_CYAN}3. Patching menu_build.sh${NC}"
if [ -f "$REPO_ROOT/lib/menu_build.sh" ]; then
    cp "$REPO_ROOT/lib/menu_build.sh" "$BACKUP_DIR/"
    if grep -q "current_gpu=\$(detect_gpu)" "$REPO_ROOT/lib/menu_build.sh"; then
        sed -i 's/current_gpu=$(detect_gpu)/current_gpu=$(select_gpu_with_override)/g' "$REPO_ROOT/lib/menu_build.sh"
        echo -e "   ${B_GREEN}✓ Patched (uses select_gpu_with_override)${NC}"
    else
        echo -e "   ${B_YELLOW}⚠ Already patched or pattern not found${NC}"
    fi
fi

# Deploy other modules
if [[ " ${AVAILABLE_FIXES[@]} " =~ " mem0 " ]]; then
    echo -e "${B_CYAN}4. Deploying menu_mem0.sh${NC}"
    [ -f "$REPO_ROOT/lib/menu_mem0.sh" ] && cp "$REPO_ROOT/lib/menu_mem0.sh" "$BACKUP_DIR/"
    cp menu_mem0_fixed.sh "$REPO_ROOT/lib/menu_mem0.sh"
    echo -e "   ${B_GREEN}✓ Installed${NC}"
fi

if [[ " ${AVAILABLE_FIXES[@]} " =~ " searxng " ]]; then
    echo -e "${B_CYAN}5. Deploying menu_searxng.sh${NC}"
    [ -f "$REPO_ROOT/lib/menu_searxng.sh" ] && cp "$REPO_ROOT/lib/menu_searxng.sh" "$BACKUP_DIR/"
    cp menu_searxng_fixed.sh "$REPO_ROOT/lib/menu_searxng.sh"
    echo -e "   ${B_GREEN}✓ Installed${NC}"
fi

if [[ " ${AVAILABLE_FIXES[@]} " =~ " download " ]]; then
    echo -e "${B_CYAN}6. Deploying menu_download.sh${NC}"
    [ -f "$REPO_ROOT/lib/menu_download.sh" ] && cp "$REPO_ROOT/lib/menu_download.sh" "$BACKUP_DIR/"
    cp menu_download_fixed.sh "$REPO_ROOT/lib/menu_download.sh"
    echo -e "   ${B_GREEN}✓ Installed${NC}"
fi

# Deploy device profile manager
if [[ " ${AVAILABLE_FIXES[@]} " =~ " profiles " ]]; then
    echo -e "${B_CYAN}7. Deploying device profile manager${NC}"
    cp device_profile_manager.sh "$REPO_ROOT/"
    chmod +x "$REPO_ROOT/device_profile_manager.sh"
    echo -e "   ${B_GREEN}✓ Installed${NC}"
fi

echo ""
echo -e "${B_GREEN}================================================${NC}"
echo -e "${B_GREEN}DEPLOYMENT COMPLETE${NC}"
echo -e "${B_GREEN}================================================${NC}"
echo ""
echo "Backups saved to: $BACKUP_DIR"
echo ""

# Offer to create device profile
echo -e "${B_CYAN}================================================${NC}"
echo -e "${B_CYAN}DEVICE PROFILE SETUP${NC}"
echo -e "${B_CYAN}================================================${NC}"
echo ""
echo "Would you like to create a device profile for this machine?"
echo "This allows automatic GPU detection on subsequent builds."
echo ""
read -r -p "Create device profile now? (y/n): " create_profile

if [[ "${create_profile,,}" == "y" ]]; then
    if [ -f "$REPO_ROOT/device_profile_manager.sh" ]; then
        cd "$REPO_ROOT"
        ./device_profile_manager.sh quick
    else
        echo ""
        echo -e "${B_YELLOW}Device profile manager not found.${NC}"
        echo "You can still manually set GPU type:"
        echo ""
        echo "Detected GPUs:"
        lspci | grep -iE "vga|3d|display"
        echo ""
        echo "Set GPU type:"
        echo "  1) NVIDIA"
        echo "  2) AMD"
        echo "  3) INTEL"
        echo "  4) CPU only"
        echo "  5) Skip"
        read -r -p "Select [1-5]: " gpu_choice
        
        case $gpu_choice in
            1) mkdir -p ~/ai_stack; echo "NVIDIA" > ~/ai_stack/gpu_override.txt; echo -e "${B_GREEN}✓ Set to NVIDIA${NC}" ;;
            2) mkdir -p ~/ai_stack; echo "AMD" > ~/ai_stack/gpu_override.txt; echo -e "${B_GREEN}✓ Set to AMD${NC}" ;;
            3) mkdir -p ~/ai_stack; echo "INTEL" > ~/ai_stack/gpu_override.txt; echo -e "${B_GREEN}✓ Set to INTEL${NC}" ;;
            4) mkdir -p ~/ai_stack; echo "CPU" > ~/ai_stack/gpu_override.txt; echo -e "${B_GREEN}✓ Set to CPU${NC}" ;;
            5) echo "Skipped" ;;
            *) echo -e "${B_RED}Invalid${NC}" ;;
        esac
    fi
fi

echo ""
echo -e "${B_CYAN}================================================${NC}"
echo -e "${B_CYAN}NEXT STEPS${NC}"
echo -e "${B_CYAN}================================================${NC}"
echo ""
echo "1. Run the build menu:"
echo "   cd $REPO_ROOT"
echo "   ./llama_manager.sh"
echo ""
echo "2. Select: Build AI Engine"
echo ""
echo "3. It will use the configured GPU type"
echo ""
echo "4. After driver installation (if any), REBOOT:"
echo "   sudo reboot"
echo ""
echo "5. On other devices:"
echo "   - Copy repository: rsync -av $REPO_ROOT/ user@device:~/gguf-gasket/"
echo "   - On each device: ./device_profile_manager.sh quick"
echo ""
echo -e "${B_GREEN}Deployment successful!${NC}"
echo ""
