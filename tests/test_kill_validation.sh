#!/bin/bash

# tests/test_kill_validation.sh
# Verify kill_process_tree refuses invalid/reserved PIDs that would otherwise
# cause scheduler-suicide (PID 0) or mass-termination of init's children (PID 1).

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

# Source scheduler.sh in --no-run mode so we can call kill_process_tree directly
# without entering the main loop.
source "$PROJECT_ROOT/bin/scheduler.sh" --no-run >/dev/null 2>&1

echo "[Test] kill_process_tree input validation..."

# --- Bad PIDs: must be refused, return non-zero, send no signals ---
# Run each bad-PID call inside a fresh setsid'd subshell. If the guard is
# missing, kill -TERM 0 would broadcast to the subshell's PG (killing it
# before it can print REFUSED=...), so absence of REFUSED= line indicates
# the guard is missing or broken.
for bad_pid in '' '0' '1' '-1' 'abc' '12.5' '0x10' '99999999999999999999'; do
    OUTPUT=$(setsid bash -c "
        source '$PROJECT_ROOT/bin/scheduler.sh' --no-run >/dev/null 2>&1
        kill_process_tree '$bad_pid' 2>/dev/null
        echo \"REFUSED=\$?\"
    " 2>&1)
    RET=$(echo "$OUTPUT" | grep -oE 'REFUSED=[0-9]+' | tail -1 | cut -d= -f2)
    if [ "$RET" = "1" ]; then
        echo "[Pass] Refused bad PID: '$bad_pid'"
        PASS=$((PASS + 1))
    else
        echo "[Fail] Did not refuse bad PID: '$bad_pid' (got REFUSED=$RET, output: $OUTPUT)"
        FAIL=$((FAIL + 1))
    fi
done

# --- Valid PID: must still be killed cleanly ---
sleep 30 &
SLEEP_PID=$!
# Give it a moment to actually exec
sleep 0.1
if ! kill -0 "$SLEEP_PID" 2>/dev/null; then
    echo "[Fail] Sentinel sleep $SLEEP_PID did not start"
    FAIL=$((FAIL + 1))
else
    kill_process_tree "$SLEEP_PID" >/dev/null 2>&1
    RET=$?
    # kill_process_tree includes a 3s grace period, then SIGKILL
    sleep 0.5
    if kill -0 "$SLEEP_PID" 2>/dev/null; then
        # Wait out the grace
        wait "$SLEEP_PID" 2>/dev/null
    fi
    if kill -0 "$SLEEP_PID" 2>/dev/null; then
        echo "[Fail] Valid PID was not killed (PID=$SLEEP_PID still alive)"
        FAIL=$((FAIL + 1))
        kill -9 "$SLEEP_PID" 2>/dev/null
    else
        echo "[Pass] Valid PID killed (PID=$SLEEP_PID, return=$RET)"
        PASS=$((PASS + 1))
    fi
    wait "$SLEEP_PID" 2>/dev/null
fi

# --- Injection attempt: PID column contains shell metacharacters ---
INJECT_PROBE="$PROJECT_ROOT/data/.kill_validation_injection_probe_$$"
rm -f "$INJECT_PROBE"
OUTPUT=$(setsid bash -c "
    source '$PROJECT_ROOT/bin/scheduler.sh' --no-run >/dev/null 2>&1
    kill_process_tree '1; touch $INJECT_PROBE' 2>/dev/null
    echo \"REFUSED=\$?\"
" 2>&1)
if [ -e "$INJECT_PROBE" ]; then
    echo "[Fail] Shell metacharacters in PID triggered command execution"
    FAIL=$((FAIL + 1))
    rm -f "$INJECT_PROBE"
else
    echo "[Pass] Shell metacharacters in PID rejected without execution"
    PASS=$((PASS + 1))
fi

print_test_summary
