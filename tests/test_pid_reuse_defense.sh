#!/bin/bash

# tests/test_pid_reuse_defense.sh
# Integration test for critical issues #1 and #2: the scheduler's recovery
# and stale-expire paths must NOT kill or restore a PID whose recorded
# starttime no longer matches the running process. Without this defense,
# a recycled PID could lead to SIGKILLing an unrelated user process.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "[Test] PID-reuse defense in recovery and stale-expire paths..."

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
export LOG_DIR="$PROJECT_ROOT/logs/test"
export CHECK_INTERVAL=2
export START_TIME=00:00
export END_TIME=23:59
export RESOURCE_THRESHOLD=200
# Force the stale window to fire fast: 0.0001 seconds means anything older
# than ~0 seconds is stale. JOB_TIMEOUT_SEC is multiplied by 2 in the code,
# but we bypass that by directly setting jobs with a past start_time.
export JOB_TIMEOUT_SEC=1
mkdir -p "$LOG_DIR"

LOCK_FILE="${TEST_DB}.lock"
SCHEDULER_PID=""

cleanup() {
    [ -n "$SCHEDULER_PID" ] && kill -KILL "$SCHEDULER_PID" 2>/dev/null
    [ -n "$SENTINEL_PID" ] && kill -KILL "$SENTINEL_PID" 2>/dev/null
    wait 2>/dev/null
    cleanup_test_db "$TEST_DB"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# Apply migrations to the test DB so pid_starttime column exists
"$PROJECT_ROOT/bin/migrate_db.sh" >/dev/null 2>&1

# --- Setup: spawn a sentinel process the test runner controls. The scheduler
#     will see it referenced in the DB but its starttime will be deliberately
#     wrong, simulating the PID-reuse case. We MUST NOT see this PID killed. ---
sleep 600 &
SENTINEL_PID=$!
sleep 0.1
SENTINEL_START_REAL=$(awk '{n=NR; for(i=NF;i>0;i--) if($i ~ /^[0-9]+$/) {;}} END{}' /proc/$SENTINEL_PID/stat 2>/dev/null)
# Use the helper to capture the real starttime
source "$PROJECT_ROOT/bin/monitor.sh" >/dev/null 2>&1
SENTINEL_START_REAL=$(get_pid_starttime "$SENTINEL_PID")
SENTINEL_START_FAKE=$((SENTINEL_START_REAL - 100))   # deliberately wrong

# Insert a service + a stale RUNNING job referencing the sentinel PID with the
# WRONG starttime. The stale path must skip the kill.
sqlite3 "$TEST_DB" "INSERT INTO services (container_name, priority, is_active) VALUES ('reuse_target', 1, 1);"
SVC_ID=$(sqlite3 "$TEST_DB" "SELECT id FROM services WHERE container_name='reuse_target';")
sqlite3 "$TEST_DB" "INSERT INTO jobs (service_id, status, pid, pid_starttime, start_time)
                    VALUES ($SVC_ID, 'RUNNING', $SENTINEL_PID, $SENTINEL_START_FAKE,
                            datetime('now','localtime','-30 seconds'));"
JOB_ID=$(sqlite3 "$TEST_DB" "SELECT id FROM jobs WHERE pid=$SENTINEL_PID;")

# --- Run scheduler briefly so it executes one stale-expire cycle ---
"$PROJECT_ROOT/bin/scheduler.sh" >/dev/null 2>&1 &
SCHEDULER_PID=$!
sleep 5
kill -TERM "$SCHEDULER_PID" 2>/dev/null
wait "$SCHEDULER_PID" 2>/dev/null
SCHEDULER_PID=""

# --- Assert 1: sentinel must still be alive (stale path skipped the kill) ---
if kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "[Pass] Stale-expire skipped kill on PID with mismatched starttime"
    PASS=$((PASS + 1))
else
    echo "[Fail] Sentinel PID was killed despite starttime mismatch (PID reuse hazard)"
    FAIL=$((FAIL + 1))
fi

# --- Assert 2: job row must be marked TIMEOUT with diagnostic message ---
JOB_STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE id=$JOB_ID;")
JOB_MSG=$(sqlite3 "$TEST_DB" "SELECT message FROM jobs WHERE id=$JOB_ID;")
if [ "$JOB_STATUS" = "TIMEOUT" ]; then
    echo "[Pass] Stale job marked TIMEOUT in DB (status=$JOB_STATUS, msg='$JOB_MSG')"
    PASS=$((PASS + 1))
else
    echo "[Fail] Stale job status=$JOB_STATUS (expected TIMEOUT)"
    FAIL=$((FAIL + 1))
fi

# --- Assert 3: recovery must NOT add the mismatched PID to BG_PIDS. We test
#     this indirectly by running scheduler again with the same DB row reverted
#     to RUNNING + wrong starttime, then checking the row gets marked ORPHANED.
#     Bump JOB_TIMEOUT_SEC for this scheduler invocation so stale auto-expire
#     (which would otherwise overwrite ORPHANED → TIMEOUT within ~2s) does not
#     fire during our observation window. We are testing the recovery path
#     in isolation here; the stale path is covered by Assert 1/2 above. ---
sqlite3 "$TEST_DB" "UPDATE jobs SET status='RUNNING', start_time=datetime('now','localtime') WHERE id=$JOB_ID;"
JOB_TIMEOUT_SEC=300 "$PROJECT_ROOT/bin/scheduler.sh" >/dev/null 2>&1 &
SCHEDULER_PID=$!
sleep 3
kill -TERM "$SCHEDULER_PID" 2>/dev/null
wait "$SCHEDULER_PID" 2>/dev/null
SCHEDULER_PID=""

POST_STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE id=$JOB_ID;")
if [ "$POST_STATUS" = "ORPHANED" ]; then
    echo "[Pass] Recovery marked mismatched-starttime row as ORPHANED (no restore)"
    PASS=$((PASS + 1))
else
    echo "[Fail] Recovery status=$POST_STATUS (expected ORPHANED)"
    FAIL=$((FAIL + 1))
fi

# --- Assert 4: sentinel STILL alive after recovery cycle ---
if kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "[Pass] Sentinel still alive after recovery cycle"
    PASS=$((PASS + 1))
else
    echo "[Fail] Sentinel killed during recovery cycle"
    FAIL=$((FAIL + 1))
fi

# --- Assert 5: legitimate matching starttime DOES allow recovery. We verify
#     by checking the row is restored as tracked (not marked ORPHANED).
#     Same JOB_TIMEOUT_SEC bump as Assert 3 to keep stale path out of scope. ---
sqlite3 "$TEST_DB" "UPDATE jobs SET status='RUNNING', start_time=datetime('now','localtime'), pid_starttime=$SENTINEL_START_REAL WHERE id=$JOB_ID;"
JOB_TIMEOUT_SEC=300 "$PROJECT_ROOT/bin/scheduler.sh" >/dev/null 2>&1 &
SCHEDULER_PID=$!
sleep 3

ALIVE_STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM jobs WHERE id=$JOB_ID;")
if [ "$ALIVE_STATUS" = "RUNNING" ]; then
    echo "[Pass] Recovery restored job with matching starttime (status=RUNNING)"
    PASS=$((PASS + 1))
else
    echo "[Fail] Recovery did not restore matching-starttime job (status=$ALIVE_STATUS)"
    FAIL=$((FAIL + 1))
fi

kill -TERM "$SCHEDULER_PID" 2>/dev/null
wait "$SCHEDULER_PID" 2>/dev/null
SCHEDULER_PID=""

print_test_summary
