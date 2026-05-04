#!/usr/bin/env bash

# =========================================================
# 🧠 MEMU MENU MODULE (AUTO-CONFIG ENABLED)
# =========================================================

MEMU_DIR="$INSTALL_DIR/memory_server"
MEMU_ENV="$MEMU_DIR/.venv"
MEMU_START="$MEMU_DIR/start_memory_server.sh"
MEMU_PID_FILE="$INSTALL_DIR/memu.pid"
MEMU_ENV_FILE="$MEMU_DIR/.env"

DEFAULT_LLAMA_URL="http://localhost:8080/v1"
DEFAULT_MODEL="llama"

# ── helpers ──────────────────────────────────────────────
memu_installed() { [[ -f "$MEMU_START" ]]; }

memu_running() {
    [[ -f "$MEMU_PID_FILE" ]] && kill -0 "$(cat "$MEMU_PID_FILE")" 2>/dev/null
}

memu_status_icon() { memu_installed && echo "✅" || echo "❌"; }

# =========================================================
# 🔍 AUTO DETECT
# =========================================================
memu_autodetect() {
    local url="$DEFAULT_LLAMA_URL"
    local model="$DEFAULT_MODEL"

    # detect running llama server
    if curl -s "$DEFAULT_LLAMA_URL/models" >/dev/null 2>&1; then
        url="$DEFAULT_LLAMA_URL"

        # try extract model name
        local detected_model
        detected_model=$(curl -s "$DEFAULT_LLAMA_URL/models" | jq -r '.data[0].id' 2>/dev/null || echo "")
        [[ -n "$detected_model" && "$detected_model" != "null" ]] && model="$detected_model"
    fi

    echo "$url|$model"
}

# =========================================================
# INSTALL
# =========================================================
memu_install() {
    echo "🧠 Installing memu..."
    install_memory_server || { echo "❌ install failed"; return 1; }
    echo "✅ installed"
}

# =========================================================
# AUTO CONFIGURE
# =========================================================
memu_auto_configure() {
    mkdir -p "$MEMU_DIR"

    local detected
    detected=$(memu_autodetect)

    local url="${detected%%|*}"
    local model="${detected##*|}"

    cat > "$MEMU_ENV_FILE" <<EOF
LLAMA_BASE_URL=$url
LLAMA_MODEL=$model
EOF

    echo "⚙️ Auto-config applied:"
    echo "  URL:   $url"
    echo "  Model: $model"
}

# =========================================================
# MANUAL CONFIG (fallback)
# =========================================================
memu_manual_configure() {
    echo "⚙️ Manual configuration"

    read -rp "LLAMA_BASE_URL [$DEFAULT_LLAMA_URL]: " base
    read -rp "MODEL [$DEFAULT_MODEL]: " model

    base="${base:-$DEFAULT_LLAMA_URL}"
    model="${model:-$DEFAULT_MODEL}"

    cat > "$MEMU_ENV_FILE" <<EOF
LLAMA_BASE_URL=$base
LLAMA_MODEL=$model
EOF

    echo "✅ saved"
}

# =========================================================
# START / STOP
# =========================================================
memu_start() {
    memu_installed || { echo "❌ not installed"; return; }

    if memu_running; then
        echo "⚠️ already running"
        return
    fi

    [[ -f "$MEMU_ENV_FILE" ]] || memu_auto_configure

    echo "🚀 Starting memu..."
    "$MEMU_START" &
    echo $! > "$MEMU_PID_FILE"

    sleep 1
    memu_running && echo "✅ running" || echo "❌ failed"
}

memu_stop() {
    if memu_running; then
        kill "$(cat "$MEMU_PID_FILE")" 2>/dev/null || true
        rm -f "$MEMU_PID_FILE"
        echo "🛑 stopped"
    else
        echo "⚠️ not running"
    fi
}

# =========================================================
# STATUS
# =========================================================
memu_status() {
    echo "🧠 memu status"
    echo "────────────────"

    memu_installed && echo "Install: ✅" || echo "Install: ❌"
    memu_running && echo "Running: ✅" || echo "Running: ❌"
    [[ -f "$MEMU_ENV_FILE" ]] && echo "Config:  ✅" || echo "Config:  ❌"
}

# =========================================================
# MENU
# =========================================================
menu_memu() {
    while true; do
        clear
        echo "╔══════════════════════════════════════╗"
        echo "║        🧠 MEMU CONTROL PANEL         ║"
        echo "╠══════════════════════════════════════╣"
        echo "║ Status: $(memu_status_icon)                        ║"
        echo "║ 1) Install                        ║"
        echo "║ 2) Start                          ║"
        echo "║ 3) Stop                           ║"
        echo "║ 4) Auto Configure (recommended)   ║"
        echo "║ 5) Manual Configure               ║"
        echo "║ 6) Status                         ║"
        echo "║ 0) Back                           ║"
        echo "╚══════════════════════════════════════╝"
        read -r -p "Select: " c

        case "$c" in
            1) memu_install ;;
            2) memu_start ;;
            3) memu_stop ;;
            4) memu_auto_configure ;;
            5) memu_manual_configure ;;
            6) memu_status ;;
            0) return ;;
        esac

        read -rp "Enter to continue..."
    done
}
