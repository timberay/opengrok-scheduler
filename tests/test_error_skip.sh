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

print_test_summary
exit $?
