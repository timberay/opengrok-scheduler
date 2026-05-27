#!/bin/bash

# tests/test_service_bad_input.sh
# Use case B4 — `scheduler.sh --service <name>` input-handling contract.
#
# The --service branch is the only operator-facing CLI surface that takes a
# free-form name argument, so it is the natural place for an attacker (or
# a typo) to inject shell metacharacters, path traversal, or SQL fragments.
# It also sits in front of the atomic INSERT-if-under-cap-and-not-running
# logic, so any bypass of input validation would feed straight into a SQL
# string interpolation in $DB_QUERY.
#
# This test pins the full input-handling chain for --service:
#
#   B4a  missing arg            → exit 1, usage hint, no DB writes
#   B4b  invalid name (special) → validate_name refuses, no SQL execution,
#                                 no shell-injection side effect
#   B4c  unknown service        → exit 1, "not found" diagnostic, no INSERT
#   B4d  inactive service       → CURRENT CONTRACT: --service IS allowed to
#                                 force-dispatch an is_active=0 service.
#                                 Pinned here so any future change to that
#                                 contract has to update this test
#                                 deliberately (operator "force-run an
#                                 inactive service for testing" use case).
#   B4e  happy path (active)    → exit 0, RUNNING→COMPLETED row, run_id NULL
#   B4f  service already RUNNING→ exit 1, "already running", no duplicate row
#   B4g  cap full (other svc)   → exit 1, "concurrency cap", no INSERT for
#                                 the targeted service

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

SCHEDULER="$PROJECT_ROOT/bin/scheduler.sh"

echo "[Test] --service bad-input contract (B4a–B4g)..."

# ------------------------------------------------------------------
# Fresh isolated DB. Single active service "svc-active" plus an
# inactive "svc-inactive" so B4d can probe the is_active=0 contract
# without seeding any extra fixture in the middle of the test.
# ------------------------------------------------------------------
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
export LOG_DIR="$PROJECT_ROOT/logs/test"
mkdir -p "$LOG_DIR"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# Lock file gets created by --service indirectly via lock-detection paths in
# other branches; --service itself never grabs the lock. Clean it preemptively
# anyway so a stale file from a prior run doesn't influence anything.
LOCK_FILE="${TEST_DB}.lock"
rm -f "$LOCK_FILE"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-active', 1, 1);"
$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('svc-inactive', 1, 0);"

# Canary file used to detect shell injection in B4b. If the bad name string
# is ever expanded by the *scheduler's* shell (eval/unquoted expansion), the
# command substitution would create this file. Any test path that creates
# the file is a fail.
CANARY="$PROJECT_ROOT/data/test_b4b_canary_$$"
rm -f "$CANARY"

# Per-sub-case helper: snapshot the jobs table COUNT so we can prove
# refusal paths did not INSERT.
jobs_count() {
    $DB_QUERY "SELECT COUNT(*) FROM jobs;"
}

# ------------------------------------------------------------------
# B4a: missing arg → exit 1, usage hint, no DB write
# ------------------------------------------------------------------
BEFORE=$(jobs_count)
OUT=$("$SCHEDULER" --service 2>&1)
EC=$?
AFTER=$(jobs_count)

if [ "$EC" -eq 1 ] \
   && echo "$OUT" | grep -qiE "provide a container name|Usage:" \
   && [ "$BEFORE" = "$AFTER" ]; then
    echo "[Pass] B4a: missing arg → exit 1 with usage hint, no DB write."
    PASS=$((PASS + 1))
else
    echo "[Fail] B4a: exit=$EC, jobs delta=$BEFORE→$AFTER"
    echo "       output: $OUT"
    FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
# B4b: invalid names (special chars, semi-colon, path traversal,
# command-substitution payload). All must be rejected by validate_name
# BEFORE any SQL is run. The canary file must not exist afterward.
# ------------------------------------------------------------------
# Each entry is a literal string we pass directly via "$VAR" to scheduler.sh.
# Note: command substitution in the SOURCE of $BAD_INPUTS would be evaluated
# by THIS test's shell, which is not what we are testing — we are testing
# whether the scheduler shell expands the bytes it receives. So we keep the
# bytes literal here (single-quoted) and let bash pass them through.
BAD_INPUTS=(
    'foo;bar'                       # command separator
    'foo|bar'                       # pipe
    'foo&bar'                       # background
    'foo$bar'                       # variable expansion attempt
    '../etc/passwd'                 # path traversal
    'foo/bar'                       # directory separator
    "'; DROP TABLE services; --"    # classic SQL injection payload
    "\$(touch $CANARY)"             # command substitution payload (literal)
    '`touch '"$CANARY"'`'           # backtick command substitution
    'foo bar'                       # space (would split into two args inside SQL string)
    'foo*'                          # glob
    'foo?bar'                       # glob ?
)

