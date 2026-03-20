#!/bin/bash

# bin/monitor.sh
# System Resource Monitoring Logic

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
fi

# CPU Usage calculated via 'top' (using 2nd iteration for current load)
get_cpu_usage() {
    # -d 0.1: short delay between iterations
    # -n 2: two iterations to get current delta
    local IDLE=$(top -bn2 -d 0.1 | grep -i "Cpu(s)" | tail -1 | awk -F',' '{for(i=1;i<=NF;i++) if($i ~ /id/) print $i}' | awk '{print $1}' | cut -d. -f1)
    if [ -z "$IDLE" ] || [[ ! $IDLE =~ ^[0-9]+$ ]]; then
        IDLE=100
    fi
    echo "$((100 - IDLE))"
}

# Memory Usage calculated via 'free -m' (using 'available' for actual pressure)
get_mem_usage() {
    # NR==2 to avoid locale issues (Mem: or 메모리:)
    local MEM_INFO=$(free -m | awk 'NR==2')
    local TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')
    local AVAIL=$(echo "$MEM_INFO" | awk '{print $7}')
    
    if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ] || [ -z "$AVAIL" ]; then
        echo "0"
        return
    fi
    
    # Calculate used percentage excluding cache/buffer (Total - Available)
    local USED_PERCENT=$(( (TOTAL - AVAIL) * 100 / TOTAL ))
    [ "$USED_PERCENT" -lt 0 ] && USED_PERCENT=0
    echo "$USED_PERCENT"
}

# Disk Usage of a given path via 'df'
get_disk_usage() {
    local TARGET_PATH=${1:-"/"}
    local PERCENT=$(df -P "$TARGET_PATH" | tail -1 | awk '{print $5}' | sed 's/%//')
    echo "$PERCENT"
}

# Disk I/O Utilization Percentage
get_diskio_usage() {
    # 1. Identify the primary disk
    # First, try to get from environment/config
    local DISK="$DISK_DEVICE"

    # If not in SQLite, fallback to auto-detection from root (/)
    if [ -z "$DISK" ]; then
        DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/.*\/dev\///; s/[0-9]*$//')
    fi

    # 2. Extract %util from iostat (second sample for interval average)
    local UTIL=$(iostat -dx 1 2 "$DISK" | awk '/^Device/ {for(i=1;i<=NF;i++) if($i=="%util") col=i} END {print $col}' | cut -d. -f1)
    
    if [ -z "$UTIL" ] || [[ ! $UTIL =~ ^[0-9]+$ ]]; then
        UTIL=0
    fi
    
    echo "$UTIL"
}

# Network Bandwidth Usage Percentage
get_bandwidth_usage() {
    local IFACE="$NET_INTERFACE"
    local MAX_BW="${MAX_BANDWIDTH:-0}"
    
    if [ -z "$IFACE" ]; then
        IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+')
    fi
    
    [ -z "$IFACE" ] && echo "0" && return

    # 2. Auto-detect Interface Speed if not configured
    # /sys/class/net/<iface>/speed is in Mbps
    if [ "$MAX_BW" -eq 0 ]; then
        if [ -f "/sys/class/net/$IFACE/speed" ]; then
            local SPEED_MBPS=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null)
            # Convert Mbps to bytes/s (Mbps * 1024 * 1024 / 8) -> approx Mbps * 125000
            if [[ "$SPEED_MBPS" =~ ^[0-9]+$ ]] && [ "$SPEED_MBPS" -gt 0 ]; then
                MAX_BW=$(( SPEED_MBPS * 125000 ))
            fi
        fi
    fi
    
    # Final fallback if still 0
    [ "$MAX_BW" -le 0 ] && MAX_BW=12500000 # Default 100Mbps in bytes/s

    # 3. Extract RX/TX bytes and calculate usage over 1s
    local STAT1=$(grep "$IFACE" /proc/net/dev | awk '{print $2, $10}')
    sleep 1
    local STAT2=$(grep "$IFACE" /proc/net/dev | awk '{print $2, $10}')
    
    local RX1=$(echo $STAT1 | awk '{print $1}')
    local TX1=$(echo $STAT1 | awk '{print $2}')
    local RX2=$(echo $STAT2 | awk '{print $1}')
    local TX2=$(echo $STAT2 | awk '{print $2}')
    
    # RX2-RX1 might be negative if counter wraps, but unlikely in 1s
    local DIFF=$(( (RX2 - RX1) + (TX2 - TX1) ))
    [ "$DIFF" -lt 0 ] && DIFF=0
    
    # 4. Calculate Score (0-100)
    local SCORE=$(( DIFF * 100 / MAX_BW ))
    [ "$SCORE" -gt 100 ] && SCORE=100
    
    echo "$SCORE"
}

# Evaluate process busyness based on /proc/stat and /proc/loadavg
# Returns a "Busy Score" where 70+ indicates high load
get_proc_usage() {
    local CORES=$(nproc)
    local RUNNING=$(grep procs_running /proc/stat | awk '{print $2}')
    local BLOCKED=$(grep procs_blocked /proc/stat | awk '{print $2}')
    local TOTAL=$(ls /proc | grep '^[0-9]' | wc -l)

    # 1. Score by Running processes (Rule: running > cores * 2 is busy)
    # We want 70 when running == cores * 2
    local SCORE_R=$(( RUNNING * 70 / (CORES * 2) ))

    # 2. Score by Blocked processes (Rule: blocked > 10 is busy)
    # We want 70 when blocked == 10
    local SCORE_B=$(( BLOCKED * 70 / 10 ))

    # 3. Score by R-state ratio (Rule: ratio > 70% is busy)
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

# Check if any resource usage exceeds thresholds
# Args: cpu mem disk diskio net proc threshold
# Return: 0 if all safe, 1 if any exceeds
check_thresholds() {
    local CPU=$1; local MEM=$2; local DISK=$3; local DISKIO=$4; local NET=$5; local PROC=$6; local LIMIT=$7
    local REASONS=()
    
    if [ "$CPU" -gt "$LIMIT" ]; then REASONS+=("CPU ${CPU}%"); fi
    if [ "$MEM" -gt "$LIMIT" ]; then REASONS+=("Memory ${MEM}%"); fi
    if [ "$DISK" -gt "$LIMIT" ]; then REASONS+=("Disk ${DISK}%"); fi
    if [ "$DISKIO" -gt "$LIMIT" ]; then REASONS+=("Disk I/O ${DISKIO}%"); fi
    if [ "$NET" -gt "$LIMIT" ]; then REASONS+=("Network ${NET}%"); fi
    if [ "$PROC" -gt "$LIMIT" ]; then REASONS+=("Process Score ${PROC}"); fi
    
    if [ ${#REASONS[@]} -gt 0 ]; then
        # Join reasons with comma and include the limit
        local JOINED=$(IFS=', '; echo "${REASONS[*]}")
        LAST_BYPASS_REASON="$JOINED (Limit: ${LIMIT})"
        return 1
    fi
    
    LAST_BYPASS_REASON=""
    return 0
}
