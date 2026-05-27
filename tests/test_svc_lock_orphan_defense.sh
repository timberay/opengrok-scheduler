#!/bin/bash
#
# tests/test_svc_lock_orphan_defense.sh
#
# Residual risk (b): the scheduler crashes between INSERT (status=RUNNING,
# pid=NULL) and the subsequent UPDATE pid. On restart the bulk ORPHANED
# sweep marks the pid=NULL row terminal, but the spawned subshell that
# was running the indexing task has been reparented to init and is still
# alive. The next dispatch cycle finds the service eligible (its only DB
# row is now ORPHANED, so the B1 per-service NOT EXISTS guard passes)
# and a SECOND indexing task runs concurrently against the same target.
#
# Defense: the dispatched subshell holds an exclusive flock on a
# per-service lock file via an inherited FD. The lock is bound to the
# open file description, so an orphan subshell that outlived its parent
# scheduler keeps the lock alive until the orphan itself exits. Any new
# scheduler's dispatch for the same service tries to acquire the lock,
# fails, and skips with a diagnostic.
#
# Sub-cases:
#   SL1  External flock held → dispatch skipped, no DB row created.
#   SL2  Lock released after orphan exits → next dispatch succeeds.
#   SL3  Lock NOT held → dispatch proceeds normally (no false positive).

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

echo "=== Test: per-service flock blocks duplicate dispatch across crash ==="

SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

# Wait briefly for an inode-based lock file to be releasable by an external
# observer. setup_test_db reuses the same DB path across sub-cases (via $$),
# so a lingering subshell from a previous sub-case can still hold the
# scheduler's main flock on ${DB_PATH}.lock for a moment after wait returns.
# Returns 0 once the lock is available, 1 on timeout.
wait_for_lock_free() {
    local lock_file="$1"
    local deadline=$(( $(date +%s) + 5 ))
    while [ "$(date +%s)" -lt $deadline ]; do
        flock -n -x "$lock_file" -c true 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}

# Kill an orphan process AND its direct children (the bash subshell forked
# `sleep 60` as a child; killing only the bash leaves the sleep reparented
# to init while still holding the inherited lock FD — the very behaviour
# we are testing for the scheduler, but here we want a clean teardown).
teardown_orphan() {
    local pid="$1"
    local kids
    kids=$(pgrep -P "$pid" 2>/dev/null || true)
    [ -n "$kids" ] && kill -TERM $kids 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.3
    [ -n "$kids" ] && kill -KILL $kids 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# --------------------------------------------------------------------
# SL1: orphan subshell holds the lock — scheduler must skip the dispatch
# --------------------------------------------------------------------
TEST_DB=$(setup_test_db); export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('svc-locked',1);"

SVC_LOCK="${TEST_DB}.svc.svc-locked.lock"

# Spawn an "orphan" subshell that takes the exact same lock the scheduler
# would acquire for svc-locked, and holds it for 30 s. This stands in for
# a real reparented indexing subshell whose parent scheduler crashed.
( exec {fd}>>"$SVC_LOCK"; flock -n -x "$fd" || exit 99; sleep 30 ) &
ORPHAN_PID=$!

# Give the orphan a moment to actually take the lock.
deadline=$(( $(date +%s) + 3 ))
LOCK_TAKEN=0
while [ "$(date +%s)" -lt $deadline ]; do
    if ! flock -n -x "$SVC_LOCK" -c true 2>/dev/null; then
        LOCK_TAKEN=1; break
    fi
    sleep 0.1
done
[ "$LOCK_TAKEN" -eq 1 ] \
    && { PASS=$((PASS+1)); echo "[Pass] SL1/precondition: orphan PID=$ORPHAN_PID holds svc-lock"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] SL1/precondition: orphan did not take lock"; kill -9 $ORPHAN_PID 2>/dev/null; cleanup_test_db "$TEST_DB"; print_test_summary; exit 1; }

# Launch the real scheduler with an always-open window so it will try to
# dispatch svc-locked. Give it ~5 s of loop time.
export START_TIME=00:00 END_TIME=23:59 CHECK_INTERVAL=1 RESOURCE_THRESHOLD=100 MAX_CONCURRENT_JOBS=2 KILL_GRACE_SEC=1
SCHED_LOG=$(mktemp)
timeout 5s "$SCHEDULER" >"$SCHED_LOG" 2>&1 &
SCHED_PID=$!
wait $SCHED_PID 2>/dev/null

# SL1 assertions: no jobs row created (orphan still alive, lock still held)
# and the scheduler logged the skip diagnostic at least once.
JOB_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='svc-locked');")
assert_eq "SL1: no jobs row inserted for svc-locked while external lock held" "0" "$JOB_COUNT"

