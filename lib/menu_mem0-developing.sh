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
# Dedicated embedding server
EMBED_DIR="$HOME/ai_stack/embeddings"
EMBED_MODEL="$EMBED_DIR/nomic-embed-text-v1.5.Q4_K_M.gguf"
EMBED_PORT="8081"

EMBED_PID_FILE="$EMBED_DIR/embedding-server.pid"
EMBED_LOG="$EMBED_DIR/embedding-server.log"

EMBED_URL="http://127.0.0.1:${EMBED_PORT}/v1"

EMBED_MODEL_URL="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"

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
        local backend embedder
        backend=$(python3 -c "import json,sys; d=json.load(open('$MEM0_CONFIG')); \
            print(d.get('vector_store',{}).get('provider','unknown'))" 2>/dev/null \
            || echo "unknown")
        embedder=$(python3 -c "import json,sys; d=json.load(open('$MEM0_CONFIG')); \
            print(d.get('embedder',{}).get('provider','unknown'))" 2>/dev/null \
            || echo "unknown")
        echo -e "    Backend  : ${B_YELLOW}${backend}${NC}"
        echo -e "    Embedder : ${B_YELLOW}${embedder}${NC}"
        echo -e "    Config   : $MEM0_CONFIG"
    else
        echo -e "    Config   : ${B_YELLOW}not configured${NC}"
    fi

    if [[ -d "$MEM0_DB_DIR" ]]; then
        local db_size
        db_size=$(du -sh "$MEM0_DB_DIR" 2>/dev/null | awk '{print $1}')
        echo -e "    DB size  : $db_size  ($MEM0_DB_DIR)"
    fi

    if _mem0_embedding_server_running; then
        echo -e "    Embed server : ${B_GREEN}running${NC} ${EMBED_URL}"
    else
        echo -e "    Embed server : ${B_YELLOW}stopped${NC}"
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

_mem0_embedding_server_running() {
    [[ -n "${EMBED_PID_FILE:-}" ]] || return 1
    [[ -f "$EMBED_PID_FILE" ]] || return 1

    local pid
    pid=$(cat "$EMBED_PID_FILE" 2>/dev/null || true)

    [[ -n "$pid" ]] || return 1

    ps -p "$pid" >/dev/null 2>&1
}

_mem0_install_embedding_model() {
    draw_header
    echo -e "${B_CYAN}[ mem0 — Install Embedding Model ]${NC}"
    echo ""

    mkdir -p "$EMBED_DIR"

    if [[ -f "$EMBED_MODEL" ]]; then
        OK "Embedding model already installed:"
        echo "  $EMBED_MODEL"
        read -p "Press Enter to return..."
        return
    fi

    STEP "Downloading nomic-embed-text GGUF..."

    if command -v wget >/dev/null 2>&1; then
        wget -O "$EMBED_MODEL" "$EMBED_MODEL_URL"
    elif command -v curl >/dev/null 2>&1; then
        curl -L "$EMBED_MODEL_URL" -o "$EMBED_MODEL"
    else
        ERR "Neither wget nor curl found."
        read -p "Press Enter to return..."
        return 1
    fi

    if [[ -f "$EMBED_MODEL" ]]; then
        OK "Embedding model installed."
    else
        ERR "Download failed."
    fi

    read -p "Press Enter to return..."
}

