#!/bin/bash
# Menu module — auto-discovered by llama_manager.sh
MENU_LABEL="SearXNG — Self-Hosted Search"
MENU_FN="searxng_menu"
MENU_COLOR='${B_GREEN}'
MENU_ORDER=84

# ================================================================
#  SearXNG — Self-Hosted Meta Search Engine
# ================================================================

SEARXNG_DIR="$HOME/ai_stack/searxng"
SEARXNG_CONFIG="$SEARXNG_DIR/settings.yml"
SEARXNG_ENV="$SEARXNG_DIR/.env"
SEARXNG_PID_FILE="/tmp/searxng.pid"
SEARXNG_CONTAINER="llama-searxng"
SEARXNG_PORT=8888
SEARXNG_LOG="$SEARXNG_DIR/searxng.log"

# ================================================================
#  HELPERS
# ================================================================

_searxng_docker_available() {
    command -v docker &>/dev/null && docker info &>/dev/null 2>&1
}

_searxng_container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${SEARXNG_CONTAINER}$"
}

_searxng_container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${SEARXNG_CONTAINER}$"
}

_searxng_status() {
    echo -e "  ${B_CYAN}SearXNG status:${NC}"

    if ! _searxng_docker_available; then
        echo -e "    Docker   : ${B_RED}not available${NC}"
    elif _searxng_container_running; then
        echo -e "    Container: ${B_GREEN}running${NC} ($SEARXNG_CONTAINER)"
        echo -e "    URL      : ${B_CYAN}http://127.0.0.1:${SEARXNG_PORT}${NC}"
        echo -e "    JSON API : ${B_CYAN}http://127.0.0.1:${SEARXNG_PORT}/search?q=test&format=json${NC}"
    elif _searxng_container_exists; then
        echo -e "    Container: ${B_YELLOW}stopped${NC} ($SEARXNG_CONTAINER)"
    else
        echo -e "    Container: ${B_RED}not created${NC}"
    fi

    if [[ -f "$SEARXNG_CONFIG" ]]; then
        echo -e "    Config   : $SEARXNG_CONFIG"
    else
        echo -e "    Config   : ${B_YELLOW}not configured${NC}"
    fi

    # Load port from env file if it exists
    if [[ -f "$SEARXNG_ENV" ]]; then
        local p
        p=$(grep '^SEARXNG_PORT=' "$SEARXNG_ENV" 2>/dev/null | cut -d= -f2)
        [[ -n "$p" ]] && SEARXNG_PORT="$p"
    fi
}

_searxng_generate_secret() {
    openssl rand -hex 32 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(32))"
}

_searxng_write_settings() {
    local secret="$1"
    
    # FIX 1: Validate secret is not empty
    [[ -z "$secret" ]] && { echo "Error: Failed to generate secret key" >&2; return 1; }
    
    mkdir -p "$SEARXNG_DIR"

    cat > "$SEARXNG_CONFIG" << YAMLEOF
# SearXNG settings — managed by LLAMA COMMAND CENTER
# Full reference: https://docs.searxng.org/admin/settings/

use_default_settings: true

general:
  debug: false
  instance_name: "llama-searxng"

server:
  secret_key: "${secret}"
  bind_address: "0.0.0.0"
  port: ${SEARXNG_PORT}
  image_proxy: false

ui:
  default_theme: simple
  default_locale: en

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"

# JSON API — required for LLM tool-calling integration
formats:
  - html
  - json

# Disable rate limiting so llama-server can query without throttling
limiter: false

# Engines — a curated set of reliable sources
engines:
  - name: google
    engine: google
    shortcut: g
  - name: bing
    engine: bing
    shortcut: b
  - name: duckduckgo
    engine: duckduckgo
    shortcut: d
  - name: wikipedia
    engine: wikipedia
    shortcut: w
    categories: general
  - name: github
    engine: github
    shortcut: gh
YAMLEOF
    # FIX 2: Secure the config file
    chmod 600 "$SEARXNG_CONFIG"
}

# ================================================================
#  INSTALL (Docker path)
# ================================================================

