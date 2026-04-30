#!/bin/bash
# tests/test_init_semantics.sh — --init must close the current run only,
# preserving prior runs/jobs. --purge-all is the explicit total-wipe.
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: --init aborts current run, preserves history ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a');"

# Plant: one closed run with a completed job, plus one RUNNING run with a job
$DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by, total_services, completed_count) \
           VALUES (datetime('now','localtime','-1 day'), datetime('now','localtime','-23 hours'), 'COMPLETED', 'auto', 1, 1);"
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES (1, 1, 'COMPLETED', datetime('now','localtime','-1 day'), datetime('now','localtime','-23 hours'));"
$DB_QUERY "INSERT INTO runs(started_at, status, triggered_by, total_services) \
           VALUES (datetime('now','localtime','-1 hour'), 'RUNNING', 'auto', 1);"
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time) VALUES (1, 2, 'RUNNING', datetime('now','localtime','-1 hour'));"

# Run --init
DB_PATH="$TEST_DB" "$SCHEDULER" --init >/dev/null 2>&1

# After --init: run #1 still COMPLETED, run #2 now ABORTED, both rows still exist
RUN1_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=1;")
RUN2_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=2;")
assert_eq "prior run preserved as COMPLETED" "COMPLETED" "$RUN1_STATUS"
assert_eq "in-flight run closed as ABORTED" "ABORTED" "$RUN2_STATUS"

# Job rows should also still exist (unlike old --init which DELETE FROM jobs)
JOB_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
assert_eq "all job rows preserved" "2" "$JOB_COUNT"

# Calling --init again with no in-flight run should be a no-op (idempotent)
DB_PATH="$TEST_DB" "$SCHEDULER" --init >/dev/null 2>&1
RUN_COUNT_AFTER_NOOP=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
assert_eq "idempotent --init does not delete rows" "2" "$RUN_COUNT_AFTER_NOOP"

echo ""
echo "--- Test: --purge-all wipes everything ---"
DB_PATH="$TEST_DB" "$SCHEDULER" --purge-all >/dev/null 2>&1

JOB_COUNT_AFTER=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
RUN_COUNT_AFTER=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
assert_eq "--purge-all clears jobs" "0" "$JOB_COUNT_AFTER"
assert_eq "--purge-all clears runs" "0" "$RUN_COUNT_AFTER"

# Services table is preserved (it's not job/run history; it's config)
SVC_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM services;")
assert_eq "--purge-all preserves services config" "1" "$SVC_COUNT"

cleanup_test_db "$TEST_DB"
print_test_summary
