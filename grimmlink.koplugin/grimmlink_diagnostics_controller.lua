local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local DataStorage = deps.DataStorage
    local json = deps.json
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS
    local SETTINGS_BACKUP_KEYS = deps.SETTINGS_BACKUP_KEYS
    local SETTINGS_BACKUP_SCHEMA_VERSION = deps.SETTINGS_BACKUP_SCHEMA_VERSION
    local SETTINGS_BACKUP_DIRECTORY_NAME = deps.SETTINGS_BACKUP_DIRECTORY_NAME
    local SETTINGS_BACKUP_FILE_NAME = deps.SETTINGS_BACKUP_FILE_NAME
    local LOCAL_DIAGNOSTICS_SCHEMA_VERSION = deps.LOCAL_DIAGNOSTICS_SCHEMA_VERSION
    local LOCAL_DIAGNOSTICS_DIRECTORY_NAME = deps.LOCAL_DIAGNOSTICS_DIRECTORY_NAME
    local LOCAL_DIAGNOSTICS_FILE_NAME = deps.LOCAL_DIAGNOSTICS_FILE_NAME
    local HISTORICAL_IMPORT_DEFAULT_FILE_NAME = deps.HISTORICAL_IMPORT_DEFAULT_FILE_NAME
    local HISTORICAL_IMPORT_GAP_SECONDS = deps.HISTORICAL_IMPORT_GAP_SECONDS
    local _gl_load_errors = deps._gl_load_errors or {}
    local basenameOf = deps.basenameOf
    local cloneTable = deps.cloneTable
    local countMapKeys = deps.countMapKeys
    local formatTimestamp = deps.formatTimestamp
    local historicalPageToPercent = deps.historicalPageToPercent
    local isValidHttpUrl = deps.isValidHttpUrl
    local maybeNumber = deps.maybeNumber
    local normalizeDeviceIdentityText = deps.normalizeDeviceIdentityText
    local normalizeDirectoryPath = deps.normalizeDirectoryPath
    local normalizeShelfType = deps.normalizeShelfType
    local nowUtc = deps.nowUtc
    local parentDirectoryPath = deps.parentDirectoryPath
    local redactSimple = deps.redactSimple
    local redactUrl = deps.redactUrl
    local roundToSingleDecimal = deps.roundToSingleDecimal
    local safeDbBoolCall = deps.safeDbBoolCall
    local safeDbValueCall = deps.safeDbValueCall
    local safeToString = deps.safeToString
    local shortPrefix = deps.shortPrefix
    local toIso8601 = deps.toIso8601
function Grimmlink:getSettingsBackupPath()
    return self:getSettingsBackupDirectory() .. "/" .. SETTINGS_BACKUP_FILE_NAME
end

function Grimmlink:getSettingsBackupDirectory()
    return normalizeDirectoryPath(DataStorage:getSettingsDir() .. "/" .. SETTINGS_BACKUP_DIRECTORY_NAME)
end

function Grimmlink:buildSettingsBackupPayload()
    local settings = {}
    for _, key in ipairs(SETTINGS_BACKUP_KEYS) do
        local value = self[key]
        if value == nil then
            value = self:readSetting(key, nil)
        end
        if value ~= nil then
            settings[key] = type(value) == "table" and cloneTable(value) or value
        end
    end

    return {
        schemaVersion = SETTINGS_BACKUP_SCHEMA_VERSION,
        plugin = "GrimmLink",
        version = self:getPluginVersionLabel(),
        exportedAt = nowUtc(),
        settings = settings,
    }
end

function Grimmlink:exportSettingsBackup(path)
    local target_path = safeToString(path)
    if target_path == "" then
        target_path = self:getSettingsBackupPath()
    end
    local backup_dir = parentDirectoryPath(target_path)
    if backup_dir and backup_dir ~= "" then
        local ok_dir = self:isDirectory(backup_dir)
        if not ok_dir then
            local created = self:ensureDirectoryExists(backup_dir)
            if not created then
                self:showMessage(T(_("Failed to create backup folder:\n%1"), backup_dir), 4)
                return false
            end
        end
    end

    local payload = self:buildSettingsBackupPayload()
    local ok_encode, encoded = pcall(json.encode, payload)
    if not ok_encode or type(encoded) ~= "string" then
        self:showMessage(_("Failed to encode settings backup"), 4)
        return false
    end

    local exported = false
    local ok_write = pcall(function()
        local handle = io.open(target_path, "w")
        if handle then
            handle:write(encoded)
            handle:close()
            exported = true
        end
    end)
    if not ok_write or not exported then
        self:showMessage(_("Failed to save settings backup"), 4)
        return false
    end

    self:showMessage(T(
        _("Settings backup saved to:\n%1\n\nWarning: this file includes your connection credentials."),
        target_path
    ), 8)
    return true
