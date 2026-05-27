#!/bin/bash
# tests/test_window_close_during_run.sh
# Case A2 — window-end with in-flight jobs.
#
# Scenario:
#   The scheduler is inside its working window and has dispatched one or more
#   background indexing jobs. While at least one job is still RUNNING, the
#   window CLOSES (wall-clock crosses END_TIME). The scheduler must:
#     1. Drain every tracked in-flight background PID (kill the process tree).
#     2. Transition every still-RUNNING jobs row in the closing run to
#        ORPHANED with message='Window closed' and end_time set.
#     3. Close the run as PARTIAL (not COMPLETED — some services didn't finish).
#     4. Leave no leaked OS processes from the closing window.
#     5. When the window re-opens later, a NEW run id is created with no
#        interference from the prior PARTIAL run.
#
# Why this is interesting:
#   START_TIME/END_TIME are env vars read EACH loop iteration. To force a
#   window-close mid-run we open a ~1-minute window that ends shortly after
#   launch, wait through the boundary, then verify the drain + PARTIAL close.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"
source "$PROJECT_ROOT/bin/monitor.sh"   # verify_pid_identity
BIN_DIR="$PROJECT_ROOT/bin"

echo "=== Test: window-close drains in-flight jobs, marks run PARTIAL (A2) ==="

PASS=0
FAIL=0
pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

SCHED_PID=""
SCHED_PID_2=""
TMP_LOG=""
TMP_LOG_2=""
TEMP_SCHEDULER=""
TEST_DB=""
TRACKED_PIDS=()