_searxng_install_docker() {
    draw_header
    echo -e "${B_CYAN}[ SearXNG — Install via Docker ]${NC}"
    echo ""

    if ! command -v docker &>/dev/null; then
        WARN "Docker not found. Installing Docker…"
        echo ""
        curl -fsSL https://get.docker.com | sudo sh 2>&1 | tail -5
        sudo usermod -aG docker "$USER"
        echo ""
        OK "Docker installed."
        WARN "Re-login required for docker group membership."
        WARN "After re-login, re-run this option to create the container."
        sleep 4; return
    fi

    if ! docker info &>/dev/null 2>&1; then
        ERR "Docker daemon is not running."
        echo "  Start it: sudo systemctl start docker"
        read -p "Press Enter to return..."; return
    fi

    echo "  Container name : $SEARXNG_CONTAINER"
    echo "  Port           : $SEARXNG_PORT"
    echo "  Config dir     : $SEARXNG_DIR"
    echo ""

    read -r -p "  Install and start SearXNG now? (y/n): " confirm
    [[ "${confirm,,}" != "y" ]] && return

    # Remove old container if exists
    if _searxng_container_exists; then
        WARN "Removing existing container…"
        docker rm -f "$SEARXNG_CONTAINER" &>/dev/null || true
    fi

    # Generate secret and write config
    local secret
    secret=$(_searxng_generate_secret)
    # FIX 3: Check if secret generation failed
    [[ -z "$secret" ]] && { ERR "Failed to generate secret key. Aborting."; return 1; }
    _searxng_write_settings "$secret"

    # Persist port and secret to env file
    {
        echo "SEARXNG_PORT=$SEARXNG_PORT"
        echo "SEARXNG_SECRET=$secret"
    } > "$SEARXNG_ENV"
    chmod 600 "$SEARXNG_ENV"
    OK "Config written with secure secret key."

    STEP "Pulling SearXNG image…"
    # FIX 4: Add error handling for docker pull
    if ! docker pull searxng/searxng:latest; then
        ERR "Failed to pull SearXNG image. Check your connection."
        sleep 4; return
    fi

    STEP "Creating container…"
    # FIX 5: Remove -p binding to 127.0.0.1 for LLM access from container
    docker run -d \
        --name "$SEARXNG_CONTAINER" \
        --restart unless-stopped \
        -p "${SEARXNG_PORT}:${SEARXNG_PORT}" \
        -v "${SEARXNG_DIR}:/etc/searxng:rw" \
        -e "SEARXNG_SECRET=${secret}" \
        searxng/searxng:latest 2>&1 | tee -a "$SEARXNG_LOG"

    echo ""
    STEP "Waiting for SearXNG to start…"
    local ready=0
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if curl -sf "http://127.0.0.1:${SEARXNG_PORT}/healthz" &>/dev/null 2>&1 || \
           curl -sf "http://127.0.0.1:${SEARXNG_PORT}/" &>/dev/null 2>&1; then
            ready=1; break
        fi
    done

    if (( ready )); then
        echo ""
        OK "SearXNG is running."
        echo ""
        echo -e "  ${B_GREEN}Web UI :${NC} http://127.0.0.1:${SEARXNG_PORT}"
        echo -e "  ${B_GREEN}JSON   :${NC} http://127.0.0.1:${SEARXNG_PORT}/search?q=test&format=json"
        echo ""
        echo "  Test with:"
        echo "  curl -s 'http://127.0.0.1:${SEARXNG_PORT}/search?q=llama+llm&format=json' | python3 -m json.tool | head -40"
    else
        WARN "Startup not confirmed. Check: docker logs $SEARXNG_CONTAINER"
    fi

    # FIX 6: Use correct log variable name
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] searxng installed, port=$SEARXNG_PORT" >> "$SEARXNG_LOG" 2>/dev/null || true
    sleep 4
}

# ================================================================
#  START / STOP / RESTART
# ================================================================

_searxng_start() {
    if ! _searxng_docker_available; then
        ERR "Docker not available."; sleep 2; return; fi
    if ! _searxng_container_exists; then
        WARN "Container not found. Run Install first."; sleep 2; return; fi
    docker start "$SEARXNG_CONTAINER" &>/dev/null \
        && OK "SearXNG started." || ERR "Failed to start."
    sleep 2
}

_searxng_stop() {
    if ! _searxng_docker_available; then
        ERR "Docker not available."; sleep 2; return; fi
    docker stop "$SEARXNG_CONTAINER" &>/dev/null \
        && OK "SearXNG stopped." || ERR "Failed to stop."
    sleep 2
}

_searxng_restart() {
    if ! _searxng_docker_available; then
        ERR "Docker not available."; sleep 2; return; fi
    # FIX 7: Check container exists before restarting
    if _searxng_container_exists; then
        docker restart "$SEARXNG_CONTAINER" &>/dev/null \
            && OK "SearXNG restarted." || ERR "Failed to restart."
    else
        ERR "Container not found. Run Install first."
    fi
    sleep 2
}

# ================================================================
#  CONFIGURE
# ================================================================

