#!/bin/bash
# tests/test_resource_throttle_release.sh
# Case D1 — Resource threshold exceeded -> dispatch pauses -> recovers -> resumes.
#
# Operator scenario:
#   The host is under load. CPU/MEM/IOWAIT spikes above thresholds. The
#   scheduler must NOT dispatch new jobs while the gate trips. Once metrics
#   recede, dispatch resumes on the next iteration.
#
# Why two phases:
#   The scheduler re-reads RESOURCE_THRESHOLD each iteration via
#   `THRESHOLD=${RESOURCE_THRESHOLD:-70}` (scheduler.sh ~L840), but it reads
#   from the bash variable inherited at fork — a parent process mutating its
#   own env after-the-fact does NOT propagate to the running child. The
#   cleanest way to exercise both states deterministically is two sequential
#   invocations sharing the same DB:
#     Phase 1 — RESOURCE_THRESHOLD=0 (impossible threshold). CPU/MEM are
#               almost always > 0 on a host running tests, so check_thresholds
#               trips on every iteration. We assert zero jobs rows over ~5s,
#               assert the "Resource limit exceeded:" log fires with a
#               populated LAST_BYPASS_REASON, and confirm no leaked state.
#     Phase 2 — RESOURCE_THRESHOLD=100 (always-passes). Dispatch must resume
#               within a few iterations and rows appear in the SAME DB.
#
# Contract pinned:
#   1. Throttled scheduler logs "Resource limit exceeded: <reason>" every iter
#      and writes zero rows to jobs over the throttled window.
#   2. DB state across the throttled window is byte-identical to the seed
#      state (no spurious INSERTs, no orphaned PIDs).
#   3. With threshold restored to 100, dispatch resumes within ~3 iterations.
#   4. No leaked BG_PIDS state survives Phase 1 (verified by Phase 2 succeeding
#      cleanly on the same DB).
#   5. LAST_BYPASS_REASON is non-empty and surfaces in the log line.
#
# Notes on edges intentionally NOT covered:
#   - "in-flight jobs continue regardless of threshold" — would require a
#     dynamic threshold flip mid-iteration, which the env-read mechanism
#     does not support. Out of scope for D1.
#   - IOWAIT/SWAP/INODE are independent specialized thresholds. We pin
#     them above any plausible value during Phase 2 so the recovery path
#     cannot be derailed by a transient IO blip on the test host.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== Test: resource threshold throttle + release (D1) ==="

PASS=0
FAIL=0
pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

SCHED_PID=""
TMP_LOG_P1=""
TMP_LOG_P2=""
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
    [ -n "$TMP_LOG_P1" ] && rm -f "$TMP_LOG_P1"
    [ -n "$TMP_LOG_P2" ] && rm -f "$TMP_LOG_P2"
    [ -n "$TEST_DB" ] && cleanup_test_db "$TEST_DB"
}
trap cleanup EXIT

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

