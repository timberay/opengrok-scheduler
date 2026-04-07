# Phase 10 Bug Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 9 bugs (6 runtime, 3 test) identified in the full codebase audit (spec: `docs/superpowers/specs/2026-04-07-bugfix-phase10-design.md`).

**Architecture:** Each fix is independent. Changes span 3 source files (`bin/scheduler.sh`, `bin/monitor.sh`, `bin/migrate_db.sh`) and 8 test files. TDD Red-Green-Refactor per fix.

**Tech Stack:** Bash, SQLite3, custom test framework (`tests/test_helper.sh`)

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `bin/scheduler.sh:266` | Fix 5: add `local` to ZOMBIE REAP_EXIT |
| Modify | `bin/scheduler.sh:289-293` | Fix 3: replace STOPPED handler |
| Modify | `bin/scheduler.sh:403` | Fix 1: replace `kill -TERM` with `kill_process_tree` |
| Modify | `bin/migrate_db.sh:57` | Fix 2: use SQL query instead of `.schema` dot-command |
| Modify | `bin/monitor.sh:124-126` | Fix 4: NVMe-aware partition stripping |
| Modify | `bin/monitor.sh:136-138` | Fix 6: change iostat default from 100 to 0 |
| Modify | `tests/test_db_init.sh:23-41` | Fix 7: fix table list and remove config query |
| Modify | `tests/test_idle_timeout.sh:1-20,120-131` | Fix 9: use setup_test_db instead of copying prod DB |
| Modify | `tests/test_service_option.sh` | Fix 8: isolate from production DB |
| Modify | `tests/test_status_output.sh` | Fix 8: isolate from production DB |
| Modify | `tests/test_init_option.sh` | Fix 8: isolate from production DB |
| Modify | `tests/test_local_keyword_fix.sh` | Fix 8: isolate from production DB |
| Modify | `tests/test_orphan_recovery_fix.sh` | Fix 8: isolate from production DB |
| Modify | `tests/test_db_error_handling.sh` | Fix 8: isolate from production DB |
| Modify | `tests/test_db_query_fixes.sh` | Fix 8: isolate from production DB |

---

### Task 1: Fix 7 — `test_db_init.sh` references non-existent `config` table

**Files:**
- Modify: `tests/test_db_init.sh:23-41`

- [ ] **Step 1: Run test to confirm it fails**

Run: `bash tests/test_db_init.sh`
Expected: FAIL — Table 'config' does not exist.

- [ ] **Step 2: Fix the table list and remove config query**

Replace the table check and config query section in `tests/test_db_init.sh`. Change lines 23-41 to:

```bash
# 3. Table existence check
TABLES=("services" "jobs" "heartbeat")
for table in "${TABLES[@]}"; do
    EXISTS=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';")
    if [ "$EXISTS" == "$table" ]; then
        echo "[Pass] Table '$table' exists."
    else
        echo "[Fail] Table '$table' does not exist."
        exit 1
    fi
done

echo "[Success] Database initialization test passed!"
exit 0
```

This removes the `config` table reference and the config value query (lines 35-41), since configuration is handled via `.env` environment variables, not a database table.

- [ ] **Step 3: Run test to verify it passes**

Run: `bash tests/test_db_init.sh`
Expected: PASS — all 3 tables exist.

- [ ] **Step 4: Commit**

```bash
git add tests/test_db_init.sh
git commit -m "fix(test): update test_db_init to reference correct tables (services, jobs, heartbeat)"
```

---

### Task 2: Fix 5 — Add `local` to ZOMBIE `REAP_EXIT`

**Files:**
- Modify: `bin/scheduler.sh:266`

- [ ] **Step 1: Apply the fix**

In `bin/scheduler.sh`, line 266, change:

```bash
                    REAP_EXIT=$?
```

to:

```bash
                    local REAP_EXIT=$?
```

- [ ] **Step 2: Run existing tests to verify no regression**

Run: `bash tests/test_scheduler_logic.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add bin/scheduler.sh
git commit -m "fix(scheduler): add local declaration to REAP_EXIT in ZOMBIE case"
```

---

### Task 3: Fix 2 — `migrate_db.sh` schema check concurrency

**Files:**
- Modify: `bin/migrate_db.sh:57`

- [ ] **Step 1: Run existing migration test to confirm baseline**

Run: `bash tests/test_migrate_constraint.sh`
Expected: PASS (existing tests work before change).

