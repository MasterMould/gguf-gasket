# OpenVINO & OVMS Manager for Ubuntu 26.04

This script provides an automated, interactive, and command-line driven utility to manage the OpenVINO Runtime (version 2026.2.0) and the OpenVINO Model Server (OVMS) (version 2026.2.1) on Ubuntu 26.04 (x86_64) systems.

It is specifically designed to handle known compatibility issues on Ubuntu 26.04, such as Python version mismatches and missing shared libraries.

## Features

### OpenVINO Runtime Management

* **Automated Installation:** Downloads and extracts the OpenVINO archive directly to `/opt/intel/openvino_2026.2.0`.


* **Python Environment Isolation:** Bypasses the Ubuntu 26.04 system Python (which is too new for the compiled bindings) by bootstrapping a compatible Python (3.10-3.13) via the `deadsnakes` PPA and building a dedicated virtual environment.


* **Environment Registration:** Automatically appends the required `setupvars.sh` source command to the user's `~/.bashrc`.


* **Hardware Verification:** Includes a verification step to print available inference devices using the initialized Python core.



### OpenVINO Model Server (OVMS)

* **Installation & Deployment:** Installs the `python_off` variant of OVMS directly to `/opt/ovms`.


* **Automated Library Repair:** Resolves an upstream issue where Ubuntu 26.04 drops `libxml2.so.2` and ICU 74 dependencies by spinning up a temporary `ubuntu:24.04` Docker container to extract and patch the missing libraries directly into `/opt/ovms/ovms/lib`.


* **Model Pulling & Conversion:** Integrates with the Hugging Face API to search for, download, and optionally quantize models using `optimum-cli`.


* **Local Model Scanning:** Scans standard directories (like `~/Downloads`, `~/.cache/huggingface/hub`, and custom paths) to find existing `.gguf` or OpenVINO IR (`.xml`/`.bin`) models to register them without re-downloading.


* **Service Management:** Starts the REST API server on a configurable port (default `8000`), tracks the process ID, and maintains logs.



---

## Prerequisites

To run this script successfully, your system must meet the following requirements:

* Root privileges (`sudo`) are required for installation and repair tasks.


* `curl` is required to download archives and query APIs.


* `docker` is required *only* if the OVMS installation needs to fetch legacy shared libraries to complete the `ovms_repair_libs` step.



---

## Usage

You can run the script in interactive mode to access a numbered menu, or pass specific arguments for direct execution.

### Interactive Mode

Run the script without arguments to open the interactive menu:

```bash
sudo ./openvino_manager.sh

```

### Command-Line Arguments

For non-interactive or scripted execution, append one of the following arguments:

| Argument | Description |
| --- | --- |
| `install` | Installs the OpenVINO Runtime and sets up the Python venv.

 |
| `uninstall` | Removes OpenVINO Runtime, symlinks, and bashrc modifications.

 |
| `verify` | Checks available inference devices via the Python API.

 |
| `repair` | Re-installs Python dependencies into the virtual environment.

 |
| `ovms-install` | Installs OVMS and automatically attempts library repair.

 |
| `ovms-uninstall` | Stops OVMS, removes `/opt/ovms`, and optionally deletes downloaded models.

 |
| `ovms-repair` | Manually triggers the Docker-based shared library patch for OVMS.

 |
| `ovms-pull` | Opens the interactive Hugging Face search, download, and conversion tool.

 |
| `ovms-scan` | Scans local directories for `.gguf` or IR models to register them.

 |
| `ovms-start` | Starts the OVMS REST API server in the background.

 |
| `ovms-stop` | Safely terminates the running OVMS process.

 |
| `ovms-status` | Displays whether OVMS is running and tails the last 20 lines of the log.

 |
| `ovms-list` | Lists all models currently registered in the `config_all.json` file.

 |
| `ovms-remove` | Removes a specific model from the active OVMS configuration.

 |

---

## Directory Structure & State

The script creates and manages the following paths on your system:

* `/opt/intel/openvino_2026.2.0`: OpenVINO Runtime installation directory.


* `/opt/ovms`: OVMS application and patched library directory.


* `~/.local/share/openvino-venv`: Dedicated Python virtual environment for OpenVINO.


* `~/ov-models`: Storage directory for pulled and converted models.


* `~/ov-models/config_all.json`: Active multi-model configuration file for OVMS.


* `~/.local/share/ovms/`: State directory containing process IDs (`ovms.pid`) and logs (`ovms.log`).
