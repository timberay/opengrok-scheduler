#!/bin/bash
# tests/test_no_rerun_same_session.sh
# Case E1 — A completed cycle must not re-run within the same window session.
#
# Bug reproduced:
#   Once every active service has been indexed and the run closes COMPLETED,
#   the main loop's next iteration found no RUNNING run and re-opened a fresh
#   run, re-dispatching every service all over again — within the same night.
#   The user-visible symptom: "jobs run again at some point on the same day;
#   shouldn't a completed cycle wait until the next day?"
#
# Contract verified:
#   A. INTEGRATION — with an always-open window the scheduler completes exactly
#      ONE cycle and then idles. After the run closes COMPLETED, letting the
#      loop tick many more times must NOT create a second run row nor a second
#      job row per service.
#   B. UNIT — current_window_start_dt resolves the most-recent window-start
#      boundary correctly, including the cross-midnight case (the morning part
#      of an 18:00->06:00 window belongs to the *previous* day's session).

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== Test: completed cycle does not re-run in same session (E1) ==="

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

# --- Part B: unit coverage of the window-start boundary -------------------
# Source the script without running the main loop so we can call the helper
# directly. CURRENT is injected so the cross-midnight branch is deterministic.
source "$PROJECT_ROOT/bin/scheduler.sh" --no-run

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

WS_EVENING=$(current_window_start_dt "18:00" "06:00" "20:00")
assert_eq "B: cross-midnight evening part resolves to today's START" \
    "$TODAY 18:00:00" "$WS_EVENING"

WS_MORNING=$(current_window_start_dt "18:00" "06:00" "02:00")
assert_eq "B: cross-midnight morning part resolves to yesterday's START" \
    "$YESTERDAY 18:00:00" "$WS_MORNING"

WS_SAMEDAY=$(current_window_start_dt "09:00" "17:00" "12:00")
assert_eq "B: same-day window resolves to today's START" \
    "$TODAY 09:00:00" "$WS_SAMEDAY"

# --- Part A: integration — one cycle, then idle ---------------------------
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

TMP_LOG=$(mktemp /tmp/test_no_rerun_same_session.XXXXXX.log)

timeout 40s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

# Wait for the first run to close COMPLETED.
DEADLINE=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    RUN_STATUS=$($DB_QUERY "SELECT status FROM runs ORDER BY id DESC LIMIT 1;" 2>/dev/null)
    [ "$RUN_STATUS" = "COMPLETED" ] && break
    sleep 1
done

FIRST_RUN_STATUS=$($DB_QUERY "SELECT status FROM runs ORDER BY id DESC LIMIT 1;")
assert_eq "A: first cycle reaches COMPLETED" "COMPLETED" "$FIRST_RUN_STATUS"

# Now the smoking gun: let the loop keep ticking well past completion.
# CHECK_INTERVAL=1, so 10s is ~10 more iterations — plenty for the buggy
# path to open a second run and re-dispatch every service.
sleep 10

RUN_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM runs;")
assert_eq "A: still exactly ONE run after idling past completion" "1" "$RUN_COUNT"

JOB_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
assert_eq "A: exactly one job per service, no re-dispatch" "2" "$JOB_COUNT"

# Stop the scheduler cleanly.
if kill -0 "$SCHED_PID" 2>/dev/null; then
    kill -TERM "$SCHED_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$SCHED_PID" 2>/dev/null || break
        sleep 1
    done
    wait "$SCHED_PID" 2>/dev/null
fi
SCHED_PID=""

if [ "$FAIL" -gt 0 ]; then
    echo "--- scheduler log (last 50 lines) ---"
    tail -50 "$TMP_LOG"
    echo "--- runs table ---"
    $DB_QUERY "SELECT id,status,triggered_by,started_at,ended_at FROM runs;"
    echo "--- jobs table ---"
    $DB_QUERY "SELECT id,service_id,run_id,status FROM jobs;"
fi

print_test_summary
