-- sql/init_db.sql
-- Batch Job Scheduler Schema

-- Services Table
CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    container_name TEXT UNIQUE NOT NULL,
    priority INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1
);

-- Runs Table — one row per scheduling cycle (nightly window or manual init)
CREATE TABLE IF NOT EXISTS runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at      DATETIME NOT NULL,
    ended_at        DATETIME,
    status          TEXT NOT NULL CHECK(status IN ('RUNNING','COMPLETED','PARTIAL','ABORTED')),
    triggered_by    TEXT NOT NULL DEFAULT 'auto' CHECK(triggered_by IN ('auto','manual','init')),
    total_services    INTEGER,
    completed_count   INTEGER DEFAULT 0,
    failed_count      INTEGER DEFAULT 0,
    timeout_count     INTEGER DEFAULT 0,
    orphaned_count    INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
CREATE INDEX IF NOT EXISTS idx_runs_started_at ON runs(started_at);

-- Jobs Table
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    run_id INTEGER REFERENCES runs(id),
    status TEXT NOT NULL CHECK(status IN ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED', 'TIMEOUT', 'ORPHANED')),
    pid INTEGER,
    pid_starttime INTEGER,
    process_state TEXT DEFAULT 'UNKNOWN',
    start_time DATETIME,
    end_time DATETIME,
    duration INTEGER,
    message TEXT,
    FOREIGN KEY (service_id) REFERENCES services(id)
);

CREATE INDEX IF NOT EXISTS idx_jobs_run_id ON jobs(run_id);

-- Heartbeat Table
CREATE TABLE IF NOT EXISTS heartbeat (
    id INTEGER PRIMARY KEY,
    last_pulse DATETIME
);
