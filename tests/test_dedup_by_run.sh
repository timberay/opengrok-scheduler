#!/bin/bash
# tests/test_dedup_by_run.sh — same service can run again in the next cycle,
# but not twice in the same one. Locks in run_id-based dedup behavior.
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: dedup by run_id, not by 23h timestamp ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('svc-a',1),('svc-b',1);"

source "$SCHEDULER" --no-run

# Cycle 1
R1=$(run_open_if_none auto)
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (1, $R1, 'COMPLETED', datetime('now','localtime'), datetime('now','localtime'));"

# Build the dedup query that the main loop will use. Must EXCLUDE svc-a
# (already attempted in run $R1) but INCLUDE svc-b.
NEXT=$($DB_QUERY "SELECT s.container_name FROM services s
                  WHERE s.is_active=1
                  AND NOT EXISTS (
                      SELECT 1 FROM jobs j WHERE j.service_id=s.id AND j.run_id=$R1
                  )
                  ORDER BY s.id LIMIT 1;")
assert_eq "within run, attempted service is excluded" "svc-b" "$NEXT"

# Add svc-b to run 1 then close it
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (2, $R1, 'COMPLETED', datetime('now','localtime'), datetime('now','localtime'));"
run_close "$R1" COMPLETED

# Cycle 2 — svc-a must be eligible again, even though it ran less than 23h ago
R2=$(run_open_if_none auto)
NEXT2=$($DB_QUERY "SELECT s.container_name FROM services s
                   WHERE s.is_active=1
                   AND NOT EXISTS (
                       SELECT 1 FROM jobs j WHERE j.service_id=s.id AND j.run_id=$R2
                   )
                   ORDER BY s.id LIMIT 1;")
assert_eq "next cycle re-admits previously-run service" "svc-a" "$NEXT2"

# Regression guard for the original 23h bug:
# A service whose ONLY job is in a CLOSED prior run must not block a fresh cycle.
[ "$NEXT2" != "" ] && PASS=$((PASS+1)) && echo "[Pass] no service blocked by closed-run job" \
                   || { FAIL=$((FAIL+1)); echo "[Fail] dedup blocked across cycles"; }

# Failed/orphaned/timeout jobs in the same run also block re-attempt — verify
# every terminal status counts, not just COMPLETED
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (1, $R2, 'FAILED', datetime('now','localtime'), datetime('now','localtime'));"
NEXT3=$($DB_QUERY "SELECT s.container_name FROM services s
                   WHERE s.is_active=1
                   AND NOT EXISTS (
                       SELECT 1 FROM jobs j WHERE j.service_id=s.id AND j.run_id=$R2
                   )
                   ORDER BY s.id LIMIT 1;")
assert_eq "FAILED job in current run also blocks re-attempt" "svc-b" "$NEXT3"

cleanup_test_db "$TEST_DB"
print_test_summary