end

function Grimmlink:applySettingsBackupPayload(payload)
    local settings = type(payload) == "table" and payload.settings or nil
    if type(settings) ~= "table" then
        return false, 0
    end

    local restored = 0
    for _, key in ipairs(SETTINGS_BACKUP_KEYS) do
        if settings[key] ~= nil then
            local value = type(settings[key]) == "table" and cloneTable(settings[key]) or settings[key]
            if self:saveSetting(key, value) then
                restored = restored + 1
            end
        end
    end
    self:markFirstRunSetupCompleted()
    self:refreshApiClient(true)
    self:clearTabItemsCache()
    return restored > 0, restored
end

function Grimmlink:restoreSettingsBackupFromPath(path)
    local target_path = safeToString(path)
    if target_path == "" then
        target_path = self:getSettingsBackupPath()
    end

    local content = nil
    local ok_read = pcall(function()
        local handle = io.open(target_path, "r")
        if handle then
            content = handle:read("*a")
            handle:close()
        end
    end)
    if not ok_read or safeToString(content) == "" then
        self:showMessage(T(_("Failed to read settings backup:\n%1"), target_path), 4)
        return false
    end

    local ok_decode, payload = pcall(json.decode, content)
    if not ok_decode or type(payload) ~= "table" then
        self:showMessage(_("Failed to parse settings backup"), 4)
        return false
    end

    local ok_apply, restored = self:applySettingsBackupPayload(payload)
    if not ok_apply then
        self:showMessage(_("Settings backup did not contain any restorable GrimmLink settings"), 4)
        return false
    end

    self:showMessage(T(
        _("Restored %1 GrimmLink settings from:\n%2\n\nNote: restart may be needed for Settings Tab visibility changes."),
        restored,
        target_path
    ), 8)
    return true
end

function Grimmlink:promptRestoreSettingsBackup()
    local default_path = self:getSettingsBackupPath()
    self:showTextInput(
        _("Restore Settings Backup"),
        default_path,
        _("Enter backup file path"),
        false,
        function(value)
            local target_path = safeToString(value)
            if target_path == "" then
                self:showMessage(_("Backup path is required"), 3)
                return
            end
            self:showConfirmAction(
                T(
                    _("Restore GrimmLink settings from:\n%1\n\nThis will overwrite current GrimmLink settings on this device."),
                    target_path
                ),
                _("Restore"),
                function()
                    self:restoreSettingsBackupFromPath(target_path)
                end
            )
        end
    )
end

function Grimmlink:getLocalDiagnosticsBundleDirectory()
    return normalizeDirectoryPath(DataStorage:getSettingsDir() .. "/" .. LOCAL_DIAGNOSTICS_DIRECTORY_NAME)
end

function Grimmlink:getLocalDiagnosticsBundlePath()
    return self:getLocalDiagnosticsBundleDirectory() .. "/" .. LOCAL_DIAGNOSTICS_FILE_NAME
end

function Grimmlink:getHistoricalImportDefaultPath()
    return normalizeDirectoryPath(DataStorage:getSettingsDir()) .. "/" .. HISTORICAL_IMPORT_DEFAULT_FILE_NAME
end

function Grimmlink:buildDiagnosticsSettingsSnapshot()
    local settings = {}
    for _, key in ipairs(SETTINGS_BACKUP_KEYS) do
        local value = self[key]
        if value == nil then
            value = self:readSetting(key, nil)
        end
        if value ~= nil then
            if key == "password" then
                settings[key] = "(redacted)"
            elseif key == "username" then
                settings[key] = redactSimple(value, 2)
            elseif key == "server_url" or key == "remote_url" then
                settings[key] = redactUrl(value)
            elseif key == "home_ssid" then
                settings[key] = self:redactSSID(value)
            elseif key == "device_id" then
                settings[key] = shortPrefix(value, 12)
            elseif type(value) == "table" then
                settings[key] = cloneTable(value)
            else
                settings[key] = value
            end
        end
    end
    return settings
