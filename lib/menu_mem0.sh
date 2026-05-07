#!/bin/bash
# Menu module — auto-discovered by llama_manager.sh
MENU_LABEL="mem0 — Persistent AI Memory"
MENU_FN="mem0_menu"
MENU_COLOR='${B_CYAN}'
MENU_ORDER=82

# ================================================================
#  mem0 — Persistent Memory Layer for LLM Interactions
#
#  mem0 is a Python library that gives LLMs persistent, structured
#  memory across conversations. It stores memories as embeddings
#  in a local vector store (Chroma by default) and retrieves
#  relevant ones at inference time.
#
#  This module:
#    • Installs mem0ai into a dedicated Python virtualenv
#    • Configures the storage backend (local Chroma or Qdrant)
#    • Generates a starter Python integration script for use
#      with llama-server's OpenAI-compatible API
#    • Provides a live test to confirm mem0 ↔ llama-server works
#    • Manages the mem0 virtualenv lifecycle (upgrade, reset)
# ================================================================

MEM0_DIR="$HOME/ai_stack/mem0"
MEM0_VENV="$MEM0_DIR/venv"
MEM0_CONFIG="$MEM0_DIR/config.json"
MEM0_SCRIPT="$MEM0_DIR/mem0_client.py"
MEM0_LOG="$MEM0_DIR/mem0.log"
MEM0_DB_DIR="$MEM0_DIR/chroma_db"

# ================================================================
#  HELPERS
# ================================================================

_mem0_is_installed() {
    [[ -f "$MEM0_VENV/bin/python" ]] && \
    "$MEM0_VENV/bin/pip" show mem0ai &>/dev/null 2>&1
}

_mem0_status() {
    echo -e "  ${B_CYAN}mem0 status:${NC}"

    if _mem0_is_installed; then
        local ver
        ver=$("$MEM0_VENV/bin/pip" show mem0ai 2>/dev/null | awk '/^Version/ {print $2}')
        echo -e "    Library  : ${B_GREEN}installed${NC} (mem0ai $ver)"
        echo -e "    Venv     : $MEM0_VENV"
    else
        echo -e "    Library  : ${B_RED}not installed${NC}"
    fi

    if [[ -f "$MEM0_CONFIG" ]]; then
        local backend
        backend=$(python3 -c "import json,sys; d=json.load(open('$MEM0_CONFIG')); \
            print(d.get('vector_store',{}).get('provider','unknown'))" 2>/dev/null \
            || echo "unknown")
        echo -e "    Backend  : ${B_YELLOW}${backend}${NC}"
        echo -e "    Config   : $MEM0_CONFIG"
    else
        echo -e "    Config   : ${B_YELLOW}not configured${NC}"
    fi

    if [[ -d "$MEM0_DB_DIR" ]]; then
        local db_size
        db_size=$(du -sh "$MEM0_DB_DIR" 2>/dev/null | awk '{print $1}')
        echo -e "    DB size  : $db_size  ($MEM0_DB_DIR)"
    fi

    # Check if llama-server is running to show integration target
    if [[ -f "$SERVER_PID_FILE" ]] && \
       ps -p "$(cat "$SERVER_PID_FILE" 2>/dev/null)" > /dev/null 2>&1; then
        local info_url
        info_url=$(grep "URL" "$SERVER_INFO_FILE" 2>/dev/null | awk '{print $NF}' || true)
        echo -e "    llama-server: ${B_GREEN}running${NC} ${info_url}"
    else
        echo -e "    llama-server: ${B_YELLOW}stopped${NC} (start it for full integration test)"
    fi
}

# ================================================================
#  INSTALL
# ================================================================