_mem0_start_embedding_server() {
    draw_header
    echo -e "${B_CYAN}[ mem0 — Start Embedding Server ]${NC}"
    echo ""

    if _mem0_embedding_server_running; then
        OK "Embedding server already running."
        echo "  URL: $EMBED_URL"
        read -p "Press Enter to return..."
        return
    fi

    if [[ ! -f "$EMBED_MODEL" ]]; then
        ERR "Embedding model not installed."
        echo ""
        echo "Install it first from menu option 4."
        read -p "Press Enter to return..."
        return 1
    fi

    if ! command -v llama-server >/dev/null 2>&1; then
        ERR "llama-server not found in PATH."
        read -p "Press Enter to return..."
        return 1
    fi

    STEP "Starting embedding server..."

    nohup llama-server \
        -m "$EMBED_MODEL" \
        --host 0.0.0.0 \
        --port "$EMBED_PORT" \
        --embeddings \
        --pooling mean \
        > "$EMBED_LOG" 2>&1 &

    echo $! > "$EMBED_PID_FILE"

    sleep 4

    if curl -s "$EMBED_URL/models" >/dev/null 2>&1; then
        OK "Embedding server online."
        echo "  URL: $EMBED_URL"

        # Auto-update mem0 config
        if [[ -f "$MEM0_CONFIG" ]]; then
            "$MEM0_VENV/bin/python3" - << PYEOF
import json
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)

cfg["embedder"] = {
    "provider": "openai",
    "config": {
        "model": "nomic-embed",
        "openai_base_url": "$EMBED_URL",
        "api_key": "localtest"
    }
}

with open("$MEM0_CONFIG","w") as f:
    json.dump(cfg, f, indent=4)

print("Updated embedder config.")
PYEOF
        fi

    else
        ERR "Embedding server failed to start."
        echo ""
        echo "Check:"
        echo "  $EMBED_LOG"
        cat $EMBED_LOG
    fi

    read -p "Press Enter to return..."
}

_mem0_stop_embedding_server() {
    draw_header
    echo -e "${B_CYAN}[ mem0 — Stop Embedding Server ]${NC}"
    echo ""

    if ! _mem0_embedding_server_running; then
        WARN "Embedding server is not running."
        read -p "Press Enter to return..."
        return
    fi

    local pid
    pid=$(cat "$EMBED_PID_FILE")

    kill "$pid" 2>/dev/null
    rm -f "$EMBED_PID_FILE"

    OK "Embedding server stopped."

    read -p "Press Enter to return..."
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
    echo "  Default embedder: Ollama nomic-embed-text (recommended)"
    echo "  Optional: Qdrant (requires Docker — configure after install)"
    echo ""
    echo "  Python 3.9+ required. Checking…"
    sudo apt-get install python3 python3-venv python3-pip -y
        
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
    "$MEM0_VENV/bin/pip" install "mem0ai[local]" chromadb openai spacy 2>&1 \
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

    # Auto-detect URL and API key from the running server info file if available.
    # Fall back to http (not https) since llama-server may use either scheme.
    local detected_url="http://127.0.0.1:8080/v1"
    local detected_key="localtest"
    if [[ -f "$SERVER_INFO_FILE" ]]; then
        local info_url info_key
        info_url=$(grep -oP 'https?://[^\s]+' "$SERVER_INFO_FILE" 2>/dev/null | head -1) || true
        info_key=$(grep -oP 'Key\s*:.*\K\S+$' "$SERVER_INFO_FILE" 2>/dev/null | head -1) || true
        [[ -n "$info_url" ]] && detected_url="${info_url%/}/v1"
    # llama.cpp local servers are almost always plain HTTP
    if [[ "$detected_url" =~ ^https://(127\.0\.0\.1|192\.168\.|10\.) ]]; then
        WARN "Detected local HTTPS URL. Converting to HTTP for llama.cpp compatibility."
        detected_url="${detected_url/https:/http:}"
    fi
        [[ -n "$info_key" ]] && detected_key="$info_key"
    fi

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
            "openai_base_url": "${detected_url}",
            "api_key": "${detected_key}"
        }
    },
    "embedder": {
        "provider": "openai",
        "config": {
            "model": "nomic-embed",
            "openai_base_url": "${EMBED_URL}",
           "api_key": "localtest"
        }
    }
}

JSONEOF
    INFO "Config written. LLM endpoint: ${detected_url}"
