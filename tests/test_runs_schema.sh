#!/bin/bash
# tests/test_runs_schema.sh — Verifies runs table + jobs.run_id are present after migration.
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: runs schema migration ==="

# Build a pre-migration DB by initializing the BASELINE schema (without runs/run_id),
# then run migrate_db.sh and assert the new shape.
TEST_DB="$PROJECT_ROOT/data/runs_schema_$$.db"
rm -f "$TEST_DB" "${TEST_DB}-shm" "${TEST_DB}-wal"

# Simulate an old DB by creating jobs WITHOUT run_id and no runs table
sqlite3 "$TEST_DB" <<'OLD_SCHEMA'
CREATE TABLE services (id INTEGER PRIMARY KEY AUTOINCREMENT, container_name TEXT UNIQUE NOT NULL, priority INTEGER DEFAULT 0, is_active INTEGER DEFAULT 1);
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
INSERT INTO services(container_name) VALUES ('svc-a');
INSERT INTO jobs(service_id, status, start_time) VALUES (1, 'COMPLETED', datetime('now', 'localtime'));
OLD_SCHEMA

# Run migration twice — must be idempotent
DB_PATH="$TEST_DB" "$PROJECT_ROOT/bin/migrate_db.sh" >/dev/null 2>&1
DB_PATH="$TEST_DB" "$PROJECT_ROOT/bin/migrate_db.sh" >/dev/null 2>&1

# Assertion 1: runs table exists
RUNS_EXISTS=$(sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='runs';")
assert_eq "runs table created" "runs" "$RUNS_EXISTS"

# Assertion 2: jobs.run_id column exists
HAS_RUN_ID=$(sqlite3 "$TEST_DB" "PRAGMA table_info(jobs);" | grep -c "|run_id|")
assert_eq "jobs.run_id column added" "1" "$HAS_RUN_ID"

# Assertion 3: pre-existing data preserved
SVC_COUNT=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM services;")
JOB_COUNT=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM jobs;")
assert_eq "services preserved across migration" "1" "$SVC_COUNT"
assert_eq "jobs preserved across migration" "1" "$JOB_COUNT"

# Assertion 4: index on run_id exists
HAS_INDEX=$(sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_jobs_run_id';")
assert_eq "idx_jobs_run_id created" "idx_jobs_run_id" "$HAS_INDEX"

# Assertion 5: pre-existing job's run_id is NULL (not assigned to any run)
PREEX_RUN=$(sqlite3 "$TEST_DB" "SELECT COALESCE(run_id, 'NULL') FROM jobs WHERE id=1;")
assert_eq "pre-migration job has run_id=NULL" "NULL" "$PREEX_RUN"

# Assertion 6: triggered_by column exists on runs (not 'trigger')
HAS_TRIGGERED_BY=$(sqlite3 "$TEST_DB" "PRAGMA table_info(runs);" | grep -c "|triggered_by|")
assert_eq "runs.triggered_by column present" "1" "$HAS_TRIGGERED_BY"

cleanup_test_db "$TEST_DB"
print_test_summary
