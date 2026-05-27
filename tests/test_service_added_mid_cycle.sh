#!/bin/bash
# tests/test_service_added_mid_cycle.sh
# Case C1 — Service added mid-cycle gets picked up in the next iteration.
#
# Operator scenario:
#   Scheduler is already running inside its window. The operator INSERTs a new
#   active service while a run is in progress. The next loop iteration's
#   NEXT_SERVICE_ID query (the LEFT JOIN against services WHERE is_active=1
#   AND NOT EXISTS row in this run) should immediately surface the new
#   service, dispatch it, and the resulting jobs row participates in run #1.
#
# Decision pinned by this test (snapshot semantics):
#   runs.total_services is taken at run_open_if_none time from
#   (SELECT COUNT(*) FROM services WHERE is_active=1). When a service is
#   added mid-cycle, the snapshot is NOT updated retroactively — the run
#   header may legitimately show "3/2 done" because the third service was
#   dispatched AFTER the run was conceived. completed_count, however, IS
#   accurate (it is aggregated at close time from actual jobs rows). This
#   asymmetry is intentional: total_services records the operator's intent
#   at window entry; completed_count records what actually ran.
#
# Sub-cases:
#   C1a — Newly active service added mid-cycle dispatches in the SAME run,
#         completes, and run closes cleanly. total_services snapshot stays at
#         the original value. completed_count reflects the actual total.
#   C1b — Newly INACTIVE (is_active=0) service added mid-cycle is ignored;
#         never gets a row in run #1.
#   C1c — Mid-cycle-added service survives across cycles: it participates
#         in run #2 the same as the originally-seeded services.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== Test: service added mid-cycle (C1) ==="

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

# ---------------------------------------------------------------------------
# C1a — Active service added mid-cycle gets dispatched and completes in run #1
# ---------------------------------------------------------------------------
echo "--- C1a: active service added mid-cycle ---"
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-alpha', 1, 1),
    ('svc-beta',  1, 1);"

export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=3
export JOB_IDLE_TIMEOUT=0
export KILL_GRACE_SEC=1

TMP_LOG=$(mktemp /tmp/test_service_added_mid_cycle.XXXXXX.log)

timeout 60s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

# Wait until the scheduler has opened run #1 AND dispatched at least one
# service (so we know we're inside the dispatch phase of an in-progress run).
# This is the "mid-cycle" window: the run is RUNNING, at least one job has
# been recorded, and the loop is still iterating through the remaining
# services / waiting for in-flight ones.
if ! poll_db "SELECT COUNT(*) FROM jobs WHERE run_id=(SELECT id FROM runs WHERE status='RUNNING');" "1" 30 "first service dispatched in open run"; then
    fail "C1a: scheduler did not dispatch the first service within 30s"
    echo "--- scheduler log ---"; tail -40 "$TMP_LOG"
    print_test_summary
    exit 1
fi

R1=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;")
[ -n "$R1" ] && pass "C1a: run #$R1 opened and first dispatch observed" \
              || fail "C1a: no RUNNING run after first dispatch"

# Capture the snapshot BEFORE inserting the third service.
SNAPSHOT_BEFORE=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$R1;")
assert_eq "C1a: total_services snapshot at open = 2" "2" "$SNAPSHOT_BEFORE"

# Operator adds a new active service WHILE the scheduler loop is alive and
# the run is still in progress.
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-gamma', 1, 1);"

# Within a few iterations (CHECK_INTERVAL=1, dummy task = sleep 2), svc-gamma
# should be dispatched against the SAME run #1.
GAMMA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-gamma';")

if poll_db "SELECT COUNT(*) FROM jobs WHERE service_id=$GAMMA_ID AND run_id=$R1;" "1" 15 "svc-gamma gets a row in run #$R1"; then
    pass "C1a: svc-gamma dispatched in the same run #$R1 (no artificial deferral to next cycle)"
else
    fail "C1a: svc-gamma was not dispatched into run #$R1 within 15s"
fi

# It eventually completes.
if poll_db "SELECT status FROM jobs WHERE service_id=$GAMMA_ID AND run_id=$R1;" "COMPLETED" 15 "svc-gamma completes"; then
    pass "C1a: svc-gamma reached COMPLETED in run #$R1"
else
    fail "C1a: svc-gamma did not reach COMPLETED in run #$R1"
fi

# Run #1 closes naturally — every service (including the newly-added one)
# has a row in the run, and nothing is RUNNING. The natural-completion path
# fires and the run flips to COMPLETED.
if poll_db "SELECT status FROM runs WHERE id=$R1;" "COMPLETED" 15 "run #$R1 closes COMPLETED with 3 services in it"; then
    pass "C1a: run #$R1 closed COMPLETED after the mid-cycle-added service finished"
else
    fail "C1a: run #$R1 did not close COMPLETED in time"
fi

# Snapshot semantics pinned: total_services must NOT have changed.
SNAPSHOT_AFTER=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$R1;")
assert_eq "C1a: total_services snapshot stays at 2 (NOT retroactively updated to 3)" "2" "$SNAPSHOT_AFTER"

# completed_count is computed at close time from actual jobs rows — it
# reflects the real total (3) even though total_services snapshot is 2.
COMPLETED_COUNT=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$R1;")
assert_eq "C1a: completed_count reflects actual finished jobs (3, not snapshot 2)" "3" "$COMPLETED_COUNT"

