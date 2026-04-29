#!/bin/bash
# tests/test_status_runs.sh — --status output includes the latest run summary.
source "$(dirname "$0")/test_helper.sh"

echo "=== Test: --status prints latest run summary header ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a'),('svc-b');"
$DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by, total_services, completed_count, failed_count) \
           VALUES (datetime('now','localtime','-2 hours'), datetime('now','localtime','-30 minutes'), 'COMPLETED', 'auto', 2, 2, 0);"
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (1, 1, 'COMPLETED', datetime('now','localtime','-2 hours'), datetime('now','localtime','-90 minutes')),
    (2, 1, 'COMPLETED', datetime('now','localtime','-90 minutes'), datetime('now','localtime','-30 minutes'));"

OUTPUT=$(DB_PATH="$TEST_DB" "$SCHEDULER" --status 2>&1)

# Header should mention the run
echo "$OUTPUT" | grep -q "Run #1" \
    && PASS=$((PASS+1)) && echo "[Pass] output includes Run #N header" \
    || { FAIL=$((FAIL+1)); echo "[Fail] missing 'Run #1' line. Output:"; echo "$OUTPUT"; }

# Should show the run's status
echo "$OUTPUT" | grep -q "COMPLETED" \
    && PASS=$((PASS+1)) && echo "[Pass] output includes run status" \
    || { FAIL=$((FAIL+1)); echo "[Fail] missing run status"; }

# Should show progress like 2/2 (done/total)
echo "$OUTPUT" | grep -qE "2/2" \
    && PASS=$((PASS+1)) && echo "[Pass] output shows 2/2 progress" \
    || { FAIL=$((FAIL+1)); echo "[Fail] missing 2/2 progress indicator"; }

# Should show triggered_by/trigger info
echo "$OUTPUT" | grep -qE "trigger=auto|triggered_by=auto" \
    && PASS=$((PASS+1)) && echo "[Pass] output shows trigger info" \
    || { FAIL=$((FAIL+1)); echo "[Fail] missing trigger info"; }

# Per-service table should still be there
echo "$OUTPUT" | grep -q "svc-a" \
    && PASS=$((PASS+1)) && echo "[Pass] output includes per-service rows" \
    || { FAIL=$((FAIL+1)); echo "[Fail] missing per-service rows"; }

cleanup_test_db "$TEST_DB"

echo ""
echo "--- Empty DB shows '(no runs yet)' fallback ---"

TEST_DB2=$(setup_test_db)
export DB_PATH="$TEST_DB2"
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-a');"
OUTPUT2=$(DB_PATH="$TEST_DB2" "$SCHEDULER" --status 2>&1)
echo "$OUTPUT2" | grep -q "no runs yet" \
    && PASS=$((PASS+1)) && echo "[Pass] empty-DB fallback shows '(no runs yet)'" \
    || { FAIL=$((FAIL+1)); echo "[Fail] missing '(no runs yet)' fallback. Output:"; echo "$OUTPUT2"; }

cleanup_test_db "$TEST_DB2"

print_test_summary
