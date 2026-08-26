# llama.cpp Build Forge module for LLAMA COMMAND CENTER

A drop-in Gasket module that adds a hardware-aware, accelerator-first build workflow for `llama.cpp` to `llama_manager.sh`.

The module keeps responsibilities separate: **LLAMA COMMAND CENTER owns the outer menu, shared settings, display helpers and parent-manager lifecycle; Build Forge owns accelerator detection, dependency resolution, profile generation, build execution, diagnostics, repair and deployment.**

The module is auto-discovered by `llama_manager.sh`. No edit to the main manager is required.

---

## 1. What this module does

The module turns llama.cpp building into a guided, repairable workflow:

```text
hardware
  -> backend matching
  -> llama.cpp discovery
  -> dependency resolution
  -> profile generation
  -> guided configuration
  -> CMake pre-flight
  -> compiler canary
  -> link canary where needed
  -> full build
  -> diagnosis
  -> evidence-based repair
  -> verified retry
  -> deployment into Gasket
```

The design goal is **complete a working accelerator build or explain exactly why it cannot yet be completed**.

A failed build is evidence. The module preserves the build directory and logs so they can be diagnosed and repaired rather than thrown away.

---

## 2. Requirements

The parent Gasket installation should provide the standard module interface documented by the project, including:

- `draw_header`
- `OK`, `ERR`, `WARN`, `INFO`, `STEP`
- `PAUSE`
- `INSTALL_DIR`
- `BUILD_DIR`
- `LOG_FILE`
- the standard colour variables such as `B_GREEN`, `B_YELLOW`, `B_CYAN` and `NC`

The Forge itself requires Bash and Python 3.

The actual accelerator toolchains are discovered separately. Depending on the target, these can include CUDA, ROCm/HIP, Intel oneAPI/SYCL, Level Zero, Vulkan and OpenCL.

---

## 3. Installation into Gasket

Copy the module file into the Gasket `lib/` directory:

```bash
cp /path/to/menu_llamaforge.sh ./lib/menu_llamaforge.sh
chmod 644 ./lib/menu_llamaforge.sh
```

Then start the normal manager:

```bash
./llama_manager.sh
```

The manager automatically discovers `lib/menu_*.sh` modules, so **do not edit `llama_manager.sh` just to add this module**.

The module appears as:

```text
llama.cpp Build Forge
```

---

## 4. How the module is registered

The module declares:

```bash
MENU_LABEL="llama.cpp Build Forge"
MENU_FN="llamaforge_menu"
MENU_COLOR='${B_GREEN}'
MENU_ORDER=15
```

Its internal functions use the `_llamaforge_` prefix and its module-level variables use the `LLAMAFORGE_` prefix. The only public function is `llamaforge_menu`.

This keeps the module isolated from other Gasket modules.

---

# 5. Forge location and bootstrap

The module separates the **Gasket runtime** from the **Forge workspace**.

Preferred Forge installation:

```text
~/ai_stack/llama-build-forge
```

Preferred llama.cpp source tree, when already present:

```text
~/ai_stack/llama.cpp
```

Preferred Gasket runtime build directory:

```text
$BUILD_DIR
```

The module can install or update the Forge from a downloaded archive such as:

```text
~/Downloads/llama-build-forge-v13.tar.gz
```

It also searches for other `llama-build-forge-v*.tar.gz` archives in `~/Downloads`.

Before replacing an existing Forge installation it creates a timestamped backup, for example:

```text
~/ai_stack/llama-build-forge.backup.20260826-185500
```

After installation it verifies that the `bin/llama-forge` launcher starts.

---

# 6. Main Forge actions

Inside Gasket, the module provides:

```text
 1) Hardware & backend scan
 2) Dependency resolver
 3) Generate build profiles
 4) Build manager
 5) Guided configuration
 6) Build performance tuning
 7) Catalogue of CMake options
 8) Diagnose / auto-repair a failed build
 9) Install / update Forge
10) Configure Forge path
11) Deploy completed build to Gasket
12) View module log
13) Back
```

