#!/bin/bash
# tests/test_retention.sh — old runs/jobs are cleaned per MAX(N runs, X days)
# policy; in-flight RUNNING run is never touched.
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: retention deletes old runs but preserves recent + RUNNING ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

source "$SCHEDULER" --no-run

# Tight retention for fast test: keep at least 2 runs OR 1 day; manual=1 day.
export RUN_RETENTION_MIN=2
export RUN_RETENTION_DAYS=1
export MANUAL_JOB_RETENTION_DAYS=1

# Plant 5 runs: 3 ancient (10 days old, ABORTED), 1 recent (12h old, COMPLETED), 1 RUNNING.
for i in 1 2 3; do
    $DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by, total_services) \
               VALUES (datetime('now','localtime','-10 days'), datetime('now','localtime','-10 days'), 'ABORTED', 'auto', 0);"
done
$DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by, total_services, completed_count) \
           VALUES (datetime('now','localtime','-12 hours'), datetime('now','localtime','-11 hours'), 'COMPLETED', 'auto', 0, 0);"
$DB_QUERY "INSERT INTO runs(started_at, status, triggered_by, total_services) \
           VALUES (datetime('now','localtime'), 'RUNNING', 'auto', 0);"

# Plant a 5-day-old manual job (should be deleted) and a 1-hour-old one (kept)
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a');"
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (1, NULL, 'COMPLETED', datetime('now','localtime','-5 days'), datetime('now','localtime','-5 days')),
    (1, NULL, 'COMPLETED', datetime('now','localtime','-1 hour'), datetime('now','localtime','-30 minutes'));"

# Run cleanup
runs_retention_cleanup

# RUNNING must always be preserved
RUNNING_KEPT=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE status='RUNNING';")
assert_eq "RUNNING run untouched" "1" "$RUNNING_KEPT"

# At least 2 finished runs preserved by RUN_RETENTION_MIN
FINISHED_KEPT=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE status != 'RUNNING';")
[ "$FINISHED_KEPT" -ge 2 ] && PASS=$((PASS+1)) && echo "[Pass] at least 2 finished runs preserved (got $FINISHED_KEPT)" \
                            || { FAIL=$((FAIL+1)); echo "[Fail] expected >=2 finished, got $FINISHED_KEPT"; }

# Total >= 3 (2 finished + 1 RUNNING)
TOTAL_KEPT=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
[ "$TOTAL_KEPT" -ge 3 ] && PASS=$((PASS+1)) && echo "[Pass] retention keeps RUNNING + recent finished (got $TOTAL_KEPT)" \
                        || { FAIL=$((FAIL+1)); echo "[Fail] expected >=3 runs kept, got $TOTAL_KEPT"; }

# 10-day-old runs that are NOT in the most-recent-2-finished window MUST be deleted.
# With N=2 and 4 finished runs (3 ancient + 1 recent), top-2 by id contains the
# recent COMPLETED + 1 ancient ABORTED. The other 2 ancient ABORTEDs must go.
ANCIENT_KEPT=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE started_at < datetime('now','localtime','-5 days');")
assert_eq "ancient runs outside top-N cleaned" "1" "$ANCIENT_KEPT"

# Manual: 5-day-old job should be deleted, 1-hour-old job preserved
MANUAL_OLD=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id IS NULL AND start_time < datetime('now','localtime','-3 days');")
MANUAL_NEW=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id IS NULL AND start_time > datetime('now','localtime','-2 hours');")
assert_eq "old manual job deleted" "0" "$MANUAL_OLD"
assert_eq "recent manual job kept" "1" "$MANUAL_NEW"

# Idempotency: a second sweep should not delete anything more
runs_retention_cleanup
TOTAL_KEPT_AFTER=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
assert_eq "second sweep is idempotent" "$TOTAL_KEPT" "$TOTAL_KEPT_AFTER"

cleanup_test_db "$TEST_DB"
print_test_summary