end

function Grimmlink:buildLocalDiagnosticsBundle(context)
    context = context or self:getCurrentDocumentContext() or {}
    self:resolveServerUrl()
    local queues = self:getQueueSummaryCounters()
    local pending_counts_for_book = safeDbValueCall(self.db, "getPendingCountsForFileHash", {
        progress = 0,
        sessions = 0,
        metadata = 0,
    }, context.file_hash)
    local shelf_stats = safeDbValueCall(self.db, "getShelfSyncStats", { total = 0, downloaded_by_grimmlink = 0 })
    local log_path = self.file_logger and type(self.file_logger.getLogPath) == "function"
        and self.file_logger:getLogPath() or ""

    return {
        schemaVersion = LOCAL_DIAGNOSTICS_SCHEMA_VERSION,
        plugin = "GrimmLink",
        version = self:getPluginVersionLabel(),
        exportedAt = nowUtc(),
        device = {
            name = normalizeDeviceIdentityText(self.device_name, self:defaultDeviceName(), 80),
            id = shortPrefix(self.device_id, 12),
        },
        connection = {
            enabled = self.enabled == true,
            configured_local_url = redactUrl(self.server_url),
            configured_remote_url = redactUrl(self.remote_url),
            active_url_source = safeToString(self.active_url_source),
            active_url = redactUrl(self.active_url),
            home_ssid = self:redactSSID(self.home_ssid),
            current_ssid = self:redactSSID(self:getCurrentSSID()),
            last_url_switch_reason = safeToString(self.last_url_switch_reason),
            last_url_switch_at = formatTimestamp(self.last_url_switch_at),
            last_connection_error_category = safeToString(self.last_connection_error_category),
            last_connection_error_message_safe = safeToString(self.last_connection_error_message_safe),
            last_connection_test_at = formatTimestamp(self.last_connection_test_at),
            last_connection_test_result = safeToString(self.last_connection_test_result),
            network_mode = self:getNetworkModeLabel(),
            ask_wifi_before_sync = self.ask_wifi_before_sync == true,
            sync_on_network_connected = self.sync_on_network_connected == true,
            network_sync_cooldown_seconds = tonumber(self.network_sync_cooldown_seconds) or DEFAULTS.network_sync_cooldown_seconds,
        },
        settings = self:buildDiagnosticsSettingsSnapshot(),
        database = {
            path = self.db and safeToString(self.db.db_path) or "",
            pending_progress = queues.pending_progress or 0,
            pending_sessions = queues.pending_sessions or 0,
            pending_metadata = queues.pending_metadata or 0,
            pending_shelf_removals = queues.pending_shelf_removals or 0,
            synced_metadata_history = safeDbValueCall(self.db, "getSyncedMetadataCount", 0),
            shelf_tombstones = safeDbValueCall(self.db, "getShelfTombstoneCount", 0),
            shelf_map_rows = shelf_stats and shelf_stats.total or 0,
            shelf_downloaded_by_grimmlink = shelf_stats and shelf_stats.downloaded_by_grimmlink or 0,
            historical_import_history = safeDbValueCall(self.db, "getHistoricalImportCount", 0),
        },
        currentBook = {
            file_name = basenameOf(context.file_path),
            file_hash = shortPrefix(context.file_hash, 16),
            book_id = maybeNumber(context.book_id) or context.book_id,
            book_file_id = maybeNumber(context.book_file_id) or context.book_file_id,
            tracking_enabled = self:isTrackingEnabled(context.file_hash, context.file_path),
            pending_counts = pending_counts_for_book,
        },
        files = {
            log_path = safeToString(log_path),
            settings_backup_path = self:getSettingsBackupPath(),
            diagnostics_bundle_path = self:getLocalDiagnosticsBundlePath(),
            historical_import_default_path = self:getHistoricalImportDefaultPath(),
        },
        loadErrors = cloneTable(_gl_load_errors),
    }
end

