#!/bin/bash
# Patch menu_build.sh to use enhanced GPU detection with override
# This script modifies the build_engine function to call select_gpu_with_override

set -e

B_GREEN='\033[1;32m'
B_RED='\033[1;31m'
B_YELLOW='\033[1;33m'
B_CYAN='\033[1;36m'
NC='\033[0m'

echo -e "${B_CYAN}================================${NC}"
echo -e "${B_CYAN}PATCH menu_build.sh${NC}"
echo -e "${B_CYAN}================================${NC}"
echo ""

# Find menu_build.sh
BUILD_FILE=""
for path in \
    ~/gguf-gasket/lib/menu_build.sh \
    ~/ai_stack/gguf-gasket/lib/menu_build.sh \
    ./lib/menu_build.sh \
    ../lib/menu_build.sh; do
    if [ -f "$path" ]; then
        BUILD_FILE="$path"
        break
    fi
done

if [ -z "$BUILD_FILE" ]; then
    echo -e "${B_RED}✗ Could not find menu_build.sh${NC}"
    echo "  Please specify the path:"
    read -r -p "  Path to menu_build.sh: " BUILD_FILE
    if [ ! -f "$BUILD_FILE" ]; then
        echo -e "${B_RED}✗ File not found: $BUILD_FILE${NC}"
        exit 1
    fi
fi

echo -e "Target file: ${B_YELLOW}$BUILD_FILE${NC}"
echo ""

# Backup original
BACKUP_FILE="${BUILD_FILE}.backup.$(date +%s)"
cp "$BUILD_FILE" "$BACKUP_FILE"
echo -e "${B_GREEN}✓ Created backup: $BACKUP_FILE${NC}"

# Check if already patched
if grep -q "select_gpu_with_override" "$BUILD_FILE"; then
    echo -e "${B_YELLOW}⚠ File already appears to be patched${NC}"
    read -r -p "  Proceed anyway? (y/n): " proceed
    if [[ "${proceed,,}" != "y" ]]; then
        echo "Cancelled"
        exit 0
    fi
fi

# Perform the replacement
# Find: current_gpu=$(detect_gpu)
# Replace with: current_gpu=$(select_gpu_with_override)

if sed -i 's/current_gpu=$(detect_gpu)/current_gpu=$(select_gpu_with_override)/g' "$BUILD_FILE"; then
    echo -e "${B_GREEN}✓ Successfully patched menu_build.sh${NC}"
    
    # Verify the change
    if grep -q "select_gpu_with_override" "$BUILD_FILE"; then
        echo -e "${B_GREEN}✓ Verification passed${NC}"
    else
        echo -e "${B_RED}✗ Verification failed - change not found${NC}"
        echo -e "${B_YELLOW}Restoring backup...${NC}"
        mv "$BACKUP_FILE" "$BUILD_FILE"
        exit 1
    fi
else
    echo -e "${B_RED}✗ Patch failed${NC}"
    echo -e "${B_YELLOW}Restoring backup...${NC}"
    mv "$BACKUP_FILE" "$BUILD_FILE"
    exit 1
fi

echo ""
echo -e "${B_CYAN}Summary:${NC}"
echo "  • menu_build.sh now uses select_gpu_with_override()"
echo "  • This enables interactive GPU selection"
echo "  • Supports manual override via ~/ai_stack/gpu_override.txt"
echo "  • Priority system: discrete GPUs preferred over integrated"
echo ""
echo -e "${B_GREEN}Next steps:${NC}"
echo "1. Ensure detect.sh is also updated (with select_gpu_with_override function)"
echo "2. Ensure drivers_gpu.sh is updated (with enhanced AMD driver installer)"
echo "3. Run the build menu - you'll see GPU selection dialog"
echo ""
