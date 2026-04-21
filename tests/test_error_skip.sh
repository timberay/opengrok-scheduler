#!/bin/bash

# tests/test_error_skip.sh
# Test that FAILED/TIMEOUT services are skipped by the next-job selection query,
# so a repeatedly-failing service does not block the scheduler from moving on.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] Error Skip Test Started..."

# ----------------------------------------------------------------------
# Scenario 1: FAILED service is skipped; next eligible service runs.
# ----------------------------------------------------------------------
echo ""
echo "[Scenario 1] FAILED service should be skipped"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc_fail', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc_ok', 1, 1);"

SVC_FAIL_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc_fail';")
SVC_OK_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc_ok';")

# Pre-seed a FAILED job for svc_fail at current time (inside 23h window)
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, end_time, duration, message)
           VALUES ($SVC_FAIL_ID, 'FAILED',
                   datetime('now', 'localtime'),
                   datetime('now', 'localtime'),
                   1, 'Pre-seeded for test');"

BASELINE_FAIL_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_FAIL_ID;")

export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
timeout 15s "$SCHEDULER" --sequence &
SCHEDULER_PID=$!
sleep 10
kill "$SCHEDULER_PID" 2>/dev/null
wait "$SCHEDULER_PID" 2>/dev/null

AFTER_FAIL_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_FAIL_ID;")
OK_COMPLETED=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_OK_ID AND status='COMPLETED';")

assert_eq "svc_fail has no new jobs created" "$BASELINE_FAIL_COUNT" "$AFTER_FAIL_COUNT"

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

$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, end_time, duration, message)
           VALUES ($SVC_TIMEOUT_ID, 'TIMEOUT',
                   datetime('now', 'localtime'),
                   datetime('now', 'localtime'),
                   1, 'Pre-seeded TIMEOUT for test');"

BASELINE_TO_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_TIMEOUT_ID;")

timeout 15s "$SCHEDULER" --sequence &
SCHEDULER_PID=$!
sleep 10
kill "$SCHEDULER_PID" 2>/dev/null
wait "$SCHEDULER_PID" 2>/dev/null

AFTER_TO_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_TIMEOUT_ID;")
OK2_COMPLETED=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$SVC_OK2_ID AND status='COMPLETED';")

assert_eq "svc_timeout has no new jobs created" "$BASELINE_TO_COUNT" "$AFTER_TO_COUNT"

if [ "$OK2_COMPLETED" -ge 1 ]; then
    echo "[Pass] svc_ok2 completed at least once ($OK2_COMPLETED)"
    PASS=$((PASS + 1))
else
    echo "[Fail] svc_ok2 should have completed at least once but got $OK2_COMPLETED"
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"

# ----------------------------------------------------------------------
# Scenario 3: FAILED job older than 23 hours does NOT block re-selection.
# ----------------------------------------------------------------------
echo ""
echo "[Scenario 3] FAILED job older than 23h should not block re-selection"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc_old_fail', 1, 1);"

SVC_OLD_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc_old_fail';")

# Pre-seed FAILED job older than 23 hours — should be OUTSIDE the exclusion window
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
