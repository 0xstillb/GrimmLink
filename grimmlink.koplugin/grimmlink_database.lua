local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local json = require("json")
local logger = require("logger")

local Database = {
    conn = nil,
    db_path = nil,
}

local function fileExists(path)
    if not path or path == "" then
        return false
    end
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function nowEpoch()
    return os.time()
end

local function normalizeShelfType(value)
    local shelf_type = tostring(value or "regular"):lower()
    if shelf_type == "" then
        return "regular"
    end
    if shelf_type ~= "regular" and shelf_type ~= "magic" then
        return "regular"
    end
    return shelf_type
end

local function decodeSettingValue(raw_value)
    if raw_value == nil or raw_value == "" then
        return nil
    end

    local ok, decoded = pcall(json.decode, raw_value)
    if ok and type(decoded) == "table" and decoded.value ~= nil then
        return decoded.value
    end

    if raw_value == "true" then
        return true
    end
    if raw_value == "false" then
        return false
    end

    local numeric = tonumber(raw_value)
    if numeric ~= nil then
        return numeric
    end

    return raw_value
end

local function encodeSettingValue(value)
    if value == nil then
        return nil
    end

    local ok, encoded = pcall(json.encode, { value = value })
    if ok then
        return encoded
    end

    return tostring(value)
end

local function firstRow(stmt, mapper)
    if not stmt then
        return nil
    end

    local result = nil
    for row in stmt:rows() do
        if mapper then
            result = mapper(row)
        else
            result = row
        end
        break
    end
    stmt:close()
    return result
end