- [ ] **Step 2: Apply the fix**

In `bin/migrate_db.sh`, line 57, change:

```bash
    local SCHEMA=$(sqlite3 "$DB_PATH" ".schema jobs")
```

to:

```bash
    local SCHEMA=$(migrate_query "SELECT sql FROM sqlite_master WHERE type='table' AND name='jobs';")
```

This uses the existing `migrate_query` helper which includes `PRAGMA busy_timeout=10000; PRAGMA journal_mode=WAL;`, making the schema check safe for concurrent access.

- [ ] **Step 3: Run migration test to verify it still passes**

Run: `bash tests/test_migrate_constraint.sh`
Expected: PASS — both cases (old schema migration + current schema no-op) pass.

- [ ] **Step 4: Commit**

```bash
git add bin/migrate_db.sh
git commit -m "fix(migrate): use migrate_query for concurrency-safe schema check"
```

---

### Task 4: Fix 4 — NVMe device fallback detection

**Files:**
- Modify: `bin/monitor.sh:124-126`

- [ ] **Step 1: Apply the fix**

In `bin/monitor.sh`, replace lines 124-126:

```bash
        # Fallback to old logic if still empty
        if [ -z "$DISK" ]; then
            DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/.*\/dev\///; s/[0-9]*$//')
        fi
```

with:

```bash
        # Fallback to old logic if still empty
        if [ -z "$DISK" ]; then
            DISK=$(df / | tail -1 | awk '{print $1}' | sed 's|.*/dev/||')
            # Strip partition suffix: "sda1" → "sda", "nvme0n1p1" → "nvme0n1"
            if [[ "$DISK" =~ ^nvme ]]; then
                DISK=$(echo "$DISK" | sed 's/p[0-9]*$//')
            else
                DISK=$(echo "$DISK" | sed 's/[0-9]*$//')
            fi
        fi
```

- [ ] **Step 2: Run monitor tests to verify no regression**

Run: `bash tests/test_monitor.sh`
Expected: PASS — all existing monitor tests pass. The primary `lsblk` path is unchanged; only the fallback is fixed.

- [ ] **Step 3: Commit**

```bash
git add bin/monitor.sh
git commit -m "fix(monitor): handle NVMe partition suffix in diskio fallback detection"
```

---

### Task 5: Fix 6 — `iostat` failure default value

**Files:**
- Modify: `bin/monitor.sh:136-138`

- [ ] **Step 1: Apply the fix**

In `bin/monitor.sh`, replace lines 136-138:

```bash
    if [ -z "$UTIL" ] || [[ ! $UTIL =~ ^[0-9]+$ ]]; then
        UTIL=100 # Assume busy on error
    fi
```

with:

```bash
    if [ -z "$UTIL" ] || [[ ! $UTIL =~ ^[0-9]+$ ]]; then
        UTIL=0 # Cannot measure — assume not busy (warn via check_monitor_deps)
    fi
```

- [ ] **Step 2: Run monitor tests to verify no regression**

Run: `bash tests/test_monitor.sh`
Expected: PASS — threshold tests use mock values, not actual iostat output.

- [ ] **Step 3: Commit**

```bash
git add bin/monitor.sh
git commit -m "fix(monitor): default diskio to 0 when iostat unavailable instead of blocking all jobs"
```

---

### Task 6: Fix 1 — Stale job expiration uses `kill_process_tree`

**Files:**
- Modify: `bin/scheduler.sh:403`

- [ ] **Step 1: Apply the fix**

In `bin/scheduler.sh`, line 403, change:

```bash
                [ -n "$JPID" ] && kill -TERM "$JPID" 2>/dev/null
```

to:

```bash
                [ -n "$JPID" ] && kill_process_tree "$JPID"
```

- [ ] **Step 2: Run scheduler logic tests to verify no regression**

Run: `bash tests/test_scheduler_logic.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add bin/scheduler.sh
git commit -m "fix(scheduler): use kill_process_tree for stale job expiration"
```

---

### Task 7: Fix 3 — STOPPED handler with process tree kill and DB update

**Files:**
- Modify: `bin/scheduler.sh:289-293`

- [ ] **Step 1: Apply the fix**

In `bin/scheduler.sh`, replace lines 289-293:

```bash
                STOPPED)
                    log "[Warning] Process stopped: $CNAME (PID=$PID). Sending SIGCONT then SIGTERM..."
                    kill -CONT "$PID" 2>/dev/null
                    sleep 2
                    kill -TERM "$PID" 2>/dev/null
                    ;;
```

