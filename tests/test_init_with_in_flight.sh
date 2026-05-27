#!/bin/bash

# tests/test_init_with_in_flight.sh
#
# B2 contract: --init must be SAFE in the presence of a live scheduler.
#
# Today, `--init` blindly closes any RUNNING run as ABORTED without touching
# job rows or live processes. When the main scheduler loop is actively
# dispatching, this leaves the system in a confusing state:
#   - the run row is ABORTED but the loop's BG_PIDS keep churning,
#   - the main loop's next iteration opens a fresh run and may re-dispatch
#     services whose old jobs are still RUNNING in the now-ABORTED run.
#
# The minimum-safe fix is for --init to detect a live scheduler instance via
# the existing advisory lock file and REFUSE, directing the operator to send
# SIGTERM to the live instance (which has the proper drain machinery).
#
# Sub-cases:
#   B2a (REFUSE):  live scheduler running → --init exits non-zero, mentions
#                  the live PID, leaves the RUNNING run untouched.
#   B2b (PROCEED): no live scheduler, but a stale RUNNING run + RUNNING jobs
#                  in DB → --init closes the run ABORTED AND marks the
#                  RUNNING job rows ORPHANED (so --status is coherent
#                  immediately, without waiting for the next scheduler boot).
#   B2c (NO-OP):   no live scheduler, no in-flight run → --init logs a
#                  benign message, exits 0, DB unchanged.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] --init safety against live scheduler / in-flight state..."

# Common knobs — short interval + permissive resources so the main loop
# dispatches immediately.
export START_TIME=00:00
export END_TIME=23:59
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=3
export KILL_GRACE_SEC=1
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"

# ------------------------------------------------------------------
# B2a: live scheduler is running → --init must REFUSE.
# ------------------------------------------------------------------
echo ""
echo "--- B2a: REFUSE while live scheduler is running ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
LOCK_FILE="${TEST_DB}.lock"
rm -f "$LOCK_FILE"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-b2a', 1, 1);"

cleanup_b2a() {
    [ -n "$SCHED_PID" ] && kill -KILL "$SCHED_PID" 2>/dev/null
    wait 2>/dev/null
    rm -f "$LOCK_FILE"
}

"$SCHEDULER" >/dev/null 2>&1 &
SCHED_PID=$!

# Wait for the loop to enter the window, open a run, and dispatch.
DISPATCHED=0
for i in $(seq 1 30); do
    AUTO_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=1 AND status='RUNNING' AND run_id IS NOT NULL;")
    if [ "${AUTO_RUNNING:-0}" -ge 1 ]; then
        DISPATCHED=1
        break
    fi
    sleep 0.2
done

if [ "$DISPATCHED" -ne 1 ]; then
    echo "[Fail] B2a setup: main loop never dispatched within 6s."
    FAIL=$((FAIL + 1))
    cleanup_b2a
    cleanup_test_db "$TEST_DB"
    print_test_summary
    exit 1
fi

# Capture pre-state.
RUN_BEFORE=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;")
JOB_RUNNING_BEFORE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING';")

# Fire --init from a second shell while the main loop is live.
INIT_OUT=$(timeout 5s "$SCHEDULER" --init 2>&1)
INIT_EXIT=$?

# Post-state.
RUN_AFTER_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN_BEFORE;")
JOB_RUNNING_AFTER=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING';")

echo "[Result B2a] init exit=$INIT_EXIT, run #$RUN_BEFORE status: $RUN_AFTER_STATUS"
echo "[Result B2a] init output: $INIT_OUT"

# Expectations:
#   - non-zero exit
#   - message mentions a live scheduler (PID-aware diagnostic)
#   - RUNNING run UNTOUCHED (still RUNNING)
#   - RUNNING job count UNTOUCHED
#   - main scheduler still alive
if [ "$INIT_EXIT" -ne 0 ] \
   && echo "$INIT_OUT" | grep -qiE "scheduler.*running|PID" \
   && [ "$RUN_AFTER_STATUS" = "RUNNING" ] \
   && [ "$JOB_RUNNING_AFTER" = "$JOB_RUNNING_BEFORE" ] \
   && kill -0 "$SCHED_PID" 2>/dev/null; then
    echo "[Pass] B2a: --init refused while live scheduler running, state preserved."
    PASS=$((PASS + 1))
else
    echo "[Fail] B2a: expected refusal + preserved state."
    echo "       init_exit=$INIT_EXIT (want !=0)"
    echo "       run status='$RUN_AFTER_STATUS' (want RUNNING)"
    echo "       running jobs before=$JOB_RUNNING_BEFORE after=$JOB_RUNNING_AFTER"
    echo "       scheduler alive=$(kill -0 "$SCHED_PID" 2>/dev/null && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi

# Tear down the live scheduler gracefully so its drain trap fires.
kill -TERM "$SCHED_PID" 2>/dev/null
wait "$SCHED_PID" 2>/dev/null
SCHED_PID=""
cleanup_b2a
cleanup_test_db "$TEST_DB"

# ------------------------------------------------------------------
# B2b: no live scheduler, but a stale RUNNING run + RUNNING jobs in DB.
#      --init should close the run ABORTED AND mark stale RUNNING jobs
#      ORPHANED (so --status is coherent without waiting for next boot).
# ------------------------------------------------------------------
echo ""
echo "--- B2b: PROCEED (no live scheduler, in-flight DB state) ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
LOCK_FILE="${TEST_DB}.lock"
rm -f "$LOCK_FILE"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-b2b', 1, 1);"
# Seed a stale RUNNING run + a RUNNING job (no live process).
$DB_QUERY "INSERT INTO runs (started_at, status, triggered_by, total_services) \
           VALUES (datetime('now','localtime','-1 hour'), 'RUNNING', 'auto', 1);"