function Grimmlink:exportLocalDiagnosticsBundle(path)
    local target_path = safeToString(path)
    if target_path == "" then
        target_path = self:getLocalDiagnosticsBundlePath()
    end
    local target_dir = parentDirectoryPath(target_path)
    if target_dir and target_dir ~= "" and not self:isDirectory(target_dir) then
        if not self:ensureDirectoryExists(target_dir) then
            self:showMessage(T(_("Failed to create diagnostics folder:\n%1"), target_dir), 4)
            return false
        end
    end

    local payload = self:buildLocalDiagnosticsBundle()
    local ok_encode, encoded = pcall(json.encode, payload)
    if not ok_encode or type(encoded) ~= "string" then
        self:showMessage(_("Failed to encode local diagnostics bundle"), 4)
        return false
    end

    local exported = false
    local ok_write = pcall(function()
        local handle = io.open(target_path, "w")
        if handle then
            handle:write(encoded)
            handle:close()
            exported = true
        end
    end)
    if not ok_write or not exported then
        self:showMessage(_("Failed to save local diagnostics bundle"), 4)
        return false
    end

    self:showMessage(T(_("Local diagnostics bundle saved to:\n%1"), target_path), 6)
    return true
end

function Grimmlink:loadHistoricalPageStatsFromPath(path)
    local target_path = safeToString(path)
    if target_path == "" then
        target_path = self:getHistoricalImportDefaultPath()
    end

    local handle = io.open(target_path, "r")
    if not handle then
        return nil, T(_("KOReader statistics DB not found:\n%1"), target_path)
    end
    handle:close()

    local ok_sqlite, sqlite = pcall(require, "lua-ljsqlite3/init")
    if not ok_sqlite or not sqlite or type(sqlite.open) ~= "function" then
        return nil, _("SQLite support unavailable for Historical Import")
    end

    local ok_open, conn = pcall(sqlite.open, target_path)
    if not ok_open or not conn then
        return nil, T(_("Failed to open KOReader statistics DB:\n%1"), target_path)
    end

    local stmt = conn:prepare([[
        SELECT
            COALESCE(b.md5, ''),
            COALESCE(b.title, ''),
            COALESCE(b.authors, ''),
            COALESCE(ps.page, 0),
            COALESCE(ps.start_time, 0),
            COALESCE(ps.duration, 0),
            COALESCE(ps.total_pages, b.pages, 0)
        FROM page_stat ps
        JOIN book b ON b.id = ps.id_book
        WHERE COALESCE(b.deleted, 0) = 0
          AND COALESCE(b.md5, '') <> ''
        ORDER BY b.md5 ASC, ps.start_time ASC, ps.page ASC
    ]])
    if not stmt then
        if type(conn.close) == "function" then
            pcall(conn.close, conn)
        end
        return nil, _("Failed to query KOReader statistics DB")
    end

    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = {
            file_hash = safeToString(row[1]),
            title = safeToString(row[2]),
            authors = safeToString(row[3]),
            page = tonumber(row[4]) or 0,
            start_time = tonumber(row[5]) or 0,
            duration = tonumber(row[6]) or 0,
            total_pages = tonumber(row[7]) or 0,
        }
    end
    stmt:close()
    if type(conn.close) == "function" then
        pcall(conn.close, conn)
    end
    return rows
end

