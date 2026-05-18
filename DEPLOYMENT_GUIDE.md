# GGUF-Gasket Repository Fixes - Deployment Guide

## Overview

This package contains comprehensive fixes for multiple modules in the gguf-gasket repository, properly integrated following the repository's module template structure.

## Issues Fixed

### 1. GPU Detection (detect.sh)
- **Issue**: Intel integrated GPU detected instead of AMD RX 570 discrete GPU
- **Fix**: Priority-based detection (discrete > integrated) with enhanced AMD patterns
- **New Feature**: Manual override via `~/ai_stack/gpu_override.txt`
- **New Feature**: Interactive GPU selection menu when multiple GPUs detected

### 2. AMD Driver Installation (drivers_gpu.sh)
- **Issue**: Missing Vulkan components (glslc, proper error handling)
- **Fix**: Comprehensive installation with verification and clear reboot instructions
- **New Feature**: Component-by-component verification
- **New Feature**: Detailed post-install instructions

### 3. Build Menu (menu_build.sh)
- **Issue**: No way to override GPU detection
- **Fix**: Now uses `select_gpu_with_override()` instead of `detect_gpu()`
- **Result**: Interactive selection dialog when building

### 4. mem0 Module (menu_mem0.sh)
- **Issue**: API incompatibility with mem0ai 2.0+, wrong embedder default
- **Fix**: API version fallback logic, Ollama embedder default
- **New Feature**: Works with both mem0 1.x and 2.x

### 5. SearXNG Module (menu_searxng.sh)
- **Issue**: Docker port mapping broken, no validation
- **Fix**: Correct port mapping (host:container), comprehensive validation
- **New Feature**: Port conflict detection, container recreation option

### 6. Download Module (menu_download.sh)
- **Issue**: HuggingFace URLs using /blob/ (downloads HTML not files)
- **Fix**: Changed to /resolve/, auto-correction for custom URLs
- **New Feature**: Standalone scripts (no function export needed)

## Files Included

```
detect_fixed_integrated.sh       → lib/detect.sh
drivers_gpu_fixed_integrated.sh  → lib/drivers_gpu.sh
menu_mem0_fixed.sh              → lib/menu_mem0.sh
menu_searxng_fixed.sh           → lib/menu_searxng.sh
menu_download_fixed.sh          → lib/menu_download.sh
deploy_all_fixes.sh             → Master deployment script
patch_menu_build.sh             → Patch for menu_build.sh
```

## Quick Start - Automated Deployment

### Step 1: Place Files in Repository
```bash
cd ~/gguf-gasket  # or wherever your repo is
cp /path/to/fixes/*.sh .
```

### Step 2: Run Master Deployment Script
```bash
chmod +x deploy_all_fixes.sh
./deploy_all_fixes.sh
```

This will:
- Find your repository automatically
- Create timestamped backups of all files
- Apply all fixes
- Show summary of changes

### Step 3: For RX 570 / AMD GPU Specific
```bash
# Force AMD detection (if auto-detect still wrong)
mkdir -p ~/ai_stack
echo "AMD" > ~/ai_stack/gpu_override.txt

# Run build menu
./llama_manager.sh
# Select: Build AI Engine
# Will detect AMD, install Vulkan drivers
```

### Step 4: After Driver Installation
```bash
# MUST reboot for drivers to activate
sudo reboot
```

### Step 5: Verify After Reboot
```bash
vulkaninfo --summary
vulkaninfo | grep -i radeon
glslc --version
```

### Step 6: Rebuild llama.cpp
```bash
./llama_manager.sh
# Select: Build AI Engine
# Should complete successfully with Vulkan support
```

## Manual Deployment (if automated script fails)

### Option 1: Copy Files Directly
```bash
cd ~/gguf-gasket

# Backup originals
mkdir -p backups
cp lib/detect.sh backups/
cp lib/drivers_gpu.sh backups/
cp lib/menu_mem0.sh backups/
cp lib/menu_searxng.sh backups/
cp lib/menu_download.sh backups/
cp lib/menu_build.sh backups/

# Copy fixed versions
cp detect_fixed_integrated.sh lib/detect.sh
cp drivers_gpu_fixed_integrated.sh lib/drivers_gpu.sh
cp menu_mem0_fixed.sh lib/menu_mem0.sh
cp menu_searxng_fixed.sh lib/menu_searxng.sh
cp menu_download_fixed.sh lib/menu_download.sh

# Patch menu_build.sh
chmod +x patch_menu_build.sh
./patch_menu_build.sh
```

### Option 2: Individual Module Updates

If you only need specific fixes:

**GPU Detection Only:**
```bash
cp detect_fixed_integrated.sh ~/gguf-gasket/lib/detect.sh
cp drivers_gpu_fixed_integrated.sh ~/gguf-gasket/lib/drivers_gpu.sh
./patch_menu_build.sh
```

**mem0 Only:**
```bash
cp menu_mem0_fixed.sh ~/gguf-gasket/lib/menu_mem0.sh
```