_mem0_install() {
    draw_header
    echo -e "${B_CYAN}[ mem0 — Install ]${NC}"
    echo ""
    echo "  mem0ai will be installed into a dedicated Python virtualenv:"
    echo "    $MEM0_VENV"
    echo ""
    echo "  Default vector store: Chroma (local, no extra services needed)"
    echo "  Optional: Qdrant (requires Docker — configure after install)"
    echo ""
    echo "  Python 3.9+ required. Checking…"

    local python_bin=""
    for py in python3 python3.12 python3.11 python3.10 python3.9; do
        if command -v "$py" &>/dev/null; then
            local ver
            ver=$("$py" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            local major minor
            major=$(echo "$ver" | cut -d. -f1)
            minor=$(echo "$ver" | cut -d. -f2)
            if (( major >= 3 && minor >= 9 )); then
                python_bin="$py"
                echo -e "  ${B_GREEN}Found: $py ($ver)${NC}"
                break
            fi
        fi
    done

    if [[ -z "$python_bin" ]]; then
        ERR "Python 3.9+ not found."
        echo "  Install with: sudo apt-get install python3 python3-venv python3-pip"
        read -p "Press Enter to return..."
        return 1
    fi

    # Ensure venv module is available
    if ! "$python_bin" -m venv --help &>/dev/null 2>&1; then
        WARN "python3-venv not installed. Installing…"
        sudo apt-get install -y python3-venv &>> "$LOG_FILE" || {
            ERR "Failed to install python3-venv."
            read -p "Press Enter to return..."
            return 1
        }
    fi

    read -r -p "  Install mem0ai now? (y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && return

    mkdir -p "$MEM0_DIR"
    echo ""
    STEP "Creating virtualenv…"
    "$python_bin" -m venv "$MEM0_VENV" || {
        ERR "Failed to create virtualenv."
        read -p "Press Enter to return..."
        return 1
    }

    STEP "Upgrading pip…"
    "$MEM0_VENV/bin/pip" install --upgrade pip 2>&1 | tail -2

    STEP "Installing mem0ai + chromadb (this may take 2–5 minutes)…"
    "$MEM0_VENV/bin/pip" install "mem0ai[local]" chromadb openai 2>&1 \
        | tee -a "$MEM0_LOG" \
        | grep -E "Successfully|error|ERROR|Collecting mem0|Installing" || true

    if ! _mem0_is_installed; then
        ERR "Installation failed. Check $MEM0_LOG"
        read -p "Press Enter to return..."
        return 1
    fi

    OK "mem0ai installed."
    echo ""

    # Write default config
    _mem0_write_default_config
    # Generate integration script
    _mem0_write_client_script
    OK "Default configuration and client script written."
    echo ""
    echo "  Next: start llama-server (menu option 4), then use"
    echo "  option 3 (Test Integration) to verify the full pipeline."
    sleep 3
}

# ================================================================
#  CONFIGURATION
# ================================================================

_mem0_write_default_config() {
    mkdir -p "$MEM0_DB_DIR"
    cat > "$MEM0_CONFIG" << JSONEOF
{
    "vector_store": {
        "provider": "chroma",
        "config": {
            "collection_name": "llama_memories",
            "path": "${MEM0_DB_DIR}"
        }
    },
    "llm": {
        "provider": "openai",
        "config": {
            "model": "any",
            "openai_base_url": "http://127.0.0.1:8080/v1",
            "api_key": "localtest"
        }
    },
    "embedder": {
        "provider": "openai",
        "config": {
            "model": "text-embedding-ada-002",
            "openai_base_url": "http://127.0.0.1:8080/v1",
            "api_key": "localtest"
        }
    }
}
JSONEOF
}

_mem0_configure() {
    draw_header
    echo -e "${B_CYAN}[ mem0 — Configure ]${NC}"
    echo ""

    if ! _mem0_is_installed; then
        WARN "mem0 is not installed. Install it first (option 1)."
        sleep 2; return
    fi

    echo "  Current config: $MEM0_CONFIG"
    echo ""
    echo "  1) Set llama-server URL and API key"
    echo "  2) Switch vector store backend"
    echo "  3) View / edit raw config (nano)"
    echo "  4) Reset to defaults"
    echo "  5) Back"
    local c=""
    read -r -p "  Select [1-5]: " c

    case $c in
        1)
            echo ""
            read -r -p "  llama-server base URL [http://127.0.0.1:8080/v1]: " url
            url="${url:-http://127.0.0.1:8080/v1}"
            read -r -p "  API key [localtest]: " apikey
            apikey="${apikey:-localtest}"
            # Patch the config in-place using python3
            "$MEM0_VENV/bin/python3" - << PYEOF
import json
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
cfg["llm"]["config"]["openai_base_url"] = "$url"
cfg["llm"]["config"]["api_key"] = "$apikey"
cfg["embedder"]["config"]["openai_base_url"] = "$url"
cfg["embedder"]["config"]["api_key"] = "$apikey"
with open("$MEM0_CONFIG","w") as f:
    json.dump(cfg, f, indent=4)
print("Config updated.")
PYEOF
            OK "llama-server URL and API key updated."
            ;;
        2)
            echo ""
            echo "  1) Chroma  (local, no extra services — default)"
            echo "  2) Qdrant  (requires Qdrant running on localhost:6333)"
            local vs=""
            read -r -p "  Select [1-2]: " vs
            case $vs in
                1)
                    "$MEM0_VENV/bin/python3" - << PYEOF