INFO "Embedder: dedicated llama.cpp embedding server"
WARN "Install/start embedding server from the mem0 menu if not already running."
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
    echo "  2) Switch embedder backend"
    echo "  3) View / edit raw config (nano)"
    echo "  4) Reset to defaults"
    echo "  5) Back"
    local c=""
    read -r -p "  Select [1-5]: " c

    case $c in
        1)
            echo ""
            # Show current values as defaults
            local cur_url cur_key
            cur_url=$("$MEM0_VENV/bin/python3" -c \
                "import json; c=json.load(open('$MEM0_CONFIG')); print(c['llm']['config'].get('openai_base_url','http://127.0.0.1:8080/v1'))" \
                2>/dev/null || echo "http://127.0.0.1:8080/v1")
            cur_key=$("$MEM0_VENV/bin/python3" -c \
                "import json; c=json.load(open('$MEM0_CONFIG')); print(c['llm']['config'].get('api_key','localtest'))" \
                2>/dev/null || echo "localtest")
            read -r -p "  llama-server base URL [$cur_url]: " url
            url="${url:-$cur_url}"
            # Strip trailing /v1 if user pasted the full URL — normalise it
            url="${url%/v1}"
            read -r -p "  API key [$cur_key]: " apikey
            apikey="${apikey:-$cur_key}"
            "$MEM0_VENV/bin/python3" - << PYEOF
import json
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
cfg["llm"]["config"]["openai_base_url"] = "$url/v1"
cfg["llm"]["config"]["api_key"] = "$apikey"
# Only update embedder URL if it is also the openai provider
#if cfg.get("embedder",{}).get("provider") == "openai":
#    cfg["embedder"]["config"]["openai_base_url"] = "$url/v1"
#    cfg["embedder"]["config"]["api_key"] = "$apikey"
with open("$MEM0_CONFIG","w") as f:
    json.dump(cfg, f, indent=4)
print("Config updated.")
PYEOF
            OK "llama-server URL set to $url/v1"
            ;;
        2)
            echo ""
            echo "  Select embedder backend:"
            echo "  1) Ollama   — nomic-embed-text (local, recommended — needs Ollama running)"
            echo "  2) OpenAI   — uses llama-server /v1/embeddings endpoint"
            echo "  3) Chroma   — switch vector store backend (Chroma ↔ Qdrant)"
            local vs=""
            read -r -p "  Select [1-3]: " vs
            case $vs in
                1)
                    "$MEM0_VENV/bin/pip" install ollama 2>&1 | tail -1
                    "$MEM0_VENV/bin/python3" - << PYEOF
import json
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
cfg["embedder"] = {
    "provider": "ollama",
    "config": {"model": "nomic-embed-text", "ollama_base_url": "http://127.0.0.1:11434"}
}
with open("$MEM0_CONFIG","w") as f:
    json.dump(cfg, f, indent=4)
print("Embedder set to Ollama nomic-embed-text.")
PYEOF
                    OK "Embedder: Ollama. Ensure Ollama is running: ollama pull nomic-embed-text"
                    ;;
                2)
                    local cur_url2
                    cur_url2=$("$MEM0_VENV/bin/python3" -c \
                        "import json; c=json.load(open('$MEM0_CONFIG')); print(c['llm']['config'].get('openai_base_url','http://127.0.0.1:8080/v1'))" \
                        2>/dev/null || echo "http://127.0.0.1:8080/v1")
                    local cur_key2
                    cur_key2=$("$MEM0_VENV/bin/python3" -c \
                        "import json; c=json.load(open('$MEM0_CONFIG')); print(c['llm']['config'].get('api_key','localtest'))" \
                        2>/dev/null || echo "localtest")
                    "$MEM0_VENV/bin/python3" - << PYEOF
import json
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
cfg["embedder"] = {
    "provider": "openai",
    "config": {
        "model": "text-embedding-ada-002",
        "openai_base_url": "$cur_url2",
        "api_key": "$cur_key2"
    }
}
with open("$MEM0_CONFIG","w") as f:
    json.dump(cfg, f, indent=4)
