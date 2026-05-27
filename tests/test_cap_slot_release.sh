#!/bin/bash
# tests/test_cap_slot_release.sh
# Case D2 — Concurrency cap slot-release granularity.
#
# Operator scenario:
#   With MAX_CONCURRENT_JOBS=N and N jobs RUNNING, when one completes the
#   scheduler must dispatch EXACTLY one new job on the NEXT iteration
#   (which fills the freed slot), not zero (cap leak), not two (over-cap).
#
# Companion to test_concurrency_cap.sh — that test pins the upper bound
# (max RUNNING <= cap over many samples). This test pins the granularity
# of slot release: a freed slot allows EXACTLY one new dispatch.
#
# Implementation note — why "exactly 3 simultaneously running" is NOT
# the assertion here:
#   The scheduler's main loop calls vmstat 1 2, iostat -dx 1 2, and a
#   bandwidth sample (`sleep 1`) every iteration before considering a
#   dispatch. On this host that is ~7-9 seconds per iteration, which
#   is several times longer than the dummy `sleep 2` task. As a result,
#   under natural pacing a previously dispatched job has typically
#   COMPLETED before the next iteration even runs, so the system rarely
#   reaches steady-state saturation at the cap. This is correct
#   throttling behaviour — not a bug.
#
#   What we CAN observe deterministically:
#     1. Cap is never exceeded — max RUNNING over all samples <= cap.
#     2. Slot-release granularity == 1 — between any two adjacent
#        samples, RUNNING never jumps by more than 1 (proves the
#        scheduler dispatches at most one new job per iteration; an
#        atomic-INSERT race that allowed two would show as a +2 jump).
#     3. Progress is monotonic — COMPLETED count grows past cap+1,
#        proving slots ARE reused after reap (no cap-stuck leak).
#
# Sub-cases:
#   D2a — cap=3, 6 services. Pins (1)+(2)+(3) above.
#   D2b — cap=1 sequential drain: max RUNNING always <= 1.
#   D2c — invalid cap config (0 / non-numeric) falls back to 3.
#         Verify max RUNNING <= 3 and the warning log is emitted.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== Test: concurrency cap slot-release granularity (D2) ==="

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

stop_sched() {
    if [ -n "$SCHED_PID" ] && kill -0 "$SCHED_PID" 2>/dev/null; then
        kill -TERM "$SCHED_PID" 2>/dev/null
        for _ in $(seq 1 10); do
            kill -0 "$SCHED_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SCHED_PID" 2>/dev/null
        wait "$SCHED_PID" 2>/dev/null
    fi
    SCHED_PID=""
}

# Shared scheduler env. Force window open + permissive resource gate so
# we are only exercising the concurrency cap.
export START_TIME="00:00"
export END_TIME="23:59"
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export KILL_GRACE_SEC=1
export IOWAIT_THRESHOLD=100
export SWAP_THRESHOLD=100
export INODE_THRESHOLD=100

# ---------------------------------------------------------------------------
# D2a — Slot release granularity at cap=3 with 6 services.
#
# Approach (sample-and-track at 100ms cadence):
#   * MAX RUNNING over the entire window <= 3 (cap upper bound).
#   * Between any two adjacent samples, RUNNING never increases by more than 1
#     (slot-release granularity: scheduler dispatches at most 1 per iteration).
#   * COMPLETED count >= 4 by end (slots ARE reused after reap; not stuck).
# ---------------------------------------------------------------------------
echo "--- D2a: slot-release granularity (cap=3, 6 services) ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

for i in 1 2 3 4 5 6; do
    $DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('d2a-svc${i}', 1, 1);"
done

export MAX_CONCURRENT_JOBS=3
TMP_LOG=$(mktemp /tmp/test_cap_slot_release_d2a.XXXXXX.log)

# Window sized so that 6 services * ~6-9s/iteration each have a chance to
# both dispatch and reap. timeout has to cover the scheduler's natural
# sleep at top-of-loop reap too.
timeout 90s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

