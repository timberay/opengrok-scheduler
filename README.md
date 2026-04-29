# Batch Job Scheduler

This is a Bash-based helper that organizes batch jobs for more than 70 service boxes. It checks how busy the computer is and works only when there is enough room and during the night.

## Main Features

- **Time-Based Work**: It only works during the hours you set (like 18:00 to 06:00).
- **Easy Settings**: It reads the rules from a simple `.env` file, so it's easy to change rules for different servers.
- **Body Check (Resource Monitoring)**: 
  - **Brain (CPU)**: It checks how hard the brain is working right now (CPU Usage, Load Average, and I/O Wait).
  - **Thinking Space (Memory)**: It looks at the real space left for thinking (Available Memory and Swap Usage).
  - **Internet (Network)**: It detects the speed and checks how much is being used across all physical interfaces.
  - **Disk & Inodes**: It checks if the disks are busy or running out of indexing space (Disk Usage, Disk I/O, and Inode Usage) for all local partitions automatically.
- **Dynamic Process Tracking**: It tracks the live status of each batch job, recovers lost processes after restarts, and safely times out jobs that exceed their absolute duration limit.
- **Idle Detection**: It samples CPU time across the entire process tree (parent + all child processes) to detect truly idle jobs. If a job's CPU time stops changing for `JOB_IDLE_TIMEOUT` seconds, it is terminated. This prevents false idle detection when a parent process spawns child processes (e.g. Docker exec, CLI tools) and appears idle while children are still working.
- **Process Usage**: It counts how many other programs are running or waiting.
- **Notebook Management (SQLite3)**: It keeps the list of boxes, rules, and history in a small notebook file.
- **Cycle-Based History (Runs)**: Each scheduling cycle is recorded as one row in the `runs` table, replacing the previous timestamp-based "last 23 hours" model. A run opens on entry to the working window and closes when:
  - all active services have a job row in that run (`COMPLETED`),
  - the working window ends with services still pending (`PARTIAL`),
  - the scheduler shuts down or recovers from a crash (`ABORTED`).
  Manual `--service <container>` jobs run outside any cycle (their `run_id` is `NULL`) and are retained per a separate day-based rule. Retention keeps `MAX(RUN_RETENTION_MIN runs, RUN_RETENTION_DAYS days)`.
- **Background Work**: It can start batch jobs in the background so it can do more than one thing at a time.
- **Sequential Execution (--sequence)**: If you prefer to run only one task at a time, use the `--sequence` flag to wait for the current job to finish before starting the next one.
- **Concurrency Cap (MAX_CONCURRENT_JOBS)**: It limits the number of jobs that can run at the same time (default 3). This stops the server from being overloaded when several jobs finish the light "download" stage together and suddenly all start the heavy "indexing" stage. Applies to both the scheduled loop and `--service` manual triggers, and is race-safe across both paths.
- **Crash-Safe Recovery (PID + starttime identity)**: Every spawned job records both its PID and the process's `/proc/<pid>/stat` starttime. After a crash or restart, the scheduler verifies the recorded tuple still matches before resuming tracking. If the OS recycled the PID for an unrelated process, the row is marked ORPHANED without sending any signal. Plain PIDs are never trusted for kill or cleanup decisions.
- **Single-Instance Lock**: The scheduler holds an `flock` on a lock file at startup. A second scheduler launched against the same DB exits immediately, preventing two main loops from racing on job admission.
- **Graceful Termination (KILL_GRACE_SEC)**: When killing a job tree, SIGTERM goes to the whole process group, then `KILL_GRACE_SEC` seconds (default 10) elapse before SIGKILL. The grace period gives SIGTERM-respecting workloads time to flush state. Identity is re-verified immediately before each signal pass so PID reuse during the wait window cannot redirect the SIGKILL to an unrelated process.
- **Signal-Isolated Job Spawning**: Spawned job subshells trap-ignore SIGTERM/SIGINT. This way, when the scheduler receives a shutdown signal, `cleanup_and_exit` walks the recorded `BG_PIDS` deterministically rather than losing track because the broadcast already terminated children out of order.
- **Fixed Checking Time**: It follows a strict schedule (like every 5 minutes) to scan for new tasks.
- **Safe Notebook**: It uses special tricks (WAL and Busy Timeout) so many programs can talk to the notebook at the same time without problems.
- **Automatic Schema Updates**: It automatically fixes the notebook layout (adds missing columns) every time it starts, so you don't have to worry about manual updates.
- **Status Reports**: Use the `--status` command to see a summary of what has been done.
- **Independent Checking**: You can check the status even while the helper is working in the background.

## Project Structure

