#!/bin/bash
# Menu module — auto-discovered by llama_manager.sh
# To add this module's entry to the main menu, ensure:
#   MENU_LABEL, MENU_FN, MENU_COLOR, and MENU_ORDER are set.
MENU_LABEL="memU — Memory Optimizer"
MENU_FN="memu_menu"
MENU_COLOR='${B_YELLOW}'
MENU_ORDER=45

# ================================================================
#  memU — Memory Usage Monitor and Optimizer for LLM Inference
#
#  Provides:
#    • Live RAM / VRAM / swap status display
#    • vm.swappiness tuning (reduce thrashing under large models)
#    • Transparent hugepages configuration (THP)
#    • nr_hugepages allocation for static hugepage pools
#    • memlock limit check / raise (prevents model pages being swapped)
#    • Drop page cache to reclaim RAM before launching a model
#    • Persist kernel settings across reboots via /etc/sysctl.d/
#    • Intel GPU VRAM status via clinfo / level-zero
#    • NVIDIA VRAM status via nvidia-smi
# ================================================================

# ── Paths ────────────────────────────────────────────────────────
MEMU_SYSCTL_FILE="/etc/sysctl.d/99-llama-memu.conf"
MEMU_LIMITS_FILE="/etc/security/limits.d/99-llama-memu.conf"

# ================================================================
#  HELPERS
# ================================================================

_memu_ram_stats() {
    echo -e "  ${B_CYAN}RAM / Swap:${NC}"
    free -h | awk '
        /^Mem:/  { printf "    Total: %-8s  Used: %-8s  Free: %-8s  Available: %s\n", $2,$3,$4,$7 }
        /^Swap:/ { printf "    Swap:  %-8s  Used: %-8s  Free: %s\n", $2,$3,$4 }
    '
}

_memu_vram_stats() {
    echo -e "  ${B_CYAN}GPU VRAM:${NC}"

    # NVIDIA
    if command -v nvidia-smi &>/dev/null; then
        local vram_info
        vram_info=$(nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free \
            --format=csv,noheader,nounits 2>/dev/null) || true
        if [[ -n "$vram_info" ]]; then
            while IFS=',' read -r name total used free; do
                printf "    NVIDIA %-28s  Total: %s MB  Used: %s MB  Free: %s MB\n" \
                    "${name// /}" "$total" "$used" "$free"
            done <<< "$vram_info"
        fi
    fi

    # Intel via clinfo
    if command -v clinfo &>/dev/null; then
        local intel_mem
        intel_mem=$(clinfo 2>/dev/null | awk '
            /Device Name.*Arc|Device Name.*UHD|Device Name.*Iris/ { dev=$0 }
            dev && /Global memory size/ { printf "    Intel %-30s  VRAM: %s\n", dev, $NF; dev="" }
        ') || true
        [[ -n "$intel_mem" ]] && echo "$intel_mem" \
            || echo "    Intel GPU: clinfo found no device (re-login may be needed)"
    fi

    # AMD via vulkaninfo
    if command -v vulkaninfo &>/dev/null; then
        local amd_mem
        amd_mem=$(vulkaninfo --summary 2>/dev/null | awk '
            /AMD|Radeon/ { dev=$0 }
            dev && /heapSize/ { printf "    AMD   %-30s  VRAM heap: %s\n", dev, $2; dev="" }
        ') || true
        [[ -n "$amd_mem" ]] && echo "$amd_mem"
    fi
}

_memu_current_kernel_settings() {
    echo -e "  ${B_CYAN}Kernel memory settings:${NC}"
    local swap
    swap=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "?")
    local thp
    thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
        | grep -oP '\[\K[^\]]+' || echo "?")
    local nr_huge
    nr_huge=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "?")
    local huge_sz
    huge_sz=$(grep Hugepagesize /proc/meminfo 2>/dev/null | awk '{print $2" "$3}' || echo "?")
    local memlock
    memlock=$(ulimit -l 2>/dev/null || echo "?")

    printf "    %-30s %s\n" "vm.swappiness:" "$swap  (default 60, recommend ≤10 for LLM)"
    printf "    %-30s %s\n" "Transparent hugepages:" "$thp  (recommend: madvise)"
    printf "    %-30s %s\n" "vm.nr_hugepages:" "$nr_huge  ($huge_sz per page)"
    printf "    %-30s %s KB\n" "memlock limit (this shell):" "$memlock"
}