B4B_OK=1
for BAD in "${BAD_INPUTS[@]}"; do
    BEFORE=$(jobs_count)
    OUT=$("$SCHEDULER" --service "$BAD" 2>&1)
    EC=$?
    AFTER=$(jobs_count)

    # Expectations:
    #   - non-zero exit
    #   - jobs table unchanged
    #   - diagnostic mentions "Invalid name" (from validate_name)
    #   - canary not created (shell injection didn't fire)
    if [ "$EC" -eq 0 ] \
       || [ "$BEFORE" != "$AFTER" ] \
       || ! echo "$OUT" | grep -qiE "Invalid name input"; then
        echo "[Fail] B4b: bad input '$BAD' was NOT rejected cleanly."
        echo "       exit=$EC, jobs delta=$BEFORE→$AFTER"
        echo "       output: $OUT"
        B4B_OK=0
    fi

    if [ -e "$CANARY" ]; then
        echo "[Fail] B4b: SHELL INJECTION — canary file created by input '$BAD'."
        rm -f "$CANARY"
        B4B_OK=0
    fi
done

if [ "$B4B_OK" -eq 1 ]; then
    echo "[Pass] B4b: all ${#BAD_INPUTS[@]} bad inputs rejected by validate_name; no DB writes; no shell injection."
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
# B4c: unknown service → exit 1, "not found" diagnostic, no INSERT
# ------------------------------------------------------------------
BEFORE=$(jobs_count)
OUT=$("$SCHEDULER" --service "svc-does-not-exist" 2>&1)
EC=$?
AFTER=$(jobs_count)

if [ "$EC" -eq 1 ] \
   && echo "$OUT" | grep -qiE "not found in database" \
   && [ "$BEFORE" = "$AFTER" ]; then
    echo "[Pass] B4c: unknown service → exit 1 with 'not found' diagnostic, no INSERT."
    PASS=$((PASS + 1))
else
    echo "[Fail] B4c: exit=$EC, jobs delta=$BEFORE→$AFTER"
    echo "       output: $OUT"
    FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
# B4d: inactive service (is_active=0).
#
# CURRENT CONTRACT (pinned here): --service IS allowed to force-dispatch
# a service whose is_active=0. The SERVICE_INFO lookup deliberately does
# not filter on is_active because the operator use case is "force-run an
# inactive service for testing / one-off rerun without re-enabling it
# globally". The main loop's own NEXT_SERVICE_ID query DOES filter on
# is_active, so the inactive service still won't auto-run on the next
# cycle — only the explicit operator trigger fires.
#
# If a future PR changes that contract (e.g. --service should refuse
# inactive services with a clear diagnostic), this assertion will fail
# and force a deliberate update.
# ------------------------------------------------------------------
S_INACTIVE_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-inactive';")
BEFORE_INACTIVE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$S_INACTIVE_ID;")
OUT=$("$SCHEDULER" --service "svc-inactive" 2>&1)
EC=$?
AFTER_INACTIVE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$S_INACTIVE_ID;")
FINAL_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$S_INACTIVE_ID ORDER BY id DESC LIMIT 1;")

if [ "$EC" -eq 0 ] \
   && [ "$AFTER_INACTIVE" = "$((BEFORE_INACTIVE + 1))" ] \
   && [ "$FINAL_STATUS" = "COMPLETED" ]; then
    echo "[Pass] B4d: --service force-dispatched inactive service (operator override contract)."
    PASS=$((PASS + 1))
else
    echo "[Fail] B4d: expected operator-override of inactive service to succeed."
    echo "       exit=$EC, jobs for svc-inactive: $BEFORE_INACTIVE→$AFTER_INACTIVE, final status='$FINAL_STATUS'"
    echo "       output: $OUT"
    FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
