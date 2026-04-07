#!/bin/bash

# tests/test_monitor.sh
# Resource Monitoring Unit Test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/bin/monitor.sh"

BG_PIDS=()
cleanup_bg() {
    for pid in "${BG_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -CONT "$pid" 2>/dev/null
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    done
}
trap cleanup_bg EXIT

echo "[Test] Resource Monitoring Test Started..."

# 1. CPU Calculation Check
CPU_USAGE=$(get_cpu_usage)
echo "Current CPU Usage: $CPU_USAGE%"
if [[ $CPU_USAGE =~ ^[0-9]+$ ]] && [ "$CPU_USAGE" -ge 0 ] && [ "$CPU_USAGE" -le 100 ]; then
    echo "[Pass] CPU usage calculated correctly."
else
    echo "[Fail] Invalid CPU usage: $CPU_USAGE"
    exit 1
fi

# 2. Memory Calculation Check
MEM_USAGE=$(get_mem_usage)
echo "Current Memory Usage: $MEM_USAGE%"
if [[ $MEM_USAGE =~ ^[0-9]+$ ]] && [ "$MEM_USAGE" -ge 0 ] && [ "$MEM_USAGE" -le 100 ]; then
    echo "[Pass] Memory usage calculated correctly."
else
    echo "[Fail] Invalid Memory usage: $MEM_USAGE"
    exit 1
fi

# 3. Disk Usage Check
DISK_USAGE=$(get_disk_usage) # All disks by default
echo "Max Disk Usage (All): $DISK_USAGE%"
if [[ $DISK_USAGE =~ ^[0-9]+$ ]] && [ "$DISK_USAGE" -ge 0 ] && [ "$DISK_USAGE" -le 100 ]; then
    echo "[Pass] Disk usage calculated correctly."
else
    echo "[Fail] Invalid Disk usage: $DISK_USAGE"
    exit 1
fi

# 4. Process Usage (Busy Score) Check
PROC_SCORE=$(get_proc_usage)
echo "Current Process Busy Score: $PROC_SCORE"
if [[ $PROC_SCORE =~ ^[0-9]+$ ]] && [ "$PROC_SCORE" -ge 0 ]; then
    echo "[Pass] Process busy score calculated correctly."
else
    echo "[Fail] Invalid Process busy score: $PROC_SCORE"
    exit 1
fi

# 5. Threshold Logic Test (Mocking 80% usage)
echo "[Test] Mocking 80% usage scenario..."
THRESHOLD=70
# check_thresholds cpu mem disk diskio net proc load iowait swap inode threshold
check_thresholds 80 10 10 10 10 10 10 0 10 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] Threshold triggered (Exceeds 70%)."
else
    echo "[Fail] Threshold not triggered for 80%."
    exit 1
fi

# 6. Disk I/O Threshold Test (Mocking 80% Disk I/O)
echo "[Test] Mocking 80% Disk I/O scenario..."
check_thresholds 10 10 10 80 10 10 10 0 10 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] Disk I/O Threshold triggered correctly."
else
    echo "[Fail] Disk I/O Threshold not triggered for 80%."
    exit 1
fi

# 7. Network Bandwidth Usage Check
BW_USAGE=$(get_bandwidth_usage) # All physical interfaces by default
echo "Max Network Usage Score (All): $BW_USAGE"
if [[ $BW_USAGE =~ ^[0-9]+$ ]] && [ "$BW_USAGE" -ge 0 ] && [ "$BW_USAGE" -le 100 ]; then
    echo "[Pass] Network usage score calculated correctly."
else
    echo "[Fail] Invalid Network usage score: $BW_USAGE"
    exit 1
fi

# 8. Network Threshold Test (Mocking 80% Network Usage)
echo "[Test] Mocking 80% Network scenario..."
check_thresholds 10 10 10 10 80 10 10 0 10 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] Network Threshold triggered correctly."
else
    echo "[Fail] Network Threshold not triggered for 80%."
    exit 1
fi

# 9. I/O Wait Calculation Check
IOWAIT_USAGE=$(get_iowait)
echo "Current I/O Wait: $IOWAIT_USAGE%"
if [[ $IOWAIT_USAGE =~ ^[0-9]+$ ]] && [ "$IOWAIT_USAGE" -ge 0 ] && [ "$IOWAIT_USAGE" -le 100 ]; then
    echo "[Pass] I/O Wait calculated correctly."
else
    echo "[Fail] Invalid I/O Wait: $IOWAIT_USAGE"
    exit 1
fi

# 10. I/O Wait Threshold Test (Mocking 25% I/O Wait - should trigger even if THRESHOLD=70)
echo "[Test] Mocking 25% I/O Wait scenario..."
# check_thresholds cpu mem disk diskio net proc load iowait swap inode threshold
check_thresholds 10 10 10 10 10 10 10 25 10 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] I/O Wait Threshold correctly triggered at 25%."
else
    echo "[Fail] I/O Wait Threshold not triggered at 25%."
    exit 1
fi

# 11. I/O Wait Below Threshold Test (Mocking 15% I/O Wait - should not trigger by default 20%)
echo "[Test] Mocking 15% I/O Wait scenario..."
check_thresholds 10 10 10 10 10 10 10 15 10 10 $THRESHOLD
if [ $? -eq 0 ]; then
    echo "[Pass] I/O Wait (15%) correctly ignored."