_memu_estimate_hugepages() {
    # Suggest nr_hugepages based on available RAM and a reasonable model size
    local avail_kb
    avail_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}') || avail_kb=0
    local huge_kb
    huge_kb=$(grep Hugepagesize /proc/meminfo 2>/dev/null | awk '{print $2}') || huge_kb=2048
    # Reserve 4 GB for OS, allocate up to 60% of remaining for hugepages
    local reserve_kb=$(( 4 * 1024 * 1024 ))
    local usable_kb=$(( avail_kb > reserve_kb ? avail_kb - reserve_kb : 0 ))
    local suggested=$(( (usable_kb * 60 / 100) / huge_kb ))
    echo "$suggested"
}

# ================================================================
#  ACTIONS
# ================================================================

_memu_set_swappiness() {
    draw_header
    echo -e "${B_CYAN}[ memU — Set vm.swappiness ]${NC}"
    echo ""
    echo "  Current value: $(cat /proc/sys/vm/swappiness 2>/dev/null)"
    echo ""
    echo "  Swappiness controls how aggressively the kernel swaps RAM to disk."
    echo "  Lower = kernel prefers RAM, avoids thrashing during model inference."
    echo ""
    echo "  1)  1  — Swap only under extreme memory pressure (best for LLMs)"
    echo "  2) 10  — Recommended for large model servers"
    echo "  3) 20  — Balanced (light RAM pressure)"
    echo "  4) 60  — System default"
    echo "  5) Custom"
    local s=""
    read -r -p "  Select [1-5]: " s
    local val
    case $s in
        1) val=1 ;;
        2) val=10 ;;
        3) val=20 ;;
        4) val=60 ;;
        5)
           read -r -p "  Enter value (0–100): " val
           if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val > 100 )); then
               WARN "Invalid. Must be 0–100."; sleep 2; return
           fi
           ;;
        *) WARN "Cancelled."; sleep 1; return ;;
    esac

    sudo sysctl -w vm.swappiness="$val" &>/dev/null \
        && OK "vm.swappiness set to $val (active immediately)" \
        || { ERR "Failed to set vm.swappiness."; sleep 2; return; }

    read -r -p "  Persist across reboots? (y/n): " persist
    if [[ "${persist,,}" == "y" ]]; then
        echo "vm.swappiness = $val" \
            | sudo tee -a "$MEMU_SYSCTL_FILE" > /dev/null
        OK "Persisted to $MEMU_SYSCTL_FILE"
    fi
    sleep 2
}

_memu_set_hugepages() {
    draw_header
    echo -e "${B_CYAN}[ memU — Hugepages Configuration ]${NC}"
    echo ""
    echo "  Hugepages (2 MB pages) reduce TLB misses when the kernel maps large"
    echo "  model files into memory. Recommended for models > 4 GB."
    echo ""
    _memu_current_kernel_settings
    echo ""
    local suggested
    suggested=$(_memu_estimate_hugepages)
    echo "  Suggested allocation based on available RAM: ${B_YELLOW}${suggested} pages${NC}"
    echo ""
    echo "  1) Apply suggested ($suggested pages)"
    echo "  2) Custom number of pages"
    echo "  3) Set Transparent Hugepages to 'madvise' (recommended)"
    echo "  4) Disable THP entirely"
    echo "  5) Back"
    local h=""
    read -r -p "  Select [1-5]: " h

    case $h in
        1)
           sudo sysctl -w vm.nr_hugepages="$suggested" &>/dev/null \
               && OK "nr_hugepages set to $suggested" || ERR "Failed."
           read -r -p "  Persist? (y/n): " p
           [[ "${p,,}" == "y" ]] && \
               echo "vm.nr_hugepages = $suggested" | sudo tee -a "$MEMU_SYSCTL_FILE" > /dev/null \
               && OK "Persisted."
           ;;
        2)
           local custom_hp=""
           read -r -p "  Enter number of hugepages: " custom_hp
           if [[ "$custom_hp" =~ ^[0-9]+$ ]]; then
               sudo sysctl -w vm.nr_hugepages="$custom_hp" &>/dev/null \
                   && OK "nr_hugepages set to $custom_hp" || ERR "Failed."
               read -r -p "  Persist? (y/n): " p
               [[ "${p,,}" == "y" ]] && \
                   echo "vm.nr_hugepages = $custom_hp" | sudo tee -a "$MEMU_SYSCTL_FILE" > /dev/null \
                   && OK "Persisted."
           else
               WARN "Invalid input."
           fi
           ;;
        3)
           echo "madvise" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null \
               && OK "Transparent hugepages set to 'madvise'" || ERR "Failed."
           ;;
        4)
           echo "never" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null \
               && OK "Transparent hugepages disabled" || ERR "Failed."
           ;;
        5) return ;;
        *) WARN "Invalid." ;;
    esac
    sleep 2
}

