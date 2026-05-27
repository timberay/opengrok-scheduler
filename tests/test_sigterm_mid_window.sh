#!/bin/bash
# tests/test_sigterm_mid_window.sh
# Case A3 — SIGTERM/SIGINT mid-window with at least one in-flight job.
#
# Scenario:
#   Scheduler is running inside its working window and has dispatched one or
#   more background indexing jobs. Operator sends SIGTERM (e.g. systemctl
#   stop) or SIGINT (Ctrl+C in interactive shell). The cleanup_and_exit
#   trap must:
#     1. Kill every tracked background process tree.
#     2. Mark every still-RUNNING job in the open run as ORPHANED with
#        message='Scheduler shutdown' and end_time set.
#     3. Close the open run as ABORTED with ended_at populated.
#     4. Exit cleanly with code 0.
#     5. Leave no live indexing processes behind.
#     6. On restart with an always-open window, a new run id is opened and
#        the dispatch produces a fresh RUNNING (then COMPLETED) job for the
#        same service — the prior ORPHANED rows must NOT block the next
#        cycle (the dedup query is run_id-scoped).
#
# This case is exercised twice, once per signal (SIGTERM, SIGINT), via a
# shared helper closure so both code paths share the same contract proof.
#
# Notes:
# - The stock indexing placeholder is `sleep 2`, which would race past the
#   signal. Build a temp scheduler whose placeholder is `sleep 60` so jobs
#   are demonstrably in-flight when we deliver the signal.
# - The scheduler wraps each dispatch in
#       ( trap '' SIGTERM SIGINT; run_indexing_task ... ) &
#   so the subshell ignores SIGTERM/SIGINT. kill_process_tree must escalate
#   to SIGKILL after KILL_GRACE_SEC. We set KILL_GRACE_SEC=1 so the test
#   does not need long timeouts.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"
source "$PROJECT_ROOT/bin/monitor.sh"   # verify_pid_identity
BIN_DIR="$PROJECT_ROOT/bin"

echo "=== Test: SIGTERM/SIGINT mid-window — cleanup_and_exit contract (A3) ==="

PASS=0
FAIL=0
pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

# -----------------------------------------------------------------------
# Shared state (set inside run_signal_case; cleaned up by trap)
# -----------------------------------------------------------------------
TEMP_SCHEDULER=""
TEST_DB=""
SCHEDULER_PID=""
SCHEDULER_PID_2=""
TMP_LOG=""
TMP_LOG_2=""
TRACKED_PIDS=()

