#!/bin/bash
# lib/chat.sh — Model selection, GPU layer picker, and terminal chat
# Requires: globals.sh, detect.sh

# ================================================================
#  GPU LAYER OFFLOAD SELECTOR
# ================================================================
prompt_gpu_layers() {
    local current_gpu="$1"
    local default_ngl=0
    [[ "$current_gpu" != "CPU" ]] && default_ngl=99

    echo -e "\n${B_CYAN}GPU Layer Offload:${NC}" >&2
    echo -e "  1)  0  — CPU only (no VRAM used)" >&2
    echo -e "  2) 16  — Partial offload (low VRAM, e.g. 4 GB)" >&2
    echo -e "  3) 32  — Moderate offload (e.g. 8 GB VRAM)" >&2
    echo -e "  4) 99  — Full offload  (recommended for GPU)" >&2
    echo -e "  5) Custom" >&2
    local ngl_choice=""
    read -r -p "Select [1-5] (default: $default_ngl layers): " ngl_choice

    case $ngl_choice in
        1) echo "0" ;;
        2) echo "16" ;;
        3) echo "32" ;;
        4) echo "99" ;;
        5)
           local custom_ngl=""
           read -r -p "Enter number of layers: " custom_ngl
           if [[ "$custom_ngl" =~ ^[0-9]+$ ]]; then
               echo "$custom_ngl"
           else
               WARN "Invalid input. Using default ($default_ngl)." >&2
               echo "$default_ngl"
           fi
           ;;
        "") echo "$default_ngl" ;;
        *)  echo "$default_ngl" ;;
    esac
}

