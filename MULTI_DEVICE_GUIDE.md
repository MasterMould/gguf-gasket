# Multi-Device Deployment Guide for GGUF-Gasket

## Your Scenario: Multiple Devices with Different GPUs

You're managing gguf-gasket across various devices:
- Device 1: ThinkCentre M91p → AMD Radeon RX 570
- Device 2: System with Intel Arc A770
- Device 3+: Other machines with different GPUs

This guide provides solutions for seamless multi-device management.

---

## Problem: Manual Override on Every Device

Without device profiles, you'd need to:
1. Remember which GPU each device has
2. Manually set override on each device
3. Risk builds failing if you forget

---

## Solution: Device Profile System

### Quick Start - Setup Each Device Once

**On Device 1 (AMD RX 570):**
```bash
./device_profile_manager.sh quick
# When prompted:
# - Profile name: thinkcentre_m91p
# - GPU type: 2 (AMD)
```

**On Device 2 (Intel Arc A770):**
```bash
./device_profile_manager.sh quick
# When prompted:
# - Profile name: intel_arc_workstation
# - GPU type: 3 (INTEL)
```

**Result:** Each device remembers its GPU type automatically.

---

## Manual Override System (Immediate Fix)

### For Your Current Intel Arc A770 Issue

**Right now, do this:**
```bash
mkdir -p ~/ai_stack
echo "INTEL" > ~/ai_stack/gpu_override.txt
```

**Then rebuild from menu.**

### Override Reference

```bash
# Force specific GPU type
echo "AMD" > ~/ai_stack/gpu_override.txt      # For RX 570
echo "INTEL" > ~/ai_stack/gpu_override.txt    # For Arc A770
echo "NVIDIA" > ~/ai_stack/gpu_override.txt   # For NVIDIA cards
echo "CPU" > ~/ai_stack/gpu_override.txt      # No GPU

# Clear override (return to auto-detect)
rm ~/ai_stack/gpu_override.txt
```

---

## Device Profile Manager - Complete Guide

### Installation

```bash
# Copy to repository
cp device_profile_manager.sh ~/gguf-gasket/
chmod +x ~/gguf-gasket/device_profile_manager.sh

# Or place in PATH
sudo cp device_profile_manager.sh /usr/local/bin/gpu-profile
sudo chmod +x /usr/local/bin/gpu-profile
```

### Usage

#### Command Line Mode

```bash
# Quick setup wizard (recommended for first time)
./device_profile_manager.sh quick

# Create profile manually
./device_profile_manager.sh create thinkcentre AMD
./device_profile_manager.sh create workstation INTEL

# Activate profile
./device_profile_manager.sh activate thinkcentre

# List all profiles
./device_profile_manager.sh list

# Interactive menu
./device_profile_manager.sh menu
```

#### Interactive Menu Mode

```bash
./device_profile_manager.sh
```

Shows:
```
========================================
   DEVICE PROFILE MANAGER
========================================

Current Device: workstation-01
Current GPU:    INTEL

Detected Hardware:
  0a:00.0 VGA compatible controller: Intel Corporation DG2 [Arc A770]

Available Device Profiles:

  1) thinkcentre_m91p - GPU: AMD (active)
     Hostname: thinkcentre

  2) intel_arc_workstation - GPU: INTEL
     Hostname: workstation-01

Actions:
  1) Create new profile for this device
  2) Activate existing profile
  3) Delete profile
  4) Return to auto-detect
  5) Back
```

---

## Deployment Strategy for Multiple Devices

### Strategy 1: Shared Git Repository

```bash
# On your main development machine
cd ~/gguf-gasket
git init
git add .
git commit -m "Initial setup with fixes"
git remote add origin <your-repo-url>
git push

# On each device
git clone <your-repo-url> ~/gguf-gasket
cd ~/gguf-gasket
./device_profile_manager.sh quick
```

Device profiles are stored in `~/ai_stack/device_profiles/` (not in git), so each device maintains its own configuration.

### Strategy 2: Rsync/SCP

```bash
# From main machine to others
rsync -av ~/gguf-gasket/ user@device2:~/gguf-gasket/

# On each device after sync
cd ~/gguf-gasket
./device_profile_manager.sh quick
```

### Strategy 3: Ansible/Automation

```yaml
# ansible playbook example
- name: Deploy gguf-gasket
  hosts: all
  tasks:
    - name: Copy repository
      synchronize:
        src: ~/gguf-gasket/
        dest: ~/gguf-gasket/
    
    - name: Set GPU type for AMD devices
      shell: echo "AMD" > ~/ai_stack/gpu_override.txt
      when: inventory_hostname in groups['amd_gpus']
    
    - name: Set GPU type for Intel devices
      shell: echo "INTEL" > ~/ai_stack/gpu_override.txt
      when: inventory_hostname in groups['intel_gpus']
```

---

## Updated Detect.sh with Multi-Device Support

The new `detect_multidevice.sh` includes:

1. **Device Profile Priority:**
   - Checks for hostname-matched profile first
   - Falls back to manual override file
   - Finally uses auto-detection

2. **Intel Arc A770 Fix:**
   - Fixed pattern matching for Intel Arc/DG GPUs
   - Line-by-line checking (not just grep on entire output)
   - Properly excludes AMD when found

