#!/bin/bash

# bin/monitor.sh
# Batch Job System Resource Monitoring Logic

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Ensure iostat (from sysstat package) is available; install if missing.
# Returns 0 if iostat is present at exit, non-zero on install failure.
ensure_iostat() {
    if command -v iostat &> /dev/null; then
        return 0
    fi

    echo "[Info] iostat not found. Attempting to install 'sysstat' package..." >&2

    local PKG_CMD=""
    if command -v apt-get &> /dev/null; then
        PKG_CMD="apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y sysstat"
    elif command -v dnf &> /dev/null; then
        PKG_CMD="dnf install -y sysstat"
    elif command -v yum &> /dev/null; then
        PKG_CMD="yum install -y sysstat"
    elif command -v pacman &> /dev/null; then
        PKG_CMD="pacman -S --noconfirm sysstat"
    elif command -v zypper &> /dev/null; then
        PKG_CMD="zypper --non-interactive install sysstat"
    elif command -v apk &> /dev/null; then
        PKG_CMD="apk add --no-cache sysstat"
    else
        echo "[Error] No supported package manager detected. Install 'sysstat' (provides iostat) manually." >&2
        return 1
    fi

    if [ "$(id -u)" -eq 0 ]; then
        eval "$PKG_CMD" >&2
    elif command -v sudo &> /dev/null; then
        sudo -n true 2>/dev/null || {
            echo "[Error] Passwordless sudo unavailable. Run: sudo bash -c \"$PKG_CMD\"" >&2
            return 1
        }
        sudo -n bash -c "$PKG_CMD" >&2
    else
        echo "[Error] Need root or sudo to install sysstat. Run manually: $PKG_CMD" >&2
        return 1
    fi

    if command -v iostat &> /dev/null; then
        echo "[Info] iostat installed successfully." >&2
        return 0
    fi
    echo "[Error] iostat install failed. Install 'sysstat' manually." >&2
    return 1
}

# Check for required monitoring tools
check_monitor_deps() {
    local MISSING=()
    for cmd in vmstat iostat nproc awk df ip; do
        if ! command -v "$cmd" &> /dev/null; then
            MISSING+=("$cmd")
        fi
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
        echo "[Warning] Monitoring tools missing: ${MISSING[*]}" >&2
        return 1
    fi
    return 0
}

# Run dependency check on source (auto-install iostat first)
ensure_iostat
check_monitor_deps

