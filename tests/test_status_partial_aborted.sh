#!/bin/bash
# tests/test_status_partial_aborted.sh
#
# Verifies that `bin/scheduler.sh --status` renders a coherent view when the
# latest run is PARTIAL or ABORTED. Operators rely on --status after they
# believe things have settled, so the header counters, per-service rows, and
# end-of-cycle messages must all agree with the underlying DB state.
#
# Sub-cases:
#   1. PARTIAL  — window closed mid-cycle; some jobs drained as ORPHANED.
#   2. ABORTED  — scheduler SIGTERM shutdown; jobs ORPHANED with the
#                 'Scheduler shutdown' message.
#   3. ABORTED-by-init — operator ran --init while jobs were RUNNING; jobs
#                 ORPHANED with 'Aborted by --init'.
#   4. mixed PARTIAL — only some services got a row in the run; services
#                 with no row at all must appear as WAITING in the table.

source "$(dirname "$0")/test_helper.sh"

echo "=== Test: --status renders PARTIAL and ABORTED runs coherently ==="

# Helper: assert OUTPUT contains a regex. Pretty-printed table cells are
# space-padded so we use -E + tolerant patterns instead of literal greps.
assert_grep() {
    local desc="$1"; local pattern="$2"; local output="$3"
    if echo "$output" | grep -qE "$pattern"; then
        PASS=$((PASS+1)); echo "[Pass] $desc"
    else
        FAIL=$((FAIL+1)); echo "[Fail] $desc"
        echo "       pattern: $pattern"
        echo "       --- output ---"
        echo "$output" | sed 's/^/       /'
        echo "       --- end ---"
    fi
}

assert_not_grep() {
    local desc="$1"; local pattern="$2"; local output="$3"
    if echo "$output" | grep -qE "$pattern"; then
        FAIL=$((FAIL+1)); echo "[Fail] $desc (unexpected match for: $pattern)"
        echo "       --- output ---"
        echo "$output" | sed 's/^/       /'
        echo "       --- end ---"
    else
        PASS=$((PASS+1)); echo "[Pass] $desc"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case 1: PARTIAL — window closed mid-cycle
# ---------------------------------------------------------------------------
echo ""
echo "--- Sub-case 1: latest run is PARTIAL ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services(container_name, priority) VALUES
    ('svc-partial-a', 10),
    ('svc-partial-b', 5),
    ('svc-partial-c', 1);"

# Insert a run with status=PARTIAL and ended_at set (PARTIAL is a terminal
# status; the contract is that ended_at MUST be populated).
$DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by,
                            total_services, completed_count, failed_count,
                            timeout_count, orphaned_count) VALUES
    (datetime('now','localtime','-3 hours'),
     datetime('now','localtime','-30 minutes'),
     'PARTIAL', 'auto', 3, 1, 0, 0, 2);"

RID=$($DB_QUERY "SELECT id FROM runs ORDER BY id DESC LIMIT 1;")

# Jobs: svc-partial-a COMPLETED; b & c drained as ORPHANED ('Window closed').
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time,
                            duration, message, process_state) VALUES
    (1, $RID, 'COMPLETED',
     datetime('now','localtime','-3 hours'),
     datetime('now','localtime','-2 hours'),
     3600, 'OK', 'EXITED'),
    (2, $RID, 'ORPHANED',
     datetime('now','localtime','-2 hours'),
     datetime('now','localtime','-30 minutes'),
     5400, 'Window closed', 'EXITED'),
    (3, $RID, 'ORPHANED',
     datetime('now','localtime','-90 minutes'),
     datetime('now','localtime','-30 minutes'),
     3600, 'Window closed', 'EXITED');"

OUTPUT=$(DB_PATH="$TEST_DB" "$SCHEDULER" --status 2>&1)
RC=$?

assert_eq "PARTIAL: --status exits 0" "0" "$RC"
assert_grep "PARTIAL: header includes Run #N with PARTIAL+trigger" \
    "Run #${RID}.*PARTIAL.*trigger=auto" "$OUTPUT"
# Header must show both started_at and ended_at — verify both appear by
# matching the 'A ~ B' segment with two non-dash timestamps.
assert_grep "PARTIAL: header has started_at ~ ended_at (both populated)" \
    "[0-9-]+ [0-9:]+ ~ [0-9-]+ [0-9:]+" "$OUTPUT"
assert_grep "PARTIAL: header shows 3/3 done (C=1 F=0 T=0 O=2)" \
    "3/3 done .*C=1 F=0 T=0 O=2" "$OUTPUT"
assert_grep "PARTIAL: footer shows Run #N done: 3/3" \
    "Run #${RID} done: 3/3" "$OUTPUT"

# Per-service rows:
assert_grep "PARTIAL: svc-partial-a row shows COMPLETED" \
    "svc-partial-a +\| COMPLETED" "$OUTPUT"
assert_grep "PARTIAL: svc-partial-b row shows ORPHANED" \
    "svc-partial-b +\| ORPHANED" "$OUTPUT"
