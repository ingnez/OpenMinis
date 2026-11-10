BEGIN TRANSACTION;
CREATE TABLE app_notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    session_id TEXT,
    bot_id TEXT,
    created_at REAL NOT NULL
);
CREATE TABLE app_settings (name TEXT PRIMARY KEY, value TEXT);
CREATE TABLE approvals (
        approval_id TEXT PRIMARY KEY,
        task_id TEXT,
        tool_call_id TEXT,
        tool TEXT,
        arguments TEXT,
        rule_id TEXT,
        category TEXT,
        reason TEXT,
        status TEXT,
        note TEXT,
        created_at REAL,
        expires_at REAL,
        decided_at REAL
    );
CREATE TABLE bot_delegations (
    delegation_id TEXT PRIMARY KEY,
    kind TEXT,               -- message / task
    from_bot TEXT,
    to_bot TEXT,
    from_session TEXT,
    from_task TEXT,
    to_session TEXT,
    to_task TEXT,
    content TEXT,
    priority TEXT,
    report_back INTEGER,
    hop INTEGER,
    root_id TEXT,
    status TEXT,             -- running / completed / failed / cancelled / limit_reached
    result TEXT,
    reported INTEGER DEFAULT 0,
    created_at REAL,
    finished_at REAL
);
CREATE TABLE credentials (
        name TEXT PRIMARY KEY,
        protocol TEXT,
        base_url TEXT,
        ciphertext BLOB NOT NULL,
        key_hint TEXT,
        created_at REAL,
        updated_at REAL
    );
CREATE TABLE group_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id TEXT NOT NULL,
        sender TEXT NOT NULL,
        kind TEXT NOT NULL,
        content TEXT,
        reply_to INTEGER,
        meta TEXT,
        timestamp REAL
    );
CREATE TABLE groups (
        group_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        members TEXT NOT NULL,
        activity TEXT,
        created_at REAL,
        updated_at REAL
    );
CREATE TABLE memory_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL DEFAULT 'note',
        content TEXT NOT NULL,
        source TEXT NOT NULL,
        origin TEXT,
        entry_time TEXT,
        content_hash TEXT NOT NULL UNIQUE,
        session_id TEXT,
        created_at REAL NOT NULL
    , persona TEXT NOT NULL DEFAULT '');
PRAGMA writable_schema=ON;
INSERT INTO sqlite_master(type,name,tbl_name,rootpage,sql)VALUES('table','memory_fts','memory_fts',0,'CREATE VIRTUAL TABLE memory_fts USING fts5(content, content=''memory_entries'', content_rowid=''id'', tokenize=''trigram'')');
CREATE TABLE 'memory_fts_config'(k PRIMARY KEY, v) WITHOUT ROWID;
INSERT INTO "memory_fts_config" VALUES('version',4);
CREATE TABLE 'memory_fts_data'(id INTEGER PRIMARY KEY, block BLOB);
INSERT INTO "memory_fts_data" VALUES(1,X'');
INSERT INTO "memory_fts_data" VALUES(10,X'00000000000000');
CREATE TABLE 'memory_fts_docsize'(id INTEGER PRIMARY KEY, sz BLOB);
CREATE TABLE 'memory_fts_idx'(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID;
CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT,
        role TEXT,
        content TEXT,
        tool_calls TEXT,
        tool_call_id TEXT,
        timestamp REAL
    );
