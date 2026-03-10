#!/bin/bash

# bin/db_query.sh
# SQLite3 query execution utility

DB_PATH="/home/tonny/projects/opengrok-scheduler/data/scheduler.db"

# Ensure the database is initialized
if [ ! -f "$DB_PATH" ]; then
    echo "[Error] Database not found at $DB_PATH" >&2
    exit 1
fi

# Execute Query
# Usage: ./db_query.sh "SELECT * FROM services"
# Execute Query with Concurrency Optimizations
# Execute Query with Concurrency Optimizations
# We run PRAGMAs and the query, but filter out PRAGMA results (wal, 10000, etc.)
# A cleaner way: Use a temporary init file and redirect its output to stderr
INIT_FILE=$(mktemp)
echo "PRAGMA busy_timeout=10000; PRAGMA journal_mode=WAL;" > "$INIT_FILE"
sqlite3 -batch -init "$INIT_FILE" "$DB_PATH" "$1" 2>/dev/null | grep -vE "^(wal|[0-9]{5})$"
rm -f "$INIT_FILE"
