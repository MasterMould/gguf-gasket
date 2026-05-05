# Adding Modules to LLAMA COMMAND CENTER

This guide covers everything needed to add a new feature to the manager — from a blank file to a working, tested menu entry.

---

## How auto-discovery works

At startup `llama_manager.sh` does two things before showing the menu:

1. Sources the four **core** modules unconditionally (`globals.sh`, `detect.sh`, `drivers_gpu.sh`, `drivers_intel.sh`). These provide all shared functions and variables.

2. Globs `lib/menu_*.sh`, sources each file it finds, reads four metadata variables from it (`MENU_LABEL`, `MENU_FN`, `MENU_COLOR`, `MENU_ORDER`), and stores them in an array. After all files are read the array is sorted by `MENU_ORDER` and the menu is rendered from it.

The main loop contains no hardcoded feature names. Every entry in the menu is driven entirely by what `lib/menu_*.sh` files exist on disk.

---

## Step-by-step workflow

### Step 1 — Copy the template

```bash
cp lib/menu_module_template.sh lib/menu_YOURMODULE.sh
```

Use a short lowercase identifier with no spaces. The filename after `menu_` becomes your module's identity throughout development.

### Step 2 — Fill in the four metadata variables

Open `lib/menu_YOURMODULE.sh` and set these at the top of the file, before any functions:

```bash
MENU_LABEL="My Feature Name"   # What appears in the main menu
MENU_FN="mymodule_menu"        # The entry-point function name
MENU_COLOR='${B_CYAN}'         # Colour for the menu label
MENU_ORDER=55                  # Position in the menu (see order table)
```

**Order table** — existing modules occupy these slots. Pick a number in a gap or above 70 for new features:

| Order | Module |
|-------|--------|
| 10 | Build AI Engine |
| 20 | Download Models |
| 30 | Interactive Chat |
| 40 | Start / Stop Web Server |
| 45 | memU — Memory Optimizer |
| 50 | Settings |
| 60 | DEEP REPAIR |
| 70 | Check for Script Updates |
| 80+ | Free for new modules |

**Colour options:**

| Variable | Colour | Use for |
|----------|--------|---------|
| `${B_CYAN}` | Cyan | General features, info tools |
| `${B_GREEN}` | Green | Safe / interactive features |
| `${B_YELLOW}` | Yellow | Configuration, settings |
| `${B_RED}` | Red | Destructive or system-level actions |

### Step 3 — Name your functions

Every function in your module must be **prefixed** with your module identifier to avoid clashing with functions in other modules:

```bash
# Good
_mymodule_do_thing()  { ... }    # private helper
_mymodule_status()    { ... }    # private helper
mymodule_menu()       { ... }    # public entry point (no underscore prefix)

# Bad — will collide with other modules or builtins
do_thing()   { ... }
status()     { ... }
menu()       { ... }
```

The entry-point function (the one named in `MENU_FN`) is the only public one. Everything else is private and prefixed.

### Step 4 — Write the entry-point function

The entry-point must:
- Match the name in `MENU_FN` exactly
- Run a `while true` loop so the user can take multiple actions without returning to the main menu
- Call `draw_header` at the top of every loop iteration (keeps the display consistent)
- Return cleanly via `return` — never call `exit` (that would kill the whole manager)

```bash
mymodule_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ My Feature ]${NC}"
        echo ""
        _mymodule_status   # optional: live status at the top

        echo -e "  1) ${B_GREEN}Do something${NC}"
        echo -e "  2) ${B_CYAN}Configure${NC}"
        echo -e "  3) Back"
        local choice=""
        read -r -p "  Action: " choice

        case $choice in
            1) _mymodule_do_something ;;
            2) _mymodule_configure ;;
            3) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}
```

### Step 5 — Write sub-action functions

Each action inside your module follows this pattern:

```bash
_mymodule_some_action() {
    draw_header
    echo -e "${B_CYAN}[ My Feature — Action Name ]${NC}"
    echo ""

    # 1. Explain what will happen
    echo "  This action does X by doing Y."
    echo ""

    # 2. Guard against missing dependencies
    if ! command -v sometool &>/dev/null; then
        WARN "sometool not found. Install: sudo apt-get install sometool"
        read -p "Press Enter to return..."
        return
    fi

    # 3. Confirm before anything destructive or slow
    read -r -p "  Proceed? (y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && { WARN "Cancelled."; sleep 1; return; }

    # 4. Do the work
    sometool --option value

    # 5. Log it
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] mymodule: some_action completed" >> "$LOG_FILE"

    # 6. Confirm to user, pause briefly
    OK "Action complete."
    sleep 2
}
```

### Step 6 — Test without restarting the manager

You can source and test any function interactively in a bash session:

```bash
# From the project root directory:
source lib/globals.sh
source lib/detect.sh
source lib/menu_YOURMODULE.sh

# Run your entry point
mymodule_menu

# Or test a single sub-function
_mymodule_some_action
```

Check that:
- No variable name clashes (`declare -F | grep -v ^_mymodule | grep mymodule`)
- `MENU_LABEL` and `MENU_FN` are set after sourcing
- The entry-point function exists (`declare -f mymodule_menu`)

### Step 7 — Verify auto-discovery

Run the full discovery chain exactly as `llama_manager.sh` does:

```bash
/bin/bash -c '
    source lib/globals.sh
    source lib/detect.sh
    source lib/drivers_gpu.sh
    source lib/drivers_intel.sh

    for f in lib/menu_*.sh; do
        MENU_LABEL=""; MENU_FN=""; MENU_ORDER=99
        source "$f"
        printf "order=%-3s  fn=%-25s  label=%s\n" \
            "$MENU_ORDER" "$MENU_FN" "$MENU_LABEL"
    done
'
```

Your module should appear in the output with the correct values. The menu numbers it appears at are determined by `MENU_ORDER` after sort.

### Step 8 — Live test in the manager

```bash
./llama_manager.sh
```

Confirm:
- Your entry appears at the expected position in the menu
- Selecting it calls the correct function
- Back / return works without exiting the manager
- Invalid input shows the error message and loops correctly

---

## Available globals and functions

### Path and runtime variables (from `lib/globals.sh`)

All of these are available to your module without any import:

```bash
INSTALL_DIR      # $HOME/ai_stack/llama.cpp
BUILD_DIR        # $INSTALL_DIR/build
MODEL_DIR        # $HOME/ai_stack/models
LOG_FILE         # $HOME/llama_forensics.log
SERVER_PID_FILE  # /tmp/llama_server.pid
KEY_FILE         # $HOME/llama_api_keys.log
SERVER_INFO_FILE # /tmp/llama_server.info
SETTINGS_FILE    # $HOME/ai_stack/settings.env
DL_DIR           # $HOME/ai_stack/.downloads
context_size     # current context window (integer)
visible2network  # current bind address (IP string)
network_port     # current port (string)
api_key_mode     # "random" | "localtest" | "custom:VALUE"
```

### Logging and display functions

```bash
OK   "message"   # ✔  green — success
ERR  "message"   # ✖  red   — failure (writes to stderr)
WARN "message"   # ⚠  yellow — warning
INFO "message"   # plain indented info line
STEP "message"   # ──  cyan section header
draw_header      # clear screen + banner
```

### Settings functions

```bash
load_settings    # re-read SETTINGS_FILE into globals
save_settings    # write context_size / visible2network /
                 # network_port / api_key_mode to SETTINGS_FILE
rotate_log       # trim LOG_FILE to 500 lines
```

If your module introduces its own persistent settings, write them to a separate file in `$HOME/ai_stack/` and source/manage it yourself — don't add fields to `save_settings` unless you also update `load_settings` and the Settings menu.

### Hardware and model functions

```bash
detect_gpu       # prints: NVIDIA | AMD | INTEL | CPU
check_deps       # verifies required CLI tools, offers to install missing ones

select_model "prompt text"
# Interactive numbered list of *.gguf files in MODEL_DIR.
# Echoes the full path of the selected model.
# Returns 1 if the user selects Cancel or no models exist.
# Usage:
#   local model
#   model=$(select_model "Select model: ") || return

prompt_gpu_layers "GPU_TYPE"
# Interactive menu: 0 / 16 / 32 / 99 / custom layers.
# Echoes an integer.
# Usage:
#   local ngl
#   ngl=$(prompt_gpu_layers "$current_gpu")
```