# CPU Usage calculated via 'vmstat' (using 2nd iteration for current load)
get_cpu_usage() {
    # 2nd iteration of vmstat provides current interval average
    # Dynamically find the "id" (Idle) column index from the header (Line 2)
    local IDLE=$(timeout 5 vmstat 1 2 | awk '
        NR==2 { for(i=1; i<=NF; i++) if($i=="id") {col=i; break} }
        NR > 2 { val=$col }
        END { print val }
    ')
    if [ -z "$IDLE" ] || [[ ! $IDLE =~ ^[0-9]+$ ]]; then
        IDLE=0 # Default to 0 idle (100% busy) on error
    fi
    echo "$((100 - IDLE))"
}

# I/O Wait Percentage via 'vmstat'
get_iowait() {
    # 2nd iteration of vmstat provides current interval average
    # Dynamically find the "wa" (Wait) column index from the header (Line 2)
    local WAIT=$(timeout 5 vmstat 1 2 | awk '
        NR==2 { for(i=1; i<=NF; i++) if($i=="wa") {col=i; break} }
        NR > 2 { val=$col }
        END { print val }
    ')
    if [ -z "$WAIT" ] || [[ ! $WAIT =~ ^[0-9]+$ ]]; then
        WAIT=100 # Default to high wait on error
    fi
    echo "$WAIT"
}


# CPU Load Average (1 min) converted to score (0-100+)
get_cpu_load_average() {
    local CORES=$(nproc)
    # Extract 1-minute load average
    local LOAD1=$(awk '{print $1}' /proc/loadavg)
    
    # Calculate score: (Load / Cores) * 100
    # e.g., Load 2.8 on 4 cores -> (2.8/4)*100 = 70
    local SCORE_LOAD=$(echo "$LOAD1 $CORES" | awk '{printf "%d", ($1/$2)*100}')
    
    echo "$SCORE_LOAD"
}

# Memory Usage calculated via '/proc/meminfo' (direct read for performance)
get_mem_usage() {
    local TOTAL AVAIL
    # Single awk call to read both values from /proc/meminfo
    # MemAvailable is the best indicator of actual memory pressure on modern Linux
    if ! read -r TOTAL AVAIL < <(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {print t, a}' /proc/meminfo 2>/dev/null); then
        echo "100"
        return
    fi
    
    if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ] || [ -z "$AVAIL" ]; then
        echo "100" # Assume full on error
        return
    fi
    
    # Calculate used percentage excluding cache/buffer (Total - Available)
    local USED_PERCENT=$(( (TOTAL - AVAIL) * 100 / TOTAL ))
    [ "$USED_PERCENT" -lt 0 ] && USED_PERCENT=0
    [ "$USED_PERCENT" -gt 100 ] && USED_PERCENT=100
    echo "$USED_PERCENT"
}

# Disk Usage of a given path via 'df'
# If path is not provided, returns the MAXIMUM percentage across all local real disks
get_disk_usage() {
    local TARGET_PATH=${1:-"all"}
    local PERCENT
    if [ "$TARGET_PATH" = "all" ]; then
        PERCENT=$(df -hl 2>/dev/null | grep '^/dev/' | awk '{print $5}' | sed 's/%//' | sort -rn | head -1)
        # Fallback to root if grep fails
        [ -z "$PERCENT" ] && PERCENT=$(df -hP / 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    else
        PERCENT=$(df -hP "$TARGET_PATH" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    fi
    [ -z "$PERCENT" ] || [[ ! $PERCENT =~ ^[0-9]+$ ]] && PERCENT=100
    echo "$PERCENT"
}

# Disk I/O Utilization Percentage
get_diskio_usage() {
    # 1. Identify the primary disk
    local DISK="$DISK_DEVICE"

    if [ -z "$DISK" ]; then
        # Use lsblk to find the parent disk of the root filesystem
        local ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null)
        if [ -n "$ROOT_DEV" ]; then
            DISK=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null)
            # If PKNAME is empty, it's already the parent (e.g. sda instead of sda1)
            [ -z "$DISK" ] && DISK=$(basename "$ROOT_DEV")
        fi
        
        # Fallback to old logic if still empty
        if [ -z "$DISK" ]; then
            DISK=$(df / | tail -1 | awk '{print $1}' | sed 's|.*/dev/||')
            # Strip partition suffix: "sda1" → "sda", "nvme0n1p1" → "nvme0n1"
            if [[ "$DISK" =~ ^nvme ]]; then
                DISK=$(echo "$DISK" | sed 's/p[0-9]*$//')
            else
                DISK=$(echo "$DISK" | sed 's/[0-9]*$//')
            fi
        fi
    fi

    # 2. Extract %util from iostat (second sample for interval average)
    local UTIL=$(timeout 5 iostat -dx 1 2 "$DISK" 2>/dev/null | awk -v dev="$DISK" '
        /^Device/ {for(i=1;i<=NF;i++) if($i=="%util") col=i}
        $1 == dev {val=$col}
        END {print val}
    ' | cut -d. -f1)
    
    if [ -z "$UTIL" ] || [[ ! $UTIL =~ ^[0-9]+$ ]]; then
        UTIL=0 # Cannot measure — assume not busy (warn via check_monitor_deps)
    fi
    
    echo "$UTIL"
}

# Network Bandwidth Usage Percentage
# If iface is not provided, returns the MAXIMUM utilization percentage across all physical interfaces
get_bandwidth_usage() {
    local TARGET_IFACE=${1:-"all"}
    local MAX_BW_CONFIG="${MAX_BANDWIDTH:-0}"
    local MAX_SCORE=0
    
    # 1. Identify interfaces to monitor
    local INTERFACES=()
    if [ "$TARGET_IFACE" = "all" ]; then
        # Use NET_INTERFACE from config as highest priority if set
        if [ -n "$NET_INTERFACE" ]; then
            INTERFACES=("$NET_INTERFACE")
        else
            # Auto-detect physical interfaces (those with 'device' link)
            for d in /sys/class/net/*; do
                local iface=$(basename "$d")
                [ "$iface" = "lo" ] && continue
                if [ -L "$d/device" ]; then
                    INTERFACES+=("$iface")
                fi
            done
            # Fallback to current default route interface if no physical ones found
            if [ ${#INTERFACES[@]} -eq 0 ]; then
                local DEFAULT_IF=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+')
                [ -n "$DEFAULT_IF" ] && INTERFACES=("$DEFAULT_IF")
            fi
        fi
    else
        INTERFACES=("$TARGET_IFACE")
    fi
    
    [ ${#INTERFACES[@]} -eq 0 ] && echo "0" && return

    # 2. Capture initial stats for all target interfaces
    local STATS1=()
    for iface in "${INTERFACES[@]}"; do
        local S=$(awk -v iface="$iface" '$1 == iface":" {printf "%d", $2 + $10}' /proc/net/dev)
        STATS1+=("$iface:$S")
    done

    sleep 1

    # 3. Capture second stats and calculate maximum score
    for s1 in "${STATS1[@]}"; do
        local iface="${s1%%:*}"
        local val1="${s1#*:}"
        local val2=$(awk -v iface="$iface" '$1 == iface":" {printf "%d", $2 + $10}' /proc/net/dev)
        
        local diff=$((val2 - val1))
        [ "$diff" -lt 0 ] && diff=0
        
        # Determine bandwidth for this specific interface
        local if_bw=$MAX_BW_CONFIG
        if [ "$if_bw" -le 0 ]; then
            if [ -f "/sys/class/net/$iface/speed" ]; then
                local speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
                # speed is in Mbps, convert to bytes/s
                if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
                    if_bw=$(( speed * 125000 ))
                fi
            fi
        fi
        
        # Fallback to 100Mbps default if still 0
        [ "$if_bw" -le 0 ] && if_bw=12500000 
        
        local score=$(( diff * 100 / if_bw ))
        [ "$score" -gt 100 ] && score=100
        [ "$score" -gt "$MAX_SCORE" ] && MAX_SCORE=$score
    done
    
    echo "$MAX_SCORE"
}

# Swap Usage calculated via '/proc/meminfo'
get_swap_usage() {
    local TOTAL FREE
    if ! read -r TOTAL FREE < <(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print t, f}' /proc/meminfo 2>/dev/null); then
        echo "100"
        return
    fi
    
    if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
        echo "0" # No swap is not an error
        return
    fi
    
    local USED_PERCENT=$(( (TOTAL - FREE) * 100 / TOTAL ))
    [ "$USED_PERCENT" -lt 0 ] && USED_PERCENT=0
    [ "$USED_PERCENT" -gt 100 ] && USED_PERCENT=100
    echo "$USED_PERCENT"
}

# Disk Inode Usage via 'df -i'
# If path is not provided, returns the MAXIMUM percentage across all local real disks
get_inode_usage() {
    local TARGET_PATH=${1:-"all"}
    local PERCENT
    if [ "$TARGET_PATH" = "all" ]; then
        # Check all local real filesystems (starting with /dev/)
        PERCENT=$(df -il 2>/dev/null | grep '^/dev/' | awk '{print $5}' | sed 's/%//' | sort -rn | head -1)
        # Fallback to root if grep fails
        [ -z "$PERCENT" ] && PERCENT=$(df -iP / 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    else
        PERCENT=$(df -iP "$TARGET_PATH" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    fi

    if [ -z "$PERCENT" ] || [[ ! $PERCENT =~ ^[0-9]+$ ]]; then
        echo "100"
        return
    fi
    echo "$PERCENT"
}

# Process State Check via /proc/<PID>/status
# Args: PID
# Returns: RUNNING | SLEEPING | DISK_WAIT | STOPPED | ZOMBIE | EXITED | UNKNOWN
get_process_state() {
    local PID=$1
    if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
        echo "EXITED"
        return
    fi
    local STATE=$(awk '/^State:/ {print $2}' /proc/$PID/status 2>/dev/null)
    case "$STATE" in
        R) echo "RUNNING" ;;
        S) echo "SLEEPING" ;;
        D) echo "DISK_WAIT" ;;
        T) echo "STOPPED" ;;
        Z) echo "ZOMBIE" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# Get all descendant PIDs of a given PID (recursive)
# Args: PID
# Returns: space-separated list of descendant PIDs
get_descendant_pids() {
    local PARENT_PID=$1
    local CHILDREN
    CHILDREN=$(pgrep -P "$PARENT_PID" 2>/dev/null)
    for CHILD in $CHILDREN; do
        echo "$CHILD"
        get_descendant_pids "$CHILD"
    done
}

# Get total CPU time (user + system jiffies) for a process and all its descendants
# Args: PID
# Returns: total jiffies (integer), or 0 if process doesn't exist
get_tree_cpu_time() {
    local ROOT_PID=$1
    local TOTAL=0

    # Collect all PIDs: root + descendants
    local ALL_PIDS="$ROOT_PID $(get_descendant_pids "$ROOT_PID")"

    for PID in $ALL_PIDS; do
        local STAT
        STAT=$(cat "/proc/$PID/stat" 2>/dev/null) || continue
        # Fields 14 (utime) and 15 (stime) — but field 2 (comm) can contain spaces and parens
        # Safe parse: strip everything up to and including the last ')' then read fields
        local AFTER_COMM="${STAT##*) }"
        # After stripping "(comm) ", remaining starts at field 3
        # So utime = field 12 of remaining, stime = field 13 of remaining
        local UTIME STIME
        read -r _ _ _ _ _ _ _ _ _ _ _ UTIME STIME _ <<< "$AFTER_COMM"
        if [[ "$UTIME" =~ ^[0-9]+$ ]] && [[ "$STIME" =~ ^[0-9]+$ ]]; then
            TOTAL=$(( TOTAL + UTIME + STIME ))
        fi
    done

    echo "$TOTAL"
}

# Evaluate process busyness based on /proc/stat and /proc/loadavg
# Returns a "Busy Score" where RESOURCE_THRESHOLD+ indicates high load
get_proc_usage() {
    local CORES=$(nproc)
    local RUNNING=$(grep procs_running /proc/stat | awk '{print $2}')
    local BLOCKED=$(grep procs_blocked /proc/stat | awk '{print $2}')
    local TOTAL=$(ls /proc | grep '^[0-9]' | wc -l)

    # .env에 정의된 부하 기준율 (기본값 70) 
    local REF_VAL=${RESOURCE_THRESHOLD:-70}

    # 1. Score by Running processes (Rule: running > cores * 2 is busy)
    # We want REF_VAL when running == cores * 2
    local SCORE_R=$(( RUNNING * REF_VAL / (CORES * 2) ))

    # 2. Score by Blocked processes (Rule: blocked > 10 is busy)
    # We want REF_VAL when blocked == 10
    local SCORE_B=$(( BLOCKED * REF_VAL / 10 ))

    # 3. Score by R-state ratio (Rule: ratio > RESOURCE_THRESHOLD% is busy)
    # R_Ratio = (Running / Total) * 100
    local SCORE_RATIO=0
    if [ "$TOTAL" -gt 0 ]; then
        SCORE_RATIO=$(( RUNNING * 100 / TOTAL ))
    fi

    # Output the highest score among criteria
    local MAX_SCORE=$SCORE_R
    [ "$SCORE_B" -gt "$MAX_SCORE" ] && MAX_SCORE=$SCORE_B
    [ "$SCORE_RATIO" -gt "$MAX_SCORE" ] && MAX_SCORE=$SCORE_RATIO

    echo "$MAX_SCORE"
}

# Global variable to store why the threshold was triggered
LAST_BYPASS_REASON=""

# Evaluate if any resource usage exceeds thresholds
# Args: cpu mem disk diskio net proc load iowait swap inode threshold
# Return: 0 if all safe, 1 if any exceeds
check_thresholds() {
    local CPU=${1:-0}; local MEM=${2:-0}; local DISK=${3:-0}; local DISKIO=${4:-0}; local NET=${5:-0}; local PROC=${6:-0}; local LOAD=${7:-0}; local IOWAIT=${8:-0}; local SWAP=${9:-0}; local INODE=${10:-0}; local LIMIT=${11:-100}
    local REASONS=()
    
    if [ "$CPU" -gt "$LIMIT" ]; then REASONS+=("CPU ${CPU}%"); fi
    if [ "$MEM" -gt "$LIMIT" ]; then REASONS+=("Memory ${MEM}%"); fi
    if [ "$DISK" -gt "$LIMIT" ]; then REASONS+=("Disk ${DISK}%"); fi
    if [ "$DISKIO" -gt "$LIMIT" ]; then REASONS+=("Disk I/O ${DISKIO}%"); fi
    if [ "$NET" -gt "$LIMIT" ]; then REASONS+=("Network ${NET}%"); fi
    if [ "$PROC" -gt "$LIMIT" ]; then REASONS+=("Process Score ${PROC}"); fi
    if [ "$LOAD" -gt "$LIMIT" ]; then REASONS+=("Load Avg Score ${LOAD}"); fi
    
    # Specific thresholds for I/O Wait, Swap, and Inodes
    if [ "$IOWAIT" -gt "${IOWAIT_THRESHOLD:-20}" ]; then REASONS+=("I/O Wait ${IOWAIT}%"); fi
    if [ "$SWAP" -gt "${SWAP_THRESHOLD:-50}" ]; then REASONS+=("Swap ${SWAP}%"); fi
    if [ "$INODE" -gt "${INODE_THRESHOLD:-90}" ]; then REASONS+=("Inodes ${INODE}%"); fi
    
    if [ ${#REASONS[@]} -gt 0 ]; then
        # Join reasons with comma and include the limit
        local JOINED=$(IFS=', '; echo "${REASONS[*]}")
        LAST_BYPASS_REASON="$JOINED (Limit: ${LIMIT})"
        return 1
    fi
    
    LAST_BYPASS_REASON=""
    return 0
}
