#!/bin/bash
# tests/test_failed_then_retry_next_cycle.sh
# Case C3 — Service that FAILED in cycle N is retried in cycle N+1.
#
# Operator scenario:
#   svc-flaky fails (non-zero exit) in run #1. Operator does NOTHING — no
#   manual --service intervention, no service edit. Run #1 closes (COMPLETED
#   if every service has a terminal row, PARTIAL otherwise). When the next
#   window opens run #2, svc-flaky must be eligible again, get dispatched,
#   and (assuming the failure was transient) reach COMPLETED.
#
# Pinned contract:
#   1. Run #1 has a row for svc-flaky with status='FAILED' and a non-null
#      message (e.g. "Exit code 7"). This is the seed state of the test.
#   2. Inside run #1, NEXT_SERVICE_ID does NOT return svc-flaky again — the
#      per-run dedup pin (see test_dedup_by_run.sh) treats every terminal
#      status, FAILED included, as "already attempted in this run".
#   3. Run #1 closes cleanly (COMPLETED if every active service has a
#      terminal row; otherwise PARTIAL would close it on window exit). For
#      this test we seed both svc-good=COMPLETED and svc-flaky=FAILED so
#      the natural-close path applies.
#   4. Run #2 opens cleanly on the next loop iteration (window is wide open).
#   5. svc-flaky gets a fresh row in run #2 and reaches COMPLETED — the
#      dummy run_indexing_task is `sleep 2` which exits 0, so a transient
#      failure recovers naturally.
#   6. Per-run counters: run #2's failed_count is 0 (it does NOT inherit
#      run #1's failure), and completed_count is 2.
#   7. Operator-visible: --status during run #2 shows svc-flaky as COMPLETED
#      in the latest-run table (not as the stale FAILED from run #1).
#
# Method (per orchestrator brief, Option A):
#   We do NOT patch run_indexing_task to inject a real failure — that would
#   conflate "how to fail a job" with "how cross-cycle retry behaves".
#   Instead we manually seed the FAILED row for run #1 via SQL, close
#   run #1, then launch the scheduler and verify run #2 picks svc-flaky
#   up and runs it to COMPLETED via the unmodified dummy task.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== Test: FAILED in cycle N retries in cycle N+1 (C3) ==="

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

# Poll DB until $1 (a sqlite expression) equals $2, up to $3 seconds.
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
# Setup: isolated DB with two services. svc-flaky is the one we'll fail in
# run #1; svc-good is the control that completes normally.
# ---------------------------------------------------------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-good',  1, 1),
    ('svc-flaky', 1, 1);"

GOOD_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-good';")
FLAKY_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-flaky';")

# ---------------------------------------------------------------------------
# Seed run #1 via the same helpers the main loop uses: open the run, then
# write a COMPLETED row for svc-good and a FAILED row for svc-flaky. This
# mirrors exactly the rows reap_bg_processes would write on a non-zero exit
# (status='FAILED', message='Exit code N', process_state='EXITED'). Finally
# close run #1 COMPLETED via run_close so its aggregate counters get filled.
# ---------------------------------------------------------------------------
source "$SCHEDULER" --no-run

R1=$(run_open_if_none auto)
[ -n "$R1" ] && pass "C3-setup: run #$R1 opened for seed" \
             || fail "C3-setup: run_open_if_none returned empty"

# Snapshot of seed-time total_services. With both services active at open
# time we expect 2.
R1_TOTAL=$($DB_QUERY "SELECT total_services FROM runs WHERE id=$R1;")
assert_eq "C3-setup: run #1 total_services=2" "2" "$R1_TOTAL"

# svc-good COMPLETED in run #1.
$DB_QUERY "INSERT INTO jobs (service_id, run_id, status, process_state, start_time, end_time, duration)
           VALUES ($GOOD_ID, $R1, 'COMPLETED', 'EXITED',
                   datetime('now','localtime','-30 seconds'),
                   datetime('now','localtime'),
                   30);"

# svc-flaky FAILED in run #1 with the same row shape reap_bg_processes writes.
$DB_QUERY "INSERT INTO jobs (service_id, run_id, status, process_state, start_time, end_time, duration, message)
           VALUES ($FLAKY_ID, $R1, 'FAILED', 'EXITED',
                   datetime('now','localtime','-30 seconds'),
                   datetime('now','localtime'),
                   30,
                   'Exit code 7');"