cleanup_all() {
    for p in "$SCHEDULER_PID" "$SCHEDULER_PID_2"; do
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            kill -TERM "$p" 2>/dev/null
            for _ in $(seq 1 5); do
                kill -0 "$p" 2>/dev/null || break
                sleep 1
            done
            kill -KILL "$p" 2>/dev/null
            wait "$p" 2>/dev/null
        fi
    done
    for p in "${TRACKED_PIDS[@]}"; do
        [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
    done
    # Best-effort: anything left under this shell.
    pkill -P $$ 2>/dev/null
    [ -n "$TMP_LOG" ] && rm -f "$TMP_LOG"
    [ -n "$TMP_LOG_2" ] && rm -f "$TMP_LOG_2"
    [ -n "$TEMP_SCHEDULER" ] && rm -f "$TEMP_SCHEDULER"
    [ -n "$TEST_DB" ] && cleanup_test_db "$TEST_DB"
}
trap cleanup_all EXIT

# -----------------------------------------------------------------------
# Build a scheduler variant whose dummy indexing task lasts long enough
# to still be alive when we send the signal. Lives under BIN_DIR so its
# internal `source common.sh` resolves correctly.
# -----------------------------------------------------------------------
TEMP_SCHEDULER=$(mktemp "$BIN_DIR/scheduler_test_sigmid_XXXXXX.sh")
sed 's|timeout --kill-after=10s "\$MAX_DURATION" bash -c "sleep 2"|timeout --kill-after=10s "$MAX_DURATION" bash -c "sleep 60"|' \
    "$BIN_DIR/scheduler.sh" > "$TEMP_SCHEDULER"
chmod +x "$TEMP_SCHEDULER"

# Common scheduler env. Always-open window so the window never closes on
# its own — the only thing that ends the scheduler is the signal we send.
export START_TIME=00:00
export END_TIME=23:59
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=3
export JOB_IDLE_TIMEOUT=0
export JOB_TIMEOUT_SEC=300
export KILL_GRACE_SEC=1
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------
# run_signal_case: shared closure exercising the full A3 contract for
# a given signal name. Each invocation runs against its own fresh DB so
# the two sub-sections do not contaminate each other (e.g. the SIGTERM
# phase-2 restart leaves a brand-new RUNNING run id that would shadow
# the SIGINT subsection's view of "newer than RID").
#
# Args: $1 = signal name (TERM | INT)
# Globals it touches: TEST_DB, SCHEDULER_PID, SCHEDULER_PID_2, TMP_LOG,
#                     TMP_LOG_2, TRACKED_PIDS, PASS, FAIL
# -----------------------------------------------------------------------
run_signal_case() {
    local SIG="$1"
    local TAG="SIG${SIG}"

    echo ""
    echo "=============================="
    echo "[Sub-case] $TAG mid-window"
    echo "=============================="

    # Fresh DB per sub-case. setup_test_db keys off basename of $0, so
    # multiple invocations within one test process collide on the file
    # path; rotate via a unique suffix.
    TEST_DB=$(setup_test_db)
    # Move the seeded DB aside so each sub-case gets a truly fresh one.
    local UNIQ_DB="${TEST_DB%.db}_${SIG}.db"
    mv "$TEST_DB" "$UNIQ_DB"
    mv "${TEST_DB}-shm" "${UNIQ_DB}-shm" 2>/dev/null || true
    mv "${TEST_DB}-wal" "${UNIQ_DB}-wal" 2>/dev/null || true
    TEST_DB="$UNIQ_DB"
    export DB_PATH="$TEST_DB"

    $DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
        ('svc-${SIG}-a', 1, 1),
        ('svc-${SIG}-b', 1, 1);"

    TMP_LOG=$(mktemp "/tmp/test_sigterm_mid_window_${SIG}.XXXXXX.log")

    # --- 1. Launch scheduler -------------------------------------------------
    # When a non-interactive bash spawns an async child with `&`, POSIX
    # mandates that SIGINT and SIGQUIT be set to SIG_IGN in that child.
    # Bash's `trap` builtin honors inherited SIG_IGN and refuses to install
    # a handler — so a naked `bash script.sh &` from this test would have
    # the scheduler silently ignore our SIGINT, which is NOT the production
    # operator's experience (an interactive Ctrl+C delivers SIGINT to a
    # process whose handler was never set to SIG_IGN).
    #
    # `env --default-signal=INT` (coreutils >=8.30) resets SIGINT to its
    # default disposition before exec'ing the scheduler, mirroring the
    # interactive-tty path the trap is designed to handle. Applied for
    # both signals for symmetry — it is a no-op for SIGTERM (SIGTERM is
    # not affected by the job-control inheritance quirk).
    env --default-signal=INT bash "$TEMP_SCHEDULER" >"$TMP_LOG" 2>&1 &
    SCHEDULER_PID=$!

    # --- 2. Wait until at least one RUNNING job is registered ---------------
    local ROW=""
    local IN_FLIGHT_PID=""
    local IN_FLIGHT_STARTTIME=""
    local RUN_ID=""
    local DEADLINE=$((SECONDS + 30))
    while [ $SECONDS -lt $DEADLINE ]; do
        ROW=$($DB_QUERY "SELECT pid, pid_starttime FROM jobs WHERE status='RUNNING' AND pid IS NOT NULL AND pid_starttime IS NOT NULL LIMIT 1;" 2>/dev/null)
        if [ -n "$ROW" ]; then
            IN_FLIGHT_PID=${ROW%%|*}
            IN_FLIGHT_STARTTIME=${ROW##*|}
            RUN_ID=$($DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;" 2>/dev/null)
            break
        fi
        sleep 1
    done

    if [ -z "$IN_FLIGHT_PID" ] || [ -z "$RUN_ID" ]; then
        fail "$TAG/C1: scheduler did not produce a RUNNING job within 30s"
        echo "--- scheduler log ---"; tail -40 "$TMP_LOG"
        # Tear down this sub-case before returning so cleanup_all doesn't
        # find leaked state from a half-built run.
        kill -KILL "$SCHEDULER_PID" 2>/dev/null
        wait "$SCHEDULER_PID" 2>/dev/null
        SCHEDULER_PID=""
        return 1
    fi
    pass "$TAG/C1: RUNNING job present in run #$RUN_ID (PID=$IN_FLIGHT_PID)"
    TRACKED_PIDS+=("$IN_FLIGHT_PID")

    # Collect every dispatched PID for the leak check after signal.
    local p
    while IFS= read -r p; do
        [ -n "$p" ] && TRACKED_PIDS+=("$p")
    done < <($DB_QUERY "SELECT pid FROM jobs WHERE run_id=$RUN_ID AND pid IS NOT NULL;")

    # Sanity: recorded PID is genuinely alive before signal.
    if verify_pid_identity "$IN_FLIGHT_PID" "$IN_FLIGHT_STARTTIME"; then
        pass "$TAG/C1: in-flight job (PID,starttime) verified alive pre-signal"
    else
        fail "$TAG/C1: recorded PID=$IN_FLIGHT_PID failed identity check pre-signal"
    fi

    # --- 3. Send the signal to the scheduler --------------------------------
    kill -"$SIG" "$SCHEDULER_PID" 2>/dev/null

    # Wait for scheduler exit, capped at 15s. cleanup_and_exit must:
    #   - SIGTERM each tracked PID, sleep KILL_GRACE_SEC (=1), then SIGKILL.
    #   - close the open run, log, exit 0.
    # 15s is comfortable headroom for that path.
    local WAIT_DEADLINE=$((SECONDS + 15))
    while kill -0 "$SCHEDULER_PID" 2>/dev/null && [ $SECONDS -lt $WAIT_DEADLINE ]; do
        sleep 1
    done
    if kill -0 "$SCHEDULER_PID" 2>/dev/null; then
        fail "$TAG/C4: scheduler did not exit within 15s of $TAG"
        kill -KILL "$SCHEDULER_PID" 2>/dev/null
        wait "$SCHEDULER_PID" 2>/dev/null
        SCHEDULER_PID=""
        echo "--- scheduler log (tail 60) ---"; tail -60 "$TMP_LOG"
        return 1
    fi
    wait "$SCHEDULER_PID"
    local SCHED_RC=$?
    SCHEDULER_PID=""
    pass "$TAG/C4: scheduler exited within 15s of $TAG (rc=$SCHED_RC)"

    # --- 4. Contract assertions --------------------------------------------

    # C4: clean exit code 0 — cleanup_and_exit ends with `exit 0`.
    assert_eq "$TAG/C4: scheduler exit code = 0" "0" "$SCHED_RC"

    # C2: open run is now ABORTED with ended_at populated.
    local RUN_STATUS RUN_ENDED
    RUN_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN_ID;")
    assert_eq "$TAG/C2: run #$RUN_ID status = ABORTED" "ABORTED" "$RUN_STATUS"
    RUN_ENDED=$($DB_QUERY "SELECT ended_at IS NOT NULL FROM runs WHERE id=$RUN_ID;")
    assert_eq "$TAG/C2: run #$RUN_ID ended_at populated" "1" "$RUN_ENDED"

    # C3: every still-RUNNING job in the run is now ORPHANED with the
    # documented message and end_time set. No RUNNING rows must remain.
    local LEFT_RUNNING ORPH_COUNT ORPH_NO_END
    LEFT_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='RUNNING';")
    assert_eq "$TAG/C3: no RUNNING jobs remain in run #$RUN_ID" "0" "$LEFT_RUNNING"

    ORPH_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='ORPHANED' AND message='Scheduler shutdown';")
    if [ "${ORPH_COUNT:-0}" -ge 1 ]; then
        pass "$TAG/C3: $ORPH_COUNT ORPHANED row(s) tagged 'Scheduler shutdown'"
    else
        fail "$TAG/C3: expected >=1 ORPHANED 'Scheduler shutdown' row, got $ORPH_COUNT"
    fi

    ORPH_NO_END=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='ORPHANED' AND end_time IS NULL;")
    assert_eq "$TAG/C3: every ORPHANED row in run has end_time set" "0" "$ORPH_NO_END"

    # C5: no leaked indexing processes — every dispatched PID's (PID,starttime)
    # tuple no longer identifies a live process. (PID may have been recycled
    # to something else; identity check guards against false negatives.)
    local LEAKED=0
    local LEAKED_LIST=""
    local LPID LSTART
    while IFS='|' read -r LPID LSTART; do
        [ -z "$LPID" ] && continue
        if verify_pid_identity "$LPID" "$LSTART" 2>/dev/null; then
            LEAKED=$((LEAKED+1))
            LEAKED_LIST="$LEAKED_LIST $LPID"
        fi
    done < <($DB_QUERY "SELECT pid, pid_starttime FROM jobs WHERE run_id=$RUN_ID AND pid IS NOT NULL;")
    if [ "$LEAKED" -eq 0 ]; then
        pass "$TAG/C5: no leaked indexing processes after $TAG"
    else
        fail "$TAG/C5: $LEAKED leaked PID(s) survived $TAG:$LEAKED_LIST"
    fi

    # --- 5. C6: restart with always-open window — new run is opened, prior
    # ORPHANED rows do NOT block the next cycle. Use the stock scheduler
    # (sleep 2) so dispatched jobs complete naturally and we can prove the
    # full RUNNING -> COMPLETED lifecycle for the SAME service.
    echo ""
    echo "--- $TAG/C6: post-signal restart opens a fresh run ---"

    TMP_LOG_2=$(mktemp "/tmp/test_sigterm_mid_window_${SIG}_phase2.XXXXXX.log")
    bash "$BIN_DIR/scheduler.sh" >"$TMP_LOG_2" 2>&1 &
    SCHEDULER_PID_2=$!

    local NEW_RUN_ID=""
    DEADLINE=$(( $(date +%s) + 25 ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        NEW_RUN_ID=$($DB_QUERY "SELECT id FROM runs WHERE id > $RUN_ID ORDER BY id DESC LIMIT 1;" 2>/dev/null)
        [ -n "$NEW_RUN_ID" ] && break
        sleep 1
    done

    if [ -z "$NEW_RUN_ID" ]; then
        fail "$TAG/C6: no new run opened after restart (last_id=$RUN_ID)"
    else
        pass "$TAG/C6: post-signal restart opened run #$NEW_RUN_ID (>$RUN_ID)"
    fi

    # Wait for at least one job in the new run to reach COMPLETED. This proves
    # the dedup query did NOT see the prior ORPHANED rows as already-attempted
    # (they belong to a different run_id), so the same service was redispatched
    # cleanly. sleep 2 + CHECK_INTERVAL=1 + scheduler startup overhead all fit
    # comfortably in 20s.
    local NEW_COMPLETED=0
    if [ -n "$NEW_RUN_ID" ]; then
        DEADLINE=$(( $(date +%s) + 20 ))
        while [ "$(date +%s)" -lt "$DEADLINE" ]; do
            NEW_COMPLETED=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$NEW_RUN_ID AND status='COMPLETED';")
            [ "${NEW_COMPLETED:-0}" -ge 1 ] && break
            sleep 1
        done
        if [ "${NEW_COMPLETED:-0}" -ge 1 ]; then
            pass "$TAG/C6: $NEW_COMPLETED job(s) in new run #$NEW_RUN_ID reached COMPLETED"
        else
            fail "$TAG/C6: no COMPLETED jobs in new run #$NEW_RUN_ID within 20s"
        fi
    fi

    # Tear down phase-2 scheduler before next sub-case.
    if kill -0 "$SCHEDULER_PID_2" 2>/dev/null; then
        kill -TERM "$SCHEDULER_PID_2" 2>/dev/null
        for _ in $(seq 1 10); do
            kill -0 "$SCHEDULER_PID_2" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SCHEDULER_PID_2" 2>/dev/null
        wait "$SCHEDULER_PID_2" 2>/dev/null
    fi
    SCHEDULER_PID_2=""

    # Prior ABORTED run must remain untouched across the restart.
    local PRIOR_STATUS
    PRIOR_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RUN_ID;")
    assert_eq "$TAG/C6: prior run #$RUN_ID stays ABORTED across restart" "ABORTED" "$PRIOR_STATUS"

    # Diagnostic dump if anything failed in this sub-case.
    if [ "$FAIL" -gt 0 ]; then
        echo "--- scheduler log (phase 1, last 40 lines) ---"
        tail -40 "$TMP_LOG" 2>/dev/null
        echo "--- scheduler log (phase 2, last 30 lines) ---"
        tail -30 "$TMP_LOG_2" 2>/dev/null
        echo "--- runs ---"
        $DB_QUERY "SELECT id,status,triggered_by,started_at,ended_at,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
        echo "--- jobs ---"
        $DB_QUERY "SELECT id,service_id,run_id,status,pid,start_time,end_time,message FROM jobs ORDER BY id;"
    fi

    # Cleanup per-subcase tempfiles + DB so the next sub-case starts clean.
    rm -f "$TMP_LOG"; TMP_LOG=""
    rm -f "$TMP_LOG_2"; TMP_LOG_2=""
    cleanup_test_db "$TEST_DB"
    TEST_DB=""
    TRACKED_PIDS=()
}

# Two sub-sections: SIGTERM (operator/systemctl), SIGINT (Ctrl+C).
run_signal_case TERM
run_signal_case INT

print_test_summary
