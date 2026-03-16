#!/bin/bash

# bin/scheduler.sh
# OpenGrok Index Scheduler Main Script

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/bin/monitor.sh"
DB_QUERY="$PROJECT_ROOT/bin/db_query.sh"
LOG_DIR="$PROJECT_ROOT/logs"
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
    local SECONDS=$1
    if [ -z "$SECONDS" ]; then echo "-"; return; fi
    local H=$((SECONDS / 3600))
    local M=$(( (SECONDS % 3600) / 60 ))
    local S=$((SECONDS % 60))
    printf "%dh %dm %ds" "$H" "$M" "$S"
}

# Function to execute indexing task and update DB
run_indexing_task() {
    local SERVICE_ID=$1
    local CONTAINER_NAME=$2

    log "Starting indexing for $CONTAINER_NAME..."
    # Insert and get ID in the same session
    local JOB_ID=$($DB_QUERY "INSERT INTO jobs (service_id, status, start_time) VALUES ($SERVICE_ID, 'RUNNING', datetime('now', 'localtime')); SELECT last_insert_rowid();")
    
    local START_SEC=$(date +%s)
    
    # ----------------------------------------------------------------------
    # [MODIFY] 아래 구간에 실제 인덱싱 명령어를 입력하세요.
    # 예: docker exec "$CONTAINER_NAME" /usr/local/bin/indexer
    # ----------------------------------------------------------------------
    
    # 실제 명령 실행 (테스트를 위해 sleep 2 유지, 실제 연동 시 아래 라인 교체)
    # docker exec "$CONTAINER_NAME" /usr/local/bin/indexer 
    sleep 2 
    
    # 실행 결과 코드 캡처
    local EXIT_CODE=$? 
    
    # ----------------------------------------------------------------------
    
    local END_SEC=$(date +%s)
    local DURATION=$((END_SEC - START_SEC))
    
    if [ "$EXIT_CODE" -eq 0 ]; then
        $DB_QUERY "UPDATE jobs SET status='COMPLETED', end_time=datetime('now', 'localtime'), duration=$DURATION WHERE id=$JOB_ID;"
        log "Indexing $CONTAINER_NAME completed successfully."
    else
        $DB_QUERY "UPDATE jobs SET status='FAILED', end_time=datetime('now', 'localtime'), duration=$DURATION, message='Exit code $EXIT_CODE' WHERE id=$JOB_ID;"
        log "Indexing $CONTAINER_NAME failed."
    fi
    return $EXIT_CODE
}