# Every service in the run is distinct (no duplicate dispatch from the
# resize-of-services-set causing svc-alpha or svc-beta to be re-eligible).
DISTINCT_IN_RUN=$($DB_QUERY "SELECT COUNT(DISTINCT service_id) FROM jobs WHERE run_id=$R1;")
assert_eq "C1a: exactly 3 distinct services in run #$R1" "3" "$DISTINCT_IN_RUN"

JOB_COUNT_IN_RUN=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$R1;")
assert_eq "C1a: no duplicate jobs in run #$R1 (one row per service)" "3" "$JOB_COUNT_IN_RUN"

# ---------------------------------------------------------------------------
# C1c — The mid-cycle-added service participates in the NEXT cycle too.
# (Done before tearing the scheduler down so we exercise the same long-lived
# loop that observed the mid-cycle INSERT.)
# ---------------------------------------------------------------------------
echo "--- C1c: svc-gamma participates in run #2 ---"

# Wait for the scheduler to open a fresh run after run #1 closed COMPLETED.
# Because the window is wide open (00:00-23:59), the very next iteration
# will call run_open_if_none and create R2.
DEADLINE=$(( $(date +%s) + 20 ))
R2=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    R2=$($DB_QUERY "SELECT id FROM runs WHERE id > $R1 AND status IN ('RUNNING','COMPLETED') ORDER BY id ASC LIMIT 1;")
    [ -n "$R2" ] && break
    sleep 1
done

if [ -n "$R2" ]; then
    pass "C1c: run #$R2 opened cleanly after run #$R1 closed"
else
    fail "C1c: no run #2 opened within 20s after run #1 closed"
fi

# svc-gamma must get a row in run #2 (re-eligibility under per-run dedup).
if [ -n "$R2" ] && poll_db "SELECT COUNT(*) FROM jobs WHERE service_id=$GAMMA_ID AND run_id=$R2;" "1" 25 "svc-gamma participates in run #$R2"; then
    pass "C1c: svc-gamma got a row in run #$R2 (mid-cycle add survives across cycles)"
else
    fail "C1c: svc-gamma did not get a row in run #$R2"
fi

# And total_services in run #2 reflects the current active count (3).
if [ -n "$R2" ]; then
    R2_TOTAL=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$R2;")
    assert_eq "C1c: run #2 total_services snapshot reflects current count (3)" "3" "$R2_TOTAL"
fi

# Stop the scheduler.
if kill -0 "$SCHED_PID" 2>/dev/null; then
    kill -TERM "$SCHED_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHED_PID" 2>/dev/null || break
        sleep 1
    done
    wait "$SCHED_PID" 2>/dev/null
fi
SCHED_PID=""

cleanup_test_db "$TEST_DB"
TEST_DB=""

# ---------------------------------------------------------------------------
# C1b — Inactive service added mid-cycle is ignored (no row in run #1).
# Fresh DB so the assertions are not entangled with C1a's runs.
# ---------------------------------------------------------------------------
echo "--- C1b: inactive service added mid-cycle is ignored ---"
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-alpha', 1, 1),
    ('svc-beta',  1, 1);"

TMP_LOG=$(mktemp /tmp/test_service_added_mid_cycle.XXXXXX.log)

timeout 30s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

# Wait until both initial services have been dispatched (any terminal state).
if ! poll_db "SELECT COUNT(*) FROM jobs WHERE run_id=(SELECT id FROM runs WHERE status='RUNNING');" "2" 25 "both initial services dispatched in open run"; then
    fail "C1b: initial dispatch did not happen in time"
    echo "--- scheduler log ---"; tail -40 "$TMP_LOG"
    print_test_summary
    exit 1
fi

R1B=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;")

# Insert an INACTIVE 4th service. The dedup query has WHERE s.is_active=1,
# so this row must never become eligible.
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-delta', 1, 0);"
DELTA_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-delta';")

# Wait through several scheduler iterations to give a hypothetical buggy
# dispatch time to fire. Then assert delta has NO row in this run.
sleep 5
DELTA_ROWS=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$DELTA_ID AND run_id=$R1B;")
assert_eq "C1b: inactive svc-delta has no row in run #$R1B" "0" "$DELTA_ROWS"

# And it has NO row anywhere (not even in a hypothetical follow-on run).
DELTA_ANY=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$DELTA_ID;")
assert_eq "C1b: inactive svc-delta has no jobs row at all" "0" "$DELTA_ANY"

# Stop the scheduler.
if kill -0 "$SCHED_PID" 2>/dev/null; then
    kill -TERM "$SCHED_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHED_PID" 2>/dev/null || break
        sleep 1
    done
    wait "$SCHED_PID" 2>/dev/null
fi
SCHED_PID=""

# Diagnostic dump on failure
if [ "$FAIL" -gt 0 ]; then
    echo "--- scheduler log (last 60 lines) ---"
    tail -60 "$TMP_LOG"
    echo "--- runs ---"
    $DB_QUERY "SELECT id,status,triggered_by,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
    echo "--- jobs ---"
    $DB_QUERY "SELECT id,service_id,run_id,status,start_time,end_time FROM jobs;"
    echo "--- services ---"
    $DB_QUERY "SELECT id,container_name,is_active FROM services;"
fi

print_test_summary
