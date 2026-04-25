#!/bin/bash

# tests/test_kill_grace.sh
# Verify the kill_process_tree extensions added in the M1+M3 follow-up:
#   - Optional EXPECTED_STARTTIME parameter triggers identity re-verification
#     immediately before SIGTERM and again before SIGKILL (TOCTOU window
#     mitigation for stale-expire path).
#   - KILL_GRACE_SEC env var controls the grace duration (default 10s).

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$PROJECT_ROOT/bin/scheduler.sh" --no-run >/dev/null 2>&1

echo "[Test] kill_process_tree starttime + grace extensions..."

# --- 1. Mismatched starttime aborts kill before any signal is sent ---
sleep 30 &
SENTINEL_PID=$!
sleep 0.1
REAL_START=$(get_pid_starttime "$SENTINEL_PID")
WRONG_START=$((REAL_START + 1))

# Single-arg path still works (legacy callers).
# We verify the new path: kill_process_tree PID WRONG_STARTTIME → returns 1
# and does NOT touch the sentinel.
kill_process_tree "$SENTINEL_PID" "$WRONG_START" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ] && kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "[Pass] Mismatched starttime aborts kill (return=1, sentinel alive)"
    PASS=$((PASS + 1))
else
    echo "[Fail] Sentinel killed or wrong return on starttime mismatch (rc=$RC)"
    FAIL=$((FAIL + 1))
fi
kill -KILL "$SENTINEL_PID" 2>/dev/null
wait "$SENTINEL_PID" 2>/dev/null

# --- 2. Matched starttime allows kill ---
sleep 30 &
SENTINEL_PID=$!
sleep 0.1
REAL_START=$(get_pid_starttime "$SENTINEL_PID")

# Use a short grace for the test to keep runtime reasonable
KILL_GRACE_SEC=1 kill_process_tree "$SENTINEL_PID" "$REAL_START" >/dev/null 2>&1
sleep 0.5
if kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "[Fail] Matched-starttime kill did not terminate sentinel"
    FAIL=$((FAIL + 1))
    kill -9 "$SENTINEL_PID" 2>/dev/null
else
    echo "[Pass] Matched starttime allows normal kill"
    PASS=$((PASS + 1))
fi
wait "$SENTINEL_PID" 2>/dev/null

# --- 3. KILL_GRACE_SEC controls timing (we measure the wall-clock gap) ---
# Spawn a process that traps SIGTERM (ignores it) so the grace must elapse
# before SIGKILL takes effect. Measure elapsed time.
( trap '' SIGTERM; sleep 30 ) &
SENTINEL_PID=$!
sleep 0.1
REAL_START=$(get_pid_starttime "$SENTINEL_PID")

START=$(date +%s%N)
KILL_GRACE_SEC=2 kill_process_tree "$SENTINEL_PID" "$REAL_START" >/dev/null 2>&1
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))

# Expect at least 2000ms (grace) but well under 5000ms (no excessive overhead)
if [ "$ELAPSED_MS" -ge 1900 ] && [ "$ELAPSED_MS" -le 5000 ]; then
    echo "[Pass] KILL_GRACE_SEC=2 produced ${ELAPSED_MS}ms wall-clock (1900~5000ms)"
    PASS=$((PASS + 1))
else
    echo "[Fail] KILL_GRACE_SEC=2 elapsed ${ELAPSED_MS}ms (expected 1900~5000ms)"
    FAIL=$((FAIL + 1))
fi
wait "$SENTINEL_PID" 2>/dev/null

# --- 4. Single-arg legacy callers still work (no starttime supplied) ---
sleep 30 &
SENTINEL_PID=$!
sleep 0.1
KILL_GRACE_SEC=1 kill_process_tree "$SENTINEL_PID" >/dev/null 2>&1
sleep 0.5
if kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "[Fail] Legacy single-arg kill did not terminate sentinel"
    FAIL=$((FAIL + 1))
    kill -9 "$SENTINEL_PID" 2>/dev/null
else
    echo "[Pass] Legacy single-arg kill still works"
    PASS=$((PASS + 1))
fi
wait "$SENTINEL_PID" 2>/dev/null

# --- 5. Empty starttime is treated as 'no starttime supplied' (no verification) ---
sleep 30 &
SENTINEL_PID=$!
sleep 0.1
KILL_GRACE_SEC=1 kill_process_tree "$SENTINEL_PID" "" >/dev/null 2>&1
sleep 0.5
if kill -0 "$SENTINEL_PID" 2>/dev/null; then
    echo "[Fail] Empty-starttime call did not terminate sentinel"
    FAIL=$((FAIL + 1))
    kill -9 "$SENTINEL_PID" 2>/dev/null
else
    echo "[Pass] Empty starttime falls back to legacy behavior"
    PASS=$((PASS + 1))
fi
wait "$SENTINEL_PID" 2>/dev/null

print_test_summary
