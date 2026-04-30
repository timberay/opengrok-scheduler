#!/bin/bash
# tests/test_run_recovery.sh — verifies a leftover RUNNING run from a prior
# crashed scheduler instance is force-closed on next startup.
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: stale RUNNING run is ABORTED on next start ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a');"

# Plant a RUNNING run row directly (as if a previous scheduler crashed)
$DB_QUERY "INSERT INTO runs(started_at, status, triggered_by, total_services) \
           VALUES (datetime('now','localtime','-6 hours'),'RUNNING','auto',1);"

# Sanity precondition: the row exists
PLANTED_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE status='RUNNING';")
assert_eq "precondition: planted RUNNING run exists" "1" "$PLANTED_RUNNING"

# Source scheduler helpers
source "$SCHEDULER" --no-run

# Run the recovery sweep (helper added by this task)
run_recover_stale

ST=$($DB_QUERY "SELECT status FROM runs ORDER BY id DESC LIMIT 1;")
assert_eq "stale run is ABORTED on recovery" "ABORTED" "$ST"

ENDED=$($DB_QUERY "SELECT ended_at IS NOT NULL FROM runs ORDER BY id DESC LIMIT 1;")
assert_eq "stale run gets ended_at on recovery" "1" "$ENDED"

# Idempotency: a second sweep is a no-op (no error, no extra row mutations)
run_recover_stale
ABORTED_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE status='ABORTED';")
assert_eq "second recovery sweep is idempotent" "1" "$ABORTED_COUNT"

# Multiple stale rows: plant two and verify both are closed
$DB_QUERY "INSERT INTO runs(started_at, status, triggered_by, total_services) \
           VALUES (datetime('now','localtime','-3 hours'),'RUNNING','auto',1);"
$DB_QUERY "INSERT INTO runs(started_at, status, triggered_by, total_services) \
           VALUES (datetime('now','localtime','-2 hours'),'RUNNING','auto',1);"

PRE_SWEEP=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE status='RUNNING';")
assert_eq "precondition: two more RUNNING rows planted" "2" "$PRE_SWEEP"

run_recover_stale

POST_SWEEP_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE status='RUNNING';")
POST_SWEEP_ABORTED=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE status='ABORTED';")
assert_eq "no RUNNING rows after multi-recovery" "0" "$POST_SWEEP_RUNNING"
assert_eq "all three closed as ABORTED" "3" "$POST_SWEEP_ABORTED"

cleanup_test_db "$TEST_DB"
print_test_summary