# Contract 1: svc-flaky row in run #1 is FAILED with a non-null message.
FLAKY_STATUS_R1=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$FLAKY_ID AND run_id=$R1;")
assert_eq "C3-1: svc-flaky has status FAILED in run #$R1" "FAILED" "$FLAKY_STATUS_R1"

FLAKY_MSG_R1=$($DB_QUERY "SELECT message FROM jobs WHERE service_id=$FLAKY_ID AND run_id=$R1;")
[ -n "$FLAKY_MSG_R1" ] && pass "C3-1: svc-flaky FAILED row has non-null message ('$FLAKY_MSG_R1')" \
                      || fail "C3-1: svc-flaky FAILED row has empty message"

# Contract 2: NEXT_SERVICE_ID inside run #1 does NOT return svc-flaky. We
# run the same dedup predicate the main loop uses (see scheduler.sh ~879).
# With both services already having a row, the result must be empty.
NEXT_IN_R1=$($DB_QUERY "SELECT s.id FROM services s
                        WHERE s.is_active=1
                        AND NOT EXISTS (
                            SELECT 1 FROM jobs j
                            WHERE j.service_id = s.id
                            AND j.run_id = $R1
                        )
                        ORDER BY s.priority DESC, s.container_name ASC
                        LIMIT 1;")
assert_eq "C3-2: NEXT_SERVICE_ID for run #$R1 is empty (svc-flaky FAILED still excluded)" "" "$NEXT_IN_R1"

# Contract 3: run #1 closes COMPLETED via the helper. Aggregate counts pick
# up 1 COMPLETED (svc-good) and 1 FAILED (svc-flaky) from the seeded jobs.
run_close "$R1" COMPLETED
R1_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$R1;")
assert_eq "C3-3: run #$R1 closed COMPLETED" "COMPLETED" "$R1_STATUS"

R1_COMPLETED=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$R1;")
assert_eq "C3-3: run #1 completed_count=1 (svc-good)" "1" "$R1_COMPLETED"

R1_FAILED=$($DB_QUERY "SELECT failed_count FROM runs WHERE id=$R1;")
assert_eq "C3-3: run #1 failed_count=1 (svc-flaky)" "1" "$R1_FAILED"

# ---------------------------------------------------------------------------
# Now launch the real scheduler. With window 00:00-23:59 it will immediately
# open run #2, dispatch both services (per-run dedup is per-run so neither
# is excluded by their run #1 rows), and the dummy sleep-2 task completes
# both successfully.
# ---------------------------------------------------------------------------
export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=3
export JOB_IDLE_TIMEOUT=0
export KILL_GRACE_SEC=1

TMP_LOG=$(mktemp /tmp/test_failed_then_retry_next_cycle.XXXXXX.log)

timeout 60s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

# Contract 4: a new RUNNING run (id > R1) appears within a few iterations.
DEADLINE=$(( $(date +%s) + 20 ))
R2=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    R2=$($DB_QUERY "SELECT id FROM runs WHERE id > $R1 AND status IN ('RUNNING','COMPLETED') ORDER BY id ASC LIMIT 1;")
    [ -n "$R2" ] && break
    sleep 1
done

if [ -n "$R2" ]; then
    pass "C3-4: run #$R2 opened cleanly after run #$R1 closed"
else
    fail "C3-4: no follow-on run opened within 20s after run #1 closed"
    echo "--- scheduler log (last 40 lines) ---"
    tail -40 "$TMP_LOG"
    print_test_summary
    exit 1
fi

# Contract 5a: svc-flaky gets a row in run #2.
if poll_db "SELECT COUNT(*) FROM jobs WHERE service_id=$FLAKY_ID AND run_id=$R2;" "1" 25 "svc-flaky dispatched in run #$R2"; then
    pass "C3-5a: svc-flaky dispatched in run #$R2 (per-run dedup does NOT carry FAILED across runs)"
else
    fail "C3-5a: svc-flaky did not get a row in run #$R2 (would indicate cross-run dedup bug)"
fi

# Contract 5b: svc-flaky reaches COMPLETED in run #2 (transient failure recovers).
if poll_db "SELECT status FROM jobs WHERE service_id=$FLAKY_ID AND run_id=$R2;" "COMPLETED" 25 "svc-flaky reaches COMPLETED in run #$R2"; then
    pass "C3-5b: svc-flaky reached COMPLETED in run #$R2 (recovered from prior FAILED)"
else
    fail "C3-5b: svc-flaky did not reach COMPLETED in run #$R2"
fi

# svc-good must also complete in run #2 (sanity: scheduler isn't stuck).
if poll_db "SELECT status FROM jobs WHERE service_id=$GOOD_ID AND run_id=$R2;" "COMPLETED" 25 "svc-good reaches COMPLETED in run #$R2"; then
    pass "C3-5c: svc-good reached COMPLETED in run #$R2 (control)"
else
    fail "C3-5c: svc-good did not reach COMPLETED in run #$R2"
fi

# Run #2 closes COMPLETED once both services have terminal rows.
if poll_db "SELECT status FROM runs WHERE id=$R2;" "COMPLETED" 15 "run #$R2 closes COMPLETED"; then
    pass "C3-5d: run #$R2 closed COMPLETED"
else
    fail "C3-5d: run #$R2 did not close COMPLETED in time"
fi

# Contract 6: run #2's per-run counters are clean — failed_count=0 (run #1's
# failure is not inherited), completed_count=2.
R2_FAILED=$($DB_QUERY "SELECT failed_count FROM runs WHERE id=$R2;")
assert_eq "C3-6: run #2 failed_count=0 (does NOT count run #1's failure)" "0" "$R2_FAILED"

R2_COMPLETED=$($DB_QUERY "SELECT completed_count FROM runs WHERE id=$R2;")
assert_eq "C3-6: run #2 completed_count=2 (both services recovered)" "2" "$R2_COMPLETED"

# Per-run sanity: exactly one row per service in run #2.
R2_JOBS=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$R2;")
assert_eq "C3-6: run #2 has exactly 2 job rows (one per service)" "2" "$R2_JOBS"

R2_DISTINCT=$($DB_QUERY "SELECT COUNT(DISTINCT service_id) FROM jobs WHERE run_id=$R2;")
assert_eq "C3-6: run #2 has 2 distinct services" "2" "$R2_DISTINCT"

# Contract 7: --status surfaces the recovered state. The latest-run table
# scopes the per-service rows to run #2 (the most recent run), so svc-flaky
# must show as COMPLETED there — NOT the stale FAILED from run #1.
STATUS_OUT=$("$PROJECT_ROOT/bin/scheduler.sh" --status 2>/dev/null)
FLAKY_STATUS_LINE=$(echo "$STATUS_OUT" | grep -E '^\s*svc-flaky\s' | head -1)

if echo "$FLAKY_STATUS_LINE" | grep -q "COMPLETED"; then
    pass "C3-7: --status shows svc-flaky=COMPLETED in latest-run view"
else
    fail "C3-7: --status did NOT show svc-flaky=COMPLETED (line: '$FLAKY_STATUS_LINE')"
fi

# Defensive: --status header should reference run #2, not run #1.
if echo "$STATUS_OUT" | head -3 | grep -q "Run #$R2"; then
    pass "C3-7: --status header references latest run #$R2"
else
    fail "C3-7: --status header does NOT reference run #$R2 (output: $(echo "$STATUS_OUT" | head -3))"
fi

# ---------------------------------------------------------------------------
# Stop the scheduler cleanly.
# ---------------------------------------------------------------------------
if kill -0 "$SCHED_PID" 2>/dev/null; then
    kill -TERM "$SCHED_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHED_PID" 2>/dev/null || break
        sleep 1
    done
    wait "$SCHED_PID" 2>/dev/null
fi
SCHED_PID=""

# Diagnostic dump on failure.
if [ "$FAIL" -gt 0 ]; then
    echo "--- scheduler log (last 80 lines) ---"
    tail -80 "$TMP_LOG"
    echo "--- runs ---"
    $DB_QUERY "SELECT id,status,triggered_by,total_services,completed_count,failed_count,timeout_count,orphaned_count FROM runs;"
    echo "--- jobs ---"
    $DB_QUERY "SELECT id,service_id,run_id,status,start_time,end_time,message FROM jobs;"
    echo "--- services ---"
    $DB_QUERY "SELECT id,container_name,is_active FROM services;"
    echo "--- --status output ---"
    echo "$STATUS_OUT"
fi

print_test_summary
