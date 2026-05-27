#!/bin/bash

# tests/test_concurrency_cap.sh
# Verify MAX_CONCURRENT_JOBS caps simultaneous RUNNING jobs in both
# main-loop and --service (manual trigger) admission paths.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] Concurrency Cap Test Started..."

# ------------------------------------------------------------------
# Scenario A: Main-loop admission obeys cap
# ------------------------------------------------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

# Seed 6 active services so the scheduler always has candidates
for i in 1 2 3 4 5 6; do
    $DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('capsvc${i}', 1, 1);"
done

# Force the scheduling window open so dispatch happens regardless of the
# wall-clock when the test runs. This test exercises the concurrency cap,
# not the time-gating behavior.
export START_TIME=00:00
export END_TIME=23:59
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=2

echo "[Info] Running scheduler with MAX_CONCURRENT_JOBS=2 for 12s..."
timeout 15s "$SCHEDULER" &
SCHEDULER_PID=$!

MAX_RUNNING=0
for i in {1..12}; do
    RUNNING_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='RUNNING';")
    [ -z "$RUNNING_COUNT" ] && RUNNING_COUNT=0
    if [ "$RUNNING_COUNT" -gt "$MAX_RUNNING" ]; then
        MAX_RUNNING="$RUNNING_COUNT"
    fi
    if [ "$RUNNING_COUNT" -gt 2 ]; then
        echo "[Fail] Cap breached: $RUNNING_COUNT running jobs (cap=2)."
        FAIL=$((FAIL + 1))
        kill -9 $SCHEDULER_PID 2>/dev/null
        cleanup_test_db "$TEST_DB"
        print_test_summary
        exit 1
    fi
    sleep 1
done

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null

COMPLETED_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='COMPLETED';")
echo "[Result A] Max Simultaneous Running Jobs: $MAX_RUNNING (cap=2)"
echo "[Result A] Completed Jobs: $COMPLETED_COUNT"

if [ "$MAX_RUNNING" -le 2 ] && [ "$COMPLETED_COUNT" -ge 1 ]; then
    echo "[Pass] Main-loop cap honored and slots are released after completion."
    PASS=$((PASS + 1))
else
    echo "[Fail] Expected max<=2 running and >=1 completed, got max=$MAX_RUNNING completed=$COMPLETED_COUNT."
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"

# ------------------------------------------------------------------
# Scenario B: --service (manual trigger) refuses to exceed cap
# ------------------------------------------------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# 3 services; 2 already RUNNING (pre-populated — no real process needed,
# since --service path only reads the count, never probes liveness)
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('capsvcA', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('capsvcB', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('capsvcC', 1, 1);"
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, pid) VALUES (1, 'RUNNING', datetime('now', 'localtime'), 99991);"
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, pid) VALUES (2, 'RUNNING', datetime('now', 'localtime'), 99992);"

export MAX_CONCURRENT_JOBS=2

MANUAL_OUTPUT=$("$SCHEDULER" --service capsvcC 2>&1)
MANUAL_EXIT=$?

NEW_JOBS=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=3;")

echo "[Result B] Manual trigger exit code: $MANUAL_EXIT"
echo "[Result B] Jobs created for capsvcC: $NEW_JOBS (expected 0)"

if [ "$MANUAL_EXIT" -ne 0 ] && [ "$NEW_JOBS" = "0" ] && echo "$MANUAL_OUTPUT" | grep -q "Concurrency cap reached"; then
    echo "[Pass] Manual trigger blocked by cap with correct diagnostic."
    PASS=$((PASS + 1))
else
    echo "[Fail] Manual trigger did not honor cap. Exit=$MANUAL_EXIT NewJobs=$NEW_JOBS"
    echo "--- output ---"
    echo "$MANUAL_OUTPUT"
    echo "--------------"
    FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
# Scenario C: Slot release allows new admission
# ------------------------------------------------------------------
# Free one slot by completing one of the two pre-populated RUNNING jobs
$DB_QUERY "UPDATE jobs SET status='COMPLETED', end_time=datetime('now', 'localtime') WHERE service_id=1 AND status='RUNNING';"

MANUAL_OUTPUT2=$("$SCHEDULER" --service capsvcC 2>&1)
MANUAL_EXIT2=$?

# With 1 RUNNING + cap=2, new job for capsvcC should be accepted and then
# complete (run_indexing_task's dummy sleep exits 0).
FINAL_C_JOB=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=3 ORDER BY id DESC LIMIT 1;")

echo "[Result C] Manual trigger exit after slot free: $MANUAL_EXIT2"
echo "[Result C] Final job status for capsvcC: $FINAL_C_JOB"

if [ "$MANUAL_EXIT2" -eq 0 ] && [ "$FINAL_C_JOB" = "COMPLETED" ]; then
    echo "[Pass] Cap correctly releases when a RUNNING job transitions to COMPLETED."
    PASS=$((PASS + 1))
else
    echo "[Fail] Expected exit 0 and COMPLETED status, got exit=$MANUAL_EXIT2 status=$FINAL_C_JOB"
    echo "--- output ---"
    echo "$MANUAL_OUTPUT2"
    echo "--------------"
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"
print_test_summary
exit $?
