-- sql/init_db.sql
-- OpenGrok Scheduler Schema

-- Services Table
CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    container_name TEXT UNIQUE NOT NULL,
    priority INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1
);

-- Jobs Table
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED')),
    start_time DATETIME,
    end_time DATETIME,
    duration INTEGER,
    message TEXT,
    FOREIGN KEY (service_id) REFERENCES services(id)
);