```text
batchjob-scheduler/
├── bin/
│   ├── scheduler.sh    # The main brain and command center
│   ├── monitor.sh      # The body check tool (10 resource metrics)
│   ├── db_query.sh     # The tool for talking to the notebook
│   ├── migrate_db.sh   # The tool for updating the notebook layout
│   └── common.sh       # Shared environment loading and input validation
├── sql/
│   └── init_db.sql     # The original layout for the notebook
├── data/
│   └── scheduler.db    # The notebook file itself
├── tests/
│   ├── test_helper.sh  # Shared test utilities and assertions
│   └── test_*.sh       # Test scripts for each module
├── logs/               # A diary of every action the helper takes
├── .env.example        # A template for your own rules
├── .env                # Your own rules (you make this from the template)
└── README.md           # This guide
```

## How to Get Started

### 1. What You Need
- Bash Shell (A special way to talk to Linux)
- SQLite3 and sysstat (Tools for the helper to work)
- Docker (The boxes that need batch job execution)

### 2. Make the notebook
```bash
mkdir -p data logs
sqlite3 data/scheduler.db < sql/init_db.sql
```

### 3. Set Your Rules
Copy the template and edit it with your favorite text editor:
```bash
cp .env.example .env
vi .env
```

### 4. Add Your Batch Jobs
Add the names of the boxes you want to organize:
```bash
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('box-1', 10);"
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('box-2', 5);"
```

### 5. Start the Helper!
```bash
chmod +x bin/*.sh
./bin/scheduler.sh
```

## How to Use It

### Run One Batch Job Now (--service)
If you want to start one box right away, no matter what time it is:
```bash
./bin/scheduler.sh --service box-1
```

### Check the Status (--status)
See a summary of what the helper is doing, including the real-time process state (like RUNNING, SLEEPING, or DISK_WAIT). The header shows the current/most-recent run with per-status counts (`C/F/T/O` = Completed / Failed / Timeout / Orphaned):
```bash
./bin/scheduler.sh --status
```

Example header line:
```
Run #1 [COMPLETED, trigger=auto] 2026-04-30 00:15:03 ~ 2026-04-30 01:45:03 | 3/3 done (C=2 F=1 T=0 O=0)
```

### Recover a Stuck Cycle (--init)
Close the in-flight run as `ABORTED` and exit. Past runs and their job rows are
preserved. Use this when a cycle is stuck and you want the next start to open a
fresh run cleanly:
```bash
./bin/scheduler.sh --init
```

### Wipe All History (--purge-all)
Total wipe of all runs and jobs (services config preserved). Use this only when
you genuinely want to discard all history. The previous destructive `--init`
behavior was renamed to this flag in v1.1:
```bash
./bin/scheduler.sh --purge-all
```

### Run Jobs One by One (--sequence)
If you want the helper to wait for each box to finish before starting the next one (no parallel work):
```bash
./bin/scheduler.sh --sequence
```

### Changing the Rules
You can change rules in the `.env` file. The helper reads this file every time it looks for a new task, so you don't need to restart it after a change.

| Rule Name | What It Is | Default |
|:---|:---|:---|
| `DB_PATH` | Where the notebook file is | `data/scheduler.db` |
| `LOG_DIR` | Where the diary is kept | `logs` |
| `START_TIME` | When work begins | `18:00` |
| `END_TIME` | When work ends | `06:00` |
| `RESOURCE_THRESHOLD` | How busy the computer can be (%) | `70` |
| `CHECK_INTERVAL` | How long to wait between checks (seconds) | `300` |
| `MAX_CONCURRENT_JOBS` | Max number of jobs running at the same time (hard cap; restart required after change) | `3` |
| `JOB_TIMEOUT_SEC` | Max allowed execution time for a job (seconds) | `36000` |
| `JOB_IDLE_TIMEOUT` | How long a job can be idle before timeout (seconds, 0=disabled) | `3600` |
| `LOG_RETENTION_DAYS` | How many days to keep old log files | `30` |
| `RUN_RETENTION_MIN` | Minimum number of finished runs to keep | `90` |
| `RUN_RETENTION_DAYS` | Minimum days of run history to keep. Effective retention is `MAX(RUN_RETENTION_MIN runs, RUN_RETENTION_DAYS days)` | `90` |
| `MANUAL_JOB_RETENTION_DAYS` | How long manual `--service` jobs (no `run_id`) are kept | `30` |
| `KILL_GRACE_SEC` | Seconds between SIGTERM and SIGKILL when killing a job tree (allows graceful cleanup) | `10` |
| `IOWAIT_THRESHOLD` | Max allowed I/O Wait (%) | `20` |
| `SWAP_THRESHOLD` | Max allowed Swap usage (%) | `50` |
| `INODE_THRESHOLD` | Max allowed Inode usage (%) | `90` |
| `NET_INTERFACE` | Which internet pipe to watch | auto-detected (All) |
| `MAX_BANDWIDTH` | Max speed of the internet | auto-detected |
| `DISK_DEVICE` | Which disk to watch | auto-detected (All) |

```bash
# Example: Change the limit to 80%
# Edit .env file and change RESOURCE_THRESHOLD=80
```