with:

```bash
                STOPPED)
                    log "[Warning] Process stopped: $CNAME (PID=$PID). Terminating process tree..."
                    kill -CONT "$PID" 2>/dev/null
                    kill_process_tree "$PID"
                    wait "$PID" 2>/dev/null
                    $DB_QUERY "UPDATE jobs SET status='FAILED', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Process was stopped (SIGSTOP), terminated' WHERE pid=$PID AND status='RUNNING';"
                    unset BG_PIDS["$CNAME"]
                    unset BG_PREV_STATE["$CNAME"]
                    unset BG_LAST_CPU["$CNAME"]
                    unset BG_IDLE_SINCE["$CNAME"]
                    ;;
```

This change:
- Removes the blocking `sleep 2`
- Uses `kill_process_tree` for full tree termination (SIGTERM → 3s grace → SIGKILL)
- Updates DB status to FAILED with descriptive message
- Cleans up all tracking arrays

- [ ] **Step 2: Run scheduler logic tests to verify no regression**

Run: `bash tests/test_scheduler_logic.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add bin/scheduler.sh
git commit -m "fix(scheduler): replace blocking STOPPED handler with process tree kill and DB update"
```

---

### Task 8: Fix 9 — `test_idle_timeout.sh` remove production DB dependency

**Files:**
- Modify: `tests/test_idle_timeout.sh:1-20,120-131`

- [ ] **Step 1: Apply the fix**

Replace the header section (lines 1-24) of `tests/test_idle_timeout.sh` with:

```bash
#!/bin/bash

# tests/test_idle_timeout.sh
# Test idle detection with process tree CPU sampling

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"
BIN_DIR="$PROJECT_ROOT/bin"

pass() { echo "[Pass] $1"; ((PASS++)); }
fail() { echo "[Fail] $1"; ((FAIL++)); }

echo "=============================="
echo "[Test] Idle Detection Tests"
echo "=============================="

# Source monitor.sh to get functions
source "$BIN_DIR/common.sh"
source "$BIN_DIR/monitor.sh"
```

Then replace the integration test setup section (lines 120-131) with:

```bash
# ===========================================
# Integration Tests (require DB and scheduler)
# ===========================================

# 1. Setup Test Environment using test_helper
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
```

And update the cleanup section at the end of the file (lines 242-244). Replace:

```bash
# Cleanup
rm -f "$TEST_DB"
rm -f "$TEMP_SCHEDULER"
```

with:

```bash
# Cleanup
cleanup_test_db "$TEST_DB"
rm -f "$TEMP_SCHEDULER"
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_idle_timeout.sh`
Expected: PASS — all cases pass using freshly created test DB instead of copying production DB.

- [ ] **Step 3: Commit**

```bash
git add tests/test_idle_timeout.sh
git commit -m "fix(test): remove production DB dependency in test_idle_timeout"
```

---

### Task 9: Fix 8 — Test isolation for `test_db_init.sh`

**Files:**
- Modify: `tests/test_db_init.sh`

Note: `test_db_init.sh` is special — it tests the schema creation itself, so it needs its own isolated path rather than using `setup_test_db()` (which already runs `init_db.sql`). The fix is to use an isolated test DB path instead of the production DB path.

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_db_init.sh` with:

```bash
#!/bin/bash

# tests/test_db_init.sh
# Database initialization test script

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_SQL="$PROJECT_ROOT/sql/init_db.sql"

# Use isolated test DB (not production)
DB_PATH="$PROJECT_ROOT/data/test_db_init_$$.db"
rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"

echo "[Test] Starting Database Initialization Test..."

# 1. Run Initialization
sqlite3 "$DB_PATH" < "$INIT_SQL"
if [ $? -ne 0 ]; then
    echo "[Fail] SQL execution failed."
    rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"
    exit 1
fi

# 2. Table existence check
TABLES=("services" "jobs" "heartbeat")
for table in "${TABLES[@]}"; do
    EXISTS=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';")
    if [ "$EXISTS" == "$table" ]; then
        echo "[Pass] Table '$table' exists."
    else
        echo "[Fail] Table '$table' does not exist."
        rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"
        exit 1
    fi
done

# 3. Cleanup
rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"

