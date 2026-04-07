#!/bin/bash

# tests/test_db_query_fixes.sh
# Test db_query.sh exit code propagation and grep filter fixes

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

echo "[Test] DB Query Fixes Test Started..."

# Test 1: Exit code propagation - invalid SQL should return non-zero
echo "[Test 1] Testing exit code propagation for invalid SQL..."
$DB_QUERY "INVALID SQL SYNTAX HERE;" > /dev/null 2>&1
INVALID_EXIT=$?

if [ $INVALID_EXIT -ne 0 ]; then
    echo "[Pass] Invalid SQL returned non-zero exit code ($INVALID_EXIT)"
else
    echo "[Fail] Invalid SQL returned exit code 0 (should be non-zero)"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# Test 2: Exit code propagation - valid SQL should return zero
echo "[Test 2] Testing exit code propagation for valid SQL..."
$DB_QUERY "SELECT 1;" > /dev/null 2>&1
VALID_EXIT=$?

if [ $VALID_EXIT -eq 0 ]; then
    echo "[Pass] Valid SQL returned exit code 0"
else
    echo "[Fail] Valid SQL returned non-zero exit code ($VALID_EXIT)"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# Test 3: 5-digit results should not be filtered
echo "[Test 3] Testing that 5-digit query results are not filtered..."

TEST_CASES=("10000" "12345" "99999" "54321")
FAILURES=0

for VAL in "${TEST_CASES[@]}"; do
    RESULT=$($DB_QUERY "SELECT $VAL;")
    if [ "$RESULT" == "$VAL" ]; then
        echo "[Pass] Value $VAL was not filtered"
    else
        echo "[Fail] Value $VAL was filtered or modified (got: '$RESULT', expected: '$VAL')"
        FAILURES=$((FAILURES + 1))
    fi
done

# Test that leading zeros are handled by SQLite naturally (00001 -> 1)
RESULT=$($DB_QUERY "SELECT 00001;")
if [ "$RESULT" == "1" ]; then
    echo "[Pass] Value 00001 converted to 1 (normal SQLite integer behavior)"
else
    echo "[Fail] Value 00001 produced unexpected result: '$RESULT'"
    FAILURES=$((FAILURES + 1))
fi

if [ $FAILURES -gt 0 ]; then
    echo "[Test 3] Failed: $FAILURES values had issues"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# Test 4: "wal" string (legitimate result) should not be filtered
echo "[Test 4] Testing that string 'wal' in results is not filtered..."
RESULT=$($DB_QUERY "SELECT 'wal';")
if [ "$RESULT" == "wal" ]; then
    echo "[Pass] String 'wal' was not filtered"
else
    echo "[Fail] String 'wal' was filtered (got: '$RESULT')"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

cleanup_test_db "$TEST_DB"

echo "[Success] DB Query fixes test passed!"
exit 0
