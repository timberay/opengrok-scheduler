#!/bin/bash
#
# tests/test_purge_with_in_flight.sh
#
# --purge-all must be SAFE in the presence of a live scheduler. Same hazard
# as --init had pre-f925e0d: --purge-all bypasses the advisory flock, and
# wiping `jobs`/`runs` out from under an active main loop would let it
# open a fresh run on the next iteration and re-dispatch every service.
# The per-service NOT EXISTS guard at INSERT time can't help here — the
# rows it checks are precisely what we just deleted.
#
# Sub-cases (mirror test_init_with_in_flight.sh structure):
#   PA1 (REFUSE):       live scheduler running → --purge-all exits non-zero,
#                       mentions the live PID, leaves all rows intact.
#   PA2 (PROCEED):      no live scheduler, seeded RUNNING run+jobs → --purge-all
#                       wipes everything, services table untouched.
#   PA2' (STALE LOCK):  lock file points to a dead PID → falls through to wipe.
#   PA3 (NO-OP):        no live scheduler, empty DB → benign wipe, exit 0.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "=== Test: --purge-all refuses while live scheduler is running ==="

SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

# --------------------------------------------------------------------
# PA1: REFUSE — main loop running on this DB
# --------------------------------------------------------------------
TEST_DB=$(setup_test_db); export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('pa-svc-a',1),('pa-svc-b',1);"

# Launch a real scheduler in background with always-open window so it grabs the
# flock and starts dispatching. timeout caps the run time as a safety net.
export START_TIME=00:00 END_TIME=23:59 CHECK_INTERVAL=1 RESOURCE_THRESHOLD=100 MAX_CONCURRENT_JOBS=2 KILL_GRACE_SEC=1
timeout 20s "$SCHEDULER" >/dev/null 2>&1 &
SCHEDULER_PID=$!

# Wait up to 10s for the scheduler to record its PID in the lock file
# (confirms it grabbed the flock and is the live instance).
deadline=$(( $(date +%s) + 10 ))
LIVE=""
while [ "$(date +%s)" -lt $deadline ]; do
    if [ -s "${TEST_DB}.lock" ]; then
        LIVE=$(head -1 "${TEST_DB}.lock" 2>/dev/null)
        [[ "$LIVE" =~ ^[0-9]+$ ]] && kill -0 "$LIVE" 2>/dev/null && break
    fi
    sleep 0.2
done

if [[ ! "$LIVE" =~ ^[0-9]+$ ]]; then
    FAIL=$((FAIL+1)); echo "[Fail] PA1/precondition: scheduler did not register in lock file"
    kill $SCHEDULER_PID 2>/dev/null; wait $SCHEDULER_PID 2>/dev/null
    cleanup_test_db "$TEST_DB"
    print_test_summary; exit 1
fi
PASS=$((PASS+1)); echo "[Pass] PA1/precondition: live scheduler PID=$LIVE in lock file"

# Snapshot DB state pre-purge so we can assert it's unchanged after refusal.
PRE_RUNS=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
PRE_JOBS=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")

PURGE_OUT=$("$SCHEDULER" --purge-all 2>&1)
PURGE_EXIT=$?

POST_RUNS=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
POST_JOBS=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")

[ "$PURGE_EXIT" -ne 0 ] \
    && { PASS=$((PASS+1)); echo "[Pass] PA1: --purge-all exited non-zero (got $PURGE_EXIT)"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] PA1: expected non-zero exit, got 0"; }

echo "$PURGE_OUT" | grep -q "refused" \
    && { PASS=$((PASS+1)); echo "[Pass] PA1: diagnostic includes the word 'refused'"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] PA1: diagnostic missing 'refused' (got: $PURGE_OUT)"; }

echo "$PURGE_OUT" | grep -q "PID=$LIVE" \
    && { PASS=$((PASS+1)); echo "[Pass] PA1: diagnostic references live PID=$LIVE"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] PA1: diagnostic missing live PID (got: $PURGE_OUT)"; }

echo "$PURGE_OUT" | grep -q "kill -TERM" \
    && { PASS=$((PASS+1)); echo "[Pass] PA1: diagnostic suggests kill -TERM remediation"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] PA1: diagnostic missing 'kill -TERM' (got: $PURGE_OUT)"; }