assert_grep "PARTIAL: svc-partial-c row shows ORPHANED" \
    "svc-partial-c +\| ORPHANED" "$OUTPUT"
# Message column — 'Window closed' is 13 chars and the column is 20-wide,
# so it should render in full without truncation.
assert_grep "PARTIAL: orphaned rows display 'Window closed' message" \
    "ORPHANED.*Window closed" "$OUTPUT"
# Drained ORPHANED rows shouldn't masquerade as WAITING.
assert_not_grep "PARTIAL: no spurious WAITING row for dispatched services" \
    "svc-partial-(a|b|c) +\| WAITING" "$OUTPUT"

cleanup_test_db "$TEST_DB"

# ---------------------------------------------------------------------------
# Sub-case 2: ABORTED — SIGTERM shutdown drained jobs
# ---------------------------------------------------------------------------
echo ""
echo "--- Sub-case 2: latest run is ABORTED (SIGTERM shutdown) ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services(container_name) VALUES
    ('svc-shutdown-a'),
    ('svc-shutdown-b');"

$DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by,
                            total_services, completed_count, failed_count,
                            timeout_count, orphaned_count) VALUES
    (datetime('now','localtime','-1 hour'),
     datetime('now','localtime','-5 minutes'),
     'ABORTED', 'auto', 2, 0, 0, 0, 2);"
RID=$($DB_QUERY "SELECT id FROM runs ORDER BY id DESC LIMIT 1;")

$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time,
                            duration, message, process_state) VALUES
    (1, $RID, 'ORPHANED',
     datetime('now','localtime','-1 hour'),
     datetime('now','localtime','-5 minutes'),
     3300, 'Scheduler shutdown', 'EXITED'),
    (2, $RID, 'ORPHANED',
     datetime('now','localtime','-50 minutes'),
     datetime('now','localtime','-5 minutes'),
     2700, 'Scheduler shutdown', 'EXITED');"

OUTPUT=$(DB_PATH="$TEST_DB" "$SCHEDULER" --status 2>&1)
RC=$?

assert_eq "ABORTED(shutdown): --status exits 0" "0" "$RC"
assert_grep "ABORTED(shutdown): header includes Run #N ABORTED+trigger" \
    "Run #${RID}.*ABORTED.*trigger=auto" "$OUTPUT"
assert_grep "ABORTED(shutdown): header has both timestamps populated" \
    "[0-9-]+ [0-9:]+ ~ [0-9-]+ [0-9:]+" "$OUTPUT"
assert_grep "ABORTED(shutdown): header counters 2/2 with O=2" \
    "2/2 done .*C=0 F=0 T=0 O=2" "$OUTPUT"
assert_grep "ABORTED(shutdown): per-service ORPHANED rows present" \
    "svc-shutdown-a +\| ORPHANED" "$OUTPUT"
assert_grep "ABORTED(shutdown): 'Scheduler shutdown' message visible" \
    "ORPHANED.*Scheduler shutdown" "$OUTPUT"

cleanup_test_db "$TEST_DB"

# ---------------------------------------------------------------------------
# Sub-case 3: ABORTED-by-init — --init flipped a stale RUNNING run
# ---------------------------------------------------------------------------
echo ""
echo "--- Sub-case 3: latest run is ABORTED (--init) ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services(container_name) VALUES
    ('svc-init-a'),('svc-init-b');"

$DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by,
                            total_services, completed_count, failed_count,
                            timeout_count, orphaned_count) VALUES
    (datetime('now','localtime','-2 hours'),
     datetime('now','localtime','-10 minutes'),
     'ABORTED', 'init', 2, 1, 0, 0, 1);"
RID=$($DB_QUERY "SELECT id FROM runs ORDER BY id DESC LIMIT 1;")

$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time,
                            duration, message, process_state) VALUES
    (1, $RID, 'COMPLETED',
     datetime('now','localtime','-2 hours'),
     datetime('now','localtime','-90 minutes'),
     1800, 'OK', 'EXITED'),
    (2, $RID, 'ORPHANED',
     datetime('now','localtime','-90 minutes'),
     datetime('now','localtime','-10 minutes'),
     4800, 'Aborted by --init', 'UNKNOWN');"

OUTPUT=$(DB_PATH="$TEST_DB" "$SCHEDULER" --status 2>&1)
RC=$?

assert_eq "ABORTED(init): --status exits 0" "0" "$RC"
assert_grep "ABORTED(init): header shows trigger=init" \
    "Run #${RID}.*ABORTED.*trigger=init" "$OUTPUT"
assert_grep "ABORTED(init): header counters 2/2 with C=1 O=1" \
    "2/2 done .*C=1 F=0 T=0 O=1" "$OUTPUT"
assert_grep "ABORTED(init): COMPLETED row for svc-init-a" \
    "svc-init-a +\| COMPLETED" "$OUTPUT"
