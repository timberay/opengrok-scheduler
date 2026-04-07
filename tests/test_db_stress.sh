#!/bin/bash

# tests/test_db_stress.sh
# Extreme stress test for DB concurrency

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

# 1. Setup Isolated Test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

echo "[Stress Test] Starting SQLite concurrency stress test..."

# 2. Spawn concurrent write processes
CONCURRENCY=10
ITERATIONS=5
echo "[Stage 1] Spawning $CONCURRENCY concurrent writers ($ITERATIONS iterations each)..."

PIDS=()
for i in $(seq 1 $CONCURRENCY); do
    (
        for j in $(seq 1 $ITERATIONS); do
            # Attempt to insert with retry on lock
            MAX_RETRIES=3
            for attempt in $(seq 1 $MAX_RETRIES); do
                RES=$($DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES (1, 'RUNNING', datetime('now')); SELECT last_insert_rowid();" 2>&1)
                if [[ "$RES" != *"database is locked"* ]]; then
                    break
                fi
                if [ "$attempt" -eq "$MAX_RETRIES" ]; then
                    echo "[FAIL] Process $i, Iteration $j: DB Locked after $MAX_RETRIES retries!"
                    exit 1
                fi
                sleep 0.$((RANDOM % 5 + 1))
            done

            JOB_ID=$(echo "$RES" | grep -vE "^(wal|[0-9]{5})$" | tail -n 1)
            if [[ ! "$JOB_ID" =~ ^[0-9]+$ ]]; then
                echo "[FAIL] Process $i, Iteration $j: Invalid Job ID."
                echo "Full Response: $RES"
                exit 1
            fi

            # Update with retry on lock
            for attempt in $(seq 1 $MAX_RETRIES); do
                UPDATE_RES=$($DB_QUERY "UPDATE jobs SET status='COMPLETED' WHERE id=$JOB_ID;" 2>&1)
                if [[ "$UPDATE_RES" != *"database is locked"* ]]; then
                    break
                fi
                if [ "$attempt" -eq "$MAX_RETRIES" ]; then
                    echo "[FAIL] Process $i, Iteration $j: DB Locked on Update after $MAX_RETRIES retries!"
                    exit 1
                fi
                sleep 0.$((RANDOM % 5 + 1))
            done
        done
    ) &
    PIDS+=($!)
done

# 3. Wait for all background jobs and collect exit codes
BG_FAILURES=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        BG_FAILURES=$((BG_FAILURES + 1))
    fi
done

if [ "$BG_FAILURES" -eq 0 ]; then
    SUCCESS_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='COMPLETED';")
    EXPECTED=$((CONCURRENCY * ITERATIONS))
    assert_eq "Concurrency stress test result" "$EXPECTED" "$SUCCESS_COUNT"
else
    echo "[Fail] Stress test failed: $BG_FAILURES background processes had errors."
    FAIL=$((FAIL + 1))
fi

cleanup_test_db "$TEST_DB"
print_test_summary
exit $?