local function allRows(stmt, mapper)
    local result = {}
    if not stmt then
        return result
    end

    for row in stmt:rows() do
        result[#result + 1] = mapper(row)
    end
    stmt:close()
    return result
end

local function rowOrNil(row)
    return row and row[1] or nil
end

Database.schema_sql = {
    [[
        CREATE TABLE IF NOT EXISTS plugin_settings (
            key TEXT PRIMARY KEY,
            value TEXT,
            updated_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    ]],
    [[
        CREATE TABLE IF NOT EXISTS book_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL UNIQUE,
            file_hash TEXT NOT NULL,
            book_id INTEGER,
            title TEXT,
            author TEXT,
            last_accessed INTEGER,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            updated_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_book_cache_hash ON book_cache(file_hash)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_book_cache_book_id ON book_cache(book_id)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS progress_state (
            file_hash TEXT PRIMARY KEY,
            file_path TEXT,
            book_id INTEGER,
            document TEXT,
            book_type TEXT,
            local_progress TEXT,
            local_location TEXT,
            local_percentage REAL,
            local_current_page INTEGER,
            local_total_pages INTEGER,
            local_timestamp INTEGER,
            remote_progress TEXT,
            remote_location TEXT,
            remote_percentage REAL,
            remote_current_page INTEGER,
            remote_total_pages INTEGER,
            remote_device TEXT,
            remote_device_id TEXT,
            remote_source TEXT,
            remote_timestamp INTEGER,
            last_action TEXT,
            updated_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_progress_state_book_id ON progress_state(book_id)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS pending_progress (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_hash TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'native',
            payload_json TEXT NOT NULL,
            retry_count INTEGER DEFAULT 0,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            last_retry_at INTEGER,
            UNIQUE(file_hash, kind)
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_progress_kind ON pending_progress(kind)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS pending_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER,
            book_hash TEXT NOT NULL,
            book_type TEXT DEFAULT 'EPUB',
            device TEXT,
            device_id TEXT NOT NULL DEFAULT '',
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            duration_seconds INTEGER NOT NULL,
            duration_formatted TEXT,
            start_progress REAL DEFAULT 0.0,
            end_progress REAL DEFAULT 0.0,
            progress_delta REAL DEFAULT 0.0,
            start_location TEXT,
            end_location TEXT,
            current_page INTEGER,
            total_pages INTEGER,
            retry_count INTEGER DEFAULT 0,
            last_retry_at INTEGER,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(book_hash, start_time, end_time, device_id)
        )
    ]],
    [[
        CREATE TABLE IF NOT EXISTS book_tracking_state (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_hash TEXT NOT NULL DEFAULT '',
            file_path TEXT NOT NULL DEFAULT '',
            tracking_enabled INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            updated_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(file_hash, file_path)
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_book_tracking_hash ON book_tracking_state(file_hash)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_book_tracking_path ON book_tracking_state(file_path)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_sessions_book_hash ON pending_sessions(book_hash)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_sessions_book_id ON pending_sessions(book_id)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS pending_metadata_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_hash TEXT NOT NULL,
            book_id INTEGER,
            book_file_id INTEGER,
            item_type TEXT NOT NULL,
            dedupe_key TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            retry_count INTEGER DEFAULT 0,
            last_retry_at INTEGER,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            updated_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(file_hash, item_type, dedupe_key)
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_metadata_file_hash ON pending_metadata_items(file_hash)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_metadata_book_id ON pending_metadata_items(book_id)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_metadata_item_type ON pending_metadata_items(item_type)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_metadata_created_at ON pending_metadata_items(created_at)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS synced_metadata_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_hash TEXT NOT NULL,
            book_id INTEGER,
            item_type TEXT NOT NULL,
            dedupe_key TEXT NOT NULL,
            server_id TEXT,
            synced_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(file_hash, item_type, dedupe_key)
        )
    ]],
    [[
        CREATE TABLE IF NOT EXISTS shelf_sync_map (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL,
            shelf_id INTEGER NOT NULL,
            shelf_type TEXT NOT NULL DEFAULT 'regular',
            remote_filename TEXT,
            remote_title TEXT,
            remote_author TEXT,
            remote_format TEXT,
            remote_file_size_kb INTEGER,
            remote_series_name TEXT,
            remote_series_number REAL,
            local_path TEXT,
            downloaded_at INTEGER,
            last_seen_in_shelf_at INTEGER,
            downloaded_by_grimmlink INTEGER DEFAULT 1,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            updated_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(book_id, shelf_id, shelf_type)
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_shelf_id ON shelf_sync_map(shelf_id)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_book_id ON shelf_sync_map(book_id)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_shelf_type ON shelf_sync_map(shelf_type)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_local_path ON shelf_sync_map(local_path)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS pending_shelf_removals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL,
            shelf_id INTEGER NOT NULL,
            shelf_type TEXT NOT NULL DEFAULT 'regular',
            local_path TEXT,
            delete_sdr INTEGER DEFAULT 0,
            retry_count INTEGER DEFAULT 0,
            last_retry_at INTEGER,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            updated_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(book_id, shelf_id, shelf_type)
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_shelf_removals_shelf_id ON pending_shelf_removals(shelf_id)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_shelf_removals_shelf_type ON pending_shelf_removals(shelf_type)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS shelf_sync_tombstones (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL,
            shelf_id INTEGER NOT NULL,
            shelf_type TEXT NOT NULL DEFAULT 'regular',
            local_path TEXT,
            remote_title TEXT,
            remote_series_name TEXT,
            removed_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(book_id, shelf_id, shelf_type)
        )
    ]],
}

function Database:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Database:_exec(sql)
    if not self.conn then
        return false
    end
    return self.conn:exec(sql) == SQ3.OK
end

function Database:repairSchema()
    if not self.conn then
        return false
    end

    for _, sql in ipairs(self.schema_sql) do
        if not self:_exec(sql) then
            logger.err("GrimmLink Database: schema repair failed:", self.conn:errmsg())
            return false
        end
    end

    self:_migrateMetadataSyncTables()
    self:_migrateBookTrackingState()
    self:_migrateShelfSyncV2()
    self:_migrateShelfSyncSeriesColumns()
    return true
end

function Database:_migrateMetadataSyncTables()
    local migration_sql = {
        [[
            CREATE TABLE IF NOT EXISTS pending_metadata_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_hash TEXT NOT NULL,
                book_id INTEGER,
                book_file_id INTEGER,
                item_type TEXT NOT NULL,
                dedupe_key TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                retry_count INTEGER DEFAULT 0,
                last_retry_at INTEGER,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER DEFAULT (strftime('%s', 'now')),
                UNIQUE(file_hash, item_type, dedupe_key)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_metadata_file_hash ON pending_metadata_items(file_hash)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_metadata_book_id ON pending_metadata_items(book_id)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_metadata_item_type ON pending_metadata_items(item_type)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_metadata_created_at ON pending_metadata_items(created_at)
        ]],
        [[
            CREATE TABLE IF NOT EXISTS synced_metadata_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_hash TEXT NOT NULL,
                book_id INTEGER,
                item_type TEXT NOT NULL,
                dedupe_key TEXT NOT NULL,
                server_id TEXT,
                synced_at INTEGER DEFAULT (strftime('%s', 'now')),
                UNIQUE(file_hash, item_type, dedupe_key)
            )
        ]],
    }

    for _, sql in ipairs(migration_sql) do
        self:_exec(sql)
    end
end

function Database:_migrateShelfSyncV2()
    local function tableHasColumn(table_name, column_name)
        local stmt = self.conn and self.conn:prepare("PRAGMA table_info(" .. table_name .. ")")
        if not stmt then
            return false
        end
        local found = false
        for row in stmt:rows() do
            if row[2] == column_name then
                found = true
                break
            end
        end
        stmt:close()
        return found
    end

    local function tableColumns(table_name)
        local cols = {}
        local stmt = self.conn and self.conn:prepare("PRAGMA table_info(" .. table_name .. ")")
        if not stmt then
            return cols
        end
        for row in stmt:rows() do
            local name = tostring(row[2] or "")
            if name ~= "" then
                cols[name] = true
            end
        end
        stmt:close()
        return cols
    end

    local function colOr(cols, column_name, fallback)
        if cols[column_name] then
            return column_name
        end
        return fallback
    end

    local function migrateShelfSyncMap()
        if tableHasColumn("shelf_sync_map", "shelf_type") then
            return true
        end

        local cols = tableColumns("shelf_sync_map")
        local select_sql = string.format([[
                SELECT
                    %s, %s, 'regular', %s, %s, %s,
                    %s, %s, %s, %s,
                    %s, %s, %s, %s,
                    %s, %s
                FROM shelf_sync_map
            ]],
            colOr(cols, "book_id", "0"),
            colOr(cols, "shelf_id", "0"),
            colOr(cols, "remote_filename", "NULL"),
            colOr(cols, "remote_title", "NULL"),
            colOr(cols, "remote_author", "NULL"),
            colOr(cols, "remote_format", "NULL"),
            colOr(cols, "remote_file_size_kb", "NULL"),
            colOr(cols, "remote_series_name", "NULL"),
            colOr(cols, "remote_series_number", "NULL"),
            colOr(cols, "local_path", "NULL"),
            colOr(cols, "downloaded_at", "NULL"),
            colOr(cols, "last_seen_in_shelf_at", "NULL"),
            colOr(cols, "downloaded_by_grimmlink", "1"),
            colOr(cols, "created_at", "strftime('%s', 'now')"),
            colOr(cols, "updated_at", "strftime('%s', 'now')")
        )

        local migration_sql = {
            "BEGIN IMMEDIATE TRANSACTION",
            [[
                CREATE TABLE IF NOT EXISTS shelf_sync_map_v2 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book_id INTEGER NOT NULL,
                    shelf_id INTEGER NOT NULL,
                    shelf_type TEXT NOT NULL DEFAULT 'regular',
                    remote_filename TEXT,
                    remote_title TEXT,
                    remote_author TEXT,
                    remote_format TEXT,
                    remote_file_size_kb INTEGER,
                    remote_series_name TEXT,
                    remote_series_number REAL,
                    local_path TEXT,
                    downloaded_at INTEGER,
                    last_seen_in_shelf_at INTEGER,
                    downloaded_by_grimmlink INTEGER DEFAULT 1,
                    created_at INTEGER DEFAULT (strftime('%s', 'now')),
                    updated_at INTEGER DEFAULT (strftime('%s', 'now')),
                    UNIQUE(book_id, shelf_id, shelf_type)
                )
            ]],
            [[
                INSERT INTO shelf_sync_map_v2 (
                    book_id, shelf_id, shelf_type, remote_filename, remote_title, remote_author,
                    remote_format, remote_file_size_kb, remote_series_name, remote_series_number,
                    local_path, downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink,
                    created_at, updated_at
                )
            ]] .. select_sql,
            "DROP TABLE shelf_sync_map",
            "ALTER TABLE shelf_sync_map_v2 RENAME TO shelf_sync_map",
            "CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_shelf_id ON shelf_sync_map(shelf_id)",
            "CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_book_id ON shelf_sync_map(book_id)",
            "CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_shelf_type ON shelf_sync_map(shelf_type)",
            "CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_local_path ON shelf_sync_map(local_path)",
            "COMMIT",
        }

        for _, sql in ipairs(migration_sql) do
            if not self:_exec(sql) then
                self:_exec("ROLLBACK")
                logger.err("GrimmLink Database: shelf_sync_map migration failed:", self.conn and self.conn:errmsg() or "unknown")
                return false
            end
        end
        return true
    end

    local function migratePendingShelfRemovals()
        if tableHasColumn("pending_shelf_removals", "shelf_type") then
            return true
        end

        local cols = tableColumns("pending_shelf_removals")
        local select_sql = string.format([[
                SELECT
                    %s, %s, 'regular', %s, %s, %s,
                    %s, %s, %s
                FROM pending_shelf_removals
            ]],
            colOr(cols, "book_id", "0"),
            colOr(cols, "shelf_id", "0"),
            colOr(cols, "local_path", "NULL"),
            colOr(cols, "delete_sdr", "0"),
            colOr(cols, "retry_count", "0"),
            colOr(cols, "last_retry_at", "NULL"),
            colOr(cols, "created_at", "strftime('%s', 'now')"),
            colOr(cols, "updated_at", "strftime('%s', 'now')")
        )

        local migration_sql = {
            "BEGIN IMMEDIATE TRANSACTION",
            [[
                CREATE TABLE IF NOT EXISTS pending_shelf_removals_v2 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book_id INTEGER NOT NULL,
                    shelf_id INTEGER NOT NULL,
                    shelf_type TEXT NOT NULL DEFAULT 'regular',
                    local_path TEXT,
                    delete_sdr INTEGER DEFAULT 0,
                    retry_count INTEGER DEFAULT 0,
                    last_retry_at INTEGER,
                    created_at INTEGER DEFAULT (strftime('%s', 'now')),
                    updated_at INTEGER DEFAULT (strftime('%s', 'now')),
                    UNIQUE(book_id, shelf_id, shelf_type)
                )
            ]],
            [[
                INSERT INTO pending_shelf_removals_v2 (
                    book_id, shelf_id, shelf_type, local_path, delete_sdr, retry_count,
                    last_retry_at, created_at, updated_at
                )
            ]] .. select_sql,
            "DROP TABLE pending_shelf_removals",
            "ALTER TABLE pending_shelf_removals_v2 RENAME TO pending_shelf_removals",
            "CREATE INDEX IF NOT EXISTS idx_pending_shelf_removals_shelf_id ON pending_shelf_removals(shelf_id)",
            "CREATE INDEX IF NOT EXISTS idx_pending_shelf_removals_shelf_type ON pending_shelf_removals(shelf_type)",
            "COMMIT",
        }

        for _, sql in ipairs(migration_sql) do
            if not self:_exec(sql) then
                self:_exec("ROLLBACK")
                logger.err("GrimmLink Database: pending_shelf_removals migration failed:", self.conn and self.conn:errmsg() or "unknown")
                return false
            end
        end
        return true
    end

    local function migrateShelfSyncTombstones()
        if tableHasColumn("shelf_sync_tombstones", "shelf_type") then
            return true
        end

        local cols = tableColumns("shelf_sync_tombstones")
        local select_sql = string.format([[
                SELECT
                    %s, %s, 'regular', %s, %s, %s, %s
                FROM shelf_sync_tombstones
            ]],
            colOr(cols, "book_id", "0"),
            colOr(cols, "shelf_id", "0"),
            colOr(cols, "local_path", "NULL"),
            colOr(cols, "remote_title", "NULL"),
            colOr(cols, "remote_series_name", "NULL"),
            colOr(cols, "removed_at", "strftime('%s', 'now')")
        )

        local migration_sql = {
            "BEGIN IMMEDIATE TRANSACTION",
            [[
                CREATE TABLE IF NOT EXISTS shelf_sync_tombstones_v2 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book_id INTEGER NOT NULL,
                    shelf_id INTEGER NOT NULL,
                    shelf_type TEXT NOT NULL DEFAULT 'regular',
                    local_path TEXT,
                    remote_title TEXT,
                    remote_series_name TEXT,
                    removed_at INTEGER DEFAULT (strftime('%s', 'now')),
                    UNIQUE(book_id, shelf_id, shelf_type)
                )
            ]],
            [[
                INSERT INTO shelf_sync_tombstones_v2 (
                    book_id, shelf_id, shelf_type, local_path, remote_title, remote_series_name, removed_at
                )
            ]] .. select_sql,
            "DROP TABLE shelf_sync_tombstones",
            "ALTER TABLE shelf_sync_tombstones_v2 RENAME TO shelf_sync_tombstones",
            "COMMIT",
        }

        for _, sql in ipairs(migration_sql) do
            if not self:_exec(sql) then
                self:_exec("ROLLBACK")
                logger.err("GrimmLink Database: shelf_sync_tombstones migration failed:", self.conn and self.conn:errmsg() or "unknown")
                return false
            end
        end
        return true
    end

    return migrateShelfSyncMap()
        and migratePendingShelfRemovals()
        and migrateShelfSyncTombstones()
