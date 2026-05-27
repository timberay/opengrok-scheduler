#!/bin/bash
# tests/test_sigkill_restart_recovery.sh
# Case A4 — Scheduler SIGKILLed mid-cycle, then restarted with fresh window.
#
# Scenario:
#   The scheduler was running inside its window with at least one in-flight
#   job. Operator (or OOM killer / kernel) sends SIGKILL: no trap fires,
#   cleanup_and_exit never runs, the DB is frozen with status=RUNNING for
#   both the run and the in-flight job(s), pid/pid_starttime recorded. The
#   user later restarts the scheduler.
#
# Restart-recovery contract:
#   For each RUNNING job with PID+starttime, verify_pid_identity is called.
#     * Alive + starttime matches  -> tracked into BG_PIDS (recovered).
#     * Dead OR starttime mismatch -> marked ORPHANED, no kill issued.
#   run_recover_stale closes the previously-RUNNING run as ABORTED.
#   Next dispatch loop opens a NEW run; ORPHANED services are eligible again
#   (the dedup query is run_id-scoped).
#
# We bypass the actual SIGKILL by seeding the DB with the (PID, starttime,
# RUNNING run, RUNNING job) state the killed scheduler would have left
# behind. This avoids forking and SIGKILLing a real scheduler, which is
# fragile in CI (timing-dependent leaks, lock-file races).
#
# Two sub-cases:
#   A4a — the indexing child died BEFORE the restart. DB still RUNNING,
#         but /proc/PID is gone. Recovery should mark ORPHANED (no kill).
#   A4b — the indexing child is STILL ALIVE at restart time (its parent
#         died but the subshell ignores SIGTERM and was reparented to
#         init). DB still RUNNING and /proc/PID is alive with matching
#         starttime. Recovery should restore tracking via BG_PIDS, the
#         prior run should be marked ABORTED, a NEW run should open, and
#         while the recovered job is still RUNNING the BG_PIDS check at
#         scheduler.sh:868 must prevent re-dispatching the SAME service
#         into the new run. Once the recovered job finishes, the service
#         becomes eligible again in the new run.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"
source "$PROJECT_ROOT/bin/monitor.sh" >/dev/null 2>&1   # get_pid_starttime, verify_pid_identity

echo "=== Test: SIGKILL scheduler then restart — recovery contract (A4) ==="

PASS=0
FAIL=0
pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

# ---- shared state used by cleanup_all ---------------------------------
TEST_DB=""
SCHEDULER_PID=""
SURVIVOR_PID=""
TMP_LOG=""

cleanup_all() {
    if [ -n "$SCHEDULER_PID" ] && kill -0 "$SCHEDULER_PID" 2>/dev/null; then
        kill -TERM "$SCHEDULER_PID" 2>/dev/null
        for _ in $(seq 1 10); do
            kill -0 "$SCHEDULER_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SCHEDULER_PID" 2>/dev/null
        wait "$SCHEDULER_PID" 2>/dev/null
    fi
    if [ -n "$SURVIVOR_PID" ] && kill -0 "$SURVIVOR_PID" 2>/dev/null; then
        kill -KILL "$SURVIVOR_PID" 2>/dev/null
        wait "$SURVIVOR_PID" 2>/dev/null
    fi
    pkill -P $$ 2>/dev/null
    [ -n "$TMP_LOG" ] && rm -f "$TMP_LOG"
    [ -n "$TEST_DB" ] && cleanup_test_db "$TEST_DB"
    rm -f "${TEST_DB}.lock" 2>/dev/null
}
trap cleanup_all EXIT

