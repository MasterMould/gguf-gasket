#!/bin/bash
# lib/updates.sh — Script self-update checker
# Requires: globals.sh

check_for_updates() {
    draw_header
    echo -e "${B_CYAN}[ 🔄  LLAMA MANAGER UPDATE CHECK ]${NC}"
    echo ""

    local REPO_RAW="https://raw.githubusercontent.com/MasterMould/gguf-gasket/main/llama_manager.sh"
    local SCRIPT_PATH
    SCRIPT_PATH="$(realpath "$0")" || SCRIPT_PATH="$0"

    echo -e "  Checking ${B_CYAN}${REPO_RAW}${NC}…"
    echo ""

    local remote_content
    if ! remote_content=$(curl -fsSL "$REPO_RAW" 2>/dev/null); then
        ERR "Could not reach GitHub. Check your network connection."
        read -p "Press Enter to return..."
        return
    fi

    local local_ver remote_ver
    local_ver=$(grep -m1 'LLAMA COMMAND CENTER' "$SCRIPT_PATH" 2>/dev/null \
        | grep -oP 'v[\d.]+' | head -1 || echo "unknown")
    remote_ver=$(echo "$remote_content" \
        | grep -m1 'LLAMA COMMAND CENTER' \
        | grep -oP 'v[\d.]+' | head -1 || echo "unknown")

    echo -e "  Installed : ${B_YELLOW}${local_ver}${NC}"
    echo -e "  Available : ${B_YELLOW}${remote_ver}${NC}"
    echo ""

    local changed_lines
    changed_lines=$(diff <(cat "$SCRIPT_PATH") <(echo "$remote_content") \
        | grep -c '^[<>]' 2>/dev/null || echo 0)

    if (( changed_lines == 0 )); then
        OK "Script is identical to the repository — no update needed."
        echo ""
        read -p "Press Enter to return..."
        return
    fi

    echo -e "  ${B_GREEN}Update available — ${changed_lines} line(s) differ from GitHub.${NC}"
    echo ""

    diff --unified=0 <(cat "$SCRIPT_PATH") <(echo "$remote_content") 2>/dev/null \
        | grep -E '^[+-]' | grep -v '^[+-]{3}' | head -30 \
        | sed 's/^+/  + /; s/^-/  - /'
    echo ""

    read -rp "  Update llama_manager.sh to the latest version? (y/n): " do_update
    if [[ "${do_update,,}" != "y" ]]; then
        echo "  Skipped."
        sleep 1; return
    fi

    local backup="${SCRIPT_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SCRIPT_PATH" "$backup" || { ERR "Could not create backup at $backup."; return 1; }
    OK "Backup saved: $backup"

    echo "$remote_content" > "$SCRIPT_PATH" \
        && chmod +x "$SCRIPT_PATH" \
        || { ERR "Failed to write update — restoring backup."; cp "$backup" "$SCRIPT_PATH"; return 1; }

    OK "Update applied. Restarting script…"
    sleep 1
    exec "$SCRIPT_PATH"
}