end

function Database:_migrateShelfSyncSeriesColumns()
    local has_column = false
    local stmt = self.conn and self.conn:prepare("PRAGMA table_info(shelf_sync_map)")
    if stmt then
        for row in stmt:rows() do
            if row[2] == "remote_series_name" then
                has_column = true
                break
            end
        end
        stmt:close()
    end
    if has_column then return end
    self:_exec("ALTER TABLE shelf_sync_map ADD COLUMN remote_series_name TEXT")
    self:_exec("ALTER TABLE shelf_sync_map ADD COLUMN remote_series_number REAL")
end

function Database:init(db_name)
    db_name = db_name or "grimmlink.sqlite"
    self.db_path = DataStorage:getSettingsDir() .. "/" .. db_name
    self.conn = SQ3.open(self.db_path)
    if not self.conn then
        logger.err("GrimmLink Database: failed to open", self.db_path)
        return false
    end

    self:_exec("PRAGMA foreign_keys = ON")
    pcall(function()
        self:_exec("PRAGMA journal_mode = TRUNCATE")
    end)

    return self:repairSchema()
end

function Database:close()
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

function Database:getPluginSetting(key)
    local stmt = self.conn and self.conn:prepare("SELECT value FROM plugin_settings WHERE key = ?")
    if not stmt then
        return nil
    end

    stmt:bind(key)
    return firstRow(stmt, function(row)
        return decodeSettingValue(row[1])
    end)
end

function Database:savePluginSetting(key, value)
    local encoded = encodeSettingValue(value)
    local sql = "INSERT INTO plugin_settings (key, value, updated_at) VALUES (?, ?, ?) " ..
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at"

    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        if not self:repairSchema() then
            return false
        end
        stmt = self.conn and self.conn:prepare(sql)
        if not stmt then
            return false
        end
    end

    stmt:bind(key, encoded, nowEpoch())
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

local function mapBookCacheRow(row)
    return {
        id = tonumber(row[1]) or row[1],
        file_path = row[2],
        file_hash = row[3],
        book_id = tonumber(row[4]) or row[4],
        title = row[5],
        author = row[6],
        last_accessed = tonumber(row[7]) or row[7],
    }
end

function Database:getBookByFilePath(file_path)
    local stmt = self.conn and self.conn:prepare(
        "SELECT id, file_path, file_hash, book_id, title, author, last_accessed FROM book_cache WHERE file_path = ?"
    )
    if not stmt then
        return nil
    end
    stmt:bind(file_path)
    return firstRow(stmt, mapBookCacheRow)
end

function Database:getBookByHash(file_hash)
    local stmt = self.conn and self.conn:prepare(
        "SELECT id, file_path, file_hash, book_id, title, author, last_accessed FROM book_cache WHERE file_hash = ? ORDER BY updated_at DESC LIMIT 1"
    )
    if not stmt then
        return nil
    end
    stmt:bind(file_hash)
    return firstRow(stmt, mapBookCacheRow)
end

function Database:getLatestBookPathByBookId(book_id)
    local stmt = self.conn and self.conn:prepare(
        "SELECT file_path FROM book_cache WHERE book_id = ? ORDER BY updated_at DESC LIMIT 1"
    )
    if not stmt then
        return nil
    end
    stmt:bind(book_id)
    local row = firstRow(stmt)
    if not row then
        return nil
    end
    return row[1]
end

