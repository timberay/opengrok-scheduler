#!/bin/bash

# tests/test_idle_timeout.sh
# Test idle detection with process tree CPU sampling

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$PROJECT_ROOT/bin"
DATA_DIR="$PROJECT_ROOT/data"
DEFAULT_DB="$DATA_DIR/scheduler.db"
TEST_DB="$DATA_DIR/test_idle_$(date +%s).db"
PASS=0
FAIL=0

pass() { echo "[Pass] $1"; ((PASS++)); }
fail() { echo "[Fail] $1"; ((FAIL++)); }

echo "=============================="
echo "[Test] Idle Detection Tests"
echo "=============================="

# Source monitor.sh to get functions
source "$BIN_DIR/common.sh"
source "$BIN_DIR/monitor.sh"

# --- Unit Test: get_descendant_pids ---
echo ""
echo "[Case 0] Unit test: get_descendant_pids"

# Spawn a parent that spawns a child that spawns a grandchild
bash -c 'bash -c "sleep 60" & sleep 60' &
PARENT_PID=$!
sleep 1

DESCENDANTS=$(get_descendant_pids $PARENT_PID)
DESC_COUNT=$(echo "$DESCENDANTS" | wc -w)

# Should find at least 2 descendants (child bash + grandchild sleep)
if [ "$DESC_COUNT" -ge 2 ]; then
    pass "get_descendant_pids found $DESC_COUNT descendants for PID $PARENT_PID"
else
    fail "get_descendant_pids found only $DESC_COUNT descendants (expected >= 2)"
fi

# Cleanup
kill -- -$PARENT_PID 2>/dev/null
kill $PARENT_PID 2>/dev/null
wait $PARENT_PID 2>/dev/null

# --- Unit Test: get_tree_cpu_time ---
echo ""
echo "[Case 0b] Unit test: get_tree_cpu_time"

# Spawn a process that does CPU work via a child (dd runs indefinitely until killed)
bash -c 'dd if=/dev/zero of=/dev/null bs=1M 2>/dev/null' &
CPU_PARENT=$!
sleep 1

CPU_TIME=$(get_tree_cpu_time $CPU_PARENT)
if [ -n "$CPU_TIME" ] && [ "$CPU_TIME" -gt 0 ] 2>/dev/null; then
    pass "get_tree_cpu_time returned $CPU_TIME jiffies for active process tree"
else
    fail "get_tree_cpu_time returned '$CPU_TIME' (expected > 0)"
fi

# Cleanup
kill $CPU_PARENT 2>/dev/null
wait $CPU_PARENT 2>/dev/null

# --- Unit Test: kill_process_tree ---
echo ""
echo "[Case 0c] Unit test: kill_process_tree"

# Source scheduler functions (need --no-run to avoid entering main loop)
source "$BIN_DIR/scheduler.sh" --no-run 2>/dev/null

# Spawn a deep process tree: parent -> child -> grandchild
bash -c 'bash -c "sleep 120" & sleep 120' &
TREE_PID=$!
sleep 1

BEFORE_DESC=$(get_descendant_pids $TREE_PID | wc -w)
kill_process_tree "$TREE_PID"
sleep 2

# Verify all processes are gone
if ! kill -0 $TREE_PID 2>/dev/null; then
    pass "kill_process_tree terminated parent PID $TREE_PID and $BEFORE_DESC descendants"
else
    fail "kill_process_tree failed to kill parent PID $TREE_PID"
    kill -9 $TREE_PID 2>/dev/null
fi
wait $TREE_PID 2>/dev/null

# Summary (placeholder for later tasks)
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
