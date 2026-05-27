#!/bin/bash

# tests/test_service_main_loop_collision.sh
# Verify that the --service (manual trigger) admission path refuses to
# dispatch a second concurrent job for a service that is ALREADY RUNNING,
# whether dispatched by the main scheduler loop or another --service call.
#
# Background: the --service branch exits before the main-loop's advisory
# flock is acquired, so it can run concurrently with a live scheduler
# instance. Without a per-service guard, a manual trigger for svc-X while
# the main loop is already running svc-X inserts a SECOND RUNNING jobs row
# and spawns a second indexing task — exactly the "indexing thundering
# herd" the concurrency cap was supposed to prevent.
#
# This test pins:
#   B1a: With main loop running svc-collision, an immediate --service
#        invocation for the same service is REFUSED with "Service already
#        running" and no duplicate RUNNING row is created.
#   B1b: When the global cap is full from main loop activity, --service
#        for a DIFFERENT (idle) service is refused with the
#        "Concurrency cap reached" message. Distinguishes cap-vs-collision
#        diagnostics so operators can tell the two cases apart.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] --service vs main-loop collision guard..."

# Common knobs — short interval + permissive resources so the main loop
# dispatches immediately.
export START_TIME=00:00
export END_TIME=23:59
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export KILL_GRACE_SEC=1

# ------------------------------------------------------------------
# B1a: main loop dispatches svc-collision, --service for SAME svc refused
# ------------------------------------------------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

# Only ONE active service so main loop's NEXT_SERVICE_ID always picks it.
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-collision', 1, 1);"

# Generous cap so the test failure mode is "duplicate row admitted",
# not "cap blocked it". We want the per-service guard to be the only
# thing standing between us and a duplicate dispatch.
export MAX_CONCURRENT_JOBS=5

LOCK_FILE="${TEST_DB}.lock"
rm -f "$LOCK_FILE"

cleanup_b1a() {
    [ -n "$SCHED_PID" ] && kill -KILL "$SCHED_PID" 2>/dev/null
    wait 2>/dev/null
    rm -f "$LOCK_FILE"
}

# Patch indexing task to a longer sleep so the RUNNING window is wide
# enough for the race. We do this by exporting an override that the test
# can rely on — but since run_indexing_task is hardcoded to `sleep 2`,
# we need a longer service execution overlap. Instead, use sleep cycles
# in the test: poll quickly for the RUNNING row, then fire --service
# while the 2-second sleep is in flight.

"$SCHEDULER" >/dev/null 2>&1 &
SCHED_PID=$!

# Poll for the auto-dispatched RUNNING row (run_id non-null).
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
    echo "[Fail] B1a setup: main loop never dispatched svc-collision within 6s."
    FAIL=$((FAIL + 1))
    cleanup_b1a
    cleanup_test_db "$TEST_DB"
    print_test_summary
    exit 1
fi

echo "[Info] B1a: main-loop dispatched svc-collision; firing --service for the same svc..."

# Fire --service for the SAME service. Run with a timeout so a regression
# (where it actually starts a 2-second indexing run) doesn't hang the
# test fixture forever — but cap is high enough that the duplicate would
# succeed without the guard.
MANUAL_OUT=$(timeout 6s "$SCHEDULER" --service svc-collision 2>&1)
MANUAL_EXIT=$?

# Snapshot RUNNING duplicates BEFORE the manual job's own sleep finishes —
# if the guard didn't fire, we'd see 2 RUNNING rows (auto + manual)
# simultaneously here.
DUP_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=1 AND status='RUNNING';")
MANUAL_ROW=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=1 AND run_id IS NULL;")

echo "[Result B1a] manual exit=$MANUAL_EXIT, RUNNING rows for svc-collision=$DUP_RUNNING, manual rows (run_id NULL)=$MANUAL_ROW"
echo "[Result B1a] manual output: $MANUAL_OUT"

# Expectations (post-fix):
#   - Manual exits non-zero (refused).
#   - No NULL-run_id row was ever inserted (NEW_MANUAL_ROW = 0).
#   - At most 1 RUNNING row for svc-collision at this snapshot.
#   - Diagnostic mentions "already running".
if [ "$MANUAL_EXIT" -ne 0 ] \
   && [ "$MANUAL_ROW" = "0" ] \
   && [ "$DUP_RUNNING" -le 1 ] \
   && echo "$MANUAL_OUT" | grep -qiE "already running"; then
    echo "[Pass] B1a: --service refused duplicate dispatch with proper diagnostic."
    PASS=$((PASS + 1))
else
    echo "[Fail] B1a: duplicate dispatch was NOT prevented."
    echo "       Expected: exit!=0, manual_row=0, dup_running<=1, output ~ 'already running'"
    FAIL=$((FAIL + 1))
fi

# Tear down scheduler. Wait briefly for the in-flight auto job's sleep 2
# to finish so cleanup doesn't have to SIGKILL it.
kill -TERM "$SCHED_PID" 2>/dev/null
wait "$SCHED_PID" 2>/dev/null
SCHED_PID=""
cleanup_b1a
cleanup_test_db "$TEST_DB"

# ------------------------------------------------------------------
# B1b: cap full from main loop, --service for DIFFERENT svc → cap msg
# (Regression for existing cap-message diagnostic — ensures the new
# guard doesn't accidentally mask the cap-reached error path.)
# ------------------------------------------------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
LOCK_FILE="${TEST_DB}.lock"
rm -f "$LOCK_FILE"

# Two services; one will be artificially marked RUNNING to fill the cap,
# the other will be the manual --service target.
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-busy', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-idle', 1, 1);"

# Cap = 1, with svc-busy already RUNNING. --service for svc-idle must be
# refused with the cap message (NOT the "already running" message —
# svc-idle has no RUNNING row).
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, pid) VALUES (1, 'RUNNING', datetime('now','localtime'), 99991);"
export MAX_CONCURRENT_JOBS=1

MANUAL_OUT=$("$SCHEDULER" --service svc-idle 2>&1)
MANUAL_EXIT=$?
IDLE_ROWS=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=2;")

echo "[Result B1b] manual exit=$MANUAL_EXIT, jobs for svc-idle=$IDLE_ROWS"
echo "[Result B1b] manual output: $MANUAL_OUT"

if [ "$MANUAL_EXIT" -ne 0 ] \
   && [ "$IDLE_ROWS" = "0" ] \
   && echo "$MANUAL_OUT" | grep -qiE "concurrency cap"; then
    echo "[Pass] B1b: cap-reached diagnostic still fires for distinct-service trigger."
    PASS=$((PASS + 1))
else
    echo "[Fail] B1b: cap diagnostic did not fire as expected."
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"
print_test_summary
exit $?
