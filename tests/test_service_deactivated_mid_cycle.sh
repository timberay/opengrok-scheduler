#!/bin/bash
# tests/test_service_deactivated_mid_cycle.sh
# Case C2 — Service deactivated mid-cycle (is_active flipped 1->0).
#
# Operator scenario:
#   Scheduler is dispatching. svc-X is currently RUNNING (its job is in
#   flight). Operator runs:
#     UPDATE services SET is_active=0 WHERE container_name='svc-X';
#
# Pinned contract:
#   1. The in-flight job for svc-X completes NORMALLY (we do NOT abort
#      mid-flight). The operator's intent is "stop dispatching in future
#      cycles", not "kill what's already running now". reap_bg_processes
#      and drain_bg_jobs both finalise jobs by their existing row (matched
#      via BG_PIDS + UPDATE ... WHERE pid=$PID AND status='RUNNING') — they
#      do NOT consult services.is_active. The job transitions to COMPLETED
#      (or its natural terminal state from exit code), not ORPHANED.
#   2. Within the current run, svc-X already has a row, so the
#      NEXT_SERVICE_ID query's per-run-dedup (NOT EXISTS row in this run)
#      would already exclude it. is_active=0 has no incremental effect for
#      svc-X inside the current run.
#   3. A deactivated service is never re-dispatched. (When a later cycle does
#      open — e.g. to retry a still-pending service — it is filtered by
#      WHERE s.is_active=1 in NEXT_SERVICE_ID; see C2c for the within-run case.)
#
# Edge cases covered:
#   C2a — In-flight RUNNING job is not aborted by deactivation. Completes
#         normally as COMPLETED.
#   C2b — A deactivated service is not resurrected into a later cycle. Here
#         both services COMPLETED this session, so the per-service success
#         gate keeps the loop idle (no follow-on run) and svc-alpha is never
#         re-dispatched.
#   C2c — Service deactivated AFTER run open but BEFORE its turn to dispatch.
#         The run's total_services snapshot was taken at open time and still
#         counts the (then-active) service. NEXT_SERVICE_ID filters it out
#         when its turn comes. run_can_close_naturally only checks for
#         RUNNING jobs in this run — it does NOT require that every
#         snapshotted service have a row. So the run can still close
#         COMPLETED once the OTHER (active) services finish. This pins that
#         intentional decoupling.
#   C2d — Reactivation symmetry: deactivated-then-reactivated before its turn
#         results in the service being dispatched normally.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== Test: service deactivated mid-cycle (C2) ==="

PASS=0
FAIL=0
pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

SCHED_PID=""
TMP_LOG=""
TEST_DB=""

cleanup() {
    if [ -n "$SCHED_PID" ] && kill -0 "$SCHED_PID" 2>/dev/null; then
        kill -TERM "$SCHED_PID" 2>/dev/null
        for _ in $(seq 1 10); do
            kill -0 "$SCHED_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SCHED_PID" 2>/dev/null
        wait "$SCHED_PID" 2>/dev/null
    fi
    pkill -P $$ 2>/dev/null
    [ -n "$TMP_LOG" ] && rm -f "$TMP_LOG"
    [ -n "$TEST_DB" ] && cleanup_test_db "$TEST_DB"
}
trap cleanup EXIT

# Poll DB until $1 (a sqlite expression returning 0/1 or numeric) satisfies
# the predicate. $2 = expected value, $3 = timeout seconds, $4 = description.
poll_db() {
    local QUERY="$1"
    local EXPECTED="$2"
    local TIMEOUT="$3"
    local DESC="$4"
    local DEADLINE=$(( $(date +%s) + TIMEOUT ))
    local ACTUAL=""
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        ACTUAL=$($DB_QUERY "$QUERY" 2>/dev/null)
        if [ "$ACTUAL" = "$EXPECTED" ]; then
            return 0
        fi
        sleep 1
    done
    echo "[poll_db timeout] $DESC: expected '$EXPECTED', last actual '$ACTUAL'"
    return 1
}

# Stop the currently-tracked scheduler PID (if any).
stop_scheduler() {
    if [ -n "$SCHED_PID" ] && kill -0 "$SCHED_PID" 2>/dev/null; then
        kill -TERM "$SCHED_PID" 2>/dev/null
        for _ in $(seq 1 10); do
            kill -0 "$SCHED_PID" 2>/dev/null || break
            sleep 1
        done
        wait "$SCHED_PID" 2>/dev/null
    fi
    SCHED_PID=""
}