RUN_ID=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING';")
# Use a clearly-dead PID (a small number that is not in use; even if it happens
# to be, --init must not kill it — only update DB state).
$DB_QUERY "INSERT INTO jobs (service_id, run_id, status, start_time, pid) \
           VALUES (1, $RUN_ID, 'RUNNING', datetime('now','localtime','-30 minutes'), 99992);"

# Ensure no stale lock file claims ownership (we simulate a clean prior shutdown).
rm -f "$LOCK_FILE"

INIT_OUT=$("$SCHEDULER" --init 2>&1)
INIT_EXIT=$?

RUN_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN_ID;")
RUN_ENDED=$($DB_QUERY "SELECT ended_at FROM runs WHERE id=$RUN_ID;")
JOB_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE run_id=$RUN_ID;")
JOB_MSG=$($DB_QUERY "SELECT COALESCE(message,'') FROM jobs WHERE run_id=$RUN_ID;")

echo "[Result B2b] init exit=$INIT_EXIT, run status=$RUN_STATUS ended_at=$RUN_ENDED"
echo "[Result B2b] job status=$JOB_STATUS msg='$JOB_MSG'"
echo "[Result B2b] init output: $INIT_OUT"

if [ "$INIT_EXIT" = "0" ] \
   && [ "$RUN_STATUS" = "ABORTED" ] \
   && [ -n "$RUN_ENDED" ] \
   && [ "$JOB_STATUS" = "ORPHANED" ] \
   && echo "$JOB_MSG" | grep -qiE "init"; then
    echo "[Pass] B2b: --init closed run ABORTED and marked stale RUNNING job ORPHANED with hint."
    PASS=$((PASS + 1))
else
    echo "[Fail] B2b: expected ABORTED run + ORPHANED job with init-hint message."
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"

# ------------------------------------------------------------------
# B2b': PROCEED also when a STALE lock file is present but its PID is dead.
#       Don't false-refuse on lock-file litter from a prior crash.
# ------------------------------------------------------------------
echo ""
echo "--- B2b': PROCEED (stale lock file, dead PID) ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
LOCK_FILE="${TEST_DB}.lock"

# Build a stale lock file: pick a PID that is virtually certainly not alive
# (a high number, and verify it is dead before proceeding).
STALE_PID=2147483646
while kill -0 "$STALE_PID" 2>/dev/null; do
    STALE_PID=$((STALE_PID - 1))
done
printf '%s\n' "$STALE_PID" >"$LOCK_FILE"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-b2bp', 1, 1);"

INIT_OUT=$("$SCHEDULER" --init 2>&1)
INIT_EXIT=$?

echo "[Result B2b'] init exit=$INIT_EXIT"
echo "[Result B2b'] init output: $INIT_OUT"

if [ "$INIT_EXIT" = "0" ] \
   && ! echo "$INIT_OUT" | grep -qiE "refus"; then
    echo "[Pass] B2b': --init proceeded past stale lock file."
    PASS=$((PASS + 1))
else
    echo "[Fail] B2b': --init was wrongly refused on stale lock."
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"
rm -f "$LOCK_FILE"

# ------------------------------------------------------------------
# B2c: no live scheduler, no in-flight run → benign no-op.
# ------------------------------------------------------------------
echo ""
echo "--- B2c: NO-OP (no live scheduler, no in-flight run) ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
LOCK_FILE="${TEST_DB}.lock"
rm -f "$LOCK_FILE"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-b2c', 1, 1);"
# Plant a CLOSED run + COMPLETED job to make sure --init does NOT mutate them.
$DB_QUERY "INSERT INTO runs (started_at, ended_at, status, triggered_by, total_services, completed_count) \
           VALUES (datetime('now','localtime','-1 hour'), datetime('now','localtime','-30 minutes'), 'COMPLETED', 'auto', 1, 1);"
$DB_QUERY "INSERT INTO jobs (service_id, run_id, status, start_time, end_time) \
           VALUES (1, 1, 'COMPLETED', datetime('now','localtime','-1 hour'), datetime('now','localtime','-30 minutes'));"

RUNS_BEFORE=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
JOBS_BEFORE=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
RUN1_STATUS_BEFORE=$($DB_QUERY "SELECT status FROM runs WHERE id=1;")

INIT_OUT=$("$SCHEDULER" --init 2>&1)
INIT_EXIT=$?

RUNS_AFTER=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
JOBS_AFTER=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
RUN1_STATUS_AFTER=$($DB_QUERY "SELECT status FROM runs WHERE id=1;")

echo "[Result B2c] init exit=$INIT_EXIT, runs $RUNS_BEFORE->$RUNS_AFTER, jobs $JOBS_BEFORE->$JOBS_AFTER"
echo "[Result B2c] init output: $INIT_OUT"

if [ "$INIT_EXIT" = "0" ] \
   && [ "$RUNS_AFTER" = "$RUNS_BEFORE" ] \
   && [ "$JOBS_AFTER" = "$JOBS_BEFORE" ] \
   && [ "$RUN1_STATUS_AFTER" = "$RUN1_STATUS_BEFORE" ] \
   && echo "$INIT_OUT" | grep -qiE "no in-flight run|no.*abort"; then
    echo "[Pass] B2c: --init was a benign no-op with coherent log."
    PASS=$((PASS + 1))
else
    echo "[Fail] B2c: expected no-op exit=0 with unchanged DB and benign log."
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
