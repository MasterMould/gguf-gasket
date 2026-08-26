# llama.cpp Build Forge module for LLAMA COMMAND CENTER

This is a drop-in `lib/menu_llamaforge.sh` module for the LLAMA COMMAND CENTER.

## Install

Copy the module into the manager's `lib/` directory:

```bash
cp lib/menu_llamaforge.sh /path/to/llama-command-center/lib/
```

Restart `llama_manager.sh`. The manager auto-discovers `lib/menu_*.sh`, so no changes to `llama_manager.sh` are required.

## Forge location

The module auto-detects the Forge in common locations, including:

- `~/ai_stack/llama-build-forge/bin/llama-forge`
- `~/Downloads/llama-build-forge/bin/llama-forge`
- versioned Forge directories from recent releases
- a `llama-forge` executable on `PATH`

Use **Configure Forge path** to select another executable. The selection is stored under `~/ai_stack/llama-forge/`.

## Module actions

The module exposes the Forge's specialist functions without replacing the existing manager:

1. Hardware and backend scan
2. Dependency resolver
3. Accelerator-aware profile generation
4. Build manager
5. Guided configuration editor
6. Build performance tuning
7. Descriptive CMake/switch catalogue
8. Failure diagnosis and bounded auto-repair
9. Forge path configuration
10. Module log

## Behaviour

The module leaves the Forge's accelerator-first policy intact. CPU fallback remains disabled unless the Forge itself is deliberately changed.

The Forge continues to provide:

- Intel SYCL/Level Zero profiles
- NVIDIA CUDA profiles
- AMD HIP/ROCm profiles where supported
- optional integrated AMD Vulkan profiles
- Vulkan/OpenCL alternatives when usable
- bounded hardware and llama.cpp discovery
- dependency resolution and re-verification
- CMake and compiler preflight
- linker canaries and evidence-based repair
- per-build logs and repair history
- performance tuning with Ninja/ccache/jobs/native/unity/LTO controls

## Module contract

This module follows `MODULE_DEVELOPMENT.md`:

- one public entry point: `llamaforge_menu`
- all private helpers use `_llamaforge_`
- module globals use the `LLAMAFORGE_` prefix
- no output or side-effects occur merely by sourcing the file
- menu actions use `read -r -p`
- the module returns to the main manager instead of calling `exit`
- meaningful actions are logged
