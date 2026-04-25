#!/bin/bash

# tests/test_threshold_boundary.sh
# Boundary-condition tests for check_thresholds() in monitor.sh.
#
# check_thresholds uses `-gt` (strictly greater than) for every comparison.
# Intent: a metric value equal to its limit is SAFE; only strictly above
# trips a bypass. This test pins that semantic so it doesn't drift to `-ge`.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"
source "$PROJECT_ROOT/bin/monitor.sh"

echo "[Test] check_thresholds boundary semantics (-gt)..."

LIMIT=70

# Helper: run check_thresholds with the metric under test set to VALUE,
# all other shared-LIMIT metrics zero, and specialized thresholds well below
# their defaults so they cannot interfere.
run_at() {
    local pos="$1"; shift
    local val="$1"; shift
    local args=(0 0 0 0 0 0 0 0 0 0)
    args[$((pos - 1))]=$val
    check_thresholds "${args[@]}" "$LIMIT"
    return $?
}

# Position map (1-based): 1=CPU 2=MEM 3=DISK 4=DISKIO 5=NET 6=PROC 7=LOAD
#                         8=IOWAIT 9=SWAP 10=INODE
declare -a SHARED=(CPU MEM DISK DISKIO NET PROC LOAD)

# --- Shared-LIMIT metrics: at LIMIT exactly = SAFE, at LIMIT+1 = BREACH ---
for i in 1 2 3 4 5 6 7; do
    name=${SHARED[$((i - 1))]}

    LAST_BYPASS_REASON=""
    run_at "$i" "$LIMIT"
    rc_eq=$?
    assert_eq "$name at LIMIT ($LIMIT) returns 0" "0" "$rc_eq"
    assert_eq "$name at LIMIT leaves LAST_BYPASS_REASON empty" "" "$LAST_BYPASS_REASON"

    LAST_BYPASS_REASON=""
    run_at "$i" "$((LIMIT + 1))"
    rc_gt=$?
    assert_eq "$name at LIMIT+1 ($((LIMIT + 1))) returns 1" "1" "$rc_gt"
    if [ -n "$LAST_BYPASS_REASON" ]; then
        echo "[Pass] $name at LIMIT+1 populates LAST_BYPASS_REASON ($LAST_BYPASS_REASON)"
        PASS=$((PASS + 1))
    else
        echo "[Fail] $name at LIMIT+1 left LAST_BYPASS_REASON empty"
        FAIL=$((FAIL + 1))
    fi
done

# --- Specialized thresholds: IOWAIT (default 20), SWAP (50), INODE (90) ---
# Use explicit env values so the test does not depend on user .env.
test_specialized() {
    local label="$1"
    local pos="$2"
    local threshold_var="$3"
    local threshold_val="$4"

    LAST_BYPASS_REASON=""
    eval "$threshold_var=$threshold_val" run_at "$pos" "$threshold_val"
    rc_eq=$?
    assert_eq "$label at threshold ($threshold_val) returns 0" "0" "$rc_eq"
    assert_eq "$label at threshold leaves LAST_BYPASS_REASON empty" "" "$LAST_BYPASS_REASON"

    LAST_BYPASS_REASON=""
    eval "$threshold_var=$threshold_val" run_at "$pos" "$((threshold_val + 1))"
    rc_gt=$?
    assert_eq "$label at threshold+1 ($((threshold_val + 1))) returns 1" "1" "$rc_gt"
}

test_specialized "IOWAIT" 8  IOWAIT_THRESHOLD 20
test_specialized "SWAP"   9  SWAP_THRESHOLD   50
test_specialized "INODE"  10 INODE_THRESHOLD  90

# --- Sanity: all-zero call must return 0 and clear bypass reason ---
LAST_BYPASS_REASON="stale"
check_thresholds 0 0 0 0 0 0 0 0 0 0 "$LIMIT"
rc_zero=$?
assert_eq "all-zero metrics return 0" "0" "$rc_zero"
assert_eq "all-zero clears LAST_BYPASS_REASON" "" "$LAST_BYPASS_REASON"

print_test_summary
exit $?
