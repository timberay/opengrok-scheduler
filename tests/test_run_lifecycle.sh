#!/bin/bash
# tests/test_run_lifecycle.sh — open / close / current_id helpers
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: run lifecycle helpers ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# Source scheduler with --no-run guard so we get the helpers without the main loop
source "$SCHEDULER" --no-run

# Pre-seed two active services so total_services lookup has data
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a'),('svc-b');"

# 1. Opening when no run is open creates one
RUN1=$(run_open_if_none auto)
assert_eq "first open returns numeric id" "1" "$RUN1"

STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN1;")
assert_eq "first run is RUNNING" "RUNNING" "$STATUS"

TRIG=$($DB_QUERY "SELECT triggered_by FROM runs WHERE id=$RUN1;")
assert_eq "first run triggered_by is auto" "auto" "$TRIG"

TOTAL=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$RUN1;")
assert_eq "total_services snapshotted" "2" "$TOTAL"

# 2. Opening when a run is already open returns the existing id (idempotent)
RUN2=$(run_open_if_none auto)
assert_eq "second open returns same id" "$RUN1" "$RUN2"

ROW_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
assert_eq "no extra row inserted" "1" "$ROW_COUNT"

# 3. run_current_id returns the open id
CURRENT=$(run_current_id)
assert_eq "run_current_id matches" "$RUN1" "$CURRENT"

# 4. run_close marks COMPLETED with end timestamp + counts
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status) VALUES (1, $RUN1, 'COMPLETED'),(2, $RUN1, 'FAILED');"
run_close "$RUN1" COMPLETED

CLOSED_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN1;")
assert_eq "run is COMPLETED after close" "COMPLETED" "$CLOSED_STATUS"

ENDED=$($DB_QUERY "SELECT ended_at IS NOT NULL FROM runs WHERE id=$RUN1;")
assert_eq "ended_at is set" "1" "$ENDED"

C_COUNT=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$RUN1;")
F_COUNT=$($DB_QUERY "SELECT failed_count FROM runs WHERE id=$RUN1;")
assert_eq "completed_count aggregated" "1" "$C_COUNT"
assert_eq "failed_count aggregated" "1" "$F_COUNT"

# 5. run_current_id returns empty after close
CURRENT_AFTER=$(run_current_id)
assert_eq "no current run after close" "" "$CURRENT_AFTER"

# 6. After close, a fresh open creates a NEW row
RUN3=$(run_open_if_none auto)
[ "$RUN3" -gt "$RUN1" ] && PASS=$((PASS+1)) && echo "[Pass] new open creates new id" \
                       || { FAIL=$((FAIL+1)); echo "[Fail] new open did not create new id (got '$RUN3', prev '$RUN1')"; }

cleanup_test_db "$TEST_DB"

echo "--- triggered_by accepts auto / manual / init ---"
TEST_DB2=$(setup_test_db); export DB_PATH="$TEST_DB2"
RID_A=$(run_open_if_none auto); run_close "$RID_A" COMPLETED
RID_M=$(run_open_if_none manual); run_close "$RID_M" COMPLETED
RID_I=$(run_open_if_none init); run_close "$RID_I" COMPLETED

T_A=$($DB_QUERY "SELECT triggered_by FROM runs WHERE id=$RID_A;")
T_M=$($DB_QUERY "SELECT triggered_by FROM runs WHERE id=$RID_M;")
T_I=$($DB_QUERY "SELECT triggered_by FROM runs WHERE id=$RID_I;")
assert_eq "auto persists" "auto" "$T_A"
assert_eq "manual persists" "manual" "$T_M"
assert_eq "init persists" "init" "$T_I"

# Invalid value rejected
if run_open_if_none bogus 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "[Fail] bogus triggered_by accepted (should have rejected)"
else
    PASS=$((PASS+1)); echo "[Pass] bogus triggered_by rejected"
fi
cleanup_test_db "$TEST_DB2"

echo "--- existing RUNNING row is honored (recovery semantics) ---"
TEST_DB3=$(setup_test_db); export DB_PATH="$TEST_DB3"
$DB_QUERY "INSERT INTO runs(started_at, status, triggered_by, total_services) \
           VALUES (datetime('now','localtime'), 'RUNNING', 'auto', 0);"
EXISTING_ID=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING';")
RECOVERED=$(run_open_if_none auto)
assert_eq "open returns existing crashed RUNNING run" "$EXISTING_ID" "$RECOVERED"

ROW_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
assert_eq "no extra row inserted on recovery" "1" "$ROW_COUNT"
cleanup_test_db "$TEST_DB3"

echo "--- Window-entry / natural-completion wiring ---"

# Wiring test uses a separate DB to avoid interference with earlier asserts.
TEST_DB4=$(setup_test_db); export DB_PATH="$TEST_DB4"
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a'),('svc-b');"

# Simulate "window entry" — main loop calls run_open_if_none(auto)
WID=$(run_open_if_none auto)
[ -n "$WID" ] && PASS=$((PASS+1)) && echo "[Pass] window entry opens a run" \
              || { FAIL=$((FAIL+1)); echo "[Fail] window entry did not open a run"; }

# Simulate two services completing under that run
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (1, $WID, 'COMPLETED', datetime('now','localtime'), datetime('now','localtime')),
    (2, $WID, 'COMPLETED', datetime('now','localtime'), datetime('now','localtime'));"

# Natural-completion path: close the run COMPLETED
run_close "$WID" COMPLETED

C=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$WID;")
assert_eq "natural completion sets completed_count=2" "2" "$C"

cleanup_test_db "$TEST_DB4"

echo "--- Window-exit / PARTIAL wiring ---"
TEST_DB5=$(setup_test_db); export DB_PATH="$TEST_DB5"
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a'),('svc-b');"

# Open a run, complete only one of two services, then close PARTIAL
RID=$(run_open_if_none auto)
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (1, $RID, 'COMPLETED', datetime('now','localtime'), datetime('now','localtime'));"
run_close "$RID" PARTIAL

ST=$($DB_QUERY "SELECT status FROM runs WHERE id=$RID;")
assert_eq "window exit close marks PARTIAL" "PARTIAL" "$ST"

C=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$RID;")
assert_eq "PARTIAL run aggregates partial completed_count" "1" "$C"

cleanup_test_db "$TEST_DB5"

print_test_summary