# ---------------------------------------------------------------------------
# C2a + C2b — In-flight job not aborted by deactivation; deactivated service
# is not picked up in the next cycle; snapshot reflects the lowered count.
# ---------------------------------------------------------------------------
echo "--- C2a: in-flight job survives deactivation; C2b: skipped in next cycle ---"
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-alpha', 1, 1),
    ('svc-beta',  1, 1);"

export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
# MAX_CONCURRENT=1 so we can deterministically observe svc-alpha RUNNING
# alone before svc-beta is dispatched.
export MAX_CONCURRENT_JOBS=1
export JOB_IDLE_TIMEOUT=0
export KILL_GRACE_SEC=1

TMP_LOG=$(mktemp /tmp/test_service_deactivated_mid_cycle.XXXXXX.log)

timeout 90s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

ALPHA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-alpha';")
BETA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-beta';")

# Wait until svc-alpha is RUNNING in the open run.
if ! poll_db "SELECT COUNT(*) FROM jobs WHERE service_id=$ALPHA_ID AND status='RUNNING' AND run_id=(SELECT id FROM runs WHERE status='RUNNING');" "1" 30 "svc-alpha is RUNNING in open run"; then
    fail "C2a: svc-alpha never reached RUNNING within 30s"
    echo "--- scheduler log ---"; tail -40 "$TMP_LOG"
    print_test_summary
    exit 1
fi

R1=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;")
[ -n "$R1" ] && pass "C2a: run #$R1 opened with svc-alpha RUNNING" \
              || fail "C2a: no RUNNING run while svc-alpha is RUNNING"

# Snapshot at run open should reflect both initially-active services.
SNAPSHOT_R1=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$R1;")
assert_eq "C2a: run #$R1 total_services snapshot = 2" "2" "$SNAPSHOT_R1"

# Operator deactivates svc-alpha WHILE its job is in flight.
$DB_QUERY "UPDATE services SET is_active=0 WHERE container_name='svc-alpha';"

# The in-flight job must NOT be aborted/killed. It should reach COMPLETED.
# (Dummy task is `sleep 2`, then exit 0 -> reap_bg_processes finalises as
# COMPLETED. Failure mode would be ORPHANED/FAILED, or BG_PIDS being torn
# down on the basis of is_active.)
if poll_db "SELECT status FROM jobs WHERE service_id=$ALPHA_ID AND run_id=$R1;" "COMPLETED" 20 "svc-alpha completes normally"; then
    pass "C2a: svc-alpha in-flight job reached COMPLETED (deactivation did not abort it)"
else
    ACTUAL_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$ALPHA_ID AND run_id=$R1;")
    fail "C2a: svc-alpha did not reach COMPLETED; actual='$ACTUAL_STATUS' (deactivation may have aborted in-flight)"
fi

# svc-beta must still be dispatched & complete in run #1 (it stayed active).
if poll_db "SELECT status FROM jobs WHERE service_id=$BETA_ID AND run_id=$R1;" "COMPLETED" 25 "svc-beta completes in run #$R1"; then
    pass "C2a: svc-beta completed in run #$R1"
else
    fail "C2a: svc-beta did not COMPLETE in run #$R1"
fi

# Run #1 should close cleanly. Even though svc-alpha is now is_active=0,
# its row is already in the run, so close-time aggregation includes it.
if poll_db "SELECT status FROM runs WHERE id=$R1;" "COMPLETED" 20 "run #$R1 closes COMPLETED"; then
    pass "C2a: run #$R1 closed COMPLETED with both job rows present"
else
    fail "C2a: run #$R1 did not close COMPLETED"
fi

# completed_count counts both rows (the deactivation does not retroactively
# remove svc-alpha's contribution from the closed-run aggregate).
R1_COMPLETED=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$R1;")
assert_eq "C2a: run #$R1 completed_count = 2 (both rows aggregated)" "2" "$R1_COMPLETED"

# --- C2b: deactivated service is not resurrected into a later cycle ---
# Both svc-alpha and svc-beta COMPLETED in run #1, and svc-alpha is now
# is_active=0. Per the per-service success gate, neither completed service
# may re-run this session, so NO follow-on run opens — and the deactivated
# svc-alpha is certainly never re-dispatched. (Within-run exclusion of a
# deactivated service is covered separately by C2c.)
sleep 8

NEW_RUNS=$($DB_QUERY "SELECT COUNT(*) FROM runs WHERE id > $R1;")
assert_eq "C2b: no follow-on run opens after both services completed this session" "0" "$NEW_RUNS"