grep -q "external svc-lock held for svc-locked" "$SCHED_LOG" \
    && { PASS=$((PASS+1)); echo "[Pass] SL1: scheduler logged the svc-lock skip diagnostic"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] SL1: skip diagnostic missing (last log lines:)"; tail -10 "$SCHED_LOG" | sed 's/^/   /'; }

# Orphan must still be alive — we did NOT kill it from the scheduler.
kill -0 $ORPHAN_PID 2>/dev/null \
    && { PASS=$((PASS+1)); echo "[Pass] SL1: orphan still alive after scheduler skipped"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] SL1: orphan died unexpectedly"; }

# Tear down SL1: release the orphan, clean up.
teardown_orphan "$ORPHAN_PID"
rm -f "$SCHED_LOG"
cleanup_test_db "$TEST_DB"
rm -f "$SVC_LOCK"

# --------------------------------------------------------------------
# SL2: lock release semantics — once nothing holds the lock, a fresh
# scheduler run dispatches normally. Split into two scheduler runs to
# isolate from the first-iteration resource-sampling timing (~4-5 s),
# which dominates a single-run test's wall-clock.
# --------------------------------------------------------------------
echo ""
echo "--- SL2: dispatch resumes after the holder releases the lock ---"
TEST_DB=$(setup_test_db); export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('svc-recovers',1);"

SVC_LOCK="${TEST_DB}.svc.svc-recovers.lock"

# Long-held orphan: keep the lock until explicitly killed, so timing is
# decoupled from scheduler's resource-sampling latency.
( exec {fd}>>"$SVC_LOCK"; flock -n -x "$fd" || exit 99; sleep 60 ) &
ORPHAN_PID=$!
# Wait for the orphan to actually take the lock before launching scheduler.
deadline=$(( $(date +%s) + 3 ))
while [ "$(date +%s)" -lt $deadline ]; do
    flock -n -x "$SVC_LOCK" -c true 2>/dev/null || break
    sleep 0.1
done

# Phase A: run scheduler with the orphan holding the lock. Expect skip + no dispatch.
export START_TIME=00:00 END_TIME=23:59 CHECK_INTERVAL=1 RESOURCE_THRESHOLD=100 MAX_CONCURRENT_JOBS=2 KILL_GRACE_SEC=1
SCHED_LOG=$(mktemp)
timeout 8s "$SCHEDULER" >"$SCHED_LOG" 2>&1 &
SCHED_PID=$!
wait $SCHED_PID 2>/dev/null

SKIPS_A=$(grep -c "external svc-lock held for svc-recovers" "$SCHED_LOG" || true)
[ "$SKIPS_A" -ge 1 ] \
    && { PASS=$((PASS+1)); echo "[Pass] SL2/A: scheduler skipped during the orphan hold ($SKIPS_A log line(s))"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] SL2/A: expected at least 1 skip log, got $SKIPS_A"; tail -10 "$SCHED_LOG" | sed 's/^/   /'; }

JOBS_DURING_HOLD=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='svc-recovers');")
assert_eq "SL2/A: no jobs row inserted while orphan held lock" "0" "$JOBS_DURING_HOLD"