# Wait until a substring appears in the given log file (or timeout).
wait_for_log() {
    local FILE="$1"
    local NEEDLE="$2"
    local TIMEOUT="$3"
    local DEADLINE=$(( $(date +%s) + TIMEOUT ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        if [ -f "$FILE" ] && grep -q -- "$NEEDLE" "$FILE" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Stop the currently tracked scheduler and wait. SIGTERM, grace, then SIGKILL.
stop_sched() {
    if [ -n "$SCHED_PID" ] && kill -0 "$SCHED_PID" 2>/dev/null; then
        kill -TERM "$SCHED_PID" 2>/dev/null
        for _ in $(seq 1 10); do
            kill -0 "$SCHED_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SCHED_PID" 2>/dev/null
        wait "$SCHED_PID" 2>/dev/null
    fi
    SCHED_PID=""
}

# ---------------------------------------------------------------------------
# Seed: two services, shared DB across both phases.
# ---------------------------------------------------------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-alpha', 1, 1),
    ('svc-beta',  1, 1);"

# Shared scheduler env. Specialized thresholds pinned high so an IO blip on
# the test host can never trip them during the recovery phase.
export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1
export MAX_CONCURRENT_JOBS=10
export KILL_GRACE_SEC=1
export IOWAIT_THRESHOLD=100
export SWAP_THRESHOLD=100
export INODE_THRESHOLD=100
export JOB_IDLE_TIMEOUT=0

# ---------------------------------------------------------------------------
# Phase 1 — RESOURCE_THRESHOLD=0: gate must trip every iteration.
# ---------------------------------------------------------------------------
echo "--- Phase 1: RESOURCE_THRESHOLD=0 -> dispatch must be throttled ---"

TMP_LOG_P1=$(mktemp /tmp/test_resource_throttle_p1.XXXXXX.log)

RESOURCE_THRESHOLD=0 timeout 30s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG_P1" 2>&1 &
SCHED_PID=$!

# Wait for the gate-trip log line. If this never appears within 20s, either
# the scheduler is not running, or the gate is silently passing.
if wait_for_log "$TMP_LOG_P1" "Resource limit exceeded:" 20; then
    pass "Phase 1: 'Resource limit exceeded' log line observed"
else
    fail "Phase 1: never saw 'Resource limit exceeded' in scheduler log within 20s"
    echo "--- Phase 1 log (tail) ---"; tail -40 "$TMP_LOG_P1"
fi

# Let the loop iterate for ~5s under the throttled threshold so we can
# observe MULTIPLE gate trips (not just one).
sleep 5

# Stop Phase 1 before asserting — gives the loop a clean boundary so we are
# not racing a half-finished iteration.
stop_sched

# Assert the gate-trip line fired multiple times (proves repeated iterations
# all blocked, not a single fluke).
THROTTLE_COUNT=$(grep -c "Resource limit exceeded:" "$TMP_LOG_P1" 2>/dev/null || echo 0)
THROTTLE_COUNT=${THROTTLE_COUNT//[^0-9]/}
if [ "${THROTTLE_COUNT:-0}" -ge 2 ]; then
    pass "Phase 1: gate tripped $THROTTLE_COUNT times (>=2)"
else
    fail "Phase 1: gate tripped only ${THROTTLE_COUNT:-0} times (expected >=2)"
fi

# LAST_BYPASS_REASON is surfaced in the log line, not via the DB. Verify that
# at least one occurrence has a non-empty reason after the colon (i.e. the
# pattern is "Resource limit exceeded: <something non-empty>. Container ...").
# Empty reason would look like "Resource limit exceeded: . Container ...".
if grep -E "Resource limit exceeded: .+\. Container '" "$TMP_LOG_P1" >/dev/null 2>&1; then
    pass "Phase 1: LAST_BYPASS_REASON populated and surfaced in log"
else
    fail "Phase 1: LAST_BYPASS_REASON appears empty in log line"
    echo "--- gate-trip lines ---"
    grep "Resource limit exceeded" "$TMP_LOG_P1" | head -5
fi

# CONTRACT 1+2: zero jobs rows, no orphan PIDs.
JOBS_P1=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
assert_eq "Phase 1: zero jobs rows created while throttled" "0" "$JOBS_P1"

# Defensive: even RUNNING/ORPHANED status filters should be zero (no row at all).
RUNNING_P1=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status IN ('RUNNING','ORPHANED');")
assert_eq "Phase 1: no RUNNING/ORPHANED jobs" "0" "$RUNNING_P1"

# Sanity: services table unchanged.
SVC_P1=$($DB_QUERY "SELECT COUNT(*) FROM services WHERE is_active=1;")
assert_eq "Phase 1: services table intact (2 active)" "2" "$SVC_P1"

# A run row MAY have been opened (the gate-trip is *after* run_open_if_none);
# that is allowed by the contract — the gate only blocks per-iteration
# dispatch, not run-lifecycle bookkeeping. Just record what we observe so
# Phase 2's assertions are anchored correctly.
RUN_AFTER_P1=$($DB_QUERY "SELECT IFNULL(MAX(id),0) FROM runs;")
echo "[Info] Phase 1: max run id after throttled window = $RUN_AFTER_P1"

# ---------------------------------------------------------------------------
# Phase 2 — RESOURCE_THRESHOLD=100: gate must pass; dispatch resumes.
# ---------------------------------------------------------------------------
echo "--- Phase 2: RESOURCE_THRESHOLD=100 -> dispatch must resume ---"

TMP_LOG_P2=$(mktemp /tmp/test_resource_throttle_p2.XXXXXX.log)

RESOURCE_THRESHOLD=100 timeout 60s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG_P2" 2>&1 &
SCHED_PID=$!

# CONTRACT 3: dispatch resumes. With CHECK_INTERVAL=1 and 2 services, both
# rows should land within ~10s comfortably. Give a generous timeout to absorb
# vmstat sampling cost (each gate check runs vmstat 1 2 which costs ~1s).
if poll_db "SELECT COUNT(*) FROM jobs;" "2" 30 "both services dispatched after recovery"; then
    pass "Phase 2: both services dispatched after threshold restored"
else
    fail "Phase 2: dispatch did not resume within 30s"
    echo "--- Phase 2 log (tail) ---"; tail -40 "$TMP_LOG_P2"
fi

# They must reach COMPLETED (dummy task is `sleep 2`).
if poll_db "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED';" "2" 30 "both jobs completed"; then
    pass "Phase 2: both jobs reached COMPLETED"
else
    fail "Phase 2: jobs did not complete within 30s"
fi

# CONTRACT 4: no leaked state — every job has a valid pid and end_time set.
LEAKED=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED' AND (pid IS NULL OR end_time IS NULL);")
assert_eq "Phase 2: no leaked PIDs / missing end_time on COMPLETED jobs" "0" "$LEAKED"

# No ORPHANED rows from Phase 1's startup cleanup attaching to Phase 2.
ORPHANED=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='ORPHANED';")
assert_eq "Phase 2: no ORPHANED jobs leaked from Phase 1" "0" "$ORPHANED"

# Sanity: jobs all belong to a single run (either the run row that may have
# been opened in Phase 1, or a fresh one Phase 2 opened — both are valid;
# what matters is they all sit in ONE run, not scattered across orphans).
DISTINCT_RUNS=$($DB_QUERY "SELECT COUNT(DISTINCT run_id) FROM jobs;")
assert_eq "Phase 2: all completed jobs share a single run" "1" "$DISTINCT_RUNS"

# Stop Phase 2.
stop_sched

# ---------------------------------------------------------------------------
# Diagnostics on failure
# ---------------------------------------------------------------------------
if [ "$FAIL" -gt 0 ]; then
    echo "--- Phase 1 log (last 60 lines) ---"
    [ -f "$TMP_LOG_P1" ] && tail -60 "$TMP_LOG_P1"
    echo "--- Phase 2 log (last 60 lines) ---"
    [ -f "$TMP_LOG_P2" ] && tail -60 "$TMP_LOG_P2"
    echo "--- runs ---"
    $DB_QUERY "SELECT id,status,triggered_by,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
    echo "--- jobs ---"
    $DB_QUERY "SELECT id,service_id,run_id,status,pid,start_time,end_time FROM jobs;"
fi

print_test_summary