function Database:saveBookCache(file_path, file_hash, book_id, title, author)
    local sql = [[
        INSERT INTO book_cache (file_path, file_hash, book_id, title, author, last_accessed, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_path) DO UPDATE SET
            file_hash = excluded.file_hash,
            book_id = excluded.book_id,
            title = excluded.title,
            author = excluded.author,
            last_accessed = excluded.last_accessed,
            updated_at = excluded.updated_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        return false
    end
    local ts = nowEpoch()
    stmt:bind(file_path, file_hash or "", book_id, title, author, ts, ts)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:updateBookId(file_hash, book_id)
    local stmt = self.conn and self.conn:prepare("UPDATE book_cache SET book_id = ?, updated_at = ? WHERE file_hash = ?")
    if not stmt then
        return false
    end
    stmt:bind(book_id, nowEpoch(), file_hash)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:getBookCacheStats()
    local stmt = self.conn and self.conn:prepare(
        "SELECT COUNT(*), SUM(CASE WHEN book_id IS NULL THEN 1 ELSE 0 END), COUNT(DISTINCT file_hash) FROM book_cache"
    )
    if not stmt then
        return { total = 0, unmatched = 0, distinct_hashes = 0 }
    end
    return firstRow(stmt, function(row)
        return {
            total = tonumber(row[1]) or 0,
            unmatched = tonumber(row[2]) or 0,
            distinct_hashes = tonumber(row[3]) or 0,
        }
    end) or { total = 0, unmatched = 0, distinct_hashes = 0 }
end

function Database:getUnmatchedCacheCount()
    local stmt = self.conn and self.conn:prepare("SELECT COUNT(*) FROM book_cache WHERE book_id IS NULL")
    if not stmt then
        return 0
    end
    local value = firstRow(stmt, function(row)
        return tonumber(row[1]) or 0
    end)
    return value or 0
end

function Database:clearUnmatchedCache()
    return self:_exec("DELETE FROM book_cache WHERE book_id IS NULL")
end

function Database:getStaleCacheEntries(limit)
    local stmt = self.conn and self.conn:prepare(
        "SELECT id, file_path, file_hash, book_id, title, author, last_accessed FROM book_cache ORDER BY COALESCE(last_accessed, updated_at) ASC LIMIT ?"
    )
    if not stmt then
        return {}
    end
    stmt:bind(limit or 10)
    return allRows(stmt, mapBookCacheRow)
end

function Database:getStaleCacheCount()
    local stmt = self.conn and self.conn:prepare("SELECT COUNT(*) FROM book_cache")
    if not stmt then
        return 0
    end
    local value = firstRow(stmt, function(row)
        return tonumber(row[1]) or 0
    end)
    return value or 0
end

function Database:clearStaleCache()
    return self:_exec("DELETE FROM book_cache")
end

function Database:deleteAllPendingProgress()
    return self:_exec("DELETE FROM pending_progress")
end

function Database:deletePendingProgressByHash(file_hash)
    local stmt = self.conn and self.conn:prepare("DELETE FROM pending_progress WHERE file_hash = ?")
    if not stmt then
        return false
    end
    stmt:bind(file_hash)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:upsertPendingProgress(file_hash, payload_json, kind)
    local sql = [[
        INSERT INTO pending_progress (file_hash, kind, payload_json, retry_count, created_at, last_retry_at)
        VALUES (?, ?, ?, 0, ?, NULL)
        ON CONFLICT(file_hash, kind) DO UPDATE SET
            payload_json = excluded.payload_json,
            retry_count = 0,
            last_retry_at = NULL,
            created_at = excluded.created_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        return false
    end
    stmt:bind(file_hash, kind or "native", payload_json, nowEpoch())
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

local function mapPendingProgressRow(row)
    return {
        id = row[1],
        file_hash = row[2],
        kind = row[3],
        payload_json = row[4],
        retry_count = row[5],
        created_at = row[6],
        last_retry_at = row[7],
    }
end

function Database:getPendingProgress(limit)
    local stmt = self.conn and self.conn:prepare(
        "SELECT id, file_hash, kind, payload_json, retry_count, created_at, last_retry_at FROM pending_progress ORDER BY created_at ASC LIMIT ?"
    )
    if not stmt then
        return {}
    end
    stmt:bind(limit or 100)
    return allRows(stmt, mapPendingProgressRow)
end

function Database:getPendingProgressCount()
    local stmt = self.conn and self.conn:prepare("SELECT COUNT(*) FROM pending_progress")
    if not stmt then
        return 0
    end
    local value = firstRow(stmt, function(row)
        return tonumber(row[1]) or 0
    end)
    return value or 0
end

function Database:deletePendingProgress(id)
    local stmt = self.conn and self.conn:prepare("DELETE FROM pending_progress WHERE id = ?")
    if not stmt then
        return false
    end
    stmt:bind(id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:incrementPendingProgressRetry(id)
    local stmt = self.conn and self.conn:prepare(
        "UPDATE pending_progress SET retry_count = retry_count + 1, last_retry_at = ? WHERE id = ?"
    )
    if not stmt then
        return false
    end
    stmt:bind(nowEpoch(), id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:_migrateBookTrackingState()
    local migration_sql = {
        [[
            CREATE TABLE IF NOT EXISTS book_tracking_state (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_hash TEXT NOT NULL DEFAULT '',
                file_path TEXT NOT NULL DEFAULT '',
                tracking_enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER DEFAULT (strftime('%s', 'now')),
                UNIQUE(file_hash, file_path)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_book_tracking_hash ON book_tracking_state(file_hash)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_book_tracking_path ON book_tracking_state(file_path)
        ]],
    }
    for _, sql in ipairs(migration_sql) do
        self:_exec(sql)
    end
end

local function mapPendingMetadataRow(row)
    return {
        id = tonumber(row[1]) or row[1],
        file_hash = row[2],
        book_id = tonumber(row[3]) or row[3],
        book_file_id = tonumber(row[4]) or row[4],
        item_type = row[5],
        dedupe_key = row[6],
        payload_json = row[7],
        retry_count = tonumber(row[8]) or row[8],
        last_retry_at = tonumber(row[9]) or row[9],
        created_at = tonumber(row[10]) or row[10],
        updated_at = tonumber(row[11]) or row[11],
    }
end

function Database:upsertPendingMetadataItem(item)
    if type(item) ~= "table" then
        return false
    end

    local payload_json = item.payload_json
    if type(payload_json) == "table" then
        local ok, encoded = pcall(json.encode, payload_json)
        if not ok then
            return false
        end
        payload_json = encoded
    end

    if type(payload_json) ~= "string"
        or payload_json == ""
        or not item.file_hash
        or not item.item_type
        or not item.dedupe_key then
        return false
    end

    local sql = [[
        INSERT INTO pending_metadata_items (
            file_hash, book_id, book_file_id, item_type, dedupe_key, payload_json,
            retry_count, last_retry_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
        ON CONFLICT(file_hash, item_type, dedupe_key) DO UPDATE SET
            book_id = excluded.book_id,
            book_file_id = excluded.book_file_id,
            payload_json = excluded.payload_json,
            retry_count = 0,
            last_retry_at = NULL,
            updated_at = excluded.updated_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        return false
    end
    local ts = nowEpoch()
    stmt:bind(
        item.file_hash,
        item.book_id,
        item.book_file_id,
        item.item_type,
        item.dedupe_key,
        payload_json,
        ts,
        ts
    )
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:getPendingMetadataItems(limit)
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT id, file_hash, book_id, book_file_id, item_type, dedupe_key,
                   payload_json, retry_count, last_retry_at, created_at, updated_at
            FROM pending_metadata_items
            ORDER BY created_at ASC
            LIMIT ?
        ]]
    )
    if not stmt then
        return {}
    end
    stmt:bind(limit or 100)
    return allRows(stmt, mapPendingMetadataRow)
end

function Database:deletePendingMetadataItem(id)
    local stmt = self.conn and self.conn:prepare("DELETE FROM pending_metadata_items WHERE id = ?")
    if not stmt then
        return false
    end
    stmt:bind(id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:incrementPendingMetadataRetry(id)
    local stmt = self.conn and self.conn:prepare(
        "UPDATE pending_metadata_items SET retry_count = retry_count + 1, last_retry_at = ?, updated_at = ? WHERE id = ?"
    )
    if not stmt then
        return false
    end
    local ts = nowEpoch()
    stmt:bind(ts, ts, id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:markMetadataItemSynced(item)
    if type(item) ~= "table" or not item.file_hash or not item.item_type or not item.dedupe_key then
        return false
    end

    local sql = [[
        INSERT INTO synced_metadata_items (file_hash, book_id, item_type, dedupe_key, server_id, synced_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_hash, item_type, dedupe_key) DO UPDATE SET
            book_id = excluded.book_id,
            server_id = excluded.server_id,
            synced_at = excluded.synced_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        return false
    end
    stmt:bind(item.file_hash, item.book_id, item.item_type, item.dedupe_key, item.server_id, nowEpoch())
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:isMetadataItemSynced(file_hash, item_type, dedupe_key)
    local stmt = self.conn and self.conn:prepare(
        "SELECT 1 FROM synced_metadata_items WHERE file_hash = ? AND item_type = ? AND dedupe_key = ?"
    )
    if not stmt then
        return false
    end
    stmt:bind(file_hash, item_type, dedupe_key)
    local row = firstRow(stmt, rowOrNil)
    return row ~= nil
end

function Database:getPendingMetadataCount()
    local stmt = self.conn and self.conn:prepare("SELECT COUNT(*) FROM pending_metadata_items")
    if not stmt then
        return 0
    end
    local value = firstRow(stmt, function(row)
        return tonumber(row[1]) or 0
    end)
    return value or 0
end

function Database:getSyncedMetadataCount()
    local stmt = self.conn and self.conn:prepare("SELECT COUNT(*) FROM synced_metadata_items")
    if not stmt then
        return 0
    end
    local value = firstRow(stmt, function(row)
        return tonumber(row[1]) or 0
    end)
    return value or 0
end

function Database:deleteAllPendingMetadata()
    return self:_exec("DELETE FROM pending_metadata_items")
end

function Database:deletePendingMetadataByFileHash(file_hash)
    if not file_hash or file_hash == "" then
        return false
    end
    local stmt = self.conn and self.conn:prepare("DELETE FROM pending_metadata_items WHERE file_hash = ?")
    if not stmt then
        return false
    end
    stmt:bind(file_hash)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:clearSyncedMetadataHistory()
    return self:_exec("DELETE FROM synced_metadata_items")
end

function Database:clearSyncedMetadataHistoryForFileHash(file_hash)
    if not file_hash or file_hash == "" then
        return false
    end
    local stmt = self.conn and self.conn:prepare("DELETE FROM synced_metadata_items WHERE file_hash = ?")
    if not stmt then
        return false
    end
    stmt:bind(file_hash)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

local function normalizeTrackingKey(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function mapTrackingRow(row)
    return {
        id = tonumber(row[1]) or row[1],
        file_hash = row[2],
        file_path = row[3],
        tracking_enabled = tonumber(row[4]) == 1,
        created_at = tonumber(row[5]) or row[5],
        updated_at = tonumber(row[6]) or row[6],
    }
end

function Database:getBookTrackingState(file_hash, file_path)
    local hash_key = normalizeTrackingKey(file_hash)
    local path_key = normalizeTrackingKey(file_path)
    local row = nil

    if hash_key ~= "" then
        local stmt_hash = self.conn and self.conn:prepare(
            [[
                SELECT id, file_hash, file_path, tracking_enabled, created_at, updated_at
                FROM book_tracking_state
                WHERE file_hash = ?
                ORDER BY updated_at DESC
                LIMIT 1
            ]]
        )
        if stmt_hash then
            stmt_hash:bind(hash_key)
            row = firstRow(stmt_hash, mapTrackingRow)
        end
    end

    if not row and path_key ~= "" then
        local stmt_path = self.conn and self.conn:prepare(
            [[
                SELECT id, file_hash, file_path, tracking_enabled, created_at, updated_at
                FROM book_tracking_state
                WHERE file_path = ?
                ORDER BY updated_at DESC
                LIMIT 1
            ]]
        )
        if stmt_path then
            stmt_path:bind(path_key)
            row = firstRow(stmt_path, mapTrackingRow)
        end
    end

    return row
end

function Database:isTrackingEnabled(file_hash, file_path)
    local row = self:getBookTrackingState(file_hash, file_path)
    if not row then
        return true
    end
    return row.tracking_enabled == true
end

function Database:setTrackingEnabled(file_hash, file_path, enabled)
    local hash_key = normalizeTrackingKey(file_hash)
    local path_key = normalizeTrackingKey(file_path)
    if hash_key == "" and path_key == "" then
        return false
    end

    local normalized = enabled == nil and true or (enabled == true)
    local sql = [[
        INSERT INTO book_tracking_state (file_hash, file_path, tracking_enabled, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(file_hash, file_path) DO UPDATE SET
            tracking_enabled = excluded.tracking_enabled,
            updated_at = excluded.updated_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        return false
    end
    local now = nowEpoch()
    stmt:bind(hash_key, path_key, normalized and 1 or 0, now, now)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:toggleTracking(file_hash, file_path)
    local currently_enabled = self:isTrackingEnabled(file_hash, file_path)
    local next_enabled = not currently_enabled
    if not self:setTrackingEnabled(file_hash, file_path, next_enabled) then
        return nil
    end
    return next_enabled
end

function Database:getPendingCountsForFileHash(file_hash)
    local key = normalizeTrackingKey(file_hash)
    if key == "" then
        return {
            progress = 0,
            sessions = 0,
            metadata = 0,
        }
    end

    local function count(sql)
        local stmt = self.conn and self.conn:prepare(sql)
        if not stmt then
            return 0
        end
        stmt:bind(key)
        local value = firstRow(stmt, function(row)
            return tonumber(row[1]) or 0
        end)
        return value or 0
    end

    return {
        progress = count("SELECT COUNT(*) FROM pending_progress WHERE file_hash = ?"),
        sessions = count("SELECT COUNT(*) FROM pending_sessions WHERE book_hash = ?"),
        metadata = count("SELECT COUNT(*) FROM pending_metadata_items WHERE file_hash = ?"),
    }
end

local function mapProgressStateRow(row)
    return {
        file_hash = row[1],
        file_path = row[2],
        book_id = tonumber(row[3]) or row[3],
        document = row[4],
        book_type = row[5],
        local_progress = row[6],
        local_location = row[7],
        local_percentage = row[8],
        local_current_page = tonumber(row[9]) or row[9],
        local_total_pages = tonumber(row[10]) or row[10],
        local_timestamp = tonumber(row[11]) or row[11],
        remote_progress = row[12],
        remote_location = row[13],
        remote_percentage = row[14],
        remote_current_page = tonumber(row[15]) or row[15],
        remote_total_pages = tonumber(row[16]) or row[16],
        remote_device = row[17],
        remote_device_id = row[18],
        remote_source = row[19],
        remote_timestamp = tonumber(row[20]) or row[20],
        last_action = row[21],
        updated_at = tonumber(row[22]) or row[22],
    }
end

function Database:getProgressState(file_hash)
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT file_hash, file_path, book_id, document, book_type,
                   local_progress, local_location, local_percentage,
                   local_current_page, local_total_pages, local_timestamp,
                   remote_progress, remote_location, remote_percentage,
                   remote_current_page, remote_total_pages, remote_device,
                   remote_device_id, remote_source, remote_timestamp,
                   last_action, updated_at
            FROM progress_state
            WHERE file_hash = ?
        ]]
    )
    if not stmt then
        return nil
    end
    stmt:bind(file_hash)
    return firstRow(stmt, mapProgressStateRow)
end

local function upsertProgressStateSql()
    return [[
        INSERT INTO progress_state (
            file_hash, file_path, book_id, document, book_type,
            local_progress, local_location, local_percentage,
            local_current_page, local_total_pages, local_timestamp,
            remote_progress, remote_location, remote_percentage,
            remote_current_page, remote_total_pages, remote_device,
            remote_device_id, remote_source, remote_timestamp,
            last_action, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_hash) DO UPDATE SET
            file_path = excluded.file_path,
            book_id = excluded.book_id,
            document = excluded.document,
            book_type = excluded.book_type,
            local_progress = excluded.local_progress,
            local_location = excluded.local_location,
            local_percentage = excluded.local_percentage,
            local_current_page = excluded.local_current_page,
            local_total_pages = excluded.local_total_pages,
            local_timestamp = excluded.local_timestamp,
            remote_progress = excluded.remote_progress,
            remote_location = excluded.remote_location,
            remote_percentage = excluded.remote_percentage,
            remote_current_page = excluded.remote_current_page,
            remote_total_pages = excluded.remote_total_pages,
            remote_device = excluded.remote_device,
            remote_device_id = excluded.remote_device_id,
            remote_source = excluded.remote_source,
            remote_timestamp = excluded.remote_timestamp,
            last_action = excluded.last_action,
            updated_at = excluded.updated_at
    ]]
end

function Database:upsertLocalProgressState(file_hash, state)
    local existing = self:getProgressState(file_hash) or {}
    local stmt = self.conn and self.conn:prepare(upsertProgressStateSql())
    if not stmt then
        return false
    end

    stmt:bind(
        file_hash,
        state.file_path or existing.file_path,
        state.book_id or existing.book_id,
        state.document or existing.document,
        state.book_type or existing.book_type,
        state.progress or existing.local_progress,
        state.location or existing.local_location,
        state.percentage or existing.local_percentage,
        state.current_page or existing.local_current_page,
        state.total_pages or existing.local_total_pages,
        state.timestamp or existing.local_timestamp,
        existing.remote_progress,
        existing.remote_location,
        existing.remote_percentage,
        existing.remote_current_page,
        existing.remote_total_pages,
        existing.remote_device,
        existing.remote_device_id,
        existing.remote_source,
        existing.remote_timestamp,
        state.last_action or existing.last_action,
        nowEpoch()
    )
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:upsertRemoteProgressState(file_hash, state)
    local existing = self:getProgressState(file_hash) or {}
    local stmt = self.conn and self.conn:prepare(upsertProgressStateSql())
    if not stmt then
        return false
    end

    stmt:bind(
        file_hash,
        state.file_path or existing.file_path,
        state.book_id or existing.book_id,
        state.document or existing.document,
        state.book_type or existing.book_type,
        existing.local_progress,
        existing.local_location,
        existing.local_percentage,
        existing.local_current_page,
        existing.local_total_pages,
        existing.local_timestamp,
        state.progress or existing.remote_progress,
        state.location or existing.remote_location,
        state.percentage or existing.remote_percentage,
        state.current_page or existing.remote_current_page,
        state.total_pages or existing.remote_total_pages,
        state.device or existing.remote_device,
        state.device_id or state.deviceId or existing.remote_device_id,
        state.source or existing.remote_source,
        state.timestamp or existing.remote_timestamp,
        state.last_action or existing.last_action,
        nowEpoch()
    )
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:setProgressLastAction(file_hash, last_action)
    local stmt = self.conn and self.conn:prepare("UPDATE progress_state SET last_action = ?, updated_at = ? WHERE file_hash = ?")
    if not stmt then
        return false
    end
    stmt:bind(last_action, nowEpoch(), file_hash)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

local function mapShelfEntry(row)
    return {
        id = tonumber(row[1]) or row[1],
        book_id = tonumber(row[2]) or row[2],
        shelf_id = tonumber(row[3]) or row[3],
        shelf_type = normalizeShelfType(row[4]),
        remote_filename = row[5],
        remote_title = row[6],
        remote_author = row[7],
        remote_format = row[8],
        remote_file_size_kb = tonumber(row[9]) or row[9],
        remote_series_name = row[10],
        remote_series_number = tonumber(row[11]),
        local_path = row[12],
        downloaded_at = tonumber(row[13]) or row[13],
        last_seen_in_shelf_at = tonumber(row[14]) or row[14],
        downloaded_by_grimmlink = (tonumber(row[15]) or 0) == 1 and 1 or 0,
        created_at = tonumber(row[16]) or row[16],
        updated_at = tonumber(row[17]) or row[17],
    }
end

local SHELF_SYNC_SELECT = [[
    SELECT id, book_id, shelf_id, shelf_type, remote_filename, remote_title, remote_author,
           remote_format, remote_file_size_kb, remote_series_name, remote_series_number,
           local_path, downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink,
           created_at, updated_at
    FROM shelf_sync_map
]]

function Database:getShelfMapping(book_id, shelf_id, shelf_type)
    if not book_id then
        return nil
    end
    local normalized_type = normalizeShelfType(shelf_type)
    local stmt = self.conn and self.conn:prepare(SHELF_SYNC_SELECT .. " WHERE book_id = ? AND shelf_id = ? AND shelf_type = ? LIMIT 1")
    if not stmt then
        return nil
    end
    stmt:bind(book_id, shelf_id, normalized_type)
    return firstRow(stmt, mapShelfEntry)
end

function Database:getShelfSyncEntry(book_id, shelf_id, shelf_type)
    if shelf_id ~= nil then
        return self:getShelfMapping(book_id, shelf_id, shelf_type)
    end

    local stmt = self.conn and self.conn:prepare(SHELF_SYNC_SELECT .. " WHERE book_id = ? ORDER BY updated_at DESC LIMIT 1")
    if not stmt then
        return nil
    end
    stmt:bind(book_id)
    return firstRow(stmt, mapShelfEntry)
end

function Database:getShelfSyncEntryByLocalPath(local_path)
    local stmt = self.conn and self.conn:prepare(SHELF_SYNC_SELECT .. " WHERE local_path = ? ORDER BY updated_at DESC LIMIT 1")
    if not stmt then
        return nil
    end
    stmt:bind(local_path)
    return firstRow(stmt, mapShelfEntry)
end

function Database:getShelfMappingsForBook(book_id)
    local stmt = self.conn and self.conn:prepare(SHELF_SYNC_SELECT .. " WHERE book_id = ? ORDER BY updated_at DESC")
    if not stmt then
        return {}
    end
    stmt:bind(book_id)
    return allRows(stmt, mapShelfEntry)
end

function Database:isBookTrackedInOtherShelf(book_id, current_shelf_id, current_shelf_type)
    local normalized_type = normalizeShelfType(current_shelf_type)
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT COUNT(*)
            FROM shelf_sync_map
            WHERE book_id = ?
              AND NOT (shelf_id = ? AND shelf_type = ?)
        ]]
    )
    if not stmt then
        return false
    end
    stmt:bind(book_id, current_shelf_id, normalized_type)
    local count = firstRow(stmt, function(row) return tonumber(row[1]) or 0 end) or 0
    return count > 0
end

function Database:isBookTrackedByRegularShelf(book_id)
    if not book_id then
        return false
    end
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT COUNT(*)
            FROM shelf_sync_map
            WHERE book_id = ?
              AND shelf_type = 'regular'
        ]]
    )
    if not stmt then
        return false
    end
    stmt:bind(book_id)
    local count = firstRow(stmt, function(row) return tonumber(row[1]) or 0 end) or 0
    return count > 0
end

function Database:isBookTrackedOnlyByMagicShelf(book_id)
    if not book_id then
        return false
    end
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT
                SUM(CASE WHEN shelf_type = 'magic' THEN 1 ELSE 0 END) AS magic_count,
                SUM(CASE WHEN shelf_type = 'regular' THEN 1 ELSE 0 END) AS regular_count
            FROM shelf_sync_map
            WHERE book_id = ?
        ]]
    )
    if not stmt then
        return false
    end
    stmt:bind(book_id)
    local counts = firstRow(stmt, function(row)
        return {
            magic_count = tonumber(row[1]) or 0,
            regular_count = tonumber(row[2]) or 0,
        }
    end) or { magic_count = 0, regular_count = 0 }
    return counts.magic_count > 0 and counts.regular_count == 0
end

function Database:getMagicOnlyShelfMappings()
    local stmt = self.conn and self.conn:prepare(
        SHELF_SYNC_SELECT .. [[
            WHERE shelf_type = 'magic'
              AND book_id NOT IN (
                SELECT DISTINCT book_id
                FROM shelf_sync_map
                WHERE shelf_type = 'regular'
              )
            ORDER BY updated_at DESC
        ]]
    )
    if not stmt then
        return {}
    end
    return allRows(stmt, mapShelfEntry)
end

function Database:updateShelfMappingLocalPath(book_id, shelf_id, shelf_type, local_path)
    if not book_id or shelf_id == nil then
        return false
    end
    local stmt = self.conn and self.conn:prepare(
        [[
            UPDATE shelf_sync_map
            SET local_path = ?, updated_at = ?
            WHERE book_id = ? AND shelf_id = ? AND shelf_type = ?
        ]]
    )
    if not stmt then
        return false
    end
    stmt:bind(local_path, nowEpoch(), book_id, shelf_id, normalizeShelfType(shelf_type))
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:upsertShelfSyncEntry(entry)
    local sql = [[
        INSERT INTO shelf_sync_map (
            book_id, shelf_id, shelf_type, remote_filename, remote_title, remote_author,
            remote_format, remote_file_size_kb, remote_series_name, remote_series_number,
            local_path, downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, shelf_id, shelf_type) DO UPDATE SET
            remote_filename = excluded.remote_filename,
            remote_title = excluded.remote_title,
            remote_author = excluded.remote_author,
            remote_format = excluded.remote_format,
            remote_file_size_kb = excluded.remote_file_size_kb,
            remote_series_name = excluded.remote_series_name,
            remote_series_number = excluded.remote_series_number,
            local_path = excluded.local_path,
            downloaded_at = excluded.downloaded_at,
            last_seen_in_shelf_at = excluded.last_seen_in_shelf_at,
            downloaded_by_grimmlink = excluded.downloaded_by_grimmlink,
            updated_at = excluded.updated_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        return false
    end
    local normalized_type = normalizeShelfType(entry.shelf_type)
    stmt:bind(
        entry.book_id,
        entry.shelf_id,
        normalized_type,
        entry.remote_filename,
        entry.remote_title,
        entry.remote_author,
        entry.remote_format,
        entry.remote_file_size_kb,
        entry.remote_series_name,
        entry.remote_series_number,
        entry.local_path,
        entry.downloaded_at or nowEpoch(),
        entry.last_seen_in_shelf_at or nowEpoch(),
        entry.downloaded_by_grimmlink == false and 0 or 1,
        nowEpoch()
    )
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:upsertShelfSyncMap(book, shelf_id, shelf_type, local_path)
    if type(book) ~= "table" then
        return false
    end
    return self:upsertShelfSyncEntry({
        book_id = tonumber(book.bookId or book.book_id),
        shelf_id = shelf_id,
        shelf_type = shelf_type,
        remote_filename = book.fileName or book.remote_filename,
        remote_title = book.title or book.remote_title,
        remote_author = book.author or book.remote_author,
        remote_format = book.fileFormat or book.remote_format,
        remote_file_size_kb = book.fileSizeKb or book.remote_file_size_kb,
        remote_series_name = book.seriesName or book.remote_series_name,
        remote_series_number = book.seriesNumber or book.remote_series_number,
        local_path = local_path,
        downloaded_at = book.downloaded_at,
        last_seen_in_shelf_at = book.last_seen_in_shelf_at,
        downloaded_by_grimmlink = book.downloaded_by_grimmlink,
    })
end

function Database:getShelfMappingsByShelf(shelf_id, shelf_type)
    local normalized_type = normalizeShelfType(shelf_type)
    local stmt = self.conn and self.conn:prepare(SHELF_SYNC_SELECT .. " WHERE shelf_id = ? AND shelf_type = ? ORDER BY updated_at DESC")
    if not stmt then
        return {}
    end
    stmt:bind(shelf_id, normalized_type)
    return allRows(stmt, mapShelfEntry)
end

function Database:getAllShelfSyncEntries(shelf_id, shelf_type)
    if shelf_id == nil then
        local stmt = self.conn and self.conn:prepare(SHELF_SYNC_SELECT .. " ORDER BY updated_at DESC")
        if not stmt then
            return {}
        end
        return allRows(stmt, mapShelfEntry)
    end
    return self:getShelfMappingsByShelf(shelf_id, shelf_type)
end

function Database:removeShelfMappingOnly(book_id, shelf_id, shelf_type)
    if shelf_id == nil then
        return self:deleteShelfSyncEntry(book_id)
    end
    local normalized_type = normalizeShelfType(shelf_type)
    local stmt = self.conn and self.conn:prepare("DELETE FROM shelf_sync_map WHERE book_id = ? AND shelf_id = ? AND shelf_type = ?")
    if not stmt then
        return false
    end
    stmt:bind(book_id, shelf_id, normalized_type)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:deleteShelfSyncEntry(book_id, shelf_id, shelf_type)
    if shelf_id ~= nil then
        return self:removeShelfMappingOnly(book_id, shelf_id, shelf_type)
    end

    local stmt = self.conn and self.conn:prepare("DELETE FROM shelf_sync_map WHERE book_id = ?")
    if not stmt then
        return false
    end
    stmt:bind(book_id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

local function mapPendingShelfRemoval(row)
    return {
        id = tonumber(row[1]) or row[1],
        book_id = tonumber(row[2]) or row[2],
        shelf_id = tonumber(row[3]) or row[3],
        shelf_type = normalizeShelfType(row[4]),
        local_path = row[5],
        delete_sdr = (tonumber(row[6]) or 0) == 1,
        retry_count = tonumber(row[7]) or row[7],
        last_retry_at = tonumber(row[8]) or row[8],
        created_at = tonumber(row[9]) or row[9],
        updated_at = tonumber(row[10]) or row[10],
    }
end

function Database:getPendingShelfRemovals(shelf_id, shelf_type)
    local normalized_type = normalizeShelfType(shelf_type)
    local stmt = self.conn and self.conn:prepare(
        "SELECT id, book_id, shelf_id, shelf_type, local_path, delete_sdr, retry_count, last_retry_at, created_at, updated_at FROM pending_shelf_removals WHERE shelf_id = ? AND shelf_type = ? ORDER BY created_at ASC"
    )
    if not stmt then
        return {}
    end
    stmt:bind(shelf_id, normalized_type)
    return allRows(stmt, mapPendingShelfRemoval)
end

function Database:getPendingShelfRemovalCount()
    local stmt = self.conn and self.conn:prepare("SELECT COUNT(*) FROM pending_shelf_removals")
    if not stmt then
        return 0
    end
    local value = firstRow(stmt, function(row)
        return tonumber(row[1]) or 0
    end)
    return value or 0
end

function Database:clearPendingShelfRemovals()
    return self:_exec("DELETE FROM pending_shelf_removals")
end

function Database:upsertPendingShelfRemoval(entry)
    local sql = [[
        INSERT INTO pending_shelf_removals (book_id, shelf_id, shelf_type, local_path, delete_sdr, retry_count, last_retry_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 0, NULL, ?, ?)
        ON CONFLICT(book_id, shelf_id, shelf_type) DO UPDATE SET
            local_path = excluded.local_path,
            delete_sdr = excluded.delete_sdr,
            retry_count = 0,
            last_retry_at = NULL,
            updated_at = excluded.updated_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        return false
    end
    local ts = nowEpoch()
    stmt:bind(
        entry.book_id,
        entry.shelf_id,
        normalizeShelfType(entry.shelf_type),
        entry.local_path,
        entry.delete_sdr == true and 1 or 0,
        ts,
        ts
    )
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:queueShelfRemoval(book_id, shelf_id, shelf_type, local_path, delete_sdr)
    return self:upsertPendingShelfRemoval({
        book_id = book_id,
        shelf_id = shelf_id,
        shelf_type = shelf_type,
        local_path = local_path,
        delete_sdr = delete_sdr,
    })
end

function Database:deletePendingShelfRemoval(book_id, shelf_id, shelf_type)
    local stmt
    if shelf_id ~= nil then
        stmt = self.conn and self.conn:prepare(
            "DELETE FROM pending_shelf_removals WHERE book_id = ? AND shelf_id = ? AND shelf_type = ?"
        )
    else
        stmt = self.conn and self.conn:prepare("DELETE FROM pending_shelf_removals WHERE book_id = ?")
    end
    if not stmt then
        return false
    end
    if shelf_id ~= nil then
        stmt:bind(book_id, shelf_id, normalizeShelfType(shelf_type))
    else
        stmt:bind(book_id)
    end
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:incrementPendingShelfRemovalRetryCount(book_id, shelf_id, shelf_type)
    local stmt
    if shelf_id ~= nil then
        stmt = self.conn and self.conn:prepare(
            "UPDATE pending_shelf_removals SET retry_count = retry_count + 1, last_retry_at = ?, updated_at = ? WHERE book_id = ? AND shelf_id = ? AND shelf_type = ?"
        )
    else
        stmt = self.conn and self.conn:prepare(
            "UPDATE pending_shelf_removals SET retry_count = retry_count + 1, last_retry_at = ?, updated_at = ? WHERE book_id = ?"
        )
    end
    if not stmt then
        return false
    end
    local ts = nowEpoch()
    if shelf_id ~= nil then
        stmt:bind(ts, ts, book_id, shelf_id, normalizeShelfType(shelf_type))
    else
        stmt:bind(ts, ts, book_id)
    end
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:addShelfSyncTombstone(entry)
    local sql = [[
        INSERT INTO shelf_sync_tombstones (book_id, shelf_id, shelf_type, local_path, remote_title, remote_series_name, removed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, shelf_id, shelf_type) DO UPDATE SET
            local_path = excluded.local_path,
            remote_title = excluded.remote_title,
            remote_series_name = excluded.remote_series_name,
            removed_at = excluded.removed_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then return false end
    stmt:bind(
        entry.book_id,
        entry.shelf_id,
        normalizeShelfType(entry.shelf_type),
        entry.local_path,
        entry.remote_title,
        entry.remote_series_name,
        nowEpoch()
    )
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:recordShelfTombstone(book_id, shelf_id, shelf_type, local_path, remote_title, remote_series_name)
    return self:addShelfSyncTombstone({
        book_id = book_id,
        shelf_id = shelf_id,
        shelf_type = shelf_type,
        local_path = local_path,
        remote_title = remote_title,
        remote_series_name = remote_series_name,
    })
end

function Database:isTombstoned(book_id, shelf_id, shelf_type)
    local stmt = self.conn and self.conn:prepare(
        "SELECT 1 FROM shelf_sync_tombstones WHERE book_id = ? AND shelf_id = ? AND shelf_type = ?"
    )
    if not stmt then return false end
    stmt:bind(book_id, shelf_id, normalizeShelfType(shelf_type))
    local row = firstRow(stmt, rowOrNil)
    return row ~= nil
end

function Database:getShelfTombstoneCount()
    local stmt = self.conn and self.conn:prepare("SELECT COUNT(*) FROM shelf_sync_tombstones")
    if not stmt then
        return 0
    end
    local value = firstRow(stmt, function(row)
        return tonumber(row[1]) or 0
    end)
    return value or 0
end

function Database:clearShelfTombstones()
    return self:_exec("DELETE FROM shelf_sync_tombstones")
end

function Database:getShelfSyncStats()
    local stmt = self.conn and self.conn:prepare(
        "SELECT COUNT(*), SUM(CASE WHEN downloaded_by_grimmlink = 1 THEN 1 ELSE 0 END) FROM shelf_sync_map"
    )
    if not stmt then
        return { total = 0, downloaded_by_grimmlink = 0 }
    end
    return firstRow(stmt, function(row)
        return {
            total = tonumber(row[1]) or 0,
            downloaded_by_grimmlink = tonumber(row[2]) or 0,
        }
    end) or { total = 0, downloaded_by_grimmlink = 0 }
end

function Database:addPendingSession(session_data)
    local sql = [[
        INSERT INTO pending_sessions (
            book_id, book_hash, book_type, device, device_id, start_time, end_time,
            duration_seconds, duration_formatted, start_progress, end_progress,
            progress_delta, start_location, end_location, current_page, total_pages,
            retry_count, last_retry_at, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?)
        ON CONFLICT(book_hash, start_time, end_time, device_id) DO UPDATE SET
            book_id = excluded.book_id,
            book_type = excluded.book_type,
            device = excluded.device,
            duration_seconds = excluded.duration_seconds,
            duration_formatted = excluded.duration_formatted,
            start_progress = excluded.start_progress,
            end_progress = excluded.end_progress,
            progress_delta = excluded.progress_delta,
            start_location = excluded.start_location,
            end_location = excluded.end_location,
            current_page = excluded.current_page,
            total_pages = excluded.total_pages,
            retry_count = 0,
            last_retry_at = NULL
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then
        return false
    end
    stmt:bind(
        session_data.bookId,
        session_data.bookHash,
        session_data.bookType or "EPUB",
        session_data.device,
        session_data.deviceId or session_data.device_id or "",
        session_data.startTime,
        session_data.endTime,
        session_data.durationSeconds,
        session_data.durationFormatted,
        session_data.startProgress,
        session_data.endProgress,
        session_data.progressDelta,
        session_data.startLocation,
        session_data.endLocation,
        session_data.currentPage,
        session_data.totalPages,
        nowEpoch()
    )
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:getPendingSessions(limit)
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT id, book_id, book_hash, book_type, device, device_id, start_time, end_time,
                   duration_seconds, duration_formatted, start_progress, end_progress,
                   progress_delta, start_location, end_location, current_page, total_pages,
                   retry_count, last_retry_at, created_at
            FROM pending_sessions
            ORDER BY created_at ASC
            LIMIT ?
        ]]
    )
    if not stmt then
        return {}
    end
    stmt:bind(limit or 100)
    return allRows(stmt, function(row)
        return {
            id = tonumber(row[1]) or row[1],
            bookId = tonumber(row[2]) or row[2],
            bookHash = row[3],
            bookType = row[4],
            device = row[5],
            deviceId = row[6],
            startTime = row[7],
            endTime = row[8],
            durationSeconds = tonumber(row[9]) or row[9],
            durationFormatted = row[10],
            startProgress = row[11],
            endProgress = row[12],
            progressDelta = row[13],
            startLocation = row[14],
            endLocation = row[15],
            currentPage = tonumber(row[16]) or row[16],
            totalPages = tonumber(row[17]) or row[17],
            retry_count = tonumber(row[18]) or row[18],
            last_retry_at = tonumber(row[19]) or row[19],
            created_at = tonumber(row[20]) or row[20],
        }
    end)
end

function Database:getPendingSessionCount()
    local stmt = self.conn and self.conn:prepare("SELECT COUNT(*) FROM pending_sessions")
    if not stmt then
        return 0
    end
    local value = firstRow(stmt, function(row)
        return tonumber(row[1]) or 0
    end)
    return value or 0
end

function Database:deletePendingSession(id)
    local stmt = self.conn and self.conn:prepare("DELETE FROM pending_sessions WHERE id = ?")
    if not stmt then
        return false
    end
    stmt:bind(id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:deleteAllPendingSessions()
    return self:_exec("DELETE FROM pending_sessions")
end

function Database:incrementSessionRetryCount(id)
    local stmt = self.conn and self.conn:prepare(
        "UPDATE pending_sessions SET retry_count = retry_count + 1, last_retry_at = ? WHERE id = ?"
    )
    if not stmt then
        return false
    end
    stmt:bind(nowEpoch(), id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:updatePendingSessionBookId(id, book_id)
    local stmt = self.conn and self.conn:prepare("UPDATE pending_sessions SET book_id = ? WHERE id = ?")
    if not stmt then
        return false
    end
    stmt:bind(book_id, id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

return Database
