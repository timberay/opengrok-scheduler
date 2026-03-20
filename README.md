# OpenGrok Index Scheduler

This is a Bash-based helper that organizes indexing for more than 70 OpenGrok service boxes. It checks how busy the computer is and works only when there is enough room and during the night.

## Main Features

- **Time-Based Work**: It only works during the hours you set (like 18:00 to 06:00).
- **Easy Settings**: It reads the rules from a simple `.env` file, so it's easy to change rules for different servers.
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
- Docker (The boxes that need indexing)

### 2. Make the notebook
```bash
mkdir -p data logs
sqlite3 data/scheduler.db < sql/init_db.sql

### 3. Set Your Rules
Copy the template and edit it with your favorite text editor:
```bash
cp .env.example .env
vi .env
```
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
You can change rules in the `.env` file. The helper reads this file every time it looks for a new task, so you don't need to restart it after a change.

| Rule Name | What It Is | Default |
|:---|:---|:---|
| `DB_PATH` | Where the notebook file is | `data/scheduler.db` |
| `LOG_DIR` | Where the diary is kept | `logs` |
| `START_TIME` | When work begins | `18:00` |
| `END_TIME` | When work ends | `06:00` |
| `RESOURCE_THRESHOLD` | How busy the computer can be (%) | `70` |
| `CHECK_INTERVAL` | How long to wait between checks (seconds) | `300` |
| `NET_INTERFACE` | Which internet pipe to watch (Optional) | auto-detected |
| `MAX_BANDWIDTH` | Max speed of the internet (Optional) | auto-detected |
| `DISK_DEVICE` | Which disk to watch (Optional) | auto-detected |

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
./tests/test_db_init.sh          # Check if the helper can make its first notes
./tests/test_db_stress.sh        # Check if the notebook is safe when many things happen
./tests/test_async_concurrency.sh # Check if many boxes can work at the same time
./tests/test_init_option.sh       # Check if the "start fresh" command works
./tests/test_service_option.sh    # Check if running one box right away works
```