INSERT INTO "messages" VALUES(1,'sess_d2aea712c4d2','user','升级前的消息',NULL,NULL,1.0);
CREATE TABLE pages (
        page_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        html TEXT NOT NULL,
        summary TEXT,
        session_id TEXT,
        task_id TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
CREATE TABLE personas (
        persona_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        instructions TEXT NOT NULL,
        emoji TEXT,
        created_at REAL,
        updated_at REAL
    , description TEXT, model TEXT, credential TEXT, skills TEXT, plugins TEXT, is_primary INTEGER NOT NULL DEFAULT 0, reasoning_effort TEXT, fast_mode INTEGER NOT NULL DEFAULT 0);
INSERT INTO "personas" VALUES('oldbot','旧Bot','x',NULL,1.79430714461116695e+09,1.79430714461116695e+09,NULL,NULL,NULL,NULL,'[]',0,NULL,0);
CREATE TABLE plugins (
        plugin_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        source TEXT NOT NULL,
        manifest TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        default_grant INTEGER NOT NULL DEFAULT 1,
        last_error TEXT,
        installed_at REAL,
        updated_at REAL
    );
CREATE TABLE routine_runs (
        run_id TEXT PRIMARY KEY,
        routine_id TEXT,
        task_id TEXT,
        session_id TEXT,
        trigger TEXT,
        status TEXT,
        result TEXT,
        error TEXT,
        started_at REAL,
        finished_at REAL
    );
CREATE TABLE routines (
        routine_id TEXT PRIMARY KEY,
        name TEXT,
        prompt TEXT,
        schedule TEXT,
        credential TEXT,
        model TEXT,
        instructions TEXT,
        enabled INTEGER,
        max_runs INTEGER,
        run_count INTEGER DEFAULT 0,
        next_run_at REAL,
        last_run_at REAL,
        last_status TEXT,
        notify INTEGER DEFAULT 1,
        created_at REAL,
        updated_at REAL
    , persona_id TEXT, reasoning_effort TEXT);
CREATE TABLE secure_settings (
        name TEXT PRIMARY KEY,
        ciphertext BLOB NOT NULL,
        updated_at REAL NOT NULL
    );
CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        local_session_id TEXT UNIQUE,
        title TEXT,
        instructions TEXT,
        created_at REAL
    , persona_id TEXT, incognito INTEGER DEFAULT 0);
INSERT INTO "sessions" VALUES('sess_d2aea712c4d2',NULL,'旧会话',NULL,1.79430714460708427e+09,NULL,0);
INSERT INTO "sessions" VALUES('sess_fa57e78f659c',NULL,'bot 会话',NULL,1.79430714461430072e+09,'oldbot',0);
CREATE TABLE skills (
        name TEXT PRIMARY KEY,
        description TEXT,
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        source TEXT NOT NULL,
        updated_at REAL NOT NULL
    );
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
CREATE TABLE telegram_bot_chats (channel TEXT NOT NULL, chat_id INTEGER NOT NULL, session_id TEXT, updated_at REAL, PRIMARY KEY (channel, chat_id));
CREATE TABLE telegram_chats (chat_id INTEGER PRIMARY KEY, session_id TEXT, updated_at REAL);
CREATE TABLE telegram_state (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE telegram_tasks (task_id TEXT PRIMARY KEY, chat_id INTEGER, created_at REAL, channel TEXT NOT NULL DEFAULT '');
CREATE TABLE usage_daily (
    day TEXT NOT NULL,
    bot_id TEXT NOT NULL,
    model TEXT NOT NULL,
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    calls INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, bot_id, model)
);
CREATE UNIQUE INDEX idx_sessions_local ON sessions(local_session_id) WHERE local_session_id IS NOT NULL;
CREATE UNIQUE INDEX idx_tasks_nonce ON tasks(client_nonce) WHERE client_nonce IS NOT NULL;
CREATE UNIQUE INDEX idx_tasks_session_active ON tasks(session_id) WHERE status IN ('running', 'waiting_user');
CREATE INDEX idx_tasks_session ON tasks(session_id, created_at);
CREATE INDEX idx_task_events_task ON task_events(task_id, id);
CREATE INDEX idx_approvals_task ON approvals(task_id, created_at);
CREATE INDEX idx_routine_runs ON routine_runs(routine_id, started_at);
CREATE INDEX idx_group_messages ON group_messages(group_id, id);
CREATE INDEX idx_memory_origin ON memory_entries(source, origin);
CREATE INDEX idx_memory_created ON memory_entries(created_at);
CREATE TRIGGER memory_ai AFTER INSERT ON memory_entries BEGIN INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content); END;
CREATE TRIGGER memory_ad AFTER DELETE ON memory_entries BEGIN INSERT INTO memory_fts(memory_fts, rowid, content) VALUES ('delete', old.id, old.content); END;
CREATE TRIGGER memory_au AFTER UPDATE ON memory_entries BEGIN INSERT INTO memory_fts(memory_fts, rowid, content) VALUES ('delete', old.id, old.content); INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content); END;
CREATE INDEX idx_pages_updated ON pages(updated_at);
PRAGMA writable_schema=OFF;
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('messages',1);
COMMIT;