**SearXNG Only:**
```bash
cp menu_searxng_fixed.sh ~/gguf-gasket/lib/menu_searxng.sh
```

**Download Only:**
```bash
cp menu_download_fixed.sh ~/gguf-gasket/lib/menu_download.sh
```

## Verification Checklist

### GPU Detection
```bash
# Test detection
source ~/gguf-gasket/lib/globals.sh
source ~/gguf-gasket/lib/detect.sh
detect_gpu_detailed

# Should show:
# AMD:1
# INTEL:1
# AMD_GPU:...Radeon RX 570...
```

### AMD Drivers
```bash
# After installation and reboot
vulkaninfo --summary        # Should show GPU
glslc --version            # Should show version
ldconfig -p | grep vulkan  # Should show libraries
```

### mem0
```bash
# Test should pass all 4 steps
./llama_manager.sh
# Navigate to mem0 menu → Test Integration
```

### SearXNG
```bash
# Should be accessible
curl http://127.0.0.1:8888/
# JSON API should work
curl 'http://127.0.0.1:8888/search?q=test&format=json'
```

### Downloads
```bash
# Try a download, check file is GGUF not HTML
file ~/ai_stack/models/*.gguf
# Should say: "data" or "GGUF", NOT "HTML document"
```

## Manual GPU Override

If auto-detection still doesn't work correctly:

```bash
# Create override file
mkdir -p ~/ai_stack
echo "AMD" > ~/ai_stack/gpu_override.txt

# Or for other GPU types:
echo "NVIDIA" > ~/ai_stack/gpu_override.txt
echo "INTEL" > ~/ai_stack/gpu_override.txt
echo "CPU" > ~/ai_stack/gpu_override.txt

# To remove override (return to auto-detect):
rm ~/ai_stack/gpu_override.txt
```

## Rollback Instructions

If something goes wrong:

```bash
cd ~/gguf-gasket

# Find your backup directory
ls -la backups_*

# Restore from backup (example timestamp)
BACKUP_DIR=backups_20241225_120000

cp $BACKUP_DIR/detect.sh lib/
cp $BACKUP_DIR/drivers_gpu.sh lib/
cp $BACKUP_DIR/menu_build.sh lib/
cp $BACKUP_DIR/menu_mem0.sh lib/
cp $BACKUP_DIR/menu_searxng.sh lib/
cp $BACKUP_DIR/menu_download.sh lib/
```

## Troubleshooting

### Issue: GPU Still Detected as Intel

**Solution 1: Use Manual Override**
```bash
echo "AMD" > ~/ai_stack/gpu_override.txt
```

**Solution 2: Check lspci Output**
```bash
lspci | grep -i "vga\|3d\|display"
# Share output for diagnosis
```

### Issue: Vulkan Build Fails

**Missing glslc:**
```bash
sudo apt-get install shaderc
# If not available, see drivers_gpu.sh for build-from-source instructions
```

**Missing Vulkan libraries:**
```bash
sudo apt-get install libvulkan1 libvulkan-dev vulkan-tools mesa-vulkan-drivers
```

**Didn't reboot after driver install:**
```bash
sudo reboot  # MUST do this
```

### Issue: mem0 Test Fails

**Step 3/4 fails (connection error):**
- Check embedder in config: should be "ollama"
- Or switch embedder: Configure → option 2 → select Ollama

**Step 4/4 fails (API error):**
- Fixed version has fallback logic
- If still fails, share exact error message

### Issue: SearXNG Not Accessible

**Container not running:**
```bash
docker ps -a | grep searxng
docker logs llama-searxng
```

**Port conflict:**
```bash
ss -tuln | grep 8888
# If port in use, change in Configure menu
```

### Issue: Downloads Still Failing

**Test URL format:**
```bash
# Bad (blob):
https://huggingface.co/.../blob/main/file.gguf

# Good (resolve):
https://huggingface.co/.../resolve/main/file.gguf
```

**Check downloaded file:**
```bash
file ~/ai_stack/models/yourfile.gguf
# Should NOT say "HTML document"
```

## Repository Structure Compliance

All fixes follow the repository's module template:
- ✅ Proper MENU_* variables for auto-discovery
- ✅ Consistent function naming conventions  
- ✅ Use of globals.sh color/logging functions
- ✅ Proper error handling with user feedback
- ✅ Compatible with existing module system

## Support

If issues persist after applying fixes:

1. Check backups are created: `ls -la ~/gguf-gasket/backups_*`
2. Run diagnostics: `./gpu_diagnostic.sh > output.txt`
3. Share relevant logs from `~/ai_stack/*.log`
4. Include output of: `lspci | grep -i vga`

## License

These fixes maintain compatibility with the original gguf-gasket repository license.

## Credits

Fixes address real-world issues reported by users:
- ThinkCentre M91p with RX 570 misdetection
- mem0ai 2.0 API breaking changes
- SearXNG Docker port mapping bugs
- HuggingFace URL format changes
