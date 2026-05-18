#!/bin/bash
# Master Fix Deployment Script
# Applies all fixes to gguf-gasket repository following proper structure

set -e

B_GREEN='\033[1;32m'
B_RED='\033[1;31m'
B_YELLOW='\033[1;33m'
B_CYAN='\033[1;36m'
NC='\033[0m'

echo -e "${B_CYAN}========================================${NC}"
echo -e "${B_CYAN}GGUF-GASKET COMPREHENSIVE FIX DEPLOYER${NC}"
echo -e "${B_CYAN}========================================${NC}"
echo ""

# Find repository root
REPO_ROOT=""
for path in \
    ~/gguf-gasket \
    ~/ai_stack/gguf-gasket \
    . \
    ..; do
    if [ -f "$path/llama_manager.sh" ] && [ -d "$path/lib" ]; then
        REPO_ROOT="$path"
        break
    fi
done

if [ -z "$REPO_ROOT" ]; then
    echo -e "${B_RED}✗ Could not find gguf-gasket repository${NC}"
    echo "  Please run this script from the repository root, or specify path:"
    read -r -p "  Path to gguf-gasket: " REPO_ROOT
    if [ ! -f "$REPO_ROOT/llama_manager.sh" ]; then
        echo -e "${B_RED}✗ Invalid repository path${NC}"
        exit 1
    fi
fi

REPO_ROOT=$(cd "$REPO_ROOT" && pwd)
echo -e "${B_GREEN}✓ Found repository: $REPO_ROOT${NC}"
echo ""

# Create backup directory
BACKUP_DIR="$REPO_ROOT/backups_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo -e "${B_GREEN}✓ Created backup directory: $BACKUP_DIR${NC}"
echo ""

# List of fixes to apply
echo -e "${B_CYAN}Fixes to apply:${NC}"
echo "  1. detect.sh       - Enhanced GPU detection with override"
echo "  2. drivers_gpu.sh  - Comprehensive AMD/Vulkan driver installer"
echo "  3. menu_build.sh   - Use select_gpu_with_override()"
echo "  4. menu_mem0.sh    - Fix API compatibility + embedder defaults"
echo "  5. menu_searxng.sh - Fix Docker port mapping + validation"
echo "  6. menu_download.sh- Fix HuggingFace URLs + function export"
echo ""

read -r -p "Continue? (y/n): " confirm
if [[ "${confirm,,}" != "y" ]]; then
    echo "Cancelled"
    exit 0
fi

# Function to backup and replace file
backup_and_replace() {
    local src="$1"
    local dest="$2"
    local name=$(basename "$dest")
    
    if [ ! -f "$src" ]; then
        echo -e "${B_RED}✗ Source file not found: $src${NC}"
        return 1
    fi
    
    if [ -f "$dest" ]; then
        cp "$dest" "$BACKUP_DIR/$name"
        echo -e "  ${B_YELLOW}Backed up:${NC} $name"
    fi
    
    cp "$src" "$dest"
    echo -e "  ${B_GREEN}Installed:${NC} $name"
    return 0
}

echo ""
echo -e "${B_CYAN}=====================================${NC}"
echo -e "${B_CYAN}Step 1/6: detect.sh${NC}"
echo -e "${B_CYAN}=====================================${NC}"
if [ -f "detect_fixed_integrated.sh" ]; then
    backup_and_replace "detect_fixed_integrated.sh" "$REPO_ROOT/lib/detect.sh"
else
    echo -e "${B_YELLOW}⚠ detect_fixed_integrated.sh not found in current directory${NC}"
    echo "  Skipping..."
fi

echo ""
echo -e "${B_CYAN}=====================================${NC}"
echo -e "${B_CYAN}Step 2/6: drivers_gpu.sh${NC}"
echo -e "${B_CYAN}=====================================${NC}"
if [ -f "drivers_gpu_fixed_integrated.sh" ]; then
    backup_and_replace "drivers_gpu_fixed_integrated.sh" "$REPO_ROOT/lib/drivers_gpu.sh"
else
    echo -e "${B_YELLOW}⚠ drivers_gpu_fixed_integrated.sh not found in current directory${NC}"
    echo "  Skipping..."
fi