cleanup() {
    for pid in "$SCHED_PID" "$SCHED_PID_2"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null
            for _ in $(seq 1 10); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    done
    # Reap any tracked job descendants we recorded.
    for pid in "${TRACKED_PIDS[@]}"; do
        [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
    done
    # Best-effort: any subprocess started under this test process tree.
    pkill -P $$ 2>/dev/null
    [ -n "$TMP_LOG" ] && rm -f "$TMP_LOG"
    [ -n "$TMP_LOG_2" ] && rm -f "$TMP_LOG_2"
    [ -n "$TEMP_SCHEDULER" ] && rm -f "$TEMP_SCHEDULER"
    [ -n "$TEST_DB" ] && cleanup_test_db "$TEST_DB"
}
trap cleanup EXIT

# --- 1. Build a scheduler variant whose dummy task lasts long enough -----
# The stock placeholder runs `sleep 2`, which finishes well before any
# window boundary we can reliably wait for. Replace it with `sleep 120`
# so jobs are still RUNNING when the window closes. The temp file lives
# in BIN_DIR so its internal `source common.sh` resolves correctly.
TEMP_SCHEDULER=$(mktemp "$BIN_DIR/scheduler_test_window_close_XXXXXX.sh")
sed 's|timeout --kill-after=10s "\$MAX_DURATION" bash -c "sleep 2"|timeout --kill-after=10s "$MAX_DURATION" bash -c "sleep 120"|' \
    "$BIN_DIR/scheduler.sh" > "$TEMP_SCHEDULER"
chmod +x "$TEMP_SCHEDULER"

# --- 2. Seed an isolated DB with 3 active services -----------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-a', 1, 1),
    ('svc-b', 1, 1),
    ('svc-c', 1, 1);"

# --- 3. Set up a ~1-minute window that ends mid-test ---------------------
# Wait until we have enough slack in the current minute that the scheduler
# can launch and dispatch at least one job before the boundary fires.
# If we are too close to the next minute, sleep until just after the tick
# so the window we open has predictable >=30s of dispatch headroom.
CUR_SEC=$(date +%S)
# Trim leading zero to avoid bash octal parsing of values like '08'.
CUR_SEC=$((10#$CUR_SEC))
if [ "$CUR_SEC" -gt 30 ]; then
    SLEEP_TO_NEXT_MINUTE=$((60 - CUR_SEC + 1))
    echo "Sleeping ${SLEEP_TO_NEXT_MINUTE}s to align with start of next minute (slack=$((60 - CUR_SEC))s)..."
    sleep "$SLEEP_TO_NEXT_MINUTE"
fi

NOW_HM=$(date +%H:%M)
END_HM=$(date -d "+1 minute" +%H:%M)
WINDOW_START_EPOCH=$(date +%s)
# Time until the next minute boundary (when END_HM trips check_time_range).
WINDOW_END_EPOCH=$(date -d "$(date +%Y-%m-%d) $END_HM:00" +%s)
WINDOW_REMAINING=$((WINDOW_END_EPOCH - WINDOW_START_EPOCH))
echo "Window: $NOW_HM ~ $END_HM (closes in ~${WINDOW_REMAINING}s)"

export START_TIME="$NOW_HM"
export END_TIME="$END_HM"
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=3
export JOB_IDLE_TIMEOUT=0
export JOB_TIMEOUT_SEC=300
export KILL_GRACE_SEC=1
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"

TMP_LOG=$(mktemp /tmp/test_window_close_during_run.XXXXXX.log)

# Total wall-time we let the scheduler run: window remainder + drain grace.
SCHED_TIMEOUT=$((WINDOW_REMAINING + 15))
[ "$SCHED_TIMEOUT" -lt 30 ] && SCHED_TIMEOUT=30
timeout "${SCHED_TIMEOUT}s" bash "$TEMP_SCHEDULER" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

# --- 4. Wait until at least one job is RUNNING (contract assertion 1) ---
RUN_ID=""
IN_FLIGHT_PID=""
IN_FLIGHT_STARTTIME=""
DEADLINE_EPOCH=$((WINDOW_END_EPOCH - 5))   # leave 5s headroom for the close
NOW_EPOCH=$(date +%s)
while [ "$NOW_EPOCH" -lt "$DEADLINE_EPOCH" ]; do
    ROW=$($DB_QUERY "SELECT pid, pid_starttime FROM jobs WHERE status='RUNNING' AND pid IS NOT NULL AND pid_starttime IS NOT NULL LIMIT 1;" 2>/dev/null)
    if [ -n "$ROW" ]; then
        IN_FLIGHT_PID=${ROW%%|*}
        IN_FLIGHT_STARTTIME=${ROW##*|}
        RUN_ID=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;")
        break
    fi
    sleep 1
    NOW_EPOCH=$(date +%s)
done

if [ -z "$IN_FLIGHT_PID" ]; then
    fail "C1: no RUNNING job appeared before window-close deadline"
    echo "--- scheduler log ---"; tail -40 "$TMP_LOG"
    print_test_summary
    exit $?
fi
pass "C1: at least one RUNNING job in run #$RUN_ID before window close (PID=$IN_FLIGHT_PID)"
TRACKED_PIDS+=("$IN_FLIGHT_PID")

# Collect every dispatched PID for the leak check after close.
mapfile -t ALL_RUN_PIDS < <($DB_QUERY "SELECT pid FROM jobs WHERE run_id=$RUN_ID AND pid IS NOT NULL;")
for p in "${ALL_RUN_PIDS[@]}"; do
    [ -n "$p" ] && TRACKED_PIDS+=("$p")
done

# Verify the recorded PID really is alive (sanity).
if verify_pid_identity "$IN_FLIGHT_PID" "$IN_FLIGHT_STARTTIME"; then
    pass "C1: in-flight job process is genuinely alive pre-close"
else
    fail "C1: recorded PID=$IN_FLIGHT_PID failed identity check before close"
fi

# --- 5. Wait through the window boundary --------------------------------
# Sleep until ~3s past the end of the closing minute so the scheduler has
# at least one loop tick to observe `check_time_range == false` and
# execute the drain + run_close branch.
WAIT_TO_CLOSE=$((WINDOW_END_EPOCH - $(date +%s) + 5))
[ "$WAIT_TO_CLOSE" -lt 1 ] && WAIT_TO_CLOSE=1
echo "Waiting ${WAIT_TO_CLOSE}s for window boundary + drain..."
sleep "$WAIT_TO_CLOSE"

# Give the scheduler a few extra ticks (CHECK_INTERVAL=1, drain SIGTERM
# grace=1s) to complete the drain + run_close path before we assert.
for _ in $(seq 1 15); do
    POST_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN_ID;" 2>/dev/null)
    [ "$POST_STATUS" = "PARTIAL" ] && break
    sleep 1
done

# --- 6. Stop the scheduler so we can assert against a quiescent system ---
if kill -0 "$SCHED_PID" 2>/dev/null; then
    kill -TERM "$SCHED_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHED_PID" 2>/dev/null || break
        sleep 1
    done
    wait "$SCHED_PID" 2>/dev/null
fi
SCHED_PID=""
sleep 1   # let the kernel reap residual children

# --- 7. Contract assertions ---------------------------------------------

# Assertion 2: no jobs row in this run is RUNNING anymore.
LEFT_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='RUNNING';")
assert_eq "C2: no RUNNING jobs remain in closed run #$RUN_ID" "0" "$LEFT_RUNNING"

# Assertion 3: every drained row is ORPHANED with the documented message
# and an end_time. There must be at least one such row (we verified at
# least one job was in-flight pre-close).
ORPH_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='ORPHANED' AND message='Window closed';")
if [ "${ORPH_COUNT:-0}" -ge 1 ]; then
    pass "C3: $ORPH_COUNT job(s) marked ORPHANED with message='Window closed'"
else
    fail "C3: expected >=1 ORPHANED 'Window closed' row, got $ORPH_COUNT"
fi

ORPH_NO_END=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='ORPHANED' AND end_time IS NULL;")
assert_eq "C3: every ORPHANED row in the run has end_time set" "0" "$ORPH_NO_END"

# Assertion 4: the run itself is PARTIAL, not COMPLETED.
RUN_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN_ID;")
assert_eq "C4: run #$RUN_ID closed as PARTIAL" "PARTIAL" "$RUN_STATUS"

RUN_ENDED=$($DB_QUERY "SELECT ended_at IS NOT NULL FROM runs WHERE id=$RUN_ID;")
assert_eq "C4: ended_at populated on PARTIAL run" "1" "$RUN_ENDED"

# orphaned_count rollup on the run should reflect what we drained.
RUN_ORPH=$($DB_QUERY "SELECT orphaned_count FROM runs WHERE id=$RUN_ID;")
if [ "${RUN_ORPH:-0}" -ge 1 ]; then
    pass "C4: runs.orphaned_count=$RUN_ORPH reflects drain"
else
    fail "C4: runs.orphaned_count=$RUN_ORPH (expected >=1)"
fi

# Assertion 5: no leaked OS processes from the closing window.
# Use identity-verified check — bare `kill -0` would false-positive on a
# recycled PID.
LEAKED=0
LEAKED_LIST=""
while IFS='|' read -r LPID LSTART; do
    [ -z "$LPID" ] && continue
    if verify_pid_identity "$LPID" "$LSTART" 2>/dev/null; then
        LEAKED=$((LEAKED+1))
        LEAKED_LIST="$LEAKED_LIST $LPID"
    fi
done < <($DB_QUERY "SELECT pid, pid_starttime FROM jobs WHERE run_id=$RUN_ID AND pid IS NOT NULL;")
if [ "$LEAKED" = "0" ]; then
    pass "C5: no leaked indexing processes from closed window"
else
    fail "C5: $LEAKED leaked PID(s) survived window close:$LEAKED_LIST"
fi

# Assertion 6: re-launching the scheduler with an always-open window opens
# a fresh run that does not interfere with the PARTIAL run.
echo ""
echo "--- C6: post-close restart opens a new run ---"

# Clear the window vars from the prior run; new window is always-open so the
# scheduler must dispatch immediately.
export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1

TMP_LOG_2=$(mktemp /tmp/test_window_close_during_run_phase2.XXXXXX.log)
# Use the stock scheduler (sleep 2) so jobs complete naturally — we only
# need to observe that a NEW run opens and is not blocked by the prior
# PARTIAL row.
timeout 20s "$BIN_DIR/scheduler.sh" >"$TMP_LOG_2" 2>&1 &
SCHED_PID_2=$!

NEW_RUN_ID=""
DEADLINE=$(( $(date +%s) + 18 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    NEW_RUN_ID=$($DB_QUERY "SELECT id FROM runs WHERE id > $RUN_ID ORDER BY id DESC LIMIT 1;" 2>/dev/null)
    [ -n "$NEW_RUN_ID" ] && break
    sleep 1
done

if kill -0 "$SCHED_PID_2" 2>/dev/null; then
    kill -TERM "$SCHED_PID_2" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHED_PID_2" 2>/dev/null || break
        sleep 1
    done
    wait "$SCHED_PID_2" 2>/dev/null
fi
SCHED_PID_2=""

if [ -n "$NEW_RUN_ID" ] && [ "$NEW_RUN_ID" -gt "$RUN_ID" ]; then
    pass "C6: post-close restart opened a new run #$NEW_RUN_ID (>$RUN_ID)"
else
    fail "C6: no new run was opened after restart (last_id=$RUN_ID, new=${NEW_RUN_ID:-<none>})"
fi

# The PARTIAL run must remain untouched.
PRIOR_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN_ID;")
assert_eq "C6: prior run #$RUN_ID stays PARTIAL across restart" "PARTIAL" "$PRIOR_STATUS"

# Diagnostic dump on failure.
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "--- scheduler log (phase 1, last 60 lines) ---"
    tail -60 "$TMP_LOG"
    if [ -n "$TMP_LOG_2" ] && [ -s "$TMP_LOG_2" ]; then
        echo "--- scheduler log (phase 2, last 30 lines) ---"
        tail -30 "$TMP_LOG_2"
    fi
    echo "--- runs ---"
    $DB_QUERY "SELECT id,status,triggered_by,started_at,ended_at,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
    echo "--- jobs ---"
    $DB_QUERY "SELECT id,service_id,run_id,status,pid,start_time,end_time,message FROM jobs ORDER BY id;"
fi

print_test_summary
