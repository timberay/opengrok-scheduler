#!/bin/bash

# tests/test_db_stress.sh
# Extreme stress test for DB concurrency

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

echo "[Stress Test] Starting SQLite concurrency stress test..."

# 1. Clear jobs
$DB_QUERY "DELETE FROM jobs;"

# 2. Spawn 50 concurrent write processes
CONCURRENCY=50
echo "[Stage 1] Spawning $CONCURRENCY concurrent writers..."

for i in $(seq 1 $CONCURRENCY); do
    (
        for j in $(seq 1 5); do
            # Attempt to insert and update
            RES=$($DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES (1, 'RUNNING', datetime('now')); SELECT last_insert_rowid();" 2>&1)
            
            if [[ "$RES" == *"database is locked"* ]]; then
                echo "[FAIL] Process $i, Iteration $j: DB Locked!"
                exit 1
            fi
            
            JOB_ID=$(echo "$RES" | grep -vE "^(wal|[0-9]{5})$" | tail -n 1)
            if [[ ! "$JOB_ID" =~ ^[0-9]+$ ]]; then
                echo "[FAIL] Process $i, Iteration $j: Invalid Job ID."
                echo "Full Response: $RES"
                exit 1
            fi
            
            $DB_QUERY "UPDATE jobs SET status='COMPLETED' WHERE id=$JOB_ID;" 2>&1 | grep -q "database is locked" && {
                echo "[FAIL] Process $i, Iteration $j: DB Locked on Update!"
                exit 1
            }
        done
    ) &
done

wait

# 3. Check for any errors in output
if [ $? -eq 0 ]; then
    SUCCESS_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='COMPLETED';")
    EXPECTED=$((CONCURRENCY * 5))
    if [ "$SUCCESS_COUNT" -eq "$EXPECTED" ]; then
        echo "[Success] All $EXPECTED operations completed without a single lock error!"
        echo "[Success] Concurrency stabilization verified."
        exit 0
    else
        echo "[Fail] Expected $EXPECTED completed jobs, but found $SUCCESS_COUNT."
        exit 1
    fi
else
    echo "[Fail] Stress test failed with errors."
    exit 1
fi