assert_eq "PA1: runs row count unchanged (no deletion happened)" "$PRE_RUNS" "$POST_RUNS"
assert_eq "PA1: jobs row count unchanged (no deletion happened)" "$PRE_JOBS" "$POST_JOBS"

# Teardown the live scheduler before subsequent sub-cases.
kill $SCHEDULER_PID 2>/dev/null; wait $SCHEDULER_PID 2>/dev/null
cleanup_test_db "$TEST_DB"

# --------------------------------------------------------------------
# PA2: PROCEED — no live scheduler, seeded RUNNING run + jobs → full wipe
# --------------------------------------------------------------------
echo ""
echo "--- PA2: PROCEED (no live scheduler, seeded RUNNING state) ---"
TEST_DB=$(setup_test_db); export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('pa-svc-c',1);"
$DB_QUERY "INSERT INTO runs(started_at, status, triggered_by, total_services)
           VALUES (datetime('now','localtime'), 'RUNNING', 'auto', 1);"
RID=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' LIMIT 1;")
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, pid)
           VALUES (1, $RID, 'RUNNING', datetime('now','localtime'), 99991);"
# No lock file written — emulates 'scheduler was never running this session'.

PURGE_OUT=$("$SCHEDULER" --purge-all 2>&1)
PURGE_EXIT=$?

[ "$PURGE_EXIT" -eq 0 ] \
    && { PASS=$((PASS+1)); echo "[Pass] PA2: --purge-all proceeded (exit 0)"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] PA2: expected exit 0, got $PURGE_EXIT (out: $PURGE_OUT)"; }

RUN_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
JOB_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
SVC_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM services;")
assert_eq "PA2: runs wiped"     "0" "$RUN_COUNT"
assert_eq "PA2: jobs wiped"     "0" "$JOB_COUNT"
assert_eq "PA2: services kept"  "1" "$SVC_COUNT"

cleanup_test_db "$TEST_DB"

# --------------------------------------------------------------------
# PA2': STALE LOCK FILE — points to a dead PID; should fall through
# --------------------------------------------------------------------
echo ""
echo "--- PA2': PROCEED past stale lock file (dead PID) ---"
TEST_DB=$(setup_test_db); export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('pa-svc-d',1);"

# Plant a lock file with a recycled-but-dead PID: spawn a no-op child,
# wait it out so its PID is freed, then write that PID into the lock.
# refuse_if_live_scheduler's `kill -0` should fail on it and the call falls
# through to the wipe path.
sleep 0 & STALE=$!; wait $STALE 2>/dev/null
echo "$STALE" > "${TEST_DB}.lock"
if kill -0 "$STALE" 2>/dev/null; then
    echo "[Skip] PA2': PID=$STALE unexpectedly still alive; skipping stale-lock sub-case"
    cleanup_test_db "$TEST_DB"
    rm -f "${TEST_DB}.lock"
    print_test_summary; exit $?
fi

PURGE_OUT=$("$SCHEDULER" --purge-all 2>&1)
PURGE_EXIT=$?

[ "$PURGE_EXIT" -eq 0 ] \
    && { PASS=$((PASS+1)); echo "[Pass] PA2': --purge-all proceeded past stale lock (exit 0)"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] PA2': expected exit 0, got $PURGE_EXIT (out: $PURGE_OUT)"; }

cleanup_test_db "$TEST_DB"
rm -f "${TEST_DB}.lock"

# --------------------------------------------------------------------
# PA3: NO-OP — no live scheduler, empty DB → benign wipe
# --------------------------------------------------------------------
echo ""
echo "--- PA3: NO-OP (no live scheduler, empty DB) ---"
TEST_DB=$(setup_test_db); export DB_PATH="$TEST_DB"

PURGE_OUT=$("$SCHEDULER" --purge-all 2>&1)
PURGE_EXIT=$?

[ "$PURGE_EXIT" -eq 0 ] \
    && { PASS=$((PASS+1)); echo "[Pass] PA3: --purge-all exit 0 on empty DB"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] PA3: expected exit 0, got $PURGE_EXIT"; }

echo "$PURGE_OUT" | grep -qi "deleting ALL" \
    && { PASS=$((PASS+1)); echo "[Pass] PA3: wipe warning printed"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] PA3: wipe warning missing"; }

cleanup_test_db "$TEST_DB"

print_test_summary
