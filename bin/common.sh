#!/bin/bash

# bin/common.sh
# Common environment and helper functions for Batch Job Scheduler

# 1. Base Directory Discovery
# This script is located in bin/, so PROJECT_ROOT is one level up
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT

# 2. Environment Loading
# Preserves existing environment variables if they are already set
load_env() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        # Save ALL config variables that might be pre-set
        local _SAVED_VARS=(
            DB_PATH LOG_DIR LOG_RETENTION_DAYS
            START_TIME END_TIME
            RESOURCE_THRESHOLD CHECK_INTERVAL JOB_TIMEOUT_SEC JOB_IDLE_TIMEOUT
            IOWAIT_THRESHOLD SWAP_THRESHOLD INODE_THRESHOLD
            DISK_DEVICE NET_INTERFACE MAX_BANDWIDTH
            MAX_CONCURRENT_JOBS KILL_GRACE_SEC
            RUN_RETENTION_MIN RUN_RETENTION_DAYS MANUAL_JOB_RETENTION_DAYS
        )
        declare -A _SAVED
        for var in "${_SAVED_VARS[@]}"; do
            [ -n "${!var}" ] && _SAVED[$var]="${!var}"
        done

        set -a
        source "$PROJECT_ROOT/.env"
        set +a

        # Restore pre-existing values
        for var in "${!_SAVED[@]}"; do
            export "$var"="${_SAVED[$var]}"
        done
    fi
}

# 3. Path Normalization
resolve_paths() {
    # DB_PATH resolution
    DB_PATH="${DB_PATH:-$PROJECT_ROOT/data/scheduler.db}"
    if [[ "$DB_PATH" != /* ]]; then
        DB_PATH="$PROJECT_ROOT/$DB_PATH"
    fi
    export DB_PATH

    # LOG_DIR resolution
    LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"
    if [[ "$LOG_DIR" != /* ]]; then
        LOG_DIR="$PROJECT_ROOT/$LOG_DIR"
    fi
    export LOG_DIR
}

# Initial Execution
load_env
resolve_paths

# Cycle history retention (used by daily cleanup in scheduler main loop).
# Keep at least RUN_RETENTION_MIN runs OR RUN_RETENTION_DAYS days of runs,
# whichever preserves more history. Manual jobs (run_id IS NULL) are kept
# for MANUAL_JOB_RETENTION_DAYS days.
RUN_RETENTION_MIN=${RUN_RETENTION_MIN:-90}
RUN_RETENTION_DAYS=${RUN_RETENTION_DAYS:-90}
MANUAL_JOB_RETENTION_DAYS=${MANUAL_JOB_RETENTION_DAYS:-30}
export RUN_RETENTION_MIN RUN_RETENTION_DAYS MANUAL_JOB_RETENTION_DAYS

# --- Input Validation Helpers ---

# Validate if input is a positive integer
validate_integer() {
    local val="$1"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        echo "[Error] Invalid integer input: '$val'" >&2
        return 1
    fi
    return 0
}

# Validate if input is a safe name (alphanumeric, hyphen, underscore, dot)
# Suitable for container names, service names, etc.
validate_name() {
    local val="$1"
    if [[ ! "$val" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "[Error] Invalid name input: '$val'. Only alphanumeric, '.', '_', and '-' are allowed." >&2
        return 1
    fi
    return 0
}