print("Embedder set to llama-server OpenAI endpoint.")
PYEOF
                    OK "Embedder: llama-server /v1/embeddings. Ensure the server is running."
                    WARN "Note: llama-server may disconnect if the model doesn't support embeddings."
                    ;;
                3)
                    echo ""
                    echo "  1) Chroma  (local, no extra services — default)"
                    echo "  2) Qdrant  (requires Qdrant running on localhost:6333)"
                    local vb=""
                    read -r -p "  Select [1-2]: " vb
                    case $vb in
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
print("Vector store: Chroma (local).")
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
print("Vector store: Qdrant.")
PYEOF
                            OK "Switched to Qdrant."
                            WARN "Start Qdrant: docker run -p 6333:6333 qdrant/qdrant"
                            ;;
                        *) WARN "Invalid." ;;
                    esac
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
    count = len(result) if isinstance(result, list) else (
        len(result.get("results", [])) if isinstance(result, dict) else 1
    )
    print(f"Added {count} memory entry/entries.")

def cmd_search(m, query, user_id="default_user"):
    # Try new API first (filters=), fall back to old API (user_id=)
    try:
        results = m.search(query, filters={"user_id": user_id})
    except (TypeError, ValueError):
        try:
            results = m.search(query, user_id=user_id)
        except:
            results = m.search(query)
    
    # Handle both dict and list results
    if isinstance(results, dict):
        results = results.get("results", [])
    
    if not results:
        print("No relevant memories found.")
        return
    for i, r in enumerate(results, 1):
        score = r.get('score', r.get('similarity', '?'))
        memory = r.get('memory', r.get('text', str(r)))
        print(f"[{i}] (score={score:.3f}) {memory}")

def cmd_list(m, user_id="default_user"):
    # Try new API first (filters=), fall back to old API (user_id=)
    try:
        memories = m.get_all(filters={"user_id": user_id})
    except (TypeError, ValueError):
        try:
            memories = m.get_all(user_id=user_id)
        except:
            memories = m.get_all()
    
    # Handle both dict and list results
    if isinstance(memories, dict):
        memories = memories.get("results", [])
    
    if not memories:
        print("No memories stored.")
        return
    for i, mem in enumerate(memories, 1):
        memory_text = mem.get('memory', mem.get('text', str(mem)))
        print(f"[{i}] {memory_text}")

def cmd_chat(m, prompt, user_id="default_user"):
    """Retrieve relevant memories and inject them into a chat request."""
    import urllib.request, json as _json
    with open(CONFIG_FILE) as f:
        cfg = _json.load(f)
    base_url = cfg["llm"]["config"]["openai_base_url"].rstrip("/v1").rstrip("/")
    api_key  = cfg["llm"]["config"]["api_key"]
    model    = cfg["llm"]["config"]["model"]

    # Search with API compatibility
    try:
        mems = m.search(prompt, filters={"user_id": user_id})
    except (TypeError, ValueError):
        try:
            mems = m.search(prompt, user_id=user_id)
        except:
            mems = m.search(prompt)
    
    # Handle both dict and list results
    if isinstance(mems, dict):
        mems = mems.get("results", [])
    
    mem_text = "\n".join(f"- {r.get('memory', r.get('text', str(r)))}" for r in mems) if mems else "None"
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

    # Detect embedder type from config — only warn about server if using openai embedder
    local embedder_provider
    embedder_provider=$("$MEM0_VENV/bin/python3" -c \
        "import json; c=json.load(open('$MEM0_CONFIG')); print(c.get('embedder',{}).get('provider','openai'))" \
        2>/dev/null || echo "openai")

    local server_running=0
    if [[ -f "$SERVER_PID_FILE" ]] && \
       ps -p "$(cat "$SERVER_PID_FILE" 2>/dev/null || echo 0)" > /dev/null 2>&1; then
        server_running=1
    fi

    if [[ "$embedder_provider" == "openai" ]] && (( server_running == 0 )); then
        echo -e "${B_YELLOW}  ⚠  Embedder is set to 'openai' (llama-server) but llama-server is not running.${NC}"
        echo "     Steps 3 and 4 (add/search memory) will fail with a connection error."
        echo ""
        echo "  Options:"
        echo "  1) Start llama-server first (menu option 4), then re-run test"
        echo "  2) Switch embedder to Ollama (Configure → option 2)"
        echo "  3) Continue anyway (steps 1-2 will pass, 3-4 will show the error)"
        local skip_choice=""
        read -r -p "  Select [1-3]: " skip_choice
        case $skip_choice in
            1) WARN "Start llama-server then return here."; sleep 2; return ;;
            2) _mem0_configure; return ;;
            3) INFO "Continuing — expect connection errors at steps 3/4." ;;
            *) return ;;
        esac
    fi

        echo ""
        STEP "0/4  Checking embedding endpoint..."

        if ! curl -s "$EMBED_URL/models" >/dev/null 2>&1; then
        ERR "Embedding server unavailable."
        echo ""
        echo "Start it using:"
        echo "  mem0 → Start Embedding Server"
        echo ""
        echo "Expected endpoint:"
        echo "  $EMBED_URL"
        read -p "Press Enter to return..."
        return
    fi

