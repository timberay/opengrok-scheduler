#!/bin/bash

# tests/test_sigterm_cleanup.sh
# Test that SIGTERM triggers graceful cleanup of background processes.
#
# Reliability notes:
# - The default `run_indexing_task` placeholder sleeps for only 2 seconds, so
#   spawned jobs would race past SIGTERM before this test could send it.
#   Mirror the test_idle_timeout.sh pattern: write a temp scheduler copy whose
#   placeholder is replaced with `sleep 60`, ensuring the job is in-flight
#   when SIGTERM arrives.
# - Use verify_pid_identity (PID + starttime) to confirm the original job
#   process is gone, defending against PID reuse during the wait window.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"
source "$PROJECT_ROOT/bin/monitor.sh"  # for verify_pid_identity
BIN_DIR="$PROJECT_ROOT/bin"

pass() { echo "[Pass] $1"; ((PASS++)); }
fail() { echo "[Fail] $1"; ((FAIL++)); }

echo "=============================="
echo "[Test] SIGTERM Cleanup"
echo "=============================="

# Build a scheduler variant whose indexing placeholder runs long enough to
# still be alive when we send SIGTERM. Must live inside BIN_DIR so its
# `source common.sh` resolves correctly.
TEMP_SCHEDULER=$(mktemp "$BIN_DIR/scheduler_test_sigterm_XXXXXX.sh")
sed 's|timeout --kill-after=10s "\$MAX_DURATION" bash -c "sleep 2"|timeout --kill-after=10s "$MAX_DURATION" bash -c "sleep 60"|' \
    "$BIN_DIR/scheduler.sh" > "$TEMP_SCHEDULER"
chmod +x "$TEMP_SCHEDULER"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

cleanup_all() {
    [ -n "$SCHEDULER_PID" ] && kill -KILL "$SCHEDULER_PID" 2>/dev/null
    [ -n "$SCHEDULER_PID" ] && wait "$SCHEDULER_PID" 2>/dev/null
    [ -n "$JOB_PID" ] && kill -KILL "$JOB_PID" 2>/dev/null
    rm -f "$TEMP_SCHEDULER"
    cleanup_test_db "$TEST_DB"
}
trap cleanup_all EXIT

sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('sigterm_svc', 1, 1);"

export JOB_IDLE_TIMEOUT=0
export JOB_TIMEOUT_SEC=300
export CHECK_INTERVAL=2
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=200
export KILL_GRACE_SEC=2
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"

echo ""
echo "[Case 1] SIGTERM terminates running job and marks it ORPHANED"

bash "$TEMP_SCHEDULER" &
SCHEDULER_PID=$!

# Poll until the scheduler has a RUNNING job recorded with a PID and
# pid_starttime. Bail out after 30s if nothing started — that itself is
# a regression we want to catch (not silently skip like the old test).
JOB_PID=""
JOB_STARTTIME=""
DEADLINE=$((SECONDS + 30))
while [ $SECONDS -lt $DEADLINE ]; do
    ROW=$(sqlite3 "$TEST_DB" "SELECT pid, pid_starttime FROM jobs WHERE status='RUNNING' AND pid IS NOT NULL AND pid_starttime IS NOT NULL LIMIT 1;")
    if [ -n "$ROW" ]; then
        JOB_PID=${ROW%%|*}
        JOB_STARTTIME=${ROW##*|}
        break
    fi
    sleep 1
done

if [ -z "$JOB_PID" ] || [ -z "$JOB_STARTTIME" ]; then
    fail "Scheduler did not produce a RUNNING job within 30s"
    print_test_summary
    exit $?
fi

pass "Scheduler started a job (PID=$JOB_PID, starttime=$JOB_STARTTIME)"

# Sanity: the recorded job process is genuinely alive right now.
if verify_pid_identity "$JOB_PID" "$JOB_STARTTIME"; then
    pass "Job (PID,starttime) verified alive before SIGTERM"
else
    fail "Job (PID=$JOB_PID, starttime=$JOB_STARTTIME) was not alive before SIGTERM"
fi

kill -TERM "$SCHEDULER_PID" 2>/dev/null

# Wait for scheduler to exit, but cap at 30s so a hung cleanup_and_exit
# fails loudly instead of stalling the suite.
WAIT_DEADLINE=$((SECONDS + 30))
while kill -0 "$SCHEDULER_PID" 2>/dev/null && [ $SECONDS -lt $WAIT_DEADLINE ]; do
    sleep 1
done
wait "$SCHEDULER_PID" 2>/dev/null
SCHED_RC=$?

if kill -0 "$SCHEDULER_PID" 2>/dev/null; then
    fail "Scheduler did not exit within 30s of SIGTERM (rc=$SCHED_RC)"
else
    pass "Scheduler exited after SIGTERM (rc=$SCHED_RC)"
fi
SCHEDULER_PID=""  # disarm trap kill

# After cleanup, the original (PID,starttime) tuple must no longer identify
# a live process. (PID may be recycled to something unrelated; starttime
# differing is also acceptable.)
if verify_pid_identity "$JOB_PID" "$JOB_STARTTIME"; then
    fail "Original job (PID=$JOB_PID, starttime=$JOB_STARTTIME) still alive after SIGTERM"
else
    pass "Original job (PID,starttime) no longer alive after SIGTERM"
fi
JOB_PID=""  # disarm trap kill

FINAL_STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs ORDER BY id DESC LIMIT 1;")
FINAL_MSG=$(sqlite3 "$TEST_DB" "SELECT message FROM jobs ORDER BY id DESC LIMIT 1;")

if [ "$FINAL_STATUS" = "ORPHANED" ]; then
    pass "Job final status=ORPHANED"
else
    fail "Job final status=$FINAL_STATUS (expected ORPHANED)"
fi

if [[ "$FINAL_MSG" == *"Scheduler shutdown"* ]]; then
    pass "Job message contains 'Scheduler shutdown' ($FINAL_MSG)"
else
    fail "Job message='$FINAL_MSG' (expected to contain 'Scheduler shutdown')"
fi

print_test_summary
exit $?
