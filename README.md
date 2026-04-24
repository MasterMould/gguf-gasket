# 🦙 gguf-gasket — `llama_manager.sh`

> A single-script command centre for building, managing, and serving local LLMs via [llama.cpp](https://github.com/ggerganov/llama.cpp) on Ubuntu / Debian x86\_64.
> Auto-detects your GPU, installs every dependency it needs, compiles an optimised binary, and exposes a full HTTPS API — all from an interactive terminal menu.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Menu Reference](#menu-reference)
  - [1 — Build AI Engine](#1--build-ai-engine)
  - [2 — Download Models](#2--download-models)
  - [3 — Interactive Chat](#3--interactive-chat)
  - [4 — Start / Stop Web Server](#4--start--stop-web-server)
  - [5 — Settings](#5--settings)
  - [6 — Deep Repair](#6--deep-repair)
  - [7 — View Forensic Logs](#7--view-forensic-logs)
  - [8 — View Saved API Keys](#8--view-saved-api-keys)
- [GPU Support Matrix](#gpu-support-matrix)
- [File Layout](#file-layout)
- [Settings Persistence](#settings-persistence)
- [Web Server & API Usage](#web-server--api-usage)
- [Path Installation](#path-installation)
- [Troubleshooting](#troubleshooting)
- [Security Notes](#security-notes)
- [License](#license)

---

## Features

| Category | Details |
|---|---|
| **GPU auto-detection** | NVIDIA (CUDA), AMD (Vulkan), Intel Arc (SYCL/oneAPI), CPU fallback |
| **Zero-friction build** | Clones llama.cpp, installs correct drivers, compiles with optimal CMake flags |
| **Auto-dependency install** | Detects missing tools, offers to `apt-get install` them, re-verifies after install |
| **System-wide PATH** | Symlinks `llama-cli` and `llama-server` into `~/.local/bin` after every build |
| **Background downloads** | Model downloads open in a separate terminal window — the menu stays live |
| **HTTPS API server** | Self-signed TLS, configurable bind address, port, and API key mode |
| **Interactive chat** | Terminal conversation mode with hard context-limit enforcement |
| **Persistent settings** | Context size, network bind, port, and API key mode survive restarts |
| **Deep Repair mode** | Fixes broken APT state and reinstalls GPU drivers from scratch |
| **Log rotation** | Forensic log capped at 500 lines; API key audit log kept at `chmod 600` |

---

## Requirements

| Requirement | Notes |
|---|---|
| **OS** | Ubuntu 22.04 / 24.04 (Noble) or compatible Debian derivative |
| **Architecture** | x86\_64 only |
| **Shell** | Bash 5+ (`declare -g`, `mapfile`, associative arrays) |
| **sudo** | Required for driver and package installation |
| **Disk** | ~3 GB for llama.cpp build + ~2–5 GB per model |
| **RAM** | 8 GB minimum; 16 GB recommended for 7–8B models |

The script will offer to install any missing tools automatically when you first run **Build AI Engine**.

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/MasterMould/gguf-gasket.git
cd gguf-gasket

# Make the script executable
chmod +x llama_manager.sh

# Launch
./llama_manager.sh
```

On first run:

1. Select **1) Build AI Engine** — the script detects your GPU, installs drivers and build tools, clones llama.cpp, and compiles an optimised binary.
2. Select **2) Download Models** — pick a preset model or paste a custom GGUF URL.
3. Select **3) Interactive Chat** to talk to the model in your terminal, or **4) Start Web Server** to expose an OpenAI-compatible HTTPS API.

---

## Menu Reference

```
