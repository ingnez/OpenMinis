BEGIN TRANSACTION;
CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT,
        role TEXT,
        content TEXT,
        tool_calls TEXT,
        tool_call_id TEXT,
        timestamp REAL
    );
INSERT INTO "messages" VALUES(1,'sess_d15be0ab9a4e','user','升级前的消息',NULL,NULL,1.0);
CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        local_session_id TEXT UNIQUE,
        title TEXT,
        instructions TEXT,
        created_at REAL
    );
INSERT INTO "sessions" VALUES('sess_d15be0ab9a4e',NULL,'旧会话',NULL,1.79430714400789093e+09);
INSERT INTO "sessions" VALUES('sess_cbac6ddb6ae5',NULL,'bot 会话',NULL,1.79430714407694721e+09);
CREATE TABLE task_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT,
        event_type TEXT,
        payload TEXT,
        timestamp REAL
    );
CREATE TABLE tasks (
        task_id TEXT PRIMARY KEY,
        session_id TEXT,
        client_nonce TEXT UNIQUE,
        status TEXT,
        model TEXT,
        created_at REAL
    );
CREATE UNIQUE INDEX idx_sessions_local ON sessions(local_session_id) WHERE local_session_id IS NOT NULL;
CREATE UNIQUE INDEX idx_tasks_nonce ON tasks(client_nonce) WHERE client_nonce IS NOT NULL;
CREATE UNIQUE INDEX idx_tasks_session_running ON tasks(session_id) WHERE status = 'running';
CREATE INDEX idx_tasks_session ON tasks(session_id, created_at);
CREATE INDEX idx_task_events_task ON task_events(task_id, id);
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('messages',1);
COMMIT;
