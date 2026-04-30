#!/bin/bash

# bin/migrate_db.sh
# SQLite3 Schema Migration Utility
# This script ensures the database schema is up-to-date by adding missing columns.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Ensure database exists
if [ ! -f "$DB_PATH" ]; then
    # If DB doesn't exist, we skip migration as it will be created by init_db.sql later
    exit 0
fi

# Helper function for safe concurrent DB access
migrate_query() {
    sqlite3 "$DB_PATH" "PRAGMA busy_timeout=10000; PRAGMA journal_mode=WAL; $1"
}

# Function to add column if it doesn't exist
add_column_if_missing() {
    local TABLE=$1
    local COLUMN=$2
    local TYPE_AND_DEFAULT=$3

    # Check if column exists (using safe query)
    local EXISTS=$(migrate_query "PRAGMA table_info($TABLE);" | grep "|$COLUMN|")
    
    if [ -z "$EXISTS" ]; then
        echo "[Migration] Adding column '$COLUMN' to table '$TABLE'..."
        migrate_query "ALTER TABLE $TABLE ADD COLUMN $COLUMN $TYPE_AND_DEFAULT;"
        if [ $? -eq 0 ]; then
            echo "[Migration] Successfully added '$COLUMN' to '$TABLE'."
        else
            echo "[Migration] [Error] Failed to add '$COLUMN' to '$TABLE'." >&2
            return 1
        fi
    fi
    return 0
}

echo "[Migration] Checking database schema for $DB_PATH..."

# 1. Services Table Migrations
add_column_if_missing "services" "is_active" "INTEGER DEFAULT 1"

# 2. Jobs Table Migrations
add_column_if_missing "jobs" "pid" "INTEGER"
add_column_if_missing "jobs" "pid_starttime" "INTEGER"
add_column_if_missing "jobs" "process_state" "TEXT DEFAULT 'UNKNOWN'"

# 3.1 Runs Table — cycle-based history (added 2026-04)
echo "[Migration] Ensuring runs table exists..."
migrate_query "CREATE TABLE IF NOT EXISTS runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at      DATETIME NOT NULL,
    ended_at        DATETIME,
    status          TEXT NOT NULL CHECK(status IN ('RUNNING','COMPLETED','PARTIAL','ABORTED')),
    triggered_by    TEXT NOT NULL DEFAULT 'auto' CHECK(triggered_by IN ('auto','manual','init')),
    total_services  INTEGER,
    completed_count INTEGER DEFAULT 0,
    failed_count    INTEGER DEFAULT 0,
    timeout_count   INTEGER DEFAULT 0,
    orphaned_count  INTEGER DEFAULT 0
);"
migrate_query "CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);"
migrate_query "CREATE INDEX IF NOT EXISTS idx_runs_started_at ON runs(started_at);"

# 3.2 Jobs.run_id — FK into runs, plus dedup-query index
add_column_if_missing "jobs" "run_id" "INTEGER REFERENCES runs(id)"
migrate_query "CREATE INDEX IF NOT EXISTS idx_jobs_run_id ON jobs(run_id);"

# 3. Heartbeat Table Migration
echo "[Migration] Ensuring heartbeat table exists..."
migrate_query "CREATE TABLE IF NOT EXISTS heartbeat (id INTEGER PRIMARY KEY, last_pulse DATETIME);"

# 4. Jobs Table Status Constraint Migration (Requires table recreation in SQLite)
check_and_update_status_constraint() {
    local SCHEMA=$(migrate_query "SELECT sql FROM sqlite_master WHERE type='table' AND name='jobs';")
    if ! echo "$SCHEMA" | grep -q "ORPHANED" || ! echo "$SCHEMA" | grep -q "TIMEOUT"; then
        echo "[Migration] Updating status CHECK constraint in 'jobs' table..."

        sqlite3 "$DB_PATH" <<'MIGRATION_EOF'
PRAGMA busy_timeout=10000;
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;

ALTER TABLE jobs RENAME TO jobs_old;

CREATE TABLE jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED', 'TIMEOUT', 'ORPHANED')),
    pid INTEGER,
    pid_starttime INTEGER,
    process_state TEXT DEFAULT 'UNKNOWN',
    start_time DATETIME,
    end_time DATETIME,
    duration INTEGER,
    message TEXT,
    FOREIGN KEY (service_id) REFERENCES services(id)
);

INSERT INTO jobs (id, service_id, status, pid, pid_starttime, process_state, start_time, end_time, duration, message)
    SELECT id, service_id, status, pid, pid_starttime, process_state, start_time, end_time, duration, message FROM jobs_old;

DROP TABLE jobs_old;

COMMIT;
PRAGMA foreign_keys=ON;
MIGRATION_EOF
        if [ $? -eq 0 ]; then
            echo "[Migration] Successfully updated status constraint."
        else
            echo "[Migration] [Error] Failed to update status constraint." >&2
            return 1
        fi
    fi
    return 0
}

check_and_update_status_constraint

echo "[Migration] Database schema is up-to-date."
exit 0