# B4e: happy path — active service, idle, cap not full, no scheduler.
# Should INSERT, run, finalise COMPLETED with run_id NULL (manual run).
# ------------------------------------------------------------------
S_ACTIVE_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='svc-active';")
BEFORE_ACTIVE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$S_ACTIVE_ID;")
OUT=$("$SCHEDULER" --service "svc-active" 2>&1)
EC=$?
AFTER_ACTIVE=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$S_ACTIVE_ID;")
FINAL=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$S_ACTIVE_ID ORDER BY id DESC LIMIT 1;")
RUN_ID_VAL=$($DB_QUERY "SELECT IFNULL(run_id, 'NULL') FROM jobs WHERE service_id=$S_ACTIVE_ID ORDER BY id DESC LIMIT 1;")

if [ "$EC" -eq 0 ] \
   && [ "$AFTER_ACTIVE" = "$((BEFORE_ACTIVE + 1))" ] \
   && [ "$FINAL" = "COMPLETED" ] \
   && [ "$RUN_ID_VAL" = "NULL" ]; then
    echo "[Pass] B4e: happy-path manual dispatch → exit 0, COMPLETED, run_id NULL."
    PASS=$((PASS + 1))
else
    echo "[Fail] B4e: exit=$EC, jobs delta=$BEFORE_ACTIVE→$AFTER_ACTIVE, status='$FINAL', run_id='$RUN_ID_VAL'"
    echo "       output: $OUT"
    FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
# B4f: service already RUNNING → refused with "already running" exit 1.
#
# Simulate a pre-existing RUNNING row (as if the main loop had dispatched
# it) and confirm the per-service guard at bin/scheduler.sh:529 fires.
# Cap is set high so the cap path can't mask the per-service path.
# ------------------------------------------------------------------
export MAX_CONCURRENT_JOBS=5
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, pid) VALUES ($S_ACTIVE_ID, 'RUNNING', datetime('now','localtime'), 99992);"
BEFORE_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$S_ACTIVE_ID AND status='RUNNING';")
OUT=$("$SCHEDULER" --service "svc-active" 2>&1)
EC=$?
AFTER_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE service_id=$S_ACTIVE_ID AND status='RUNNING';")

if [ "$EC" -ne 0 ] \
   && [ "$BEFORE_RUNNING" = "$AFTER_RUNNING" ] \
   && echo "$OUT" | grep -qiE "already running"; then
    echo "[Pass] B4f: duplicate dispatch refused with per-service diagnostic."
    PASS=$((PASS + 1))
else
    echo "[Fail] B4f: exit=$EC, RUNNING for svc-active: $BEFORE_RUNNING→$AFTER_RUNNING"
    echo "       output: $OUT"
    FAIL=$((FAIL + 1))
fi

# Clean up the synthetic RUNNING row from B4f before moving on.
$DB_QUERY "DELETE FROM jobs WHERE service_id=$S_ACTIVE_ID AND status='RUNNING' AND pid=99992;"

# ------------------------------------------------------------------
# B4g: cap full from OTHER services → refused with "concurrency cap"
# message (and NOT the "already running" message; svc-active has no
# RUNNING row at this point). Distinguishes the two refusal diagnostics.
# ------------------------------------------------------------------
export MAX_CONCURRENT_JOBS=1
# Fill the cap with an unrelated RUNNING row (svc-inactive is fine for this).
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, pid) VALUES ($S_INACTIVE_ID, 'RUNNING', datetime('now','localtime'), 99993);"
BEFORE_TOTAL=$(jobs_count)
OUT=$("$SCHEDULER" --service "svc-active" 2>&1)
EC=$?
AFTER_TOTAL=$(jobs_count)

if [ "$EC" -ne 0 ] \
   && [ "$BEFORE_TOTAL" = "$AFTER_TOTAL" ] \
   && echo "$OUT" | grep -qiE "concurrency cap" \
   && ! echo "$OUT" | grep -qiE "Service already running"; then
    # Note: we look for the specific B1-collision diagnostic
    # "Service already running" rather than the substring "already running",
    # because the cap-message itself reads "1/1 jobs already running"
    # which would false-match a naive "already running" grep.
    echo "[Pass] B4g: cap-full refusal fires with correct diagnostic (not collision msg)."
    PASS=$((PASS + 1))
else
    echo "[Fail] B4g: exit=$EC, jobs delta=$BEFORE_TOTAL→$AFTER_TOTAL"
    echo "       output: $OUT"
    FAIL=$((FAIL + 1))
fi

# Final teardown — drop the synthetic cap-filler row, kill any stray test
# artifacts, and wipe the test DB.
$DB_QUERY "DELETE FROM jobs WHERE pid=99993;"
rm -f "$CANARY"
rm -f "$LOCK_FILE"
cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
