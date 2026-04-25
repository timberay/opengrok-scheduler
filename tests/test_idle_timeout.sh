#!/bin/bash

# tests/test_idle_timeout.sh
# Test idle detection with process tree CPU sampling

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"
BIN_DIR="$PROJECT_ROOT/bin"

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

# --- Unit Test: idle detection handles vanished process without bash error ---
echo ""
echo "[Case 0d] Unit test: integer validation for vanished process"

# Simulate what happens when get_tree_cpu_time returns empty string
EMPTY_CPU=""
LAST_CPU_VAL="100"

# This should NOT produce a bash error
ERROR_OUTPUT=$( {
    if [[ ! "$EMPTY_CPU" =~ ^[0-9]+$ ]]; then
        echo "SKIPPED"
    elif [ -n "$LAST_CPU_VAL" ] && [ "$EMPTY_CPU" -eq "$LAST_CPU_VAL" ]; then
        echo "IDLE"
    else
        echo "ACTIVE"
    fi
} 2>&1 )

if [ "$ERROR_OUTPUT" = "SKIPPED" ]; then
    pass "Empty CPU value correctly skipped without bash error"
else
    fail "Empty CPU value produced unexpected output: $ERROR_OUTPUT"
fi


# ===========================================
# Integration Tests (require DB and scheduler)
# ===========================================

# 1. Setup Test Environment using test_helper
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# Create a temp scheduler copy with sleep 120 instead of sleep 2 (so idle detection can trigger)
# Must be created inside BIN_DIR so that source "$(dirname "${BASH_SOURCE[0]}")/common.sh" resolves correctly
TEMP_SCHEDULER=$(mktemp "$BIN_DIR/scheduler_test_XXXXXX.sh")
# Replace sleep 2 with a command that briefly uses CPU (dd) then sleeps long enough for idle detection.
# The dd ensures CURRENT_CPU > 0 on first sample, then sleep 120 leaves CPU unchanged on subsequent
# samples, satisfying the idle detection condition: CURRENT_CPU == LAST_CPU && CURRENT_CPU > 0.
sed 's|timeout --kill-after=10s "\$MAX_DURATION" bash -c "sleep 2"|timeout --kill-after=10s "$MAX_DURATION" bash -c '"'"'x=1; while [ $x -le 10000 ]; do x=$((x+1)); done; sleep 120'"'"'|' \
    "$BIN_DIR/scheduler.sh" > "$TEMP_SCHEDULER"
chmod +x "$TEMP_SCHEDULER"

# --- Integration Test: Idle Hang triggers TIMEOUT ---
echo ""
echo "[Case 1] Testing Idle Hang (sleep with JOB_IDLE_TIMEOUT=15)..."
sqlite3 "$TEST_DB" "DELETE FROM jobs;"
sqlite3 "$TEST_DB" "DELETE FROM services;"
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('idle_svc', 1, 1);"

export JOB_IDLE_TIMEOUT=15
export JOB_TIMEOUT_SEC=120
export CHECK_INTERVAL=5
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=200

timeout 60s bash "$TEMP_SCHEDULER" &
SCHEDULER_PID=$!

sleep 45 # Wait for idle timeout to trigger (15s + scheduler intervals + kill_process_tree grace period + buffer)

STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='idle_svc') ORDER BY id DESC LIMIT 1;")
MSG=$(sqlite3 "$TEST_DB" "SELECT message FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='idle_svc') ORDER BY id DESC LIMIT 1;")

if [ "$STATUS" == "TIMEOUT" ] && [[ "$MSG" == *"Idle"* ]]; then
    pass "Idle service was correctly timed out. Status=$STATUS, Msg=$MSG"
else
    fail "Idle service status: $STATUS, Msg: $MSG (expected TIMEOUT with 'Idle' in message)"
fi

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null

# --- Integration Test: JOB_IDLE_TIMEOUT=0 disables idle detection ---
echo ""
echo "[Case 2] Testing JOB_IDLE_TIMEOUT=0 (idle detection disabled)..."
sqlite3 "$TEST_DB" "DELETE FROM jobs;"
sqlite3 "$TEST_DB" "DELETE FROM services;"
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('noidle_svc', 1, 1);"

export JOB_IDLE_TIMEOUT=0
export JOB_TIMEOUT_SEC=120
export CHECK_INTERVAL=5
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=200

timeout 30s bash "$TEMP_SCHEDULER" &
SCHEDULER_PID=$!

sleep 20

STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='noidle_svc') ORDER BY id DESC LIMIT 1;")

if [ "$STATUS" == "RUNNING" ] || [ "$STATUS" == "COMPLETED" ]; then
    pass "With JOB_IDLE_TIMEOUT=0, job was NOT idle-timed-out. Status=$STATUS"
else
    fail "With JOB_IDLE_TIMEOUT=0, unexpected status: $STATUS (expected RUNNING or COMPLETED)"
fi

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null

# --- Integration Test: Pure sleep (0 CPU) triggers idle timeout ---
echo ""
echo "[Case 3] Testing pure sleep process (0 CPU time) triggers idle timeout..."
sqlite3 "$TEST_DB" "DELETE FROM jobs;"
sqlite3 "$TEST_DB" "DELETE FROM services;"
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('zerocpu_svc', 1, 1);"

# Create a scheduler variant that runs pure sleep (no CPU work at all)
TEMP_SCHEDULER_ZEROCPU=$(mktemp "$BIN_DIR/scheduler_test_zerocpu_XXXXXX.sh")
sed 's|timeout --kill-after=10s "\$MAX_DURATION" bash -c "sleep 2"|timeout --kill-after=10s "$MAX_DURATION" bash -c "sleep 120"|' \
    "$BIN_DIR/scheduler.sh" > "$TEMP_SCHEDULER_ZEROCPU"
chmod +x "$TEMP_SCHEDULER_ZEROCPU"

export JOB_IDLE_TIMEOUT=15
export JOB_TIMEOUT_SEC=120
export CHECK_INTERVAL=5
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=200

timeout 60s bash "$TEMP_SCHEDULER_ZEROCPU" &
SCHEDULER_PID=$!

sleep 45

STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='zerocpu_svc') ORDER BY id DESC LIMIT 1;")
MSG=$(sqlite3 "$TEST_DB" "SELECT message FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='zerocpu_svc') ORDER BY id DESC LIMIT 1;")

if [ "$STATUS" == "TIMEOUT" ] && [[ "$MSG" == *"Idle"* ]]; then
    pass "Zero-CPU process correctly timed out. Status=$STATUS, Msg=$MSG"
else
    fail "Zero-CPU process status: $STATUS, Msg: $MSG (expected TIMEOUT with 'Idle' in message)"
fi

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null
rm -f "$TEMP_SCHEDULER_ZEROCPU"

# Cleanup
cleanup_test_db "$TEST_DB"
rm -f "$TEMP_SCHEDULER"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