Each action returns to the Forge module rather than exiting the parent manager.

---

# 7. Hardware & backend scan

The scanner identifies actual graphics accelerators and distinguishes useful devices from PCI bridges, audio functions and other graphics-adjacent hardware.

Where enough information is available, it records:

- vendor
- product
- discrete/integrated form factor
- kernel driver
- PCI address
- accelerator family
- available API/toolchain hints

Typical accelerator families include:

- Intel Arc and Intel integrated graphics
- AMD discrete graphics
- AMD integrated graphics
- NVIDIA graphics
- Vulkan devices
- OpenCL devices
- SYCL/Level Zero devices
- NPU/TPU devices when detectable

The scanner is deliberately hardware-aware. The presence of an AMD integrated GPU does not automatically mean that ROCm/HIP should be selected.

---

# 8. Dependency resolver

The dependency resolver performs a bounded live scan rather than recursively walking the user's entire home directory.

It searches known locations and checks:

### llama.cpp

- source trees
- Git metadata
- `llama-cli`
- `llama-server`
- `llama-bench`

### Build tools

- CMake
- Ninja
- GCC/G++
- Clang where relevant
- Git
- pkg-config
- ccache

### Accelerator toolchains

- NVIDIA `nvcc` / `nvidia-smi`
- AMD `hipcc` / ROCm tools
- Intel `icx` / `icpx` / SYCL tools
- Level Zero
- Vulkan
- OpenCL

### Resolver states

```text
OK          available and usable
MISSING     required and unavailable
OPTIONAL    useful but not required
BLOCKED     known unsupported or unsafe for this target
```

The resolver should progress from discovery to a concrete solution where a safe solution exists. It should not stop at a vague “install this manually” message when a repository package, existing runtime or supported local environment can resolve the issue.

Vendor installations remain conservative. The module must not silently mix packages from the wrong Ubuntu release merely to make a dependency check appear green.

---

# 9. llama.cpp source discovery

Once discovered, the llama.cpp source directory is retained in every generated build manifest.

For example:

```text
/home/first/ai_stack/llama.cpp
```

This allows a build to be reproduced and prevents the Forge from quietly switching source trees between runs.

The Forge workspace is separate from the source tree:

```text
source:  ~/ai_stack/llama.cpp
Forge:   ~/ai_stack/llama-build-forge
build:   ~/ai_stack/llama-build-forge/builds/<build-id>
runtime: ~/ai_stack/llama.cpp/build/bin
```

---

# 10. Accelerator-first profile generation

The profile generator matches detected hardware to build backends.

Typical targets include:

| Hardware | Profile | Backend |
|---|---|---|
| Intel Arc discrete | Intel SYCL / oneAPI | SYCL + Level Zero |
| Intel GPU | Intel Vulkan | Vulkan |
| AMD discrete | AMD HIP / ROCm | HIP |
| AMD integrated | AMD integrated Vulkan | Vulkan |
| NVIDIA | NVIDIA CUDA | CUDA |
| Generic Vulkan device | Vulkan | Vulkan |

CPU-only fallback is disabled by default.

If no suitable accelerator is available, the Forge may still inspect the machine and catalogue, but it must not silently generate a CPU-only substitute for an accelerator build.

---

# 11. READY and BLOCKED profiles

Profile readiness is a first-class decision.

Example:

```text
Intel SYCL / oneAPI (discrete)      READY
AMD integrated GPU / Vulkan         BLOCKED
```

A blocked profile explains its blocker and is withheld from normal build creation.

For example:

```text
AMD integrated GPU / Vulkan
BLOCKED
Reason: Vulkan development/runtime support is not ready
```

This prevents a profile from looking valid in the menu only to fail immediately in CMake.

---

# 12. Build manager

The Build Manager unifies list and detail views.

A build entry can show:

- build ID
- human-readable profile name
- actual target accelerator
- backend
- readiness/status
- generator
- parallel jobs
- source tree
- build directory
- CMake options
- toolchain environment
- dependency contract
- tuning settings
- build result
- repair history
- log location

Failed builds are retained.

Do not delete a failed build before diagnosis unless disk space is the reason. The build directory contains the most useful evidence for repair.

---

# 13. Guided configuration editor

The editor is intended to explain decisions rather than expose a wall of raw CMake variables.

A typical entry looks like:

```text
[x] GGML_SYCL = ON                       [RECOMMENDED]
[ ] GGML_SYCL_F16 = OFF                  [OPTIONAL]
[x] GGML_SYCL_SUPPORT_LEVEL_ZERO = ON    [RECOMMENDED]
[=] CMAKE_CXX_COMPILER = icpx            [PROTECTED]
```

Each catalogue entry includes:

1. Purpose.
2. Relevant use cases.
3. Hardware-aware recommendation.
4. Trade-offs/cautions.
5. Example usage.

Backend identity and compiler identity can be protected when editing them would invalidate the selected profile.

---

# 14. CMake option catalogue

The catalogue is intended to answer:

> What does this option do, when should I use it, and what could go wrong?

rather than simply listing the variable name.

The target catalogue contains meaningful descriptions, use cases, recommendations, cautions and examples for the supported build switches.

The catalogue can also be refreshed against the Forge's upstream switch discovery mechanism where supported.

---

# 15. Build performance tuning

The performance screen considers detected hardware and host resources.

It can control:

- generator selection, including Ninja where available
- parallel job count
- ccache
- `GGML_NATIVE`
- unity builds
- interprocedural optimisation / LTO
- conservative versus throughput-oriented modes

The default should not consume every logical CPU simply because those CPUs exist. Build jobs are chosen with CPU threads and memory available to the machine in mind.

Performance settings are stored in the build manifest, so a build can be reproduced.

---

# 16. Staged build verification

The Forge does not treat “CMake configured successfully” as proof that the build is usable.

It uses staged checks.

## Stage A: CMake configuration

Confirms that the selected compiler, backend and dependencies can configure the project.

## Stage B: compiler canary

Compiles a representative backend translation unit.

For Intel SYCL builds this has already proven useful for catching an `icpx` crash before a long build.

## Stage C: link canary

When a previous full build exposed a linker failure, the Forge can retest the failed target before another complete compilation.

## Stage D: full build

Only after the earlier checks succeed does the Forge commit to the complete build.

---

# 17. Automatic repair

Automatic repair is evidence-driven and bounded.

The intended sequence is:

```text
failure
  -> diagnose
  -> collect evidence
  -> choose safe repair
  -> apply repair
  -> reconfigure
  -> compiler/link canary
  -> retry
```

## Compiler failure

A compiler crash can trigger a conservative retry such as:

```text
ccache OFF
jobs = 1
unity OFF
LTO OFF
```

This helps distinguish compiler instability from caching or parallel-build effects.

## Intel SYCL/TBB linker mismatch

For the TBB problem observed on Intel oneAPI builds, the Forge can inspect:

- `ldd`
- `readelf`
- `nm`
- SONAMEs
- exported symbols

It can then identify a local library which actually exports the missing symbol before changing linker/runtime paths.

A repaired target must pass a link canary before a full rebuild is retried.

## Repair limits

The repair loop is bounded. It must not retry the same failed repair indefinitely.

Every repair attempt is recorded in the build manifest and build log.

Potentially destructive vendor repository changes require explicit user approval.

---

# 18. Installing and updating the Forge

Select:

```text
Install / update Forge
```

The module searches `~/Downloads` for Forge archives:

```text
llama-build-forge-v*.tar.gz
```

It prefers known versions, then falls back to the newest matching archive it can find.

The destination is:

```text
~/ai_stack/llama-build-forge
```

Existing installations are backed up before replacement.

