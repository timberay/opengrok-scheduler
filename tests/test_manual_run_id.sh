#!/bin/bash
# tests/test_manual_run_id.sh — manual --service jobs must not be tagged with
# any run_id, and must not pollute auto-cycle statistics or block dispatch.
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: manual --service jobs leave run_id NULL ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a');"

source "$SCHEDULER" --no-run

# Plant a manual job (mimicking what scheduler.sh's --service path does — INSERT
# without a run_id column, so SQLite defaults it to NULL).
$DB_QUERY "INSERT INTO jobs(service_id, status, start_time, end_time) VALUES
    (1, 'COMPLETED', datetime('now','localtime'), datetime('now','localtime'));"

NULL_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id IS NULL;")
assert_eq "manual job has run_id NULL" "1" "$NULL_COUNT"

# Open a fresh auto run; svc-a must be eligible (manual job is not in this run)
R=$(run_open_if_none auto)
NEXT=$($DB_QUERY "SELECT s.container_name FROM services s
                  WHERE s.is_active=1
                  AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.service_id=s.id AND j.run_id=$R)
                  ORDER BY s.id LIMIT 1;")
assert_eq "manual job does not block auto cycle" "svc-a" "$NEXT"

# Run-level stat aggregation: a manual COMPLETED row must NOT be counted in run R
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status) VALUES (1, $R, 'COMPLETED');"
run_close "$R" COMPLETED
RUN_COMPLETED=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$R;")
assert_eq "run completed_count counts only run-tagged rows" "1" "$RUN_COMPLETED"

# Sanity: total COMPLETED across the table is 2 (one manual + one in-run)
TOTAL_COMPLETED=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED';")
assert_eq "total COMPLETED across table is 2" "2" "$TOTAL_COMPLETED"

cleanup_test_db "$TEST_DB"
print_test_summary
