#!/bin/bash
# lib/download.sh — Background download engine and model browser
# Requires: globals.sh

# ── Find best available terminal emulator ─────────────────────────────────
find_terminal() {
    for term in x-terminal-emulator gnome-terminal xterm konsole \
                xfce4-terminal lxterminal mate-terminal; do
        command -v "$term" &>/dev/null && echo "$term" && return
    done
    echo ""
}

# ── Download status for the main menu status bar ──────────────────────────
show_download_status() {
    [[ -d "$DL_DIR" ]] || return 0
    local active=0 done_count=0 failed=0
    for f in "$DL_DIR"/*.status; do
        [[ -f "$f" ]] || continue
        local st
        st=$(cat "$f" 2>/dev/null || echo "")
        case "$st" in
            RUNNING)   (( active++ )) ;;
            DONE)      (( done_count++ )) ;;
            FAILED)    (( failed++ )) ;;
        esac
    done
    (( active > 0 ))     && echo -e "  Downloads:     ${B_YELLOW}⬇  $active in progress${NC}"
    (( done_count > 0 )) && echo -e "  Downloads:     ${B_GREEN}✔  $done_count completed (clear with option 2)${NC}"
    (( failed > 0 ))     && echo -e "  Downloads:     ${B_RED}✖  $failed failed (check logs)${NC}"
}

# ── Download worker — runs inside the spawned terminal window ─────────────
_download_worker() {
    local url="$1" filename="$2" dest="$3" state_file="$4"
    echo "RUNNING" > "$state_file"
    echo ""
    echo "  Downloading: $filename"
    echo "  To:          $dest/$filename"
    echo "  Source:      $url"
    echo ""
    if curl -L --fail --progress-bar "$url" -o "$dest/$filename.part"; then
        mv "$dest/$filename.part" "$dest/$filename"
        echo "DONE" > "$state_file"
        echo ""
        echo "  ✔ Download complete: $dest/$filename"
    else
        echo "FAILED" > "$state_file"
        rm -f "$dest/$filename.part"
        echo ""
        echo "  ✖ Download FAILED for $filename"
        echo "  URL may be invalid, gated, or a network issue."
    fi
    echo ""
    read -rp "  Press Enter to close this window..."
}
export -f _download_worker

# ── Spawn a download in a new terminal window ─────────────────────────────
spawn_download() {
    local url="$1" filename="$2"
    mkdir -p "$MODEL_DIR" "$DL_DIR"

    if [[ -f "$MODEL_DIR/$filename" ]]; then
        echo -e "${B_YELLOW}[!] $filename already exists. Skipping.${NC}"
        sleep 2; return
    fi

    local safe_name="${filename//[^a-zA-Z0-9._-]/_}"
    local state_file="$DL_DIR/${safe_name}.status"
    echo "QUEUED" > "$state_file"

    local term
    term=$(find_terminal)

    if [[ -z "$term" ]]; then
        WARN "No terminal emulator found. Downloading in background (no progress bar)."
        (
            if curl -L --fail -s "$url" -o "$MODEL_DIR/$filename.part"; then
                mv "$MODEL_DIR/$filename.part" "$MODEL_DIR/$filename"
                echo "DONE" > "$state_file"
            else
                echo "FAILED" > "$state_file"
                rm -f "$MODEL_DIR/$filename.part"
            fi
        ) >> "$LOG_FILE" 2>&1 &
        OK "Download started in background (PID $!). Check status on main menu."
        sleep 2
        return
    fi

    case "$term" in
        gnome-terminal)
            gnome-terminal -- bash -c \
                "_download_worker $(printf '%q' "$url") \
                 $(printf '%q' "$filename") \
                 $(printf '%q' "$MODEL_DIR") \
                 $(printf '%q' "$state_file")" &
            ;;
        xterm|lxterminal|mate-terminal|xfce4-terminal|konsole)
            "$term" -e "bash -c \"_download_worker \
                $(printf '%q' "$url") \
                $(printf '%q' "$filename") \
                $(printf '%q' "$MODEL_DIR") \
                $(printf '%q' "$state_file")\"" &
            ;;
        x-terminal-emulator)
            x-terminal-emulator -e "bash -c \"_download_worker \
                $(printf '%q' "$url") \
                $(printf '%q' "$filename") \
                $(printf '%q' "$MODEL_DIR") \
                $(printf '%q' "$state_file")\"" &
            ;;
    esac

    OK "Download window opened for $filename — you can continue using the menu."
    sleep 2
}

# ================================================================
#  MODEL BROWSER
# ================================================================
download_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ 📥  MODEL DOWNLOADER ]${NC}"
        echo ""

        # Show active downloads
        if [[ -d "$DL_DIR" ]]; then
            local any_shown=0
            for f in "$DL_DIR"/*.status; do
                [[ -f "$f" ]] || continue
                local name st
                name=$(basename "$f" .status)
                st=$(cat "$f" 2>/dev/null || echo "?")
                case "$st" in
                    RUNNING) echo -e "  ${B_YELLOW}⬇ DOWNLOADING:${NC} $name" ;;
                    DONE)    echo -e "  ${B_GREEN}✔ COMPLETE:${NC}    $name" ;;
                    FAILED)  echo -e "  ${B_RED}✖ FAILED:${NC}      $name" ;;
                    QUEUED)  echo -e "  ${B_CYAN}⏳ QUEUED:${NC}      $name" ;;
                esac
                any_shown=1
            done
            (( any_shown )) && echo ""
        fi

        echo "  Select model to download:"
        echo "  1) gemma-4-E4B-it-OBLITERATED  (Smart mid-size — Google Q5_K_M ~5.76 GB)"
        echo "  2) Mistral-7B  (Industry standard — TheBloke Q4_K_M ~4.1 GB)"
        echo "  3) Phi-3-Mini  (Tiny but powerful — bartowski Q4_K_M ~2.2 GB)"
        echo "  4) Custom URL  (Paste direct GGUF link)"
        echo "  5) Clear completed/failed status entries"
        echo "  6) Back"
        echo ""
        local d=""
        read -r -p "  Select [1-6]: " d

        local url="" filename=""
        case $d in
            1) url="https://huggingface.co/OBLITERATUS/gemma-4-E4B-it-OBLITERATED/blob/main/gemma-4-E4B-it-OBLITERATED-Q5_K_M.gguf"
               filename="gemma-4-E4B-it-OBLITERATED-Q5_K_M.gguf" ;;
            2) url="https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
               filename="mistral-7b.gguf" ;;
            3) url="https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF/resolve/main/Phi-3-mini-4k-instruct-Q4_K_M.gguf"
               filename="phi3-mini.gguf" ;;
            4)
               read -r -p "  Paste GGUF URL: " url
               read -r -p "  Save as filename (.gguf): " filename
               if [[ -z "$url" || -z "$filename" ]]; then
                   echo -e "${B_RED}Invalid input.${NC}"; sleep 1; continue
               fi
               [[ "$filename" != *.gguf ]] && filename="${filename}.gguf"
               ;;
            5)
               if [[ -d "$DL_DIR" ]]; then
                   for f in "$DL_DIR"/*.status; do
                       [[ -f "$f" ]] || continue
                       local st; st=$(cat "$f" 2>/dev/null || echo "")
                       [[ "$st" == "DONE" || "$st" == "FAILED" ]] && rm -f "$f"
                   done
                   OK "Cleared completed/failed entries."
               fi
               sleep 1; continue
               ;;
            6) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1; continue ;;
        esac

        spawn_download "$url" "$filename"
    done
}
