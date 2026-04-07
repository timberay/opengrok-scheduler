#!/bin/bash

# tests/test_orphan_recovery_fix.sh
# Test that recovered jobs are not immediately marked ORPHANED

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] Orphan Recovery Fix Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Create test services
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('orphan-test-live', 100);"
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('orphan-test-dead', 50);"

SVC_LIVE=$($DB_QUERY "SELECT id FROM services WHERE container_name='orphan-test-live';")
SVC_DEAD=$($DB_QUERY "SELECT id FROM services WHERE container_name='orphan-test-dead';")

# 3. Start a background process that will stay alive
sleep 120 &
LIVE_PID=$!
DEAD_PID=99999

echo "[Setup] Live PID: $LIVE_PID (should be alive)"
echo "[Setup] Dead PID: $DEAD_PID (doesn't exist)"

# 4. Insert both jobs as RUNNING
$DB_QUERY "INSERT INTO jobs (service_id, status, pid, start_time) VALUES ($SVC_LIVE, 'RUNNING', $LIVE_PID, datetime('now', 'localtime'));"
$DB_QUERY "INSERT INTO jobs (service_id, status, pid, start_time) VALUES ($SVC_DEAD, 'RUNNING', $DEAD_PID, datetime('now', 'localtime'));"

# 5. Trigger scheduler recovery by running it briefly (outside working hours)
export START_TIME="23:00"
export END_TIME="23:01"
export CHECK_INTERVAL="1"

echo "[Test] Running scheduler to trigger recovery..."
timeout 3 bash "$PROJECT_ROOT/bin/scheduler.sh" > /dev/null 2>&1

# 6. Check results
STATUS_LIVE=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$SVC_LIVE ORDER BY id DESC LIMIT 1;")
STATUS_DEAD=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$SVC_DEAD ORDER BY id DESC LIMIT 1;")

echo "[Result] Live PID job status: $STATUS_LIVE"
echo "[Result] Dead PID job status: $STATUS_DEAD"

# Cleanup
kill $LIVE_PID 2>/dev/null
wait $LIVE_PID 2>/dev/null

# 7. Assertions
EXIT_CODE=0

if [ "$STATUS_LIVE" == "RUNNING" ]; then
    echo "[Pass] Live PID job remained RUNNING (not orphaned by blanket update)"
else
    echo "[Fail] Live PID job has status '$STATUS_LIVE' instead of RUNNING"
    EXIT_CODE=1
fi

if [ "$STATUS_DEAD" == "ORPHANED" ]; then
    echo "[Pass] Dead PID job was correctly marked ORPHANED"
else
    echo "[Fail] Dead PID job has status '$STATUS_DEAD' instead of ORPHANED"
    EXIT_CODE=1
fi

cleanup_test_db "$TEST_DB"

if [ $EXIT_CODE -eq 0 ]; then
    echo "[Success] Orphan recovery fix test passed!"
else
    echo "[Failure] Test revealed issues"
fi

exit $EXIT_CODE