# Shared scheduler env. Always-open window so a new run opens immediately
# on restart; resource threshold high so dispatch never stalls; idle
# timeout disabled so the dummy sleep-task doesn't trip on zero CPU.
export START_TIME=00:00
export END_TIME=23:59
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=3
export JOB_IDLE_TIMEOUT=0
# Default JOB_TIMEOUT_SEC=36000 means stale-expire (2x) won't touch a
# seeded row whose start_time is now() — perfect for A4b. For A4a we
# also want the seeded row's start_time to be recent enough to skip the
# stale path; the recovery path then handles it.
export JOB_TIMEOUT_SEC=36000
export KILL_GRACE_SEC=1
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"

# Rotate the seeded DB filename so the two sub-cases never share state
# (setup_test_db keys off $0's basename and PID, both stable within a
# single bash invocation).
rotate_db() {
    local TAG="$1"
    TEST_DB=$(setup_test_db)
    local UNIQ_DB="${TEST_DB%.db}_${TAG}.db"
    mv "$TEST_DB" "$UNIQ_DB"
    mv "${TEST_DB}-shm" "${UNIQ_DB}-shm" 2>/dev/null || true
    mv "${TEST_DB}-wal" "${UNIQ_DB}-wal" 2>/dev/null || true
    TEST_DB="$UNIQ_DB"
    export DB_PATH="$TEST_DB"
    "$PROJECT_ROOT/bin/migrate_db.sh" >/dev/null 2>&1
}

# Wait until a DB predicate (single-row query returning 0/non-zero) holds,
# bounded by a deadline in seconds. Polls every 1s.
wait_until() {
    local TIMEOUT="$1"; shift
    local DESC="$1"; shift
    local QUERY="$1"
    local EXPECT="$2"
    local DEADLINE=$((SECONDS + TIMEOUT))
    local VAL=""
    while [ $SECONDS -lt $DEADLINE ]; do
        VAL=$($DB_QUERY "$QUERY" 2>/dev/null)
        [ "$VAL" = "$EXPECT" ] && return 0
        sleep 1
    done
    echo "[wait_until] '$DESC' timed out after ${TIMEOUT}s (last value='$VAL', expected='$EXPECT')" >&2
    return 1
}

# ============================================================================
# Sub-case A4a — Job's child PID is DEAD at restart time
# ============================================================================
echo ""
echo "=============================="
echo "[Sub-case A4a] PID dead at restart"
echo "=============================="

rotate_db "a4a"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-a4a', 1, 1);"
SVC_ID_A=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-a4a';")

# Spawn a sentinel and kill it so we have a (PID, starttime) tuple whose
# /proc entry is gone. Using a real-then-reaped PID is more honest than
# a hardcoded 99999: it proves we picked up an identity that *was* alive
# when the (killed) scheduler recorded it.
sleep 60 &
DEAD_PID=$!
sleep 0.2
DEAD_START=$(get_pid_starttime "$DEAD_PID")
kill -KILL "$DEAD_PID" 2>/dev/null
wait "$DEAD_PID" 2>/dev/null
# Defensive: confirm /proc/$DEAD_PID is gone before we seed the DB.
DEAD_PID_GONE_DEADLINE=$((SECONDS + 5))
while [ -d "/proc/$DEAD_PID" ] && [ $SECONDS -lt $DEAD_PID_GONE_DEADLINE ]; do
    sleep 0.1
done

if [ -d "/proc/$DEAD_PID" ]; then
    fail "A4a/precondition: PID $DEAD_PID is still in /proc after kill+wait"
else
    pass "A4a/precondition: PID $DEAD_PID is gone from /proc"
fi
if [ -z "$DEAD_START" ] || ! [[ "$DEAD_START" =~ ^[0-9]+$ ]]; then
    fail "A4a/precondition: could not capture starttime for sentinel (got '$DEAD_START')"
else
    pass "A4a/precondition: captured dead-PID starttime=$DEAD_START"
fi

