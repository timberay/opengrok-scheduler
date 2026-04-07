#!/bin/bash

# tests/test_sequence_mode.sh
# Test script to verify sequential execution mode (--sequence)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] Sequential Execution Mode Test Started..."

# 1. Setup Isolated Test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

# 2. Add services
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('seq1', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('seq2', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('seq3', 1, 1);"

# 3. Run scheduler in background with --sequence, short interval, high threshold
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
timeout 20s "$SCHEDULER" --sequence &
SCHEDULER_PID=$!

echo "[Info] Monitoring running jobs for 15 seconds to ensure sequential execution..."

MAX_RUNNING=0
for i in {1..15}; do
    RUNNING_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='RUNNING';")
    
    if [ "$RUNNING_COUNT" -gt "$MAX_RUNNING" ]; then
        MAX_RUNNING="$RUNNING_COUNT"
    fi
    
    if [ "$RUNNING_COUNT" -gt 1 ]; then
        echo "[Fail] Sequential execution violated: $RUNNING_COUNT jobs running simultaneously."
        FAIL=$((FAIL + 1))
        kill -9 $SCHEDULER_PID 2>/dev/null
        cleanup_test_db "$TEST_DB"
        print_test_summary
        exit 1
    fi
    sleep 1
done

# 4. Verify DB state at end
RUNNING_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='RUNNING';")
COMPLETED_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='COMPLETED';")

echo "[Result] Max Simultaneous Running Jobs: $MAX_RUNNING"
echo "[Result] Total Completed Jobs: $COMPLETED_COUNT"
echo "[Result] Currently Running Jobs: $RUNNING_COUNT"

TOTAL_STARTED=$((RUNNING_COUNT + COMPLETED_COUNT))
if [ "$MAX_RUNNING" -le 1 ] && [ "$TOTAL_STARTED" -ge 1 ]; then
    echo "[Pass] Sequential execution verified: Max 1 running job and $TOTAL_STARTED total jobs processed."
    PASS=$((PASS + 1))
else
    echo "[Fail] Expected max 1 running and at least 1 started, but got max $MAX_RUNNING running, $TOTAL_STARTED started."
    FAIL=$((FAIL + 1))
fi

kill $SCHEDULER_PID 2>/dev/null
wait $SCHEDULER_PID 2>/dev/null
cleanup_test_db "$TEST_DB"
print_test_summary
exit $?