After installation the launcher is checked.

---

# 19. Configuring a custom Forge path

Select:

```text
Configure Forge path
```

You can point the module at an existing `bin/llama-forge` executable.

The setting is stored under:

```text
~/ai_stack/llama-forge/config
```

Selecting an empty path resets discovery to automatic mode.

---

# 20. Deploying a successful build into Gasket

This is the bridge between the Forge workspace and the normal Gasket runtime.

Select:

```text
Deploy completed build to Gasket
```

The module only offers builds whose last recorded build result succeeded.

The source payload is the complete generated:

```text
<build>/cmake/bin/
```

payload, including accelerator/backend shared libraries produced alongside the executables.

The deployment target is:

```text
$BUILD_DIR/bin
```

which is normally:

```text
~/ai_stack/llama.cpp/build/bin
```

## Why the whole `bin/` directory is copied

An accelerator build is rarely just a single executable. `llama-cli` may depend on backend libraries such as:

```text
libggml-base.so
libggml-cpu.so
libggml-sycl.so
libggml-vulkan.so
```

depending on the selected configuration.

Copying only `llama-cli` can therefore produce a runtime that looks installed but fails when launched.

## Deployment safety

Before replacing an existing target directory the module creates a timestamped backup:

```text
$BUILD_DIR/bin.backup.YYYYMMDD-HHMMSS
```

The copy is then performed and the resulting payload is checked for the expected llama.cpp executables where present.

Deployment is a copy operation, not a symlink, so Gasket receives a self-contained runtime payload.

---

# 21. Logs

The module log is:

```text
~/ai_stack/llama-forge/module.log
```

The Forge keeps a separate log for each build:

```text
~/ai_stack/llama-build-forge/builds/<build-id>/build.log
```

The module log records module-level actions such as:

```text
Forge installed
Forge path configured
Forge launched
Build deployed
```

The build log records the technical evidence:

```text
CMake
compiler
linker
failed targets
repair attempts
exit codes
```

When reporting or diagnosing a failure, preserve both logs.

---

# 22. Typical new-machine workflow

```text
1. Open ./llama_manager.sh
2. Select llama.cpp Build Forge
3. Hardware & backend scan
4. Dependency resolver
5. Generate build profiles
6. Review READY/BLOCKED profiles
7. Guided configuration if required
8. Tune build performance
9. Build the selected configuration
10. Allow bounded automatic repair where offered
11. Review the final result
12. Deploy completed build to Gasket
```

---

# 23. Typical failed-build workflow

```text
1. Open Build manager
2. Select the failed build
3. Diagnose / auto-repair
4. Inspect diagnosis and proposed repair
5. Let the canary verify the repair
6. Retry the full build
7. Deploy only after success
```

Do not delete the failed build before repair if the log contains a useful compiler or linker failure.

---

# 24. Example: Intel Arc + oneAPI

A typical Intel Arc profile uses:

```text
CMAKE_BUILD_TYPE=Release
GGML_SYCL=ON
GGML_SYCL_TARGET=INTEL
GGML_SYCL_SUPPORT_LEVEL_ZERO=ON
GGML_NATIVE=ON
CMAKE_C_COMPILER=icx
CMAKE_CXX_COMPILER=icpx
```

The important part is explicit compiler selection. Merely finding `icpx` in the filesystem is not enough if CMake subsequently drives the build with `/usr/bin/c++` and passes it SYCL flags.

The Forge therefore records and uses the Intel oneAPI environment for the build.

---

# 25. Example: Intel Arc plus integrated AMD graphics

A workstation may expose:

```text
Intel Arc A770          discrete
AMD Granite Ridge       integrated
```

The Forge treats those as two potential targets rather than one blended GPU.

A typical result is:

```text
Intel SYCL / oneAPI       READY
AMD integrated Vulkan     READY or BLOCKED according to Vulkan support
```

The AMD integrated path is optional. Its presence must not force the Arc build onto ROCm.

---