# Seed the DB to match what a SIGKILLed scheduler would have left:
#   - one RUNNING run (the in-flight cycle)
#   - one RUNNING job referencing the now-dead PID/starttime tuple
PRIOR_RUN_ID_A=$($DB_QUERY "INSERT INTO runs (started_at, status, triggered_by, total_services)
                            VALUES (datetime('now','localtime','-5 minutes'),
                                    'RUNNING','auto',
                                    (SELECT COUNT(*) FROM services WHERE is_active=1));
                            SELECT last_insert_rowid();")
$DB_QUERY "INSERT INTO jobs (service_id, run_id, status, pid, pid_starttime, process_state, start_time)
           VALUES ($SVC_ID_A, $PRIOR_RUN_ID_A, 'RUNNING', $DEAD_PID, $DEAD_START, 'RUNNING',
                   datetime('now','localtime','-2 minutes'));"
OLD_JOB_ID_A=$($DB_QUERY "SELECT id FROM jobs WHERE run_id=$PRIOR_RUN_ID_A AND service_id=$SVC_ID_A;")

# Sanity: pre-restart DB state matches the SIGKILL aftermath we want to recover from.
PRE_RUN_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$PRIOR_RUN_ID_A;")
PRE_JOB_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE id=$OLD_JOB_ID_A;")
assert_eq "A4a/C1: prior run seeded as RUNNING" "RUNNING" "$PRE_RUN_STATUS"
assert_eq "A4a/C1: prior job seeded as RUNNING" "RUNNING" "$PRE_JOB_STATUS"

# Restart the scheduler. With an always-open window it will: run recovery
# (marks dead-PID row ORPHANED, never killing anything), close the prior
# run as ABORTED, open a new run, and re-dispatch svc-a4a.
TMP_LOG=$(mktemp /tmp/test_sigkill_restart_a4a.XXXXXX.log)
bash "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHEDULER_PID=$!

# Recovery + first dispatch tick + sleep 2 dummy task + run close: 20s is comfortable.
wait_until 20 "A4a old job marked ORPHANED" \
    "SELECT status FROM jobs WHERE id=$OLD_JOB_ID_A;" "ORPHANED"
ORPH_STATUS_A=$($DB_QUERY "SELECT status FROM jobs WHERE id=$OLD_JOB_ID_A;")
ORPH_PSTATE_A=$($DB_QUERY "SELECT process_state FROM jobs WHERE id=$OLD_JOB_ID_A;")
assert_eq "A4a/C2: old job marked ORPHANED" "ORPHANED" "$ORPH_STATUS_A"
assert_eq "A4a/C2: old job process_state=UNKNOWN" "UNKNOWN" "$ORPH_PSTATE_A"

wait_until 10 "A4a old run marked ABORTED" \
    "SELECT status FROM runs WHERE id=$PRIOR_RUN_ID_A;" "ABORTED"
OLD_RUN_STATUS_A=$($DB_QUERY "SELECT status FROM runs WHERE id=$PRIOR_RUN_ID_A;")
assert_eq "A4a/C3: prior run closed as ABORTED" "ABORTED" "$OLD_RUN_STATUS_A"

# Wait for a NEW run row (id > PRIOR_RUN_ID_A) with status=RUNNING.
NEW_RUN_DEADLINE=$((SECONDS + 15))
NEW_RUN_ID_A=""
while [ $SECONDS -lt $NEW_RUN_DEADLINE ]; do
    NEW_RUN_ID_A=$($DB_QUERY "SELECT id FROM runs WHERE id > $PRIOR_RUN_ID_A AND status='RUNNING' ORDER BY id DESC LIMIT 1;")
    [ -n "$NEW_RUN_ID_A" ] && break
    sleep 1
done
if [ -n "$NEW_RUN_ID_A" ]; then
    pass "A4a/C4: new run #$NEW_RUN_ID_A opened RUNNING"
else
    fail "A4a/C4: no new RUNNING run opened after restart"
fi

# The same service should be dispatched again in the new run (dedup is
# per-run; the prior ORPHANED row in PRIOR_RUN_ID_A is invisible here)
# and should eventually reach COMPLETED with the stock sleep-2 task.
if [ -n "$NEW_RUN_ID_A" ]; then
    wait_until 20 "A4a new run dispatched the service to COMPLETED" \
        "SELECT status FROM jobs WHERE service_id=$SVC_ID_A AND run_id=$NEW_RUN_ID_A;" \
        "COMPLETED"
    NEW_JOB_STATUS_A=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$SVC_ID_A AND run_id=$NEW_RUN_ID_A;")
    assert_eq "A4a/C5: service re-dispatched and COMPLETED in new run" "COMPLETED" "$NEW_JOB_STATUS_A"
fi

# Tear down the scheduler before moving to A4b.
if kill -0 "$SCHEDULER_PID" 2>/dev/null; then
    kill -TERM "$SCHEDULER_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHEDULER_PID" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$SCHEDULER_PID" 2>/dev/null
    wait "$SCHEDULER_PID" 2>/dev/null
fi
SCHEDULER_PID=""

# Diagnostic dump if anything failed in A4a.
if [ "$FAIL" -gt 0 ]; then
    echo "--- A4a scheduler log (last 60 lines) ---"
    tail -60 "$TMP_LOG"
    echo "--- A4a runs table ---"
    $DB_QUERY "SELECT id,status,triggered_by,started_at,ended_at,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
    echo "--- A4a jobs table ---"
    $DB_QUERY "SELECT id,service_id,run_id,status,pid,start_time,end_time,message FROM jobs ORDER BY id;"
fi

rm -f "$TMP_LOG"; TMP_LOG=""
cleanup_test_db "$TEST_DB"
rm -f "${TEST_DB}.lock" 2>/dev/null
TEST_DB=""

A4A_FAIL_BASELINE=$FAIL

# ============================================================================
# Sub-case A4b — Job's child PID is ALIVE at restart time
# ============================================================================
echo ""
echo "=============================="
echo "[Sub-case A4b] PID alive at restart (reparented to init)"
echo "=============================="

rotate_db "a4b"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-a4b', 1, 1);"
SVC_ID_B=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-a4b';")

# Spawn a long-lived subshell mirroring the production dispatch wrapper:
#   ( trap '' SIGTERM SIGINT; run_indexing_task ... ) &
# This is exactly what survives a SIGKILL of the parent scheduler (the
# subshell ignores SIGTERM/SIGINT — and SIGKILL would have only hit the
# parent in the operator-described scenario). setsid detaches it from
# the test process group so a stray pkill -P $$ won't accidentally take
# it out before we measure recovery behavior.
#
# Lifetime 40s: long enough that several reap+dispatch cycles observe the
# survivor as still-alive (we need to see "Process check skip" logged at
# least twice), short enough that the test wraps in well under a minute.
SURVIVOR_LIFETIME=40
setsid bash -c "trap '' SIGTERM SIGINT; exec sleep $SURVIVOR_LIFETIME" </dev/null >/dev/null 2>&1 &
SURVIVOR_PID=$!
sleep 0.3
SURVIVOR_START=$(get_pid_starttime "$SURVIVOR_PID")

if [ -z "$SURVIVOR_START" ] || ! [[ "$SURVIVOR_START" =~ ^[0-9]+$ ]]; then
    fail "A4b/precondition: could not capture starttime for survivor (got '$SURVIVOR_START')"
else
    pass "A4b/precondition: survivor PID=$SURVIVOR_PID alive starttime=$SURVIVOR_START"
fi
if verify_pid_identity "$SURVIVOR_PID" "$SURVIVOR_START"; then
    pass "A4b/precondition: survivor (PID,starttime) verifies alive"
else
    fail "A4b/precondition: survivor failed identity check pre-restart"
fi

# Seed: RUNNING run + RUNNING job pointing at the live survivor PID.
PRIOR_RUN_ID_B=$($DB_QUERY "INSERT INTO runs (started_at, status, triggered_by, total_services)
                            VALUES (datetime('now','localtime','-5 minutes'),
                                    'RUNNING','auto',
                                    (SELECT COUNT(*) FROM services WHERE is_active=1));
                            SELECT last_insert_rowid();")
$DB_QUERY "INSERT INTO jobs (service_id, run_id, status, pid, pid_starttime, process_state, start_time)
           VALUES ($SVC_ID_B, $PRIOR_RUN_ID_B, 'RUNNING', $SURVIVOR_PID, $SURVIVOR_START, 'RUNNING',
                   datetime('now','localtime','-1 minute'));"
OLD_JOB_ID_B=$($DB_QUERY "SELECT id FROM jobs WHERE run_id=$PRIOR_RUN_ID_B AND service_id=$SVC_ID_B;")

# Restart scheduler.
TMP_LOG=$(mktemp /tmp/test_sigkill_restart_a4b.XXXXXX.log)
bash "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHEDULER_PID=$!

# Recovery should log "[Recovery] Restored job tracking" and keep the
# old job RUNNING (NOT ORPHANED). Give it up to 10s.
RECOVERY_DEADLINE=$((SECONDS + 10))
RECOVERED=0
while [ $SECONDS -lt $RECOVERY_DEADLINE ]; do
    if grep -q "\[Recovery\] Restored job tracking for svc-a4b" "$TMP_LOG" 2>/dev/null; then
        RECOVERED=1
        break
    fi
    sleep 1
done
if [ "$RECOVERED" = "1" ]; then
    pass "A4b/C2: recovery restored job tracking for live survivor"
else
    fail "A4b/C2: recovery did not log restoration for svc-a4b within 10s"
fi

STILL_RUNNING_B=$($DB_QUERY "SELECT status FROM jobs WHERE id=$OLD_JOB_ID_B;")
assert_eq "A4b/C2: old job stays RUNNING after recovery (not ORPHANED)" "RUNNING" "$STILL_RUNNING_B"

# Prior run should be closed ABORTED by run_recover_stale.
wait_until 10 "A4b prior run closed ABORTED" \
    "SELECT status FROM runs WHERE id=$PRIOR_RUN_ID_B;" "ABORTED"
PRIOR_STATUS_B=$($DB_QUERY "SELECT status FROM runs WHERE id=$PRIOR_RUN_ID_B;")
assert_eq "A4b/C3: prior run closed as ABORTED by run_recover_stale" "ABORTED" "$PRIOR_STATUS_B"

# New run opens (always-open window).
NEW_RUN_DEADLINE=$((SECONDS + 15))
NEW_RUN_ID_B=""
while [ $SECONDS -lt $NEW_RUN_DEADLINE ]; do
    NEW_RUN_ID_B=$($DB_QUERY "SELECT id FROM runs WHERE id > $PRIOR_RUN_ID_B AND status='RUNNING' ORDER BY id DESC LIMIT 1;")
    [ -n "$NEW_RUN_ID_B" ] && break
    sleep 1
done
if [ -n "$NEW_RUN_ID_B" ]; then
    pass "A4b/C4: new run #$NEW_RUN_ID_B opened RUNNING"
else
    fail "A4b/C4: no new RUNNING run opened after restart"
fi

# While the recovered job is STILL alive, the scheduler's line-868 check
# (`kill -0 "${BG_PIDS[$CNAME]}"`) must prevent re-dispatch of the same
# service into the new run. We assert this in two complementary ways:
#   1. The log line "Process check skip: svc-a4b is already being indexed"
#      is emitted at least once.
#   2. There is NO new jobs row for svc-a4b in NEW_RUN_ID_B while the
#      old job is still RUNNING. (Old row continues to belong to
#      PRIOR_RUN_ID_B.)
#
# Poll until the dispatch loop has actually had a chance to run at least
# one tick with the survivor still alive. Each tick is ~5s on this host
# because vmstat/iostat each take a ~1s sample interval. We poll up to
# 20s for at least one skip line to appear.
SKIP_DEADLINE=$((SECONDS + 20))
SKIP_LOGGED=0
while [ $SECONDS -lt $SKIP_DEADLINE ]; do
    SKIP_LOGGED=$(grep -c "Process check skip: svc-a4b is already being indexed" "$TMP_LOG" 2>/dev/null)
    # grep -c emits the count on stdout (always); exit code is 0/1 but we
    # only care about the number. Coerce empty to 0 in case the file is
    # missing for any reason.
    [ -z "$SKIP_LOGGED" ] && SKIP_LOGGED=0
    [ "$SKIP_LOGGED" -ge 1 ] && break
    sleep 1
done
if [ "${SKIP_LOGGED:-0}" -ge 1 ]; then
    pass "A4b/C4: dispatch loop skipped svc-a4b while recovered job alive ($SKIP_LOGGED log line(s))"
else
    fail "A4b/C4: expected 'Process check skip' for svc-a4b at least once within 20s, got $SKIP_LOGGED"
fi

NEW_ROWS_WHILE_ALIVE=0
if [ -n "$NEW_RUN_ID_B" ]; then
    NEW_ROWS_WHILE_ALIVE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$NEW_RUN_ID_B AND service_id=$SVC_ID_B;")
fi
# C4 expected behaviour: dedup query is per-run, so the service IS
# eligible in the new run, BUT the BG_PIDS check prevents a NEW jobs
# row from being inserted. Therefore COUNT=0 here (provided the survivor
# is still alive — verify_pid_identity below).
SURVIVOR_STILL_ALIVE=0
if kill -0 "$SURVIVOR_PID" 2>/dev/null && verify_pid_identity "$SURVIVOR_PID" "$SURVIVOR_START"; then
    SURVIVOR_STILL_ALIVE=1
fi
if [ "$SURVIVOR_STILL_ALIVE" = "1" ]; then
    assert_eq "A4b/C4: no NEW job row for svc-a4b while recovered job still alive" "0" "$NEW_ROWS_WHILE_ALIVE"
else
    # Survivor exited before we could observe this — the C4 assertion is
    # only meaningful while the recovered process is alive. Record this
    # as a soft skip rather than a false-positive pass/fail.
    echo "[Skip] A4b/C4: survivor exited before NEW-row check could observe (timing)"
fi

# Now wait for the recovered job to reach a terminal status. The
# scheduler's reap_bg_processes loop transitions the row RUNNING ->
# {COMPLETED|FAILED|TIMEOUT} based on the wrapped process's exit code.
#
# Realistic exit code for a recovered orphan: 127. The scheduler that
# now monitors the survivor is NOT its parent (the original scheduler
# was SIGKILLed, the subshell got reparented to init). `wait $PID` from
# a non-parent shell returns 127 ("not a child of this shell"), so the
# reap loop's EXITED branch records status=FAILED, message='Exit code 127'.
# That is the correct, documented behaviour for adopt-and-reap of an
# orphaned subshell — the alternative (COMPLETED) would require parent
# adoption via prctl(PR_SET_CHILD_SUBREAPER), which the scheduler does
# not do.
#
# Reap-vs-dispatch race coverage: if the survivor exits between the
# top-of-loop reap_bg_processes call and the dispatch's `kill -0` check
# (the gap spans several seconds of resource sampling via vmstat /
# iostat), the recovered BG_PID would otherwise be silently overwritten
# by the new dispatch without the old DB row ever being finalised. The
# scheduler has an explicit "BG_PID is dead but unreaped" branch in the
# dispatch path that forces an extra reap before allowing re-dispatch;
# this assertion is what proves that defence holds (the row reaches a
# terminal status, NOT remains RUNNING).
DEADLINE=$((SECONDS + SURVIVOR_LIFETIME + 30))
FINAL_OLD_STATUS_B=""
while [ $SECONDS -lt $DEADLINE ]; do
    FINAL_OLD_STATUS_B=$($DB_QUERY "SELECT status FROM jobs WHERE id=$OLD_JOB_ID_B;" 2>/dev/null)
    case "$FINAL_OLD_STATUS_B" in
        COMPLETED|FAILED|TIMEOUT|ORPHANED) break ;;
    esac
    sleep 1
done
case "$FINAL_OLD_STATUS_B" in
    COMPLETED|FAILED|TIMEOUT)
        pass "A4b/C3: recovered job reached terminal status='$FINAL_OLD_STATUS_B' (not stuck RUNNING)"
        ;;
    RUNNING)
        fail "A4b/C3: recovered job stuck RUNNING after survivor exit (reap/dispatch race not handled)"
        ;;
    *)
        fail "A4b/C3: recovered job has unexpected status '$FINAL_OLD_STATUS_B'"
        ;;
