# llama.cpp Build Forge

Hardware-aware, accelerator-first llama.cpp build manager for Ubuntu 24.04 and 26.04.

## Safety / policy

- CPU-only fallback is disabled.
- A build is blocked when no usable GPU/NPU/TPU is detected.
- A build is also blocked when its selected accelerator backend lacks required drivers/toolchains.
- Existing build folders and logs are preserved after failures.

## Interactive menu

Run:
```
./bin/llama-forge
```

The menu includes hardware scanning, dependency checks/install, build profile generation, CRUD, export, switch catalogue refresh, and performance tuning.

## Dependency scanning

The dependency manager is deliberately bounded. It does **not** recursively crawl the entire filesystem or home directory looking for `llama.cpp`. It checks known locations to a small depth, installed binaries, compiler/toolchain commands, accelerator runtime indicators, and configured APT packages.

Live status is printed as the scan progresses.

## Performance tuning

The performance menu shows detected CPU threads, RAM, Ninja/ccache availability, and the exact parallel job count selected by each profile.

Profiles:

1. Balanced / desktop-friendly
2. Fast compile
3. Maximum runtime optimisation
4. Responsive / low system impact
5. Maximum CPU parallelism

The default generated configuration does not automatically consume every CPU thread. Maximum parallelism remains an explicit choice.

llama.cpp currently recommends parallel compilation (`-j`), Ninja, and ccache for faster builds; `GGML_NATIVE=ON` is used when a machine-specific optimized build is appropriate.


## Resolver behavior
The dependency menu is a resolver, not a report-only check.  
It performs:

1. bounded discovery;
2. hardware-to-backend matching;
3. safe APT installation where the configured repositories provide the required packages;
4. vendor-specific installation guidance where an external repository is required;
5. re-scan and verification;
6. a final `SOLUTION STATUS: READY TO GENERATE A BUILD` or `SOLUTION STATUS: BLOCKED` result.

The resolver does not treat an integrated AMD Radeon APU as a reason to install ROCm just because an AMD GPU is present. Discrete AMD GPUs can select HIP/ROCm; integrated Radeon hardware uses an available alternate backend such as Vulkan instead.

Intel oneAPI is detected even when `icpx` is not on the current interactive shell `PATH`. Existing `/opt/intel/oneapi/setvars.sh` installations are discovered and their environment is loaded automatically for llama.cpp builds.


## v10 hardening
- Restores the missing gpu_form_factor helper used by profile generation and manifests.
- Profile creation is now gated by live dependency blockers.
- Blocked profiles are displayed with concrete reasons and are not emitted or built.
- Runtime emit_build also enforces the blocker gate.

## Automatic repair
Build failures are diagnosed and, when a bounded local repair is available, repaired automatically before retrying. Repair history is stored in each build manifest. Current automatic repairs include Intel oneAPI TBB/MKL linker compatibility when a local matching TBB library exports the missing symbol, and conservative compilation fallback after compiler/linker failures. Vendor repository changes, kernel/driver changes, and cross-release package/repository changes are not performed automatically.

## Accessibility and presentation
The menu uses high-contrast ANSI colours only when supported. Set `NO_COLOR=1` or `LLAMA_FORGE_NO_COLOR=1` for plain output. Status text also includes words such as `[OK]`, `[BLOCKED]` and `[FAILED]`, so colour is never the only signal.