echo "[Success] Database initialization test passed!"
exit 0
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_db_init.sh`
Expected: PASS — all 3 tables exist, no production DB touched.

- [ ] **Step 3: Commit**

```bash
git add tests/test_db_init.sh
git commit -m "fix(test): isolate test_db_init from production database"
```

---

### Task 10: Fix 8 — Test isolation for `test_service_option.sh`

**Files:**
- Modify: `tests/test_service_option.sh`

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_service_option.sh` with:

```bash
#!/bin/bash

# tests/test_service_option.sh
# --service option functionality test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] CLI --service Option Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Setup Mock data
CONTAINER="service-test-cmd"
$DB_QUERY "INSERT OR IGNORE INTO services (container_name, priority) VALUES ('$CONTAINER', 100);"
S_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='$CONTAINER';")

# 3. Run --service for specific container
$PROJECT_ROOT/bin/scheduler.sh --service "$CONTAINER"
EXIT_STATUS=$?

if [ $EXIT_STATUS -eq 0 ]; then
    echo "[Pass] --service command exited with success."
else
    echo "[Fail] --service command failed with exit code $EXIT_STATUS."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 4. Verify record in jobs table
JOB_RECORD=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$S_ID ORDER BY start_time DESC LIMIT 1;")
if [ "$JOB_RECORD" == "COMPLETED" ]; then
    echo "[Pass] Job record created and status is COMPLETED."
else
    echo "[Fail] Job record not found or status is unexpected: '$JOB_RECORD'."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 5. Verify --service with non-existent container
echo "[Test] Testing with non-existent container..."
$PROJECT_ROOT/bin/scheduler.sh --service "non-existent-xyz" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[Pass] Correctly failed for non-existent container."
else
    echo "[Fail] Expected failure for non-existent container but got success."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

cleanup_test_db "$TEST_DB"

echo "[Success] --service option test passed!"
exit 0
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_service_option.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_service_option.sh
git commit -m "fix(test): isolate test_service_option from production database"
```

---

### Task 11: Fix 8 — Test isolation for `test_status_output.sh`

**Files:**
- Modify: `tests/test_status_output.sh`

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_status_output.sh` with:

```bash
#!/bin/bash

# tests/test_status_output.sh
# CLI status output test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] CLI Status Output Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Setup Mock data
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('test-container-1', 10);"
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('test-container-2', 5);"

# 3. Mock a job result
SERVICE_ID=$($DB_QUERY "SELECT id FROM services LIMIT 1;")
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time, end_time, duration) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', '-1 hour'), datetime('now'), 3600);"

# 4. Call scheduler with --status
OUTPUT=$($PROJECT_ROOT/bin/scheduler.sh --status)

echo "--- Received Output ---"
echo "$OUTPUT"
echo "--- End of Output ---"

if echo "$OUTPUT" | grep -q "Batch Job Execution Summary"; then
    echo "[Pass] Output contains summary header."
else
    echo "[Fail] Summary header not found."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

if echo "$OUTPUT" | grep -q "test-container-1"; then
    echo "[Pass] Output contains service name."
else
    echo "[Fail] Service name not found in output."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

cleanup_test_db "$TEST_DB"

echo "[Success] CLI status output tests passed!"
exit 0
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_status_output.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_status_output.sh
git commit -m "fix(test): isolate test_status_output from production database"
```

---

### Task 12: Fix 8 — Test isolation for `test_init_option.sh`

**Files:**
- Modify: `tests/test_init_option.sh`

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_init_option.sh` with:

```bash
#!/bin/bash

# tests/test_init_option.sh
# --init option functionality test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] CLI --init Option Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Setup Mock data (One recent, one old)
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('init-test-container', 1);"
SERVICE_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='init-test-container';")
# Recent job
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', 'localtime', '-1 hour'));"
# Old job (2 days ago)
$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SERVICE_ID, 'COMPLETED', datetime('now', 'localtime', '-2 days'));"

# 3. Verify records exist
COUNT_BEFORE=$($DB_QUERY "SELECT count(*) FROM jobs;")
if [ "$COUNT_BEFORE" -ge 2 ]; then
    echo "[Pass] Mock records created ($COUNT_BEFORE)."
else
    echo "[Fail] Mock record creation failed ($COUNT_BEFORE)."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 4. Run --init
$PROJECT_ROOT/bin/scheduler.sh --init

# 5. Verify ALL records deleted
COUNT_AFTER=$($DB_QUERY "SELECT count(*) FROM jobs;")
if [ "$COUNT_AFTER" -eq 0 ]; then
    echo "[Pass] All records cleared successfully."
else
    echo "[Fail] Records still exist ($COUNT_AFTER)."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

cleanup_test_db "$TEST_DB"

echo "[Success] --init option test passed!"
exit 0
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_init_option.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_init_option.sh
git commit -m "fix(test): isolate test_init_option from production database"
```

