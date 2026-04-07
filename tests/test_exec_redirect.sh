#!/bin/bash

# tests/test_exec_redirect.sh
# Test that run_indexing_task does not permanently redirect stderr

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

pass() { echo "[Pass] $1"; ((PASS++)); }
fail() { echo "[Fail] $1"; ((FAIL++)); }

echo "=============================="
echo "[Test] exec Redirect Fix"
echo "=============================="

# Source scheduler without entering main loop
source "$PROJECT_ROOT/bin/scheduler.sh" --no-run 2>/dev/null

# --- Case 1: stderr still works after run_indexing_task ---
echo ""
echo "[Case 1] stderr is preserved after run_indexing_task call"

# Redirect stdout to a temp file so we can detect if exec 2>&1 leaks stderr into it
TMPFILE=$(mktemp)
exec 3>&1           # save original stdout to fd 3
exec 1>"$TMPFILE"   # stdout now goes to file

# Call run_indexing_task — if exec 2>&1 is inside, fd 2 becomes a dup of fd 1 (the file)
run_indexing_task "test_container"

# Write to stderr — if exec leaked, this goes to the file (fd 1)
echo "STDERR_LEAK_MARKER" >&2

exec 1>&3           # restore stdout from fd 3
exec 3>&-           # close saved fd

# Check if the stderr marker ended up in the stdout file
if grep -q "STDERR_LEAK_MARKER" "$TMPFILE"; then
    fail "stderr was redirected to stdout after run_indexing_task (exec leak detected)"
else
    pass "stderr is still independent after run_indexing_task"
fi

rm -f "$TMPFILE"

print_test_summary
exit $?