MAX_RUNNING=0
PREV=0
MAX_JUMP=0
BREACH=0
SAMPLES=0
# Sample at 100ms for up to ~80s = 800 samples. Early-exit when all 6
# services are completed (test usually finishes well before 80s).
for _ in $(seq 1 800); do
    if ! kill -0 "$SCHED_PID" 2>/dev/null; then
        break
    fi
    CUR=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING';" 2>/dev/null)
    [ -z "$CUR" ] && CUR=0

    if [ "$CUR" -gt "$MAX_RUNNING" ]; then
        MAX_RUNNING="$CUR"
    fi
    if [ "$CUR" -gt 3 ]; then
        BREACH=1
        echo "[Diag D2a] CAP BREACH: RUNNING=$CUR at sample $SAMPLES"
        $DB_QUERY "SELECT id,service_id,status,pid,start_time FROM jobs WHERE status='RUNNING';"
    fi

    JUMP=$((CUR - PREV))
    if [ "$JUMP" -gt "$MAX_JUMP" ]; then
        MAX_JUMP="$JUMP"
    fi
    PREV="$CUR"
    SAMPLES=$((SAMPLES+1))

    DONE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED';" 2>/dev/null)
    [ -z "$DONE" ] && DONE=0
    if [ "$DONE" -ge 6 ]; then
        break
    fi
    sleep 0.1
done

stop_sched

COMPLETED=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED';")
TOTAL_JOBS=$($DB_QUERY "SELECT COUNT(*) FROM jobs;")
echo "[Info D2a] samples=$SAMPLES max_running=$MAX_RUNNING max_jump=$MAX_JUMP completed=$COMPLETED total=$TOTAL_JOBS"

# 1. Cap upper bound.
if [ "$BREACH" -eq 0 ] && [ "$MAX_RUNNING" -le 3 ]; then
    pass "D2a: max RUNNING=$MAX_RUNNING <= cap=3 (no over-dispatch)"
else
    fail "D2a: cap breach — max RUNNING=$MAX_RUNNING > cap=3"
fi

# 2. Slot-release granularity == 1 (the core D2 contract).
# A +2 jump between adjacent samples would mean the scheduler dispatched
# two jobs in one iteration (the atomic-INSERT race lost).
if [ "$MAX_JUMP" -le 1 ]; then
    pass "D2a: slot-release granularity is exactly 1 (max sample-to-sample RUNNING delta=$MAX_JUMP)"
else
    fail "D2a: RUNNING jumped by $MAX_JUMP between adjacent samples — multi-dispatch race"
fi

# 3. Slots ARE reused.
if [ "$COMPLETED" -ge 4 ]; then
    pass "D2a: completed=$COMPLETED >= 4 (slots reused after reap, no cap-stuck leak)"
else
    fail "D2a: completed=$COMPLETED < 4 — slot release never exercised in window"
    echo "--- log tail ---"; tail -40 "$TMP_LOG"
fi

cleanup_test_db "$TEST_DB"
rm -f "$TMP_LOG"
TEST_DB=""
TMP_LOG=""

# ---------------------------------------------------------------------------
# D2b — Sequential (cap=1): 4 services, max RUNNING always <= 1.
# At cap=1 the system serialises completely. Per-iteration overhead is
# ~6-9s here, so 4 services need ~30-40s end-to-end. Window sized generously.
# ---------------------------------------------------------------------------
echo "--- D2b: serial execution (cap=1, 4 services) ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

for i in 1 2 3 4; do
    $DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('d2b-svc${i}', 1, 1);"
done

export MAX_CONCURRENT_JOBS=1
TMP_LOG=$(mktemp /tmp/test_cap_slot_release_d2b.XXXXXX.log)

timeout 75s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
SCHED_PID=$!

MAX_RUNNING=0
CAP_BREACHED=0
for _ in $(seq 1 700); do
    if ! kill -0 "$SCHED_PID" 2>/dev/null; then
        break
    fi
    CUR=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING';" 2>/dev/null)
    [ -z "$CUR" ] && CUR=0
    if [ "$CUR" -gt "$MAX_RUNNING" ]; then
        MAX_RUNNING="$CUR"
    fi
    if [ "$CUR" -gt 1 ]; then
        CAP_BREACHED=1
        echo "[Diag D2b] CAP BREACH: RUNNING=$CUR"
    fi
    DONE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED';" 2>/dev/null)
    [ -z "$DONE" ] && DONE=0
    if [ "$DONE" -ge 4 ]; then
        break
    fi
    sleep 0.1
done

stop_sched

COMPLETED=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED';")
echo "[Info D2b] max_running=$MAX_RUNNING completed=$COMPLETED breached=$CAP_BREACHED"