import json
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
cfg["vector_store"] = {
    "provider": "chroma",
    "config": {"collection_name": "llama_memories", "path": "$MEM0_DB_DIR"}
}
with open("$MEM0_CONFIG","w") as f:
    json.dump(cfg, f, indent=4)
PYEOF
                    OK "Switched to Chroma (local)."
                    ;;
                2)
                    "$MEM0_VENV/bin/pip" install qdrant-client 2>&1 | tail -1
                    "$MEM0_VENV/bin/python3" - << PYEOF
import json
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
cfg["vector_store"] = {
    "provider": "qdrant",
    "config": {"collection_name": "llama_memories",
               "host": "localhost", "port": 6333}
}
with open("$MEM0_CONFIG","w") as f:
    json.dump(cfg, f, indent=4)
PYEOF
                    OK "Switched to Qdrant. Ensure Qdrant is running on localhost:6333."
                    WARN "Start Qdrant: docker run -p 6333:6333 qdrant/qdrant"
                    ;;
                *) WARN "Invalid." ;;
            esac
            ;;
        3)
            if command -v nano &>/dev/null; then
                nano "$MEM0_CONFIG"
            else
                cat "$MEM0_CONFIG"
                echo ""
                WARN "nano not found. Printed config above. Edit manually: $MEM0_CONFIG"
            fi
            ;;
        4)
            read -r -p "  Reset config to defaults? (y/n): " rst
            [[ "${rst,,}" == "y" ]] && _mem0_write_default_config && OK "Reset to defaults."
            ;;
        5) return ;;
        *) WARN "Invalid." ;;
    esac
    sleep 2
}

# ================================================================
#  INTEGRATION SCRIPT
# ================================================================