function Grimmlink:groupHistoricalPageStats(rows, gap_seconds)
    local groups = {}
    local current = nil
    local gap = tonumber(gap_seconds) or HISTORICAL_IMPORT_GAP_SECONDS

    for _, row in ipairs(rows or {}) do
        local file_hash = safeToString(row.file_hash or row.md5)
        local start_time = tonumber(row.start_time) or 0
        local duration = math.max(0, tonumber(row.duration) or 0)
        local page = tonumber(row.page) or 0
        local total_pages = math.max(0, tonumber(row.total_pages) or 0)

        if file_hash ~= "" and start_time > 0 and duration > 0 then
            local end_time = start_time + duration
            local split = current == nil
                or current.file_hash ~= file_hash
                or start_time < current.start_time
                or (start_time - (current.end_time or start_time)) > gap

            if split then
                current = {
                    file_hash = file_hash,
                    title = safeToString(row.title),
                    authors = safeToString(row.authors),
                    start_time = start_time,
                    end_time = end_time,
                    duration_seconds = duration,
                    start_page = page,
                    end_page = page,
                    total_pages = total_pages,
                    row_count = 1,
                }
                groups[#groups + 1] = current
            else
                current.end_time = math.max(current.end_time or end_time, end_time)
                current.duration_seconds = (current.duration_seconds or 0) + duration
                current.end_page = page
                current.total_pages = math.max(current.total_pages or 0, total_pages)
                current.row_count = (current.row_count or 0) + 1
                if current.title == "" then
                    current.title = safeToString(row.title)
                end
                if current.authors == "" then
                    current.authors = safeToString(row.authors)
                end
            end
        end
    end

    return groups
end

function Grimmlink:buildHistoricalImportSession(group, matched)
    local total_pages = math.max(
        tonumber(group.total_pages) or 0,
        tonumber(group.end_page) or 0,
        tonumber(group.start_page) or 0
    )
    local start_progress = historicalPageToPercent(group.start_page, total_pages)
    local end_progress = historicalPageToPercent(group.end_page, total_pages)
    local duration_seconds = math.max(0, tonumber(group.duration_seconds) or 0)
    local cached = self.db and type(self.db.getBookByHash) == "function" and self.db:getBookByHash(group.file_hash) or nil
    local file_path = cached and cached.file_path or nil
    local book_type = self:getBookType(file_path or safeToString(group.title))

    return {
        bookId = maybeNumber(matched and matched.book_id or (cached and cached.book_id) or nil),
        bookHash = group.file_hash,
        bookType = book_type,
        device = self.device_name,
        deviceId = self.device_id,
        startTime = toIso8601(group.start_time),
        endTime = toIso8601(group.end_time),
        durationSeconds = duration_seconds,
        durationFormatted = self:formatDuration(duration_seconds),
        startProgress = start_progress,
        endProgress = end_progress,
        progressDelta = roundToSingleDecimal((end_progress or 0) - (start_progress or 0)),
        startLocation = "/" .. tostring(tonumber(group.start_page) or 0),
        endLocation = "/" .. tostring(tonumber(group.end_page) or 0),
        currentPage = tonumber(group.end_page) or 0,
        totalPages = total_pages,
    }
end

function Grimmlink:importHistoricalSessionsFromPath(path)
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return false
    end

    local rows, load_error = self:loadHistoricalPageStatsFromPath(path)
    if type(rows) ~= "table" then
        self:showMessage(load_error or _("Failed to load KOReader historical reading data"), 5)
        return false
    end

    local groups = self:groupHistoricalPageStats(rows, HISTORICAL_IMPORT_GAP_SECONDS)
    if #groups == 0 then
        self:showMessage(_("No historical KOReader reading sessions found to import"), 4)
        return true
    end

    local resolved_by_hash = {}
    local seen_books = {}
    local matched_books = {}
    local unresolved_books = {}
    local queued_count = 0
    local skipped_invalid = 0
    local skipped_duplicate = 0

    for _, group in ipairs(groups) do
        seen_books[group.file_hash] = true
        local matched = resolved_by_hash[group.file_hash]
        if matched == nil then
            matched = self:resolveBookByHash(nil, group.file_hash, true) or false
            resolved_by_hash[group.file_hash] = matched
        end

        if matched and matched.book_id then
            matched_books[group.file_hash] = true
        else
            unresolved_books[group.file_hash] = true
        end

        local session = self:buildHistoricalImportSession(group, matched ~= false and matched or nil)
        local is_valid = self:validateSession(
            session.durationSeconds,
            session.progressDelta,
            group.start_page,
            group.end_page
        )

        if is_valid then
            local already_imported = safeDbValueCall(
                self.db,
                "isHistoricalSessionImported",
                false,
                session.bookHash,
                session.startTime,
                session.endTime,
                session.deviceId
            )

            if already_imported then
                skipped_duplicate = skipped_duplicate + 1
            elseif self.db:addPendingSession(session) then
                safeDbBoolCall(
                    self.db,
                    "markHistoricalSessionImported",
                    session.bookHash,
                    session.startTime,
                    session.endTime,
                    session.deviceId
                )
                queued_count = queued_count + 1
            else
                skipped_invalid = skipped_invalid + 1
            end
        else
            skipped_invalid = skipped_invalid + 1
        end
    end

    self:showMessage(T(
        _("Historical Import complete\nBooks seen: %1\nMatched books: %2\nUnmatched books: %3\nSessions queued: %4\nSkipped duplicates: %5\nSkipped invalid: %6\n\nRun Sync Pending Now when ready."),
        countMapKeys(seen_books),
        countMapKeys(matched_books),
        countMapKeys(unresolved_books),
        queued_count,
        skipped_duplicate,
        skipped_invalid
    ), 8)
    return true
end

function Grimmlink:promptHistoricalImport()
    local default_path = self:getHistoricalImportDefaultPath()
    self:showTextInput(
        _("Historical Import"),
        default_path,
        _("Path to KOReader statistics.sqlite3"),
        false,
        function(value)
            local target_path = safeToString(value)
            if target_path == "" then
                self:showMessage(_("Statistics DB path is required"), 3)
                return
            end
            self:showConfirmAction(
                T(
                    _("Import historical KOReader reading sessions from:\n%1\n\nThis only queues past sessions inside GrimmLink and will not change your current reading position."),
                    target_path
                ),
                _("Import History"),
                function()
                    self:importHistoricalSessionsFromPath(target_path)
                end
            )
        end
    )
end

function Grimmlink:buildDebugInfo(context)
    context = context or self:getCurrentDocumentContext() or {}
    self:resolveServerUrl()
    local pending_counts = safeDbValueCall(self.db, "getPendingCountsForFileHash", {
        progress = 0,
        sessions = 0,
        metadata = 0,
    }, context.file_hash)
    local pending_progress_total = safeDbValueCall(self.db, "getPendingProgressCount", 0)
    local pending_sessions_total = safeDbValueCall(self.db, "getPendingSessionCount", 0)
    local pending_metadata_total = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    local tracking_enabled = self:isTrackingEnabled(context.file_hash, context.file_path)
    local matched = (self.db and context.file_hash and context.file_hash ~= "")
        and safeDbValueCall(self.db, "getBookByHash", nil, context.file_hash) or nil
    local cached = context.file_path and self:resolveBookByFilePath(context.file_path) or nil
    local shelf_map = context.book_id and safeDbValueCall(self.db, "getShelfSyncEntry", nil, context.book_id) or nil
    local async_download = self.api and type(self.api.isAsyncDownloadAvailable) == "function"
        and self.api:isAsyncDownloadAvailable() or false
    local device_name = normalizeDeviceIdentityText(self.device_name, self:defaultDeviceName(), 80)
    local log_path = self.file_logger and type(self.file_logger.getLogPath) == "function"
        and self.file_logger:getLogPath() or ""
    local current_ssid = self:getCurrentSSID()
    local magic_only_file_count = 0
    local shared_regular_magic_file_count = 0
    if self.db and type(self.db.getAllShelfSyncEntries) == "function" then
        local entries = self.db:getAllShelfSyncEntries()
        local per_book = {}
        for _, entry in ipairs(entries or {}) do
            local book_key = tostring(entry.book_id or "")
            if book_key ~= "" then
                local state = per_book[book_key] or { regular = false, magic = false }
                local shelf_type = normalizeShelfType(entry.shelf_type)
                if shelf_type == "magic" then
                    state.magic = true
                else
                    state.regular = true
                end
                per_book[book_key] = state
            end
        end
        for _, state in pairs(per_book) do
            if state.magic and state.regular then
                shared_regular_magic_file_count = shared_regular_magic_file_count + 1
            elseif state.magic then
                magic_only_file_count = magic_only_file_count + 1
            end
        end
    end

    local lines = {
        _("GrimmLink Debug Info"),
        T(_("Plugin version: %1"), self:getPluginVersionLabel()),
        T(_("Device: %1"), device_name),
        T(_("Enabled: %1"), self.enabled and _("yes") or _("no")),
        T(_("configured local URL: %1"), redactUrl(self.server_url)),
        T(_("configured remote URL: %1"), redactUrl(self.remote_url)),
        T(_("home_ssid: %1"), self:redactSSID(self.home_ssid)),
        T(_("current_ssid: %1"), self:redactSSID(current_ssid)),
        T(_("active_url_source: %1"), safeToString(self.active_url_source)),
        T(_("active_url: %1"), redactUrl(self.active_url)),
        T(_("last_url_switch_reason: %1"), safeToString(self.last_url_switch_reason)),
        T(_("last_url_switch_at: %1"), formatTimestamp(self.last_url_switch_at)),
        T(_("last_connection_error_category: %1"), safeToString(self.last_connection_error_category)),
        T(_("last_connection_error_message_safe: %1"), safeToString(self.last_connection_error_message_safe)),
        T(_("last_connection_test_at: %1"), formatTimestamp(self.last_connection_test_at)),
        T(_("last_connection_test_result: %1"), safeToString(self.last_connection_test_result)),
        T(_("network_mode: %1"), self:getNetworkModeLabel()),
        T(_("network_sync_cooldown_seconds: %1"), tonumber(self.network_sync_cooldown_seconds) or DEFAULTS.network_sync_cooldown_seconds),
        T(
            _("pending_shelf_removal_retry_cooldown_seconds: %1"),
            tonumber(self.pending_shelf_removal_retry_cooldown_seconds) or DEFAULTS.pending_shelf_removal_retry_cooldown_seconds
        ),
        T(_("ask_wifi_before_sync: %1"), self.ask_wifi_before_sync == true and _("yes") or _("no")),
        T(_("sync_on_network_connected: %1"), self.sync_on_network_connected == true and _("yes") or _("no")),
        T(_("username: %1"), redactSimple(self.username, 2)),
        T(_("device_id: %1"), shortPrefix(self.device_id, 10)),
        T(_("Pending progress count: %1"), pending_progress_total),
        T(_("Pending session count: %1"), pending_sessions_total),
        T(_("Pending metadata count: %1"), pending_metadata_total),
        T(_("Shelf sync enabled: %1"), self.shelf_sync_enabled and _("yes") or _("no")),
        T(_("Legacy shelf id/name/type: %1 / %2 / %3"), safeToString(self.shelf_id), safeToString(self.shelf_name), safeToString(self.shelf_type)),
        T(_("Regular sync enabled id/name: %1 / %2 / %3"), self.sync_regular_shelf_enabled and _("yes") or _("no"), safeToString(self.selected_regular_shelf_id), safeToString(self.selected_regular_shelf_name)),
        T(_("Magic sync enabled id/name: %1 / %2 / %3"), self.sync_magic_shelf_enabled and _("yes") or _("no"), safeToString(self.selected_magic_shelf_id), safeToString(self.selected_magic_shelf_name)),
        T(_("use_separate_magic_download_dir: %1"), self.use_separate_magic_download_dir == true and _("yes") or _("no")),
        T(_("shelf_plan_batch_size: %1"), tonumber(self.shelf_plan_batch_size) or DEFAULTS.shelf_plan_batch_size),
        T(_("Download dir: %1"), safeToString(self.download_dir)),
        T(_("Magic download dir: %1"), safeToString(self.magic_download_dir)),
        T(_("magic-only file count: %1"), magic_only_file_count),
        T(_("shared regular+magic file count: %1"), shared_regular_magic_file_count),
        T(_("DB path: %1"), self.db and safeToString(self.db.db_path) or ""),
        T(_("Async download available: %1"), async_download and _("yes") or _("no")),
        T(_("Log file path: %1"), safeToString(log_path)),
        "",
        _("Current/Selected Book"),
        T(_("File: %1"), basenameOf(context.file_path)),
        T(_("File hash: %1"), shortPrefix(context.file_hash, 10)),
        T(_("Cached bookId/bookFileId: %1 / %2"),
            safeToString((matched and matched.book_id) or (cached and cached.book_id) or context.book_id),
            safeToString((matched and matched.bookFileId) or context.book_file_id)),
        T(_("Tracking enabled: %1"), tracking_enabled and _("yes") or _("no")),
        T(_("Pending for file: progress %1, sessions %2, metadata %3"),
            safeToString(pending_counts.progress or 0),
            safeToString(pending_counts.sessions or 0),
            safeToString(pending_counts.metadata or 0)),
        T(_("Shelf mapping bookId/shelfId: %1 / %2"),
            safeToString((shelf_map and shelf_map.book_id) or ""),
            safeToString((shelf_map and shelf_map.shelf_id) or "")),
    }
    return table.concat(lines, "\n")
end

function Grimmlink:exportDebugInfo()
    local text = self:buildDebugInfo()
    local exported = false
    local path = DataStorage:getDataDir() .. "/grimmlink-debug-info.txt"
    local ok_write = pcall(function()
        local handle = io.open(path, "w")
        if handle then
            handle:write(text)
            handle:close()
            exported = true
        end
    end)
    if ok_write and exported then
        text = text .. "\n\n" .. T(_("Saved to: %1"), path)
    end
    self:showMessage(text, 8)
end

function Grimmlink:clearLogsWithConfirm()
    if not self.file_logger or type(self.file_logger.clearLogs) ~= "function" then
        self:showMessage(_("Log file manager unavailable"), 3)
        return
    end
    self:showConfirmAction(
        _("Clear GrimmLink logs?"),
        _("Clear Logs"),
        function()
            local ok, result = pcall(self.file_logger.clearLogs, self.file_logger)
            if ok and result then
                self:showMessage(_("Logs cleared"), 3)
            else
                self:showMessage(_("Log cleanup finished with warnings"), 3)
            end
        end
    )
end

function Grimmlink:diagnoseConnectionFailure(url, error_message, http_code, current_ssid, active_url_source)
    local lowered = safeToString(error_message):lower()
    local safe_error = safeToString(error_message):gsub("https?://[^%s]+", "[URL REDACTED]")
    local category = "unknown"

    if not self:isOnline() then
        category = "no_wifi"
    elseif safeToString(url) == "" then
        category = "url_missing"
    elseif not isValidHttpUrl(url) then
        category = "url_invalid"
    elseif type(http_code) == "number" then
        if http_code == 401 then
            category = "unauthorized"
        elseif http_code == 403 then
            category = "forbidden"
        elseif http_code == 404 then
            category = "not_found"
        elseif http_code >= 500 and http_code <= 504 then
            category = (http_code == 502 or http_code == 503 or http_code == 504) and "proxy_unavailable" or "server_error"
        elseif http_code >= 500 then
            category = "server_error"
        end
    elseif lowered:find("timeout", 1, true) then
        category = "timeout"
    elseif lowered:find("dns", 1, true) or lowered:find("name or service not known", 1, true)
        or lowered:find("host not found", 1, true) then
        category = "dns_failed"
    elseif lowered:find("refused", 1, true) then
        category = "connection_refused"
    elseif lowered:find("no route", 1, true) then
        category = "no_route_to_host"
    elseif lowered:find("unreachable", 1, true) then
        category = "host_unreachable"
    elseif lowered:find("tls", 1, true) or lowered:find("certificate", 1, true) or lowered:find("ssl", 1, true) then
        category = "tls_error"
    end

    local suggestion = _("Try again and check server/network settings.")
    if category == "no_wifi" then
        suggestion = _("Connect to Wi-Fi/network and try again.")
    elseif category == "url_missing" then
        suggestion = _("Configure Local URL and/or Remote URL in GrimmLink Connection settings.")
    elseif category == "url_invalid" then
        suggestion = _("Use URL starting with http:// or https://")
    elseif category == "timeout" or category == "connection_refused" or category == "host_unreachable" or category == "no_route_to_host" then
        if active_url_source == "local" or active_url_source == "fallback" then
            suggestion = _("Check that Grimmory is running and this device is on the same network.")
        else
            suggestion = _("Check remote domain, reverse proxy, VPN, port forwarding, or internet connection.")
        end
    elseif category == "dns_failed" then
        suggestion = _("Remote hostname could not be resolved. Check domain name, DNS, or internet.")
    elseif category == "unauthorized" then
        suggestion = _("Authentication failed. Check username/password or KOReader auth key.")
    elseif category == "forbidden" then
        suggestion = _("Access denied. This account may not have permission.")
    elseif category == "not_found" then
        suggestion = _("Endpoint not found. Grimmory version may not match GrimmLink.")
    elseif category == "server_error" then
        suggestion = _("Grimmory server error. Check server logs.")
    elseif category == "proxy_unavailable" then
        suggestion = _("Reverse proxy or server temporarily unavailable (502/503/504).")
    elseif category == "tls_error" then
        suggestion = _("HTTPS certificate/TLS failed. Check cert, domain, and device date/time.")
    end

    return {
        category = category,
        safe_error = safe_error,
        suggestion = suggestion,
    }
end
end

return M