# Main Execution Loop (Only run if not sourced with --no-run)
if [[ "$1" != "--no-run" ]]; then

    # Handle --status argument
    if [[ "$1" == "--status" ]]; then
        echo "[OpenGrok Indexing Summary]"
        echo "--------------------------------------------------------------------------------"
        printf "%-25s | %-12s | %-20s | %-12s | %-20s\n" "Service Name" "Status" "Start Time" "Duration" "Message"
        echo "----------------------------------------------------------------------------------------------------"
        
        # Query 결과를 최근 23시간 기준으로 필터링
        QUERY="SELECT s.container_name, j.status, j.start_time, j.duration, j.message 
               FROM services s 
               LEFT JOIN jobs j ON s.id = j.service_id 
               WHERE (j.start_time > datetime('now', 'localtime', '-23 hours') OR j.start_time IS NULL)
               ORDER BY j.start_time DESC LIMIT 50;"
        
        $DB_QUERY "$QUERY" | while IFS='|' read -r name status start duration msg; do
            [[ -z "$name" ]] && continue
            F_DURATION=$(format_duration "$duration")
            printf "%-25s | %-12s | %-20s | %-12s | %-20s\n" "$name" "${status:-WAITING}" "${start:--}" "$F_DURATION" "${msg:--}"
        done
        echo "----------------------------------------------------------------------------------------------------"
        
        TOTAL=$($DB_QUERY "SELECT count(*) FROM services;")
        DONE=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='COMPLETED' AND start_time > datetime('now', 'localtime', '-23 hours');")
        echo "Total: $TOTAL | Done (Last 23h): $DONE"
        exit 0
    fi

    # Handle --init argument
    if [[ "$1" == "--init" ]]; then
        log "Initializing today's job status (23h window)..."
        # Check if any job is currently RUNNING within 23h
        RUNNING_JOBS=$($DB_QUERY "SELECT count(*) FROM jobs WHERE status='RUNNING' AND start_time > datetime('now', 'localtime', '-23 hours');")
        if [ "$RUNNING_JOBS" -gt 0 ]; then
            log "[Warning] There are $RUNNING_JOBS jobs currently in 'RUNNING' status."
            log "Force initializing anyway..."
        fi
        
        $DB_QUERY "DELETE FROM jobs WHERE start_time > datetime('now', 'localtime', '-23 hours');"
        log "Recent job records (last 23h) have been cleared."
        exit 0
    fi

    # Handle --service argument
    if [[ "$1" == "--service" ]]; then
        TARGET_CONTAINER=$2
        if [ -z "$TARGET_CONTAINER" ]; then
            echo "[Error] Please provide a container name. Usage: $0 --service <container_name>"
            exit 1
        fi
        
        SERVICE_INFO=$($DB_QUERY "SELECT id, container_name FROM services WHERE container_name='$TARGET_CONTAINER';")
        if [ -z "$SERVICE_INFO" ]; then
            echo "[Error] Service '$TARGET_CONTAINER' not found in database."
            exit 1
        fi
        
        S_ID=$(echo "$SERVICE_INFO" | cut -d'|' -f1)
        S_NAME=$(echo "$SERVICE_INFO" | cut -d'|' -f2)
        
        log "Manually starting indexing for $S_NAME..."
        run_indexing_task "$S_ID" "$S_NAME"
        exit $?
    fi

    log "OpenGrok Scheduler Started."
    
    while true; do
        # 1. Load Config
        START_TIME=$($DB_QUERY "SELECT value FROM config WHERE key='start_time';")
        END_TIME=$($DB_QUERY "SELECT value FROM config WHERE key='end_time';")
        THRESHOLD=$($DB_QUERY "SELECT value FROM config WHERE key='resource_threshold';")
        INTERVAL=$($DB_QUERY "SELECT value FROM config WHERE key='check_interval';")

        # 2. Check Time Range
        if ! check_time_range "$START_TIME" "$END_TIME" > /dev/null; then
            log "Outside working hours ($START_TIME ~ $END_TIME). Sleeping..."
        else
            # 3. Check Resources
            CPU=$(get_cpu_usage)
            MEM=$(get_mem_usage)
            DISK=$(get_disk_usage "/")
            DISKIO=$(get_diskio_usage)
            NET=$(get_bandwidth_usage)
            PROC=$(get_proc_usage)
            
            if ! check_thresholds "$CPU" "$MEM" "$DISK" "$DISKIO" "$NET" "$PROC" "$THRESHOLD"; then
                log "Resource limit exceeded: $LAST_BYPASS_REASON. Waiting..."
            else
                # 4. Get Next Job (Exclude services already RUNNING or COMPLETED today)
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
                           AND j.status IN ('RUNNING', 'COMPLETED')
                       )
                       ORDER BY COALESCE(j_stats.avg_duration, -1) DESC, s.container_name ASC 
                       LIMIT 1;"
                NEXT_SERVICE_ID=$($DB_QUERY "$QUERY")
                
                if [ -z "$NEXT_SERVICE_ID" ]; then
                    log "All tasks completed for today. Waiting..."
                else
                    CONTAINER_NAME=$($DB_QUERY "SELECT container_name FROM services WHERE id=$NEXT_SERVICE_ID;")
                    
                    # 5. Double Check: Is there already a process running for this container?
                    if ps -elf | grep -v grep | grep "run_indexing_task" | grep -q "$CONTAINER_NAME"; then
                        log "Process check skip: $CONTAINER_NAME is already being indexed. Skipping..."
                    else
                        # 6. Execute Job (Simple Background)
                        run_indexing_task "$NEXT_SERVICE_ID" "$CONTAINER_NAME" &
                    fi
                fi
            fi
        fi
        
        # Always sleep for the interval regardless of task execution
        sleep "$INTERVAL"
        
    done
fi
