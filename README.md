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
- **Process Usage**: It counts how many other programs are running or waiting.
- **Notebook Management (SQLite3)**: It keeps the list of boxes, rules, and history in a small notebook file.
- **Background Work**: It can start batch jobs in the background so it can do more than one thing at a time.
- **Sequential Execution (--sequence)**: If you prefer to run only one task at a time, use the `--sequence` flag to wait for the current job to finish before starting the next one.
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
│   ├── monitor.sh      # The body check tool
│   ├── db_query.sh     # The tool for talking to the notebook
│   └── migrate_db.sh   # The tool for updating the notebook layout
├── sql/
│   └── init_db.sql     # The original layout for the notebook
├── data/
│   └── scheduler.db    # The notebook file itself
├── tests/              # Games and tests to check if everything works
├── logs/               # A diary of every action the helper takes
├── .env.example        # A template for your own rules
├── .env                # Your own rules (you make this from the template)
├── README.md           # This guide
├── ARCHITECTURE.md     # A big map of how it all works
└── TASK.md             # A checklist of what we have done
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

### 3. Add Your Batch Jobs
Add the names of the boxes you want to organize:
```bash
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('box-1', 10);"
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('box-2', 5);"
```

### 4. Start the Helper!
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
See a summary of what the helper is doing, including the real-time process state (like RUNNING, SLEEPING, or DISK_WAIT):
```bash
./bin/scheduler.sh --status
```

### Start Fresh (--init)
Clear the diary for the last 23 hours:
```bash
./bin/scheduler.sh --init
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
| `JOB_TIMEOUT_SEC` | Max allowed execution time for a job (seconds) | `7200` |
| `LOG_RETENTION_DAYS` | How many days to keep old log files | `30` |
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
./tests/test_monitor.sh           # Check the body check tool
./tests/test_scheduler_logic.sh   # Check the time and waiting rules
./tests/test_status_output.sh     # Check the status reports
./tests/test_db_init.sh           # Check if the helper can make its first notes
./tests/test_db_stress.sh         # Check if the notebook is safe when many things happen
./tests/test_db_error_handling.sh # Check how the helper handles notebook errors
./tests/test_input_validation.sh  # Check if the helper rejects bad input (SQL injection etc.)
./tests/test_async_concurrency.sh # Check if many boxes can work at the same time
./tests/test_orphan_status.sh     # Check if the helper detects jobs after a crash
./tests/test_idle_timeout.sh      # Check if jobs exceeding max duration are stopped
./tests/test_init_option.sh       # Check if the "start fresh" command works
./tests/test_service_option.sh    # Check if running one box right away works
./tests/test_sequence_mode.sh    # Check if the helper can run boxes one by one
```