---

### Task 13: Fix 8 — Test isolation for `test_local_keyword_fix.sh`

**Files:**
- Modify: `tests/test_local_keyword_fix.sh`

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_local_keyword_fix.sh` with:

```bash
#!/bin/bash

# tests/test_local_keyword_fix.sh
# Test that job creation works (verifying local keyword fix)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] Local Keyword Fix Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Setup test service
CONTAINER="test-local-fix"
$DB_QUERY "INSERT OR IGNORE INTO services (container_name, priority) VALUES ('$CONTAINER', 100);"
S_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='$CONTAINER';")

# 3. Test --service command (this uses local at line 152, 160)
echo "[Test] Testing --service command job creation..."
$PROJECT_ROOT/bin/scheduler.sh --service "$CONTAINER" 2>&1 | grep -q "Error"
if [ $? -eq 0 ]; then
    echo "[Fail] --service command produced errors (likely due to 'local' outside function)"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

$PROJECT_ROOT/bin/scheduler.sh --service "$CONTAINER"
EXIT_STATUS=$?

if [ $EXIT_STATUS -eq 0 ]; then
    echo "[Pass] --service command exited with success."
else
    echo "[Fail] --service command failed with exit code $EXIT_STATUS."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 4. Verify job record was created
JOB_COUNT=$($DB_QUERY "SELECT count(*) FROM jobs WHERE service_id=$S_ID;")
if [ "$JOB_COUNT" -ge "1" ]; then
    echo "[Pass] Job record was created in database."
else
    echo "[Fail] Job record was NOT created (count: $JOB_COUNT). This indicates 'local' keyword error."
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# 5. Verify job status
JOB_STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$S_ID ORDER BY start_time DESC LIMIT 1;")
if [ "$JOB_STATUS" == "COMPLETED" ]; then
    echo "[Pass] Job completed successfully (status: $JOB_STATUS)."
else
    echo "[Pass] Job was created with status: $JOB_STATUS (creation successful even if not completed)."
fi

cleanup_test_db "$TEST_DB"

echo "[Success] Local keyword fix test passed!"
exit 0
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_local_keyword_fix.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_local_keyword_fix.sh
git commit -m "fix(test): isolate test_local_keyword_fix from production database"
```

---

### Task 14: Fix 8 — Test isolation for `test_orphan_recovery_fix.sh`

**Files:**
- Modify: `tests/test_orphan_recovery_fix.sh`

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_orphan_recovery_fix.sh` with:

```bash
#!/bin/bash

# tests/test_orphan_recovery_fix.sh
# Test that recovered jobs are not immediately marked ORPHANED

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

echo "[Test] Orphan Recovery Fix Test Started..."

# 1. Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# 2. Create test services
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('orphan-test-live', 100);"
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('orphan-test-dead', 50);"

SVC_LIVE=$($DB_QUERY "SELECT id FROM services WHERE container_name='orphan-test-live';")
SVC_DEAD=$($DB_QUERY "SELECT id FROM services WHERE container_name='orphan-test-dead';")

# 3. Start a background process that will stay alive
sleep 120 &
LIVE_PID=$!
DEAD_PID=99999

echo "[Setup] Live PID: $LIVE_PID (should be alive)"
echo "[Setup] Dead PID: $DEAD_PID (doesn't exist)"

# 4. Insert both jobs as RUNNING
$DB_QUERY "INSERT INTO jobs (service_id, status, pid, start_time) VALUES ($SVC_LIVE, 'RUNNING', $LIVE_PID, datetime('now', 'localtime'));"
$DB_QUERY "INSERT INTO jobs (service_id, status, pid, start_time) VALUES ($SVC_DEAD, 'RUNNING', $DEAD_PID, datetime('now', 'localtime'));"

# 5. Trigger scheduler recovery by running it briefly (outside working hours)
export START_TIME="23:00"
export END_TIME="23:01"
export CHECK_INTERVAL="1"

echo "[Test] Running scheduler to trigger recovery..."
timeout 3 bash "$PROJECT_ROOT/bin/scheduler.sh" > /dev/null 2>&1

# 6. Check results
STATUS_LIVE=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$SVC_LIVE ORDER BY id DESC LIMIT 1;")
STATUS_DEAD=$($DB_QUERY "SELECT status FROM jobs WHERE service_id=$SVC_DEAD ORDER BY id DESC LIMIT 1;")

echo "[Result] Live PID job status: $STATUS_LIVE"
echo "[Result] Dead PID job status: $STATUS_DEAD"

# Cleanup
kill $LIVE_PID 2>/dev/null
wait $LIVE_PID 2>/dev/null

# 7. Assertions
EXIT_CODE=0

if [ "$STATUS_LIVE" == "RUNNING" ]; then
    echo "[Pass] Live PID job remained RUNNING (not orphaned by blanket update)"
else
    echo "[Fail] Live PID job has status '$STATUS_LIVE' instead of RUNNING"
    EXIT_CODE=1
fi

if [ "$STATUS_DEAD" == "ORPHANED" ]; then
    echo "[Pass] Dead PID job was correctly marked ORPHANED"
else
    echo "[Fail] Dead PID job has status '$STATUS_DEAD' instead of ORPHANED"
    EXIT_CODE=1
fi

cleanup_test_db "$TEST_DB"

if [ $EXIT_CODE -eq 0 ]; then
    echo "[Success] Orphan recovery fix test passed!"
else
    echo "[Failure] Test revealed issues"
fi

exit $EXIT_CODE
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_orphan_recovery_fix.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_orphan_recovery_fix.sh
git commit -m "fix(test): isolate test_orphan_recovery_fix from production database"
```

---

### Task 15: Fix 8 — Test isolation for `test_db_error_handling.sh`

**Files:**
- Modify: `tests/test_db_error_handling.sh`

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_db_error_handling.sh` with:

```bash
#!/bin/bash
# tests/test_db_error_handling.sh

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

assert_error() {
    local query="$1"
    local desc="$2"
    local err_msg
    # Capture stderr
    err_msg=$($DB_QUERY "$query" 2>&1 >/dev/null)
    local exit_code=$?
    
    if [ "$exit_code" -ne 0 ]; then
        echo "[Pass] $desc (Exit: $exit_code)"
        PASS=$((PASS + 1))
    else
        echo "[Fail] $desc (Exit: $exit_code, expected non-zero)"
        FAIL=$((FAIL + 1))
    fi
}

echo "[Test] DB Error Handling Tests Started..."

# 1. Non-existent table
assert_error "SELECT * FROM non_existent_table;" "Querying non-existent table fails"

# 2. Syntax error
assert_error "SELEC * FROM services;" "Invalid SQL syntax fails"

# 3. Constraint violation
$DB_QUERY "INSERT INTO services (container_name) VALUES ('test-duplicate');"
assert_error "INSERT INTO services (container_name) VALUES ('test-duplicate');" "Duplicate UNIQUE constraint violation fails"

cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_db_error_handling.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_db_error_handling.sh
git commit -m "fix(test): isolate test_db_error_handling from production database"
```

---

### Task 16: Fix 8 — Test isolation for `test_db_query_fixes.sh`

**Files:**
- Modify: `tests/test_db_query_fixes.sh`

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_db_query_fixes.sh` with:

