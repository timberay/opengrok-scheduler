#!/bin/bash
# tests/test_full_daily_cycle.sh
# Case A1 — Full daily cycle happy path.
#
# Scenario:
#   Scheduler enters its window, dispatches every active service, all complete
#   cleanly, the run closes COMPLETED, no errors / stale rows / leaked PIDs.
#
# Contract verified (see Scenario A1 spec):
#   1. Before window open: scheduler is idle (no RUNNING run row).
#      (Pre-spawn snapshot of the seeded DB.)
#   2. On window entry: exactly one runs row opens with status=RUNNING,
#      triggered_by=auto, total_services snapshotted correctly.
#   3. During dispatch: each active service gets a jobs row with run_id=current,
#      status transitions RUNNING -> COMPLETED.
#   4. After every service is done: the run closes COMPLETED, completed_count
#      matches total_services, ended_at is set.
#   5. No duplicate jobs for any (service_id, run_id) tuple.
#   6. No leaked background processes after the run closes (we sent SIGTERM
#      to the scheduler; every spawned indexing child must be gone).
#   7. Heartbeat is updated regularly (heartbeat.last_pulse is fresh).
#   8. Run lifecycle counters accurate: completed_count=N_services,
#      failed_count=timeout_count=orphaned_count=0.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== Test: Full daily cycle happy path (A1) ==="

PASS=0
FAIL=0
pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

SCHED_PID=""
TMP_LOG=""
TEST_DB=""

cleanup() {
    if [ -n "$SCHED_PID" ] && kill -0 "$SCHED_PID" 2>/dev/null; then
        kill -TERM "$SCHED_PID" 2>/dev/null
        # Give cleanup_and_exit a moment to drain.
        for _ in $(seq 1 10); do
            kill -0 "$SCHED_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SCHED_PID" 2>/dev/null
        wait "$SCHED_PID" 2>/dev/null
    fi
    # Kill any orphaned descendants started under this test process tree.
    pkill -P $$ 2>/dev/null
    [ -n "$TMP_LOG" ] && rm -f "$TMP_LOG"
    [ -n "$TEST_DB" ] && cleanup_test_db "$TEST_DB"
}
trap cleanup EXIT

# --- 1. Set up isolated DB with 3 active services -------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-alpha', 1, 1),
    ('svc-beta',  1, 1),
    ('svc-gamma', 1, 1);"

# Contract item 1: nothing is RUNNING before we even start the scheduler.
PRE_RUN_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE status='RUNNING';")
[ "$PRE_RUN_COUNT" = "0" ] && pass "C1: no RUNNING run before scheduler starts" \
                           || fail "C1: expected 0 RUNNING runs pre-start, got $PRE_RUN_COUNT"

PRE_JOB_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
[ "$PRE_JOB_COUNT" = "0" ] && pass "C1: no jobs before scheduler starts" \
                           || fail "C1: expected 0 jobs pre-start, got $PRE_JOB_COUNT"

# --- 2. Launch the scheduler with an always-open window -------------------
export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=3
# Shrink idle-detection so it doesn't kick in during the test (the dummy
# sleep 2 task uses no CPU and could trip JOB_IDLE_TIMEOUT defaults).
export JOB_IDLE_TIMEOUT=0

TMP_LOG=$(mktemp /tmp/test_full_daily_cycle.XXXXXX.log)

timeout 30s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

# --- 3. Wait for all 3 services to reach COMPLETED ------------------------
# With CHECK_INTERVAL=1 and a 2-second dummy task, each service dispatches
# on a separate loop iteration. 3 services + reap cycles = a handful of
# seconds, but we allow up to 25s for slow CI.
DEADLINE=$(( $(date +%s) + 25 ))
RUN_ID=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    COMPLETED=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED';" 2>/dev/null)
    if [ "${COMPLETED:-0}" -ge 3 ]; then
        # Wait one more loop tick so the scheduler observes the
        # natural-completion condition and closes the run.
        for _ in $(seq 1 10); do
            RUN_STATUS=$($DB_QUERY "SELECT status FROM runs ORDER BY id DESC LIMIT 1;" 2>/dev/null)
            [ "$RUN_STATUS" = "COMPLETED" ] && break
            sleep 1
        done
        break
    fi
    sleep 1
done

RUN_ID=$($DB_QUERY "SELECT id FROM runs ORDER BY id DESC LIMIT 1;")
RUN_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN_ID;")

# --- 4. Stop scheduler cleanly before asserting --------------------------
# We need the scheduler stopped before checking for leaked PIDs (contract C6).
if kill -0 "$SCHED_PID" 2>/dev/null; then
    kill -TERM "$SCHED_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHED_PID" 2>/dev/null || break
        sleep 1
    done
    wait "$SCHED_PID" 2>/dev/null
fi
SCHED_PID=""

# Give the kernel a brief moment to fully reap any exiting children we spawned.
sleep 1

# --- 5. Contract assertions ----------------------------------------------

