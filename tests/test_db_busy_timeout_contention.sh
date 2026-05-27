#!/bin/bash
# tests/test_db_busy_timeout_contention.sh
# Case D3 — DB busy_timeout actually waits and succeeds under contention.
#
# Operator scenario:
#   Two writers contend on the same SQLite DB. One holds a RESERVED lock
#   (BEGIN IMMEDIATE) for a few seconds; the other's BEGIN IMMEDIATE
#   blocks. With PRAGMA busy_timeout=10000 (set by bin/db_query.sh on
#   every invocation), the waiter must SLEEP — up to 10 s — until the
#   holder commits, then succeed. It must NOT fail immediately with
#   "database is locked", and it must NOT silently drop the write.
#
# This complements tests/test_db_stress.sh:
#   - test_db_stress.sh fires 10 concurrent writers, each with its own
#     in-test retry loop that re-issues the query when it sees "database
#     is locked". It pins "the system can grind through high contention
#     given retries" but does NOT pin "the wrapper waits inside a single
#     invocation" — its retry loop would mask a busy_timeout that wasn't
#     applied. We deliberately do NOT retry here: the wrapper's own
#     busy_timeout MUST carry us through, in one shot.
#   - This test also exercises the actual scheduler --service dispatch
#     path under concurrent contention (D3c), which test_db_stress does
#     not touch.
#
# Contract pinned:
#   D3a — busy_timeout actually waits and the write eventually succeeds.
#     1. Spawn a background sqlite3 process that holds a RESERVED lock
#        for ~3 s via BEGIN IMMEDIATE + .system sleep + COMMIT.
#     2. From the main shell, fire one db_query.sh write. Measure how
#        long it takes.
#     3. Assert: contender exit code = 0, elapsed >= 1 s (so it provably
#        waited, didn't fast-fail), elapsed < 11 s (so the wait stayed
#        within busy_timeout), both writes are durably present, and the
#        contender's stderr contains no "database is locked".
#
#   D3b — busy_timeout is the right MAGNITUDE (sanity check, NOT a
#         full exhaustion test).
#     Re-run the holder for ~3 s with a contender that uses an
#     intentionally LOW busy_timeout=500 ms. That contender MUST fail
#     with "database is locked" (proving busy_timeout is what carries
#     D3a; without it, D3a would fail). We do NOT run a full >10 s
#     exhaustion case here — that would needlessly slow the suite and
#     is well-covered by SQLite's own test suite.
#
#   D3c — concurrent dispatch via the actual scheduler --service path.
#     Two services + one DB. Three parallel `scheduler.sh --service X`
#     invocations (different services, so the per-service guard from
#     B1 does not refuse them and the cap is not the limiter). Assert
#     all three exit 0, all three jobs reach COMPLETED, the wrapper
#     leaks no "database is locked" diagnostic on any of their stderr
#     streams.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== Test: DB busy_timeout under contention (D3) ==="

PASS=0
FAIL=0
pass() { echo "[Pass] $1"; PASS=$((PASS+1)); }
fail() { echo "[Fail] $1"; FAIL=$((FAIL+1)); }

# Track all artefacts so the EXIT trap can sweep them.
HOG_PID=""
TEST_DB=""
TMP_STDERR=""
TMP_HOG_LOG=""
TMP_A=""
TMP_B=""
TMP_C=""

cleanup() {
    if [ -n "$HOG_PID" ] && kill -0 "$HOG_PID" 2>/dev/null; then
        kill -KILL "$HOG_PID" 2>/dev/null
        wait "$HOG_PID" 2>/dev/null
    fi
    [ -n "$TMP_STDERR" ] && rm -f "$TMP_STDERR"
    [ -n "$TMP_HOG_LOG" ] && rm -f "$TMP_HOG_LOG"
    [ -n "$TMP_A" ] && rm -f "$TMP_A"
    [ -n "$TMP_B" ] && rm -f "$TMP_B"
    [ -n "$TMP_C" ] && rm -f "$TMP_C"
    if [ -n "$TEST_DB" ]; then
        cleanup_test_db "$TEST_DB"
    fi
}
trap cleanup EXIT