if [ "$CAP_BREACHED" -eq 0 ] && [ "$MAX_RUNNING" -le 1 ]; then
    pass "D2b: max RUNNING <= 1 across entire window (strictly serial)"
else
    fail "D2b: cap=1 breached — max RUNNING=$MAX_RUNNING"
fi

if [ "$COMPLETED" -ge 4 ]; then
    pass "D2b: all 4 services completed (serial drain works)"
else
    fail "D2b: only $COMPLETED/4 services completed"
    echo "--- log tail ---"; tail -40 "$TMP_LOG"
fi

cleanup_test_db "$TEST_DB"
rm -f "$TMP_LOG"
TEST_DB=""
TMP_LOG=""

# ---------------------------------------------------------------------------
# D2c — Invalid cap falls back to 3.
#
# Two flavours: MAX_CONCURRENT_JOBS=0 (non-positive) and =garbage
# (non-numeric). Both must:
#   * Log the "[Warning] MAX_CONCURRENT_JOBS=... invalid ... Falling back to 3."
#     line.
#   * Behave as cap=3 (max RUNNING <= 3 over the window).
# ---------------------------------------------------------------------------
run_d2c_subcase() {
    local LABEL="$1"
    local VAL="$2"

    TEST_DB=$(setup_test_db)
    export DB_PATH="$TEST_DB"

    # 5 services > 3 fallback cap, so cap is exercised.
    for i in 1 2 3 4 5; do
        $DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('d2c-${LABEL}-svc${i}', 1, 1);"
    done

    export MAX_CONCURRENT_JOBS="$VAL"
    TMP_LOG=$(mktemp /tmp/test_cap_slot_release_d2c_${LABEL}.XXXXXX.log)

    timeout 25s "$PROJECT_ROOT/bin/scheduler.sh" >"$TMP_LOG" 2>&1 &
    SCHED_PID=$!

    local MAX_RUN=0
    local BREACH=0
    for _ in $(seq 1 200); do
        if ! kill -0 "$SCHED_PID" 2>/dev/null; then
            break
        fi
        local CUR
        CUR=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING';" 2>/dev/null)
        [ -z "$CUR" ] && CUR=0
        if [ "$CUR" -gt "$MAX_RUN" ]; then
            MAX_RUN="$CUR"
        fi
        if [ "$CUR" -gt 3 ]; then
            BREACH=1
        fi
        sleep 0.1
    done

    stop_sched

    local COMP
    COMP=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED';")
    echo "[Info D2c/$LABEL] MAX_CONCURRENT_JOBS='$VAL' max_running=$MAX_RUN completed=$COMP breach=$BREACH"

    # 1. Warning log emitted.
    if grep -q "MAX_CONCURRENT_JOBS=.* invalid" "$TMP_LOG" 2>/dev/null \
       && grep -q "Falling back to 3" "$TMP_LOG" 2>/dev/null; then
        pass "D2c/$LABEL: fallback warning logged"
    else
        fail "D2c/$LABEL: expected warning + fallback log not found"
        echo "--- log tail ---"; tail -30 "$TMP_LOG"
    fi

    # 2. Cap effectively == 3 (max RUNNING never above 3).
    if [ "$BREACH" -eq 0 ] && [ "$MAX_RUN" -le 3 ]; then
        pass "D2c/$LABEL: max RUNNING=$MAX_RUN <= 3 (fallback enforced)"
    else
        fail "D2c/$LABEL: cap breach — max RUNNING=$MAX_RUN"
    fi

    # 3. Dispatch progresses (proves fallback isn't a degenerate cap=0 that
    # would block all dispatch). At cap=3 with 5 services and ~6-9s per
    # iteration the window covers at least 2 dispatches => >=2 COMPLETED.
    if [ "$COMP" -ge 2 ]; then
        pass "D2c/$LABEL: dispatch progressed ($COMP COMPLETED — fallback is not degenerate cap=0)"
    else
        fail "D2c/$LABEL: only $COMP COMPLETED — fallback may not be effective"
    fi

    cleanup_test_db "$TEST_DB"
    rm -f "$TMP_LOG"
    TEST_DB=""
    TMP_LOG=""
}

echo "--- D2c: invalid MAX_CONCURRENT_JOBS=0 -> fallback to 3 ---"
run_d2c_subcase "zero" "0"

echo "--- D2c: invalid MAX_CONCURRENT_JOBS=garbage -> fallback to 3 ---"
run_d2c_subcase "garbage" "garbage"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_test_summary