_searxng_configure() {
    draw_header
    echo -e "${B_CYAN}[ SearXNG — Configure ]${NC}"
    echo ""
    echo "  1) Change port (current: $SEARXNG_PORT)"
    echo "  2) Rotate secret key"
    echo "  3) Edit settings.yml (nano)"
    echo "  4) Toggle limiter on/off"
    echo "  5) Back"
    local c=""
    read -r -p "  Select [1-5]: " c

    case $c in
        1)
            read -r -p "  New port (1024–65535): " newport
            if [[ "$newport" =~ ^[0-9]+$ ]] && (( newport >= 1024 && newport <= 65535 )); then
                SEARXNG_PORT=$newport
                sed -i "s/^SEARXNG_PORT=.*/SEARXNG_PORT=$newport/" "$SEARXNG_ENV" 2>/dev/null || \
                    echo "SEARXNG_PORT=$newport" >> "$SEARXNG_ENV"
                # Rewrite settings with new port
                local secret
                secret=$(grep '^SEARXNG_SECRET=' "$SEARXNG_ENV" 2>/dev/null | cut -d= -f2)
                [[ -z "$secret" ]] && secret=$(_searxng_generate_secret)
                _searxng_write_settings "$secret"
                OK "Port set to $newport. Recreate container to apply (option 1 in Install)."
            else
                WARN "Invalid port."
            fi
            ;;
        2)
            local new_secret
            new_secret=$(_searxng_generate_secret)
            [[ -z "$new_secret" ]] && { ERR "Failed to generate new secret. Aborting."; return 1; }
            sed -i "s/^SEARXNG_SECRET=.*/SEARXNG_SECRET=$new_secret/" "$SEARXNG_ENV" || \
                echo "SEARXNG_SECRET=$new_secret" >> "$SEARXNG_ENV"
            _searxng_write_settings "$new_secret"
            # FIX 8: Add container existence check before restart
            if _searxng_container_exists; then
                _searxng_restart
            else
                ERR "No running container found. Recreate container to apply new secret."
            fi
            OK "Secret key rotated and container restarted."
            ;;
        3)
            if [[ ! -f "$SEARXNG_CONFIG" ]]; then
                WARN "Config not found. Run Install first."; sleep 2; return
            fi
            command -v nano &>/dev/null && nano "$SEARXNG_CONFIG" || {
                cat "$SEARXNG_CONFIG"
                WARN "nano not found. Edit manually: $SEARXNG_CONFIG"
            }
            # FIX 9: Add check before restart
            if _searxng_container_exists; then
                _searxng_restart
            else
                ERR "No container found to restart."
            fi
            ;;
        4)
            if grep -q "limiter: false" "$SEARXNG_CONFIG" 2>/dev/null; then
                sed -i 's/limiter: false/limiter: true/' "$SEARXNG_CONFIG"
                OK "Limiter enabled."
            else
                sed -i 's/limiter: true/limiter: false/' "$SEARXNG_CONFIG"
                OK "Limiter disabled."
            fi
            # FIX 10: Add container existence check before restart
            if _searxng_container_exists; then
                _searxng_restart
            else
                ERR "No container found. Run Install first."
            fi
            ;;
        5) return ;;
        *) WARN "Invalid." ;;
    esac
    sleep 2
}

# ================================================================
#  TEST
# ================================================================