assert_grep "ABORTED(init): ORPHANED row for svc-init-b" \
    "svc-init-b +\| ORPHANED" "$OUTPUT"
# 'Aborted by --init' is 17 chars; column width is 20, so it must render
# without truncation. (If the column ever shrinks below 17, this catches it.)
assert_grep "ABORTED(init): full 'Aborted by --init' message renders" \
    "Aborted by --init" "$OUTPUT"

cleanup_test_db "$TEST_DB"

# ---------------------------------------------------------------------------
# Sub-case 4: mixed PARTIAL — only some services got a job row
# ---------------------------------------------------------------------------
echo ""
echo "--- Sub-case 4: PARTIAL with un-dispatched service → WAITING row ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

$DB_QUERY "INSERT INTO services(container_name) VALUES
    ('svc-mixed-a'),
    ('svc-mixed-b'),
    ('svc-mixed-undispatched');"

# total_services=3 but only 2 jobs exist; the 3rd service was never reached
# before the window closed. Header counter (1 COMPLETED + 1 ORPHANED = 2 done)
# correctly lags total (3).
$DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by,
                            total_services, completed_count, failed_count,
                            timeout_count, orphaned_count) VALUES
    (datetime('now','localtime','-2 hours'),
     datetime('now','localtime','-15 minutes'),
     'PARTIAL', 'auto', 3, 1, 0, 0, 1);"
RID=$($DB_QUERY "SELECT id FROM runs ORDER BY id DESC LIMIT 1;")

$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time,
                            duration, message, process_state) VALUES
    (1, $RID, 'COMPLETED',
     datetime('now','localtime','-2 hours'),
     datetime('now','localtime','-90 minutes'),
     1800, 'OK', 'EXITED'),
    (2, $RID, 'ORPHANED',
     datetime('now','localtime','-90 minutes'),
     datetime('now','localtime','-15 minutes'),
     4500, 'Window closed', 'EXITED');"

OUTPUT=$(DB_PATH="$TEST_DB" "$SCHEDULER" --status 2>&1)
RC=$?

assert_eq "mixed PARTIAL: --status exits 0" "0" "$RC"
assert_grep "mixed PARTIAL: header 2/3 (one service never dispatched)" \
    "2/3 done .*C=1 F=0 T=0 O=1" "$OUTPUT"
assert_grep "mixed PARTIAL: svc-mixed-a row COMPLETED" \
    "svc-mixed-a +\| COMPLETED" "$OUTPUT"
assert_grep "mixed PARTIAL: svc-mixed-b row ORPHANED" \
    "svc-mixed-b +\| ORPHANED" "$OUTPUT"
# The un-dispatched service must appear (LEFT JOIN preserves it) and render
# as WAITING via the `${status:-WAITING}` fallback in the table printf.
assert_grep "mixed PARTIAL: un-dispatched service shows WAITING" \
    "svc-mixed-undispatched +\| WAITING" "$OUTPUT"

cleanup_test_db "$TEST_DB"

# ---------------------------------------------------------------------------
# Read-only verification: --status MUST NOT write to the DB.
# Take a checksum of the DB file before and after a status call.
# ---------------------------------------------------------------------------
echo ""
echo "--- Sub-case 5: --status is read-only ---"

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name) VALUES ('svc-readonly');"
$DB_QUERY "INSERT INTO runs(started_at, ended_at, status, triggered_by,
                            total_services, orphaned_count) VALUES
    (datetime('now','localtime','-1 hour'),
     datetime('now','localtime','-10 minutes'),
     'PARTIAL', 'auto', 1, 1);"
RID=$($DB_QUERY "SELECT id FROM runs ORDER BY id DESC LIMIT 1;")
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time,
                            duration, message) VALUES
    (1, $RID, 'ORPHANED',
     datetime('now','localtime','-1 hour'),
     datetime('now','localtime','-10 minutes'),
     3000, 'Window closed');"

# Force a WAL checkpoint so the comparison is stable (without this, a
# concurrent reader can rotate the WAL/SHM files even on read-only access).
sqlite3 "$TEST_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1

# Compare logical content (table rows), not the file checksum: SQLite's
# WAL/SHM machinery can touch sidecar files even for read-only queries.
DUMP_BEFORE=$(sqlite3 "$TEST_DB" ".dump")
DB_PATH="$TEST_DB" "$SCHEDULER" --status >/dev/null 2>&1
sqlite3 "$TEST_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
DUMP_AFTER=$(sqlite3 "$TEST_DB" ".dump")

if [ "$DUMP_BEFORE" == "$DUMP_AFTER" ]; then
    PASS=$((PASS+1)); echo "[Pass] --status did not mutate DB content"
else
    FAIL=$((FAIL+1)); echo "[Fail] --status changed DB rows"
    diff <(echo "$DUMP_BEFORE") <(echo "$DUMP_AFTER") | head -40
fi

cleanup_test_db "$TEST_DB"

print_test_summary
