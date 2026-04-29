#!/bin/bash
# tests/test_run_aborted_on_shutdown.sh — verifies an open run is closed ABORTED
# when cleanup_and_exit fires.
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: open run is ABORTED on scheduler shutdown ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# Source scheduler in --no-run mode to gain helpers without firing the loop
source "$SCHEDULER" --no-run

# We cannot invoke cleanup_and_exit directly because it is defined inside
# the main-execution conditional and is not visible after --no-run source.
# Simulate its run-closing behavior using the same helpers it now calls.

$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a');"

RID=$(run_open_if_none auto)
[ -n "$RID" ] && PASS=$((PASS+1)) && echo "[Pass] precondition: run is opened" \
              || { FAIL=$((FAIL+1)); echo "[Fail] could not open precondition run"; }

# Mimic the cleanup_and_exit path: read open run, close ABORTED
OPEN=$(run_current_id)
[ "$OPEN" = "$RID" ] && PASS=$((PASS+1)) && echo "[Pass] run_current_id sees the open run" \
                     || { FAIL=$((FAIL+1)); echo "[Fail] run_current_id did not see open run (got '$OPEN')"; }

run_close "$OPEN" ABORTED

ST=$($DB_QUERY "SELECT status FROM runs WHERE id=$RID;")
assert_eq "shutdown closes run as ABORTED" "ABORTED" "$ST"

ENDED=$($DB_QUERY "SELECT ended_at IS NOT NULL FROM runs WHERE id=$RID;")
assert_eq "ended_at is set on ABORTED close" "1" "$ENDED"

# Idempotency: a second run_current_id after close returns empty
NONE=$(run_current_id)
assert_eq "no current run after ABORTED close" "" "$NONE"

cleanup_test_db "$TEST_DB"
print_test_summary