# 26. CPU-only behaviour

CPU fallback is disabled by default.

With no usable accelerator:

- hardware inspection remains available
- dependency inspection remains available
- the catalogue remains available
- existing build metadata can be inspected
- accelerator profiles are not fabricated
- CPU-only builds are not silently substituted

This is intentional: the manager should never imply that an accelerator build exists when the machine cannot provide one.

---

# 27. Troubleshooting

## Forge is “not found”

Use:

```text
Install / update Forge
```

or:

```text
Configure Forge path
```

Preferred launcher:

```text
~/ai_stack/llama-build-forge/bin/llama-forge
```

## No builds are offered for deployment

Deployment only exposes successful builds.

Open Build manager and inspect failed builds rather than deploying an incomplete payload.

## Profile is BLOCKED

Read the blocker shown in the profile. A blocked profile is not a broken build. It means the Forge intentionally stopped before wasting a build attempt.

## CMake fails

Run the dependency resolver first, then Diagnose / auto-repair.

Typical causes include missing toolchains, incorrect compilers or unavailable backend development files.

## Compiler crashes

Allow the conservative repair path to retry with reduced concurrency and cache use.

## Linker fails

Keep the build directory. The linker failure and missing symbols are often enough to identify the incorrect library version or runtime path.

Use Diagnose / auto-repair before deleting the build.

## Deployment works but Gasket cannot launch the executable

Check:

```text
$BUILD_DIR/bin
```

and confirm that the accelerator backend libraries copied with `llama-cli`/`llama-server` are present.

Also inspect the deployed executable's runtime dependencies with `ldd` if required.

---

# 28. Development rules

Follow the Gasket module-development contract when modifying the module.

### Function names

Use:

```text
_llamaforge_<helper>
llamaforge_menu
```

### Globals

Use:

```text
LLAMAFORGE_<name>
```

### Sourcing

Sourcing the module must not perform actions or print output.

### Menu lifecycle

The entry point must loop and `return` to the parent manager. Never call `exit` from the module.

### Prompts

Use:

```bash
read -r -p
```

### Destructive/slow actions

Ask for confirmation before performing them.

### Logging

Record significant actions with timestamps.

### Shared helpers

Prefer the existing Gasket helpers for headers, status and prompts rather than recreating them in the module.

---

# 29. Validation checklist

Before committing a module change:

```text
[ ] bash -n lib/menu_llamaforge.sh
[ ] module sources without output or side effects
[ ] MENU_LABEL is set
[ ] MENU_FN matches llamaforge_menu
[ ] MENU_ORDER is an integer
[ ] all private functions use the _llamaforge_ prefix
[ ] menu entry appears automatically
[ ] Back returns to llama_manager.sh
[ ] invalid input loops safely
[ ] Forge discovery works
[ ] Forge installation/update works
[ ] successful builds only are offered for deployment
[ ] deployment creates a rollback backup
[ ] deployment copies the complete bin payload
[ ] build failures preserve evidence
[ ] repair attempts are logged
```

Recommended live test:

```bash
./llama_manager.sh
```

Then exercise at least:

```text
llama.cpp Build Forge
  -> Hardware & backend scan
  -> Dependency resolver
  -> Generate build profiles
  -> Build manager
  -> Guided configuration
  -> Build performance tuning
  -> Diagnose / auto-repair
  -> Install / update Forge
  -> Deploy completed build to Gasket
```

---

# 30. File layout

The module package contains:

```text
llama-forge-module-v14/
├── README.md
└── lib/
    └── menu_llamaforge.sh
```

The README stays with the module so the integration remains understandable when copied into another Gasket checkout.

---

## Design principle

Build Forge is not intended to be another menu wrapper around `cmake`.

It is intended to answer three questions every time:

```text
What hardware do I have?
What build does that hardware actually need?
What must change when the build fails?
```

The module exists to make those answers visible, repeatable and actionable from LLAMA COMMAND CENTER.
