# OpenGrok Index Scheduler Architecture

This is the detailed design for the Bash-based helper that manages OpenGrok indexing.

## 1. Overview
This tool helps manage many OpenGrok boxes. It runs them one by one during the night (18:00 to 06:00). It also checks if the computer is too tired (CPU, Memory, Disk, and Processes) to make sure everything runs smoothly.

## 2. Main Features
- **Time Watcher**: It only runs during the lucky hours you pick (like at night).
- **Body Check (Resource Monitoring)**: 
  - **Brain (CPU)**: It checks how busy the computer's brain is right now.
  - **Thinking Space (Memory)**: It makes sure there is enough room to think, excluding temporary notes (cache).
  - **Internet (Network)**: It checks how fast the internet pipe is moving.
  - **Busy Score (Process)**: it counts how many other programs are running or waiting.
- **Easy Settings**: It uses a simple `.env` file for rules, so they are easy to change.
- **Diary (Logging)**: It writes everything down in a notebook (SQLite3) and a log file.
- **Status Report**: You can ask for a summary using the `--status` command.

## 3. Tools We Use
- **Language**: Bash Script
- **Notebook (Database)**: SQLite3
- **Boxes**: Docker CLI
- **Measuring Tools**: `top`, `free`, `iostat`, `/proc/net/dev`, `/sys/class/net/`

## 4. Notebook Design (SQLite3)

### 4.1 Configuration File (`.env`)
This file holds the rules for the helper.
- `DB_PATH`: Where the notebook file is
- `LOG_DIR`: Where the diary is kept
- `START_TIME`: When work begins
- `END_TIME`: When work ends
- `RESOURCE_THRESHOLD`: How busy the computer can be
- `CHECK_INTERVAL`: How long to wait between checks

### 4.2 Boxes Table (`services`)
This is the list of boxes to work on.
- `id`: Row number
- `container_name`: The name of the box
- `priority`: How important this box is (higher number means it goes sooner)
- `is_active`: Is this box ready to work? (1: Yes, 0: No)

### 4.3 Work Table (`jobs`)
This is where the helper writes down what happened.
- `id`: Row number
- `service_id`: Which box was working
- `status`: How it's doing ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED')
- `start_time`: When it started
- `end_time`: When it finished
- `duration`: How many seconds it took
- `message`: Extra notes (like if there was a problem)

## 5. How Corporate Brain Works (The Algorithm)

### 5.1 The Main Loop
1. Read the rules from the `.env` file.
2. Check the clock. Is it time to work? If not, wait and check again.
3. Check the computer's body. If any measurement is too high (above the limit), wait.
4. Look for the next box that needs help (not worked in the last 23 hours).
    - It picks the box that usually takes the most time first (Longest Job First).
5. Start the work and update the notebook when finished.

### 5.2 Measuring Details
- **Brain (CPU)**: Checks the "idle" time to see how busy the brain is right now.
- **Memory**: Checks how much "available" space is left compared to the total.
- **Disk I/O**: Uses `iostat` to see how busy the computer is reading books.
- **Internet**: Checks the speed of the internet interface.
- **Busy Score**: Checks how many programs are "running" or "blocked."

## 6. How to Talk to It (CLI)

### 6.1 Status Command
You can ask for a report anytime.
- It shows each box's status, start time, how long it took, and the result.
- It shows how many boxes are finished out of the total for the last 23 hours.

## 7. Being Careful (Exception Handling)
- **Different Languages**: The helper understands computer measurements even if the computer speaks different languages.
- **Internet Speed**: If it can't find the internet speed, it uses a safe guess (100Mbps).
- **Safe Notebook**: It is very careful when writing in the notebook so it doesn't get stuck (DB Lock).