3. **Profile Integration:**
   - Profiles stored in `~/ai_stack/device_profiles/`
   - Each profile contains: GPU_TYPE, HOSTNAME, CREATED timestamp
   - Automatic profile suggestion on first run

---

## Recommended Workflow

### Initial Setup (Once per Device)

1. **Deploy fixes to device:**
   ```bash
   cd ~/gguf-gasket
   ./deploy_all_fixes.sh
   ```

2. **Create device profile:**
   ```bash
   ./device_profile_manager.sh quick
   ```

3. **Build llama.cpp:**
   ```bash
   ./llama_manager.sh
   # Select: Build AI Engine
   # Will use saved profile automatically
   ```

### Subsequent Builds

Just run the build menu - the device profile is remembered:
```bash
./llama_manager.sh
# Automatically uses correct GPU for this device
```

### Moving Between Devices

The repository is portable - just the profiles stay per-device:
```bash
# On device 1 (AMD)
cd ~/gguf-gasket && ./llama_manager.sh
# Uses AMD profile

# On device 2 (Intel)
cd ~/gguf-gasket && ./llama_manager.sh  
# Uses Intel profile
```

---

## Troubleshooting Multi-Device Issues

### Issue: Profile Not Found After Moving Repository

**Cause:** Profiles are stored in `~/ai_stack/device_profiles/`, not in the repository itself.

**Solution:**
```bash
# On the new device
./device_profile_manager.sh quick
```

### Issue: Wrong GPU Selected on New Device

**Cause:** Override file or old profile exists.

**Solution:**
```bash
# Clear override
rm ~/ai_stack/gpu_override.txt

# Delete old profiles
rm -rf ~/ai_stack/device_profiles/

# Create new profile
./device_profile_manager.sh quick
```

### Issue: Auto-Detection Still Wrong

**Cause:** Pattern matching bug in detect_gpu().

**Temporary Solution:**
```bash
# Use manual override
echo "CORRECT_TYPE" > ~/ai_stack/gpu_override.txt
```

**Permanent Solution:**
```bash
# Create device profile
./device_profile_manager.sh create $(hostname) CORRECT_TYPE
```

### Issue: Need Different GPU on Same Device

**Use Case:** Testing different configurations.

**Solution:**
```bash
# Temporarily change
echo "CPU" > ~/ai_stack/gpu_override.txt

# Or create multiple profiles
./device_profile_manager.sh create $(hostname)_cpu CPU
./device_profile_manager.sh create $(hostname)_gpu INTEL

# Switch between them
./device_profile_manager.sh activate $(hostname)_cpu
```

---

## File Locations Reference

```
~/gguf-gasket/                          # Repository (portable)
├── lib/
│   ├── detect.sh                       # Updated with profile support
│   ├── drivers_gpu.sh                  # Fixed AMD/Intel drivers
│   └── menu_*.sh                       # Fixed modules
├── device_profile_manager.sh           # Profile management tool
└── deploy_all_fixes.sh                 # Master installer

~/ai_stack/                             # Per-device data (not portable)
├── gpu_override.txt                    # Manual override (if set)
├── device_profiles/                    # Device profiles directory
│   ├── thinkcentre_m91p.profile       # AMD device profile
│   └── intel_workstation.profile       # Intel device profile
├── llama.cpp/                          # Built binary
└── models/                             # Downloaded models
```

---

## Quick Reference: GPU Type Codes

| Code | Hardware | Use For |
|------|----------|---------|
| `AMD` | AMD Radeon cards (RX 570, etc.) | ThinkCentre M91p |
| `INTEL` | Intel GPUs (Arc A770, UHD, etc.) | Your current device |
| `NVIDIA` | NVIDIA cards (RTX, GTX, etc.) | NVIDIA systems |
| `CPU` | No GPU acceleration | Testing or low-power |

---

## Integration with Existing Menu

The fixed detect.sh integrates seamlessly:

```bash
# In menu_build.sh (already patched)
current_gpu=$(select_gpu_with_override)

# This now:
# 1. Checks device profiles first
# 2. Falls back to manual override
# 3. Uses auto-detection last
# 4. Offers to create profile if ambiguous
```

---

## Your Immediate Action Items

### For Intel Arc A770 (Current Device)

```bash
# Option 1: Quick fix (30 seconds)
echo "INTEL" > ~/ai_stack/gpu_override.txt
./llama_manager.sh  # Build again

# Option 2: Create profile (1 minute)
./device_profile_manager.sh quick
# Select: INTEL
./llama_manager.sh  # Build
```

### For ThinkCentre M91p with RX 570

```bash
# On that device
echo "AMD" > ~/ai_stack/gpu_override.txt
# Or
./device_profile_manager.sh quick
# Select: AMD
```

### Deploy Fixed detect.sh

```bash
# Use the multi-device version
cp detect_multidevice.sh ~/gguf-gasket/lib/detect.sh
```

---

## Summary

**Before (broken):**
- Auto-detect fails on Arc A770 → returns CPU
- No memory of device configuration
- Manual override needed each time
- Different devices require manual tracking

**After (fixed):**
- ✅ Intel Arc A770 properly detected
- ✅ Device profiles remember GPU type
- ✅ One-time setup per device
- ✅ Portable repository with per-device configs
- ✅ Manual override still available for testing
- ✅ Interactive selection for ambiguous cases

**Result:** Seamless multi-device workflow with automatic GPU selection.
