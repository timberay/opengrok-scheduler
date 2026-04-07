#!/bin/bash

# tests/test_db_init.sh
# Database initialization test script

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

INIT_SQL="$PROJECT_ROOT/sql/init_db.sql"

# Use isolated test DB
TEST_DB=$(setup_test_db)
trap 'cleanup_test_db "$TEST_DB"' EXIT

echo "[Test] Starting Database Initialization Test..."

# 1. Table existence check
TABLES=("services" "jobs" "heartbeat")
for table in "${TABLES[@]}"; do
    EXISTS=$(sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';")
    assert_eq "Table '$table' exists" "$table" "$EXISTS"
done

print_test_summary
exit $?