# Contract item 2: exactly one runs row with the expected fields.
RUN_ROW_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
assert_eq "C2: exactly one runs row created" "1" "$RUN_ROW_COUNT"

RUN_TRIGGER=$($DB_QUERY "SELECT triggered_by FROM runs WHERE id=$RUN_ID;")
assert_eq "C2: run triggered_by=auto" "auto" "$RUN_TRIGGER"

RUN_TOTAL=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$RUN_ID;")
assert_eq "C2: total_services snapshot=3" "3" "$RUN_TOTAL"

# Contract item 3: every active service has a job row with the right run_id,
# and every one of those job rows is COMPLETED.
JOB_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID;")
assert_eq "C3: one job row per service in the run" "3" "$JOB_COUNT"

COMPLETED_JOBS=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='COMPLETED';")
assert_eq "C3: all jobs reached COMPLETED" "3" "$COMPLETED_JOBS"

# All three service ids are present (no service was skipped).
DISTINCT_SVCS=$($DB_QUERY "SELECT COUNT(DISTINCT service_id) FROM jobs WHERE run_id=$RUN_ID;")
assert_eq "C3: every distinct active service covered" "3" "$DISTINCT_SVCS"

# Contract item 4: run closed COMPLETED with ended_at populated.
assert_eq "C4: run status=COMPLETED" "COMPLETED" "$RUN_STATUS"

ENDED_NOT_NULL=$($DB_QUERY "SELECT ended_at IS NOT NULL FROM runs WHERE id=$RUN_ID;")
assert_eq "C4: ended_at is set" "1" "$ENDED_NOT_NULL"

COMPLETED_COUNT=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$RUN_ID;")
assert_eq "C4: completed_count matches total_services" "3" "$COMPLETED_COUNT"

# Contract item 5: no (service_id, run_id) duplicates.
DUP_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM (
    SELECT service_id, run_id, COUNT(*) AS n FROM jobs
    WHERE run_id=$RUN_ID GROUP BY service_id, run_id HAVING n > 1
);")
assert_eq "C5: no duplicate jobs per service in the run" "0" "$DUP_COUNT"

# Contract item 6: no leaked background PIDs.
# Every job row we inserted has a recorded pid; none of them should still
# be alive now that the scheduler has exited and reaped its children.
LEAKED=0
LEAKED_LIST=""
while IFS='|' read -r PID PSTART; do
    [ -z "$PID" ] && continue
    if kill -0 "$PID" 2>/dev/null; then
        # Same PID could have been recycled. Confirm identity via starttime
        # if we have it, otherwise treat as a leak (conservative).
        if [ -n "$PSTART" ] && [ -r "/proc/$PID/stat" ]; then
            CUR_STARTTIME=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null)
            if [ "$CUR_STARTTIME" = "$PSTART" ]; then
                LEAKED=$((LEAKED+1))
                LEAKED_LIST="$LEAKED_LIST $PID"
            fi
        else
            LEAKED=$((LEAKED+1))
            LEAKED_LIST="$LEAKED_LIST $PID"
        fi
    fi
done < <($DB_QUERY "SELECT pid, pid_starttime FROM jobs WHERE run_id=$RUN_ID;")
[ "$LEAKED" = "0" ] && pass "C6: no leaked background indexing PIDs" \
                    || fail "C6: $LEAKED leaked PID(s):$LEAKED_LIST"

# Contract item 7: heartbeat was updated. last_pulse must exist and must be
# recent (within the test window).
HEARTBEAT_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM heartbeat;")
assert_eq "C7: heartbeat row exists" "1" "$HEARTBEAT_COUNT"
HEARTBEAT_FRESH=$($DB_QUERY "SELECT (strftime('%s','now') - strftime('%s', last_pulse)) < 120 FROM heartbeat WHERE id=1;")
assert_eq "C7: heartbeat is fresh (<120s old)" "1" "$HEARTBEAT_FRESH"

# Contract item 8: lifecycle counters are accurate.
FAILED_COUNT=$($DB_QUERY "SELECT failed_count FROM runs WHERE id=$RUN_ID;")
TIMEOUT_COUNT=$($DB_QUERY "SELECT timeout_count FROM runs WHERE id=$RUN_ID;")
ORPHANED_COUNT=$($DB_QUERY "SELECT orphaned_count FROM runs WHERE id=$RUN_ID;")
assert_eq "C8: failed_count=0" "0" "$FAILED_COUNT"
assert_eq "C8: timeout_count=0" "0" "$TIMEOUT_COUNT"
assert_eq "C8: orphaned_count=0" "0" "$ORPHANED_COUNT"

# Diagnostic dump on failure so iteration debugging is easier.
if [ "$FAIL" -gt 0 ]; then
    echo "--- scheduler log (last 40 lines) ---"
    tail -40 "$TMP_LOG"
    echo "--- runs table ---"
    $DB_QUERY "SELECT id,status,triggered_by,started_at,ended_at,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
    echo "--- jobs table ---"
    $DB_QUERY "SELECT id,service_id,run_id,status,pid,start_time,end_time FROM jobs;"
fi

print_test_summary