ALPHA_JOBS=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$ALPHA_ID;")
assert_eq "C2b: deactivated svc-alpha not re-dispatched (single run #1 row only)" "1" "$ALPHA_JOBS"

BETA_JOBS=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$BETA_ID;")
assert_eq "C2b: completed svc-beta not re-dispatched this session" "1" "$BETA_JOBS"

stop_scheduler
cleanup_test_db "$TEST_DB"
TEST_DB=""
rm -f "$TMP_LOG"
TMP_LOG=""

# ---------------------------------------------------------------------------
# C2c — Service deactivated AFTER run open but BEFORE its dispatch turn.
# Snapshot counts it; NEXT_SERVICE_ID filters it out when its turn comes.
# Natural-close gate allows the run to close COMPLETED even though the
# snapshotted count exceeds the actual number of jobs rows in the run.
# ---------------------------------------------------------------------------
echo "--- C2c: deactivate-before-dispatch in the same cycle ---"
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# Three services, all initially active. MAX_CONCURRENT=1 so svc-gamma will
# not be dispatched until svc-alpha and svc-beta finish (alphabetical
# ordering inside the NEXT_SERVICE_ID query). That gives us a window of a
# few seconds (sleep 2 * 2 jobs ≈ 4s) to deactivate svc-gamma before its turn.
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-alpha', 1, 1),
    ('svc-beta',  1, 1),
    ('svc-gamma', 1, 1);"

export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=1
export JOB_IDLE_TIMEOUT=0
export KILL_GRACE_SEC=1

TMP_LOG=$(mktemp /tmp/test_service_deactivated_mid_cycle.XXXXXX.log)

timeout 90s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

ALPHA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-alpha';")
BETA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-beta';")
GAMMA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-gamma';")

# Wait until the run is open AND svc-alpha is RUNNING. At this point the
# snapshot of total_services should be 3 (all initially active).
if ! poll_db "SELECT COUNT(*) FROM jobs WHERE service_id=$ALPHA_ID AND status='RUNNING' AND run_id=(SELECT id FROM runs WHERE status='RUNNING');" "1" 30 "svc-alpha RUNNING in open run"; then
    fail "C2c: svc-alpha never RUNNING within 30s"
    echo "--- scheduler log ---"; tail -40 "$TMP_LOG"
    print_test_summary
    exit 1
fi

R1C=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;")
SNAPSHOT_R1C=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$R1C;")
assert_eq "C2c: run #$R1C total_services snapshot = 3 (all three active at open)" "3" "$SNAPSHOT_R1C"

# Immediately deactivate svc-gamma — before its turn (svc-alpha and svc-beta
# need to dispatch first under MAX_CONCURRENT=1).
$DB_QUERY "UPDATE services SET is_active=0 WHERE container_name='svc-gamma';"
pass "C2c: deactivated svc-gamma while svc-alpha was RUNNING and svc-gamma had no row yet"

# Sanity: svc-gamma should still have no jobs row at this point.
GAMMA_PRE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$GAMMA_ID;")
assert_eq "C2c: svc-gamma has no jobs row at deactivation time" "0" "$GAMMA_PRE"

# Wait for svc-alpha + svc-beta to complete in run #1.
if poll_db "SELECT status FROM jobs WHERE service_id=$ALPHA_ID AND run_id=$R1C;" "COMPLETED" 20 "svc-alpha COMPLETED"; then
    pass "C2c: svc-alpha COMPLETED in run #$R1C"
else
    fail "C2c: svc-alpha did not COMPLETE in run #$R1C"
fi
if poll_db "SELECT status FROM jobs WHERE service_id=$BETA_ID AND run_id=$R1C;" "COMPLETED" 25 "svc-beta COMPLETED"; then
    pass "C2c: svc-beta COMPLETED in run #$R1C"
else
    fail "C2c: svc-beta did not COMPLETE in run #$R1C"
fi

# Critical assertion: even though run #1's snapshot expected 3 services, the
# natural-close gate (run_can_close_naturally) only requires that no jobs
# are RUNNING. NEXT_SERVICE_ID returns empty for run #1 (svc-gamma is
# is_active=0 and so filtered out; svc-alpha and svc-beta have rows). So
# the run can close COMPLETED.
if poll_db "SELECT status FROM runs WHERE id=$R1C;" "COMPLETED" 25 "run #$R1C closes COMPLETED"; then
    pass "C2c: run #$R1C closed COMPLETED (natural-close gate allows close once eligible services have rows)"
