#!/bin/bash
# tests/test_window_end_drain.sh
#
# Regression: when the scheduling window closes with jobs still in flight,
# the previous implementation only marked the `runs` row PARTIAL — `jobs`
# rows stayed in 'RUNNING' status (relying on the 2× JOB_TIMEOUT_SEC stale
# auto-expire) and the underlying background processes kept running after
# hours. After a scheduler restart that left BG_PIDS empty, the next
# window could re-dispatch the same services because the dedup query is
# scoped per run_id.
#
# The fix introduces `drain_bg_jobs` (shared with cleanup_and_exit): for
# every PID tracked in BG_PIDS, kill the process tree and transition the
# DB row to a terminal status with an explanatory message.

source "$(dirname "$0")/test_helper.sh"

echo "=== Test: drain_bg_jobs terminates tracked jobs and updates DB ==="

TEST_DB=$(setup_test_db); export DB_PATH="$TEST_DB"
# Short kill-grace so the test does not block on the SIGTERM→SIGKILL gap.
export KILL_GRACE_SEC=1
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('svc-x',1);"

source "$SCHEDULER" --no-run

if ! type drain_bg_jobs >/dev/null 2>&1; then
    FAIL=$((FAIL+1)); echo "[Fail] drain_bg_jobs helper missing (Fix 2 not applied)"
    cleanup_test_db "$TEST_DB"
    print_test_summary
    exit $?
fi

# Set up the BG_PIDS family in this test's scope; bash's dynamic scoping
# lets drain_bg_jobs read them. Mirrors the arrays the main loop maintains.
declare -A BG_PIDS BG_PREV_STATE BG_LAST_CPU BG_IDLE_SINCE

# Spawn a long-running child that ignores SIGTERM — same trap pattern the
# real scheduler wraps its background tasks in, so this exercises the
# SIGTERM→SIGKILL escalation path inside kill_process_tree.
( trap '' SIGTERM SIGINT; sleep 60 ) &
CHILD=$!
BG_PIDS["svc-x"]=$CHILD
BG_PREV_STATE["svc-x"]="RUNNING"

# Open a run and record the matching RUNNING job row (UPDATE finds it by PID).
RID=$(run_open_if_none auto)
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, pid)
           VALUES (1, $RID, 'RUNNING', datetime('now','localtime'), $CHILD);"

if kill -0 $CHILD 2>/dev/null; then
    PASS=$((PASS+1)); echo "[Pass] pre-condition: child PID=$CHILD alive"
else
    FAIL=$((FAIL+1)); echo "[Fail] pre-condition: child PID=$CHILD already dead"
fi

drain_bg_jobs ORPHANED "Window closed"

assert_eq "BG_PIDS cleared after drain" "0" "${#BG_PIDS[@]}"
assert_eq "BG_PREV_STATE cleared after drain" "0" "${#BG_PREV_STATE[@]}"

STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE pid=$CHILD;")
assert_eq "job row transitioned to ORPHANED" "ORPHANED" "$STATUS"

MSG=$($DB_QUERY "SELECT message FROM jobs WHERE pid=$CHILD;")
assert_eq "job message reflects window-close reason" "Window closed" "$MSG"

ENDED=$($DB_QUERY "SELECT end_time IS NOT NULL FROM jobs WHERE pid=$CHILD;")
assert_eq "end_time stamped on drained job" "1" "$ENDED"

# After SIGKILL escalation (KILL_GRACE_SEC=1) the process must be gone.
sleep 2
if kill -0 $CHILD 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "[Fail] child PID=$CHILD still alive after drain"
    kill -9 $CHILD 2>/dev/null
else
    PASS=$((PASS+1)); echo "[Pass] child terminated by drain"
fi

# Bad status arg must be rejected (we never want SQL injection-grade
# free-form status values reaching the UPDATE).
if drain_bg_jobs BOGUS "x" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "[Fail] drain_bg_jobs accepted invalid status"
else
    PASS=$((PASS+1)); echo "[Pass] drain_bg_jobs rejects invalid status"
fi

cleanup_test_db "$TEST_DB"

echo "--- Stale RUNNING regression: window-close path no longer leaves zombies ---"

# Reproduce the cross-cycle symptom: after window-close drain + PARTIAL close,
# (a) no RUNNING job row remains, (b) opening the next run does not see any
# leftover in-flight state, and (c) the service is eligible again — but
# safely, because the old row is terminal.
TEST_DB2=$(setup_test_db); export DB_PATH="$TEST_DB2"
export KILL_GRACE_SEC=1
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('svc-y',1);"
unset BG_PIDS BG_PREV_STATE BG_LAST_CPU BG_IDLE_SINCE
declare -A BG_PIDS BG_PREV_STATE BG_LAST_CPU BG_IDLE_SINCE

( trap '' SIGTERM SIGINT; sleep 60 ) &
CHILD2=$!
BG_PIDS["svc-y"]=$CHILD2
BG_PREV_STATE["svc-y"]="RUNNING"

R1=$(run_open_if_none auto)
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, pid)
           VALUES (1, $R1, 'RUNNING', datetime('now','localtime'), $CHILD2);"

# Simulate the window-close branch: drain, then PARTIAL.
drain_bg_jobs ORPHANED "Window closed"
run_close "$R1" PARTIAL

LEFT=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE run_id=$R1 AND status='RUNNING';")
assert_eq "no RUNNING rows remain in closed run" "0" "$LEFT"

R1_STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$R1;")
assert_eq "run #1 marked PARTIAL" "PARTIAL" "$R1_STATUS"

# Next window: a fresh run opens, service is eligible — and dispatching it
# now is safe because the prior row is terminal (no risk of duplicate live
# process under the same service).
R2=$(run_open_if_none auto)
[ "$R2" -gt "$R1" ] && PASS=$((PASS+1)) && echo "[Pass] next window opens a new run id" \
                    || { FAIL=$((FAIL+1)); echo "[Fail] next run id did not advance ($R2 vs $R1)"; }

ELIGIBLE=$($DB_QUERY "SELECT s.container_name FROM services s
                      WHERE s.is_active=1
                      AND NOT EXISTS (
                          SELECT 1 FROM jobs j WHERE j.service_id=s.id AND j.run_id=$R2
                      ) LIMIT 1;")
assert_eq "service re-eligible in next run (terminal prior row)" "svc-y" "$ELIGIBLE"

# Safety: there must be no orphan process from R1 still consuming resources.
sleep 1
if kill -0 $CHILD2 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "[Fail] R1 child PID=$CHILD2 still alive across windows"
    kill -9 $CHILD2 2>/dev/null
else
    PASS=$((PASS+1)); echo "[Pass] R1 child reaped before R2 dispatch"
fi

cleanup_test_db "$TEST_DB2"
print_test_summary
