local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local json = require("json")
local logger = require("logger")

local Database = {
    VERSION = 7,
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
    [2] = {
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
    },
    [3] = {
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
    },
    [4] = {
        -- Offline queue for annotation/bookmark/rating sync.
        -- kind: 'annotation' | 'bookmark' | 'rating'
        -- payload_json: array (annotations/bookmarks) or { rating = N } (rating)
        -- dedupe_key: same key used by the server for upsert. NULL for ratings.
        [[
            CREATE TABLE IF NOT EXISTS pending_annotations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER NOT NULL,
                kind TEXT NOT NULL,
                dedupe_key TEXT,
                payload_json TEXT NOT NULL,
                retry_count INTEGER DEFAULT 0,
                last_retry_at INTEGER,
                last_error TEXT,
                created_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_annotations_book_id
                ON pending_annotations(book_id)
        ]],
        [[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_annotations_unique_key
                ON pending_annotations(book_id, kind, dedupe_key)
                WHERE dedupe_key IS NOT NULL
        ]],
        -- Per-book per-kind last successful sync timestamp (epoch seconds).
        [[
            CREATE TABLE IF NOT EXISTS annotation_sync_state (
                book_id INTEGER NOT NULL,
                kind TEXT NOT NULL,
                last_synced_at INTEGER,
                last_pulled_at INTEGER,
                PRIMARY KEY (book_id, kind)
            )
        ]],
    },
    [5] = {
        [[
            CREATE TABLE IF NOT EXISTS remote_annotation_merge_state (
                book_id INTEGER NOT NULL,
                kind TEXT NOT NULL,
                remote_key TEXT NOT NULL,
                remote_id INTEGER,
                remote_updated_at INTEGER,
                local_key TEXT,
                status TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                retry_count INTEGER DEFAULT 0,
                last_error TEXT,
                conflict_reason TEXT,
                updated_at INTEGER DEFAULT (strftime('%s', 'now')),
                PRIMARY KEY (book_id, kind, remote_key)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_remote_annotation_merge_state_book_kind
                ON remote_annotation_merge_state(book_id, kind, status)
        ]],
    },
      [6] = {
          [[
              CREATE TABLE IF NOT EXISTS web_bridge_state (
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
                remote_timestamp INTEGER,
                remote_updated_at INTEGER,
                remote_epub_cfi TEXT,
                remote_position_href TEXT,
                remote_content_source_progress_percent REAL,
                remote_source TEXT,
                remote_device TEXT,
                remote_device_id TEXT,
                last_action TEXT,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        ]],
        [[
              CREATE INDEX IF NOT EXISTS idx_web_bridge_state_book_id ON web_bridge_state(book_id)
          ]],
      },
      [7] = {
          [[
              CREATE TABLE IF NOT EXISTS not_found_hashes (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  file_hash TEXT NOT NULL UNIQUE,
                  book_id INTEGER,
                  file_path TEXT,
                  file_format TEXT,
                  source TEXT,
                  reason TEXT,
                  retry_count INTEGER DEFAULT 0,
                  last_seen_at INTEGER,
                  created_at INTEGER DEFAULT (strftime('%s', 'now')),
                  updated_at INTEGER DEFAULT (strftime('%s', 'now'))
              )
          ]],
          [[
              CREATE INDEX IF NOT EXISTS idx_not_found_hashes_book_id ON not_found_hashes(book_id)
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

    if not self:repairSchema() then
        return false
    end

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

function Database:repairSchema()
    if not self.conn then
        return false
    end

    for version = 1, self.VERSION do
        local migration = self.migrations[version]
        if migration then
            for _, sql in ipairs(migration) do
                if self.conn:exec(sql) ~= SQ3.OK then
                    logger.err("GrimmLink Database: schema repair", version, "failed:", self.conn:errmsg())
                    return false
                end
            end
        end
    end

    return true
end

function Database:prepareWithSchemaRepair(sql)
    if not self.conn then
        return nil
    end

    local stmt = self.conn:prepare(sql)
    if stmt then
        return stmt
    end

    if self:repairSchema() then
        stmt = self.conn:prepare(sql)
    end

    return stmt
end

function Database:getPluginSetting(key)
    local stmt = self:prepareWithSchemaRepair("SELECT value FROM plugin_settings WHERE key = ?")
    if not stmt then
        return nil
    end
    stmt:bind(tostring(key))

    return firstRow(stmt, function(row)
        return decodeSettingValue(row[1] and tostring(row[1]) or nil)
    end)
end

function Database:savePluginSetting(key, value)
    local stmt = self:prepareWithSchemaRepair([[
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

function Database:getUnmatchedCacheCount()
    local stmt = self.conn:prepare([[
        SELECT COUNT(*)
        FROM book_cache
        WHERE book_id IS NULL
    ]])
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

function Database:clearUnmatchedCache()
    local count = self:getUnmatchedCacheCount()
    local stmt = self.conn:prepare([[DELETE FROM book_cache WHERE book_id IS NULL]])
    if not stmt then
        return false, 0
    end

    local result = stmt:step()
    stmt:close()
    if result == SQ3.DONE or result == SQ3.OK then
        return true, count
    end
    return false, count
end

function Database:getStaleCacheEntries(limit)
    local rows = {}
    local max_rows = limit or 100

    local function collect(table_name, sql)
        if #rows >= max_rows then
            return
        end

        local stmt = self.conn:prepare(sql)
        if not stmt then
            return
        end

        for row in stmt:rows() do
            local file_path = row[3] and tostring(row[3]) or nil
            if file_path and not fileExists(file_path) then
                rows[#rows + 1] = {
                    table_name = table_name,
                    id = tonumber(row[1]),
                    file_hash = row[2] and tostring(row[2]) or nil,
                    file_path = file_path,
                    book_id = row[4] and tonumber(row[4]) or nil,
                    file_format = row[5] and tostring(row[5]) or nil,
                }
                if #rows >= max_rows then
                    break
                end
            end
        end
        stmt:close()
    end

    collect("book_cache", [[
        SELECT id, file_hash, file_path, book_id, title
        FROM book_cache
        ORDER BY updated_at DESC, id DESC
    ]])
    collect("progress_state", [[
        SELECT id, file_hash, file_path, book_id, file_format
        FROM progress_state
        ORDER BY updated_at DESC, id DESC
    ]])
    collect("web_bridge_state", [[
        SELECT id, file_hash, file_path, book_id, file_format
        FROM web_bridge_state
        ORDER BY updated_at DESC, id DESC
    ]])

    return rows
end

function Database:getStaleCacheCount()
    return #self:getStaleCacheEntries(1000)
end

function Database:clearStaleCache()
    local entries = self:getStaleCacheEntries(1000)
    local deleted = {
        book_cache = 0,
        progress_state = 0,
        web_bridge_state = 0,
    }

    local function deleteRow(sql, value)
        local stmt = self.conn:prepare(sql)
        if not stmt then
            return false
        end
        stmt:bind(value)
        local result = stmt:step()
        stmt:close()
        return result == SQ3.DONE or result == SQ3.OK
    end

    for _, entry in ipairs(entries) do
        if entry.table_name == "book_cache" then
            if deleteRow("DELETE FROM book_cache WHERE id = ?", entry.id) then
                deleted.book_cache = deleted.book_cache + 1
            end
        elseif entry.table_name == "progress_state" then
            if deleteRow("DELETE FROM progress_state WHERE id = ?", entry.id) then
                deleted.progress_state = deleted.progress_state + 1
            end
        elseif entry.table_name == "web_bridge_state" then
            if deleteRow("DELETE FROM web_bridge_state WHERE id = ?", entry.id) then
                deleted.web_bridge_state = deleted.web_bridge_state + 1
            end
        end
    end

    return deleted
end

function Database:deleteAllPendingProgress()
    local stmt = self.conn:prepare("DELETE FROM pending_progress")
    if not stmt then
        return false
    end
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:deletePendingProgressByHash(file_hash)
    local stmt = self.conn:prepare("DELETE FROM pending_progress WHERE file_hash = ?")
    if not stmt then
        return false
    end
    stmt:bind(tostring(file_hash))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:upsertNotFoundHash(entry)
    local stmt = self.conn:prepare([[
        INSERT INTO not_found_hashes (
            file_hash, book_id, file_path, file_format, source, reason, retry_count, last_seen_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 0, CAST(strftime('%s', 'now') AS INTEGER), CAST(strftime('%s', 'now') AS INTEGER), CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(file_hash) DO UPDATE SET
            book_id = COALESCE(excluded.book_id, not_found_hashes.book_id),
            file_path = COALESCE(excluded.file_path, not_found_hashes.file_path),
            file_format = COALESCE(excluded.file_format, not_found_hashes.file_format),
            source = COALESCE(excluded.source, not_found_hashes.source),
            reason = COALESCE(excluded.reason, not_found_hashes.reason),
            retry_count = not_found_hashes.retry_count + 1,
            last_seen_at = excluded.last_seen_at,
            updated_at = excluded.updated_at
    ]])
    if not stmt then
        return false
    end

    stmt:bind(
        tostring(entry.file_hash or ""),
        entry.book_id and tonumber(entry.book_id) or nil,
        entry.file_path,
        entry.file_format,
        entry.source,
        entry.reason
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:hasNotFoundHash(file_hash)
    local stmt = self.conn:prepare("SELECT 1 FROM not_found_hashes WHERE file_hash = ? LIMIT 1")
    if not stmt then
        return false
    end
    stmt:bind(tostring(file_hash))

    local found = false
    for row in stmt:rows() do
        found = row[1] ~= nil
        break
    end
    stmt:close()
    return found
end

function Database:getNotFoundHashCount()
    local stmt = self.conn:prepare("SELECT COUNT(*) FROM not_found_hashes")
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

function Database:getNotFoundHashes(limit)
    local stmt = self.conn:prepare([[
        SELECT id, file_hash, book_id, file_path, file_format, source, reason, retry_count, last_seen_at
        FROM not_found_hashes
        ORDER BY updated_at DESC, id DESC
        LIMIT ?
    ]])
    if not stmt then
        return {}
    end
    stmt:bind(limit or 25)

    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = {
            id = tonumber(row[1]),
            file_hash = tostring(row[2]),
            book_id = row[3] and tonumber(row[3]) or nil,
            file_path = row[4] and tostring(row[4]) or nil,
            file_format = row[5] and tostring(row[5]) or nil,
            source = row[6] and tostring(row[6]) or nil,
            reason = row[7] and tostring(row[7]) or nil,
            retry_count = row[8] and tonumber(row[8]) or 0,
            last_seen_at = row[9] and tonumber(row[9]) or nil,
        }
    end
    stmt:close()
    return rows
end

function Database:clearNotFoundHashes()
    local stmt = self.conn:prepare("DELETE FROM not_found_hashes")
    if not stmt then
        return false
    end
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
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

function Database:getWebBridgeState(file_hash)
    local stmt = self.conn:prepare([[
        SELECT
            file_hash, file_path, book_id, document, file_format,
            local_progress, local_location, local_percentage, local_current_page, local_total_pages, local_timestamp,
            remote_progress, remote_location, remote_percentage, remote_current_page, remote_total_pages,
            remote_timestamp, remote_updated_at, remote_epub_cfi, remote_position_href,
            remote_content_source_progress_percent, remote_source, remote_device, remote_device_id, last_action
        FROM web_bridge_state
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
            remote_timestamp = row[17] and tonumber(row[17]) or nil,
            remote_updated_at = row[18] and tonumber(row[18]) or nil,
            remote_epub_cfi = row[19] and tostring(row[19]) or nil,
            remote_position_href = row[20] and tostring(row[20]) or nil,
            remote_content_source_progress_percent = row[21] and tonumber(row[21]) or nil,
            remote_source = row[22] and tostring(row[22]) or nil,
            remote_device = row[23] and tostring(row[23]) or nil,
            remote_device_id = row[24] and tostring(row[24]) or nil,
            last_action = row[25] and tostring(row[25]) or nil,
        }
    end)
end

function Database:upsertLocalWebBridgeState(file_hash, state)
    local stmt = self.conn:prepare([[
        INSERT INTO web_bridge_state (
            file_hash, file_path, book_id, document, file_format,
            local_progress, local_location, local_percentage, local_current_page, local_total_pages, local_timestamp,
            last_action, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(file_hash) DO UPDATE SET
            file_path = COALESCE(excluded.file_path, web_bridge_state.file_path),
            book_id = COALESCE(excluded.book_id, web_bridge_state.book_id),
            document = COALESCE(excluded.document, web_bridge_state.document),
            file_format = COALESCE(excluded.file_format, web_bridge_state.file_format),
            local_progress = excluded.local_progress,
            local_location = excluded.local_location,
            local_percentage = excluded.local_percentage,
            local_current_page = excluded.local_current_page,
            local_total_pages = excluded.local_total_pages,
            local_timestamp = excluded.local_timestamp,
            last_action = COALESCE(excluded.last_action, web_bridge_state.last_action),
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

function Database:upsertRemoteWebBridgeState(file_hash, state)
    local stmt = self.conn:prepare([[
        INSERT INTO web_bridge_state (
            file_hash, file_path, book_id, document, file_format,
            remote_progress, remote_location, remote_percentage, remote_current_page, remote_total_pages,
            remote_timestamp, remote_updated_at, remote_epub_cfi, remote_position_href,
            remote_content_source_progress_percent, remote_source, remote_device, remote_device_id,
            last_action, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(file_hash) DO UPDATE SET
            file_path = COALESCE(excluded.file_path, web_bridge_state.file_path),
            book_id = COALESCE(excluded.book_id, web_bridge_state.book_id),
            document = COALESCE(excluded.document, web_bridge_state.document),
            file_format = COALESCE(excluded.file_format, web_bridge_state.file_format),
            remote_progress = excluded.remote_progress,
            remote_location = excluded.remote_location,
            remote_percentage = excluded.remote_percentage,
            remote_current_page = excluded.remote_current_page,
            remote_total_pages = excluded.remote_total_pages,
            remote_timestamp = excluded.remote_timestamp,
            remote_updated_at = excluded.remote_updated_at,
            remote_epub_cfi = excluded.remote_epub_cfi,
            remote_position_href = excluded.remote_position_href,
            remote_content_source_progress_percent = excluded.remote_content_source_progress_percent,
            remote_source = excluded.remote_source,
            remote_device = excluded.remote_device,
            remote_device_id = excluded.remote_device_id,
            last_action = COALESCE(excluded.last_action, web_bridge_state.last_action),
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
        state.remote_updated_at and tonumber(state.remote_updated_at) or nil,
        state.remote_epub_cfi,
        state.remote_position_href,
        state.remote_content_source_progress_percent,
        state.remote_source,
        state.device,
        state.device_id or state.deviceId or "",
        state.last_action
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:setWebBridgeLastAction(file_hash, last_action)
    local stmt = self.conn:prepare([[
        UPDATE web_bridge_state
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
            retry_count = CASE
                WHEN pending_progress.payload_json = excluded.payload_json THEN pending_progress.retry_count
                ELSE 0
            END,
            last_retry_at = CASE
                WHEN pending_progress.payload_json = excluded.payload_json THEN pending_progress.last_retry_at
                ELSE NULL
            END
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
        SELECT id, file_hash, payload_json, retry_count, last_retry_at, created_at
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
            last_retry_at = row[5] and tonumber(row[5]) or nil,
            created_at = row[6] and tonumber(row[6]) or nil,
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

function Database:getShelfSyncEntry(book_id)
    local stmt = self.conn:prepare([[
        SELECT id, book_id, shelf_id, remote_filename, remote_title, remote_author,
               remote_format, remote_file_size_kb, local_path,
               downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink
        FROM shelf_sync_map
        WHERE book_id = ?
    ]])
    if not stmt then return nil end
    stmt:bind(tonumber(book_id))

    return firstRow(stmt, function(row)
        return {
            id = tonumber(row[1]),
            book_id = tonumber(row[2]),
            shelf_id = tonumber(row[3]),
            remote_filename = row[4] and tostring(row[4]) or nil,
            remote_title = row[5] and tostring(row[5]) or nil,
            remote_author = row[6] and tostring(row[6]) or nil,
            remote_format = row[7] and tostring(row[7]) or nil,
            remote_file_size_kb = row[8] and tonumber(row[8]) or nil,
            local_path = row[9] and tostring(row[9]) or nil,
            downloaded_at = row[10] and tonumber(row[10]) or nil,
            last_seen_in_shelf_at = row[11] and tonumber(row[11]) or nil,
            downloaded_by_grimmlink = row[12] and tonumber(row[12]) or 1,
        }
    end)
end

function Database:getShelfSyncEntryByLocalPath(local_path)
    local stmt = self.conn:prepare([[
        SELECT id, book_id, shelf_id, remote_filename, remote_title, remote_author,
               remote_format, remote_file_size_kb, local_path,
               downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink
        FROM shelf_sync_map
        WHERE local_path = ?
        ORDER BY id DESC
        LIMIT 1
    ]])
    if not stmt then return nil end
    stmt:bind(tostring(local_path))

    return firstRow(stmt, function(row)
        return {
            id = tonumber(row[1]),
            book_id = tonumber(row[2]),
            shelf_id = tonumber(row[3]),
            remote_filename = row[4] and tostring(row[4]) or nil,
            remote_title = row[5] and tostring(row[5]) or nil,
            remote_author = row[6] and tostring(row[6]) or nil,
            remote_format = row[7] and tostring(row[7]) or nil,
            remote_file_size_kb = row[8] and tonumber(row[8]) or nil,
            local_path = row[9] and tostring(row[9]) or nil,
            downloaded_at = row[10] and tonumber(row[10]) or nil,
            last_seen_in_shelf_at = row[11] and tonumber(row[11]) or nil,
            downloaded_by_grimmlink = row[12] and tonumber(row[12]) or 1,
        }
    end)
end

function Database:upsertShelfSyncEntry(entry)
    local stmt = self.conn:prepare([[
        INSERT INTO shelf_sync_map (
            book_id, shelf_id, remote_filename, remote_title, remote_author,
            remote_format, remote_file_size_kb, local_path,
            downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink,
            updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(book_id) DO UPDATE SET
            shelf_id = excluded.shelf_id,
            remote_filename = COALESCE(excluded.remote_filename, shelf_sync_map.remote_filename),
            remote_title = COALESCE(excluded.remote_title, shelf_sync_map.remote_title),
            remote_author = COALESCE(excluded.remote_author, shelf_sync_map.remote_author),
            remote_format = COALESCE(excluded.remote_format, shelf_sync_map.remote_format),
            remote_file_size_kb = COALESCE(excluded.remote_file_size_kb, shelf_sync_map.remote_file_size_kb),
            local_path = COALESCE(excluded.local_path, shelf_sync_map.local_path),
            downloaded_at = COALESCE(excluded.downloaded_at, shelf_sync_map.downloaded_at),
            last_seen_in_shelf_at = excluded.last_seen_in_shelf_at,
            updated_at = excluded.updated_at
    ]])
    if not stmt then return false end

    stmt:bind(
        tonumber(entry.book_id),
        tonumber(entry.shelf_id),
        entry.remote_filename,
        entry.remote_title,
        entry.remote_author,
        entry.remote_format,
        entry.remote_file_size_kb and tonumber(entry.remote_file_size_kb) or nil,
        entry.local_path,
        entry.downloaded_at and tonumber(entry.downloaded_at) or nil,
        entry.last_seen_in_shelf_at and tonumber(entry.last_seen_in_shelf_at) or nil,
        entry.downloaded_by_grimmlink ~= nil and tonumber(entry.downloaded_by_grimmlink) or 1
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getAllShelfSyncEntries(shelf_id)
    local stmt = self.conn:prepare([[
        SELECT id, book_id, shelf_id, remote_filename, remote_title, remote_author,
               remote_format, remote_file_size_kb, local_path,
               downloaded_at, last_seen_in_shelf_at, downloaded_by_grimmlink
        FROM shelf_sync_map
        WHERE shelf_id = ?
        ORDER BY id ASC
    ]])
    if not stmt then return {} end
    stmt:bind(tonumber(shelf_id))

    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = {
            id = tonumber(row[1]),
            book_id = tonumber(row[2]),
            shelf_id = tonumber(row[3]),
            remote_filename = row[4] and tostring(row[4]) or nil,
            remote_title = row[5] and tostring(row[5]) or nil,
            remote_author = row[6] and tostring(row[6]) or nil,
            remote_format = row[7] and tostring(row[7]) or nil,
            remote_file_size_kb = row[8] and tonumber(row[8]) or nil,
            local_path = row[9] and tostring(row[9]) or nil,
            downloaded_at = row[10] and tonumber(row[10]) or nil,
            last_seen_in_shelf_at = row[11] and tonumber(row[11]) or nil,
            downloaded_by_grimmlink = row[12] and tonumber(row[12]) or 1,
        }
    end
    stmt:close()
    return rows
end

function Database:deleteShelfSyncEntry(book_id)
    local stmt = self.conn:prepare("DELETE FROM shelf_sync_map WHERE book_id = ?")
    if not stmt then return false end
    stmt:bind(tonumber(book_id))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getPendingShelfRemovals(shelf_id)
    local stmt = self.conn:prepare([[
        SELECT id, book_id, shelf_id, local_path, delete_sdr, retry_count, last_retry_at, created_at, updated_at
        FROM pending_shelf_removals
        WHERE shelf_id = ?
        ORDER BY id ASC
    ]])
    if not stmt then return {} end
    stmt:bind(tonumber(shelf_id))

    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = {
            id = tonumber(row[1]),
            book_id = tonumber(row[2]),
            shelf_id = tonumber(row[3]),
            local_path = row[4] and tostring(row[4]) or nil,
            delete_sdr = row[5] and tonumber(row[5]) or 0,
            retry_count = row[6] and tonumber(row[6]) or 0,
            last_retry_at = row[7] and tonumber(row[7]) or nil,
            created_at = row[8] and tonumber(row[8]) or nil,
            updated_at = row[9] and tonumber(row[9]) or nil,
        }
    end
    stmt:close()
    return rows
end

function Database:upsertPendingShelfRemoval(entry)
    local stmt = self.conn:prepare([[
        INSERT INTO pending_shelf_removals (
            book_id, shelf_id, local_path, delete_sdr,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER), CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(book_id) DO UPDATE SET
            shelf_id = excluded.shelf_id,
            local_path = COALESCE(excluded.local_path, pending_shelf_removals.local_path),
            delete_sdr = excluded.delete_sdr,
            updated_at = excluded.updated_at
    ]])
    if not stmt then return false end

    stmt:bind(
        tonumber(entry.book_id),
        tonumber(entry.shelf_id),
        entry.local_path,
        entry.delete_sdr and 1 or 0
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:deletePendingShelfRemoval(book_id)
    local stmt = self.conn:prepare("DELETE FROM pending_shelf_removals WHERE book_id = ?")
    if not stmt then return false end
    stmt:bind(tonumber(book_id))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:incrementPendingShelfRemovalRetryCount(book_id)
    local stmt = self.conn:prepare([[
        UPDATE pending_shelf_removals
        SET retry_count = retry_count + 1,
            last_retry_at = CAST(strftime('%s', 'now') AS INTEGER),
            updated_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE book_id = ?
    ]])
    if not stmt then return false end
    stmt:bind(tonumber(book_id))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getShelfSyncStats()
    local stmt = self.conn:prepare("SELECT COUNT(*) FROM shelf_sync_map")
    if not stmt then return { total = 0 } end
    local count = 0
    for row in stmt:rows() do
        count = tonumber(row[1]) or 0
        break
    end
    stmt:close()
    return { total = count }
end

-- ===== Annotation/Bookmark/Rating offline queue =====

-- Enqueue or refresh a pending annotation/bookmark item.
-- For ratings, dedupe_key may be nil — only one rating row should exist per book.
function Database:enqueueAnnotation(book_id, kind, dedupe_key, payload_json)
    if kind == "rating" then
        -- Replace any prior queued rating for this book
        local del = self.conn:prepare("DELETE FROM pending_annotations WHERE book_id = ? AND kind = 'rating'")
        if del then del:bind(tonumber(book_id)); del:step(); del:close() end

        local ins = self.conn:prepare([[
            INSERT INTO pending_annotations (book_id, kind, dedupe_key, payload_json, retry_count, created_at)
            VALUES (?, 'rating', NULL, ?, 0, CAST(strftime('%s', 'now') AS INTEGER))
        ]])
        if not ins then return false end
        ins:bind(tonumber(book_id), tostring(payload_json))
        local result = ins:step()
        ins:close()
        return result == SQ3.DONE or result == SQ3.OK
    end

    -- annotation/bookmark — UPSERT by (book_id, kind, dedupe_key).
    -- ON CONFLICT(cols) DO UPDATE fails with partial unique indexes in SQLite,
    -- so use INSERT OR REPLACE which works with any constraint type.
    local stmt = self.conn:prepare([[
        INSERT OR REPLACE INTO pending_annotations (book_id, kind, dedupe_key, payload_json, retry_count, created_at)
        VALUES (?, ?, ?, ?, 0, CAST(strftime('%s', 'now') AS INTEGER))
    ]])
    if not stmt then return false end
    stmt:bind(tonumber(book_id), tostring(kind), tostring(dedupe_key or ""), tostring(payload_json))
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

-- Returns rows grouped per (book_id, kind) so caller can batch-upload.
function Database:getPendingAnnotationGroups(limit_per_group)
    local stmt = self.conn:prepare([[
        SELECT id, book_id, kind, dedupe_key, payload_json, retry_count
        FROM pending_annotations
        ORDER BY book_id ASC, kind ASC, created_at ASC
    ]])
    if not stmt then return {} end

    local groups = {}
    local key_index = {}
    for row in stmt:rows() do
        local book_id = tonumber(row[2])
        local kind = tostring(row[3])
        local key = book_id .. ":" .. kind
        local g = key_index[key]
        if not g then
            g = { book_id = book_id, kind = kind, items = {} }
            groups[#groups + 1] = g
            key_index[key] = g
        end
        if not limit_per_group or #g.items < limit_per_group then
            g.items[#g.items + 1] = {
                id = tonumber(row[1]),
                dedupe_key = row[4] and tostring(row[4]) or nil,
                payload_json = tostring(row[5]),
                retry_count = tonumber(row[6]) or 0,
            }
        end
    end
    stmt:close()
    return groups
end

function Database:getPendingAnnotationCount()
    local stmt = self.conn:prepare("SELECT COUNT(*) FROM pending_annotations")
    if not stmt then return 0 end
    local count = 0
    for row in stmt:rows() do
        count = tonumber(row[1]) or 0
        break
    end
    stmt:close()
    return count
end

function Database:deletePendingAnnotations(ids)
    if not ids or #ids == 0 then return true end
    local all_ok = true
    for _, id in ipairs(ids) do
        local stmt = self.conn:prepare("DELETE FROM pending_annotations WHERE id = ?")
        if stmt then
            stmt:bind(tonumber(id))
            local result = stmt:step()
            stmt:close()
            if result ~= SQ3.DONE and result ~= SQ3.OK then
                all_ok = false
            end
        else
            all_ok = false
        end
    end
    return all_ok
end

function Database:incrementPendingAnnotationRetry(ids, error_msg)
    if not ids or #ids == 0 then return true end
    local err = error_msg and tostring(error_msg):sub(1, 250) or nil
    local all_ok = true
    for _, id in ipairs(ids) do
        local stmt = self.conn:prepare([[
            UPDATE pending_annotations
            SET retry_count = retry_count + 1,
                last_retry_at = CAST(strftime('%s', 'now') AS INTEGER),
                last_error = ?
            WHERE id = ?
        ]])
        if stmt then
            stmt:bind(err, tonumber(id))
            local result = stmt:step()
            stmt:close()
            if result ~= SQ3.DONE and result ~= SQ3.OK then
                all_ok = false
            end
        else
            all_ok = false
        end
    end
    return all_ok
end

function Database:setAnnotationSyncState(book_id, kind, last_synced_at, last_pulled_at)
    local stmt = self.conn:prepare([[
        INSERT INTO annotation_sync_state (book_id, kind, last_synced_at, last_pulled_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(book_id, kind) DO UPDATE SET
            last_synced_at = COALESCE(excluded.last_synced_at, annotation_sync_state.last_synced_at),
            last_pulled_at = COALESCE(excluded.last_pulled_at, annotation_sync_state.last_pulled_at)
    ]])
    if not stmt then return false end
    stmt:bind(tonumber(book_id), tostring(kind),
        last_synced_at and tonumber(last_synced_at) or nil,
        last_pulled_at and tonumber(last_pulled_at) or nil)
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getAnnotationSyncState(book_id, kind)
    local stmt = self.conn:prepare([[
        SELECT last_synced_at, last_pulled_at
        FROM annotation_sync_state
        WHERE book_id = ? AND kind = ?
    ]])
    if not stmt then return nil end
    stmt:bind(tonumber(book_id), tostring(kind))

    return firstRow(stmt, function(row)
        return {
            last_synced_at = row[1] and tonumber(row[1]) or nil,
            last_pulled_at = row[2] and tonumber(row[2]) or nil,
        }
    end)
end

function Database:saveRemoteAnnotationMergeState(entry)
    if not entry or not entry.book_id or not entry.kind or not entry.remote_key then
        return false
    end

    local stmt = self.conn:prepare([[
        INSERT INTO remote_annotation_merge_state (
            book_id, kind, remote_key, remote_id, remote_updated_at, local_key,
            status, payload_json, retry_count, last_error, conflict_reason, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(book_id, kind, remote_key) DO UPDATE SET
            remote_id = excluded.remote_id,
            remote_updated_at = excluded.remote_updated_at,
            local_key = COALESCE(excluded.local_key, remote_annotation_merge_state.local_key),
            status = excluded.status,
            payload_json = excluded.payload_json,
            retry_count = excluded.retry_count,
            last_error = excluded.last_error,
            conflict_reason = excluded.conflict_reason,
            updated_at = excluded.updated_at
    ]])
    if not stmt then return false end

    stmt:bind(
        tonumber(entry.book_id),
        tostring(entry.kind),
        tostring(entry.remote_key),
        entry.remote_id and tonumber(entry.remote_id) or nil,
        entry.remote_updated_at and tonumber(entry.remote_updated_at) or nil,
        entry.local_key and tostring(entry.local_key) or nil,
        tostring(entry.status or "pending"),
        tostring(entry.payload_json or "{}"),
        tonumber(entry.retry_count or 0),
        entry.last_error and tostring(entry.last_error):sub(1, 250) or nil,
        entry.conflict_reason and tostring(entry.conflict_reason):sub(1, 250) or nil
    )
    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getRemoteAnnotationMergeState(book_id, kind, remote_key)
    local stmt = self.conn:prepare([[
        SELECT remote_id, remote_updated_at, local_key, status, payload_json, retry_count, last_error, conflict_reason, updated_at
        FROM remote_annotation_merge_state
        WHERE book_id = ? AND kind = ? AND remote_key = ?
    ]])
    if not stmt then return nil end
    stmt:bind(tonumber(book_id), tostring(kind), tostring(remote_key))

    return firstRow(stmt, function(row)
        return {
            remote_id = row[1] and tonumber(row[1]) or nil,
            remote_updated_at = row[2] and tonumber(row[2]) or nil,
            local_key = row[3] and tostring(row[3]) or nil,
            status = row[4] and tostring(row[4]) or nil,
            payload_json = row[5] and tostring(row[5]) or nil,
            retry_count = row[6] and tonumber(row[6]) or 0,
            last_error = row[7] and tostring(row[7]) or nil,
            conflict_reason = row[8] and tostring(row[8]) or nil,
            updated_at = row[9] and tonumber(row[9]) or nil,
        }
    end)
end

function Database:getPendingRemoteAnnotationMergeStates(book_id, kind)
    local stmt = self.conn:prepare([[
        SELECT remote_key, remote_id, remote_updated_at, local_key, status, payload_json, retry_count, last_error, conflict_reason
        FROM remote_annotation_merge_state
        WHERE book_id = ? AND kind = ? AND status = 'pending'
        ORDER BY updated_at ASC
    ]])
    if not stmt then return {} end
    stmt:bind(tonumber(book_id), tostring(kind))

    local items = {}
    for row in stmt:rows() do
        items[#items + 1] = {
            remote_key = tostring(row[1]),
            remote_id = row[2] and tonumber(row[2]) or nil,
            remote_updated_at = row[3] and tonumber(row[3]) or nil,
            local_key = row[4] and tostring(row[4]) or nil,
            status = row[5] and tostring(row[5]) or "pending",
            payload_json = row[6] and tostring(row[6]) or "{}",
            retry_count = row[7] and tonumber(row[7]) or 0,
            last_error = row[8] and tostring(row[8]) or nil,
            conflict_reason = row[9] and tostring(row[9]) or nil,
        }
    end
    stmt:close()
    return items
end

return Database
