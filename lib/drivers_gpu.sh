#!/bin/bash
# lib/drivers_gpu.sh — NVIDIA and AMD GPU driver installers
# Requires: globals.sh

# ================================================================
#  NVIDIA DRIVER INSTALLATION
# ================================================================
install_Nvidia_gpu_drivers() {
    STEP "Installing NVIDIA CUDA toolkit…"
    sudo apt-get install -y ubuntu-drivers-common nvidia-cuda-toolkit &>> "$LOG_FILE" || true
}

# ================================================================
#  AMD DRIVER INSTALLATION - ENHANCED
# ================================================================
install_AMD_gpu_drivers() {
    STEP "Installing AMD / Vulkan dependencies…"
    
    # Core Vulkan packages (fixed typos from original)
    local core_pkgs=(
        libvulkan1
        libvulkan-dev
        vulkan-tools
        vulkan-validationlayers
        vulkan-validationlayers-dev
        mesa-vulkan-drivers
        libdrm-dev
        libdrm-amdgpu1
    )
    
    # Optional packages (may not be available on all Ubuntu versions)
    local optional_pkgs=(
        mesa-vulkan-drivers:i386
        libvulkan1:i386
        libvulkan-dev:i386
        mesa-utils
        spirv-tools
        spirv-headers
        glslang-tools
        glslang-dev
        shaderc
        libshaderc-dev
        libnuma-dev
        xserver-xorg-video-amdgpu
        firmware-amd-graphics
    )
    
    # Install core packages first
    INFO "Installing core Vulkan packages..."
    if ! sudo apt-get install -y "${core_pkgs[@]}" &>> "$LOG_FILE"; then
        WARN "Some core packages failed to install. Continuing..."
    fi
    
    # Enable i386 architecture for 32-bit support
    sudo dpkg --add-architecture i386 2>/dev/null || true
    sudo apt-get update -qq &>> "$LOG_FILE" || true
    
    # Install optional packages (don't fail if unavailable)
    INFO "Installing optional packages..."
    for pkg in "${optional_pkgs[@]}"; do
        sudo apt-get install -y "$pkg" &>> "$LOG_FILE" 2>&1 || true
    done
    
    # Check for glslc specifically (required for llama.cpp Vulkan build)
    if ! command -v glslc &>/dev/null; then
        WARN "glslc shader compiler not found"
        INFO "Attempting to install shaderc..."
        
        if sudo apt-get install -y shaderc &>> "$LOG_FILE" 2>&1; then
            OK "shaderc installed"
        else
            WARN "Could not install shaderc from repos"
            WARN "You may need to build glslc from source for Vulkan support"
            INFO "See: https://github.com/google/shaderc"
        fi
    fi
    
    # Add user to video and render groups for GPU access
    INFO "Adding user to video and render groups..."
    sudo usermod -a -G video,render "$USER" &>> "$LOG_FILE" || true
    
    # Verify installation
    echo ""
    STEP "Verifying Vulkan installation..."
    
    local verification_failed=0
    
    # Check Vulkan loader
    if ldconfig -p 2>/dev/null | grep -q "libvulkan.so"; then
        OK "Vulkan loader: installed"
    else
        ERR "Vulkan loader: MISSING"
        verification_failed=1
    fi
    
    # Check vulkaninfo tool
    if command -v vulkaninfo &>/dev/null; then
        OK "vulkaninfo: installed"
        
        # Try to run vulkaninfo
        if vulkaninfo --summary &>> "$LOG_FILE" 2>&1; then
            OK "vulkaninfo runs successfully"
            
            # Show brief summary
            echo ""
            INFO "Vulkan device info:"
            vulkaninfo --summary 2>/dev/null | grep -A 5 "GPU" | head -10 || true
        else
            WARN "vulkaninfo installed but failed to run"
            WARN "This is normal if you haven't rebooted yet"
        fi
    else
        ERR "vulkaninfo: MISSING"
        verification_failed=1
    fi
    
    # Check glslc compiler
    if command -v glslc &>/dev/null; then
        OK "glslc compiler: installed"
        glslc --version 2>&1 | head -1 | sed 's/^/    /' || true
    else
        ERR "glslc compiler: MISSING (required for Vulkan builds)"
        verification_failed=1
    fi
    
    # Check Mesa RADV driver
    if ldconfig -p 2>/dev/null | grep -q "libvulkan_radeon.so"; then
        OK "Mesa RADV driver: installed"
    else
        WARN "Mesa RADV driver: not detected"
        WARN "This may appear after reboot"
    fi
    
    # Check for Vulkan ICD
    if [ -d /usr/share/vulkan/icd.d/ ]; then
        local icd_count
        icd_count=$(ls -1 /usr/share/vulkan/icd.d/*.json 2>/dev/null | wc -l)
        if [ "$icd_count" -gt 0 ]; then
            OK "Vulkan ICD files: $icd_count found"
        else
            WARN "No Vulkan ICD files found in /usr/share/vulkan/icd.d/"
        fi
    fi
    
    echo ""
    
    if [ $verification_failed -eq 0 ]; then
        OK "AMD/Vulkan driver installation complete"
    else
        WARN "Some components are missing"
    fi
    
    echo ""
    echo -e "${B_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${B_YELLOW}IMPORTANT: Reboot or re-login required${NC}"
    echo -e "${B_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Changes that need activation:"
    echo "  • Video/render group membership"
    echo "  • Vulkan ICD driver registration"
    echo "  • Kernel module loading"
    echo ""
    echo "  Either:"
    echo "  1) Reboot now:    sudo reboot"
    echo "  2) Re-login:      logout and login again"
    echo "  3) New group:     newgrp video (temporary for this session)"
    echo ""
    echo "  After reboot, verify with:"
    echo "    vulkaninfo --summary"
    echo "    vulkaninfo | grep -i radeon"
    echo ""
    
    sleep 5
}