else
    echo "[Fail] I/O Wait Threshold triggered at 15% (should only trigger > 20%)."
    exit 1
fi

# 12. I/O Wait Environment Variable Override Test (Mocking IOWAIT_THRESHOLD=40, IOWAIT=25 - should not trigger)
echo "[Test] Mocking IOWAIT_THRESHOLD=40 with 25% I/O Wait scenario..."
IOWAIT_THRESHOLD=40 check_thresholds 10 10 10 10 10 10 10 25 10 10 $THRESHOLD
if [ $? -eq 0 ]; then
    echo "[Pass] I/O Wait (25%) correctly ignored with IOWAIT_THRESHOLD=40."
else
    echo "[Fail] I/O Wait Threshold triggered at 25% even with IOWAIT_THRESHOLD=40."
    exit 1
fi

# 13. I/O Wait Environment Variable Override Test (Mocking IOWAIT_THRESHOLD=10, IOWAIT=15 - should trigger)
echo "[Test] Mocking IOWAIT_THRESHOLD=10 with 15% I/O Wait scenario..."
IOWAIT_THRESHOLD=10 check_thresholds 10 10 10 10 10 10 10 15 10 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] I/O Wait Threshold correctly triggered at 15% with IOWAIT_THRESHOLD=10."
else
    echo "[Fail] I/O Wait Threshold not triggered at 15% with IOWAIT_THRESHOLD=10."
    exit 1
fi

# 14. Swap Usage Check
SWAP_USAGE=$(get_swap_usage)
echo "Current Swap Usage: $SWAP_USAGE%"
if [[ $SWAP_USAGE =~ ^[0-9]+$ ]] && [ "$SWAP_USAGE" -ge 0 ] && [ "$SWAP_USAGE" -le 100 ]; then
    echo "[Pass] Swap usage calculated correctly."
else
    echo "[Fail] Invalid Swap usage: $SWAP_USAGE"
    exit 1
fi

# 15. Inode Usage Check
INODE_USAGE=$(get_inode_usage) # All disks by default
echo "Max Inode Usage (All): $INODE_USAGE%"
if [[ $INODE_USAGE =~ ^[0-9]+$ ]] && [ "$INODE_USAGE" -ge 0 ] && [ "$INODE_USAGE" -le 100 ]; then
    echo "[Pass] Inode usage calculated correctly."
else
    echo "[Fail] Invalid Inode usage: $INODE_USAGE"
    exit 1
fi

# 16. Swap Threshold Test (Mocking 60% swap with 50% limit)
echo "[Test] Mocking 60% Swap scenario..."
SWAP_THRESHOLD=50 check_thresholds 10 10 10 10 10 10 10 0 60 10 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] Swap Threshold correctly triggered at 60%."
else
    echo "[Fail] Swap Threshold not triggered at 60%."
    exit 1
fi

# 17. Inode Threshold Test (Mocking 95% inode with 90% limit)
echo "[Test] Mocking 95% Inode scenario..."
INODE_THRESHOLD=90 check_thresholds 10 10 10 10 10 10 10 0 10 95 $THRESHOLD
if [ $? -ne 0 ]; then
    echo "[Pass] Inode Threshold correctly triggered at 95%."
else
    echo "[Fail] Inode Threshold not triggered at 95%."
    exit 1
fi

# 18. Process State Check (Current Shell)
STATE=$(get_process_state $$)
echo "Current Shell State ($$): $STATE"
if [[ "$STATE" == "RUNNING" || "$STATE" == "SLEEPING" ]]; then
    echo "[Pass] Current shell state is valid."
else
    echo "[Fail] Invalid shell state: $STATE"
    exit 1
fi

# 19. Process State Check (Non-existent PID)
STATE=$(get_process_state 999999)
echo "Non-existent PID State: $STATE"
if [ "$STATE" == "EXITED" ]; then
    echo "[Pass] Non-existent PID correctly identified as EXITED."
else
    echo "[Fail] Expected EXITED for non-existent PID, got: $STATE"
    exit 1
fi

# 20. Process State Check (Background Sleep)
sleep 2 &
BG_PID=$!
BG_PIDS+=($BG_PID)
STATE=$(get_process_state $BG_PID)
echo "Background Sleep State ($BG_PID): $STATE"
if [ "$STATE" == "SLEEPING" ] || [ "$STATE" == "RUNNING" ]; then
    echo "[Pass] Background sleep state is valid."
else
    echo "[Fail] Invalid background sleep state: $STATE"
    kill $BG_PID 2>/dev/null
    exit 1
fi
kill $BG_PID 2>/dev/null
wait $BG_PID 2>/dev/null

# 21. Process State Check (Stopped Process)
sleep 5 &
BG_PID=$!
BG_PIDS+=($BG_PID)
kill -STOP $BG_PID
sleep 0.1 # Give it a moment to stop
STATE=$(get_process_state $BG_PID)
echo "Stopped Process State ($BG_PID): $STATE"
if [ "$STATE" == "STOPPED" ]; then
    echo "[Pass] Stopped process correctly identified."
else
    echo "[Fail] Expected STOPPED for stopped process, got: $STATE"
    kill -CONT $BG_PID 2>/dev/null
    kill $BG_PID 2>/dev/null
    exit 1
fi
kill -CONT $BG_PID 2>/dev/null
kill $BG_PID 2>/dev/null
wait $BG_PID 2>/dev/null

echo "[Success] Resource Monitoring module tests passed!"
exit 0
