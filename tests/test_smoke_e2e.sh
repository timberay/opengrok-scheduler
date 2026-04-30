#!/bin/bash
# Smoke test: exercises the production scheduler.sh end-to-end on an isolated
# DB to catch regressions the unit suite does not cover.
#
# Cases:
#   1. --status on a fresh DB (no crashes, "(no runs yet)" fallback).
#   2. --service <stub> reaches the workload path and creates a job row.
#   3. Main loop opens a run, closes it COMPLETED on natural completion.
#   4. Main loop closes the open run as PARTIAL when window ends with
#      pending services. This is the integration path the unit tests skip
#      (test_run_lifecycle.sh only invokes run_close PARTIAL directly).

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

PASS=0
FAIL=0

pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

cleanup() {
    [ -n "${SMOKE_DB:-}" ] && cleanup_test_db "$SMOKE_DB" 2>/dev/null
    [ -n "${TMP_SCHED:-}" ] && [ -f "$TMP_SCHED" ] && rm -f "$TMP_SCHED"
    [ -n "${SCHED_PID:-}" ] && kill -9 "$SCHED_PID" 2>/dev/null
    pkill -P $$ 2>/dev/null
}
trap cleanup EXIT

# -----------------------------------------------------------------------
# Case 1: --status on fresh DB
# -----------------------------------------------------------------------
echo "=== Case 1: --status on fresh DB ==="
SMOKE_DB=$(setup_test_db)
export DB_PATH="$SMOKE_DB"
OUT=$("$PROJECT_ROOT/bin/scheduler.sh" --status 2>&1)
RC=$?
[ $RC -eq 0 ] && pass "--status returns 0 on fresh DB" || fail "--status rc=$RC ($OUT)"
echo "$OUT" | grep -q "no runs yet" && pass "fresh DB shows '(no runs yet)' fallback" || fail "missing fallback"
cleanup_test_db "$SMOKE_DB"

# -----------------------------------------------------------------------
# Case 2: --service stub_container creates a job row
# -----------------------------------------------------------------------
echo "=== Case 2: --service path creates a job row ==="
SMOKE_DB=$(setup_test_db)
export DB_PATH="$SMOKE_DB"
"$PROJECT_ROOT/bin/db_query.sh" "INSERT INTO services (container_name, priority) VALUES ('stub-svc', 1);" >/dev/null

# Use a temp scheduler copy with run_indexing_task stubbed to a quick true so
# the path exercises real admission + run_id pinning without needing Docker.
TMP_SCHED="$PROJECT_ROOT/bin/scheduler_smoke_$$.sh"
sed 's|^run_indexing_task() {.*|run_indexing_task() { sleep 1; return 0;|' \
    "$PROJECT_ROOT/bin/scheduler.sh" > "$TMP_SCHED"
chmod +x "$TMP_SCHED"

DB_PATH="$SMOKE_DB" timeout 15s "$TMP_SCHED" --service stub-svc >/dev/null 2>&1
sleep 2
JOB_ROW=$("$PROJECT_ROOT/bin/db_query.sh" "SELECT status, run_id FROM jobs WHERE service_id=1;")
echo "  job row: $JOB_ROW"
echo "$JOB_ROW" | grep -q "COMPLETED" && pass "--service produced COMPLETED job" || fail "--service did not complete (got: $JOB_ROW)"
echo "$JOB_ROW" | awk -F'|' '{print $2}' | grep -qE "^$" && pass "--service pins run_id=NULL" || fail "--service run_id leaked"
rm -f "$TMP_SCHED"
cleanup_test_db "$SMOKE_DB"

# -----------------------------------------------------------------------
# Case 3: Main loop opens run + closes COMPLETED naturally
# -----------------------------------------------------------------------
echo "=== Case 3: Main loop COMPLETED close ==="
SMOKE_DB=$(setup_test_db)
export DB_PATH="$SMOKE_DB"
"$PROJECT_ROOT/bin/db_query.sh" "INSERT INTO services (container_name) VALUES ('stub-a'),('stub-b');" >/dev/null

TMP_SCHED="$PROJECT_ROOT/bin/scheduler_smoke_$$.sh"
sed 's|^run_indexing_task() {.*|run_indexing_task() { sleep 1; return 0;|' \
    "$PROJECT_ROOT/bin/scheduler.sh" > "$TMP_SCHED"
chmod +x "$TMP_SCHED"

