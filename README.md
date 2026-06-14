# gguf-gasket · Config Manager

A browser-based `.ini` configuration editor, model browser, chat interface,
build manager, and llama-server launcher for [gguf-gasket](https://github.com/MasterMould/gguf-gasket).
Runs as a drop-in menu module inside the gasket or as a standalone tool.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [File Layout](#file-layout)
4. [Installation](#installation)
5. [Quick Start](#quick-start)
6. [Web UI — Seven Panels](#web-ui--seven-panels)
7. [Standalone Launcher — manager.sh](#standalone-launcher--managersh)
8. [Arc GPU Tools — arc-fix.sh & arc_check.sh](#arc-gpu-tools)
9. [Shared State System](#shared-state-system)
10. [REST API Reference](#rest-api-reference)
11. [Go Source Modules](#go-source-modules)
12. [Configuration Files](#configuration-files)
13. [Build Flags Reference](#build-flags-reference)
14. [Known llama.cpp Parameters](#known-llamacpp-parameters)
15. [Troubleshooting](#troubleshooting)

---

## Overview

This toolchain adds three things to gguf-gasket:

| Component | What it does |
|---|---|
| **Config Manager web UI** | Browser-based CRUD editor for llama.cpp `.ini` config files, with a model browser, chat interface, cmake build runner, live log viewer, and HuggingFace downloader |
| **Arc GPU diagnostics** | Automated diagnosis and repair of the Intel Arc A770 driver/compute stack — OpenCL, Level Zero, oneAPI, SYCL, and the SYCL OOM crash (`could not create a memory object`) |
| **Shared state bus** | A single `~/ai_stack/selected.env` file that all tools — the web UI, `manager.sh`, `llama_manager.sh`, and the gasket's menu modules — read and write, so picking a model in one tool propagates everywhere |

Everything is self-contained: the web UI is a single Go binary with the HTML
embedded at compile time. No Node.js, no npm, no external services required.

---

## Architecture

```
llama_manager.sh  (gguf-gasket main menu)
│
├── lib/shared_state.sh          State bus — sourced by all bash tools
│
├── lib/arc_check.sh             Sourceable Arc GPU check library
│   ├── arc_detect()             Detects Arc via lspci PCI IDs
│   ├── arc_driver_loaded()      Checks xe/i915 kernel module
│   ├── arc_opencl_ok()          Validates OpenCL with portable grep -Eqi
│   ├── arc_levelzero_ok()       Checks apt package OR oneAPI-bundled Level Zero
│   ├── arc_sycl_sees_gpu()      Runs sycl-ls via oneAPI setvars.sh
│   ├── arc_quick_fix()          Auto-repairs groups/packages/driver/env vars
│   └── arc_full_status()        Coloured multi-line status table
│
├── lib/menu_arc_fix.sh          Gasket module (order 65)
│   ├── arc_fix_menu()           Interactive diagnostics + repair menu
│   ├── _arc_fix_levelzero_conflict()  Resolves apt-vs-oneAPI Level Zero conflict
│   └── show_arc_status()        One-line status for gasket main menu header
│
├── lib/menu_config_manager.sh   Gasket module (order 45)
│   ├── cm_menu()                Main module entry point
│   ├── _cm_build()              Builds the Go binary (auto-installs Go)
│   ├── _cm_start()              Starts the web UI server
│   ├── _cm_launch_server()      Starts llama-server with selected config
│   └── show_config_manager_status()  Status line for main menu header
│
└── lib/config_manager/          Go web application
    ├── main.go                  Entry point, 31-route HTTP mux, //go:embed
    ├── ini.go                   INI parser and serialiser
    ├── store.go                 Config file CRUD
    ├── models.go                GGUF file scanner, quant parser
    ├── paths.go                 paths.json management
    ├── state.go                 selected.env read/write
    ├── arc.go                   Arc GPU status via OS commands
    ├── server_mgr.go            llama-server process lifecycle
    ├── chat.go                  OpenAI-compatible streaming chat proxy
    ├── build_mgr.go             cmake + make with SSE streaming
    ├── download.go              Async HuggingFace downloader
    ├── logs.go                  SSE log tail with context cancellation
    ├── settings.go              settings.env read/write
    ├── params.go                38 documented llama.cpp parameters
    ├── handlers.go              30 HTTP handler methods
    └── app.html                 7-panel single-page application (embedded)

arc-fix.sh                       Standalone interactive Arc diagnostic (10 sections)
manager.sh                       Standalone bash launcher (no gasket required)
```

### Data flow

```
User picks model in web UI (Models tab)
    → POST /api/state  { model: "/path/to/model.gguf" }
    → writes ~/ai_stack/selected.env
    → manager.sh reads STATE_MODEL on next loop
    → menu_config_manager.sh reads STATE_MODEL for launch
    → llama_manager.sh menu header shows model name

User edits config.ini in web UI (Configs tab)
    → PUT /api/files/my-config.ini
    → writes ~/ai_stack/llama_configs/my-config.ini
    → Clicks ▶ Launch
    → POST /api/server/start  { config: "my-config.ini" }
    → Go backend parses .ini → builds CLI args
    → launches llama-server as subprocess
    → writes PID to ~/ai_stack/server.pid
    → server status bar in web UI polls GET /api/server/status every 4s
```

---

## File Layout

### Drop into gguf-gasket

```
gguf-gasket/
│
├── arc-fix.sh                   ← standalone Arc diagnostic (unchanged)
├── manager.sh                   ← standalone launcher
│
└── lib/
    ├── shared_state.sh          ← NEW: state bus
    ├── arc_check.sh             ← NEW: sourceable Arc library
    ├── menu_arc_fix.sh          ← NEW: gasket Arc module (order 65)
    ├── menu_config_manager.sh   ← NEW: gasket config manager module (order 45)
    └── config_manager/
        ├── main.go
        ├── ini.go
        ├── store.go
        ├── models.go
        ├── paths.go
        ├── state.go
        ├── arc.go
        ├── server_mgr.go
        ├── chat.go
        ├── build_mgr.go
        ├── download.go
        ├── logs.go
        ├── settings.go
        ├── params.go
        ├── handlers.go
        ├── app.html
        └── go.mod
```

### Runtime files (all in `~/ai_stack/`)

```
~/ai_stack/
├── selected.env         Active model, config, binary, port (shared state bus)
├── paths.json           Model and binary search directories
├── settings.env         Gasket settings (context size, port, network bind)
├── config_manager.env   Config manager module settings (port, configs dir)
├── llama_configs/       Where .ini config files are stored (default)
├── server.pid           PID of the running llama-server
├── server.log           llama-server stdout/stderr
├── build.log            cmake/make output
├── arc_fix.log          Arc auto-fix action log
└── llama_manager.log    Gasket main script log
```

---

## Installation

### As a gguf-gasket module (recommended)

```bash
# From the root of your gguf-gasket clone (dev branch)
cp lib/shared_state.sh       lib/
cp lib/arc_check.sh          lib/
cp lib/menu_arc_fix.sh       lib/
cp lib/menu_config_manager.sh lib/
mkdir -p lib/config_manager
cp lib/config_manager/* lib/config_manager/

chmod +x lib/menu_arc_fix.sh lib/menu_config_manager.sh

# Launch gasket — new menu items appear automatically
./llama_manager.sh
```

The gasket auto-discovers every `lib/menu_*.sh` on startup. No edits to
`llama_manager.sh` are needed.

### As a standalone tool (no gasket required)

```bash
chmod +x manager.sh
./manager.sh
```

`manager.sh` is fully self-contained. It sources `lib/shared_state.sh` and
`lib/arc_check.sh` from the same directory if they exist, but falls back to
inline stubs when running without the full library set.

### Building the Go binary

The binary is built automatically the first time you start the config manager
from either `manager.sh` or the gasket module. To build manually:

```bash
cd lib/config_manager
go build -o llamacpp-config-mgr .
```

**Requirements:** Go ≥ 1.22. If Go is not installed, the scripts attempt to
install it automatically via `apt-get` (Ubuntu/Debian), then `snap`, then a
direct download from `go.dev`.

---

## Quick Start

### From the gasket

```
./llama_manager.sh

# Main menu shows:
#   45) Config Manager  (INI editor · model browser · server)
#   65) Arc GPU  (diagnostics · repair)

# Select 45 → Start web UI → browser opens at http://localhost:7070
```

### From manager.sh

```bash
./manager.sh

# [1] Select Model (.gguf)    ← scans 15+ directories
# [2] Select Config (.ini)
# [3] Select llama binary
# [4] Launch llama-server     ← uses selected model + config
# [5] Start Config Manager (web UI)
# [6] Arc GPU diagnostics / fix
```

### Direct binary

```bash
# Start with default config dir and port 7070
./lib/config_manager/llamacpp-config-mgr

# Custom config dir and port
./lib/config_manager/llamacpp-config-mgr ~/my-configs 8888
```

---

## Web UI — Seven Panels

Open `http://localhost:7070` after starting the config manager. The top
navigation switches between panels. A persistent status bar below the
navigation shows the llama-server running state and Arc GPU health at all times.

### ⚙ Configs

The main panel. Create, edit, and delete llama.cpp `.ini` config files.

**Creating a file**

Click **+ New**, enter a name, and choose a starter template:

| Template | Pre-filled values | Best for |
|---|---|---|
| Chat / CLI | Standard sampling parameters | Interactive use |
| Server | Host, port, parallel slots, cont-batching | API server |
| Embedding | embedding=true, reduced context | Vector databases |
| Arc A770 Optimised | `n-gpu-layers=85`, `ctx-size=4096`, `flash-attn=true` | Arc A770 16 GB VRAM |
| Blank | Model path only | Manual configuration |

**Form editor**

Every known llama.cpp parameter is described with:
- A human-readable label (e.g. *Context Size* instead of `ctx-size`)
- A plain-English description of what the parameter does
- Type-appropriate input: number spinners with min/max/step, checkboxes for
  booleans, text fields for paths and strings

38 parameters are documented across these categories: model, context, GPU
offload, CPU threads, sampling (temperature, top-p, top-k, min-p, mirostat,
TFS, typical-p, repeat penalty), generation limits, server (host, port,
timeout, parallel, continuous batching), features (flash attention, embedding,
reranking, KV cache quantisation, memory lock, NUMA), and logging.

**Raw editor**

Switch to the Raw tab to edit the `.ini` text directly. Switching back to Form
re-parses the raw text, so both views stay in sync.

**Sections**

Config files support INI sections (`[section-name]`). The + Section button adds
a new section. Root-level keys (before any section header) are shown as "root".

**Saving and launching**

- `Ctrl+S` or the Save button writes the file to disk
- The **▶ Launch** button (appears when the server is stopped) auto-saves the
  config and starts llama-server with the currently selected model from the
  shared state

### 🗃 Models

Scans all configured directories for `.gguf` files and presents them in a
searchable, sortable table.

**Columns:** filename, quantisation badge (colour-coded), file size, last
modified date, action buttons.

**Quant colour coding:**

| Colour | Quantisations | Quality |
|---|---|---|
| 🔴 Red | Q2, IQ1, IQ2 | Very lossy |
| 🟡 Yellow | Q3, IQ3 | Lossy |
| 🩵 Cyan | Q4, IQ4 | Balanced (recommended) |
| 🟢 Green | Q5, Q6, Q8 | High quality |
| 🟣 Purple | F16, BF16, F32 | Full precision |

**Use in Config** sets the `model =` key in the currently open `.ini` file and
switches back to the Configs panel. It also writes the model path to
`~/ai_stack/selected.env` so `manager.sh` and the gasket see the selection.

**Download** opens a dialog for a HuggingFace URL. Paste any `/blob/` or
`/resolve/` URL; the downloader converts them automatically. A progress bar
streams from the server via SSE. When complete, the model list rescans
automatically.

**Rescan** re-runs the directory scan without reloading the page.

### 💬 Chat

A streaming chat interface that talks to the running llama-server using its
OpenAI-compatible `/v1/chat/completions` API.

- **System prompt** — sets the system message prepended to every conversation
- **Server port** — which port the llama-server is listening on
- **Clear** — resets conversation history

Messages stream token-by-token. Models that output `reasoning_content` (e.g.
Qwen3-Thinking) display their thinking in a separate dimmed block above the
final response.

`Enter` sends. `Shift+Enter` inserts a newline.

> The server must be running before using this panel. Start it from the Server
> panel or with **▶ Launch** in the Configs panel.

### 🖥 Server

Full llama-server lifecycle management.

**Status card** shows: running/stopped state, PID, port, active model name,
and uptime. Updates every 4 seconds.

**Launch options:**

| Field | Description |
|---|---|
| Model path | Override the model from shared state; leave blank to use `selected.env` |
| Config (.ini) | Select any config from the configs directory |
| Port | Server listen port (default 8080) |
| Extra flags | Additional CLI arguments (e.g. `--flash-attn --cont-batching`) |

**Recent log** shows the last 60 lines of `~/ai_stack/server.log` with a
refresh button.

### 🔨 Build

Compiles llama.cpp from source with a graphical flag selector.

**Source fields:**

| Field | Default |
|---|---|
| Source directory | `~/ai_stack/llama.cpp` |
| Build directory | `<source>/build` |
| Parallel jobs | 4 |

**Backend flags** (pre-ticked for Ryzen 7 5700X + Arc A770):

| Flag | cmake variable | Notes |
|---|---|---|
| SYCL | `GGML_SYCL` | Best for Arc A770; requires oneAPI. Also adds `-DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx` |
| SYCL F16 | `GGML_SYCL_F16` | Half-precision ops on Arc |
| Vulkan ✓ | `GGML_VULKAN` | Cross-platform GPU; no oneAPI needed |
| OpenCL | `GGML_OPENCL` | Legacy GPU path |
| CUDA | `GGML_CUDA` | NVIDIA GPUs |
| Flash Attention ✓ | `GGML_FLASH_ATTN` | Significant speed-up on supported hardware |
| AVX2 ✓ | `GGML_AVX2` | Modern x86 CPUs |
| FMA ✓ | `GGML_FMA` | Fused multiply-add |
| F16C ✓ | `GGML_F16C` | Half-precision conversion instructions |
| AVX-512 | `GGML_AVX512` | Disabled by default — causes crashes on Ryzen |

Build output streams live into the panel. Lines containing `error` are
highlighted red; completion messages are highlighted green.

### 📋 Logs

Live streaming viewer for all runtime log files.

| Tab | File | Content |
|---|---|---|
| server.log | `~/ai_stack/server.log` | llama-server stdout and stderr |
| build.log | `~/ai_stack/build.log` | cmake and make output |
| arc_fix.log | `~/ai_stack/arc_fix.log` | Arc auto-fix actions and results |
| gasket.log | `~/ai_stack/llama_manager.log` | Gasket script log |

New lines are delivered via SSE (Server-Sent Events). The browser maintains a
persistent connection; no polling. Auto-scroll can be toggled. **Clear** wipes
the log file on disk. **↻ Reload** re-fetches the last 200 lines and
reconnects the stream.

### ⚡ Paths

Edit the model and binary search directories that are shared between the web UI
and `manager.sh` via `~/ai_stack/paths.json`.

**Model Search Directories** — scanned recursively (up to 6 levels) for
`.gguf` files. The first directory is also used as the default download
destination.

Default model search directories (in priority order):

```
/home/first/ai_stack/models
~/ai_stack/models
~/models
~/Downloads
~/.cache/huggingface/hub
~/.cache/lm-studio/models
~/.lmstudio/models
~/.cache/llama.cpp
~/.ollama/models/blobs
~/llama.cpp/models
~/llama/models
/opt/models  /opt/ai/models  /var/lib/models  /srv/models
```

**Binary Search Directories** — searched for `llama-server`, `llama-cli`,
`llama-bench`, `server`, `main`.

Default binary search directories:

```
/home/first/ai_stack
/home/first/ai_stack/llama.cpp
/home/first/ai_stack/llama.cpp/build/bin
~/llama.cpp/build/bin
~/llama.cpp/build
~/llama.cpp
~/llama/build/bin  ~/llama/build
/opt/llama.cpp/bin  /opt/llama.cpp
/usr/local/bin  /usr/bin
```

Click **Save paths.json** to persist. `manager.sh` reloads the file on every
menu loop iteration, so changes take effect within seconds without restarting
anything.

---

## Standalone Launcher — manager.sh

`manager.sh` is a full-featured terminal UI that works with or without the
gasket. It sources `lib/shared_state.sh` and `lib/arc_check.sh` if they exist
beside it, with inline stubs as fallback.

### Main menu

```
Status strip (refreshed every iteration):
  ✔/✘  Config mgr    ready / will build on start / Go missing
  ✔/⚠  llama-server  RUNNING PID 12345 / stopped
  ✔/⚠  Arc GPU       OK driver=xe render=/dev/dri/renderD128 / N issue(s)
  ✔/–  Port 7070      free / in use
  ✔/–  paths.json     15 model dirs · 12 binary dirs
  ✔/⚠  Model         Qwen3.5-9B.Q8_0.gguf  9.5G  Q8_0
  ✔/–  Config        chat-4096.ini
  ✔/–  llama bin     llama-server

[1] ▶ Select Model (.gguf)
[2]    Select Config (.ini)
[3]    Select llama binary
[4] ▶ Launch llama-server
[5] ⊞ Start Config Manager (web UI)
[6] 🔧 Arc GPU diagnostics / fix
[7]    Reload paths.json
[8] ⚙  Check / Auto-fix Dependencies
[9]    Build Config Manager
[0]    Config Directory / Port
[s] ■  Stop All (server + config mgr)
[q]    Quit
```

### Model picker (`[1]`)

Scans all directories from `paths.json` (or built-in defaults). Results are
displayed in a paginated table showing filename, size, and quantisation. 12
models per page.

| Key | Action |
|---|---|
| `1`–`12` | Select model on current page |
| `n` / `p` | Next / previous page |
| `s` | Search by name or quant string |
| `i` | Show full path, size, date for a model |
| `r` | Rescan all directories |
| `a` | Add a new search directory for this session |
| `b` | Back without selecting |

Selecting a model writes to `~/ai_stack/selected.env` immediately.

### Launch inference (`[4]`)

Combines the selected model, config, and binary into a complete command:

- `--model <path>` from `STATE_MODEL`
- Every key in the selected `.ini` becomes `--flag` or `--flag value`
- Boolean `true`/`1` values become bare flags; `false`/`0` are omitted
- Option `[e]` opens the assembled command for inline editing before launch

Runs llama-server in the **foreground** — output is visible in the terminal.
`Ctrl+C` to stop.

### Auto-fix dependencies (`[8]`)

If Go is missing, attempts installation in order:
1. `apt-get install golang-1.23-go` → `golang-1.22-go` → `golang-go`
2. `snap install go --classic`
3. Official tarball from `go.dev` with persistent PATH configuration

After Go is available, automatically runs `go build` to produce the binary.

### First-run setup

If the binary is missing when the script starts, a setup prompt appears
before the main menu:

```
First-run setup needed.
Source files found but Go toolchain / binary missing.
[y] Auto-install Go and build binary now
[n] Continue to main menu anyway
```

---

## Arc GPU Tools

### arc_check.sh — the library

A sourceable bash library containing 19 non-interactive check functions.
Any script can use these by sourcing the file:

```bash
source lib/arc_check.sh

# Quick health check
arc_all_ok && echo "GPU stack healthy" || echo "Issues found"

# Detailed status table (always renders correctly regardless
# of parent shell colour variable definitions)
arc_full_status

# One-line summary for header strips
arc_status_line
# → Arc A770: OK  (driver=xe  render=/dev/dri/renderD128)

# Apply common fixes silently
arc_quick_fix
```

**Key functions:**

| Function | Returns | Description |
|---|---|---|
| `arc_detect` | 0 if Arc found | Sets `ARC_PCI_ADDR` and `ARC_PCI_ID`; scans 11 Alchemist PCI IDs |
| `arc_driver_loaded` | 0 if loaded | Checks `lsmod` for `xe` or `i915` |
| `arc_driver_bound` | 0 if bound | Checks `/sys/bus/pci/devices/.../driver` symlink |
| `arc_render_access` | 0 if writable | Tests open of `/dev/dri/renderD*` |
| `arc_user_groups_ok` | 0 if member | Checks `render` and `video` group membership |
| `arc_opencl_ok` | 0 if visible | Uses `grep -Eqi` (portable ERE alternation) |
| `arc_opencl_device_name` | string | Extracts device name from clinfo whitespace format |
| `arc_levelzero_ok` | 0 if available | Checks apt package **or** oneAPI-bundled Level Zero |
| `arc_levelzero_source` | string | Reports `apt` or `oneAPI (/opt/intel/oneapi)` |
| `arc_oneapi_ok` | 0 if functional | Sources `setvars.sh` and tests `icpx` |
| `arc_sycl_sees_gpu` | 0 if visible | Runs `sycl-ls` with `ONEAPI_DEVICE_SELECTOR=level_zero:*` |
| `arc_all_ok` | 0 if all critical | Checks detect + driver + render + groups (SYCL is non-critical) |
| `arc_quick_fix` | — | Fixes groups, installs OpenCL pkgs, skips Level Zero if oneAPI present, runs `ldconfig`, writes env profile |
| `arc_full_status` | — | Coloured table; always uses `$'\033[...]'` own colour constants |
| `arc_status_line` | — | Plain one-liner; safe for terminal headers |

**Known bug fixes baked in:**

- `grep -Eqi` (ERE) instead of `grep -qi "...\|..."` (BRE) — the BRE `\|`
  alternation was silently failing on this system, causing OpenCL to report
  false-negative even when clinfo clearly showed the Intel Arc device
- `arc_levelzero_ok` accepts either the apt `libze-intel-gpu1` package **or**
  the Level Zero bundled inside oneAPI — previously it only checked the apt
  package, so a system with only oneAPI installed would always report failure
- `arc_quick_fix` skips `apt install libze-intel-gpu1` when oneAPI is present —
  installing both creates two competing Level Zero runtimes that break `sycl-ls`
- `arc_full_status` defines its own colour constants with `$'\033[...]'` so
  it renders correctly regardless of how the parent shell (e.g. the gasket)
  defines `B_GREEN`, `B_RED` etc.

### menu_arc_fix.sh — the gasket module

Wraps `arc_check.sh` as a gasket menu module at order 65.

```
9) Arc GPU  (diagnostics · repair)

[ 🔧  INTEL ARC A770 DIAGNOSTICS ]

  ✔  Arc GPU detected         03:00.0  [56a0]
  ✔  Kernel driver loaded     xe
  ✔  Driver bound to GPU
  ✔  Render node present      /dev/dri/renderD128
  ✔  Render node writable
  ✔  intel-opencl-icd pkg
  ✔  OpenCL device visible    Intel(R) Arc(TM) A770 Graphics
  ✔  Level Zero runtime       oneAPI (/opt/intel/oneapi)
  ✔  oneAPI / icpx            /opt/intel/oneapi
  ✔  SYCL sees GPU

  1) Auto-fix common issues
  2) Fix Level Zero conflict  (apt vs oneAPI)
  3) Full interactive report  (arc-fix.sh --auto)
  4) Back
```

Option **2** detects the specific conflict where both `apt install libze-intel-gpu1`
and oneAPI are installed simultaneously. It offers to `apt remove
libze-intel-gpu1` and prints the `source setvars.sh` command to restore the
SYCL environment.

The `show_arc_status()` function is called by the gasket's main menu header:

```
Arc GPU:  ✓ Arc A770: OK  (driver=xe  render=/dev/dri/renderD128)
```

### arc-fix.sh — standalone interactive tool

The standalone version runs outside the gasket. Ten diagnostic sections:

| Section | Checks |
|---|---|
| 1. Hardware | lspci PCI ID detection, PCIe link, IOMMU group |
| 2. Kernel driver | xe/i915 module, driver binding, version check |
| 3. DRM nodes | /dev/dri/card* and renderD* presence |
| 4. Permissions | render and video group membership |
| 5. Compute runtime | OpenCL ICD, Level Zero, clinfo output |
| 6. Vulkan | mesa-vulkan-drivers, ANV ICD, vulkaninfo |
| 7. oneAPI/SYCL | Installation path, icpx, sycl-ls |
| 8. llama.cpp build | CMakeCache.txt flag inspection, linked libraries |
| 9. Environment | Profile vars, hugepages, CPU governor |
| 10. SYCL memory | USM pool vars, GDB config, VRAM budget table, log scan |

```bash
# Interactive menu
./arc-fix.sh

# Full automated scan and fix
./arc-fix.sh --auto
```

**Section 10 — SYCL Memory** (added after the `could not create a memory
object` OOM crash):

- Checks all five critical SYCL env vars and writes any missing ones to
  `/etc/profile.d/arc-llamacpp.sh`
- Writes `~/.config/gdb/gdbinit` to suppress the auto-load safe-path GDB
  warnings that appear in crash output
- Prints a VRAM budget table for Q4–Q8 quantisations × 4096/8192 context:

  ```
  Quant      Size     KV@4096ctx    KV@8192ctx    Headroom@4096
  Q4_K_M     5.5GB    1.07GB        2.15GB        8.4GB
  Q5_K_M     6.5GB    1.07GB        2.15GB        7.4GB
  Q6_K       7.5GB    1.07GB        2.15GB        6.4GB
  Q8_0       9.5GB    1.07GB        2.15GB        4.4GB   ← OOM risk at 8192
  ```

- Scans `server.log` and `arc_fix.log` for `could not create a memory object`
  occurrences
- Offers to write `~/ai_stack/llama_configs/arc-a770-optimised.ini`

**Arc A770 OOM fix (Qwen3.5-9B.Q8_0 + ctx-size=8192)**

The crash (`could not create a memory object` in `ggml_sycl_op_mul_mat`) occurs
because SYCL's Level Zero allocator is not compacting. After the first
generation, the remaining VRAM is fragmented, and the scratch buffer needed
for the matrix multiply on the second turn cannot be satisfied contiguously.

Fixes in order of impact:

```bash
# 1. Reduce context (halves KV cache, most effective)
ctx-size = 4096

# 2. Reserve VRAM for scratch
n-gpu-layers = 85   # not 99

# 3. Enable USM memory pool (prevents fragmentation)
export SYCL_PI_LEVEL_ZERO_USM_ALLOCATOR=1
export ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE

# 4. Run arc-fix.sh → [s] SYCL memory → auto-writes the above to profile
```

---

## Shared State System

`lib/shared_state.sh` is the glue between all tools. Every tool that sources
it reads and writes `~/ai_stack/selected.env`:

```bash
# ~/ai_stack/selected.env
STATE_MODEL=/home/first/ai_stack/models/Qwen3.5-9B.Q8_0.gguf
STATE_CONFIG=/home/first/ai_stack/llama_configs/chat-4096.ini
STATE_BINARY=/home/first/ai_stack/llama.cpp/build/bin/llama-server
STATE_PORT=8080
```

**Functions provided:**

```bash
state_load            # reads selected.env into STATE_* variables
state_save            # writes STATE_* variables back to file
state_set_model path  # sets STATE_MODEL and saves
state_set_config path # sets STATE_CONFIG and saves
state_set_binary path # sets STATE_BINARY and saves
state_set_port port   # sets STATE_PORT and saves
state_clear           # empties all selections

server_is_running     # returns 0 if PID in server.pid is alive
server_pid            # prints the PID or empty string
server_stop           # kills the server and removes server.pid
server_write_pid pid  # writes a PID to server.pid

state_summary         # prints a formatted status block
```

**Propagation table:**

| Action | Written by | Read by |
|---|---|---|
| Pick model in web UI | Go `/api/state` | `manager.sh`, `menu_config_manager.sh` |
| Pick model in `manager.sh` | `state_set_model` | Go web UI (polls on tab switch) |
| Open config in web UI | Go `/api/state` | `manager.sh`, `menu_config_manager.sh` |
| Start server in web UI | Go writes `server.pid` | `manager.sh [s]`, `menu_config_manager.sh`, gasket header |
| Start server in `manager.sh` | `server_write_pid` | Web UI status bar (polls every 4s) |
| Save paths in web UI | Go writes `paths.json` | `manager.sh` (reloads each loop), `menu_config_manager.sh` |

---

## REST API Reference

The web server listens on port 7070 by default (configurable).
All endpoints return `application/json`. Errors return `{"error": "message"}`.

### Config files

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/files` | List all `.ini` filenames |
| `GET` | `/api/files/{name}` | Read a config as `IniFile` JSON |
| `POST` | `/api/files` | Create from template `{"name":"…","template":"…"}` |
| `PUT` | `/api/files/{name}` | Replace entire file with `IniFile` JSON |
| `DELETE` | `/api/files/{name}` | Delete a config file |

**IniFile JSON structure:**
```json
{
  "Name": "my-config.ini",
  "Sections": [
    {
      "Name": "",
      "Keys": [
        { "Key": "ctx-size", "Value": "4096", "Comment": "context window" }
      ]
    }
  ]
}
```

### Models & binaries

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/models` | Scan and return `[]ModelInfo` |
| `GET` | `/api/binaries` | Scan and return `[]BinaryInfo` |

**ModelInfo fields:** `name`, `path`, `size`, `size_human`, `quant`, `dir`, `mod_time`

### Paths configuration

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/paths` | Return current `PathsConfig` |
| `PUT` | `/api/paths` | Save new `PathsConfig` to `paths.json` |

### Shared state

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/state` | Read `~/ai_stack/selected.env` |
| `PUT` | `/api/state` | Write `~/ai_stack/selected.env` |

**GasketState fields:** `model`, `config`, `binary`, `port`

### Gasket settings

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/settings` | Read `~/ai_stack/settings.env` |
| `PUT` | `/api/settings` | Write `~/ai_stack/settings.env` |

**GasketSettings fields:** `context_size`, `network_port`, `visible_to_network`,
`api_key_mode`, `n_gpu_layers`

### Arc GPU

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/arc/status` | Run lspci/lsmod/clinfo/dpkg checks, return `ArcStatus` |
| `POST` | `/api/arc/fix` | Run `arc_quick_fix` via `arc_check.sh`, return output |

**ArcStatus fields:** `detected`, `pci_addr`, `driver_ok`, `driver_name`,
`render_ok`, `groups_ok`, `opencl_ok`, `level_zero_ok`, `sycl_ok`, `summary`

### llama-server lifecycle

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/server/status` | Return `ServerStatus` |
| `POST` | `/api/server/start` | Start llama-server subprocess |
| `POST` | `/api/server/stop` | Send SIGINT and remove PID file |
| `GET` | `/api/server/log?n=100` | Last N lines of `server.log` |

**ServerStartReq fields:** `config` (filename), `model` (path override),
`binary` (path override), `port`, `extra` (raw CLI args)

### Chat (SSE streaming)

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/chat` | Stream chat via SSE. Body: `{"messages":[…],"stream":true}` |
| `GET` | `/api/chat/models` | Query `/v1/models` from the running server |

**SSE events:** `data: {"token":"…","think":"…","role":"assistant"}` per token,
`data: [DONE]` on completion, `data: {"error":"…"}` on failure.

### Build (SSE streaming)

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/build/start` | Start cmake+make, stream output as SSE |
| `GET` | `/api/build/status` | Return `BuildStatus` |

**BuildConfig fields:** `source_dir`, `build_dir`, `parallel`, `flags` (map of
flag key → bool)

**SSE events:** `event: log` for each output line, `event: done` with
`{"success":true/false}` on completion.

### Logs (SSE streaming)

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/logs/{name}?n=200` | Last N lines as JSON |
| `GET` | `/api/logs/{name}/stream` | SSE tail (persistent connection) |
| `DELETE` | `/api/logs/{name}` | Truncate the log file |

Valid names: `server`, `build`, `arc`, `gasket`

**SSE events:** `event: line` with each new log line; `: keepalive` every 5
seconds to prevent proxy timeouts.

### Downloads

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/downloads` | Start download `{"url":"…","dest_dir":"…"}` |
| `GET` | `/api/downloads` | List all jobs |
| `GET` | `/api/downloads/{id}` | Get job status |
| `GET` | `/api/downloads/{id}/stream` | SSE progress stream |

**DownloadJob fields:** `id`, `url`, `filename`, `dest_dir`, `total`, `done`,
`pct`, `status` (pending/downloading/done/error), `error`

HuggingFace `/blob/` URLs are automatically rewritten to `/resolve/` for
direct download.

---

## Go Source Modules

The web application is `package main` across 15 files in the same directory.
`go build .` produces a single self-contained binary with `app.html` embedded
via `//go:embed`.

| File | Exports | Notes |
|---|---|---|
| `ini.go` | `IniFile`, `IniSection`, `IniKey`, `parseINI`, `serialiseINI` | No external dependencies |
| `store.go` | `Store`, `NewStore`, `sanitiseName` | Config CRUD in a single directory |
| `models.go` | `ModelInfo`, `BinaryInfo`, `scanModels`, `scanBinaries`, `parseQuant`, `humanSize`, `expandHome` | Respects `GASKET_MODEL_DIR` env var |
| `paths.go` | `PathsConfig`, `defaultPaths`, `pathsFile`, `loadPaths`, `savePaths` | `pathsFile()` prefers `~/ai_stack/paths.json` when gasket is installed |
| `state.go` | `GasketState`, `loadGasketState`, `saveGasketState` | Reads `GASKET_STATE_FILE` env var |
| `arc.go` | `ArcStatus`, `queryArcStatus` | Pure Go re-implementation of `arc_check.sh` checks |
| `server_mgr.go` | `ServerStatus`, `serverStatus`, `ServerStartReq`, `iniToArgs`, `findBinary` | Uses `GASKET_SERVER_PID_FILE` env var |
| `chat.go` | `ChatMessage`, `ChatRequest`, `streamChat`, `fetchServerModels` | SSE proxy to OpenAI `/v1/chat/completions` |
| `build_mgr.go` | `BuildConfig`, `BuildStatus`, `streamBuild` | cmake + make with SSE output; thread-safe `buildMu` |
| `download.go` | `DownloadJob`, `startDownload`, `sseDownloadProgress` | Context-based SSE cancellation; HuggingFace URL rewriting |
| `logs.go` | `tailLog`, `streamLog`, `knownLogs` | Context-based SSE cancellation; 500 ms polling; 5 s keepalive |
| `settings.go` | `GasketSettings`, `loadGasketSettings`, `saveGasketSettings` | Preserves comments and unknown keys in `settings.env` |
| `params.go` | `ParamMeta`, `knownParams`, `paramMetaJSON`, `templateFile` | 38 documented parameters; 5 INI templates |
| `handlers.go` | `Handler`, 30 handler methods, `wire`, `errJSON` | One method per route; delegates all logic to feature modules |
| `main.go` | `main` | Route table; `//go:embed app.html` |

---

## Configuration Files

### `~/ai_stack/selected.env`

Written by `shared_state.sh`, the Go web app, and `manager.sh`. Format is
`KEY=value` with no quoting.

```bash
STATE_MODEL=/home/first/ai_stack/models/Qwen3.5-9B.Q8_0.gguf
STATE_CONFIG=/home/first/ai_stack/llama_configs/chat-4096.ini
STATE_BINARY=/home/first/ai_stack/llama.cpp/build/bin/llama-server
STATE_PORT=8080
```

### `~/ai_stack/paths.json`

Written by the Paths tab and read by all tools. Standard JSON.

```json
{
  "model_search_dirs": [
    "/home/first/ai_stack/models",
    "/home/first/Downloads"
  ],
  "binary_search_dirs": [
    "/home/first/ai_stack/llama.cpp/build/bin",
    "/usr/local/bin"
  ]
}
```

### `~/ai_stack/config_manager.env`

Config Manager module settings. Written by the gasket module's Settings
sub-menu.

```bash
cm_port=7070
cm_config_dir=/home/first/ai_stack/llama_configs
```

### `/etc/profile.d/arc-llamacpp.sh`

Written by `arc_quick_fix`. Sourced by every login shell.

```bash
export ONEAPI_DEVICE_SELECTOR=level_zero:0
export ZES_ENABLE_SYSMAN=1
export SYCL_CACHE_PERSISTENT=1
export GGML_SYCL_DEVICE=0
export SYCL_PI_LEVEL_ZERO_USM_ALLOCATOR=1
export ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE
```

---

## Build Flags Reference

Recommended flag combinations for common hardware:

### Intel Arc A770 — SYCL (maximum performance)

```bash
cmake -B build -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_SYCL=ON \
  -DGGML_SYCL_F16=ON \
  -DGGML_FLASH_ATTN=ON \
  -DGGML_AVX2=ON \
  -DGGML_FMA=ON \
  -DGGML_F16C=ON \
  -DGGML_AVX512=OFF \
  -DCMAKE_C_COMPILER=icx \
  -DCMAKE_CXX_COMPILER=icpx

# Requires: source /opt/intel/oneapi/setvars.sh --force
```

### Intel Arc A770 — Vulkan (no oneAPI required)

```bash
cmake -B build -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON \
  -DGGML_FLASH_ATTN=ON \
  -DGGML_AVX2=ON \
  -DGGML_FMA=ON \
  -DGGML_F16C=ON
```

### CPU only (Ryzen 7 5700X)

```bash
cmake -B build -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_AVX2=ON \
  -DGGML_FMA=ON \
  -DGGML_F16C=ON \
  -DGGML_AVX512=OFF \
  -DGGML_AVX_VNNI=OFF
```

---

## Known llama.cpp Parameters

38 parameters documented across 8 categories. All are available in the Configs
form editor with descriptions, types, and min/max/step constraints.

**Model:** `model`

**Context:** `ctx-size`, `batch-size`, `ubatch-size`

**GPU:** `n-gpu-layers`, `main-gpu`, `tensor-split`

**CPU:** `threads`, `threads-batch`

**Sampling:** `temperature`, `top-p`, `top-k`, `min-p`, `repeat-penalty`,
`repeat-last-n`, `tfs-z`, `typical-p`, `mirostat`, `mirostat-lr`,
`mirostat-ent`

**Generation:** `n-predict`, `seed`

**Server:** `host`, `port`, `timeout`, `parallel`, `cont-batching`,
`slots-endpoint`

**Features:** `embedding`, `reranking`, `flash-attn`, `no-mmap`, `mlock`,
`numa`, `cache-type-k`, `cache-type-v`, `defrag-thold`

**Logging:** `log-disable`, `verbose`, `log-format`

---

## Troubleshooting

### Web UI won't start — "Go not installed"

`manager.sh [8]` or selecting Start for the first time triggers auto-install.
If that fails, install manually:

```bash
sudo apt-get install golang-1.22-go   # Ubuntu 22.04+
# or
sudo snap install go --classic
# then rebuild:
cd lib/config_manager && go build -o llamacpp-config-mgr .
```

### Models panel shows empty list

1. Check the Paths tab — ensure at least one directory under **Model Search
   Directories** actually contains `.gguf` files
2. Click **⟳ Rescan**
3. Verify the `GASKET_MODEL_DIR` env var isn't pointing to an empty directory

### Chat returns "cannot reach llama-server"

1. The Server panel must show **RUNNING**
2. The port in the Chat panel must match the port llama-server is listening on
3. Check `~/ai_stack/server.log` for startup errors

### llama-server crashes on second inference turn

SYCL OOM: `could not create a memory object` in `ggml_sycl_op_mul_mat`.

```bash
# Immediate fix (current shell)
export SYCL_PI_LEVEL_ZERO_USM_ALLOCATOR=1
export ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE

# Permanent fix
./arc-fix.sh → [s] SYCL memory & crash diagnostics

# Config fix (create via web UI → New → Arc A770 Optimised)
n-gpu-layers = 85   # not 99
ctx-size     = 4096 # not 8192
```

### Arc GPU shows "OpenCL device visible ✘" despite device being present

This was caused by `grep -qi "pattern1\|pattern2"` using BRE alternation which
is not portable. Fixed in `arc_check.sh` by changing to `grep -Eqi`. Update to
the latest `arc_check.sh` if still seeing this.

### SYCL was working, now broken after arc auto-fix

The auto-fix installed `libze-intel-gpu1` from apt, which conflicts with the
Level Zero bundled in your oneAPI installation.

```bash
# From gasket: Arc GPU → Fix Level Zero conflict → Remove apt libze-intel-gpu1
# Or manually:
sudo apt remove libze-intel-gpu1
sudo ldconfig
source /opt/intel/oneapi/setvars.sh --force
```

### Colour codes show as literal `\033[...` in terminal

The gasket's colour variables are defined with single quotes (`'\033[...]'`)
making `\033` a literal 4-character string. Fixed in `arc_check.sh` by defining
local colour constants with `$'\033[...]'` (ANSI-C quoting) unconditionally,
ignoring parent shell definitions.

### GDB debug output appears when llama-server crashes

Add to `~/.config/gdb/gdbinit`:

```
set auto-load safe-path /
set debuginfod enabled off
```

Or run `arc-fix.sh → [s] SYCL memory` which writes this automatically.

---

## Requirements

| Requirement | Minimum | Notes |
|---|---|---|
| OS | Ubuntu 22.04 | Also works on 24.04; untested on other distros |
| Kernel | 5.15 | 6.2+ for xe driver; 6.8+ makes xe the default for Arc |
| Go | 1.22 | Auto-installed if missing |
| GPU driver | xe or i915 | xe is default from kernel 6.8 |
| Firmware | linux-firmware | For xe/i915 firmware blobs |
| Groups | render, video | Required for GPU access without root |
| oneAPI | 2024.x+ | Required for SYCL backend only; Vulkan has no extra deps |
| curl | any | Optional; used for server readiness checks |
| lspci | any | Optional; from `pciutils` package |
| clinfo | any | Optional; from `clinfo` package |
