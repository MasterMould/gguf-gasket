#!/bin/bash
# lib/drivers_gpu.sh — NVIDIA and AMD GPU driver installers
# Requires: globals.sh

install_Nvidia_gpu_drivers() {
    STEP "Installing NVIDIA CUDA toolkit…"
    sudo apt-get install -y ubuntu-drivers-common nvidia-cuda-toolkit &>> "$LOG_FILE" || true
}

install_AMD_gpu_drivers() {
    STEP "Installing AMD / Vulkan dependencies…"
    sudo apt-get install -y \
        libnuma-dev spirv-headers libvulkan libvulkan1 \
        linux-modules-extra-$(uname -r) libvulkan-dev wget \
        glsc glslang-dev vulkan-tools vulkan-headers libvulk \
        mesa-vulkan-drivers mesa-vulkan-drivers:i386 mesa-utils \
        glslang-tools gnupg2 &>> "$LOG_FILE" || true
    sudo dpkg --add-architecture i386 2>/dev/null || true
    sudo apt-get update -qq &>> "$LOG_FILE" || true
    sudo apt-get install -y libvulkan-dev:i386 &>> "$LOG_FILE" || true
    vulkaninfo --summary
    sleep 3
}
