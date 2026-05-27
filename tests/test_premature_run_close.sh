#!/bin/bash
# tests/test_premature_run_close.sh
#
# Regression: the natural-completion close must NOT fire while any job in the
# run is still RUNNING. The original main loop closed a run as COMPLETED as
# soon as every active service had *a row* in the run — but a row in 'RUNNING'
# status satisfies the dedup EXISTS check, so the run got closed while jobs
# were still in flight. The next iteration then opened a fresh run and made
# those services eligible again, leading to duplicate dispatch once the old
# background processes finally finished.
#
# Symptom seen by operators: a service shows RUNNING in --status, briefly
# flips to WAITING (because --status filters by the latest run_id and the
# next run has no row yet), then a second indexing pass starts.

source "$(dirname "$0")/test_helper.sh"

echo "=== Test: natural-completion close honors in-flight RUNNING jobs ==="

TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('svc-a',1),('svc-b',1);"

source "$SCHEDULER" --no-run

# Open a run, then simulate the main loop having dispatched both services:
#   svc-a is still RUNNING; svc-b finished COMPLETED.
RID=$(run_open_if_none auto)
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time) VALUES
    (1, $RID, 'RUNNING',   datetime('now','localtime'));"
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (2, $RID, 'COMPLETED', datetime('now','localtime'), datetime('now','localtime'));"

# Pre-condition: the dedup query the main loop uses returns no eligible service —
# every active service has a row in this run. Pre-bug, the next branch would
# close the run COMPLETED right here even though svc-a is still RUNNING.
NEXT=$($DB_QUERY "SELECT s.id FROM services s
                  WHERE s.is_active=1
                  AND NOT EXISTS (
                      SELECT 1 FROM jobs j WHERE j.service_id=s.id AND j.run_id=$RID
                  ) LIMIT 1;")
assert_eq "no NEXT_SERVICE_ID when every service has a row (RUNNING counts)" "" "$NEXT"

# Behavioral contract introduced by the fix: a helper that gates the close.
if ! type run_can_close_naturally >/dev/null 2>&1; then
    FAIL=$((FAIL+1))
    echo "[Fail] run_can_close_naturally helper missing (fix not applied)"
else
    if run_can_close_naturally "$RID"; then
        FAIL=$((FAIL+1))
        echo "[Fail] run_can_close_naturally returned 0 while svc-a is still RUNNING"
    else
        PASS=$((PASS+1))
        echo "[Pass] run_can_close_naturally refused close while a RUNNING job remains"
    fi
fi

# Outcome check: nothing must have transitioned the run off RUNNING.
STATUS=$($DB_QUERY "SELECT status FROM runs WHERE id=$RID;")
assert_eq "run remains RUNNING while in-flight job exists" "RUNNING" "$STATUS"

# Now svc-a finishes. The decision must flip — the run is closable.
$DB_QUERY "UPDATE jobs SET status='COMPLETED', end_time=datetime('now','localtime')
           WHERE service_id=1 AND run_id=$RID;"

if type run_can_close_naturally >/dev/null 2>&1; then
    if run_can_close_naturally "$RID"; then
        PASS=$((PASS+1))
        echo "[Pass] run_can_close_naturally allows close once all jobs are terminal"
    else
        FAIL=$((FAIL+1))
        echo "[Fail] run_can_close_naturally still refused close after all jobs finished"
    fi
fi

cleanup_test_db "$TEST_DB"

# Second scenario — end-to-end through the dedup + close-decision pair, with
# a fresh run opened to verify that the fix prevents the "re-dispatch in the
# next run" symptom that the user actually observed.
echo "--- Cross-run regression: no re-eligibility while old run still RUNNING ---"
TEST_DB2=$(setup_test_db); export DB_PATH="$TEST_DB2"
$DB_QUERY "INSERT INTO services(container_name, is_active) VALUES ('svc-a',1),('svc-b',1);"

R1=$(run_open_if_none auto)
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time) VALUES
    (1, $R1, 'RUNNING',   datetime('now','localtime'));"
$DB_QUERY "INSERT INTO jobs(service_id, run_id, status, start_time, end_time) VALUES
    (2, $R1, 'COMPLETED', datetime('now','localtime'), datetime('now','localtime'));"

# Main-loop close gate must say "no" because svc-a is still RUNNING.
if type run_can_close_naturally >/dev/null 2>&1 && ! run_can_close_naturally "$R1"; then
    PASS=$((PASS+1))
    echo "[Pass] close gate refuses while RUNNING job remains in run #$R1"
else
    FAIL=$((FAIL+1))
    echo "[Fail] close gate should have refused while RUNNING job remains"
fi

# Because we did NOT close the run, run_open_if_none must keep returning R1
# (idempotent) — no fresh run is opened, so svc-a cannot become eligible again.
R2=$(run_open_if_none auto)
assert_eq "run_open_if_none stays on R1 while it is still RUNNING" "$R1" "$R2"

ELIGIBLE=$($DB_QUERY "SELECT s.container_name FROM services s
                      WHERE s.is_active=1
                      AND NOT EXISTS (
                          SELECT 1 FROM jobs j WHERE j.service_id=s.id AND j.run_id=$R2
                      ) ORDER BY s.id LIMIT 1;")
assert_eq "no service is re-eligible while in-flight job remains" "" "$ELIGIBLE"

cleanup_test_db "$TEST_DB2"
print_test_summary
