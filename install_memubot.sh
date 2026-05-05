#!/usr/bin/env bash

set -e

# --- Colors ---
GREEN="\033[0;32m"
CYAN="\033[0;36m"
RED="\033[0;31m"
NC="\033[0m"

# --- Config ---
MEMU_REPO="https://github.com/NevaMind-AI/memUBot.git"
GASKET_REPO="https://github.com/MasterMould/gguf-gasket.git"
INSTALL_DIR="$HOME/memubot-stack"

# --- Helpers ---
function check_requirements() {
    echo -e "${CYAN}🔍 Checking requirements...${NC}"
    command -v python3 >/dev/null || { echo -e "${RED}Python3 not found${NC}"; exit 1; }
    command -v git >/dev/null || { echo -e "${RED}Git not found${NC}"; exit 1; }
}

function setup_dirs() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
}

function clone_repos() {
    echo -e "${CYAN}📦 Cloning repositories...${NC}"

    [ ! -d "memUBot" ] && git clone "$MEMU_REPO"
    [ ! -d "gguf-gasket" ] && git clone -b dev "$GASKET_REPO"
}

function setup_venv() {
    echo -e "${CYAN}🐍 Setting up virtual environment...${NC}"

    python3 -m venv venv
    source venv/bin/activate

    pip install --upgrade pip
}

function install_memubot() {
    echo -e "${CYAN}🧠 Installing memUBot...${NC}"

    cd "$INSTALL_DIR/memUBot"
    pip install -e .
}

function install_gasket() {
    echo -e "${CYAN}🔩 Installing gguf-gasket...${NC}"

    cd "$INSTALL_DIR/gguf-gasket"
    pip install -e .
}

function manual_config() {
    echo -e "${GREEN}⚙️ Manual configuration mode${NC}"

    read -p "Enter LLM provider (openai/ollama/custom): " LLM
    read -p "Enter API key (leave blank if local): " API_KEY

    cat <<EOF > $INSTALL_DIR/.env
LLM_PROVIDER=$LLM
API_KEY=$API_KEY
EOF

    echo -e "${GREEN}Saved config to .env${NC}"
}

function auto_config() {
    echo -e "${GREEN}⚡ Auto configuration mode${NC}"

    cat <<EOF > $INSTALL_DIR/.env
LLM_PROVIDER=ollama
API_KEY=
MODEL=llama3
EOF

    echo -e "${GREEN}Auto config complete (local Ollama default)${NC}"
}

function finish() {
    echo -e "${GREEN}✅ Installation complete!${NC}"
    echo -e "${CYAN}Run:${NC}"
    echo -e "cd $INSTALL_DIR && source venv/bin/activate"
    echo -e "python memUBot/main.py  # or your entrypoint"
}

# --- Menu ---
function menu() {
    echo ""
    echo "==== memUBot Installer ===="
    echo "1) Auto Install (recommended)"
    echo "2) Manual Install (custom config)"
    echo "3) Exit"
    echo ""
    read -p "Select option: " CHOICE

    case $CHOICE in
        1)
            check_requirements
            setup_dirs
            clone_repos
            setup_venv
            install_memubot
            install_gasket
            auto_config
            finish
            ;;
        2)
            check_requirements
            setup_dirs
            clone_repos
            setup_venv
            install_memubot
            install_gasket
            manual_config
            finish
            ;;
        3)
            exit 0
            ;;
        *)
            echo "Invalid option"
            menu
            ;;
    esac
}

menu
