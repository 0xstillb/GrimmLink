local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local json = require("json")
local logger = require("logger")

local Database = {
    VERSION = 1,
    conn = nil,
    db_path = nil,
}

Database.migrations = {
    [1] = {
        [[
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        ]],
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
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_hash TEXT NOT NULL UNIQUE,
                file_path TEXT,
                book_id INTEGER,
                document TEXT,
                file_format TEXT,
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
                remote_timestamp INTEGER,
                last_action TEXT,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_progress_state_book_id ON progress_state(book_id)
        ]],
        [[
            CREATE TABLE IF NOT EXISTS pending_progress (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_hash TEXT NOT NULL UNIQUE,
                payload_json TEXT NOT NULL,
                retry_count INTEGER DEFAULT 0,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                last_retry_at INTEGER
            )
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
                start_progress REAL DEFAULT 0.0,
                end_progress REAL DEFAULT 0.0,
                progress_delta REAL DEFAULT 0.0,
                start_location TEXT,
                end_location TEXT,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                retry_count INTEGER DEFAULT 0,
                last_retry_at INTEGER,
                UNIQUE(book_hash, start_time, end_time, device_id)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_sessions_book_hash ON pending_sessions(book_hash)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_sessions_book_id ON pending_sessions(book_id)
        ]],
    },
}

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
        result = mapper(row)
        break
    end
    stmt:close()
    return result
end

function Database:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Database:init(db_name)
    db_name = db_name or "grimmlink.sqlite"
    self.db_path = DataStorage:getSettingsDir() .. "/" .. db_name
    self.conn = SQ3.open(self.db_path)

    if not self.conn then
        logger.err("GrimmLink Database: failed to open", self.db_path)
        return false
    end

    self.conn:exec("PRAGMA foreign_keys = ON")
    pcall(function()
        self.conn:exec("PRAGMA journal_mode = TRUNCATE")
    end)

    return self:runMigrations()
end

function Database:close()
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

function Database:getCurrentVersion()
    local stmt = self.conn:prepare("SELECT MAX(version) FROM schema_version")
    if not stmt then
        return 0
    end

    local version = 0
    for row in stmt:rows() do
        version = tonumber(row[1]) or 0
        break
    end
    stmt:close()
    return version
end

function Database:runMigrations()
    local current_version = self:getCurrentVersion()
    if current_version >= self.VERSION then
        return true
    end

    for version = current_version + 1, self.VERSION do
        local migration = self.migrations[version]
        if not migration then
            logger.err("GrimmLink Database: missing migration", version)
            return false
        end

        self.conn:exec("BEGIN TRANSACTION")
        local ok = true
        for _, sql in ipairs(migration) do
            if self.conn:exec(sql) ~= SQ3.OK then
                logger.err("GrimmLink Database: migration", version, "failed:", self.conn:errmsg())
                ok = false
                break
            end
        end

        if ok then
            local stmt = self.conn:prepare("INSERT INTO schema_version (version) VALUES (?)")
            if not stmt then
                self.conn:exec("ROLLBACK")
                return false
            end
            stmt:bind(version)
            local result = stmt:step()
            stmt:close()
            if result ~= SQ3.DONE and result ~= SQ3.OK then
                self.conn:exec("ROLLBACK")
                return false
            end
            self.conn:exec("COMMIT")
        else
            self.conn:exec("ROLLBACK")
            return false
        end
    end

    return true
end

function Database:getPluginSetting(key)
    local stmt = self.conn:prepare("SELECT value FROM plugin_settings WHERE key = ?")
    if not stmt then
        return nil
    end
    stmt:bind(tostring(key))

    return firstRow(stmt, function(row)
        return decodeSettingValue(row[1] and tostring(row[1]) or nil)
    end)
end