# ================================================================
#  MODEL SELECTION HELPER
# ================================================================
select_model() {
    local prompt_text="$1"
    local models_found=0
    for file in "$MODEL_DIR"/*.gguf; do
        [[ -f "$file" ]] && { models_found=1; break; }
    done

    if [[ $models_found -eq 0 ]]; then
        echo -e "${B_RED}No models found in $MODEL_DIR — download one first.${NC}" >&2
        sleep 2
        return 1
    fi

    local models_arr=("$MODEL_DIR"/*.gguf)
    local menu_items=("${models_arr[@]}" "── Cancel / Back ──")
    PS3="$prompt_text"
    local selected
    select selected in "${menu_items[@]}"; do
        if [[ -z "$selected" ]]; then
            echo "Invalid selection. Try again (or pick the last option to cancel)." >&2
        elif [[ "$selected" == "── Cancel / Back ──" ]]; then
            return 1
        else
            break
        fi
    done
    echo "$selected"
}

# ================================================================
#  TERMINAL CHAT
# ================================================================
chat_mode() {
    draw_header
    load_settings
    local current_gpu
    current_gpu=$(detect_gpu)

    # Intel SYCL pre-flight: check render group membership
    if [[ "$current_gpu" == "INTEL" ]]; then
        if ! id -Gn 2>/dev/null | grep -qw "render"; then
            echo -e ""
            echo -e "${B_RED}╔══════════════════════════════════════════════╗${NC}"
            echo -e "${B_RED}║  ⚠  Intel GPU — 'render' group missing       ║${NC}"
            echo -e "${B_RED}╠══════════════════════════════════════════════╣${NC}"
            echo -e "${B_RED}║${NC}  SYCL needs /dev/dri/render access.          ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  The build added you to 'render' but group   ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  membership needs a ${B_YELLOW}full log-out + log-in${NC}.   ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  After re-login, SYCL will find your GPU.    ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  To continue now with ${B_YELLOW}CPU fallback${NC}:          ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}    Select 0 GPU layers at the next prompt.   ${B_RED}║${NC}"
            echo -e "${B_RED}╚══════════════════════════════════════════════╝${NC}"
            echo ""
            read -rp "  Continue anyway? (y/n): " grp_cont
            [[ "${grp_cont,,}" != "y" ]] && return
        fi
    fi

    local model
    model=$(select_model "Select model for chat [#]: ") || return

    local ngl
    ngl=$(prompt_gpu_layers "$current_gpu")

    echo -e "${B_CYAN}Launching chat with $(basename "$model")${NC}"
    echo -e "${B_YELLOW}  Context: $context_size tokens | GPU layers: $ngl${NC}"
    echo -e "${B_YELLOW}  (Type /bye to quit or Ctrl+C to force exit)${NC}"
    echo -e "${B_YELLOW}  --no-context-shift: chat will STOP when context window is full${NC}"

    # Capture stderr synchronously — process substitution is async and may be
    # empty when read immediately after the command. Direct redirect is reliable.
    # SYCL_PI_TRACE renamed to SYCL_UR_TRACE in oneAPI 2024+; set both to 0 to
    # suppress GDB-on-exception across all oneAPI versions.
    local stderr_log
    stderr_log=$(mktemp /tmp/llama_chat_stderr.XXXXXX)
    local chat_exit=0

    SYCL_PI_TRACE=0 \
    SYCL_UR_TRACE=0 \
    ONEAPI_DEVICE_SELECTOR=level_zero:gpu \
    "$BUILD_DIR/bin/llama-cli" \
        -c "$context_size" \
        -m "$model" \
        -ngl "$ngl" \
        -cnv --prio 2 \
        --no-context-shift \
        2>"$stderr_log" \
        || chat_exit=$?

    # Echo captured stderr so the user sees it, then use it for diagnosis
    cat "$stderr_log" >&2

    if (( chat_exit != 0 )); then
        echo -e ""
        local stderr_content
        stderr_content=$(cat "$stderr_log" 2>/dev/null || true)
        rm -f "$stderr_log"

        if echo "$stderr_content" | grep -qi "No device of requested type\|no devices\|SYCL.*not found\|level.zero.*error"; then
            echo -e "${B_RED}╔══════════════════════════════════════════════╗${NC}"
            echo -e "${B_RED}║  ✖  SYCL: No GPU device found (exit $chat_exit)$(printf '%*s' $((16 - ${#chat_exit})) '')║${NC}"
            echo -e "${B_RED}╠══════════════════════════════════════════════╣${NC}"
            echo -e "${B_RED}║${NC}  The SYCL runtime could not see any GPU.     ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  Most likely cause: not yet in 'render' group${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  Fix: ${B_YELLOW}log out and log back in${NC}, then retry.  ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  Or use ${B_YELLOW}0 GPU layers${NC} to run on CPU instead. ${B_RED}║${NC}"
            echo -e "${B_RED}╚══════════════════════════════════════════════╝${NC}"
        elif echo "$stderr_content" | grep -qi "context.shift\|context full\|KV cache\|kv.cache"; then
            echo -e "${B_RED}╔══════════════════════════════════════════════╗${NC}"
            echo -e "${B_RED}║  Chat ended — context window full (exit $chat_exit)$(printf '%*s' $((7 - ${#chat_exit})) '')║${NC}"
            echo -e "${B_RED}╠══════════════════════════════════════════════╣${NC}"
            echo -e "${B_RED}║${NC}  Context: ${B_YELLOW}$context_size tokens${NC} was exhausted.$(printf '%*s' $((12 - ${#context_size})) '')${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  Increase it in ${B_YELLOW}Settings → Context Size${NC}.     ${B_RED}║${NC}"
            echo -e "${B_RED}╚══════════════════════════════════════════════╝${NC}"
        else
            echo -e "${B_RED}╔══════════════════════════════════════════════╗${NC}"
            echo -e "${B_RED}║  Chat ended (exit code $chat_exit)$(printf '%*s' $((31 - ${#chat_exit})) '')║${NC}"
            echo -e "${B_RED}╠══════════════════════════════════════════════╣${NC}"
            echo -e "${B_RED}║${NC}  Last error lines shown above. For full log: ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  use ${B_YELLOW}menu option 8${NC} → View Forensic Logs.    ${B_RED}║${NC}"
            echo -e "${B_RED}║${NC}  If GPU layers > 0, try ${B_YELLOW}0 layers (CPU)${NC}.     ${B_RED}║${NC}"
            echo -e "${B_RED}╚══════════════════════════════════════════════╝${NC}"
        fi
    else
        rm -f "$stderr_log"
    fi

    read -p "Press Enter to return to menu..."
}
