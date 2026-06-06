# 📁 Config Manager — gguf-gasket module

A drop-in menu module for [gguf-gasket](https://github.com/MasterMould/gguf-gasket)
that adds a browser-based `.ini` config editor and model browser for llama.cpp.

---

## What it adds to the gasket menu

```
45) Config Manager  (INI editor · model browser)
```

Selecting it opens a sub-menu that lets you:

| Action | Description |
|--------|-------------|
| **Start web UI** | Launches the Go HTTP server; opens browser automatically |
| **Stop server** | Kills the background process |
| **(Re)build binary** | Compiles `main.go` with the system Go toolchain; auto-installs Go if missing |
| **Settings** | Change port (default 7070) and configs directory |

The web UI itself provides three panels:

- **Configs** — Create, edit, and delete `.ini` files with a guided form for every known llama.cpp parameter (type-appropriate inputs, descriptions, min/max/step). Raw `.ini` text editor also available.
- **Models** — Scans `$MODEL_DIR` (and any extra paths in `~/ai_stack/paths.json`) for `.gguf` files. Shows quant class, size, and date. "Use in Config" sets `model =` in the currently open `.ini`.
- **Paths** — Live editor for model and binary search directories. Saves to `~/ai_stack/paths.json`, shared with `llama_manager.sh`.

---

## Installation

```bash
# From the root of your gguf-gasket clone (dev branch)
cp menu_config_manager.sh  lib/
cp -r config_manager/      lib/

# Make executable
chmod +x lib/menu_config_manager.sh
```

That's it. `llama_manager.sh` auto-discovers every `lib/menu_*.sh` on startup —
no edits to the main script are needed.

---

## File layout

```
lib/
├── menu_config_manager.sh      ← module (sourced by llama_manager.sh)
└── config_manager/
    ├── main.go                 ← Go web server source
    └── go.mod                  ← Go module manifest
                                  (binary built here on first use)
```

---

## Path integration with gguf-gasket

| Variable | Value | Source |
|----------|-------|--------|
| `MODEL_DIR` | `~/ai_stack/models` | `lib/globals.sh` — used as primary model scan root |
| `GASKET_MODEL_DIR` | env var set before starting binary | `menu_config_manager.sh` — prepended to model search list |
| `~/ai_stack/paths.json` | shared search-path config | written by web UI Paths tab; read by this module and `llama_manager.sh` |
| `~/ai_stack/config_manager.env` | module settings | port and configs directory, separate from gasket's `settings.env` |
| `~/ai_stack/llama_configs/` | default configs directory | created on first start; configurable |

When `~/ai_stack/` exists (i.e. gasket is installed), `paths.json` is stored
there alongside `settings.env`.  When the binary is used standalone, `paths.json`
lives next to the binary as before.

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| Go ≥ 1.22 | Auto-installed via `apt` or `snap` if missing |
| `curl` | For server readiness polling (optional) |
| `xdg-open` | For auto-opening the browser (optional) |

All other dependencies are met by gguf-gasket's core (`globals.sh`, `detect.sh`).

---

## Module interface

`menu_config_manager.sh` exports one public function for the gasket main loop:

```bash
show_config_manager_status   # prints a status line in the main menu header
```

This follows the same convention as `show_download_status` in `menu_download.sh`.

---

## Settings

Managed via the module's own Settings sub-menu and stored in
`~/ai_stack/config_manager.env`:

```bash
cm_port=7070                          # Web UI port
cm_config_dir=$HOME/ai_stack/llama_configs   # Where .ini files live
```