_mem0_write_client_script() {
    cat > "$MEM0_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
mem0 ↔ llama-server integration client.
Generated by LLAMA COMMAND CENTER — edit as needed.

Usage:
    python3 mem0_client.py add    "user" "Remember that I prefer concise answers"
    python3 mem0_client.py search "what are my preferences?"
    python3 mem0_client.py list
    python3 mem0_client.py chat   "Tell me about my preferences" [user_id]
"""
import sys
import json
import os

CONFIG_FILE = os.path.join(os.path.dirname(__file__), "config.json")

def load_mem0():
    from mem0 import Memory
    with open(CONFIG_FILE) as f:
        cfg = json.load(f)
    return Memory.from_config(cfg)

def cmd_add(m, role, content, user_id="default_user"):
    result = m.add([{"role": role, "content": content}], user_id=user_id)
    print(f"Added {len(result)} memory entries.")

def cmd_search(m, query, user_id="default_user"):
    results = m.search(query, user_id=user_id)
    if not results:
        print("No relevant memories found.")
        return
    for i, r in enumerate(results, 1):
        print(f"[{i}] (score={r.get('score', '?'):.3f}) {r['memory']}")

def cmd_list(m, user_id="default_user"):
    memories = m.get_all(user_id=user_id)
    if not memories:
        print("No memories stored.")
        return
    for i, mem in enumerate(memories, 1):
        print(f"[{i}] {mem['memory']}")

def cmd_chat(m, prompt, user_id="default_user"):
    """Retrieve relevant memories and inject them into a chat request."""
    import urllib.request, json as _json
    with open(CONFIG_FILE) as f:
        cfg = _json.load(f)
    base_url = cfg["llm"]["config"]["openai_base_url"].rstrip("/v1").rstrip("/")
    api_key  = cfg["llm"]["config"]["api_key"]
    model    = cfg["llm"]["config"]["model"]

    mems = m.search(prompt, user_id=user_id)
    mem_text = "\n".join(f"- {r['memory']}" for r in mems) if mems else "None"
    system_msg = f"You are a helpful assistant.\n\nRelevant memories about this user:\n{mem_text}"

    payload = json.dumps({
        "model": model,
        "messages": [
            {"role": "system",  "content": system_msg},
            {"role": "user",    "content": prompt}
        ]
    }).encode()

    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {api_key}"},
        method="POST"
    )
    # Accept self-signed certs
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
        data = json.loads(resp.read())
    reply = data["choices"][0]["message"]["content"]
    print(reply)
    # Store the exchange in memory
    m.add([
        {"role": "user",      "content": prompt},
        {"role": "assistant", "content": reply}
    ], user_id=user_id)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    cmd = sys.argv[1]
    m = load_mem0()
    if   cmd == "add"    and len(sys.argv) >= 4: cmd_add(m, sys.argv[2], sys.argv[3])
    elif cmd == "search" and len(sys.argv) >= 3: cmd_search(m, sys.argv[2])
    elif cmd == "list":                           cmd_list(m)
    elif cmd == "chat"   and len(sys.argv) >= 3:
        uid = sys.argv[3] if len(sys.argv) > 3 else "default_user"
        cmd_chat(m, sys.argv[2], uid)
    else:
        print(__doc__); sys.exit(1)
PYEOF
    chmod +x "$MEM0_SCRIPT"
}

# ================================================================
#  TEST
# ================================================================

_mem0_test() {
    draw_header
    echo -e "${B_CYAN}[ mem0 — Test Integration ]${NC}"
    echo ""

    if ! _mem0_is_installed; then
        WARN "mem0 not installed. Use option 1."; sleep 2; return
    fi

    STEP "1/4  Importing mem0…"
    if ! "$MEM0_VENV/bin/python3" -c "from mem0 import Memory; print('  import OK')" 2>&1; then
        ERR "Import failed. Check $MEM0_LOG"
        read -p "Press Enter to return..."; return
    fi

    STEP "2/4  Initialising memory store with config…"
    "$MEM0_VENV/bin/python3" - << PYEOF 2>&1 | tee -a "$MEM0_LOG"
import json
from mem0 import Memory
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
try:
    m = Memory.from_config(cfg)
    print("  Memory store initialised OK")
except Exception as e:
    print(f"  ERROR: {e}")
    raise
PYEOF

    STEP "3/4  Adding a test memory…"
    "$MEM0_VENV/bin/python3" - << PYEOF 2>&1
import json
from mem0 import Memory
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
m = Memory.from_config(cfg)
result = m.add([{"role":"user","content":"mem0 integration test message"}],
               user_id="test_user")
print(f"  Added {len(result)} memory entries.")
PYEOF

    STEP "4/4  Searching memories…"
    "$MEM0_VENV/bin/python3" - << PYEOF 2>&1
import json
from mem0 import Memory
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
m = Memory.from_config(cfg)
results = m.search("integration test", user_id="test_user")
if results:
    print(f"  Found {len(results)} result(s) — mem0 round-trip OK")
    for r in results:
        print(f"    [{r.get('score','?'):.3f}] {r['memory']}")
else:
    print("  No results — store may be empty or embedding failed")
PYEOF

    echo ""
    OK "Test complete. See above for results."
    echo ""
    echo "  Client script: $MEM0_SCRIPT"
    echo "  Usage: $MEM0_VENV/bin/python3 $MEM0_SCRIPT --help"
    read -p "Press Enter to return..."
}

# ================================================================
#  UPGRADE / RESET
# ================================================================

_mem0_upgrade() {
    draw_header
    echo -e "${B_CYAN}[ mem0 — Upgrade ]${NC}"
    echo ""
    if ! _mem0_is_installed; then
        WARN "mem0 not installed."; sleep 2; return
    fi
    STEP "Upgrading mem0ai…"
    "$MEM0_VENV/bin/pip" install --upgrade "mem0ai[local]" chromadb openai 2>&1 \
        | grep -E "Successfully|already up-to-date|ERROR" || true
    OK "Upgrade complete."
    sleep 2
}

_mem0_reset() {
    draw_header
    echo -e "${B_CYAN}[ mem0 — Reset ]${NC}"
    echo ""
    WARN "This will delete the virtualenv, config, client script, and all"
    WARN "stored memories in $MEM0_DB_DIR."
    read -r -p "  Type 'yes' to confirm full reset: " conf
    [[ "$conf" != "yes" ]] && { echo "Cancelled."; sleep 1; return; }
    rm -rf "$MEM0_DIR"
    OK "mem0 fully removed."
    sleep 2
}

# ================================================================
#  MAIN MENU
# ================================================================
mem0_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ 🧠  mem0 — Persistent AI Memory ]${NC}"
        echo ""
        _mem0_status
        echo ""
        echo -e "------------------------------------------------------"
        echo -e "  1) ${B_GREEN}Install mem0ai${NC}"
        echo -e "  2) ${B_CYAN}Configure${NC}              (URL, API key, vector store)"
        echo -e "  3) ${B_CYAN}Test Integration${NC}       (store → search round-trip)"
        echo -e "  4) ${B_YELLOW}Upgrade mem0ai${NC}"
        echo -e "  5) ${B_RED}Reset / Uninstall${NC}"
        echo -e "  6) Back"
        echo ""
        local choice=""
        read -r -p "  Action: " choice
        case $choice in
            1) _mem0_install ;;
            2) _mem0_configure ;;
            3) _mem0_test ;;
            4) _mem0_upgrade ;;
            5) _mem0_reset ;;
            6) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}