else
    fail "C2c: run #$R1C did not close COMPLETED — natural-close gate may be over-strict on snapshot"
fi

# svc-gamma must have NO row in run #1.
GAMMA_IN_R1C=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$GAMMA_ID AND run_id=$R1C;")
assert_eq "C2c: deactivated-before-dispatch svc-gamma has no row in run #$R1C" "0" "$GAMMA_IN_R1C"

# Snapshot must remain at the open-time value (3) — the snapshot is taken
# once at open and is not retroactively rewritten when services flip.
SNAPSHOT_R1C_AFTER=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$R1C;")
assert_eq "C2c: total_services snapshot for run #$R1C stays at 3 (not retroactively rewritten)" "3" "$SNAPSHOT_R1C_AFTER"

# Aggregate counts should reflect only the actually-recorded rows (2).
R1C_COMPLETED=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$R1C;")
assert_eq "C2c: run #$R1C completed_count = 2 (only actual jobs rows aggregated)" "2" "$R1C_COMPLETED"

stop_scheduler
cleanup_test_db "$TEST_DB"
TEST_DB=""
rm -f "$TMP_LOG"
TMP_LOG=""

# ---------------------------------------------------------------------------
# C2d — Reactivation symmetry: deactivate then reactivate before dispatch.
# Service is then dispatched normally in the same run.
# ---------------------------------------------------------------------------
echo "--- C2d: reactivation symmetry ---"
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-alpha', 1, 1),
    ('svc-beta',  1, 1),
    ('svc-gamma', 1, 1);"

export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=1
export JOB_IDLE_TIMEOUT=0
export KILL_GRACE_SEC=1

TMP_LOG=$(mktemp /tmp/test_service_deactivated_mid_cycle.XXXXXX.log)

timeout 90s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

ALPHA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-alpha';")
GAMMA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-gamma';")

if ! poll_db "SELECT COUNT(*) FROM jobs WHERE service_id=$ALPHA_ID AND status='RUNNING' AND run_id=(SELECT id FROM runs WHERE status='RUNNING');" "1" 30 "svc-alpha RUNNING (C2d)"; then
    fail "C2d: svc-alpha never RUNNING within 30s"
    echo "--- scheduler log ---"; tail -40 "$TMP_LOG"
    print_test_summary
    exit 1
fi

R1D=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;")

# Deactivate svc-gamma, then immediately reactivate it. End-state is
# is_active=1 before its dispatch turn arrives.
$DB_QUERY "UPDATE services SET is_active=0 WHERE container_name='svc-gamma';"
$DB_QUERY "UPDATE services SET is_active=1 WHERE container_name='svc-gamma';"
pass "C2d: svc-gamma flipped 1->0->1 before its dispatch turn"

# svc-gamma should be dispatched in run #1 (re-eligible since is_active=1
# at the moment NEXT_SERVICE_ID picks it).
if poll_db "SELECT COUNT(*) FROM jobs WHERE service_id=$GAMMA_ID AND run_id=$R1D;" "1" 30 "svc-gamma dispatched in run #$R1D"; then
    pass "C2d: svc-gamma reactivated in time and got a row in run #$R1D"
else
    fail "C2d: svc-gamma did not get a row in run #$R1D"
fi

# Run closes COMPLETED with all three services.
if poll_db "SELECT status FROM runs WHERE id=$R1D;" "COMPLETED" 40 "run #$R1D closes COMPLETED"; then
    pass "C2d: run #$R1D closed COMPLETED with all three services"
else
    fail "C2d: run #$R1D did not close COMPLETED"
fi

R1D_DISTINCT=$($DB_QUERY "SELECT COUNT(DISTINCT service_id) FROM jobs WHERE run_id=$R1D;")
assert_eq "C2d: 3 distinct services in run #$R1D" "3" "$R1D_DISTINCT"

stop_scheduler

# Diagnostic dump on failure
if [ "$FAIL" -gt 0 ]; then
    echo "--- scheduler log (last 80 lines) ---"
    tail -80 "$TMP_LOG"
    echo "--- runs ---"
    $DB_QUERY "SELECT id,status,triggered_by,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
    echo "--- jobs ---"
    $DB_QUERY "SELECT id,service_id,run_id,status,start_time,end_time,message FROM jobs;"
    echo "--- services ---"
    $DB_QUERY "SELECT id,container_name,is_active FROM services;"
fi

print_test_summary
