#!/bin/bash

# tests/test_service_option.sh
# --service option functionality test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] CLI --service Option Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Setup Mock data
CONTAINER="service-test-cmd"
$DB_QUERY "INSERT OR IGNORE INTO services (container_name, priority) VALUES ('$CONTAINER', 100);"
S_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='$CONTAINER';")

# 3. Run --service for specific container
$PROJECT_ROOT/bin/scheduler.sh --service "$CONTAINER"
EXIT_STATUS=$?

if [ $EXIT_STATUS -eq 0 ]; then
    echo "[Pass] --service command exited with success."
else
    echo "[Fail] --service command failed with exit code $EXIT_STATUS."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 4. Verify record in jobs table
JOB_RECORD=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$S_ID ORDER BY start_time DESC LIMIT 1;")
if [ "$JOB_RECORD" == "COMPLETED" ]; then
    echo "[Pass] Job record created and status is COMPLETED."
else
    echo "[Fail] Job record not found or status is unexpected: '$JOB_RECORD'."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 5. Verify --service with non-existent container
echo "[Test] Testing with non-existent container..."
$PROJECT_ROOT/bin/scheduler.sh --service "non-existent-xyz" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[Pass] Correctly failed for non-existent container."
else
    echo "[Fail] Expected failure for non-existent container but got success."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

cleanup_test_db "$TEST_DB"

echo "[Success] --service option test passed!"
exit 0