## Running Tests
Run these games to make sure the helper is working:
```bash
# Resource Monitoring
./tests/test_monitor.sh             # Check all 10 resource metrics and thresholds
./tests/test_threshold_boundary.sh  # Check check_thresholds -gt boundary semantics (at LIMIT = safe, LIMIT+1 = breach)

# Scheduler Logic
./tests/test_scheduler_logic.sh     # Check the time and waiting rules
./tests/test_async_concurrency.sh   # Check if many boxes can work at the same time
./tests/test_sequence_mode.sh       # Check if the helper can run boxes one by one
./tests/test_concurrency_cap.sh     # Check that MAX_CONCURRENT_JOBS caps running jobs in both loop and --service paths
./tests/test_idle_timeout.sh        # Check if idle jobs (no CPU activity) are detected and stopped
./tests/test_sigterm_cleanup.sh     # Check if the helper cleans up on shutdown signal
./tests/test_error_skip.sh          # Check FAILED/TIMEOUT jobs are excluded from next-job retry pool within the current run
./tests/test_dedup_by_run.sh        # Check auto-cycle dedup is scoped to run_id, replacing the 23h rolling window

# Run Lifecycle (cycle-based history)
./tests/test_runs_schema.sh             # Check runs table + jobs.run_id migration is idempotent
./tests/test_run_lifecycle.sh           # Check run opens on window entry and closes COMPLETED/PARTIAL naturally
./tests/test_run_aborted_on_shutdown.sh # Check the open run is closed ABORTED on cleanup_and_exit
./tests/test_run_recovery.sh            # Check stale RUNNING runs are recovered to ABORTED on startup
./tests/test_manual_run_id.sh           # Check --service jobs pin run_id=NULL (excluded from cycle counters)
./tests/test_init_semantics.sh          # Check --init aborts the current run only (non-destructive)
./tests/test_status_runs.sh             # Check --status reports the latest run summary and counters
./tests/test_retention.sh               # Check retention keeps MAX(RUN_RETENTION_MIN, RUN_RETENTION_DAYS)

# Command Options
./tests/test_init_option.sh         # Check the run-abort behavior of --init (and --purge-all wipe path)
./tests/test_service_option.sh      # Check if running one box right away works
./tests/test_status_output.sh       # Check the status reports

# Database
./tests/test_db_init.sh             # Check if the helper can make its first notes
./tests/test_db_stress.sh           # Check if the notebook is safe when many things happen
./tests/test_db_error_handling.sh   # Check how the helper handles notebook errors
./tests/test_db_query_fixes.sh      # Check database query edge cases
./tests/test_migrate_constraint.sh  # Check schema migration with constraints

# Process & Recovery
./tests/test_orphan_status.sh       # Check if the helper detects jobs after a crash
./tests/test_orphan_recovery_fix.sh # Check if orphaned jobs are recovered correctly
./tests/test_kill_validation.sh     # Check kill_process_tree refuses PID 0/1/empty/non-numeric (no system damage)
./tests/test_instance_lock.sh       # Check that two scheduler instances cannot run on the same DB
./tests/test_signal_isolation.sh    # Check spawned jobs ignore broadcast SIGTERM so cleanup_and_exit can walk BG_PIDS
./tests/test_pid_identity.sh        # Check (PID, starttime) identity helpers used to defend against PID reuse
./tests/test_pid_reuse_defense.sh   # Check recovery and stale-expire skip kills when starttime mismatches
./tests/test_kill_grace.sh          # Check kill_process_tree starttime re-verification and KILL_GRACE_SEC env var

# Code Quality
./tests/test_input_validation.sh    # Check if the helper rejects bad input (SQL injection etc.)
./tests/test_local_keyword_fix.sh   # Check variable scoping (local keyword usage)
./tests/test_exec_redirect.sh       # Check stderr is not permanently redirected
```

## Upgrading

When upgrading from a pre-(PID, starttime) version, any jobs left in the
RUNNING state by the old scheduler will lack a recorded `pid_starttime`
and **cannot be safely identity-verified** by the new code. On the next
startup the scheduler logs a `[Migration] Found N legacy RUNNING job(s)`
warning and marks those rows as ORPHANED without issuing any kill — the
PID alone could refer to a recycled, unrelated process.

Recommended drain procedure before upgrading:

1. Stop accepting new work outside the `START_TIME`–`END_TIME` window or
   set `MAX_CONCURRENT_JOBS=0` and wait for in-flight jobs to finish.
2. Verify with `bin/scheduler.sh --status` that no RUNNING rows remain.
3. Deploy the new code and start the scheduler.

If you cannot drain (e.g. an unattended crash left RUNNING rows behind),
the `[Migration]` warning will tell you how many rows were affected. If
the underlying processes are still running, terminate them manually
(`pkill -f <indexer>`); otherwise wait — `KILL_GRACE_SEC` and the stale
auto-expire path (2 × `JOB_TIMEOUT_SEC`) will eventually mark them
TIMEOUT without attempting a kill.
