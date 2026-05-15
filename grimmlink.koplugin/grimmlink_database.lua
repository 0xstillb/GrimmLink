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
        CREATE INDEX IF NOT EXISTS idx_pending_sessions_book_hash ON pending_sessions(book_hash)
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_sessions_book_id ON pending_sessions(book_id)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS shelf_sync_map (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL UNIQUE,
            shelf_id INTEGER NOT NULL,
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
            updated_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_shelf_sync_map_shelf_id ON shelf_sync_map(shelf_id)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS pending_shelf_removals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL UNIQUE,
            shelf_id INTEGER NOT NULL,
            local_path TEXT,
            delete_sdr INTEGER DEFAULT 0,
            retry_count INTEGER DEFAULT 0,
            last_retry_at INTEGER,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            updated_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    ]],
    [[
        CREATE INDEX IF NOT EXISTS idx_pending_shelf_removals_shelf_id ON pending_shelf_removals(shelf_id)
    ]],
    [[
        CREATE TABLE IF NOT EXISTS shelf_sync_tombstones (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL,
            shelf_id INTEGER NOT NULL,
            local_path TEXT,
            remote_title TEXT,
            remote_series_name TEXT,
            removed_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(book_id, shelf_id)
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

    self:_migrateShelfSyncSeriesColumns()
    return true
end

function Database:_migrateShelfSyncSeriesColumns()
    local stmt = self.conn and self.conn:prepare("SELECT remote_series_name FROM shelf_sync_map LIMIT 0")
    if stmt then
        stmt:close()
        return
    end
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
        remote_filename = row[4],
        remote_title = row[5],
        remote_author = row[6],
        remote_format = row[7],
        remote_file_size_kb = tonumber(row[8]) or row[8],
        remote_series_name = row[9],
        remote_series_number = tonumber(row[10]),
        local_path = row[11],
        downloaded_at = tonumber(row[12]) or row[12],
        last_seen_in_shelf_at = tonumber(row[13]) or row[13],
        downloaded_by_grimmlink = (tonumber(row[14]) or 0) == 1 and 1 or 0,
        created_at = tonumber(row[15]) or row[15],
        updated_at = tonumber(row[16]) or row[16],
    }
end

function Database:getShelfSyncEntry(book_id)
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT id, book_id, shelf_id, remote_filename, remote_title, remote_author,
                   remote_format, remote_file_size_kb, remote_series_name, remote_series_number,
                   local_path, downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink,
                   created_at, updated_at
            FROM shelf_sync_map
            WHERE book_id = ?
        ]]
    )
    if not stmt then
        return nil
    end
    stmt:bind(book_id)
    return firstRow(stmt, mapShelfEntry)
end

function Database:getShelfSyncEntryByLocalPath(local_path)
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT id, book_id, shelf_id, remote_filename, remote_title, remote_author,
                   remote_format, remote_file_size_kb, remote_series_name, remote_series_number,
                   local_path, downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink,
                   created_at, updated_at
            FROM shelf_sync_map
            WHERE local_path = ?
        ]]
    )
    if not stmt then
        return nil
    end
    stmt:bind(local_path)
    return firstRow(stmt, mapShelfEntry)
end

function Database:upsertShelfSyncEntry(entry)
    local sql = [[
        INSERT INTO shelf_sync_map (
            book_id, shelf_id, remote_filename, remote_title, remote_author,
            remote_format, remote_file_size_kb, remote_series_name, remote_series_number,
            local_path, downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id) DO UPDATE SET
            shelf_id = excluded.shelf_id,
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
    stmt:bind(
        entry.book_id,
        entry.shelf_id,
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

function Database:getAllShelfSyncEntries(shelf_id)
    local stmt = self.conn and self.conn:prepare(
        [[
            SELECT id, book_id, shelf_id, remote_filename, remote_title, remote_author,
                   remote_format, remote_file_size_kb, remote_series_name, remote_series_number,
                   local_path, downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink,
                   created_at, updated_at
            FROM shelf_sync_map
            WHERE shelf_id = ?
            ORDER BY updated_at DESC
        ]]
    )
    if not stmt then
        return {}
    end
    stmt:bind(shelf_id)
    return allRows(stmt, mapShelfEntry)
end

function Database:deleteShelfSyncEntry(book_id)
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
        local_path = row[4],
        delete_sdr = (tonumber(row[5]) or 0) == 1,
        retry_count = tonumber(row[6]) or row[6],
        last_retry_at = tonumber(row[7]) or row[7],
        created_at = tonumber(row[8]) or row[8],
        updated_at = tonumber(row[9]) or row[9],
    }
end

function Database:getPendingShelfRemovals(shelf_id)
    local stmt = self.conn and self.conn:prepare(
        "SELECT id, book_id, shelf_id, local_path, delete_sdr, retry_count, last_retry_at, created_at, updated_at FROM pending_shelf_removals WHERE shelf_id = ? ORDER BY created_at ASC"
    )
    if not stmt then
        return {}
    end
    stmt:bind(shelf_id)
    return allRows(stmt, mapPendingShelfRemoval)
end

function Database:upsertPendingShelfRemoval(entry)
    local sql = [[
        INSERT INTO pending_shelf_removals (book_id, shelf_id, local_path, delete_sdr, retry_count, last_retry_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, 0, NULL, ?, ?)
        ON CONFLICT(book_id) DO UPDATE SET
            shelf_id = excluded.shelf_id,
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
    stmt:bind(entry.book_id, entry.shelf_id, entry.local_path, entry.delete_sdr == true and 1 or 0, ts, ts)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:deletePendingShelfRemoval(book_id)
    local stmt = self.conn and self.conn:prepare("DELETE FROM pending_shelf_removals WHERE book_id = ?")
    if not stmt then
        return false
    end
    stmt:bind(book_id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:incrementPendingShelfRemovalRetryCount(book_id)
    local stmt = self.conn and self.conn:prepare(
        "UPDATE pending_shelf_removals SET retry_count = retry_count + 1, last_retry_at = ?, updated_at = ? WHERE book_id = ?"
    )
    if not stmt then
        return false
    end
    local ts = nowEpoch()
    stmt:bind(ts, ts, book_id)
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:addShelfSyncTombstone(entry)
    local sql = [[
        INSERT INTO shelf_sync_tombstones (book_id, shelf_id, local_path, remote_title, remote_series_name, removed_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, shelf_id) DO UPDATE SET
            local_path = excluded.local_path,
            remote_title = excluded.remote_title,
            remote_series_name = excluded.remote_series_name,
            removed_at = excluded.removed_at
    ]]
    local stmt = self.conn and self.conn:prepare(sql)
    if not stmt then return false end
    stmt:bind(entry.book_id, entry.shelf_id, entry.local_path, entry.remote_title, entry.remote_series_name, nowEpoch())
    local ok = stmt:step() == SQ3.DONE
    stmt:close()
    return ok
end

function Database:isTombstoned(book_id, shelf_id)
    local stmt = self.conn and self.conn:prepare(
        "SELECT 1 FROM shelf_sync_tombstones WHERE book_id = ? AND shelf_id = ?"
    )
    if not stmt then return false end
    stmt:bind(book_id, shelf_id)
    local row = firstRow(stmt, rowOrNil)
    return row ~= nil
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