### Colour constants

```bash
B_RED     # bold red
B_GREEN   # bold green
B_YELLOW  # bold yellow
B_CYAN    # bold cyan
NC        # reset / no colour
CLEAR     # ANSI clear screen + home
```

---

## Patterns reference

### Persistent module config

Store module-specific settings in their own file, not in `settings.env`:

```bash
MYMOD_CONFIG="$HOME/ai_stack/mymodule.conf"

_mymodule_save_config() {
    mkdir -p "$(dirname "$MYMOD_CONFIG")"
    {
        echo "mymod_option_a=$mymod_option_a"
        echo "mymod_option_b=$mymod_option_b"
    } > "$MYMOD_CONFIG"
}

_mymodule_load_config() {
    [[ -f "$MYMOD_CONFIG" ]] || return 0
    source "$MYMOD_CONFIG" || true
}
```

### Calling a background process

```bash
some_long_command > "$LOG_FILE" 2>&1 &
local pid=$!
echo "$pid" > /tmp/mymod.pid
OK "Started in background (PID $pid)"
```

### Waiting for a process with a timeout

```bash
local ready=0
for _ in 1 2 3 4 5; do
    sleep 1
    ps -p "$pid" > /dev/null 2>&1 || { ERR "Process died."; break; }
    grep -q "ready" /tmp/mymod.log 2>/dev/null && { ready=1; break; }
done
(( ready )) || WARN "Process did not confirm readiness — check logs."
```

### Sudo with a clear user message

```bash
echo -e "${B_YELLOW}  This step requires sudo.${NC}"
if ! sudo some_command; then
    ERR "Command failed. Check $LOG_FILE."
    sleep 2
    return 1
fi
```

### Using select_model in your module

```bash
_mymodule_pick_and_process() {
    local model
    model=$(select_model "Select model to process [#]: ") || return
    echo "Working on: $(basename "$model")"
    # ... do something with $model
}
```

---

## Checklist before committing

```
[ ] File named lib/menu_<identifier>.sh
[ ] MENU_LABEL set (non-empty string)
[ ] MENU_FN set and matches the entry-point function name exactly
[ ] MENU_COLOR is one of: '${B_CYAN}' '${B_GREEN}' '${B_YELLOW}' '${B_RED}'
[ ] MENU_ORDER integer, not conflicting with an existing module
[ ] All functions prefixed with _<identifier>_ (except the entry point)
[ ] No module-level code that produces output or side-effects
    (everything runs inside functions — sourcing the file must be silent)
[ ] Entry-point uses while/case/return — never calls exit
[ ] draw_header called at top of every menu screen refresh
[ ] All read prompts use read -r -p (not bare read -p)
[ ] Destructive actions guarded with a confirmation prompt
[ ] Significant actions logged to $LOG_FILE with timestamp
[ ] Tested with: source lib/globals.sh && source lib/menu_YOURMODULE.sh
[ ] Auto-discovery verified with the Step 7 test command
[ ] Live-tested in ./llama_manager.sh
```

---

## Example: minimal working module

The smallest possible module that passes all checks:

```bash
#!/bin/bash
MENU_LABEL="Hello World"
MENU_FN="hello_menu"
MENU_COLOR='${B_GREEN}'
MENU_ORDER=80

hello_menu() {
    while true; do
        draw_header
        echo -e "${B_GREEN}[ Hello World ]${NC}"
        echo ""
        echo "  1) ${B_GREEN}Say hello${NC}"
        echo "  2) Back"
        local c=""
        read -r -p "  Action: " c
        case $c in
            1) OK "Hello, world!"; sleep 2 ;;
            2) return ;;
            *) echo -e "${B_RED}Invalid.${NC}"; sleep 1 ;;
        esac
    done
}
```

Save as `lib/menu_hello.sh`, run `./llama_manager.sh`, and "Hello World" appears at position 80 in the menu with no other changes required.
