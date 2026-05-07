#!/bin/bash

# --- Color Definitions ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}Intel Arc A770 'Unstoppable' Setup Utility for Ubuntu 24.04${NC}"

show_menu() {
    echo -e "\n${GREEN}Select an option:${NC}"
    echo "1) [Recommended] Full Driver & Compute Stack Install (OpenCL/LevelZero)"
    echo "2) Add User to Render Group (Fixes Permissions)"
    echo "3) Install Monitoring Tools (intel_gpu_top)"
    echo "4) Verify Hardware & Driver Status"
    echo "5) Enable 'Xe' Driver (Experimental Kernel 6.8+)"
    echo "q) Quit"
}

install_stack() {
    echo -e "${CYAN}Installing Intel Graphics Repositories and Compute Stack...${NC}"
    # 1. Install Key and Repo
    wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | sudo gpg --yes --dearmor --output /usr/share/keyrings/intel-graphics.gpg
    echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble unified" | sudo tee /etc/apt/sources.list.d/intel-gpu-noble.list
    
    # 2. Update and Install Compute/Media Packages
    sudo apt update
    sudo apt install -y libze-intel-gpu1 libze1 intel-opencl-icd clinfo intel-gsc intel-media-va-driver-non-free libmfx-gen1 libvpl2 libva-glx2 va-driver-all vainfo
    echo -e "${GREEN}Driver stack installed successfully!${NC}"
}

fix_permissions() {
    echo -e "${CYAN}Applying hardware access permissions...${NC}"
    sudo gpasswd -a ${USER} render
    sudo gpasswd -a ${USER} video
    echo -e "${GREEN}Permissions updated. You MUST log out and back in for this to take effect.${NC}"
}

while true; do
    show_menu
    read -p "Choice: " choice
    case $choice in
        1) install_stack ;;
        2) fix_permissions ;;
        3) sudo apt install -y intel-gpu-tools && echo -e "${GREEN}Run 'sudo intel_gpu_top' to monitor your card.${NC}" ;;
        4) 
            echo -e "\n${CYAN}--- Verification Report ---${NC}"
            lspci -k | grep -EA3 'VGA|3D|Display'
            clinfo | grep "Device Name" | head -n 1
            groups | grep -q "render" && echo "Render Group: OK" || echo "Render Group: MISSING (Run option 2)"
            ;;
        5)
            echo -e "${RED}Warning: This modifies GRUB and requires a reboot.${NC}"
            sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="i915.force_probe=!56a0 xe.force_probe=56a0 /' /etc/default/grub
            sudo update-grub
            echo -e "${GREEN}Kernel parameters updated. Reboot to use the 'Xe' driver.${NC}"
            ;;
        q) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
done