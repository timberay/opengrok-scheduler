#!/bin/bash
# tests/test_db_error_handling.sh

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

assert_error() {
    local query="$1"
    local desc="$2"
    local err_msg
    # Capture stderr
    err_msg=$($DB_QUERY "$query" 2>&1 >/dev/null)
    local exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo "[Pass] $desc (Exit: $exit_code)"
        PASS=$((PASS + 1))
    else
        echo "[Fail] $desc (Exit: $exit_code, expected non-zero)"
        FAIL=$((FAIL + 1))
    fi
}

echo "[Test] DB Error Handling Tests Started..."

# 1. Non-existent table
assert_error "SELECT * FROM non_existent_table;" "Querying non-existent table fails"

# 2. Syntax error
assert_error "SELEC * FROM services;" "Invalid SQL syntax fails"

# 3. Constraint violation
$DB_QUERY "INSERT INTO services (container_name) VALUES ('test-duplicate');"
assert_error "INSERT INTO services (container_name) VALUES ('test-duplicate');" "Duplicate UNIQUE constraint violation fails"

cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
