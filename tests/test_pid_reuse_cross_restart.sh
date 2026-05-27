#!/bin/bash
# tests/test_pid_reuse_cross_restart.sh
# Case A5 — PID reuse defense across scheduler restart.
#
# Operator scenario:
#   Scheduler dispatched svc-X at PID=12345 with pid_starttime=999 yesterday.
#   Scheduler hard-crashed. Hours pass. Linux recycles PID=12345 to an
#   unrelated process (another user's bash, sshd, anything). Operator
#   restarts the scheduler.
#
#   Recovery sees jobs.status='RUNNING' with pid=12345. It MUST NOT trust
#   the PID alone. It MUST call verify_pid_identity, comparing the recorded
#   pid_starttime against /proc/12345/stat field 22. On mismatch:
#     - mark the row ORPHANED, process_state='UNKNOWN'
#     - NEVER invoke kill on the recycled PID
#
#   Same defense applies to the stale-auto-expire path: the SELECT picks
#   up jobs older than 2× JOB_TIMEOUT_SEC; if the recorded PID now points
#   at an unrelated process, kill_process_tree must refuse via its own
#   re-verify (TOCTOU narrow).
#
# This test covers three sub-cases:
#   A5a: recovery + recycled PID -> ORPHANED, no kill issued, innocent alive
#   A5b: stale-expire + recycled PID -> TIMEOUT + kill refused, innocent alive
#   A5c: recovery + matching identity -> restored, then SIGTERM the scheduler
#        and confirm kill_process_tree DID terminate the legitimate process
#
# Critical safety note: this test spawns "innocent" processes the runner
# owns. If the scheduler's defense ever regresses, those PIDs would be
# SIGKILLed. Cleanup must defensively kill its OWN tracked PIDs only
# (never via pkill on a name), and must run even if the test fails mid-flight.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"
# Source monitor.sh to expose get_pid_starttime / verify_pid_identity to the
# test runner — same helpers the scheduler uses for identity checks.
source "$PROJECT_ROOT/bin/monitor.sh" >/dev/null 2>&1
BIN_DIR="$PROJECT_ROOT/bin"

echo "=== Test: A5 — PID reuse defense across scheduler restart ==="

PASS=0
FAIL=0
pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

# Shared cleanup state. Updated in-place by each sub-case.
INNOCENT_PID=""
SUBSHELL_PID=""
SCHEDULER_PID=""
TMP_LOG=""
TEST_DB=""

cleanup_all() {
    # Kill scheduler first if still alive — it could otherwise stall on its
    # 10s KILL_GRACE_SEC default while we tear down.
    if [ -n "$SCHEDULER_PID" ] && kill -0 "$SCHEDULER_PID" 2>/dev/null; then
        kill -KILL "$SCHEDULER_PID" 2>/dev/null
        wait "$SCHEDULER_PID" 2>/dev/null
    fi
    # Kill OUR tracked innocent / subshell PIDs only — never pkill by name.
    # If the scheduler regressed and already killed them, kill -KILL is a no-op.
    [ -n "$INNOCENT_PID" ] && kill -KILL "$INNOCENT_PID" 2>/dev/null
    [ -n "$SUBSHELL_PID" ] && kill -KILL "$SUBSHELL_PID" 2>/dev/null
    wait 2>/dev/null
    [ -n "$TMP_LOG" ] && rm -f "$TMP_LOG"
    [ -n "$TEST_DB" ] && cleanup_test_db "$TEST_DB"
}
trap cleanup_all EXIT

# Shared scheduler env. Always-open window so recovery + stale-expire happen
# inside the active branch (the inactive branch sleeps and never sweeps).
export START_TIME=00:00
export END_TIME=23:59
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=200
export MAX_CONCURRENT_JOBS=3
export JOB_IDLE_TIMEOUT=0
export KILL_GRACE_SEC=1
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"