echo ""
echo -e "${B_CYAN}=====================================${NC}"
echo -e "${B_CYAN}Step 3/6: menu_build.sh patch${NC}"
echo -e "${B_CYAN}=====================================${NC}"
if [ -f "$REPO_ROOT/lib/menu_build.sh" ]; then
    # Backup first
    cp "$REPO_ROOT/lib/menu_build.sh" "$BACKUP_DIR/menu_build.sh"
    echo -e "  ${B_YELLOW}Backed up:${NC} menu_build.sh"
    
    # Apply patch
    if grep -q "current_gpu=\$(detect_gpu)" "$REPO_ROOT/lib/menu_build.sh"; then
        sed -i 's/current_gpu=$(detect_gpu)/current_gpu=$(select_gpu_with_override)/g' "$REPO_ROOT/lib/menu_build.sh"
        echo -e "  ${B_GREEN}Patched:${NC} menu_build.sh (now uses select_gpu_with_override)"
    else
        echo -e "  ${B_YELLOW}Already patched or pattern not found${NC}"
    fi
else
    echo -e "${B_RED}✗ menu_build.sh not found${NC}"
fi

echo ""
echo -e "${B_CYAN}=====================================${NC}"
echo -e "${B_CYAN}Step 4/6: menu_mem0.sh${NC}"
echo -e "${B_CYAN}=====================================${NC}"
if [ -f "menu_mem0_fixed.sh" ]; then
    backup_and_replace "menu_mem0_fixed.sh" "$REPO_ROOT/lib/menu_mem0.sh"
else
    echo -e "${B_YELLOW}⚠ menu_mem0_fixed.sh not found in current directory${NC}"
    echo "  Skipping..."
fi

echo ""
echo -e "${B_CYAN}=====================================${NC}"
echo -e "${B_CYAN}Step 5/6: menu_searxng.sh${NC}"
echo -e "${B_CYAN}=====================================${NC}"
if [ -f "menu_searxng_fixed.sh" ]; then
    backup_and_replace "menu_searxng_fixed.sh" "$REPO_ROOT/lib/menu_searxng.sh"
else
    echo -e "${B_YELLOW}⚠ menu_searxng_fixed.sh not found in current directory${NC}"
    echo "  Skipping..."
fi

echo ""
echo -e "${B_CYAN}=====================================${NC}"
echo -e "${B_CYAN}Step 6/6: menu_download.sh${NC}"
echo -e "${B_CYAN}=====================================${NC}"
if [ -f "menu_download_fixed.sh" ]; then
    backup_and_replace "menu_download_fixed.sh" "$REPO_ROOT/lib/menu_download.sh"
else
    echo -e "${B_YELLOW}⚠ menu_download_fixed.sh not found in current directory${NC}"
    echo "  Skipping..."
fi

echo ""
echo -e "${B_GREEN}========================================${NC}"
echo -e "${B_GREEN}DEPLOYMENT COMPLETE${NC}"
echo -e "${B_GREEN}========================================${NC}"
echo ""
echo "Backups saved to: $BACKUP_DIR"
echo ""
echo -e "${B_CYAN}Summary of changes:${NC}"
echo "  • Enhanced GPU detection with priority system"
echo "  • Manual GPU override capability"
echo "  • Comprehensive AMD/Vulkan driver installer"
echo "  • Fixed mem0 API compatibility (v1.x and v2.x)"
echo "  • Fixed SearXNG Docker port mapping"
echo "  • Fixed download HuggingFace URL format"
echo ""
echo -e "${B_YELLOW}IMPORTANT - Your specific issue (ThinkCentre M91p RX 570):${NC}"
echo ""
echo "1. The AMD GPU will now be detected correctly"
echo "2. You can force AMD if needed:"
echo "     mkdir -p ~/ai_stack"
echo "     echo 'AMD' > ~/ai_stack/gpu_override.txt"
echo ""
echo "3. Run the build menu, it will:"
echo "     - Detect AMD GPU (or show override menu)"
echo "     - Install proper Vulkan drivers"
echo "     - Build with AMD support"
echo ""
echo "4. AFTER driver installation, you MUST reboot:"
echo "     sudo reboot"
echo ""
echo "5. After reboot, verify with:"
echo "     vulkaninfo --summary"
echo "     vulkaninfo | grep -i radeon"
echo ""
echo -e "${B_GREEN}You can now run:${NC} $REPO_ROOT/llama_manager.sh"
echo ""