# Hold a RESERVED write-lock for HOLD_SECS by issuing a transaction whose
# COMMIT is gated on a shell sleep run via sqlite3's `.system` directive.
# This is the only deterministic primitive we have here: sqlite3 has no
# native sleep, and we cannot keep an interactive process attached cleanly
# across a long-running shell test. The `.system sleep N` line yields the
# CLI to the shell for N seconds while the open transaction continues to
# hold the lock; COMMIT runs only after the shell returns.
#
# Args: $1 = DB path, $2 = hold seconds.
# Writes its own PID to $HOG_PID via the caller's scope.
spawn_lock_holder() {
    local DB="$1"
    local HOLD="$2"
    TMP_HOG_LOG=$(mktemp /tmp/d3_lockhog.XXXXXX.log)
    # Use heredoc on stdin. The background process inherits the cwd and
    # env we set above. .bail on makes any earlier error abort the script
    # so the COMMIT never accidentally runs with the lock un-held.
    sqlite3 "$DB" <<SQL >"$TMP_HOG_LOG" 2>&1 &
.bail on
PRAGMA busy_timeout=10000;
PRAGMA journal_mode=WAL;
BEGIN IMMEDIATE;
INSERT INTO services (container_name, priority, is_active) VALUES ('hog-tx', 9, 1);
.system sleep $HOLD
COMMIT;
SQL
    HOG_PID=$!
    # Give the holder a moment to actually issue BEGIN IMMEDIATE before
    # the contender races in. Without this 200 ms grace, the contender
    # can win the lock first and the whole test inverts.
    sleep 0.3
}

# ---------------------------------------------------------------------------
# Shared seed: schema only, plus the env the scheduler --service path needs
# in D3c. Cap is generous so the three parallel --service calls in D3c are
# not throttled by the cap (cap is exercised by other tests).
# ---------------------------------------------------------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
export START_TIME=00:00
export END_TIME=23:59
export CHECK_INTERVAL=1
export RESOURCE_THRESHOLD=100
export MAX_CONCURRENT_JOBS=10
export KILL_GRACE_SEC=1
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

# ---------------------------------------------------------------------------
# D3a — wrapper's busy_timeout=10000 carries the writer through ~3 s of
# contention, no retry needed.
# ---------------------------------------------------------------------------
echo "--- D3a: db_query.sh waits through a 3s lock hog and succeeds ---"

# Bind start row-count BEFORE spawning the holder so we can prove the
# contender's write actually landed (not just the holder's).
PRE_ROWS=$($DB_QUERY "SELECT COUNT(*) FROM services;")

spawn_lock_holder "$TEST_DB" 3

