# Implementation Tasks (TDD & E2E Focused)

## Coding Rules: Be a Good Student!

**Write all code in this order: Red → Green → Refactor.**

1. **Red**: Write a test that fails first and run it.
2. **Green**: Write the smallest amount of code to make the test pass.
3. **Refactor**: Clean up the code while the test still passes.

Never write code without a test! Only make one small change at a time (Baby Steps).
When adding a new phase, you must add **Test** and **E2E** items to the list.

---

## Phase 1: Environment & Database Setup
- [x] **Test**: Write test code for making the notebook (schema) and adding initial rules.
- [x] Create the project folders (bin, logs, sql).
- [x] Write the notebook setup script (`init_db.sql`).
  - [x] Create `config`, `services`, and `jobs` tables.
- [x] Write the special tool for talking to the notebook (`db_query.sh`).
- [x] **E2E**: Check if the notebook initializes and basic queries work.

## Phase 2: Resource Monitoring Module
- [x] **Test**: Write tests for when the computer is too tired (CPU 100%, Disk Full, etc.).
- [x] Teach the helper to calculate Brain (CPU), Space (Memory), Disk, and Process usage.
- [x] Write the main body check function (check 70% limit).
- [x] **E2E**: Check if the helper can read real computer stats and judge the limits.

## Phase 3: Scheduler Core Logic
- [x] **Test**: Write tests for working during the night and sleeping during the day.
- [x] Teach the helper to decide whether to work based on the clock.
- [x] Create the main loop (runs every 5 minutes) and the box-turn logic.
- [x] **E2E**: Check the whole scheduling flow using fake boxes (Docker).

## Phase 4: CLI Interface (`--status`)
- [x] **Test**: Check if the reports look right for different stories (Waiting, Running, Done, Failed).
- [x] Make the `--status` command show a summary report.
- [x] **E2E**: Ask for the status report while the helper is working and check if it's correct.

## Phase 5: Final Verification
- [x] Run a big integration test with 70 fake boxes.
- [x] Check if the helper waits correctly when the computer is very busy.
- [x] Test if the helper can recover from problems (DB Lock, Docker errors).

## Phase 6: Maintenance & Enhancement
- [x] **Test**: Check the math for counting busy programs using `/proc`.
- [x] Make the process monitoring better using `/proc/stat` and `/proc/loadavg`.
- [x] Fine-tune the body check limits and verify them.
- [x] **Feature**: Add a way to start fresh for the day (`--init`).
- [x] **Test**: Check if starting fresh works and the helper restarts correctly.
- [x] **Feature**: Let the helper start tasks in the background and keep a fixed waiting time.
  - [x] Always wait for the `check_interval` time even if there is no work.
  - [x] Run indexing tasks in the background (no limit on count).
- [x] **Stabilization**: Make the notebook safe for many programs (WAL & Busy Timeout).
  - [x] Add `busy_timeout` and `WAL` mode to `db_query.sh`.
  - [x] Write a stress test to write to the notebook many times at once.
  - [x] Test again and again until there are no errors.

## Phase 7: Monitoring & UI Enhancement
- [x] **Test**: Write tests for when limits are crossed and columns are mapped correctly.
- [x] Remove the extra `Result` column and map everything to the `Message` field.
- [x] Show more details in the diary when the computer is too tired.
- [x] Change the memory window from 20 hours to 23 hours everywhere.
- [x] **E2E**: Check if the diary and reports match real-life busy moments.