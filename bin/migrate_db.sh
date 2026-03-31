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
add_column_if_missing "jobs" "process_state" "TEXT DEFAULT 'UNKNOWN'"

# 3. Heartbeat Table Migration
echo "[Migration] Ensuring heartbeat table exists..."
migrate_query "CREATE TABLE IF NOT EXISTS heartbeat (id INTEGER PRIMARY KEY, last_pulse DATETIME);"

# 4. Jobs Table Status Constraint Migration (Requires table recreation in SQLite)
check_and_update_status_constraint() {
    local SCHEMA=$(migrate_query ".schema jobs")
    if ! echo "$SCHEMA" | grep -q "ORPHANED" || ! echo "$SCHEMA" | grep -q "TIMEOUT"; then
        echo "[Migration] Updating status CHECK constraint in 'jobs' table..."
        
        # Identify existing columns to preserve data (id, service_id, status, start_time, end_time, duration, message)
        # pid and process_state are handled by add_column_if_missing above, so they should exist now.
        local COLS="id, service_id, status, pid, process_state, start_time, end_time, duration, message"

        sqlite3 "$DB_PATH" <<EOF
PRAGMA busy_timeout=10000;
PRAGMA journal_mode=WAL;
EOF
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;

-- Rename existing table
ALTER TABLE jobs RENAME TO jobs_old;

-- Create new table with FULL schema including all status values
CREATE TABLE jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED', 'TIMEOUT', 'ORPHANED')),
    pid INTEGER,
    process_state TEXT DEFAULT 'UNKNOWN',
    start_time DATETIME,
    end_time DATETIME,
    duration INTEGER,
    message TEXT,
    FOREIGN KEY (service_id) REFERENCES services(id)
);

-- Copy data with explicit columns
INSERT INTO jobs ($COLS) SELECT $COLS FROM jobs_old;

-- Drop old table
DROP TABLE jobs_old;

COMMIT;
PRAGMA foreign_keys=ON;
EOF
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
