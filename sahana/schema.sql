CREATE TABLE IF NOT EXISTS config (
    id INTEGER PRIMARY KEY CHECK (id = 1), now INTEGER NOT NULL,
    detector TEXT NOT NULL, response_seconds INTEGER NOT NULL,
    run_mode TEXT NOT NULL DEFAULT 'demo'
);
CREATE TABLE IF NOT EXISTS people (
    id TEXT PRIMARY KEY, name TEXT NOT NULL,
    movement INTEGER NOT NULL DEFAULT 0, facial INTEGER NOT NULL DEFAULT 0,
    paused INTEGER NOT NULL DEFAULT 0, self_medication INTEGER NOT NULL DEFAULT 0,
    movement_session INTEGER NOT NULL DEFAULT 0, movement_session_start INTEGER,
    camera INTEGER NOT NULL DEFAULT 0, recording INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS routine_windows (
    person TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    signal TEXT NOT NULL,
    starts INTEGER NOT NULL, ends INTEGER NOT NULL,
    name TEXT,
    PRIMARY KEY(person, signal)
);
CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY, person TEXT NOT NULL REFERENCES people(id),
    kind TEXT NOT NULL, observation TEXT NOT NULL, source TEXT NOT NULL,
    room TEXT, observed_at INTEGER NOT NULL, recorded_at INTEGER NOT NULL,
    reason TEXT NOT NULL, flagged INTEGER NOT NULL, optional INTEGER NOT NULL,
    routine TEXT, setting TEXT, coverage_start INTEGER, movement_session INTEGER
);
CREATE INDEX IF NOT EXISTS events_person ON events (person);
CREATE TABLE IF NOT EXISTS checkins (
    id TEXT PRIMARY KEY, person TEXT NOT NULL REFERENCES people(id),
    event_id TEXT REFERENCES events(id) ON DELETE SET NULL,
    routine_day TEXT NOT NULL, reason TEXT NOT NULL, state TEXT NOT NULL,
    opens_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
    signal TEXT NOT NULL,
    UNIQUE(person, routine_day, signal)
);
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY, person TEXT NOT NULL REFERENCES people(id),
    kind TEXT NOT NULL, label TEXT NOT NULL, reason TEXT NOT NULL,
    priority INTEGER NOT NULL, deadline INTEGER NOT NULL, created_at INTEGER NOT NULL,
    due_at INTEGER, acknowledged_at INTEGER, resolved_at INTEGER, administered_at INTEGER,
    event_reason TEXT, self_managed INTEGER NOT NULL DEFAULT 0,
    reminder_acknowledged_at INTEGER
);
CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY, created_at INTEGER NOT NULL,
    message TEXT NOT NULL DEFAULT 'Assistance requested'
);
CREATE TABLE IF NOT EXISTS routine_preferences (
    id TEXT PRIMARY KEY, person TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    label TEXT NOT NULL, due_minute INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS routine_preferences_person ON routine_preferences (person, due_minute);
CREATE TABLE IF NOT EXISTS routine_preference_logs (
    preference TEXT NOT NULL REFERENCES routine_preferences(id) ON DELETE CASCADE,
    routine_day TEXT NOT NULL,
    PRIMARY KEY (preference, routine_day)
);
CREATE TABLE IF NOT EXISTS chat_messages (
    person TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    id TEXT NOT NULL, sender TEXT NOT NULL, message TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (person, id)
);