# Phase B: kill the orphan (releases the lock), then run scheduler again. Expect dispatch.
teardown_orphan "$ORPHAN_PID"
# Confirm lock is now releasable.
flock -n -x "$SVC_LOCK" -c true 2>/dev/null \
    && { PASS=$((PASS+1)); echo "[Pass] SL2/B: lock released after orphan exit"; } \
    || { FAIL=$((FAIL+1)); echo "[Fail] SL2/B: lock still held after killing orphan"; }

> "$SCHED_LOG"
timeout 8s "$SCHEDULER" >"$SCHED_LOG" 2>&1 &
SCHED_PID=$!
wait $SCHED_PID 2>/dev/null

# Any terminal row from this run path proves dispatch happened. ORPHANED is
# acceptable (it just means the SIGTERM cleanup intercepted a still-running
# job mid-flight); the meaningful contract is "a job row exists with the
# scheduler-recorded PID", which the skip-path never produces.
DISPATCHED_PID=$($DB_QUERY "SELECT pid FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='svc-recovers') AND pid IS NOT NULL LIMIT 1;")
if [ -n "$DISPATCHED_PID" ]; then
    PASS=$((PASS+1)); echo "[Pass] SL2/B: dispatch resumed after lock release (recorded PID=$DISPATCHED_PID)"
else
    FAIL=$((FAIL+1)); echo "[Fail] SL2/B: no dispatched-with-pid row appeared after lock release"
    tail -15 "$SCHED_LOG" | sed 's/^/   /'
fi

rm -f "$SCHED_LOG"
cleanup_test_db "$TEST_DB"
rm -f "$SVC_LOCK"

# --------------------------------------------------------------------
# SL3: NO orphan — dispatch proceeds normally (false-positive guard)
# --------------------------------------------------------------------
echo ""
echo "--- SL3: no external lock → normal dispatch (no false-positive skip) ---"
TEST_DB=$(setup_test_db); export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('svc-normal',1);"

# Lingering subshell from the prior SL2/B scheduler may still hold the
# main flock on ${DB_PATH}.lock for a moment. Wait it out before starting
# our scheduler, otherwise it would refuse with "Another scheduler
# instance is already running" — a spurious failure unrelated to the
# svc-lock semantics this sub-case is pinning.
wait_for_lock_free "${TEST_DB}.lock" \
    || { FAIL=$((FAIL+1)); echo "[Fail] SL3/precondition: main scheduler lock did not become free in time"; }

export START_TIME=00:00 END_TIME=23:59 CHECK_INTERVAL=1 RESOURCE_THRESHOLD=100 MAX_CONCURRENT_JOBS=2 KILL_GRACE_SEC=1
SCHED_LOG=$(mktemp)
timeout 8s "$SCHEDULER" >"$SCHED_LOG" 2>&1 &
SCHED_PID=$!
wait $SCHED_PID 2>/dev/null

JOB_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=(SELECT id FROM services WHERE container_name='svc-normal') ORDER BY id DESC LIMIT 1;")
case "$JOB_STATUS" in
    COMPLETED|FAILED|TIMEOUT)
        PASS=$((PASS+1)); echo "[Pass] SL3: dispatch proceeded normally without an external lock (status='$JOB_STATUS')" ;;
    *)
        FAIL=$((FAIL+1)); echo "[Fail] SL3: expected terminal status, got '$JOB_STATUS'"
        tail -15 "$SCHED_LOG" | sed 's/^/   /' ;;
esac

grep -q "external svc-lock held for svc-normal" "$SCHED_LOG" \
    && { FAIL=$((FAIL+1)); echo "[Fail] SL3: false-positive skip log appeared without an external lock"; } \
    || { PASS=$((PASS+1)); echo "[Pass] SL3: no false-positive skip log"; }

rm -f "$SCHED_LOG"
cleanup_test_db "$TEST_DB"
rm -f "${TEST_DB}.svc.svc-normal.lock"

print_test_summary