TMP_STDERR=$(mktemp /tmp/d3a_stderr.XXXXXX.log)
T0=$(date +%s.%N)
RESULT=$($DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('contender-d3a', 1, 1);" 2>"$TMP_STDERR")
RC=$?
T1=$(date +%s.%N)
ELAPSED=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')

# Reap the holder so its stderr is flushed before we read it for the
# leak-check. If the COMMIT failed (it should not), the holder's exit
# code surfaces here.
wait "$HOG_PID" 2>/dev/null
HOG_RC=$?
HOG_PID=""

echo "[Info D3a] contender rc=$RC elapsed=${ELAPSED}s hog_rc=$HOG_RC"
echo "[Info D3a] contender stderr: $(cat "$TMP_STDERR" 2>/dev/null)"
echo "[Info D3a] hog stderr: $(cat "$TMP_HOG_LOG" 2>/dev/null)"

# 1. Contender succeeded in one shot.
if [ "$RC" -eq 0 ]; then
    pass "D3a: contender succeeded (rc=0) without in-test retry"
else
    fail "D3a: contender failed (rc=$RC) — busy_timeout did not carry it through"
fi

# 2. It actually WAITED. >=1s proves the wait happened (the wrapper plus
# a real lock hog have ~50-300 ms of intrinsic overhead at zero
# contention, so 1 s is comfortably above noise but well below the 3 s
# hold target). If elapsed < 1 s the lock hog never engaged (regression
# in our test fixture) — surface that loudly.
# Using awk because bash arithmetic does not do floats.
WAITED_OK=$(awk -v e="$ELAPSED" 'BEGIN{print (e >= 1.0 && e < 11.0) ? "yes" : "no"}')
if [ "$WAITED_OK" = "yes" ]; then
    pass "D3a: elapsed ${ELAPSED}s is in [1s, 11s] (waited, then succeeded inside timeout)"
else
    fail "D3a: elapsed ${ELAPSED}s outside expected [1s, 11s] window"
fi

# 3. No "database is locked" leaked to the wrapper's stderr.
if grep -qi "database is locked" "$TMP_STDERR" 2>/dev/null; then
    fail "D3a: wrapper stderr contained 'database is locked' — busy_timeout was ineffective"
    echo "--- stderr ---"; cat "$TMP_STDERR"
else
    pass "D3a: no 'database is locked' in wrapper stderr"
fi

# 4. Both writes are durably present: holder's 'hog-tx' AND contender's
# 'contender-d3a'. PRE_ROWS+2 confirms neither was silently lost.
POST_ROWS=$($DB_QUERY "SELECT COUNT(*) FROM services;")
EXPECTED_ROWS=$((PRE_ROWS + 2))
if [ "$POST_ROWS" = "$EXPECTED_ROWS" ]; then
    pass "D3a: both writes durable (services row count $PRE_ROWS -> $POST_ROWS)"
else
    fail "D3a: row count mismatch — expected $EXPECTED_ROWS, got $POST_ROWS"
    $DB_QUERY "SELECT id, container_name FROM services;"
fi

# Tidy D3a artefacts.
rm -f "$TMP_STDERR" "$TMP_HOG_LOG"
TMP_STDERR=""; TMP_HOG_LOG=""

# Reset to a fresh DB so D3b starts clean (no leftover hog-tx row would
# affect D3b's assertions, but a fresh DB is cleaner and matches the
# isolation pattern other tests use).
cleanup_test_db "$TEST_DB"
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# ---------------------------------------------------------------------------
# D3b — Sanity-check that busy_timeout is the LOAD-BEARING mechanism.
# A bypass-wrapper sqlite3 call with busy_timeout=500ms must FAIL against
# the same 3 s hold. If it didn't, D3a could be passing for the wrong
# reason (e.g., lock was never actually held).
# ---------------------------------------------------------------------------
echo "--- D3b: a sub-second busy_timeout DOES fail against the same hold ---"

spawn_lock_holder "$TEST_DB" 3

TMP_STDERR=$(mktemp /tmp/d3b_stderr.XXXXXX.log)
T0=$(date +%s.%N)
# Deliberately do NOT use db_query.sh — invoke sqlite3 directly with a
# short timeout to bypass the wrapper's 10 s default.
sqlite3 "$TEST_DB" "PRAGMA busy_timeout=500; PRAGMA journal_mode=WAL; BEGIN IMMEDIATE; INSERT INTO services (container_name) VALUES ('contender-d3b'); COMMIT;" >/dev/null 2>"$TMP_STDERR"
SHORT_RC=$?
T1=$(date +%s.%N)
SHORT_ELAPSED=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')

wait "$HOG_PID" 2>/dev/null
HOG_PID=""

echo "[Info D3b] short-timeout rc=$SHORT_RC elapsed=${SHORT_ELAPSED}s"
echo "[Info D3b] short-timeout stderr: $(cat "$TMP_STDERR" 2>/dev/null)"

# Expectation: this MUST fail with a lock error within ~1 s. Both
# conditions must hold for the test to give us a meaningful negative
# control: a fast failure proves the lock-hog actually engaged AND the
# short busy_timeout actually expired.
SHORT_FAST=$(awk -v e="$SHORT_ELAPSED" 'BEGIN{print (e < 2.5) ? "yes" : "no"}')
if [ "$SHORT_RC" -ne 0 ] \
   && grep -qi "database is locked" "$TMP_STDERR" 2>/dev/null \
   && [ "$SHORT_FAST" = "yes" ]; then
    pass "D3b: 500ms busy_timeout fails fast with lock error (proves D3a's 10s carry was load-bearing)"
else
    fail "D3b: short busy_timeout did NOT behave as expected (rc=$SHORT_RC, elapsed=${SHORT_ELAPSED}s)"
    echo "--- stderr ---"; cat "$TMP_STDERR" 2>/dev/null
fi

# The hog's write should still be durable.
HOG_ROW=$($DB_QUERY "SELECT COUNT(*) FROM services WHERE container_name='hog-tx';")
assert_eq "D3b: hog's transaction committed durably despite contender failure" "1" "$HOG_ROW"

# The contender row should be ABSENT (it failed).
SHORT_ROW=$($DB_QUERY "SELECT COUNT(*) FROM services WHERE container_name='contender-d3b';")
assert_eq "D3b: short-timeout contender did NOT silently land its row" "0" "$SHORT_ROW"

rm -f "$TMP_STDERR" "$TMP_HOG_LOG"
TMP_STDERR=""; TMP_HOG_LOG=""

cleanup_test_db "$TEST_DB"
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

# ---------------------------------------------------------------------------
# D3c — 3 parallel `scheduler.sh --service X` against the same DB.
#
# Each --service invocation INSERTs a job row, runs the dummy indexing
# task (sleep 2), then UPDATEs the row to COMPLETED. With three
# in-flight in parallel they contend on every BEGIN IMMEDIATE — both
# the insert and the final update phases.
#
# Different services on purpose: the per-service guard added in B1
# would refuse a second --service for the SAME service. Here we want
# pure DB contention without the guard rejecting anyone.
#
# Cap=10 (from the exports above) so the cap is not the limiter — we
# are testing the DB layer, not the cap.
# ---------------------------------------------------------------------------
echo "--- D3c: 3 parallel --service invocations succeed under wrapper contention ---"

# Seed three services.
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES
    ('svc-d3c-a', 1, 1),
    ('svc-d3c-b', 1, 1),
    ('svc-d3c-c', 1, 1);"

# Per-invocation log files so we can grep each stderr independently
# and surface diagnostics on failure.
TMP_A=$(mktemp /tmp/d3c_a.XXXXXX.log)
TMP_B=$(mktemp /tmp/d3c_b.XXXXXX.log)
TMP_C=$(mktemp /tmp/d3c_c.XXXXXX.log)

# Override LOG_DIR so the scheduler's own log() helper doesn't fight
# for the real logs/ tree. The directory is created on demand.
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"

# Three concurrent dispatches. `&` runs each in a child shell that
# inherits all the exports above. Capture stderr+stdout combined per
# child so a leaked DB error is visible regardless of which channel
# it lands on.
"$SCHEDULER" --service svc-d3c-a >"$TMP_A" 2>&1 &
PA=$!
"$SCHEDULER" --service svc-d3c-b >"$TMP_B" 2>&1 &
PB=$!
"$SCHEDULER" --service svc-d3c-c >"$TMP_C" 2>&1 &
PC=$!

wait "$PA"; RA=$?
wait "$PB"; RB=$?
wait "$PC"; RC=$?

echo "[Info D3c] exit codes: a=$RA b=$RB c=$RC"

# 1. All three exits clean. A non-zero exit here means either the dummy
# task failed (rare on a healthy host), or the wrapper's INSERT/UPDATE
# couldn't grab the lock inside busy_timeout (which would be the bug
# this case exists to catch).
if [ "$RA" -eq 0 ] && [ "$RB" -eq 0 ] && [ "$RC" -eq 0 ]; then
    pass "D3c: all 3 parallel --service invocations exited 0"
else
    fail "D3c: at least one --service invocation failed (a=$RA b=$RB c=$RC)"
    echo "--- A log ---"; cat "$TMP_A"
    echo "--- B log ---"; cat "$TMP_B"
    echo "--- C log ---"; cat "$TMP_C"
fi

# 2. All three jobs reached COMPLETED. Counting via service_id ensures
# we are not also catching some unrelated row.
COMPLETED=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='COMPLETED' AND service_id IN (SELECT id FROM services WHERE container_name LIKE 'svc-d3c-%');")
assert_eq "D3c: 3 COMPLETED job rows landed for svc-d3c-*" "3" "$COMPLETED"

# 3. No 'database is locked' string leaked to any wrapper output. The
# wrapper at bin/db_query.sh:33 filters init noise but forwards real
# errors to stderr — if busy_timeout failed mid-transaction we'd see
# it surface here. Use -i to catch any case variant.
LEAKED=0
for LOG in "$TMP_A" "$TMP_B" "$TMP_C"; do
    if grep -qi "database is locked" "$LOG" 2>/dev/null; then
        LEAKED=1
        echo "[Diag D3c] 'database is locked' in $LOG:"
        grep -i "database is locked" "$LOG"
    fi
done
if [ "$LEAKED" -eq 0 ]; then
    pass "D3c: no 'database is locked' leaked across all 3 wrapper outputs"
else
    fail "D3c: 'database is locked' leaked despite busy_timeout=10000"
fi

# 4. No duplicate or stuck-RUNNING rows. After both phases finish, the
# table should have exactly 3 svc-d3c-* rows and zero RUNNING.
RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING' AND service_id IN (SELECT id FROM services WHERE container_name LIKE 'svc-d3c-%');")
assert_eq "D3c: no lingering RUNNING rows after all 3 finish" "0" "$RUNNING"

TOTAL=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id IN (SELECT id FROM services WHERE container_name LIKE 'svc-d3c-%');")
assert_eq "D3c: exactly 3 job rows total for svc-d3c-* (no duplicate dispatch)" "3" "$TOTAL"

print_test_summary