```bash
#!/bin/bash

# tests/test_db_query_fixes.sh
# Test db_query.sh exit code propagation and grep filter fixes

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

echo "[Test] DB Query Fixes Test Started..."

# Test 1: Exit code propagation - invalid SQL should return non-zero
echo "[Test 1] Testing exit code propagation for invalid SQL..."
$DB_QUERY "INVALID SQL SYNTAX HERE;" > /dev/null 2>&1
INVALID_EXIT=$?

if [ $INVALID_EXIT -ne 0 ]; then
    echo "[Pass] Invalid SQL returned non-zero exit code ($INVALID_EXIT)"
else
    echo "[Fail] Invalid SQL returned exit code 0 (should be non-zero)"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# Test 2: Exit code propagation - valid SQL should return zero
echo "[Test 2] Testing exit code propagation for valid SQL..."
$DB_QUERY "SELECT 1;" > /dev/null 2>&1
VALID_EXIT=$?

if [ $VALID_EXIT -eq 0 ]; then
    echo "[Pass] Valid SQL returned exit code 0"
else
    echo "[Fail] Valid SQL returned non-zero exit code ($VALID_EXIT)"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# Test 3: 5-digit results should not be filtered
echo "[Test 3] Testing that 5-digit query results are not filtered..."

TEST_CASES=("10000" "12345" "99999" "54321")
FAILURES=0

for VAL in "${TEST_CASES[@]}"; do
    RESULT=$($DB_QUERY "SELECT $VAL;")
    if [ "$RESULT" == "$VAL" ]; then
        echo "[Pass] Value $VAL was not filtered"
    else
        echo "[Fail] Value $VAL was filtered or modified (got: '$RESULT', expected: '$VAL')"
        FAILURES=$((FAILURES + 1))
    fi
done

# Test that leading zeros are handled by SQLite naturally (00001 -> 1)
RESULT=$($DB_QUERY "SELECT 00001;")
if [ "$RESULT" == "1" ]; then
    echo "[Pass] Value 00001 converted to 1 (normal SQLite integer behavior)"
else
    echo "[Fail] Value 00001 produced unexpected result: '$RESULT'"
    FAILURES=$((FAILURES + 1))
fi

if [ $FAILURES -gt 0 ]; then
    echo "[Test 3] Failed: $FAILURES values had issues"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

# Test 4: "wal" string (legitimate result) should not be filtered
echo "[Test 4] Testing that string 'wal' in results is not filtered..."
RESULT=$($DB_QUERY "SELECT 'wal';")
if [ "$RESULT" == "wal" ]; then
    echo "[Pass] String 'wal' was not filtered"
else
    echo "[Fail] String 'wal' was filtered (got: '$RESULT')"
    cleanup_test_db "$TEST_DB"
    exit 1
fi

cleanup_test_db "$TEST_DB"

echo "[Success] DB Query fixes test passed!"
exit 0
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_db_query_fixes.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_db_query_fixes.sh
git commit -m "fix(test): isolate test_db_query_fixes from production database"
```

---

### Task 17: Fix 8 — Test isolation for `test_orphan_status.sh`

**Files:**
- Modify: `tests/test_orphan_status.sh`

- [ ] **Step 1: Apply the fix**

Replace the full content of `tests/test_orphan_status.sh` with:

```bash
#!/bin/bash

# tests/test_orphan_status.sh
# Tests for ORPHANED status lifecycle

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"

# Setup isolated test DB
TEST_DB=$(setup_test_db)
export DB_PATH="$TEST_DB"

echo "[Test] ORPHANED Status Lifecycle Tests Started..."

# --- Setup ---
$DB_QUERY "INSERT INTO services (container_name, priority) VALUES ('orphan-svc-1', 10);"
SVC_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='orphan-svc-1';")

# ============================================================
# Test 1: Startup cleanup marks RUNNING → ORPHANED
# ============================================================
echo ""
echo "--- Test 1: Startup cleanup ---"

$DB_QUERY "INSERT INTO jobs (service_id, status, pid, start_time) VALUES ($SVC_ID, 'RUNNING', 99999, datetime('now', 'localtime'));"
JOB1_ID=$($DB_QUERY "SELECT id FROM jobs WHERE service_id=$SVC_ID AND status='RUNNING' AND pid=99999;")

$DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN' WHERE status='RUNNING' AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'));"

STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE id=$JOB1_ID;")
PSTATE=$($DB_QUERY "SELECT process_state FROM jobs WHERE id=$JOB1_ID;")

assert_eq "RUNNING job transitions to ORPHANED on startup" "ORPHANED" "$STATUS"
assert_eq "process_state set to UNKNOWN" "UNKNOWN" "$PSTATE"

# ============================================================
# Test 2: COMPLETED/FAILED process_state jobs are NOT orphaned
# ============================================================
echo ""
echo "--- Test 2: COMPLETED process_state preserved ---"

$DB_QUERY "INSERT INTO jobs (service_id, status, pid, process_state, start_time) VALUES ($SVC_ID, 'RUNNING', 88888, 'COMPLETED', datetime('now', 'localtime'));"
JOB2_ID=$($DB_QUERY "SELECT id FROM jobs WHERE service_id=$SVC_ID AND pid=88888;")

$DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN' WHERE status='RUNNING' AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'));"

STATUS=$($DB_QUERY "SELECT status FROM jobs WHERE id=$JOB2_ID;")
assert_eq "RUNNING job with process_state=COMPLETED is NOT orphaned" "RUNNING" "$STATUS"

# ============================================================
# Test 3: ORPHANED jobs are included in auto-expire
# ============================================================
echo ""
echo "--- Test 3: ORPHANED auto-expire ---"

$DB_QUERY "INSERT INTO jobs (service_id, status, process_state, start_time) VALUES ($SVC_ID, 'ORPHANED', 'UNKNOWN', datetime('now', 'localtime', '-2 hours'));"
JOB3_ID=$($DB_QUERY "SELECT id FROM jobs WHERE service_id=$SVC_ID AND status='ORPHANED' AND start_time < datetime('now', 'localtime', '-1 hour') LIMIT 1;")

STALE_LIMIT=600
STALE=$($DB_QUERY "SELECT id FROM jobs WHERE status IN ('RUNNING', 'ORPHANED') AND start_time < datetime('now', 'localtime', '-${STALE_LIMIT} seconds') AND id=$JOB3_ID;")
assert_eq "ORPHANED job older than STALE_LIMIT is found by expire query" "$JOB3_ID" "$STALE"

# ============================================================
# Test 4: ORPHANED service is excluded from next-job query
# ============================================================
echo ""
echo "--- Test 4: ORPHANED blocks re-scheduling ---"

$DB_QUERY "INSERT INTO services (container_name, priority, is_active) VALUES ('orphan-svc-2', 5, 1);"
SVC2_ID=$($DB_QUERY "SELECT id FROM services WHERE container_name='orphan-svc-2';")

NEXT=$($DB_QUERY "SELECT s.id FROM services s
    WHERE s.is_active=1
    AND NOT EXISTS (
        SELECT 1 FROM jobs j
        WHERE j.service_id = s.id
        AND j.start_time > datetime('now', 'localtime', '-23 hours')
        AND j.status IN ('RUNNING', 'COMPLETED', 'ORPHANED')
    )
    ORDER BY s.priority DESC LIMIT 1;")

assert_eq "ORPHANED service excluded; next job selects svc-2" "$SVC2_ID" "$NEXT"

# ============================================================
# Test 5: CHECK constraint accepts ORPHANED and TIMEOUT
# ============================================================
echo ""
echo "--- Test 5: CHECK constraint ---"

$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SVC_ID, 'ORPHANED', datetime('now', 'localtime'));" 2>/dev/null
ORPHAN_OK=$?
assert_eq "INSERT with status=ORPHANED succeeds" "0" "$ORPHAN_OK"

$DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SVC_ID, 'TIMEOUT', datetime('now', 'localtime'));" 2>/dev/null
TIMEOUT_OK=$?
assert_eq "INSERT with status=TIMEOUT succeeds" "0" "$TIMEOUT_OK"

# ============================================================
# Test 6: --status output shows ORPHANED
# ============================================================
echo ""
echo "--- Test 6: --status output ---"

OUTPUT=$($PROJECT_ROOT/bin/scheduler.sh --status 2>/dev/null)
if echo "$OUTPUT" | grep -q "ORPHANED"; then
    echo "[Pass] --status output contains ORPHANED"
    PASS=$((PASS + 1))
else
    echo "[Fail] --status output does not show ORPHANED"
    FAIL=$((FAIL + 1))
fi

# --- Cleanup ---
cleanup_test_db "$TEST_DB"

print_test_summary
exit $?
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_orphan_status.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_orphan_status.sh
git commit -m "fix(test): isolate test_orphan_status from production database"
```

---

### Task 18: Run full test suite for regression check

**Files:** None modified — verification only

- [ ] **Step 1: Run all test files**

```bash
for test in tests/test_*.sh; do
    echo "=== $test ==="
    timeout 120 bash "$test"
    echo "Exit code: $?"
    echo ""
done
```

Expected: All tests PASS. If any fail, investigate and fix before proceeding.

- [ ] **Step 2: Commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address test regressions from Phase 10 bug fixes"
```

(Skip this step if no fixes were needed.)

---

## Verification

After all tasks are complete:

1. **Runtime fixes:** All 6 runtime bugs addressed in `bin/scheduler.sh`, `bin/monitor.sh`, `bin/migrate_db.sh`
2. **Test fixes:** All 8 modified test files pass independently
3. **Regression:** Full test suite `tests/test_*.sh` passes with exit code 0
4. **Isolation:** No test touches `data/scheduler.db` or the production DB path
