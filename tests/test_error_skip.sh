#!/bin/bash

# tests/test_error_skip.sh
# Test that FAILED/TIMEOUT services are skipped by the next-job selection query,
# so a repeatedly-failing service does not block the scheduler from moving on.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] Error Skip Test Started..."

# Force 24-hour working hours so the scheduler's main loop isn't gated by time-of-day
export START_TIME="00:00"
export END_TIME="23:59"

# ----------------------------------------------------------------------
# Scenario 1: FAILED service is skipped; next eligible service runs.
# ----------------------------------------------------------------------
echo ""
echo "[Scenario 1] FAILED service should be skipped"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc_fail', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc_ok', 1, 1);"

SVC_FAIL_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc_fail';")
SVC_OK_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc_ok';")

# Pre-seed a FAILED job for svc_fail tagged with the run_id the scheduler
# will create on first window entry (id=1, since the runs table is empty).
# Under run_id-based dedup, only same-run jobs block re-attempt.
$DB_QUERY "INSERT INTO jobs (service_id, run_id, status, start_time, end_time, duration, message)
           VALUES ($SVC_FAIL_ID, 1, 'FAILED',
                   datetime('now', 'localtime'),
                   datetime('now', 'localtime'),
                   1, 'Pre-seeded for test');"

# Count rows in run 1 only — under run_id-based dedup, the contract is
# "within a run, an attempted service is not retried". Rows in later runs
# (r2, r3, ...) are unrelated and acceptable.
BASELINE_FAIL_RUN1=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_FAIL_ID AND run_id=1;")

export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
timeout 15s "$SCHEDULER" --sequence &
SCHEDULER_PID=$!
sleep 10
kill "$SCHEDULER_PID" 2>/dev/null
wait "$SCHEDULER_PID" 2>/dev/null
# Reap any orphaned dispatch wrappers (subshells with `trap '' SIGTERM`)
# and short-lived monitor children before the next scenario tries to
# acquire the per-DB flock.
pkill -KILL -f "$SCHEDULER --sequence" 2>/dev/null
sleep 1

AFTER_FAIL_RUN1=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_FAIL_ID AND run_id=1;")
OK_COMPLETED=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_OK_ID AND status='COMPLETED';")

assert_eq "svc_fail not redispatched within run 1" "$BASELINE_FAIL_RUN1" "$AFTER_FAIL_RUN1"

if [ "$OK_COMPLETED" -ge 1 ]; then
    echo "[Pass] svc_ok completed at least once ($OK_COMPLETED)"
    PASS=$((PASS + 1))
else
    echo "[Fail] svc_ok should have completed at least once but got $OK_COMPLETED"
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"

# ----------------------------------------------------------------------
# Scenario 2: TIMEOUT service is skipped; next eligible service runs.
# ----------------------------------------------------------------------
echo ""
echo "[Scenario 2] TIMEOUT service should be skipped"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc_timeout', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc_ok2', 1, 1);"

SVC_TIMEOUT_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc_timeout';")
SVC_OK2_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc_ok2';")

# Tag with run_id=1 so the scheduler's first opened run matches and the
# dedup query excludes svc_timeout from re-dispatch.
$DB_QUERY "INSERT INTO jobs (service_id, run_id, status, start_time, end_time, duration, message)
           VALUES ($SVC_TIMEOUT_ID, 1, 'TIMEOUT',
                   datetime('now', 'localtime'),
                   datetime('now', 'localtime'),
                   1, 'Pre-seeded TIMEOUT for test');"

# Count rows in run 1 only — see Scenario 1 rationale.
BASELINE_TO_RUN1=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_TIMEOUT_ID AND run_id=1;")

timeout 15s "$SCHEDULER" --sequence &
SCHEDULER_PID=$!
sleep 10
kill "$SCHEDULER_PID" 2>/dev/null
wait "$SCHEDULER_PID" 2>/dev/null
pkill -KILL -f "$SCHEDULER --sequence" 2>/dev/null
sleep 1

AFTER_TO_RUN1=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_TIMEOUT_ID AND run_id=1;")
OK2_COMPLETED=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_OK2_ID AND status='COMPLETED';")

assert_eq "svc_timeout not redispatched within run 1" "$BASELINE_TO_RUN1" "$AFTER_TO_RUN1"

if [ "$OK2_COMPLETED" -ge 1 ]; then
    echo "[Pass] svc_ok2 completed at least once ($OK2_COMPLETED)"
    PASS=$((PASS + 1))
else
    echo "[Fail] svc_ok2 should have completed at least once but got $OK2_COMPLETED"
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"

# ----------------------------------------------------------------------
# Scenario 3: FAILED job from a prior run does NOT block re-selection
# in a fresh cycle. (Under run_id-based dedup, only same-run jobs block.)
# ----------------------------------------------------------------------
echo ""
echo "[Scenario 3] FAILED job from prior run should not block re-selection"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc_old_fail', 1, 1);"

SVC_OLD_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc_old_fail';")

# Pre-seed FAILED job with run_id=NULL (representing a row from before this
# branch landed, or from a closed prior run). Should NOT be matched by the
# current-run dedup query, so svc_old_fail is eligible for re-selection.
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, end_time, duration, message)
           VALUES ($SVC_OLD_ID, 'FAILED',
                   datetime('now', 'localtime', '-24 hours'),
                   datetime('now', 'localtime', '-24 hours'),
                   1, 'Pre-seeded old FAILED for test');"

timeout 15s "$SCHEDULER" --sequence &
SCHEDULER_PID=$!
sleep 10
kill "$SCHEDULER_PID" 2>/dev/null
wait "$SCHEDULER_PID" 2>/dev/null

NEW_JOBS=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_OLD_ID AND status IN ('RUNNING', 'COMPLETED');")

if [ "$NEW_JOBS" -ge 1 ]; then
    echo "[Pass] svc_old_fail was re-selected and executed ($NEW_JOBS new RUNNING/COMPLETED job(s))"
    PASS=$((PASS + 1))
else
    echo "[Fail] svc_old_fail should have been re-selected but got $NEW_JOBS new RUNNING/COMPLETED jobs"
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