_memu_set_memlock() {
    draw_header
    echo -e "${B_CYAN}[ memU — Memory Lock Limits ]${NC}"
    echo ""
    echo "  memlock controls how much RAM a process can pin (prevent from swapping)."
    echo "  Setting it to 'unlimited' ensures llama-server can lock model weights"
    echo "  in RAM and prevent costly swap reads during inference."
    echo ""
    local cur
    cur=$(ulimit -l 2>/dev/null || echo "unknown")
    echo "  Current limit (this shell): ${B_YELLOW}${cur} KB${NC}"
    echo ""

    if [[ -f "$MEMU_LIMITS_FILE" ]]; then
        echo "  Current limits file ($MEMU_LIMITS_FILE):"
        cat "$MEMU_LIMITS_FILE" | sed 's/^/    /'
        echo ""
    fi

    echo "  1) Set memlock to unlimited (recommended)"
    echo "  2) Set memlock to custom value (KB)"
    echo "  3) Back"
    local m=""
    read -r -p "  Select [1-3]: " m
    case $m in
        1)
           {
               echo "# llama memU — memory lock"
               echo "*    soft memlock unlimited"
               echo "*    hard memlock unlimited"
               echo "root soft memlock unlimited"
               echo "root hard memlock unlimited"
           } | sudo tee "$MEMU_LIMITS_FILE" > /dev/null
           OK "memlock set to unlimited in $MEMU_LIMITS_FILE"
           WARN "Re-login required for limits to take effect in new sessions."
           ulimit -l unlimited 2>/dev/null && OK "Applied to current shell." || true
           ;;
        2)
           local custom_lock=""
           read -r -p "  Enter limit in KB: " custom_lock
           if [[ "$custom_lock" =~ ^[0-9]+$ ]]; then
               {
                   echo "# llama memU — memory lock"
                   echo "*    soft memlock $custom_lock"
                   echo "*    hard memlock $custom_lock"
               } | sudo tee "$MEMU_LIMITS_FILE" > /dev/null
               OK "memlock set to ${custom_lock} KB"
           else
               WARN "Invalid."
           fi
           ;;
        3) return ;;
    esac
    sleep 2
}

_memu_drop_caches() {
    draw_header
    echo -e "${B_CYAN}[ memU — Drop Page Cache ]${NC}"
    echo ""
    echo "  Drops the Linux page cache, dentries, and inodes."
    echo "  This frees RAM before loading a large model, reducing initial"
    echo "  allocation time and swap pressure."
    echo ""
    _memu_ram_stats
    echo ""
    WARN "This is safe during normal operation but may slow disk access briefly."
    read -r -p "  Drop caches now? (y/n): " dc
    if [[ "${dc,,}" == "y" ]]; then
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null \
            && OK "Page cache dropped." \
            || ERR "Failed to drop caches."
        echo ""
        _memu_ram_stats
    fi
    sleep 2
}

