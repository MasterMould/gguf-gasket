#!/bin/bash
# lib/settings.sh — Runtime settings selection menus
# Requires: globals.sh

select_context_size() {
    local doubled=$(( context_size * 2 ))
    echo -e "\n${B_CYAN}Select Context Window Size:${NC}"
    echo "  1)  1024  tokens  (minimal RAM, very short conversations)"
    echo "  2)  2048  tokens"
    echo "  3)  4096  tokens"
    echo "  4)  8192  tokens  (default)"
    echo "  5) 16384  tokens"
    echo "  6) 32768  tokens  (large RAM / VRAM required)"
    echo "  7) Double current → ${doubled} tokens"
    echo "  8) Type a number manually"
    local c=""
    read -r -p "Select [1-8] (current: ${context_size}): " c
    case $c in
        1) declare -g context_size=1024 ;;
        2) declare -g context_size=2048 ;;
        3) declare -g context_size=4096 ;;
        4) declare -g context_size=8192 ;;
        5) declare -g context_size=16384 ;;
        6) declare -g context_size=32768 ;;
        7) declare -g context_size=$doubled ;;
        8)
           local custom_ctx=""
           read -r -p "  Enter context size (min 512): " custom_ctx
           if [[ "$custom_ctx" =~ ^[0-9]+$ ]] && (( custom_ctx >= 512 )); then
               declare -g context_size=$custom_ctx
           else
               WARN "Invalid value — must be a number ≥ 512. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    save_settings
    OK "Context size set to $context_size tokens."
    sleep 1
}

select_api_key_mode() {
    echo -e "\n${B_CYAN}Select API Key Mode:${NC}"
    echo "  Current mode: ${B_YELLOW}${api_key_mode}${NC}"
    echo ""
    echo "  1) Random     — new 24-char hex key generated each server start (default)"
    echo "  2) localtest  — fixed key 'localtest' for local curl/dev testing"
    echo "  3) Custom     — type your own key"
    local a=""
    read -r -p "  Select [1-3]: " a
    case $a in
        1) declare -g api_key_mode="random" ;;
        2) declare -g api_key_mode="localtest"
           WARN "Key 'localtest' is predictable — only use on localhost." ;;
        3)
           local custom_key=""
           read -r -p "  Enter API key (min 8 chars): " custom_key
           if [[ ${#custom_key} -ge 8 ]]; then
               declare -g api_key_mode="custom:${custom_key}"
           else
               WARN "Key too short (min 8 chars). Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    save_settings
    local display_mode="$api_key_mode"
    [[ "$api_key_mode" == custom:* ]] && display_mode="custom (${api_key_mode#custom:})"
    OK "API key mode set to: $display_mode"
    sleep 1
}

select_network_binding() {
    echo -e "\n${B_CYAN}Select Network Accessibility:${NC}"
    echo "  1) 127.0.0.1  — Localhost only  (secure default)"
    echo "  2) 0.0.0.0    — All interfaces  (LAN / network accessible)"
    echo "  3) Custom IP"
    local n=""
    read -r -p "Select [1-3]: " n
    case $n in
        1) declare -g visible2network="127.0.0.1" ;;
        2)
           WARN "Server will be reachable on the network. Ensure your firewall is configured."
           declare -g visible2network="0.0.0.0"
           ;;
        3)
           local custom_ip=""
           read -r -p "Enter bind address (e.g. 192.168.1.50): " custom_ip
           if [[ "$custom_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
               declare -g visible2network="$custom_ip"
           else
               WARN "Invalid IP format. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    save_settings
    OK "Network binding set to $visible2network."
    sleep 1
}

select_server_port() {
    echo -e "\n${B_CYAN}Select Server Port:${NC}"
    echo "  1) 8080  (default)"
    echo "  2) 8443  (HTTPS convention)"
    echo "  3) 9000"
    echo "  4) Custom"
    local p=""
    read -r -p "Select [1-4]: " p
    case $p in
        1) declare -g network_port="8080" ;;
        2) declare -g network_port="8443" ;;
        3) declare -g network_port="9000" ;;
        4)
           local custom_port=""
           read -r -p "Enter custom port (1024–65535): " custom_port
           if [[ "$custom_port" =~ ^[0-9]+$ ]] && (( custom_port >= 1024 && custom_port <= 65535 )); then
               declare -g network_port="$custom_port"
           else
               WARN "Invalid port. Must be 1024–65535. Unchanged."; sleep 1; return
           fi
           ;;
        *) WARN "Invalid selection. Unchanged."; sleep 1; return ;;
    esac
    save_settings
    OK "Server port set to $network_port."
    sleep 1
}

settings_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ ⚙  RUNTIME SETTINGS ]${NC}"
        echo -e ""
        echo -e "  Current values:"
        echo -e "    Context size  : ${B_YELLOW}$context_size tokens${NC}"
        echo -e "    Network bind  : ${B_YELLOW}$visible2network${NC}"
        echo -e "    Server port   : ${B_YELLOW}$network_port${NC}"
        echo -e "    API key mode  : ${B_YELLOW}$api_key_mode${NC}"
        echo -e ""
        echo -e "  1) Change Context Size"
        echo -e "  2) Change Network Binding"
        echo -e "  3) Change Server Port"
        echo -e "  4) Change API Key Mode"
        echo -e "  5) Back"
        local s=""
        read -r -p "Select [1-5]: " s
        case $s in
            1) select_context_size ;;
            2) select_network_binding ;;
            3) select_server_port ;;
            4) select_api_key_mode ;;
            5) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}
