#!/bin/bash
# lib/server.sh — HTTPS/HTTP web server management
# Requires: globals.sh, detect.sh, chat.sh (select_model, prompt_gpu_layers)

manage_server() {
    draw_header
    load_settings

    # ── Handle already-running server ─────────────────────────────────────
    if [[ -f "$SERVER_PID_FILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$existing_pid" ]] && ps -p "$existing_pid" > /dev/null 2>&1; then
            echo -e "${B_GREEN}Server is running (PID $existing_pid).${NC}"
            if [[ -f "$SERVER_INFO_FILE" ]]; then
                echo -e ""
                cat "$SERVER_INFO_FILE"
                echo -e ""
            fi
            read -p "Stop it? (y/n): " k
            if [[ "$k" == "y" ]]; then
                kill "$existing_pid" 2>/dev/null || true
                rm -f "$SERVER_PID_FILE" "$SERVER_INFO_FILE"
                echo -e "${B_YELLOW}Server stopped.${NC}"
            fi
            read -p "Press Enter to return..."
            return
        else
            rm -f "$SERVER_PID_FILE" "$SERVER_INFO_FILE"
        fi
    fi

    local current_gpu
    current_gpu=$(detect_gpu)

    # Intel render group pre-check
    if [[ "$current_gpu" == "INTEL" ]]; then
        if ! id -Gn 2>/dev/null | grep -qw "render"; then
            WARN "Not in 'render' group — SYCL will crash at startup."
            WARN "Log out and log back in, then restart the server."
            WARN "Or set GPU layers to 0 to use CPU-only mode."
            echo ""
            read -rp "  Continue anyway? (y/n): " grp_srv
            [[ "${grp_srv,,}" != "y" ]] && return
        fi
    fi

    local model
    model=$(select_model "Select model for server [#]: ") || return

    local ngl
    ngl=$(prompt_gpu_layers "$current_gpu")

    # ── TLS / HTTP mode selection ──────────────────────────────────────────
    local cert_file="$INSTALL_DIR/server.crt"
    local key_file_ssl="$INSTALL_DIR/server.key"
    local use_ssl=1

    echo ""
    echo -e "  ${B_CYAN}Server mode:${NC}"
    echo -e "  1) HTTPS (self-signed TLS — recommended, needs -k with curl)"
    echo -e "  2) HTTP  (plain, no cert — easiest for local testing)"
    local srvmode=""
    read -r -p "  Select [1-2] (default: 1): " srvmode
    [[ "$srvmode" == "2" ]] && use_ssl=0

    if (( use_ssl )); then
        local lan_ip
        lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "$lan_ip" ]] && lan_ip=""

        # Regenerate cert if missing or lacks SAN
        local needs_regen=0
        if [[ ! -f "$cert_file" ]]; then
            needs_regen=1
        elif ! openssl x509 -in "$cert_file" -noout -text 2>/dev/null \
                | grep -q "Subject Alternative Name"; then
            INFO "Existing cert has no SAN — regenerating with SAN support."
            needs_regen=1
        fi

        if (( needs_regen )); then
            echo "Generating self-signed SSL certificate with SAN…"
            local san_list="IP:127.0.0.1,DNS:localhost,DNS:llama.local"
            [[ -n "$lan_ip" && "$lan_ip" != "127.0.0.1" ]] \
                && san_list+=",IP:$lan_ip"
            [[ "$visible2network" == "0.0.0.0" || \
               ( -n "$visible2network" && \
                 "$visible2network" != "127.0.0.1" && \
                 "$visible2network" != "$lan_ip" ) ]] \
                && san_list+=",IP:$visible2network" 2>/dev/null || true

            openssl req -x509 -newkey rsa:2048 \
                -keyout "$key_file_ssl" \
                -out "$cert_file" \
                -sha256 -days 365 -nodes \
                -subj "/CN=llama.local" \
                -addext "subjectAltName=$san_list" 2>/dev/null \
                && OK "Certificate generated (SAN: $san_list)" \
                || { echo "Warning: Failed to generate SSL cert — falling back to HTTP."; use_ssl=0; }
        fi
    fi

    # ── API key ────────────────────────────────────────────────────────────
    local api_key
    case "$api_key_mode" in
        "random")    api_key=$(openssl rand -hex 12) ;;
        "localtest") api_key="localtest" ;;
        custom:*)    api_key="${api_key_mode#custom:}" ;;
        *)           api_key=$(openssl rand -hex 12) ;;
    esac

    # ── Derive display URL ─────────────────────────────────────────────────
    local display_ip
    if [[ "$visible2network" == "0.0.0.0" ]]; then
        display_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "$display_ip" ]] && display_ip="0.0.0.0"
    else
        display_ip="$visible2network"
    fi
    local scheme="http"
    (( use_ssl )) && scheme="https"
    local server_url="${scheme}://${display_ip}:${network_port}"

    # ── Build and launch server command ───────────────────────────────────
    local server_cmd=(
        "$BUILD_DIR/bin/llama-server"
        -m "$model"
        -ngl "$ngl"
        --ctx-size "$context_size"
        --host "$visible2network"
        --port "$network_port"
        --api-key "$api_key"
    )
    (( use_ssl )) && \
        server_cmd+=(--ssl-key-file "$key_file_ssl" --ssl-cert-file "$cert_file")

    SYCL_PI_TRACE=0 \
    SYCL_UR_TRACE=0 \
    ONEAPI_DEVICE_SELECTOR=level_zero:gpu \
    "${server_cmd[@]}" \
        > "$INSTALL_DIR/server.log" 2>&1 &

    local server_pid=$!
    echo "$server_pid" > "$SERVER_PID_FILE"

    # llama-server logs "listening" / "server started" / "all slots are idle"
    local started=0
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if ! ps -p "$server_pid" > /dev/null 2>&1; then
            echo -e "\n${B_RED}✖ Server process died immediately. Check logs:${NC}"
            echo -e "   $INSTALL_DIR/server.log"
            tail -n 20 "$INSTALL_DIR/server.log" 2>/dev/null || true
            rm -f "$SERVER_PID_FILE"
            read -p "Press Enter to return..."
            return 1
        fi
        grep -qiE "listening|server started|all slots are idle" \
            "$INSTALL_DIR/server.log" 2>/dev/null && { started=1; break; }
    done

    # ── Persist connection info ────────────────────────────────────────────
    {
        echo -e "  ${B_GREEN}URL  :${NC} ${B_CYAN}${server_url}${NC}"
        echo -e "  ${B_GREEN}Key  :${NC} ${B_YELLOW}${api_key}${NC}"
        echo -e "  ${B_GREEN}Model:${NC} $(basename "$model")  |  ctx ${context_size}t  |  ${ngl} GPU layers"
    } > "$SERVER_INFO_FILE"
    chmod 600 "$SERVER_INFO_FILE" 2>/dev/null || true

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PID=$server_pid | $(basename "$model") | ngl=$ngl | ctx=$context_size | bind=$visible2network | url=$server_url | key=$api_key" >> "$KEY_FILE"
    chmod 600 "$KEY_FILE" 2>/dev/null || true

    # ── Display box ────────────────────────────────────────────────────────
    local ssl_note=""
    (( use_ssl )) && ssl_note=" (use -k with curl to accept self-signed cert)"

    echo -e ""
    echo -e "${B_GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${B_GREEN}║  🚀  SERVER LIVE                             ║${NC}"
    echo -e "${B_GREEN}╠══════════════════════════════════════════════╣${NC}"
    printf "${B_GREEN}║${NC}  %-12s ${B_CYAN}%-31s${NC} ${B_GREEN}║${NC}\n" "URL:" "$server_url"
    printf "${B_GREEN}║${NC}  %-12s ${B_YELLOW}%-31s${NC} ${B_GREEN}║${NC}\n" "API Key:" "$api_key"
    printf "${B_GREEN}║${NC}  %-12s %-31s ${B_GREEN}║${NC}\n" "Context:" "${context_size} tokens"
    printf "${B_GREEN}║${NC}  %-12s %-31s ${B_GREEN}║${NC}\n" "Bind:" "$visible2network:$network_port"
    printf "${B_GREEN}║${NC}  %-12s %-31s ${B_GREEN}║${NC}\n" "TLS:" "$(( use_ssl )) && echo 'HTTPS self-signed' || echo 'HTTP plain'"
    [[ $started -eq 0 ]] && \
    printf "${B_YELLOW}║${NC}  %-44s ${B_YELLOW}║${NC}\n" "⚠  Startup not confirmed yet — check logs"
    echo -e "${B_GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${B_CYAN}Quick test:${NC}"
    if (( use_ssl )); then
        echo -e "  curl -sk ${server_url}/health -H \"Authorization: Bearer ${api_key}\""
    else
        echo -e "  curl -s ${server_url}/health -H \"Authorization: Bearer ${api_key}\""
    fi
    echo -e "  ${B_YELLOW}Note: For network access set binding to 0.0.0.0 in Settings${NC}${ssl_note}"
    echo ""
    echo -e "   Logs: $INSTALL_DIR/server.log"
    echo -e "   Keys: $KEY_FILE"
    read -p "Press Enter to return..."
}
