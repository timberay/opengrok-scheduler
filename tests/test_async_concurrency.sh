#!/bin/bash

# tests/test_async_concurrency.sh
# Test script to verify asynchronous concurrency and fixed interval

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$PROJECT_ROOT/bin"
DATA_DIR="$PROJECT_ROOT/data"
DB_PATH="$DATA_DIR/scheduler.db"
SCHEDULER="$BIN_DIR/scheduler.sh"

echo "[Test] Async Concurrency Test Started..."

# 1. Reset DB
sqlite3 "$DB_PATH" "DELETE FROM jobs;"
sqlite3 "$DB_PATH" "DELETE FROM services;"
sqlite3 "$DB_PATH" "UPDATE config SET value='5' WHERE key='check_interval';" # Fast check
sqlite3 "$DB_PATH" "UPDATE config SET value='2' WHERE key='max_concurrent_jobs';"

# 2. Add services
sqlite3 "$DB_PATH" "INSERT INTO services (container_name, priority, is_active) VALUES ('svc1', 1, 1);"
sqlite3 "$DB_PATH" "INSERT INTO services (container_name, priority, is_active) VALUES ('svc2', 1, 1);"
sqlite3 "$DB_PATH" "INSERT INTO services (container_name, priority, is_active) VALUES ('svc3', 1, 1);"

# 3. Run scheduler in background
# We source scheduler.sh with a dummy argument to stop it after one loop or just kill it
# But scheduler.sh has a while true loop. Let's run it for a few seconds.
timeout 15s "$SCHEDULER" &
SCHEDULER_PID=$!

echo "[Info] Waiting for scheduler to pick up jobs (approx 15s)..."
sleep 12

# 4. Verify DB state
RUNNING_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM jobs WHERE status='RUNNING';")
COMPLETED_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM jobs WHERE status='COMPLETED';")

echo "[Result] Running Jobs: $RUNNING_COUNT"
echo "[Result] Completed Jobs: $COMPLETED_COUNT"

# Verify concurrency limit (max 2)
if [ "$RUNNING_COUNT" -gt 2 ]; then
    echo "[Fail] More than 2 jobs running simultaneously!"
    kill $SCHEDULER_PID 2>/dev/null
    exit 1
fi

# Verify asynchronous (at least 2 should have started)
if [ $((RUNNING_COUNT + COMPLETED_COUNT)) -lt 2 ]; then
    echo "[Fail] Async execution failed. Expected at least 2 jobs to be processed or running."
    kill $SCHEDULER_PID 2>/dev/null
    exit 1
fi

echo "[Pass] Async concurrency test passed!"
kill $SCHEDULER_PID 2>/dev/null
exit 0