_searxng_test() {
    draw_header
    echo -e "${B_CYAN}[ SearXNG — Test ]${NC}"
    echo ""

    local base="http://127.0.0.1:${SEARXNG_PORT}"

    STEP "1/3  Checking SearXNG is reachable…"
    if ! curl -sf --max-time 5 "${base}/" &>/dev/null; then
        ERR "SearXNG not reachable at ${base}"
        WARN "Is the container running? Use option 2 to start it."
        read -p "Press Enter to return..."; return
    fi
    OK "Reachable at ${base}"

    STEP "2/3  Testing JSON search API…"
    local result
    result=$(curl -sf --max-time 10 \
        "${base}/search?q=llama+AI&format=json" 2>/dev/null) || true

    if [[ -z "$result" ]]; then
        ERR "JSON API returned no response."
        WARN "Check that 'formats: [json]' is in $SEARXNG_CONFIG"
        read -p "Press Enter to return..."; return
    fi

    local result_count
    result_count=$(echo "$result" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(len(d.get('results',[])))" \
        2>/dev/null || echo "?")
    OK "JSON API returned ${result_count} results."

    STEP "3/3  Showing first 3 results…"
    echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('results', [])[:3]:
    print(f\"  [{r.get('engine','?')}] {r.get('title','?')}\")
    print(f\"    {r.get('url','')}\")
" 2>/dev/null || echo "  (could not parse results)"

    echo ""
    OK "SearXNG JSON API is working."
    echo ""
    echo "  Integration endpoint for llama tool-calling:"
    echo -e "  ${B_CYAN}${base}/search?q={query}&format=json${NC}"
    echo ""
    echo "  Example curl:"
    echo "  curl -s '${base}/search?q=your+query&format=json' | python3 -m json.tool"
    read -p "Press Enter to return..."
}

# ================================================================
#  VIEW LOGS
# ================================================================

_searxng_logs() {
    draw_header
    echo -e "${B_CYAN}[ SearXNG — Logs ]${NC}"
    echo ""
    if _searxng_docker_available && _searxng_container_exists; then
        echo "  -- Docker container logs (last 30 lines) --"
        docker logs --tail 30 "$SEARXNG_CONTAINER" 2>&1
    else
        echo "  (No container found)"
    fi
    echo ""
    read -p "Press Enter to return..."
}

# ================================================================
#  UNINSTALL
# ================================================================

_searxng_uninstall() {
    draw_header
    echo -e "${B_CYAN}[ SearXNG — Uninstall ]${NC}"
    echo ""
    WARN "This will stop and remove the Docker container and delete $SEARXNG_DIR"
    read -r -p "  Type 'yes' to confirm: " conf
    [[ "$conf" != "yes" ]] && { echo "Cancelled."; sleep 1; return; }

    if _searxng_docker_available; then
        docker rm -f "$SEARXNG_CONTAINER" &>/dev/null && OK "Container removed." || true
    fi
    # FIX 11: Add cleanup for systemd service files
    if [ -f "/etc/systemd/system/llama-searxng.service" ]; then
        sudo systemctl disable llama-searxng 2>/dev/null || true
        sudo rm -f /etc/systemd/system/llama-searxng.service 2>/dev/null || true
        sudo systemctl daemon-reload 2>/dev/null || true
    fi
    
    rm -rf "$SEARXNG_DIR"
    OK "SearXNG fully removed."
    sleep 2
}

# ================================================================
#  MAIN MENU
# ================================================================
searxng_menu() {
    # Load port from env if persisted
    if [[ -f "$SEARXNG_ENV" ]]; then
        local _p
        _p=$(grep '^SEARXNG_PORT=' "$SEARXNG_ENV" 2>/dev/null | cut -d= -f2)
        [[ -n "$_p" ]] && SEARXNG_PORT="$_p"
    fi

    while true; do
        draw_header
        echo -e "${B_GREEN}[ 🔍  SearXNG — Self-Hosted Search Engine ]${NC}"
        echo ""
        _searxng_status
        echo ""
        echo -e "------------------------------------------------------"

        if _searxng_container_running 2>/dev/null; then
            echo -e "  1) ${B_RED}Stop SearXNG${NC}"
        elif _searxng_container_exists 2>/dev/null; then
            echo -e "  1) ${B_GREEN}Start SearXNG${NC}"
        else
            echo -e "  1) ${B_GREEN}Install SearXNG (Docker)${NC}"
        fi

        echo -e "  2) ${B_YELLOW}Restart SearXNG${NC}"
        echo -e "  3) ${B_CYAN}Configure${NC}              (port, secret, engines)"
        echo -e "  4) ${B_CYAN}Test JSON API${NC}"
        echo -e "  5) ${B_CYAN}View Logs${NC}"
        echo -e "  6) ${B_RED}Uninstall${NC}"
        echo -e "  7) Back"
        echo ""
        local choice=""
        read -r -p "  Action: " choice
        case $choice in
            1)
                if _searxng_container_running 2>/dev/null; then
                    _searxng_stop
                elif _searxng_container_exists 2>/dev/null; then
                    _searxng_start
                else
                    _searxng_install_docker
                fi
                ;;
            2) _searxng_restart ;;
            3) _searxng_configure ;;
            4) _searxng_test ;;
            5) _searxng_logs ;;
            6) _searxng_uninstall ;;
            7) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# ================================================================
#  UTILITY FUNCTIONS
# ================================================================
# If this script is run standalone (not sourced), provide basic color definitions
if [[ -z "${B_GREEN+x}" ]]; then
    B_RED='\033[0;31m'
    B_GREEN='\033[0;32m'
    B_CYAN='\033[0;36m'
    B_YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
fi

if [[ -z "${OK+x}" ]]; then
    OK() { echo -e "${B_GREEN}[OK]${NC} $1"; }
    WARN() { echo -e "${B_YELLOW}[WARN]${NC} $1"; }
    ERR() { echo -e "${B_RED}[ERR]${NC} $1"; }
fi

if [[ -z "${STEP+x}" ]]; then
    STEP() { echo -e "${B_CYAN}[> ]${NC} $1"; }
fi

if [[ -z "${draw_header+x}" ]]; then
    draw_header() { echo ""; echo "==================================================="; }
fi
