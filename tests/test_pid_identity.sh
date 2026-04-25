#!/bin/bash

# tests/test_pid_identity.sh
# Verify get_pid_starttime / verify_pid_identity helpers used to defend
# against PID reuse in the scheduler's recovery and stale-expire paths
# (critical issues #1 and #2 of the kill-path review).

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$PROJECT_ROOT/bin/monitor.sh" >/dev/null 2>&1

echo "[Test] PID identity helpers..."

# --- 1. get_pid_starttime returns a positive integer for the current shell ---
SELF_START=$(get_pid_starttime $$)
if [[ "$SELF_START" =~ ^[0-9]+$ ]] && [ "$SELF_START" -gt 0 ]; then
    echo "[Pass] get_pid_starttime(\$\$=$$) returned $SELF_START"
    PASS=$((PASS + 1))
else
    echo "[Fail] get_pid_starttime(\$\$) returned non-integer: '$SELF_START'"
    FAIL=$((FAIL + 1))
fi

# --- 2. get_pid_starttime returns empty for a non-existent PID ---
DEAD_START=$(get_pid_starttime 999999)
if [ -z "$DEAD_START" ]; then
    echo "[Pass] get_pid_starttime(999999) returned empty"
    PASS=$((PASS + 1))
else
    echo "[Fail] get_pid_starttime(999999) returned: '$DEAD_START'"
    FAIL=$((FAIL + 1))
fi

# --- 3. get_pid_starttime returns empty for malformed input ---
for bad in '' 'abc' '12.5' '-1' '0x10'; do
    R=$(get_pid_starttime "$bad")
    if [ -z "$R" ]; then
        echo "[Pass] get_pid_starttime('$bad') returned empty"
        PASS=$((PASS + 1))
    else
        echo "[Fail] get_pid_starttime('$bad') returned: '$R'"
        FAIL=$((FAIL + 1))
    fi
done

# --- 4. verify_pid_identity matches for self with correct starttime ---
if verify_pid_identity "$$" "$SELF_START"; then
    echo "[Pass] verify_pid_identity matches self with correct starttime"
    PASS=$((PASS + 1))
else
    echo "[Fail] verify_pid_identity rejected self with correct starttime"
    FAIL=$((FAIL + 1))
fi

# --- 5. verify_pid_identity rejects mismatched starttime (PID reuse defense) ---
if verify_pid_identity "$$" "1"; then
    echo "[Fail] verify_pid_identity accepted self with wrong starttime '1'"
    FAIL=$((FAIL + 1))
else
    echo "[Pass] verify_pid_identity rejected wrong starttime"
    PASS=$((PASS + 1))
fi

# --- 6. verify_pid_identity rejects non-existent PID ---
if verify_pid_identity 999999 12345; then
    echo "[Fail] verify_pid_identity accepted non-existent PID"
    FAIL=$((FAIL + 1))
else
    echo "[Pass] verify_pid_identity rejected non-existent PID"
    PASS=$((PASS + 1))
fi

# --- 7. verify_pid_identity rejects malformed inputs ---
for bad_pair in "'' ''" "'abc' '123'" "'$$' 'xyz'" "'$$' ''" "'' '$SELF_START'"; do
    eval "args=($bad_pair)"
    if verify_pid_identity "${args[0]}" "${args[1]}"; then
        echo "[Fail] verify_pid_identity accepted malformed input: ${args[*]}"
        FAIL=$((FAIL + 1))
    else
        echo "[Pass] verify_pid_identity rejected malformed input: ${args[*]}"
        PASS=$((PASS + 1))
    fi
done

# --- 8. Realistic PID-reuse scenario: child's starttime persists, lookup with
#       wrong starttime fails even if PID happens to still exist ---
sleep 30 &
CHILD_PID=$!
sleep 0.1
CHILD_START=$(get_pid_starttime "$CHILD_PID")
if [ -z "$CHILD_START" ]; then
    echo "[Fail] could not capture child starttime"
    FAIL=$((FAIL + 1))
else
    if verify_pid_identity "$CHILD_PID" "$CHILD_START"; then
        echo "[Pass] verify_pid_identity matches live child"
        PASS=$((PASS + 1))
    else
        echo "[Fail] verify_pid_identity failed live child"
        FAIL=$((FAIL + 1))
    fi
    # Simulate "recycled to different process" by checking with a fake earlier starttime
    if verify_pid_identity "$CHILD_PID" "$((CHILD_START - 1))"; then
        echo "[Fail] verify_pid_identity accepted off-by-one starttime (no PID-reuse defense)"
        FAIL=$((FAIL + 1))
    else
        echo "[Pass] verify_pid_identity rejected off-by-one starttime"
        PASS=$((PASS + 1))
    fi
fi
kill -KILL "$CHILD_PID" 2>/dev/null
wait "$CHILD_PID" 2>/dev/null

print_test_summary
