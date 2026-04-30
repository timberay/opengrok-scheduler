#!/bin/bash

# tests/test_init_option.sh
# CLI option test for the destructive-wipe path.
# Under cycle-based history semantics, --init no longer wipes jobs;
# the explicit --purge-all flag is the destructive operation.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] CLI --init / --purge-all Option Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Setup Mock data (One recent, one old)
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('init-test-container', 1);"
SERVICE_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='init-test-container';")
# Recent job
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', 'localtime', '-1 hour'));"
# Old job (2 days ago)
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', 'localtime', '-2 days'));"

# 3. Verify records exist
COUNT_BEFORE=$($DB_QUERY "SELECT count(*) FROM jobs;")
if [ "$COUNT_BEFORE" -ge 2 ]; then
    echo "[Pass] Mock records created ($COUNT_BEFORE)."
else
    echo "[Fail] Mock record creation failed ($COUNT_BEFORE)."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 4. Run --init — must NOT delete jobs (no in-flight run here, so it's a no-op)
$PROJECT_ROOT/bin/scheduler.sh --init

# 5. Verify --init preserved jobs (non-destructive semantics)
COUNT_AFTER_INIT=$($DB_QUERY "SELECT count(*) FROM jobs;")
if [ "$COUNT_AFTER_INIT" -eq "$COUNT_BEFORE" ]; then
    echo "[Pass] --init preserved job records ($COUNT_AFTER_INIT)."
else
    echo "[Fail] --init unexpectedly modified job records ($COUNT_BEFORE -> $COUNT_AFTER_INIT)."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 6. Run --purge-all — this is the explicit destructive wipe
$PROJECT_ROOT/bin/scheduler.sh --purge-all

# 7. Verify ALL job records deleted
COUNT_AFTER_PURGE=$($DB_QUERY "SELECT count(*) FROM jobs;")
if [ "$COUNT_AFTER_PURGE" -eq 0 ]; then
    echo "[Pass] --purge-all cleared all records."
else
    echo "[Fail] Records still exist after --purge-all ($COUNT_AFTER_PURGE)."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

cleanup_test_db "$TEST_DB"

echo "[Success] --init / --purge-all option test passed!"
exit 0