_memu_apply_llm_profile() {
    draw_header
    echo -e "${B_CYAN}[ memU — Apply LLM Inference Profile ]${NC}"
    echo ""
    echo "  Applies all recommended settings for LLM inference in one shot:"
    echo "    • vm.swappiness = 1"
    echo "    • Transparent hugepages = madvise"
    echo "    • vm.nr_hugepages = $(_memu_estimate_hugepages) (auto-calculated)"
    echo "    • memlock = unlimited"
    echo "    • Drop page cache"
    echo "    • Persist all kernel settings"
    echo ""
    read -r -p "  Apply LLM profile now? (y/n): " ap
    [[ "${ap,,}" != "y" ]] && return

    local hp_count
    hp_count=$(_memu_estimate_hugepages)

    # Swappiness
    sudo sysctl -w vm.swappiness=1 &>/dev/null && OK "vm.swappiness=1" || WARN "swappiness failed"

    # THP
    echo "madvise" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null \
        && OK "THP=madvise" || WARN "THP failed"

    # Hugepages
    sudo sysctl -w vm.nr_hugepages="$hp_count" &>/dev/null \
        && OK "nr_hugepages=$hp_count" || WARN "hugepages failed"

    # Persist
    sudo mkdir -p "$(dirname "$MEMU_SYSCTL_FILE")"
    {
        echo "# llama memU — LLM inference profile"
        echo "vm.swappiness = 1"
        echo "vm.nr_hugepages = $hp_count"
    } | sudo tee "$MEMU_SYSCTL_FILE" > /dev/null
    OK "Kernel settings persisted → $MEMU_SYSCTL_FILE"

    # memlock
    {
        echo "# llama memU — memory lock"
        echo "*    soft memlock unlimited"
        echo "*    hard memlock unlimited"
        echo "root soft memlock unlimited"
        echo "root hard memlock unlimited"
    } | sudo tee "$MEMU_LIMITS_FILE" > /dev/null
    ulimit -l unlimited 2>/dev/null || true
    OK "memlock=unlimited → $MEMU_LIMITS_FILE"

    # Drop caches
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null \
        && OK "Page cache dropped"

    echo ""
    OK "LLM inference profile applied."
    WARN "Re-login for memlock changes to fully apply to new sessions."
    sleep 3
}

_memu_reset() {
    draw_header
    echo -e "${B_CYAN}[ memU — Reset to Defaults ]${NC}"
    echo ""
    WARN "This will remove all memU-managed sysctl and limits files and"
    WARN "restore swappiness/hugepages to system defaults."
    read -r -p "  Continue? (y/n): " rst
    [[ "${rst,,}" != "y" ]] && return

    sudo rm -f "$MEMU_SYSCTL_FILE" "$MEMU_LIMITS_FILE"
    sudo sysctl -w vm.swappiness=60 &>/dev/null || true
    sudo sysctl -w vm.nr_hugepages=0 &>/dev/null || true
    echo "always" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true
    OK "Reset to system defaults. Re-login to restore memlock."
    sleep 2
}

# ================================================================
#  MAIN MENU
# ================================================================
memu_menu() {
    while true; do
        draw_header
        echo -e "${B_CYAN}[ 🧠  memU — Memory Optimizer for LLM Inference ]${NC}"
        echo ""

        _memu_ram_stats
        echo ""
        _memu_vram_stats
        echo ""
        _memu_current_kernel_settings
        echo ""
        echo -e "------------------------------------------------------"
        echo -e "  1) ${B_GREEN}Apply LLM Inference Profile${NC}  (recommended one-shot setup)"
        echo -e "  2) ${B_CYAN}Set vm.swappiness${NC}             (reduce swap thrashing)"
        echo -e "  3) ${B_CYAN}Configure Hugepages${NC}           (THP + static pool)"
        echo -e "  4) ${B_CYAN}Set memlock Limit${NC}             (pin model weights in RAM)"
        echo -e "  5) ${B_YELLOW}Drop Page Cache${NC}               (free RAM before model load)"
        echo -e "  6) ${B_RED}Reset to Defaults${NC}"
        echo -e "  7) Back"
        echo ""
        local m=""
        read -r -p "  Action: " m
        case $m in
            1) _memu_apply_llm_profile ;;
            2) _memu_set_swappiness ;;
            3) _memu_set_hugepages ;;
            4) _memu_set_memlock ;;
            5) _memu_drop_caches ;;
            6) _memu_reset ;;
            7) return ;;
            *) echo -e "${B_RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}
