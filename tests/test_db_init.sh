#!/bin/bash

# tests/test_db_init.sh
# Database initialization test script

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_PATH="$PROJECT_ROOT/data/scheduler.db"
INIT_SQL="$PROJECT_ROOT/sql/init_db.sql"

# 1. Previous DB Cleanup
rm -f "$DB_PATH"

echo "[Test] Starting Database Initialization Test..."

# 2. Run Initialization
sqlite3 "$DB_PATH" < "$INIT_SQL"
if [ $? -ne 0 ]; then
    echo "[Fail] SQL execution failed."
    exit 1
fi

# 3. Table existence check
TABLES=("services" "jobs" "heartbeat")
for table in "${TABLES[@]}"; do
    EXISTS=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';")
    if [ "$EXISTS" == "$table" ]; then
        echo "[Pass] Table '$table' exists."
    else
        echo "[Fail] Table '$table' does not exist."
        exit 1
    fi
done

echo "[Success] Database initialization test passed!"
exit 0
