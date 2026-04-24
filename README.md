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
======================================================
           🦙 LLAMA COMMAND CENTER (v8.2) 🦙
           * Universal GPU & Repair Mode *
======================================================
[ SYSTEM STATUS ]
  Detected GPU:  NVIDIA
  Context size:  8192 tokens
  Network bind:  127.0.0.1:8080
  AI Engine:     ✓ INSTALLED
  Web Server:    ✗ STOPPED
  Models:        2 downloaded
------------------------------------------------------
1) Build AI Engine     (Auto-Detect: NVIDIA)
2) Download Models     (Includes Custom URL option)
3) Interactive Chat
4) Start / Stop Web Server
5) ⚙  Settings          (Context, Port, Network)
6) DEEP REPAIR         (Fix Drivers/Conflicts)
7) View Forensic Logs
8) View Saved API Keys
9) Exit
```

### 1 — Build AI Engine

Performs a full from-scratch or incremental build of llama.cpp:

1. Runs `check_deps` — detects missing tools from a command→package map and offers to `apt-get install` them automatically. Re-verifies after install; aborts if anything is still missing.
2. Calls `detect_gpu` to determine the backend (NVIDIA / AMD / INTEL / CPU).
3. Installs the correct GPU driver stack for your hardware (see [GPU Support Matrix](#gpu-support-matrix)).
4. Clones `https://github.com/ggerganov/llama.cpp` into `~/ai_stack/llama.cpp` (or runs `git pull` if already present). Asks before wiping an existing build directory.
5. Runs `cmake` with backend-specific flags (`-DGGML_CUDA=ON`, `-DGGML_VULKAN=ON`, `-DGGML_SYCL=ON`, or CPU default) plus `-DGGML_CURL=ON` and `-DGGML_SERVER_SSL=ON`.
6. Builds in Release mode using all available CPU cores (`-j$(nproc)`).
7. On success, symlinks both binaries into `~/.local/bin` and patches your shell profiles (see [Path Installation](#path-installation)).

**NVIDIA note:** CUDA architecture is auto-detected via `nvidia-smi`. Falls back to `all-major` if detection fails.

**Intel note:** Requires Intel oneAPI SYCL compiler (`icx`). The installer adds both the Intel GPU compute-runtime repo and the oneAPI APT repo, handles package name variations across repo versions, and patches `~/.bashrc`/`~/.zshrc` to source `setvars.sh` at login.

---

### 2 — Download Models

Opens a non-blocking download menu. Each download spawns a **new terminal window** (using `gnome-terminal`, `xterm`, `konsole`, or the system default) so the main menu remains fully interactive while large files transfer.

If no GUI terminal emulator is found, the download falls back to a silent background process tracked in `~/ai_stack/.downloads/`.

**Preset models:**

| # | Model | Size | Source |
|---|---|---|---|
| 1 | Meta-Llama-3-8B-Instruct Q4\_K\_M | ~4.9 GB | NousResearch / HuggingFace |
| 2 | Mistral-7B-Instruct-v0.2 Q4\_K\_M | ~4.1 GB | TheBloke / HuggingFace |
| 3 | Phi-3-mini-4k-instruct Q4\_K\_M | ~2.2 GB | bartowski / HuggingFace |
| 4 | Custom URL | — | Any direct `.gguf` link |

Download status (QUEUED / DOWNLOADING / COMPLETE / FAILED) is shown at the top of the download menu on every refresh. Option 5 clears completed and failed entries.

All models are saved to `~/ai_stack/models/`.

---

### 3 — Interactive Chat

Launches `llama-cli` in conversation mode (`-cnv`) against a model you select from the ones present in `~/ai_stack/models/`.

Before launch you choose GPU layer offload:

| Option | Layers | When to use |
|---|---|---|
| 1 | 0 | CPU-only, no VRAM |
| 2 | 16 | Low VRAM (≈4 GB) |
| 3 | 32 | Mid VRAM (≈8 GB) |
| 4 | 99 | Full GPU (default if GPU detected) |
| 5 | Custom | Manual entry |

**Context limit enforcement:** `--no-context-shift` is passed to `llama-cli`. When the context window fills the process exits cleanly rather than silently discarding old messages. The exit is caught and a box is displayed indicating the current context size and pointing to **Settings → Context Size** to increase it.

Type `/bye` or press `Ctrl+C` to exit chat.

---

### 4 — Start / Stop Web Server

Starts `llama-server` as a background daemon with full HTTPS and API key authentication.

**On start:**
- Generates a self-signed TLS certificate (`server.crt` / `server.key`) if one does not exist.
- Resolves the API key from the current `api_key_mode` setting.
- Displays a confirmation box with the exact URL, API key, context size, and bind address.
- Waits up to 4 seconds for the server to log `HTTP server listening`; warns if startup is unconfirmed.
- Writes connection info to `/tmp/llama_server.info` so the main menu status bar shows it on every refresh.
- Appends an audit entry (timestamp, PID, model, key) to `~/llama_api_keys.log` (`chmod 600`).

**On stop (selecting option 4 while server is running):**
- Displays the live URL and API key again for reference.
- Kills the process and removes the PID and info files.

**Example curl test:**
```bash
curl -sk https://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer localtest" \
  -H "Content-Type: application/json" \
  -d '{"model":"any","messages":[{"role":"user","content":"Hello"}]}'
```
*(Replace `localtest` with your actual key if using random or custom mode.)*

---

### 5 — Settings

All settings are saved to `~/ai_stack/settings.env` and loaded via `source` at startup and before every chat or server operation.

| Setting | Default | Options |
|---|---|---|
| **Context Size** | 8192 tokens | 1024 / 2048 / 4096 / 8192 / 16384 / 32768 / manual entry (min 512) |
| **Network Binding** | `127.0.0.1` | `127.0.0.1` (localhost) / `0.0.0.0` (all interfaces) / custom IP |
| **Server Port** | 8080 | 8080 / 8443 / 9000 / custom (1024–65535) |
| **API Key Mode** | `random` | `random` (new 24-char hex key per start) / `localtest` (fixed) / `custom:<value>` |

Changes take effect immediately for the current session and persist across restarts.

---

### 6 — Deep Repair

A recovery tool for broken GPU driver installations and corrupted APT state. **Requires confirmation (`yes`) before proceeding and warns that display managers may be affected.**

What it does, per GPU:

- **All:** Runs `dpkg --configure -a` and `apt-get --fix-broken install` first.
- **NVIDIA:** Purges all `^nvidia-.*` and `^libnvidia-.*` packages (requires typing `I UNDERSTAND`), then reinstalls via `ubuntu-drivers autoinstall`.
- **AMD:** Reinstalls Vulkan libraries and matching kernel headers/modules.
- **INTEL:** Re-runs the full Intel GPU + oneAPI installer.
- **CPU:** No-op for GPU drivers.

Offers to reboot immediately on completion. **Strongly recommended to reboot after use.**

---

### 7 — View Forensic Logs

Displays the last 50 lines of `~/llama_forensics.log`. The log captures all build output, driver install output, cmake output, and error messages. It is automatically rotated to keep a maximum of 500 lines.

---

### 8 — View Saved API Keys

Displays the contents of `~/llama_api_keys.log` — a timestamped audit trail of every server start, recording PID, model, GPU layers, context size, bind address, URL, and API key.

This file is created with `chmod 600` (readable only by your user).

---

## GPU Support Matrix

| GPU | Backend | CMake flag | Driver installer |
|---|---|---|---|
| NVIDIA (any) | CUDA | `-DGGML_CUDA=ON` | `ubuntu-drivers autoinstall` + `nvidia-cuda-toolkit` |
| AMD Radeon | Vulkan | `-DGGML_VULKAN=ON -DGGML_VULKAN_FLASH_ATTN=ON` | `libvulkan-dev`, `vulkan-tools`, i386 multiarch |
| Intel Arc / UHD / Iris | SYCL | `-DGGML_SYCL=ON` | Intel GPU repo + level-zero + oneAPI `icx` compiler |
| No supported GPU | CPU | *(none)* | *(none)* |

CUDA architecture is auto-detected from `nvidia-smi` and passed as `-DCMAKE_CUDA_ARCHITECTURES=<arch>`; falls back to `all-major` if detection fails.

---

## File Layout

```
~/ai_stack/
├── llama.cpp/               # llama.cpp source (cloned from GitHub)
│   ├── build/
│   │   └── bin/
│   │       ├── llama-cli    # Chat binary
│   │       └── llama-server # API server binary
│   ├── server.crt           # Self-signed TLS certificate
│   ├── server.key           # TLS private key
│   └── server.log           # Live server log
├── models/
│   ├── llama3-8b.gguf
│   ├── mistral-7b.gguf
│   └── *.gguf               # Any downloaded GGUF model
├── settings.env             # Persisted runtime settings (sourced on load)
└── .downloads/
    └── *.status             # Per-download state files (QUEUED/RUNNING/DONE/FAILED)

~/.local/bin/
├── llama-cli  -> ~/ai_stack/llama.cpp/build/bin/llama-cli    # symlink
└── llama-server -> ~/ai_stack/llama.cpp/build/bin/llama-server

~/llama_forensics.log        # Build/install/error log (max 500 lines, chmod 600)
~/llama_api_keys.log         # Audit log of all server starts (chmod 600)

/tmp/llama_server.pid        # PID of running server (cleared on stop)
/tmp/llama_server.info       # Active URL + key for status bar display
```

---

## Settings Persistence

Settings are stored as plain bash assignments in `~/ai_stack/settings.env`:

```bash
context_size=16384
visible2network=0.0.0.0
network_port=8443
api_key_mode=localtest
```

The file is loaded at script startup and re-loaded inside `chat_mode` and `manage_server` before use, guarding against variable state inconsistencies from subshell scope. You can edit it directly with any text editor as an alternative to the Settings menu.

---

## Web Server & API Usage

The server exposes an **OpenAI-compatible REST API** over HTTPS. The self-signed certificate will trigger a browser warning — accept it, or pass `-k` / `--insecure` to curl.

**Health check:**
```bash
curl -sk https://127.0.0.1:8080/health
```

**List models:**
```bash
curl -sk https://127.0.0.1:8080/v1/models \
  -H "Authorization: Bearer <your-api-key>"
```

**Chat completion:**
```bash
curl -sk https://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer <your-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "any",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user",   "content": "Explain GGUF format in one paragraph."}
    ]
  }'
```

**API Key Modes:**

| Mode | Behaviour |
|---|---|
| `random` | A new 24-character hex key is generated each time the server starts. Check the startup box or `~/llama_api_keys.log` for the current key. |
| `localtest` | The fixed key `localtest` is used — convenient for local curl scripting. **Only use on localhost.** |
| `custom:<value>` | Your own key, set via **Settings → API Key Mode → Custom**. |

**To make the server accessible on your local network**, set Network Binding to `0.0.0.0` in Settings (option 5 → option 2) and ensure your firewall allows the chosen port.

---

## Path Installation

After every successful build, `llama-cli` and `llama-server` are symlinked into `~/.local/bin/` and your shell profiles are patched:

```bash
# Added to ~/.bashrc, ~/.zshrc, and ~/.profile:
export PATH="$HOME/.local/bin:$PATH"  # llama.cpp binaries
```

The export is also applied to the current session immediately. From then on, in any new terminal:

```bash
llama-cli   --help
llama-server --help
```

Symlinks always point to the latest build directory, so rebuilding automatically updates the system-wide binaries without re-running PATH setup.

---

## Troubleshooting

**`AI Engine: ✗ NOT BUILT` after a successful build**

The build directory is inside `~/ai_stack/llama.cpp/build/bin/`. Check the forensic log (option 7) for cmake or compiler errors.

**Server dies immediately on start**

Select option 4 again — if the process is gone it will show the last 20 lines of `server.log` inline. Common causes: port already in use, missing SSL cert (regenerates automatically on next start), or insufficient VRAM for the selected context size and GPU layers.

**Context window fills and chat stops**

By design — `--no-context-shift` is passed so context exhaustion is explicit rather than silent. Go to **Settings → Context Size** and increase it, then start a new chat.

**Intel GPU not visible after driver install**

Level-zero requires the `render` and `video` groups. The installer adds you automatically, but group membership requires a **full re-login** (not just a new terminal). Run `groups` to verify after logging back in.

**`icx` not found after oneAPI install**

Run `source /opt/intel/oneapi/setvars.sh` manually. The installer patches `~/.bashrc`/`~/.zshrc` for future sessions. If the issue persists, check `/opt/intel/oneapi/` exists and re-run **Build AI Engine**.

**AMD Vulkan build errors**

Ensure `libvulkan-dev` and `libvulkan-dev:i386` are both installed. The installer enables i386 multiarch automatically, but a manual `sudo dpkg --add-architecture i386 && sudo apt-get update` may be needed if it was previously disabled.

**Download window doesn't open**

No supported terminal emulator was found. The download runs silently in the background instead; check status on the main menu or in `~/llama_forensics.log`.

---

## Security Notes

- The TLS certificate is **self-signed** and intended for local use. For production exposure, replace `server.crt` / `server.key` with certificates from a trusted CA.
- `~/llama_api_keys.log` contains plaintext API keys and is restricted to `chmod 600`. Do not share this file.
- The `localtest` API key mode is predictable by design — restrict use to `127.0.0.1` (the default bind address).
- Binding to `0.0.0.0` exposes the server on all network interfaces. Ensure your firewall is configured appropriately before doing so.
- The NVIDIA Deep Repair path purges all NVIDIA packages. If you are running a desktop environment, this **will break your display manager** until drivers are reinstalled and the system is rebooted.

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

*Part of the [gguf-gasket](https://github.com/MasterMould/gguf-gasket) project.*