function Database:savePluginSetting(key, value)
    local stmt = self.conn:prepare([[
        INSERT INTO plugin_settings (key, value, updated_at)
        VALUES (?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = excluded.updated_at
    ]])
    if not stmt then
        return false
    end

    stmt:bind(tostring(key), encodeSettingValue(value))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getBookByFilePath(file_path)
    local stmt = self.conn:prepare([[
        SELECT id, file_path, file_hash, book_id, title, author, last_accessed
        FROM book_cache
        WHERE file_path = ?
    ]])
    if not stmt then
        return nil
    end
    stmt:bind(tostring(file_path))

    return firstRow(stmt, function(row)
        return {
            id = tonumber(row[1]),
            file_path = tostring(row[2]),
            file_hash = tostring(row[3]),
            book_id = row[4] and tonumber(row[4]) or nil,
            title = row[5] and tostring(row[5]) or nil,
            author = row[6] and tostring(row[6]) or nil,
            last_accessed = row[7] and tonumber(row[7]) or nil,
        }
    end)
end

function Database:getBookByHash(file_hash)
    local stmt = self.conn:prepare([[
        SELECT id, file_path, file_hash, book_id, title, author, last_accessed
        FROM book_cache
        WHERE file_hash = ?
        ORDER BY updated_at DESC, id DESC
        LIMIT 1
    ]])
    if not stmt then
        return nil
    end
    stmt:bind(tostring(file_hash))

    return firstRow(stmt, function(row)
        return {
            id = tonumber(row[1]),
            file_path = tostring(row[2]),
            file_hash = tostring(row[3]),
            book_id = row[4] and tonumber(row[4]) or nil,
            title = row[5] and tostring(row[5]) or nil,
            author = row[6] and tostring(row[6]) or nil,
            last_accessed = row[7] and tonumber(row[7]) or nil,
        }
    end)
end

function Database:saveBookCache(file_path, file_hash, book_id, title, author)
    local stmt = self.conn:prepare([[
        INSERT INTO book_cache (
            file_path, file_hash, book_id, title, author, last_accessed, updated_at
        ) VALUES (?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER), CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(file_path) DO UPDATE SET
            file_hash = excluded.file_hash,
            book_id = COALESCE(excluded.book_id, book_cache.book_id),
            title = COALESCE(excluded.title, book_cache.title),
            author = COALESCE(excluded.author, book_cache.author),
            last_accessed = excluded.last_accessed,
            updated_at = excluded.updated_at
    ]])
    if not stmt then
        return false
    end

    local normalized_book_id = book_id and tonumber(book_id) or nil
    stmt:bind(
        tostring(file_path or ""),
        tostring(file_hash or ""),
        normalized_book_id,
        title,
        author
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:updateBookId(file_hash, book_id)
    local stmt = self.conn:prepare([[
        UPDATE book_cache
        SET book_id = ?, updated_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE file_hash = ?
    ]])
    if not stmt then
        return false
    end
    stmt:bind(book_id and tonumber(book_id) or nil, tostring(file_hash))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getBookCacheStats()
    local stmt = self.conn:prepare([[
        SELECT COUNT(*), COUNT(book_id), COUNT(*) - COUNT(book_id)
        FROM book_cache
    ]])
    if not stmt then
        return { total = 0, matched = 0, unmatched = 0 }
    end

    local stats = { total = 0, matched = 0, unmatched = 0 }
    for row in stmt:rows() do
        stats.total = tonumber(row[1]) or 0
        stats.matched = tonumber(row[2]) or 0
        stats.unmatched = tonumber(row[3]) or 0
        break
    end
    stmt:close()
    return stats
end

function Database:getProgressState(file_hash)
    local stmt = self.conn:prepare([[
        SELECT
            file_hash, file_path, book_id, document, file_format,
            local_progress, local_location, local_percentage, local_current_page, local_total_pages, local_timestamp,
            remote_progress, remote_location, remote_percentage, remote_current_page, remote_total_pages,
            remote_device, remote_device_id, remote_timestamp, last_action
        FROM progress_state
        WHERE file_hash = ?
    ]])
    if not stmt then
        return nil
    end
    stmt:bind(tostring(file_hash))

    return firstRow(stmt, function(row)
        return {
            file_hash = tostring(row[1]),
            file_path = row[2] and tostring(row[2]) or nil,
            book_id = row[3] and tonumber(row[3]) or nil,
            document = row[4] and tostring(row[4]) or nil,
            file_format = row[5] and tostring(row[5]) or nil,
            local_progress = row[6] and tostring(row[6]) or nil,
            local_location = row[7] and tostring(row[7]) or nil,
            local_percentage = row[8] and tonumber(row[8]) or nil,
            local_current_page = row[9] and tonumber(row[9]) or nil,
            local_total_pages = row[10] and tonumber(row[10]) or nil,
            local_timestamp = row[11] and tonumber(row[11]) or nil,
            remote_progress = row[12] and tostring(row[12]) or nil,
            remote_location = row[13] and tostring(row[13]) or nil,
            remote_percentage = row[14] and tonumber(row[14]) or nil,
            remote_current_page = row[15] and tonumber(row[15]) or nil,
            remote_total_pages = row[16] and tonumber(row[16]) or nil,
            remote_device = row[17] and tostring(row[17]) or nil,
            remote_device_id = row[18] and tostring(row[18]) or nil,
            remote_timestamp = row[19] and tonumber(row[19]) or nil,
            last_action = row[20] and tostring(row[20]) or nil,
        }
    end)
end

function Database:upsertLocalProgressState(file_hash, state)
    local stmt = self.conn:prepare([[
        INSERT INTO progress_state (
            file_hash, file_path, book_id, document, file_format,
            local_progress, local_location, local_percentage, local_current_page, local_total_pages, local_timestamp,
            last_action, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(file_hash) DO UPDATE SET
            file_path = COALESCE(excluded.file_path, progress_state.file_path),
            book_id = COALESCE(excluded.book_id, progress_state.book_id),
            document = COALESCE(excluded.document, progress_state.document),
            file_format = COALESCE(excluded.file_format, progress_state.file_format),
            local_progress = excluded.local_progress,
            local_location = excluded.local_location,
            local_percentage = excluded.local_percentage,
            local_current_page = excluded.local_current_page,
            local_total_pages = excluded.local_total_pages,
            local_timestamp = excluded.local_timestamp,
            last_action = COALESCE(excluded.last_action, progress_state.last_action),
            updated_at = excluded.updated_at
    ]])
    if not stmt then
        return false
    end

    stmt:bind(
        tostring(file_hash),
        state.file_path,
        state.book_id and tonumber(state.book_id) or nil,
        state.document,
        state.file_format,
        state.progress,
        state.location,
        state.percentage,
        state.current_page,
        state.total_pages,
        state.timestamp,
        state.last_action
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:upsertRemoteProgressState(file_hash, state)
    local stmt = self.conn:prepare([[
        INSERT INTO progress_state (
            file_hash, file_path, book_id, document, file_format,
            remote_progress, remote_location, remote_percentage, remote_current_page, remote_total_pages,
            remote_device, remote_device_id, remote_timestamp, last_action, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(file_hash) DO UPDATE SET
            file_path = COALESCE(excluded.file_path, progress_state.file_path),
            book_id = COALESCE(excluded.book_id, progress_state.book_id),
            document = COALESCE(excluded.document, progress_state.document),
            file_format = COALESCE(excluded.file_format, progress_state.file_format),
            remote_progress = excluded.remote_progress,
            remote_location = excluded.remote_location,
            remote_percentage = excluded.remote_percentage,
            remote_current_page = excluded.remote_current_page,
            remote_total_pages = excluded.remote_total_pages,
            remote_device = excluded.remote_device,
            remote_device_id = excluded.remote_device_id,
            remote_timestamp = excluded.remote_timestamp,
            last_action = COALESCE(excluded.last_action, progress_state.last_action),
            updated_at = excluded.updated_at
    ]])
    if not stmt then
        return false
    end

    stmt:bind(
        tostring(file_hash),
        state.file_path,
        state.book_id and tonumber(state.book_id) or nil,
        state.document,
        state.file_format,
        state.progress,
        state.location,
        state.percentage,
        state.current_page,
        state.total_pages,
        state.device,
        state.device_id or state.deviceId or "",
        state.timestamp,
        state.last_action
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:setProgressLastAction(file_hash, last_action)
    local stmt = self.conn:prepare([[
        UPDATE progress_state
        SET last_action = ?, updated_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE file_hash = ?
    ]])
    if not stmt then
        return false
    end
    stmt:bind(last_action, tostring(file_hash))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:upsertPendingProgress(file_hash, payload_json)
    local stmt = self.conn:prepare([[
        INSERT INTO pending_progress (file_hash, payload_json, retry_count, created_at, last_retry_at)
        VALUES (?, ?, 0, CAST(strftime('%s', 'now') AS INTEGER), NULL)
        ON CONFLICT(file_hash) DO UPDATE SET
            payload_json = excluded.payload_json,
            retry_count = 0,
            last_retry_at = NULL
    ]])
    if not stmt then
        return false
    end

    stmt:bind(tostring(file_hash), tostring(payload_json))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getPendingProgress(limit)
    local stmt = self.conn:prepare([[
        SELECT id, file_hash, payload_json, retry_count
        FROM pending_progress
        ORDER BY created_at ASC
        LIMIT ?
    ]])
    if not stmt then
        return {}
    end
    stmt:bind(limit or 100)

    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = {
            id = tonumber(row[1]),
            file_hash = tostring(row[2]),
            payload_json = tostring(row[3]),
            retry_count = tonumber(row[4]) or 0,
        }
    end
    stmt:close()
    return rows
end

function Database:getPendingProgressCount()
    local stmt = self.conn:prepare("SELECT COUNT(*) FROM pending_progress")
    if not stmt then
        return 0
    end
    local count = 0
    for row in stmt:rows() do
        count = tonumber(row[1]) or 0
        break
    end
    stmt:close()
    return count
end

function Database:deletePendingProgress(id)
    local stmt = self.conn:prepare("DELETE FROM pending_progress WHERE id = ?")
    if not stmt then
        return false
    end
    stmt:bind(id)
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:incrementPendingProgressRetry(id)
    local stmt = self.conn:prepare([[
        UPDATE pending_progress
        SET retry_count = retry_count + 1,
            last_retry_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE id = ?
    ]])
    if not stmt then
        return false
    end
    stmt:bind(id)
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:addPendingSession(session_data)
    local stmt = self.conn:prepare([[
        INSERT OR IGNORE INTO pending_sessions (
            book_id, book_hash, book_type, device, device_id,
            start_time, end_time, duration_seconds, start_progress, end_progress, progress_delta,
            start_location, end_location, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
    ]])
    if not stmt then
        return false
    end

    stmt:bind(
        session_data.bookId and tonumber(session_data.bookId) or nil,
        tostring(session_data.bookHash or ""),
        session_data.bookType or "EPUB",
        session_data.device,
        tostring(session_data.deviceId or session_data.device_id or ""),
        tostring(session_data.startTime or ""),
        tostring(session_data.endTime or ""),
        tonumber(session_data.durationSeconds) or 0,
        tonumber(session_data.startProgress) or 0.0,
        tonumber(session_data.endProgress) or 0.0,
        tonumber(session_data.progressDelta) or 0.0,
        session_data.startLocation or "",
        session_data.endLocation or ""
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getPendingSessions(limit)
    local stmt = self.conn:prepare([[
        SELECT
            id, book_id, book_hash, book_type, device, device_id,
            start_time, end_time, duration_seconds, start_progress, end_progress, progress_delta,
            start_location, end_location, retry_count
        FROM pending_sessions
        ORDER BY created_at ASC
        LIMIT ?
    ]])
    if not stmt then
        return {}
    end
    stmt:bind(limit or 100)

    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = {
            id = tonumber(row[1]),
            bookId = row[2] and tonumber(row[2]) or nil,
            bookHash = tostring(row[3]),
            bookType = row[4] and tostring(row[4]) or "EPUB",
            device = row[5] and tostring(row[5]) or nil,
            deviceId = row[6] and tostring(row[6]) or "",
            startTime = tostring(row[7]),
            endTime = tostring(row[8]),
            durationSeconds = tonumber(row[9]) or 0,
            startProgress = tonumber(row[10]) or 0.0,
            endProgress = tonumber(row[11]) or 0.0,
            progressDelta = tonumber(row[12]) or 0.0,
            startLocation = row[13] and tostring(row[13]) or "",
            endLocation = row[14] and tostring(row[14]) or "",
            retryCount = tonumber(row[15]) or 0,
        }
    end
    stmt:close()
    return rows
end

function Database:getPendingSessionCount()
    local stmt = self.conn:prepare("SELECT COUNT(*) FROM pending_sessions")
    if not stmt then
        return 0
    end
    local count = 0
    for row in stmt:rows() do
        count = tonumber(row[1]) or 0
        break
    end
    stmt:close()
    return count
end

function Database:deletePendingSession(id)
    local stmt = self.conn:prepare("DELETE FROM pending_sessions WHERE id = ?")
    if not stmt then
        return false
    end
    stmt:bind(id)
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:incrementSessionRetryCount(id)
    local stmt = self.conn:prepare([[
        UPDATE pending_sessions
        SET retry_count = retry_count + 1,
            last_retry_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE id = ?
    ]])
    if not stmt then
        return false
    end
    stmt:bind(id)
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:updatePendingSessionBookId(id, book_id)
    local stmt = self.conn:prepare("UPDATE pending_sessions SET book_id = ? WHERE id = ?")
    if not stmt then
        return false
    end
    stmt:bind(book_id and tonumber(book_id) or nil, id)
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

return Database
