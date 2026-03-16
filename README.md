# OpenGrok Index Scheduler

This is a Bash-based helper that organizes indexing for more than 70 OpenGrok service boxes. It checks how busy the computer is and works only when there is enough room and during the night.

## Main Features

- **Time-Based Work**: It only works during the hours you set (like 18:00 to 06:00).
- **Live Settings**: It reads the rules from the notebook (SQLite3) every time it checks, so you don't have to restart it to change rules.
- **Body Check (Resource Monitoring)**: 
  - **Brain (CPU)**: It checks how hard the brain is working right now.
  - **Thinking Space (Memory)**: It looks at the real space left for thinking (available memory).
  - **Internet (Network)**: It detects the speed and checks how much is being used.
  - **Disk I/O**: It checks if the computer is busy reading or writing books (files).
- **Process Usage**: it counts how many other programs are running or waiting.
- **Notebook Management (SQLite3)**: It keeps the list of boxes, rules, and history in a small notebook file.
- **Background Work**: It can start indexing tasks in the background so it can do more than one thing at a time.
- **Fixed Checking Time**: It follows a strict schedule (like every 5 minutes) to scan for new tasks.
- **Safe Notebook**: It uses special tricks (WAL and Busy Timeout) so many programs can talk to the notebook at the same time without problems.
- **Status Reports**: Use the `--status` command to see a summary of what has been done.
- **Independent Checking**: You can check the status even while the helper is working in the background.

## Project Structure

```text
opengrok-scheduler/
├── bin/
│   ├── scheduler.sh    # The main brain and command center
│   ├── monitor.sh      # The body check tool
│   └── db_query.sh     # The tool for talking to the notebook
├── sql/
│   └── init_db.sql     # The original layout for the notebook
├── data/
│   └── scheduler.db    # The notebook file itself
├── tests/              # Games and tests to check if everything works
├── logs/               # A diary of every action the helper takes
├── README.md           # This guide
├── ARCHITECTURE.md     # A big map of how it all works
└── TASK.md             # A checklist of what we have done
```

## How to Get Started

### 1. What You Need
- Bash Shell (A special way to talk to Linux)
- SQLite3 and sysstat (Tools for the helper to work)
- Docker (The boxes that need indexing)

### 2. Make the notebook
```bash
mkdir -p data logs
sqlite3 data/scheduler.db < sql/init_db.sql
```

### 3. Add Your Boxes
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

### Run One Box Now (--service)
If you want to start one box right away, no matter what time it is:
```bash
./bin/scheduler.sh --service box-1
```

### Check the Status (--status)
See a summary of what the helper is doing:
```bash
./bin/scheduler.sh --status
```

### Start Fresh (--init)
Clear the diary for the last 23 hours:
```bash
./bin/scheduler.sh --init
```

### Changing the Rules
You can change rules in the `config` table of the notebook.

| Rule Name | What It Is | Default |
|:---|:---|:---|
| `start_time` | When work begins | `18:00` |
| `end_time` | When work ends | `06:00` |
| `resource_threshold` | How busy the computer can be (%) | `70` |
| `check_interval` | How long to wait between checks (seconds) | `300` |
| `net_interface` | Which internet pipe to watch | - |
| `max_bandwidth` | Max speed of the internet | - |
| `disk_device` | Which disk to watch | - |

```bash
# Change the limit to 80%
./bin/db_query.sh "UPDATE config SET value='80' WHERE key='resource_threshold';"
```

## Running Tests
Run these games to make sure the helper is working:
```bash
./tests/test_monitor.sh           # Check the body check tool
./tests/test_scheduler_logic.sh   # Check the time and waiting rules
./tests/test_status_output.sh     # Check the status reports
./tests/test_db_stress.sh        # Check if the notebook is safe
```
