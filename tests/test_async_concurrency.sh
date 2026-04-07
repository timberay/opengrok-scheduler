#!/bin/bash

# tests/test_async_concurrency.sh
# Test script to verify asynchronous concurrency and fixed interval

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] Async Concurrency Test Started..."

# 1. Setup Isolated Test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

# 2. Add services
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc1', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc2', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc3', 1, 1);"

# 3. Run scheduler in background with short interval and high threshold
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
timeout 30s "$SCHEDULER" &
SCHEDULER_PID=$!

echo "[Info] Waiting for scheduler to pick up jobs (approx 20s)..."
sleep 20

# 4. Verify DB state
# 4. Verify DB state
RUNNING_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='RUNNING';")
COMPLETED_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='COMPLETED';")

echo "[Result] Running Jobs: $RUNNING_COUNT"
echo "[Result] Completed Jobs: $COMPLETED_COUNT"

# Verify asynchronous (at least 2 should have started)
TOTAL_STARTED=$((RUNNING_COUNT + COMPLETED_COUNT))
if [ "$TOTAL_STARTED" -ge 2 ]; then
    echo "[Pass] Async execution verified: $TOTAL_STARTED jobs started."
    PASS=$((PASS + 1))
else
    echo "[Fail] Async execution failed. Expected at least 2 jobs to be processed or running, but got $TOTAL_STARTED."
    FAIL=$((FAIL + 1))
fi

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null
cleanup_test_db "$TEST_DB"
print_test_summary
exit $?