esac

# Once the survivor exits, the next dispatch tick should insert a NEW
# job row for svc-a4b in NEW_RUN_ID_B (BG_PIDS now empty for that
# service, dedup query sees no row in this run). Give it generous
# headroom for the reap cycle + dispatch tick + stock sleep-2 task.
if [ -n "$NEW_RUN_ID_B" ]; then
    wait_until 25 "A4b service re-dispatched and COMPLETED in new run after survivor exit" \
        "SELECT status FROM jobs WHERE service_id=$SVC_ID_B AND run_id=$NEW_RUN_ID_B;" \
        "COMPLETED"
    NEW_DISPATCH_STATUS_B=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$SVC_ID_B AND run_id=$NEW_RUN_ID_B;")
    assert_eq "A4b/C5: service re-dispatched in new run after old job finished" "COMPLETED" "$NEW_DISPATCH_STATUS_B"
fi

# Tear down scheduler.
if kill -0 "$SCHEDULER_PID" 2>/dev/null; then
    kill -TERM "$SCHEDULER_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHEDULER_PID" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$SCHEDULER_PID" 2>/dev/null
    wait "$SCHEDULER_PID" 2>/dev/null
fi
SCHEDULER_PID=""

# C6: no leaked processes. Survivor should have exited on its own; if it
# is somehow still alive (recovery never reaped it), that's a leak.
if [ -n "$SURVIVOR_PID" ] && kill -0 "$SURVIVOR_PID" 2>/dev/null; then
    # It might still be in sleep 25 if our recovery wait raced; give it
    # one more tick.
    sleep 2
fi
if [ -n "$SURVIVOR_PID" ] && kill -0 "$SURVIVOR_PID" 2>/dev/null; then
    fail "A4b/C6: survivor PID $SURVIVOR_PID still alive at test end (leak)"
    kill -KILL "$SURVIVOR_PID" 2>/dev/null
    wait "$SURVIVOR_PID" 2>/dev/null
else
    pass "A4b/C6: no leaked processes after recovery cycle"
fi
SURVIVOR_PID=""

# Diagnostic dump if A4b added any failures.
if [ "$FAIL" -gt "$A4A_FAIL_BASELINE" ]; then
    echo "--- A4b scheduler log (last 80 lines) ---"
    tail -80 "$TMP_LOG"
    echo "--- A4b runs table ---"
    $DB_QUERY "SELECT id,status,triggered_by,started_at,ended_at,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
    echo "--- A4b jobs table ---"
    $DB_QUERY "SELECT id,service_id,run_id,status,pid,pid_starttime,start_time,end_time,message FROM jobs ORDER BY id;"
fi

rm -f "$TMP_LOG"; TMP_LOG=""
cleanup_test_db "$TEST_DB"
rm -f "${TEST_DB}.lock" 2>/dev/null
TEST_DB=""

print_test_summary