# Wait for a scheduler-log predicate to become true. Polls $TMP_LOG up to
# $1 seconds for the regex $2. Returns 0 on hit, 1 on timeout.
wait_for_log() {
    local LIMIT=$1
    local PATTERN=$2
    local DEADLINE=$(( SECONDS + LIMIT ))
    while [ $SECONDS -lt $DEADLINE ]; do
        if [ -s "$TMP_LOG" ] && grep -qE "$PATTERN" "$TMP_LOG"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ===========================================================================
# A5a: Recovery + recycled PID -> ORPHANED, no kill issued
# ===========================================================================
run_a5a() {
    echo ""
    echo "=============================="
    echo "[Sub-case] A5a recovery + recycled PID"
    echo "=============================="

    TEST_DB=$(setup_test_db)
    export DB_PATH="$TEST_DB"
    "$PROJECT_ROOT/bin/migrate_db.sh" >/dev/null 2>&1

    # Spawn an innocent process owned by this test. The DB will claim a job
    # was running at this PID with a DIFFERENT starttime — that is the
    # simulated cross-restart PID-recycle event.
    sleep 600 &
    INNOCENT_PID=$!
    sleep 0.1
    local REAL_START FAKE_START
    REAL_START=$(get_pid_starttime "$INNOCENT_PID")
    if [ -z "$REAL_START" ]; then
        fail "A5a/setup: could not capture INNOCENT_PID starttime"
        kill -KILL "$INNOCENT_PID" 2>/dev/null; wait "$INNOCENT_PID" 2>/dev/null
        INNOCENT_PID=""
        cleanup_test_db "$TEST_DB"; TEST_DB=""
        return 1
    fi
    FAKE_START=$(( REAL_START + 99999 ))   # guaranteed mismatch

    $DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-a5a', 1, 1);"
    local SVC_ID
    SVC_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-a5a';")
    # start_time = now so stale-expire (2× JOB_TIMEOUT_SEC) cannot fire and
    # cloud the recovery-path observation.
    $DB_QUERY "INSERT INTO jobs (service_id, status, pid, pid_starttime, start_time)
               VALUES ($SVC_ID, 'RUNNING', $INNOCENT_PID, $FAKE_START, datetime('now','localtime'));"
    local JOB_ID
    JOB_ID=$($DB_QUERY "SELECT id FROM jobs WHERE service_id=$SVC_ID;")

    TMP_LOG=$(mktemp "/tmp/test_a5a_XXXXXX.log")
    # JOB_TIMEOUT_SEC=300 so stale-expire (2× = 600s) cannot fire and convert
    # our ORPHANED row to TIMEOUT during the 5s observation window.
    JOB_TIMEOUT_SEC=300 bash "$BIN_DIR/scheduler.sh" >"$TMP_LOG" 2>&1 &
    SCHEDULER_PID=$!

    # Recovery is the very first thing main loop does; 5s is generous.
    sleep 5

    kill -TERM "$SCHEDULER_PID" 2>/dev/null
    # Bounded wait — scheduler shutdown should be near-instant since no
    # BG_PIDS were restored.
    for _ in $(seq 1 10); do
        kill -0 "$SCHEDULER_PID" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$SCHEDULER_PID" 2>/dev/null
    wait "$SCHEDULER_PID" 2>/dev/null
    SCHEDULER_PID=""

    # --- Assertions -------------------------------------------------------

    # 1. Innocent process still alive (was NOT killed during recovery).
    if kill -0 "$INNOCENT_PID" 2>/dev/null; then
        pass "A5a/1: innocent PID $INNOCENT_PID still alive after recovery"
    else
        fail "A5a/1: innocent PID $INNOCENT_PID was killed by recovery (PID-reuse hazard regressed)"
    fi

    # 2. Starttime unchanged — proves the SAME process is alive, not a
    #    recycled instance the kernel handed back after a kill+spawn race.
    local POST_START
    POST_START=$(get_pid_starttime "$INNOCENT_PID")
    assert_eq "A5a/2: innocent PID starttime unchanged" "$REAL_START" "$POST_START"

    # 3. Seeded job row is ORPHANED with process_state='UNKNOWN'.
    local JOB_STATUS JOB_STATE
    JOB_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE id=$JOB_ID;")
    JOB_STATE=$($DB_QUERY "SELECT process_state FROM jobs WHERE id=$JOB_ID;")
    assert_eq "A5a/3a: seeded job status = ORPHANED" "ORPHANED" "$JOB_STATUS"
    assert_eq "A5a/3b: seeded job process_state = UNKNOWN" "UNKNOWN" "$JOB_STATE"

    # 4. Identity-check warning logged for this PID. The format is fixed in
    #    bin/scheduler.sh — anchor on it so a regression that downgrades the
    #    log line (or skips it entirely) trips the test.
    if grep -qE "PID $INNOCENT_PID for svc-a5a failed identity check" "$TMP_LOG"; then
        pass "A5a/4a: warning log present for failed identity check"
    else
        fail "A5a/4a: expected '[Warning] PID $INNOCENT_PID for svc-a5a failed identity check' in scheduler log"
    fi
    # 5. No "Restored job tracking" line for this PID — would prove the
    #    defense was bypassed and the recycled PID was admitted to BG_PIDS.
    if grep -qE "Restored job tracking .* PID=$INNOCENT_PID" "$TMP_LOG"; then
        fail "A5a/4b: 'Restored job tracking' log appeared for recycled PID $INNOCENT_PID (defense bypassed)"
    else
        pass "A5a/4b: no 'Restored job tracking' log for recycled PID $INNOCENT_PID"
    fi

    # Diagnostic dump on failure.
    if [ "$FAIL" -gt 0 ]; then
        echo "--- A5a scheduler log (tail 40) ---"
        tail -40 "$TMP_LOG" 2>/dev/null
        echo "--- A5a jobs ---"
        $DB_QUERY "SELECT id,service_id,status,pid,pid_starttime,process_state,message FROM jobs;"
    fi

    # Per-subcase teardown.
    kill -KILL "$INNOCENT_PID" 2>/dev/null
    wait "$INNOCENT_PID" 2>/dev/null
    INNOCENT_PID=""
    rm -f "$TMP_LOG"; TMP_LOG=""
    cleanup_test_db "$TEST_DB"; TEST_DB=""
}

# ===========================================================================
# A5b: Stale-expire + recycled PID -> TIMEOUT, kill refused, innocent alive
# ===========================================================================
run_a5b() {
    echo ""
    echo "=============================="
    echo "[Sub-case] A5b stale-expire + recycled PID"
    echo "=============================="

    TEST_DB=$(setup_test_db)
    export DB_PATH="$TEST_DB"
    "$PROJECT_ROOT/bin/migrate_db.sh" >/dev/null 2>&1

    sleep 600 &
    INNOCENT_PID=$!
    sleep 0.1
    local REAL_START FAKE_START
    REAL_START=$(get_pid_starttime "$INNOCENT_PID")
    if [ -z "$REAL_START" ]; then
        fail "A5b/setup: could not capture INNOCENT_PID starttime"
        kill -KILL "$INNOCENT_PID" 2>/dev/null; wait "$INNOCENT_PID" 2>/dev/null
        INNOCENT_PID=""
        cleanup_test_db "$TEST_DB"; TEST_DB=""
        return 1
    fi
    FAKE_START=$(( REAL_START + 99999 ))

    $DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-a5b', 1, 1);"
    local SVC_ID
    SVC_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-a5b';")
    # Use a tiny JOB_TIMEOUT_SEC so the stale window (2×) is small, and
    # backdate start_time well past it. The recovery path will ALSO see this
    # row, but recovery alone marks it ORPHANED — the stale loop then sees
    # status IN ('RUNNING','ORPHANED') and converts it to TIMEOUT.
    $DB_QUERY "INSERT INTO jobs (service_id, status, pid, pid_starttime, start_time)
               VALUES ($SVC_ID, 'RUNNING', $INNOCENT_PID, $FAKE_START, datetime('now','localtime','-25 hours'));"
    local JOB_ID
    JOB_ID=$($DB_QUERY "SELECT id FROM jobs WHERE service_id=$SVC_ID;")

    TMP_LOG=$(mktemp "/tmp/test_a5b_XXXXXX.log")
    # JOB_TIMEOUT_SEC=1 -> stale window = 2s. 25h backdate is comfortably stale.
    JOB_TIMEOUT_SEC=1 bash "$BIN_DIR/scheduler.sh" >"$TMP_LOG" 2>&1 &
    SCHEDULER_PID=$!

    # Wait for the stale-expire warning to appear (one loop iteration is
    # enough at CHECK_INTERVAL=1), capped at 8s to leave headroom for
    # scheduler startup + WAL contention.
    wait_for_log 8 "Skipped kill for svc-a5b: identity check failed" || true

    kill -TERM "$SCHEDULER_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHEDULER_PID" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$SCHEDULER_PID" 2>/dev/null
    wait "$SCHEDULER_PID" 2>/dev/null
    SCHEDULER_PID=""

    # --- Assertions -------------------------------------------------------

    # 1. Innocent process still alive.
    if kill -0 "$INNOCENT_PID" 2>/dev/null; then
        pass "A5b/1: innocent PID $INNOCENT_PID still alive after stale-expire"
    else
        fail "A5b/1: innocent PID $INNOCENT_PID was killed by stale-expire path"
    fi

    # 2. Starttime unchanged — same process, not a recycled instance.
    local POST_START
    POST_START=$(get_pid_starttime "$INNOCENT_PID")
    assert_eq "A5b/2: innocent PID starttime unchanged" "$REAL_START" "$POST_START"

    # 3. Job is TIMEOUT with 'Stale auto-expired' message.
    local JOB_STATUS JOB_MSG
    JOB_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE id=$JOB_ID;")
    JOB_MSG=$($DB_QUERY "SELECT message FROM jobs WHERE id=$JOB_ID;")
    assert_eq "A5b/3a: stale job status = TIMEOUT" "TIMEOUT" "$JOB_STATUS"
    assert_eq "A5b/3b: stale job message = 'Stale auto-expired'" "Stale auto-expired" "$JOB_MSG"

    # 4. Stale-expire warning line present — proves kill_process_tree's
    #    pre-SIGTERM identity check fired and the outer log call recorded it.
    if grep -qE "Skipped kill for svc-a5b: identity check failed \(PID=$INNOCENT_PID likely recycled\)" "$TMP_LOG"; then
        pass "A5b/4: stale-expire 'Skipped kill ... likely recycled' warning present"
    else
        fail "A5b/4: expected 'Skipped kill for svc-a5b: identity check failed (PID=$INNOCENT_PID likely recycled)' in log"
    fi

    if [ "$FAIL" -gt 0 ]; then
        echo "--- A5b scheduler log (tail 60) ---"
        tail -60 "$TMP_LOG" 2>/dev/null
        echo "--- A5b jobs ---"
        $DB_QUERY "SELECT id,service_id,status,pid,pid_starttime,process_state,message FROM jobs;"
    fi

    kill -KILL "$INNOCENT_PID" 2>/dev/null
    wait "$INNOCENT_PID" 2>/dev/null
    INNOCENT_PID=""
    rm -f "$TMP_LOG"; TMP_LOG=""
    cleanup_test_db "$TEST_DB"; TEST_DB=""
}

# ===========================================================================
# A5c: Recovery + MATCHING identity -> restored, SIGTERM scheduler, subshell dies
# ===========================================================================
run_a5c() {
    echo ""
    echo "=============================="
    echo "[Sub-case] A5c recovery + matching identity, shutdown kills subshell"
    echo "=============================="

    TEST_DB=$(setup_test_db)
    export DB_PATH="$TEST_DB"
    "$PROJECT_ROOT/bin/migrate_db.sh" >/dev/null 2>&1

    # Mirror the production dispatch shape: subshell that ignores SIGTERM/SIGINT
    # so naive kill -TERM is not enough — kill_process_tree must escalate to
    # SIGKILL after KILL_GRACE_SEC. This proves the kill path actually fired.
    ( trap '' SIGTERM SIGINT; sleep 600 ) &
    SUBSHELL_PID=$!
    sleep 0.1
    local REAL_START
    REAL_START=$(get_pid_starttime "$SUBSHELL_PID")
    if [ -z "$REAL_START" ]; then
        fail "A5c/setup: could not capture SUBSHELL_PID starttime"
        kill -KILL "$SUBSHELL_PID" 2>/dev/null; wait "$SUBSHELL_PID" 2>/dev/null
        SUBSHELL_PID=""
        cleanup_test_db "$TEST_DB"; TEST_DB=""
        return 1
    fi

    $DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-a5c', 1, 1);"
    local SVC_ID
    SVC_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-a5c';")
    # Seed with the CORRECT starttime — recovery must accept and restore it
    # into BG_PIDS. start_time is now so stale-expire never fires.
    $DB_QUERY "INSERT INTO jobs (service_id, status, pid, pid_starttime, start_time)
               VALUES ($SVC_ID, 'RUNNING', $SUBSHELL_PID, $REAL_START, datetime('now','localtime'));"

    TMP_LOG=$(mktemp "/tmp/test_a5c_XXXXXX.log")
    # JOB_TIMEOUT_SEC=300 -> 2× = 600s, stale-expire stays out of the way.
    JOB_TIMEOUT_SEC=300 bash "$BIN_DIR/scheduler.sh" >"$TMP_LOG" 2>&1 &
    SCHEDULER_PID=$!

    # Wait for the recovery log line confirming the seeded row was admitted.
    # grep -E: '(' is a grouping metachar, so anchor on the literal log shape
    # via a character class. The line in scheduler.sh ~line 683 is:
    #   "[Recovery] Restored job tracking for $JCNAME (PID=$JPID, starttime=$JSTART)"
    if wait_for_log 10 "Restored job tracking for svc-a5c [(]PID=$SUBSHELL_PID, starttime=$REAL_START[)]"; then
        pass "A5c/1: 'Restored job tracking' log present for matching-identity row"
    else
        fail "A5c/1: expected 'Restored job tracking for svc-a5c (PID=$SUBSHELL_PID, starttime=$REAL_START)' in log"
        echo "--- A5c scheduler log (tail 40) ---"; tail -40 "$TMP_LOG"
    fi

    # Send SIGTERM. cleanup_and_exit -> drain_bg_jobs -> kill_process_tree
    # on SUBSHELL_PID. SIGTERM is trapped by the subshell, so the SIGKILL
    # escalation (after KILL_GRACE_SEC=1) is what must do the actual kill.
    kill -TERM "$SCHEDULER_PID" 2>/dev/null

    # Bounded wait for scheduler exit. KILL_GRACE_SEC=1 + housekeeping
    # comfortably fits in 15s.
    local DEADLINE=$(( SECONDS + 15 ))
    while kill -0 "$SCHEDULER_PID" 2>/dev/null && [ $SECONDS -lt $DEADLINE ]; do
        sleep 1
    done
    if kill -0 "$SCHEDULER_PID" 2>/dev/null; then
        fail "A5c/2: scheduler did not exit within 15s of SIGTERM"
        kill -KILL "$SCHEDULER_PID" 2>/dev/null
        wait "$SCHEDULER_PID" 2>/dev/null
    else
        wait "$SCHEDULER_PID" 2>/dev/null
        pass "A5c/2: scheduler exited within 15s of SIGTERM"
    fi
    SCHEDULER_PID=""

    # Subshell must be gone. Wait briefly — the kernel processes SIGKILL
    # asynchronously; we just exited the scheduler so a tight poll may catch
    # the corpse mid-reap. Give the kernel up to 5s.
    local KILLED=0
    DEADLINE=$(( SECONDS + 5 ))
    while [ $SECONDS -lt $DEADLINE ]; do
        if ! kill -0 "$SUBSHELL_PID" 2>/dev/null; then
            KILLED=1
            break
        fi
        sleep 1
    done
    if [ "$KILLED" -eq 1 ]; then
        pass "A5c/3: subshell PID $SUBSHELL_PID terminated after scheduler shutdown"
    else
        fail "A5c/3: subshell PID $SUBSHELL_PID survived scheduler shutdown (kill_process_tree did not escalate)"
    fi
    SUBSHELL_PID=""   # whether dead or not, we no longer track it

    if [ "$FAIL" -gt 0 ]; then
        echo "--- A5c scheduler log (tail 60) ---"
        tail -60 "$TMP_LOG" 2>/dev/null
        echo "--- A5c jobs ---"
        $DB_QUERY "SELECT id,service_id,status,pid,pid_starttime,process_state,message FROM jobs;"
    fi

    rm -f "$TMP_LOG"; TMP_LOG=""
    cleanup_test_db "$TEST_DB"; TEST_DB=""
}

run_a5a
run_a5b
run_a5c

print_test_summary