OK "Embedding endpoint reachable."

    STEP "1/4  Importing mem0…"
    if ! "$MEM0_VENV/bin/python3" -c \
        "from mem0 import Memory; print('  import OK')" 2>&1; then
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
    "$MEM0_VENV/bin/python3" - << PYEOF 2>&1 | tee -a "$MEM0_LOG"
import json
from mem0 import Memory
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
m = Memory.from_config(cfg)
# mem0 >=0.1.x: user_id goes in metadata, not as kwarg
result = m.add(
    [{"role": "user", "content": "mem0 integration test message"}],
    user_id="test_user"
)
count = len(result) if isinstance(result, list) else (
    len(result.get("results", [])) if isinstance(result, dict) else 1
)
print(f"  Added {count} memory entry/entries.")
PYEOF

    STEP "4/4  Searching memories…"
    "$MEM0_VENV/bin/python3" - << PYEOF 2>&1 | tee -a "$MEM0_LOG"
import json
from mem0 import Memory
with open("$MEM0_CONFIG") as f:
    cfg = json.load(f)
m = Memory.from_config(cfg)

# Try new API first (filters=), fall back to old API (user_id=)
try:
    results = m.search("integration test", filters={"user_id": "test_user"})
except (TypeError, ValueError):
    try:
        results = m.search("integration test", user_id="test_user")
    except:
        results = m.search("integration test")

# Handle both dict and list results
if isinstance(results, dict):
    results = results.get("results", [])

if results:
    print(f"  Found {len(results)} result(s) — mem0 round-trip OK")
    for r in results[:3]:
        score = r.get("score", r.get("similarity", "?"))
        mem   = r.get("memory", r.get("text", str(r)))
        print(f"    [{score}] {mem}")
else:
    print("  No results — store may be empty or embedding step failed")
PYEOF

    echo ""
    OK "Test complete. See above for results."
    echo ""
    echo "  Client script: $MEM0_SCRIPT"
    echo "  Usage: $MEM0_VENV/bin/python3 $MEM0_SCRIPT list"
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
        echo -e "  4) ${B_GREEN}Install Embedding Model${NC}"
        echo -e "  5) ${B_GREEN}Start Embedding Server${NC}"
        echo -e "  6) ${B_YELLOW}Stop Embedding Server${NC}"
        echo -e "  7) ${B_YELLOW}Upgrade mem0ai${NC}"
        echo -e "  8) ${B_RED}Reset / Uninstall${NC}"
        echo -e "  9) Back"
        echo ""
        local choice=""
        read -r -p "  Action: " choice
        case $choice in
            1) _mem0_install ;;
            2) _mem0_configure ;;
            3) _mem0_test ;;
            4) _mem0_install_embedding_model ;;
            5) _mem0_start_embedding_server ;;
            6) _mem0_stop_embedding_server ;;
            7) _mem0_upgrade ;;
            8) _mem0_reset ;;
            9) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}
