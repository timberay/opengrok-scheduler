#!/bin/bash

# bin/scheduler.sh
# Batch Job Scheduler Main Script

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

source "$PROJECT_ROOT/bin/monitor.sh"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
JOB_TIMEOUT_SEC="${JOB_TIMEOUT_SEC:-36000}"
export JOB_TIMEOUT_SEC
JOB_IDLE_TIMEOUT="${JOB_IDLE_TIMEOUT:-300}"
export JOB_IDLE_TIMEOUT

# If LOG_DIR is relative, prepend PROJECT_ROOT
if [[ "$LOG_DIR" != /* ]]; then
    LOG_DIR="$PROJECT_ROOT/$LOG_DIR"
fi

mkdir -p "$LOG_DIR"

# Function to check if current time is within range
# Supports cross-day ranges (e.g. 18:00 to 06:00)
check_time_range() {
    local START=$1
    local END=$2
    local CURRENT=${3:-$(date +%H:%M)}
    
    # Convert to minutes from midnight
    local S_MIN=$(( $(date -d "$START" +%-H)*60 + $(date -d "$START" +%-M) ))
    local E_MIN=$(( $(date -d "$END" +%-H)*60 + $(date -d "$END" +%-M) ))
    local C_MIN=$(( $(date -d "$CURRENT" +%-H)*60 + $(date -d "$CURRENT" +%-M) ))
    
    if [ "$S_MIN" -le "$E_MIN" ]; then
        if [ "$C_MIN" -ge "$S_MIN" ] && [ "$C_MIN" -lt "$E_MIN" ]; then
            echo "true"; return 0
        fi
    else
        # Cross-day (e.g. 18:00 to 06:00)
        if [ "$C_MIN" -ge "$S_MIN" ] || [ "$C_MIN" -lt "$E_MIN" ]; then
            echo "true"; return 0
        fi
    fi
    echo "false"; return 1
}

# Subroutine to log to console and DB if needed
log() {
    local LOG_FILE="$LOG_DIR/scheduler_$(date +%Y%m%d).log"
    local MESSAGE="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$MESSAGE"
    echo "$MESSAGE" >> "$LOG_FILE"
}

# Helper to format duration
format_duration() {
    local SECS=$1
    if [ -z "$SECS" ]; then echo "-"; return; fi
    local H=$((SECS / 3600))
    local M=$(( (SECS % 3600) / 60 ))
    local S=$((SECS % 60))
    printf "%dh %dm %ds" "$H" "$M" "$S"
}

# Run lifecycle helpers — cycle-based history.
# Each "run" is one scheduling cycle: opened on window entry (idempotent),
# closed when all services have a row OR the window ends OR the scheduler
# shuts down. State machine: RUNNING → {COMPLETED | PARTIAL | ABORTED}.

# Open a new run if none is currently RUNNING. Idempotent: returns the
# existing run id when called repeatedly within the same cycle. Race-safe
# under concurrent callers — the eligibility check (no other RUNNING run)
# runs *inside* the IMMEDIATE-locked transaction via WHERE NOT EXISTS,
# matching the job-admission pattern at the bottom of the main loop.
# Args: $1 = triggered_by value ('auto' | 'manual' | 'init'). Defaults to 'auto'.
# Stdout: the run id (integer). Returns non-zero on error (with empty stdout).
run_open_if_none() {
    local TRIGGERED_BY="${1:-auto}"
    case "$TRIGGERED_BY" in
        auto|manual|init) ;;
        *) log "[Error] run_open_if_none: invalid triggered_by '$TRIGGERED_BY' (must be auto|manual|init)"; return 1 ;;
    esac

    local RESULT
    RESULT=$($DB_QUERY "BEGIN IMMEDIATE; \
INSERT INTO runs (started_at, status, triggered_by, total_services) \
SELECT datetime('now', 'localtime'), 'RUNNING', '$TRIGGERED_BY', \
       (SELECT COUNT(*) FROM services WHERE is_active=1) \
WHERE NOT EXISTS (SELECT 1 FROM runs WHERE status='RUNNING'); \
SELECT CASE WHEN changes() > 0 \
            THEN last_insert_rowid() \
            ELSE (SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1) \
       END; \
COMMIT;") || { log "[Error] run_open_if_none: db query failed"; return 1; }

    if [ -z "$RESULT" ] || ! [[ "$RESULT" =~ ^[0-9]+$ ]]; then
        log "[Error] run_open_if_none: unexpected DB result '$RESULT'"
        return 1
    fi
    echo "$RESULT"
}

# Return the id of the currently RUNNING run, or empty if none.
run_current_id() {
    $DB_QUERY "SELECT id FROM runs WHERE status='RUNNING' ORDER BY id DESC LIMIT 1;"
}

# Close a run: aggregate per-status job counts into the row, set ended_at,
# and switch status. Args: $1 = run id, $2 = terminal status
# (COMPLETED | PARTIAL | ABORTED). Returns non-zero if args are missing
# or the DB call fails.
run_close() {
    local RUN_ID="$1"
    local FINAL_STATUS="$2"
    if [ -z "$RUN_ID" ] || [ -z "$FINAL_STATUS" ]; then
        log "[Error] run_close: missing args (run_id='$RUN_ID', status='$FINAL_STATUS')"
        return 1
    fi
    case "$FINAL_STATUS" in
        COMPLETED|PARTIAL|ABORTED) ;;
        *) log "[Error] run_close: invalid status '$FINAL_STATUS' (must be COMPLETED|PARTIAL|ABORTED)"; return 1 ;;
    esac
    $DB_QUERY "UPDATE runs SET
        status='$FINAL_STATUS',
        ended_at=datetime('now', 'localtime'),
        completed_count=(SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='COMPLETED'),
        failed_count=(SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='FAILED'),
        timeout_count=(SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='TIMEOUT'),
        orphaned_count=(SELECT COUNT(*) FROM jobs WHERE run_id=$RUN_ID AND status='ORPHANED')
        WHERE id=$RUN_ID;" || { log "[Error] run_close: db update failed for run_id=$RUN_ID"; return 1; }
    return 0
}

# Function to execute indexing task and return exit code
run_indexing_task() {
    local CONTAINER_NAME=$1
    local MAX_DURATION=${JOB_TIMEOUT_SEC:-36000}
    
    # ----------------------------------------------------------------------
    # [MODIFY] Enter the actual indexing command in the section below.
    # e.g. docker exec "$CONTAINER_NAME" /usr/local/bin/indexer
    # ----------------------------------------------------------------------
    
    # Actual command execution (Keep stdin isolated, run with absolute timeout)
    # --kill-after=10s: SIGTERM the whole process group at MAX_DURATION; if any group
    # member is still alive 10s later, escalate to SIGKILL. Prevents grandchild leaks
    # when the wrapped command spawns subprocesses that ignore SIGTERM.
    timeout --kill-after=10s "$MAX_DURATION" bash -c "sleep 2" < /dev/null 2>&1 # REPLACEME: docker exec "$CONTAINER_NAME" /usr/local/bin/indexer
    return $?
}

# Kill an entire process tree: SIGTERM first, SIGKILL after grace period.
# Args: PID [EXPECTED_STARTTIME]
#
# Refuses invalid/reserved PIDs (empty / non-numeric / <=1) — see comments
# above the regex for the threats those represent.
#
# When EXPECTED_STARTTIME is supplied, the function re-verifies (PID,
# starttime) identity immediately before each signal pass. This narrows
# the TOCTOU window between an upstream identity check (e.g. stale-expire)
# and the actual `kill` syscall: if the original process exited and the
# kernel recycled the PID to an unrelated process during that gap,
# verify_pid_identity now fails and the kill is aborted. The window is
# not closed entirely (signals are still individual syscalls), but it
# shrinks from "hundreds of microseconds of bash interpretation" to
# "the gap between two consecutive kill calls".
kill_process_tree() {
    local ROOT_PID=$1
    local EXPECTED_STARTTIME=$2
    if ! [[ "$ROOT_PID" =~ ^[0-9]+$ ]] || [ "$ROOT_PID" -le 1 ]; then
        echo "[Error] kill_process_tree: refusing invalid/reserved PID '$ROOT_PID'" >&2
        return 1
    fi
    if [ -n "$EXPECTED_STARTTIME" ] && ! verify_pid_identity "$ROOT_PID" "$EXPECTED_STARTTIME"; then
        echo "[Warning] kill_process_tree: PID $ROOT_PID identity check failed before SIGTERM, aborting kill." >&2
        return 1
    fi
    local DESCENDANTS
    DESCENDANTS=$(get_descendant_pids "$ROOT_PID")

    # Kill leaf-to-root order: descendants first, then root
    local ALL_PIDS_REVERSED=""
    for PID in $DESCENDANTS; do
        ALL_PIDS_REVERSED="$PID $ALL_PIDS_REVERSED"
    done

    # SIGTERM to all (descendants first, then root)
    for PID in $ALL_PIDS_REVERSED $ROOT_PID; do
        kill -TERM "$PID" 2>/dev/null
    done

    # Grace period — generous enough to span timeout(1)'s own --kill-after
    # escalation so SIGTERM-respecting workloads can finish cleanup before
    # we escalate to SIGKILL.
    sleep "${KILL_GRACE_SEC:-10}"

    # Re-verify identity once more before SIGKILL — last chance to bail
    # out if the original process exited and the PID was recycled during
    # the grace period.
    if [ -n "$EXPECTED_STARTTIME" ] && ! verify_pid_identity "$ROOT_PID" "$EXPECTED_STARTTIME"; then
        echo "[Warning] kill_process_tree: PID $ROOT_PID identity check failed before SIGKILL, aborting." >&2
        return 1
    fi

    # SIGKILL any survivors
    for PID in $ALL_PIDS_REVERSED $ROOT_PID; do
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
    done
}

# Main Execution Loop (Only run if not sourced with --no-run)
if [[ "$1" != "--no-run" ]]; then

    MODE_SEQUENCE=false
    for arg in "$@"; do
        if [[ "$arg" == "--sequence" ]]; then
            MODE_SEQUENCE=true
        fi
    done

    # Handle --status argument
    if [[ "$1" == "--status" ]]; then
        echo "[Batch Job Execution Summary]"
        echo "-------------------------------------------------------------------------------------------------------------"
        printf "%-25s | %-12s | %-10s | %-20s | %-12s | %-20s\n" "Service Name" "Status" "Process" "Start Time" "Duration" "Message"
        echo "-------------------------------------------------------------------------------------------------------------"
        
        # Filter query results based on the last 23 hours
        QUERY="SELECT s.container_name, j.status, COALESCE(j.process_state, '-'), j.start_time, j.duration, j.message 
               FROM services s 
               LEFT JOIN jobs j ON s.id = j.service_id 
               WHERE (j.start_time > datetime('now', 'localtime', '-23 hours') OR j.start_time IS NULL)
               ORDER BY j.start_time DESC LIMIT 50;"
        
        $DB_QUERY "$QUERY" | while IFS='|' read -r name status proc_state start duration msg; do
            [[ -z "$name" ]] && continue
            F_DURATION=$(format_duration "$duration")
            printf "%-25s | %-12s | %-10s | %-20s | %-12s | %-20s\n" "$name" "${status:-WAITING}" "$proc_state" "${start:--}" "$F_DURATION" "${msg:--}"
        done
        echo "-------------------------------------------------------------------------------------------------------------"
        
        TOTAL=$($DB_QUERY "SELECT count(*) FROM services;")
        DONE=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='COMPLETED' AND start_time > datetime('now', 'localtime', '-23 hours');")
        echo "Total: $TOTAL | Done (Last 23h): $DONE"
        exit 0
    fi

    # Handle --init argument
    if [[ "$1" == "--init" ]]; then
        log "Initializing all job records..."
        # Check if any job is currently RUNNING
        RUNNING_JOBS=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='RUNNING';")
        if [ "$RUNNING_JOBS" -gt 0 ]; then
            log "[Warning] There are $RUNNING_JOBS jobs currently in 'RUNNING' status."
            log "Force initializing anyway..."
        fi
        
        $DB_QUERY "DELETE FROM jobs;"
        log "All job records have been cleared."
        exit 0
    fi

    # Handle --service argument
    if [[ "$1" == "--service" ]]; then
        TARGET_CONTAINER=$2
        if [ -z "$TARGET_CONTAINER" ]; then
            echo "[Error] Please provide a container name. Usage: $0 --service <container_name>"
            exit 1
        fi
        
        validate_name "$TARGET_CONTAINER" || exit 1
        
        SERVICE_INFO=$($DB_QUERY "SELECT id, container_name FROM services WHERE container_name='$TARGET_CONTAINER';")
        if [ -z "$SERVICE_INFO" ]; then
            echo "[Error] Service '$TARGET_CONTAINER' not found in database."
            exit 1
        fi
        
        S_ID=$(echo "$SERVICE_INFO" | cut -d'|' -f1)
        S_NAME=$(echo "$SERVICE_INFO" | cut -d'|' -f2)
        
        log "Manually starting batch job for $S_NAME..."

        # Concurrency cap applies to manual trigger too — prevents bypassing the ceiling
        # that protects against indexing-phase thundering herd.
        MANUAL_MAX_CONCURRENT=${MAX_CONCURRENT_JOBS:-3}
        if ! [[ "$MANUAL_MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]]; then
            MANUAL_MAX_CONCURRENT=3
        fi

        # Atomic INSERT-if-under-cap: race-safe against main-loop scheduler
        JOB_ID=$($DB_QUERY "BEGIN IMMEDIATE; \
INSERT INTO jobs (service_id, status, start_time) \
SELECT $S_ID, 'RUNNING', datetime('now', 'localtime') \
WHERE (SELECT COUNT(*) FROM jobs WHERE status='RUNNING') < $MANUAL_MAX_CONCURRENT; \
SELECT CASE WHEN changes() > 0 THEN last_insert_rowid() ELSE 0 END; \
COMMIT;")

        if [ $? -ne 0 ] || [ -z "$JOB_ID" ]; then
            log "[Error] Failed to create job record in database for $S_NAME. Skipping..."
            exit 1
        fi

        if [ "$JOB_ID" = "0" ]; then
            CURRENT=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING';")
            log "[Error] Concurrency cap reached: $CURRENT/$MANUAL_MAX_CONCURRENT jobs already running. Cannot start '$S_NAME'."
            exit 1
        fi

        run_indexing_task "$S_NAME"
        REAP_EXIT=$?
        
        if [ "$REAP_EXIT" -eq 124 ]; then
            $DB_QUERY "UPDATE jobs SET status='TIMEOUT', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Max duration limit exceeded' WHERE id=$JOB_ID;"
            log "[Warning] Batch job $S_NAME timed out after ${JOB_TIMEOUT_SEC}s."
        elif [ "$REAP_EXIT" -eq 0 ]; then
            $DB_QUERY "UPDATE jobs SET status='COMPLETED', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER) WHERE id=$JOB_ID;"
            log "Batch job $S_NAME completed successfully."
        else
            $DB_QUERY "UPDATE jobs SET status='FAILED', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Exit code $REAP_EXIT' WHERE id=$JOB_ID;"
            log "Batch job $S_NAME failed with exit code $REAP_EXIT."
        fi
        
        exit $REAP_EXIT
    fi

    # --- Single-instance lock (advisory flock) ---
    # Prevents two scheduler main-loops from running against the same DB.
    # Without this, parallel instances would race recovery logic and
    # SIGKILL each other's tracked PIDs (critical issue #5 of the
    # kill-path review). The lock is per-DB so isolated test DBs do
    # not collide with the production scheduler.
    # The lock is released automatically when this process exits — flock
    # is bound to the file descriptor's lifetime, so crashes also release.
    LOCK_FILE="${DB_PATH}.lock"
    exec {SCHEDULER_LOCK_FD}>>"$LOCK_FILE" || {
        echo "[Error] Failed to open lock file: $LOCK_FILE" >&2
        exit 1
    }
    if ! flock -n "$SCHEDULER_LOCK_FD"; then
        OTHER_PID=$(head -1 "$LOCK_FILE" 2>/dev/null)
        echo "[Error] Another scheduler instance is already running (PID=${OTHER_PID:-unknown}, lock=$LOCK_FILE). Refusing to start." >&2
        exit 1
    fi
    # Record our PID for diagnostics. Truncates via a separate FD; the
    # advisory lock is on the inode, so write-truncation does not break it.
    printf '%s\n' "$$" >"$LOCK_FILE"

    log "Batch Job Scheduler Started."

    # Automatic Log Cleanup moved to loop
    LAST_LOG_CLEANUP=""

    # Run Database Migration (ensure schema is up-to-date)
    "$PROJECT_ROOT/bin/migrate_db.sh"
    
    # PID Tracking and State Management
    declare -A BG_PIDS       # KEY=CONTAINER_NAME, VALUE=PID
    declare -A BG_PREV_STATE  # KEY=CONTAINER_NAME, VALUE=last known state
    declare -A BG_LAST_CPU    # KEY=CONTAINER_NAME, VALUE=last sampled CPU jiffies
    declare -A BG_IDLE_SINCE  # KEY=CONTAINER_NAME, VALUE=epoch when idle started (0=active)

    # Graceful shutdown handler
    cleanup_and_exit() {
        log "Received shutdown signal. Cleaning up..."
        for CNAME in "${!BG_PIDS[@]}"; do
            local PID=${BG_PIDS[$CNAME]}
            log "Terminating $CNAME (PID=$PID)..."
            kill_process_tree "$PID"
            $DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='EXITED',
                       end_time=datetime('now', 'localtime'),
                       duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
                       message='Scheduler shutdown' WHERE pid=$PID AND status='RUNNING';"
        done
        log "Shutdown complete."
        exit 0
    }
    trap cleanup_and_exit SIGTERM SIGINT

    reap_bg_processes() {
        for CNAME in "${!BG_PIDS[@]}"; do
            local PID=${BG_PIDS[$CNAME]}
            local STATE=$(get_process_state "$PID")
            local PREV=${BG_PREV_STATE[$CNAME]:-""}

            # Update DB only when state changes
            if [ "$STATE" != "$PREV" ]; then
                $DB_QUERY "UPDATE jobs SET process_state='$STATE' WHERE pid=$PID AND status='RUNNING';"
                BG_PREV_STATE["$CNAME"]="$STATE"
            fi

            case "$STATE" in
                EXITED)
                    wait "$PID" 2>/dev/null
                    local REAP_EXIT=$?
                    log "Process finished: $CNAME (PID=$PID, exit=$REAP_EXIT)"
                    if [ "$REAP_EXIT" -eq 124 ]; then
                        $DB_QUERY "UPDATE jobs SET status='TIMEOUT', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Max duration limit exceeded' WHERE pid=$PID AND status='RUNNING';"
                    elif [ "$REAP_EXIT" -eq 0 ]; then
                        $DB_QUERY "UPDATE jobs SET status='COMPLETED', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER) WHERE pid=$PID AND status='RUNNING';"
                    else
                        $DB_QUERY "UPDATE jobs SET status='FAILED', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Exit code $REAP_EXIT' WHERE pid=$PID AND status='RUNNING';"
                    fi
                    unset BG_PIDS["$CNAME"]
                    unset BG_PREV_STATE["$CNAME"]
                    unset BG_LAST_CPU["$CNAME"]
                    unset BG_IDLE_SINCE["$CNAME"]
                    ;;
                ZOMBIE)
                    wait "$PID" 2>/dev/null
                    local REAP_EXIT=$?
                    log "[Warning] Zombie reaped: $CNAME (PID=$PID, exit=$REAP_EXIT)"
                    if [ "$REAP_EXIT" -eq 124 ]; then
                        $DB_QUERY "UPDATE jobs SET status='TIMEOUT', process_state='EXITED',
                                   end_time=datetime('now', 'localtime'),
                                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
                                   message='Zombie reaped - timeout' WHERE pid=$PID AND status='RUNNING';"
                    elif [ "$REAP_EXIT" -eq 0 ]; then
                        $DB_QUERY "UPDATE jobs SET status='COMPLETED', process_state='EXITED',
                                   end_time=datetime('now', 'localtime'),
                                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER)
                                   WHERE pid=$PID AND status='RUNNING';"
                    else
                        $DB_QUERY "UPDATE jobs SET status='FAILED', process_state='EXITED',
                                   end_time=datetime('now', 'localtime'),
                                   duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER),
                                   message='Zombie reaped - exit $REAP_EXIT' WHERE pid=$PID AND status='RUNNING';"
                    fi
                    unset BG_PIDS["$CNAME"]
                    unset BG_PREV_STATE["$CNAME"]
                    unset BG_LAST_CPU["$CNAME"]
                    unset BG_IDLE_SINCE["$CNAME"]
                    ;;
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
                DISK_WAIT)
                    log "[Warning] Process in uninterruptible I/O: $CNAME (PID=$PID). Will retry on next reap cycle."
                    ;;
                RUNNING|SLEEPING)
                    # Idle detection: sample CPU time across process tree
                    if [ "${JOB_IDLE_TIMEOUT:-0}" -gt 0 ]; then
                        local CURRENT_CPU
                        CURRENT_CPU=$(get_tree_cpu_time "$PID")

                        # Validate: if process vanished mid-sample, skip this cycle
                        if [[ ! "$CURRENT_CPU" =~ ^[0-9]+$ ]]; then
                            BG_LAST_CPU["$CNAME"]=""
                            continue
                        fi

                        local LAST_CPU=${BG_LAST_CPU[$CNAME]:-""}

                        if [ -n "$LAST_CPU" ] && [ "$CURRENT_CPU" -eq "$LAST_CPU" ]; then
                            # CPU time unchanged — process tree may be idle
                            if [ "${BG_IDLE_SINCE[$CNAME]:-0}" -eq 0 ]; then
                                BG_IDLE_SINCE["$CNAME"]=$(date +%s)
                                log "[Idle] $CNAME (PID=$PID): CPU time unchanged at $CURRENT_CPU jiffies. Monitoring..."
                            else
                                local NOW
                                NOW=$(date +%s)
                                local ELAPSED=$(( NOW - BG_IDLE_SINCE[$CNAME] ))
                                if [ "$ELAPSED" -ge "$JOB_IDLE_TIMEOUT" ]; then
                                    log "[Idle Timeout] $CNAME (PID=$PID): idle for ${ELAPSED}s (limit: ${JOB_IDLE_TIMEOUT}s). Terminating..."
                                    kill_process_tree "$PID"
                                    wait "$PID" 2>/dev/null
                                    $DB_QUERY "UPDATE jobs SET status='TIMEOUT', process_state='EXITED', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Idle timeout after ${ELAPSED}s' WHERE pid=$PID AND status='RUNNING';"
                                    unset BG_PIDS["$CNAME"]
                                    unset BG_PREV_STATE["$CNAME"]
                                    unset BG_LAST_CPU["$CNAME"]
                                    unset BG_IDLE_SINCE["$CNAME"]
                                fi
                            fi
                        else
                            # CPU time changed or first sample — reset idle timer
                            BG_IDLE_SINCE["$CNAME"]=0
                        fi

                        BG_LAST_CPU["$CNAME"]=$CURRENT_CPU
                    fi
                    ;;
            esac
        done
    }

    # Detect legacy RUNNING rows lacking pid_starttime (left over from a
    # pre-(PID,starttime) scheduler version). They cannot be identity-verified
    # and will be marked ORPHANED below; surface a single explicit log line
    # so the operator knows the cause is a one-shot upgrade artifact, not a
    # routine recovery failure.
    LEGACY_COUNT=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING' AND pid IS NOT NULL AND pid_starttime IS NULL;")
    if [ -n "$LEGACY_COUNT" ] && [ "$LEGACY_COUNT" -gt 0 ]; then
        log "[Migration] Found $LEGACY_COUNT legacy RUNNING job(s) without recorded starttime. They will be marked ORPHANED (no kill issued). If their underlying processes are still running, terminate them manually or wait for stale auto-expire."
    fi

    # Attempt to recover previously RUNNING jobs by checking process identity.
    # We compare the recorded (PID, starttime) tuple against /proc — comm
    # alone was insufficient because common names like 'bash'/'sleep' produce
    # false matches against unrelated user processes that happen to inherit
    # a recycled PID, and a successful match would lead us to SIGKILL them.
    log "Attempting to recover previously RUNNING jobs..."
    RECOVER_JOBS=$($DB_QUERY "SELECT j.id, j.pid, j.pid_starttime, s.container_name FROM jobs j JOIN services s ON j.service_id=s.id WHERE j.status='RUNNING' AND j.pid IS NOT NULL;")
    RECOVERED_PIDS=()
    if [ -n "$RECOVER_JOBS" ]; then
        while IFS='|' read -r JID JPID JSTART JCNAME; do
            if [ -n "$JSTART" ] && verify_pid_identity "$JPID" "$JSTART"; then
                log "[Recovery] Restored job tracking for $JCNAME (PID=$JPID, starttime=$JSTART)"
                BG_PIDS["$JCNAME"]=$JPID
                BG_PREV_STATE["$JCNAME"]="RUNNING"
                RECOVERED_PIDS+=("$JPID")
            else
                log "[Warning] PID $JPID for $JCNAME failed identity check (missing or mismatched starttime). Marking ORPHANED without kill."
                $DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN' WHERE id=$JID;"
            fi
        done <<< "$RECOVER_JOBS"
    fi

    # Mark any remaining RUNNING jobs as ORPHANED, excluding recovered PIDs
    if [ ${#RECOVERED_PIDS[@]} -gt 0 ]; then
        PID_LIST=$(IFS=','; echo "${RECOVERED_PIDS[*]}")
        $DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN'
                   WHERE status='RUNNING'
                   AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'))
                   AND (pid IS NULL OR pid NOT IN ($PID_LIST));"
    else
        $DB_QUERY "UPDATE jobs SET status='ORPHANED', process_state='UNKNOWN'
                   WHERE status='RUNNING'
                   AND (process_state IS NULL OR process_state NOT IN ('COMPLETED', 'FAILED'));"
    fi

    CURRENT_RUN_ID=""
    while true; do
        # Log Cleanup (Keep last N days)
        CUR_DATE=$(date +%Y%m%d)
        if [ "$LAST_LOG_CLEANUP" != "$CUR_DATE" ]; then
            LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-30}
            find "$LOG_DIR" -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
            log "Cleaned up logs older than ${LOG_RETENTION_DAYS} days."
            LAST_LOG_CLEANUP="$CUR_DATE"
        fi

        # 0. Update Heartbeat (Signal liveness)
        $DB_QUERY "REPLACE INTO heartbeat (id, last_pulse) VALUES (1, datetime('now', 'localtime'));"
        
        reap_bg_processes

        # 0. Auto-expire stale RUNNING jobs (no activity for 2x timeout duration)
        STALE_LIMIT=$((${JOB_TIMEOUT_SEC:-36000} * 2))
        STALE_JOBS=$($DB_QUERY "SELECT j.id, j.pid, j.pid_starttime, s.container_name FROM jobs j JOIN services s ON j.service_id=s.id WHERE j.status IN ('RUNNING', 'ORPHANED') AND j.start_time < datetime('now', 'localtime', '-${STALE_LIMIT} seconds');")
        if [ -n "$STALE_JOBS" ]; then
            while IFS='|' read -r JID JPID JSTART JCNAME; do
                log "[Warning] Expiring stale job id=$JID ($JCNAME, PID=$JPID)."
                # Only kill if PID identity still matches. After 2x JOB_TIMEOUT_SEC
                # (default 20h) the original PID has almost certainly been recycled
                # to a different process; killing it blindly would tear down an
                # unrelated process tree.
                if [ -n "$JPID" ] && [ -n "$JSTART" ]; then
                    # Pass starttime so kill_process_tree re-verifies identity
                    # immediately before SIGTERM and again before SIGKILL,
                    # narrowing the TOCTOU window if the PID was recycled
                    # between this select and the actual kill syscalls.
                    kill_process_tree "$JPID" "$JSTART" || \
                        log "[Warning] Skipped kill for $JCNAME: identity check failed (PID=$JPID likely recycled)."
                elif [ -n "$JPID" ]; then
                    log "[Warning] Skipping kill for $JCNAME: PID=$JPID has no recorded starttime (legacy row)."
                fi
                $DB_QUERY "UPDATE jobs SET status='TIMEOUT', end_time=datetime('now', 'localtime'), duration=CAST((julianday('now', 'localtime') - julianday(start_time)) * 86400 AS INTEGER), message='Stale auto-expired' WHERE id=$JID;"
                unset BG_PIDS["$JCNAME"] 2>/dev/null
                unset BG_PREV_STATE["$JCNAME"] 2>/dev/null
                unset BG_LAST_CPU["$JCNAME"] 2>/dev/null
                unset BG_IDLE_SINCE["$JCNAME"] 2>/dev/null
            done <<< "$STALE_JOBS"
        fi

        # 1. Load Config (Use environment variables with defaults)
        START=${START_TIME:-18:00}
        END=${END_TIME:-06:00}
        THRESHOLD=${RESOURCE_THRESHOLD:-70}
        INTERVAL=${CHECK_INTERVAL:-300}
        MAX_CONCURRENT=${MAX_CONCURRENT_JOBS:-3}
        if ! [[ "$MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]]; then
            log "[Warning] MAX_CONCURRENT_JOBS='$MAX_CONCURRENT' invalid (must be positive integer). Falling back to 3."
            MAX_CONCURRENT=3
        fi

        # 2. Check Time Range — also tracks run lifecycle transitions.
        if ! check_time_range "$START" "$END" > /dev/null; then
            # If we just exited the window with an open run that still has
            # incomplete services, mark it PARTIAL. (Natural-completion close
            # below would have already moved status off RUNNING.)
            #
            # Read from DB via run_current_id rather than the in-memory
            # $CURRENT_RUN_ID — this path must survive a scheduler restart
            # mid-night without leaking a stale RUNNING row.
            OPEN_RUN=$(run_current_id)
            if [ -n "$OPEN_RUN" ]; then
                log "Window closed with run #$OPEN_RUN still open — marking PARTIAL."
                run_close "$OPEN_RUN" PARTIAL
                CURRENT_RUN_ID=""
            fi
            log "Outside working hours ($START ~ $END). Sleeping..."
        else
            # Idempotent: opens a new run only if none is currently RUNNING.
            CURRENT_RUN_ID=$(run_open_if_none auto)
            if [ -z "$CURRENT_RUN_ID" ]; then
                log "[Error] Failed to open or recover a run. Retrying in 30s..."
                sleep 30
                continue
            fi

            # 3. Get Next Job (Exclude services already attempted in this run)
            QUERY="SELECT s.id FROM services s 
                   LEFT JOIN (
                       SELECT service_id, AVG(duration) as avg_duration 
                       FROM jobs 
                       WHERE status='COMPLETED' 
                       GROUP BY service_id
                   ) j_stats ON s.id = j_stats.service_id
                   WHERE s.is_active=1
                   AND NOT EXISTS (
                       SELECT 1 FROM jobs j
                       WHERE j.service_id = s.id
                       AND j.start_time > datetime('now', 'localtime', '-23 hours')
                       AND j.status IN ('RUNNING', 'COMPLETED', 'ORPHANED', 'FAILED', 'TIMEOUT')
                   )
                   ORDER BY s.priority DESC, COALESCE(j_stats.avg_duration, -1) DESC, s.container_name ASC 
                   LIMIT 1;"
            NEXT_SERVICE_ID=$($DB_QUERY "$QUERY")
            if [ $? -ne 0 ]; then
                log "[Error] Database query failed while fetching next service. Retrying in 30s..."
                sleep 30
                continue
            fi
            
            if [ -z "$NEXT_SERVICE_ID" ]; then
                # Natural completion: every active service has a row in this run.
                # Close it COMPLETED so the next window entry opens a fresh run.
                if [ -n "$CURRENT_RUN_ID" ]; then
                    log "All tasks completed for run #$CURRENT_RUN_ID. Closing as COMPLETED."
                    run_close "$CURRENT_RUN_ID" COMPLETED
                    CURRENT_RUN_ID=""
                fi
                log "All tasks completed for today. Waiting..."
            else
                CONTAINER_NAME=$($DB_QUERY "SELECT container_name FROM services WHERE id=$NEXT_SERVICE_ID;")

                # 4. Check Resources
                CPU=$(get_cpu_usage)
                MEM=$(get_mem_usage)
                DISK=$(get_disk_usage)
                DISKIO=$(get_diskio_usage)
                NET=$(get_bandwidth_usage)
                PROC=$(get_proc_usage)
                LOAD=$(get_cpu_load_average)
                IOWAIT=$(get_iowait)
                SWAP=$(get_swap_usage)
                INODE=$(get_inode_usage)
                
                if ! check_thresholds "$CPU" "$MEM" "$DISK" "$DISKIO" "$NET" "$PROC" "$LOAD" "$IOWAIT" "$SWAP" "$INODE" "$THRESHOLD"; then
                    log "Resource limit exceeded: $LAST_BYPASS_REASON. Container '$CONTAINER_NAME' is waiting..."
                else
                    # 5. Concurrency cap: fast-path count check (race-protected by atomic INSERT below)
                    CURRENT_RUNNING=$($DB_QUERY "SELECT COUNT(*) FROM jobs WHERE status='RUNNING';")
                    if [ "${CURRENT_RUNNING:-0}" -ge "$MAX_CONCURRENT" ]; then
                        log "Concurrency cap reached: $CURRENT_RUNNING/$MAX_CONCURRENT jobs running. '$CONTAINER_NAME' is waiting..."
                    # 6. Double Check: Is there already a process running for this container?
                    elif [[ "$MODE_SEQUENCE" == "true" ]] && [[ ${#BG_PIDS[@]} -gt 0 ]]; then
                        log "Process check skip: Sequence mode is enabled and ${#BG_PIDS[@]} job(s) already running."
                    elif [[ -n "${BG_PIDS[$CONTAINER_NAME]}" ]] && kill -0 "${BG_PIDS[$CONTAINER_NAME]}" 2>/dev/null; then
                        log "Process check skip: $CONTAINER_NAME is already being indexed. Skipping..."
                    else
                        # 7. Execute Job — atomic INSERT-if-under-cap guards race with manual trigger (bin/scheduler.sh:180)
                        JOB_ID=$($DB_QUERY "BEGIN IMMEDIATE; \
INSERT INTO jobs (service_id, status, start_time) \
SELECT $NEXT_SERVICE_ID, 'RUNNING', datetime('now', 'localtime') \
WHERE (SELECT COUNT(*) FROM jobs WHERE status='RUNNING') < $MAX_CONCURRENT; \
SELECT CASE WHEN changes() > 0 THEN last_insert_rowid() ELSE 0 END; \
COMMIT;")

                        if [ $? -ne 0 ] || [ -z "$JOB_ID" ]; then
                            log "[Error] Failed to create job record in database for $CONTAINER_NAME. Skipping..."
                        elif [ "$JOB_ID" = "0" ]; then
                            log "Concurrency cap race: slot filled by concurrent path. '$CONTAINER_NAME' is waiting..."
                        else
                            # Wrap the spawn in a subshell that ignores SIGTERM/SIGINT.
                            # Under systemd KillMode=control-group or a tty Ctrl+C, every
                            # process in the unit/PG receives the signal simultaneously.
                            # Without this trap the subshell would exit before
                            # cleanup_and_exit could walk BG_PIDS and kill each tree, and
                            # the wrapped `timeout` child would be reparented to init and
                            # keep running. The trap blocks the broadcast SIGTERM, giving
                            # cleanup_and_exit time to issue explicit kill_process_tree
                            # calls; the SIGKILL fallback in kill_process_tree still works
                            # because SIGKILL cannot be trapped.
                            ( trap '' SIGTERM SIGINT; run_indexing_task "$CONTAINER_NAME" ) &
                            PID=$!
                            # Capture starttime alongside PID. PID alone is ambiguous
                            # because the kernel recycles PID numbers, so identity
                            # checks during recovery / stale-expire compare against
                            # the (PID, starttime) tuple to avoid SIGKILLing an
                            # unrelated process that happens to occupy the same PID.
                            PID_STARTTIME=$(get_pid_starttime "$PID")
                            BG_PIDS["$CONTAINER_NAME"]=$PID
                            BG_PREV_STATE["$CONTAINER_NAME"]="RUNNING"
                            # Update DB with PID + starttime for crash-safe recovery
                            $DB_QUERY "UPDATE jobs SET pid=$PID, pid_starttime=${PID_STARTTIME:-NULL}, process_state='RUNNING' WHERE id=$JOB_ID;"
                            log "Background PID=$PID started for $CONTAINER_NAME (Job ID: $JOB_ID)"
                            BG_LAST_CPU["$CONTAINER_NAME"]=""
                            BG_IDLE_SINCE["$CONTAINER_NAME"]=0
                        fi
                    fi
                fi
            fi
        fi
        
        # Always sleep for the interval regardless of task execution
        sleep "$INTERVAL"
        
    done
fi