# Window that includes "now" so the loop will admit jobs.
NOW_HM=$(date +%H:%M)
END_HM=$(date -d "+5 minutes" +%H:%M)

DB_PATH="$SMOKE_DB" CHECK_INTERVAL=2 START_TIME="$NOW_HM" END_TIME="$END_HM" \
    "$TMP_SCHED" >/tmp/smoke_c3.log 2>&1 &
SCHED_PID=$!

# Poll for the run to close COMPLETED
for i in $(seq 1 30); do
    STATUS=$("$PROJECT_ROOT/bin/db_query.sh" "SELECT status FROM runs ORDER BY id DESC LIMIT 1;" 2>/dev/null)
    [ "$STATUS" = "COMPLETED" ] && break
    sleep 1
done
kill -TERM "$SCHED_PID" 2>/dev/null; wait "$SCHED_PID" 2>/dev/null
SCHED_PID=""

[ "$STATUS" = "COMPLETED" ] && pass "main loop closes run COMPLETED naturally" || fail "run did not reach COMPLETED (got: $STATUS)"
COMPLETED_COUNT=$("$PROJECT_ROOT/bin/db_query.sh" "SELECT completed_count FROM runs ORDER BY id DESC LIMIT 1;")
[ "$COMPLETED_COUNT" = "2" ] && pass "completed_count=2 (both services)" || fail "completed_count=$COMPLETED_COUNT (expected 2)"
rm -f "$TMP_SCHED"
cleanup_test_db "$SMOKE_DB"

# -----------------------------------------------------------------------
# Case 4: PARTIAL on window exit (the integration path uncovered by unit tests)
# -----------------------------------------------------------------------
echo "=== Case 4: Main loop PARTIAL on window exit ==="
SMOKE_DB=$(setup_test_db)
export DB_PATH="$SMOKE_DB"
"$PROJECT_ROOT/bin/db_query.sh" "INSERT INTO services (container_name) VALUES ('slow-a'),('slow-b'),('slow-c');" >/dev/null

# Use a slow stub so services can't all finish before the window ends.
TMP_SCHED="$PROJECT_ROOT/bin/scheduler_smoke_$$.sh"
sed 's|^run_indexing_task() {.*|run_indexing_task() { sleep 30; return 0;|' \
    "$PROJECT_ROOT/bin/scheduler.sh" > "$TMP_SCHED"
chmod +x "$TMP_SCHED"

# Tight window: starts now, ends in ~20s, so the main loop will exit window
# while at least 2 services are still pending (MAX_CONCURRENT_JOBS=1, sleep 30).
NOW_HM=$(date +%H:%M)
END_HM=$(date -d "+1 minute" +%H:%M)
WINDOW_DEADLINE_S=$(date -d "$END_HM" +%s)
NOW_S=$(date +%s)

DB_PATH="$SMOKE_DB" CHECK_INTERVAL=3 MAX_CONCURRENT_JOBS=1 \
    START_TIME="$NOW_HM" END_TIME="$END_HM" \
    "$TMP_SCHED" >/tmp/smoke_c4.log 2>&1 &
SCHED_PID=$!

# Wait until 5 seconds past the window end, then poll briefly for PARTIAL.
WAIT_UNTIL=$(( WINDOW_DEADLINE_S - NOW_S + 8 ))
sleep "$WAIT_UNTIL"

for i in $(seq 1 10); do
    STATUS=$("$PROJECT_ROOT/bin/db_query.sh" "SELECT status FROM runs ORDER BY id DESC LIMIT 1;" 2>/dev/null)
    [ "$STATUS" = "PARTIAL" ] && break
    sleep 1
done

kill -TERM "$SCHED_PID" 2>/dev/null; wait "$SCHED_PID" 2>/dev/null
SCHED_PID=""

if [ "$STATUS" = "PARTIAL" ]; then
    pass "main loop closes run PARTIAL on window exit"
else
    fail "run did not reach PARTIAL (got: $STATUS)"
    echo "--- last 20 lines of scheduler log ---"
    tail -20 /tmp/smoke_c4.log
fi

rm -f "$TMP_SCHED" /tmp/smoke_c3.log /tmp/smoke_c4.log
cleanup_test_db "$SMOKE_DB"

# -----------------------------------------------------------------------
echo
echo "=========================================="
echo "Smoke test results: $PASS passed, $FAIL failed"
echo "=========================================="
exit $FAIL
