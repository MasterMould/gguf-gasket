# llama.cpp Build Forge

Hardware-aware, accelerator-first build manager for llama.cpp on Ubuntu 24.04 and Ubuntu 26.04.

## Interactive menu

Run with no arguments:

```bash
./bin/llama-forge
```

The interface is plain numbered text with no colour, cursor tricks, mouse controls, or external TUI dependency. It is designed to behave well over SSH, in screen readers, and in ordinary terminal logs.

The menu provides:

1. Scan hardware
2. Check/install dependencies
3. Generate build configurations
4. List builds
5. View build details
6. Edit build CMake options
7. Build a configuration
8. Delete a build
9. Export build commands
10. Refresh the switch catalog
11. Show the switch catalog
12. Improve build performance
0. Exit

## Accelerator-first policy

CPU fallback is disabled. The forge will not automatically create or run CPU-only builds.

A build is allowed only when the scan finds an accelerator such as a supported GPU, NPU, TPU, or another recognised accelerator capability. If an accelerator exists but no known llama.cpp backend matches it, the forge reports that condition and creates no CPU fallback.

Compilation performs the accelerator check again, so an old configuration cannot silently turn into a CPU build after hardware or driver changes.

## Hardware and dependency preflight

The scan uses `lshw`, `lspci`, `/etc/os-release`, device nodes, and tool detection to build a hardware profile. The dependency manager then checks the software stack required by the matching backend.

It can find:

- llama.cpp source trees and common installed binaries
- CMake, Ninja, GCC/Clang, Git and package-config tooling
- NVIDIA driver/CUDA
- AMD ROCm/HIP
- Intel oneAPI SYCL and Level Zero
- Vulkan runtime/development tooling
- OpenCL runtime/development tooling
- ccache/sccache

On Ubuntu 24.04/26.04, missing packages are offered for APT installation when they are actually available in the configured repositories. Vendor stacks that need a vendor repository or installer are reported rather than guessed at.

Each generated build contains a dependency contract describing the required accelerator tools, runtime checks, optional build accelerators, and the no-CPU-fallback policy.

## Performance tuning

The forge includes four build-tuning profiles:

### Balanced

Uses Ninja when available, parallel compilation sized from detected CPU/RAM resources, `GGML_NATIVE=ON`, and ccache when installed.

### Fast compile

Balanced settings plus CMake unity builds. Unity builds can reduce compilation overhead but may expose source-level incompatibilities, so the setting is explicit rather than silently enabled.

### Maximum runtime optimization

Balanced settings plus CMake interprocedural optimization/LTO. This can improve final runtime performance but may increase build time and memory consumption.

### Conservative

Uses portable CPU flags and fewer parallel compilation jobs for systems where maximum concurrency or machine-specific tuning is undesirable.

Upstream llama.cpp documents parallel CMake builds, Ninja, ccache, and `GGML_NATIVE` as useful compilation/performance mechanisms. citeturn271724search0turn271724search4

When performance settings change on an already-configured build, the old CMake cache is preserved as `cmake.previous-<timestamp>` and a clean CMake tree is created. This avoids generator/cache conflicts.

## Active build feedback

Builds are no longer executed as a blind `subprocess.run()` call.

During a build the forge displays:

```text
=== BUILD PRE-FLIGHT ===
Profile: Intel SYCL / oneAPI (discrete)
Generator: Ninja
Parallel jobs: 16
ccache: ON | native: ON | unity: OFF | LTO: OFF
Log: .../build.log

[1/2] Configuring CMake...
[CMAKE] -- Found IntelSYCL ...
[CMAKE] finished with exit 0 in 2.1s

[2/2] Compiling with 16 parallel job(s)...
[COMPILE]   8% | [ 8%] Building ...
[COMPILE]  25% | [25%] Building ...
...
[COMPILE] finished with exit 0 in 143.7s

BUILD COMPLETE. ✅
```

Progress lines are derived from CMake's percentage output. Important warnings/errors are surfaced immediately, while the complete stdout/stderr stream is retained in `build.log`.

A failed configuration or compile is kept intact for diagnosis. The forge does not throw a Python traceback at the user.

## Intel SYCL compiler protection

SYCL profiles explicitly select `icx` and `icpx`. This is important because a generic `c++` compiler cannot consume SYCL's `-fsycl` option. The generated environment and manifest preserve the selected compiler/toolchain.

## Build layout

Every generated configuration receives an independent folder:

```text
builds/
└── intel-sycl-20260814-135500/
    ├── manifest.json
    ├── run.sh
    ├── build.log
    └── cmake/
```

`manifest.json` contains:

- hardware snapshot
- selected backend/profile
- dependency contract
- compiler/toolchain settings
- performance tuning
- CMake switches
- build environment
- generated command
- previous build results and log locations

This makes builds inspectable, reproducible, editable, exportable, and removable.

## CLI

The menu is the primary interface, but the commands remain available for scripting:

```bash
./bin/llama-forge scan
./bin/llama-forge dependencies
./bin/llama-forge generate --source /path/to/llama.cpp
./bin/llama-forge list
./bin/llama-forge show BUILD_ID
./bin/llama-forge edit BUILD_ID GGML_CUDA_GRAPHS=OFF
./bin/llama-forge performance
./bin/llama-forge build-run BUILD_ID
./bin/llama-forge delete BUILD_ID
./bin/llama-forge export BUILD_ID
```
