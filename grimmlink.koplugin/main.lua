local DataStorage = require("datastorage")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local json = require("json")
local bit = require("bit")
local ffiutil = require("ffi/util")
local _ok_event, Event = pcall(require, "ui/event")
if not _ok_event then Event = nil end

local _ok_dispatcher, Dispatcher = pcall(require, "dispatcher")
if not _ok_dispatcher then Dispatcher = nil end
local _ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
if not _ok_fm then FileManager = nil end

local _gl_load_errors = {}
local function _glRequire(name)
    local ok, mod = pcall(require, name)
    if not ok then
        _gl_load_errors[#_gl_load_errors + 1] = name .. ": " .. tostring(mod)
        return {}
    end
    return mod
end

local Database    = _glRequire("grimmlink_database")
local APIClient   = _glRequire("grimmlink_api_client")
local FileLogger  = _glRequire("grimmlink_file_logger")
local ShelfSync   = _glRequire("grimmlink_shelf_sync")
local Annotations = _glRequire("grimmlink_annotations")
local Updater     = _glRequire("grimmlink_updater")

local _ = require("gettext")
local T = ffiutil.template

local Grimmlink = WidgetContainer:extend{
    name = "grimmlink",
    is_doc_only = false,
}

local grimmlink_fm_patched = false

local DEFAULTS = {
    enabled = true,
    server_url = "",
    username = "",
    password = "",
    device_name = "KOReader",
    device_id = nil,
    auto_pull_on_open = true,
    auto_push_on_close = true,
    offline_queue_enabled = true,
    debug_logging = false,
    log_to_file = false,
    threshold_percent = 1.0,
    threshold_minutes = 5,
    threshold_pages = 5,
    session_min_seconds = 30,
    -- Shelf Sync settings
    shelf_sync_enabled = false,
    shelf_id = nil,
    shelf_name = "",
    download_dir = "",
    auto_sync_shelf_on_resume = false,
    two_way_shelf_delete_sync = false,
    shelf_use_original_filename = true,
    delete_sdr_on_book_delete = false,
    -- Annotation / bookmark / rating sync (Prompt 6)
    annotations_sync_enabled = false,
    bookmarks_sync_enabled = false,
    rating_sync_enabled = false,
    annotations_capture_on_close = true,
    -- Auto update (Prompt 7B)
    auto_update_enabled = false,
    check_update_on_startup = false,
    update_channel = "stable",
    update_repo = "0xstillb/grimmlink",
    allow_prerelease_updates = false,
    -- Web Reader Bridge (Prompt 8)
    web_reader_bridge_enabled = false,
    cfi_conversion_enabled = false,
}

local function safeToString(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function roundToSingleDecimal(value)
    if value == nil then
        return nil
    end
    return math.floor((tonumber(value) or 0) * 10 + 0.5) / 10
end

local function normalizePercent(value)
    if value == nil then
        return nil
    end
    value = tonumber(value)
    if not value then
        return nil
    end
    if value >= 0 and value <= 1 then
        value = value * 100
    end
    if value < 0 then
        value = 0
    end
    if value > 100 then
        value = 100
    end
    return roundToSingleDecimal(value)
end

local function absDifference(a, b)
    if a == nil or b == nil then
        return nil
    end
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0))
end

local function redactSecrets(message)
    if type(message) ~= "string" then
        return tostring(message)
    end
    return message:gsub("https?://[^%s]+", "[URL REDACTED]")
end

local function isNonEmpty(value)
    return value ~= nil and tostring(value) ~= ""
end

local function nowUtc()
    return os.time()
end

local function toIso8601(epoch_seconds)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch_seconds)
end

local function formatTimestamp(epoch_seconds)
    if not epoch_seconds then
        return _("unknown")
    end
    return os.date("%Y-%m-%d %H:%M:%S", epoch_seconds)
end

local function maybeNumber(value)
    if value == nil or value == "" then
        return nil
    end
    return tonumber(value)
end

local function safeMethodCall(target, method, ...)
    if not target or type(target[method]) ~= "function" then
        return nil, false
    end

    local ok, result = pcall(target[method], target, ...)
    if ok then
        return result, true
    end

    return nil, false
end

local function safeDispatchEvent(ui, name, ...)
    if not ui or type(ui.handleEvent) ~= "function" then
        return nil, false
    end

    if not Event or type(Event.new) ~= "function" then
        return nil, false
    end

    local ok, result = pcall(ui.handleEvent, ui, Event:new(name, ...))
    if ok then
        return result, true
    end

    return nil, false
end

local function tryReadSetting(doc_settings, key)
    if not doc_settings or type(doc_settings.readSetting) ~= "function" then
        return nil
    end

    local ok, result = pcall(doc_settings.readSetting, doc_settings, key)
    if ok then
        return result
    end
    return nil
end

local function sanitizeTitle(file_path)
    local title = safeToString(file_path):match("([^/\\]+)$") or safeToString(file_path)
    return title:gsub("%.[^.]+$", "")
end

local function cloneTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function normalizeUpdateChannel(value)
    return value == "prerelease" and "prerelease" or "stable"
end

local function detectPluginDir()
    local source = debug.getinfo(1, "S").source or ""
    local from_source = source:match("^@(.*)[/\\]main%.lua$")
    if from_source and from_source:match("grimmlink%.koplugin$") then
        return from_source
    end
    return DataStorage:getDataDir() .. "/plugins/grimmlink.koplugin"
end

function Grimmlink:log(level, ...)
    local args = { ... }
    for i = 1, #args do
        args[i] = redactSecrets(args[i])
    end

    if level == "warn" then
        logger.warn(table.unpack(args))
    elseif level == "err" then
        logger.err(table.unpack(args))
    elseif level == "dbg" then
        if self.debug_logging then
            logger.dbg(table.unpack(args))
        end
    else
        logger.info(table.unpack(args))
    end

    if self.file_logger and self.log_to_file then
        self.file_logger:write(level:upper(), table.unpack(args))
    end
end

function Grimmlink:logInfo(...)
    self:log("info", ...)
end

function Grimmlink:logWarn(...)
    self:log("warn", ...)
end

function Grimmlink:logErr(...)
    self:log("err", ...)
end

function Grimmlink:logDbg(...)
    self:log("dbg", ...)
end

function Grimmlink:getLogFilePath()
    return DataStorage:getDataDir() .. "/grimmlink.log"
end

function Grimmlink:ensureFileLogger()
    if self.file_logger then
        return true
    end

    self.file_logger = FileLogger:new()
    if not self.file_logger:init() then
        self.file_logger = nil
        return false
    end

    return true
end

function Grimmlink:readRecentLogLines(max_lines)
    local file = io.open(self:getLogFilePath(), "r")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()
    if not content or content == "" then
        return {}
    end

    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end

    local keep = tonumber(max_lines) or 12
    if #lines <= keep then
        return lines
    end

    local recent = {}
    for index = #lines - keep + 1, #lines do
        recent[#recent + 1] = lines[index]
    end
    return recent
end

function Grimmlink:showLogFileLocation()
    local path = self:getLogFilePath()
    self:showMessage(table.concat({
        _("GrimmLink log file"),
        path,
        "",
        T(_("Debug logging: %1"), self.debug_logging and _("enabled") or _("disabled")),
        T(_("Write logs to file: %1"), self.log_to_file and _("enabled") or _("disabled")),
    }, "\n"), 8)
end

function Grimmlink:showRecentLogLines()
    local lines = self:readRecentLogLines(12)
    if lines == nil then
        self:showMessage(T(_("No GrimmLink log file found yet.\nExpected path:\n%1"), self:getLogFilePath()), 6)
        return
    end

    if #lines == 0 then
        self:showMessage(T(_("GrimmLink log file is empty.\nPath:\n%1"), self:getLogFilePath()), 6)
        return
    end

    self:showMessage(table.concat({
        T(_("Recent GrimmLink log lines\nPath: %1"), self:getLogFilePath()),
        "",
        table.concat(lines, "\n"),
    }, "\n"), 10)
end

function Grimmlink:safeDbCall(method_name, fallback, ...)
    if not self.db or type(self.db[method_name]) ~= "function" then
        return fallback
    end

    local ok, result = pcall(self.db[method_name], self.db, ...)
    if not ok then
        return fallback
    end

    return result
end

function Grimmlink:formatDebugFields(fields, preferred_order)
    if type(fields) ~= "table" then
        return ""
    end

    local order = preferred_order or {
        "bookId",
        "bookFileId",
        "bookHash",
        "fileFormat",
        "source",
        "direction",
        "currentPage",
        "totalPages",
        "percent",
        "koreaderRawProgress",
        "koreaderRawLocation",
        "koreaderRawXPointer",
        "epubCfi",
        "positionHref",
        "conversionStatus",
        "conversionConfidence",
        "apiStatus",
        "apiErrorClass",
        "retryCount",
        "reason",
        "action",
    }

    local seen = {}
    local parts = {}

    local function add_field(key)
        local value = fields[key]
        if value == nil or value == "" then
            return
        end
        seen[key] = true
        parts[#parts + 1] = key .. "=" .. tostring(value)
    end

    for _, key in ipairs(order) do
        add_field(key)
    end

    for key, _ in pairs(fields) do
        if not seen[key] then
            add_field(key)
        end
    end

    return table.concat(parts, " ")
end

function Grimmlink:classifyApiOutcome(code, response)
    local numeric_code = tonumber(code)
    local response_text = tostring(response or "")

    if numeric_code == nil then
        local lowered = response_text:lower()
        if lowered:find("timeout", 1, true) then
            return "timeout", "transient_timeout"
        end
        if lowered:find("connection", 1, true) or lowered:find("offline", 1, true) then
            return "offline", "transient_network"
        end
        return "error", "unknown"
    end

    if numeric_code == 404 then
        return "http_404", "permanent_not_found"
    end
    if numeric_code == 400 then
        return "http_400", "permanent_bad_request"
    end
    if numeric_code == 401 or numeric_code == 403 then
        return "http_" .. tostring(numeric_code), "permanent_auth"
    end
    if numeric_code == 408 then
        return "http_408", "transient_timeout"
    end
    if numeric_code == 429 then
        return "http_429", "transient_rate_limited"
    end
    if numeric_code >= 500 then
        return "http_" .. tostring(numeric_code), "transient_server"
    end

    return "http_" .. tostring(numeric_code), "unknown"
end

function Grimmlink:buildProgressDebugFields(snapshot, extra)
    snapshot = type(snapshot) == "table" and snapshot or {}
    extra = type(extra) == "table" and extra or {}

    return {
        bookId = extra.bookId or snapshot.bookId,
        bookFileId = extra.bookFileId or snapshot.bookFileId,
        bookHash = snapshot.bookHash or extra.bookHash,
        fileFormat = snapshot.fileFormat or extra.fileFormat,
        source = extra.source or snapshot.source or "koreader",
        direction = extra.direction,
        currentPage = snapshot.currentPage or extra.currentPage,
        totalPages = snapshot.totalPages or extra.totalPages,
        percent = snapshot.percentage or snapshot.percent or extra.percent,
        koreaderRawProgress = snapshot.rawKoreaderProgress or snapshot.progress or extra.koreaderRawProgress,
        koreaderRawLocation = snapshot.rawKoreaderLocation or snapshot.location or extra.koreaderRawLocation,
        koreaderRawXPointer = snapshot.rawKoreaderXPointer or extra.koreaderRawXPointer,
        epubCfi = snapshot.epubCfi or extra.epubCfi,
        positionHref = snapshot.positionHref or snapshot.href or extra.positionHref,
        conversionStatus = snapshot.conversionStatus or extra.conversionStatus,
        conversionConfidence = snapshot.conversionConfidence or extra.conversionConfidence,
        apiStatus = extra.apiStatus,
        apiErrorClass = extra.apiErrorClass,
        retryCount = extra.retryCount,
        reason = extra.reason,
        action = extra.action,
    }
end

function Grimmlink:logProgressEvent(level, action, fields)
    local message = self:formatDebugFields(fields)
    if message == "" then
        self:log(level or "info", "GrimmLink", action)
    else
        self:log(level or "info", "GrimmLink", action, message)
    end
end

function Grimmlink:recordNotFoundHash(entry)
    if not self.db or type(self.db.upsertNotFoundHash) ~= "function" then
        return false
    end

    entry = entry or {}
    local file_hash = entry.file_hash and tostring(entry.file_hash) or nil
    self._not_found_hashes = self._not_found_hashes or {}
    self._not_found_logged = self._not_found_logged or {}

    if file_hash and file_hash ~= "" then
        self._not_found_hashes[file_hash] = true
    end

    local ok = self.db:upsertNotFoundHash(entry)
    if file_hash and file_hash ~= "" and type(self.db.deletePendingProgressByHash) == "function" then
        self.db:deletePendingProgressByHash(file_hash)
    end

    if file_hash and file_hash ~= "" and not self._not_found_logged[file_hash] then
        self._not_found_logged[file_hash] = true
        logger.warn("GrimmLink: hash not in Grimmory, sync disabled for this book")
    end

    return ok
end

function Grimmlink:isHashMarkedNotFound(file_hash)
    if not file_hash or file_hash == "" then
        return false
    end

    self._not_found_hashes = self._not_found_hashes or {}
    if self._not_found_hashes[file_hash] then
        return true
    end

    if self.db and type(self.db.hasNotFoundHash) == "function" then
        local ok, result = pcall(self.db.hasNotFoundHash, self.db, file_hash)
        if ok and result then
            self._not_found_hashes[file_hash] = true
            return true
        end
    end

    return false
end

function Grimmlink:hasMatchedCurrentDocument()
    if not self.db or not self.ui or not self.ui.document or not self.ui.document.file then
        return false
    end

    local file_path = tostring(self.ui.document.file)
    local cached = self:resolveBookByFilePath(file_path)
    if cached and cached.book_id then
        return true
    end

    if type(self.db.getShelfSyncEntryByLocalPath) == "function" then
        local shelf_entry = self.db:getShelfSyncEntryByLocalPath(file_path)
        return shelf_entry ~= nil and shelf_entry.book_id ~= nil
    end

    return false
end

function Grimmlink:buildDebugSummaryLines(sample_limit)
    local limit = tonumber(sample_limit) or 3
    local cache_stats = self:safeDbCall("getBookCacheStats", { total = 0, matched = 0, unmatched = 0 })
    local shelf_stats = self:safeDbCall("getShelfSyncStats", { total = 0 })
    local pending_progress = self:safeDbCall("getPendingProgressCount", 0)
    local pending_sessions = self:safeDbCall("getPendingSessionCount", 0)
    local pending_annotations = self:safeDbCall("getPendingAnnotationCount", 0)
    local not_found_count = self:safeDbCall("getNotFoundHashCount", 0)
    local stale_count = self:safeDbCall("getStaleCacheCount", 0)
    local not_found_items = self:safeDbCall("getNotFoundHashes", {}, limit) or {}
    local stale_items = self:safeDbCall("getStaleCacheEntries", {}, limit) or {}

    local lines = {
        T(_("Books cached: total=%1 matched=%2 unmatched=%3"),
            cache_stats.total or 0, cache_stats.matched or 0, cache_stats.unmatched or 0),
        T(_("Shelf cache entries: %1"), shelf_stats.total or 0),
        T(_("Pending queues: progress=%1 sessions=%2 annotations=%3"),
            pending_progress or 0, pending_sessions or 0, pending_annotations or 0),
        T(_("Stale cache entries: %1"), stale_count or 0),
        T(_("Not found hashes: %1"), not_found_count or 0),
        T(_("Non-shelf cached books: %1"), math.max((cache_stats.total or 0) - (shelf_stats.total or 0), 0)),
    }

    if #stale_items > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Recent stale cache rows:")
        for index, entry in ipairs(stale_items) do
            lines[#lines + 1] = T(_("- %1 id=%2 hash=%3 path=%4"),
                tostring(entry.table_name or "?"),
                tostring(entry.id or "?"),
                entry.file_hash or "-",
                entry.file_path or "-")
        end
    end

    if #not_found_items > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Recent not found hashes:")
        for index, entry in ipairs(not_found_items) do
            lines[#lines + 1] = T(_("- %1 book=%2 format=%3 source=%4 reason=%5"),
                entry.file_hash or "-",
                entry.book_id and tostring(entry.book_id) or "-",
                entry.file_format or "-",
                entry.source or "-",
                entry.reason or "-")
        end
    end

    return lines
end

function Grimmlink:showDetailedCacheStats()
    if not self:requireReady({ silent = false }) then
        return
    end

    self:showMessage(table.concat({
        _("GrimmLink debug status"),
        table.concat(self:buildDebugSummaryLines(3), "\n"),
    }, "\n"), 8)
end

function Grimmlink:showLocalDbSummary()
    if not self:requireReady({ silent = false }) then
        return
    end

    self:showMessage(table.concat({
        _("GrimmLink local DB summary"),
        table.concat(self:buildDebugSummaryLines(5), "\n"),
    }, "\n"), 10)
end

function Grimmlink:clearPendingProgressQueue()
    if not self:requireReady({ silent = false }) then
        return
    end

    local count = self:safeDbCall("getPendingProgressCount", 0)
    local ok = self:safeDbCall("deleteAllPendingProgress", false)
    if ok then
        self:showMessage(T(_("Cleared %1 pending progress entries."), count or 0), 3)
    else
        self:showMessage(_("Failed to clear pending progress entries."), 4)
    end
end

function Grimmlink:clearStaleCacheEntries()
    if not self:requireReady({ silent = false }) then
        return
    end

    local stale_count = self:safeDbCall("getStaleCacheCount", 0)
    local deleted = self:safeDbCall("clearStaleCache", nil)
    if type(deleted) == "table" then
        self:showMessage(table.concat({
            _("Cleared stale cache entries."),
            T(_("book_cache=%1 progress_state=%2 web_bridge_state=%3"),
                deleted.book_cache or 0,
                deleted.progress_state or 0,
                deleted.web_bridge_state or 0),
        }, "\n"), 4)
    elseif deleted then
        self:showMessage(T(_("Cleared %1 stale cache entries."), stale_count or 0), 4)
    else
        self:showMessage(_("Failed to clear stale cache entries."), 4)
    end
end

function Grimmlink:clearNotFoundHashes()
    if not self:requireReady({ silent = false }) then
        return
    end

    local count = self:safeDbCall("getNotFoundHashCount", 0)
    local ok = self:safeDbCall("clearNotFoundHashes", false)
    if ok then
        self:showMessage(T(_("Cleared %1 not found hashes."), count or 0), 3)
    else
        self:showMessage(_("Failed to clear not found hashes."), 4)
    end
end

function Grimmlink:exportDebugLog()
    if not self:requireReady({ silent = false }) then
        return
    end

    local export_path = DataStorage:getDataDir() .. string.format("/grimmlink-debug-%s.txt", os.date("!%Y%m%d-%H%M%SZ"))
    local file = io.open(export_path, "w")
    if not file then
        self:showMessage(_("Failed to create debug export file."), 4)
        return
    end

    local summary_lines = self:buildDebugSummaryLines(5)
    file:write("[GrimmLink Debug Export]\n")
    file:write("Generated: " .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\n\n")
    file:write("Summary:\n")
    file:write(table.concat(summary_lines, "\n"))
    file:write("\n\nRecent log lines:\n")

    local log_lines = self:readRecentLogLines(200) or {}
    if #log_lines > 0 then
        file:write(table.concat(log_lines, "\n"))
        file:write("\n")
    else
        file:write("(no log lines available)\n")
    end

    file:close()
    self:showMessage(T(_("Debug export written to:\n%1"), export_path), 5)
end

function Grimmlink:isReady(require_api)
    if not self or not self._initialized or not self.db then
        return false
    end
    if require_api and not self.api then
        return false
    end
    return true
end

function Grimmlink:isWebReaderSyncEnabled()
    return self.enabled == true and self.web_reader_bridge_enabled == true
end

function Grimmlink:requireReady(opts)
    opts = opts or {}
    if self:isReady(opts.require_api) then
        return true
    end

    if not opts.silent then
        self:showMessage(opts.message or _("GrimmLink is still starting up"), opts.timeout or 2)
    end
    return false
end

function Grimmlink:invokeSafely(label, fn, args, opts)
    opts = opts or {}
    if type(fn) ~= "function" then
        return opts.fallback
    end

    local ok, result = pcall(fn, table.unpack(args or {}))
    if ok then
        return result
    end

    local err = tostring(result)
    logger.err("GrimmLink " .. tostring(label) .. " error:", err)
    if not opts.silent then
        pcall(function()
            self:showMessage(T(_("GrimmLink %1 failed:\n%2"), tostring(label), err), opts.timeout or 4)
        end)
    end
    return opts.fallback
end

function Grimmlink:wrapUiSpec(spec, path)
    if type(spec) ~= "table" then
        return spec
    end

    local wrapped = {}
    local base_path = path or "GrimmLink"

    for key, value in pairs(spec) do
        local child_path = base_path .. "/" .. tostring(key)
        if key == "callback" then
            wrapped[key] = function(...)
                return self:invokeSafely(base_path, value, { ... }, { fallback = nil, silent = false })
            end
        elseif key == "checked_func" then
            wrapped[key] = function(...)
                return self:invokeSafely(base_path .. " checked", value, { ... }, { fallback = false, silent = true })
            end
        elseif key == "text_func" then
            wrapped[key] = function(...)
                local fallback = spec.text or _("GrimmLink")
                local result = self:invokeSafely(base_path .. " label", value, { ... }, { fallback = fallback, silent = true })
                if result == nil or result == "" then
                    return fallback
                end
                return result
            end
        elseif key == "ok_callback" or key == "cancel_callback" or key == "close_callback" or key == "on_select" then
            wrapped[key] = function(...)
                return self:invokeSafely(base_path .. " " .. tostring(key), value, { ... }, { fallback = nil, silent = false })
            end
        elseif type(value) == "table" then
            wrapped[key] = self:wrapUiSpec(value, child_path)
        else
            wrapped[key] = value
        end
    end

    return wrapped
end

function Grimmlink:init()
    self._initialized = false

    if self.ui and self.ui.menu and type(self.ui.menu.registerToMainMenu) == "function" then
        self.ui.menu:registerToMainMenu(self)
    end

    if #_gl_load_errors > 0 then
        logger.warn("GrimmLink: module load errors: " .. table.concat(_gl_load_errors, " | "))
        UIManager:show(InfoMessage:new{
            text = "GrimmLink load error:\n" .. _gl_load_errors[1],
            timeout = 8,
        })
        return
    end

    if not Database or not Database.new then
        UIManager:show(InfoMessage:new{
            text = _("Failed to initialize GrimmLink database"),
            timeout = 4,
        })
        return
    end

    self.db = Database:new()
    local _db_ok, _db_result = pcall(function() return self.db:init() end)
    if not _db_ok then
        local err_msg = tostring(_db_result)
        logger.err("GrimmLink: db init threw:", err_msg)
        _gl_load_errors[#_gl_load_errors + 1] = "db: " .. err_msg
        UIManager:show(InfoMessage:new{
            text = "GrimmLink db error:\n" .. err_msg,
            timeout = 10,
        })
        return
    elseif not _db_result then
        logger.err("GrimmLink: db init returned false, path:", DataStorage:getSettingsDir())
        UIManager:show(InfoMessage:new{
            text = _("Failed to initialize GrimmLink database"),
            timeout = 4,
        })
        return
    end

    self.enabled = self:readSetting("enabled", DEFAULTS.enabled)
    self.server_url = self:readSetting("server_url", DEFAULTS.server_url)
    self.username = self:readSetting("username", DEFAULTS.username)
    local legacy_auth_key = self.db:getPluginSetting("auth_key")
    self.auth_key = self:readSetting("password", legacy_auth_key or DEFAULTS.password)
    self.device_name = self:readSetting("device_name", self:defaultDeviceName())
    self.device_id = self:readSetting("device_id", self:defaultDeviceId())
    self.auto_pull_on_open = self:readSetting("auto_pull_on_open", DEFAULTS.auto_pull_on_open)
    self.auto_push_on_close = self:readSetting("auto_push_on_close", DEFAULTS.auto_push_on_close)
    self.offline_queue_enabled = self:readSetting("offline_queue_enabled", DEFAULTS.offline_queue_enabled)
    self.debug_logging = self:readSetting("debug_logging", DEFAULTS.debug_logging)
    self.log_to_file = self:readSetting("log_to_file", DEFAULTS.log_to_file)
    self.threshold_percent = self:readSetting("threshold_percent", DEFAULTS.threshold_percent)
    self.threshold_minutes = self:readSetting("threshold_minutes", DEFAULTS.threshold_minutes)
    self.threshold_pages = self:readSetting("threshold_pages", DEFAULTS.threshold_pages)
    self.session_min_seconds = self:readSetting("session_min_seconds", DEFAULTS.session_min_seconds)

    if self.log_to_file then
        if not self:ensureFileLogger() then
            self.file_logger = nil
        end
    end

    self.api = APIClient:new()
    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)

    -- Shelf Sync settings
    self.shelf_sync_enabled = self:readSetting("shelf_sync_enabled", DEFAULTS.shelf_sync_enabled)
    self.shelf_id = self:readSetting("shelf_id", DEFAULTS.shelf_id)
    self.shelf_name = self:readSetting("shelf_name", DEFAULTS.shelf_name)
    self.download_dir = self:readSetting("download_dir", DEFAULTS.download_dir)
    self.auto_sync_shelf_on_resume = self:readSetting("auto_sync_shelf_on_resume", DEFAULTS.auto_sync_shelf_on_resume)
    local legacy_delete_removed = self.db:getPluginSetting("delete_removed_shelf_books")
    local two_way_default = legacy_delete_removed ~= nil and legacy_delete_removed or DEFAULTS.two_way_shelf_delete_sync
    self.two_way_shelf_delete_sync = self:readSetting("two_way_shelf_delete_sync", two_way_default)
    self.shelf_use_original_filename = self:readSetting("shelf_use_original_filename", DEFAULTS.shelf_use_original_filename)
    self.delete_sdr_on_book_delete = self:readSetting("delete_sdr_on_book_delete", DEFAULTS.delete_sdr_on_book_delete)

    self.shelf_sync = ShelfSync:new(self.db, self.api)

    -- Annotation / bookmark / rating sync (Prompt 6)
    self.annotations_sync_enabled = self:readSetting("annotations_sync_enabled", DEFAULTS.annotations_sync_enabled)
    self.bookmarks_sync_enabled = self:readSetting("bookmarks_sync_enabled", DEFAULTS.bookmarks_sync_enabled)
    self.rating_sync_enabled = self:readSetting("rating_sync_enabled", DEFAULTS.rating_sync_enabled)
    self.annotations_capture_on_close = self:readSetting("annotations_capture_on_close", DEFAULTS.annotations_capture_on_close)

    self.annotations = Annotations:new({
        db = self.db,
        api = self.api,
        annotations_sync_enabled = self.annotations_sync_enabled,
        bookmarks_sync_enabled = self.bookmarks_sync_enabled,
        rating_sync_enabled = self.rating_sync_enabled,
    })

    self.web_reader_bridge_enabled = self:readSetting("web_reader_bridge_enabled", DEFAULTS.web_reader_bridge_enabled)
    self.cfi_conversion_enabled = self:readSetting("cfi_conversion_enabled", DEFAULTS.cfi_conversion_enabled)
    self.last_web_bridge_result = nil

    self.plugin_dir = detectPluginDir()
    self.auto_update_enabled = self:readSetting("auto_update_enabled", DEFAULTS.auto_update_enabled)
    self.check_update_on_startup = self:readSetting("check_update_on_startup", DEFAULTS.check_update_on_startup)
    self.update_channel = normalizeUpdateChannel(self:readSetting("update_channel", DEFAULTS.update_channel))
    self.allow_prerelease_updates = self:readSetting("allow_prerelease_updates", DEFAULTS.allow_prerelease_updates)
    if self.allow_prerelease_updates then
        self.update_channel = "prerelease"
    else
        self.update_channel = normalizeUpdateChannel(self.update_channel)
        self.allow_prerelease_updates = self.update_channel == "prerelease"
    end
    self.update_repo = self:readSetting("update_repo", DEFAULTS.update_repo)
    if self.update_repo ~= DEFAULTS.update_repo then
        self.update_repo = DEFAULTS.update_repo
        self.db:savePluginSetting("update_repo", self.update_repo)
    end
    self.db:savePluginSetting("allow_prerelease_updates", self.allow_prerelease_updates)
    self.db:savePluginSetting("update_channel", self.update_channel)
    self.last_update_check = tonumber(self:readSetting("last_update_check", 0)) or 0
    self.update_available = false

    self.updater = Updater:new()
    self.updater:init(self.plugin_dir, self.db, {
        allow_prerelease = self.allow_prerelease_updates,
        update_repo = self.update_repo,
    })

    self.current_session = nil
    self.last_auto_sync_time = 0
    self.last_sync_summary = nil

    self._initialized = true
    self:logInfo("GrimmLink initialized")

    if FileManager and FileManager.addFileDialogButtons then
        FileManager.addFileDialogButtons(FileManager, "grimmlink_actions", function(file, is_file, _book_props)
            if not is_file then return nil end
            return self:wrapUiSpec({
                {
                    text = _("GrimmLink"),
                    callback = function()
                        local fc = FileManager.instance and FileManager.instance.file_chooser
                        if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                        self:showGrimmLinkFileDialog(file)
                    end,
                },
            }, "GrimmLink FileManager Menu")
        end)
        grimmlink_fm_patched = true
        self:logInfo("GrimmLink: FileManager integration installed")
    end

    if Dispatcher then
        self:registerDispatcherActions()
    end
end

function Grimmlink:readSetting(key, default_value)
    local value = self.db:getPluginSetting(key)
    if value == nil then
        self.db:savePluginSetting(key, default_value)
        return default_value
    end
    return value
end

function Grimmlink:saveSetting(key, value)
    if not self.db then
        if not self._initialized then
            return false
        end
        self:showMessage(_("GrimmLink is still starting up"), 2)
        return false
    end

    self.db:savePluginSetting(key, value)
    self[key] = value
    if key == "password" then
        self.auth_key = value
    end

    if key == "server_url" or key == "username" or key == "password" or key == "debug_logging" then
        if self.api and type(self.api.init) == "function" then
            self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
        end
    end

    if key == "log_to_file" then
        if value and not self.file_logger then
            if not self:ensureFileLogger() then
                self.file_logger = nil
            end
        elseif not value then
            self.file_logger = nil
        end
    end

    if key == "debug_logging" and value and not self.log_to_file then
        self.db:savePluginSetting("log_to_file", true)
        self.log_to_file = true
        if not self:ensureFileLogger() then
            self.file_logger = nil
            self:showMessage(_("Debug logging was enabled, but GrimmLink could not create the log file."), 5)
        else
            self:showMessage(T(_("Debug logging is enabled.\nLog file: %1"), self:getLogFilePath()), 5)
        end
    end

    if (key == "allow_prerelease_updates" or key == "update_repo") and self.updater then
        if key == "allow_prerelease_updates" then
            self.updater:setAllowPrerelease(value == true)
        else
            self.update_repo = DEFAULTS.update_repo
            self.db:savePluginSetting("update_repo", self.update_repo)
            self.updater.update_repo = self.update_repo
        end
    end

    return true
end

function Grimmlink:defaultDeviceName()
    local ok, device = pcall(require, "device")
    if ok and device then
        return device.model or device.name or DEFAULTS.device_name
    end
    return DEFAULTS.device_name
end

function Grimmlink:defaultDeviceId()
    local existing = self.db and self.db:getPluginSetting("device_id")
    if existing and existing ~= "" then
        return existing
    end

    local seed = table.concat({
        safeToString(DataStorage:getDataDir()),
        safeToString(DataStorage:getSettingsDir()),
        tostring(nowUtc()),
    }, "|")
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.md5 then
        local generated = "grimmlink-" .. sha2.md5(seed)
        self.db:savePluginSetting("device_id", generated)
        return generated
    end

    local fallback = string.format("grimmlink-%d", nowUtc())
    self.db:savePluginSetting("device_id", fallback)
    return fallback
end

function Grimmlink:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 3,
    })
end

function Grimmlink:refreshTouchMenu(touchmenu_instance)
    if touchmenu_instance then
        safeMethodCall(touchmenu_instance, "updateItems")
        safeMethodCall(touchmenu_instance, "updateItemTable")
        safeMethodCall(touchmenu_instance, "refresh")
    end

    if UIManager and type(UIManager.setDirty) == "function" then
        pcall(UIManager.setDirty, UIManager, nil, "ui")
    end
end

function Grimmlink:showTextInput(title, current_value, hint, secret, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = current_value or "",
        input_hint = hint or "",
        text_type = secret and "password" or nil,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        UIManager:close(dialog)
                        on_save(value)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        dialog:onShowKeyboard()
    end
end

function Grimmlink:showNumberInput(title, current_value, hint, on_save)
    self:showTextInput(title, tostring(current_value or ""), hint, false, function(value)
        local parsed = tonumber(value)
        if not parsed then
            self:showMessage(_("Please enter a valid number"), 2)
            return
        end
        on_save(parsed)
    end)
end

function Grimmlink:configureServerUrl()
    self:showTextInput(_("Grimmory Server URL"), self.server_url, "http://192.168.1.100:6060", false, function(value)
        local normalized = safeToString(value):gsub("/$", "")
        self:saveSetting("server_url", normalized)
        self:showMessage(_("Server URL saved"), 2)
    end)
end

function Grimmlink:configureUsername()
    self:showTextInput(_("KOReader Username"), self.username, _("Enter username"), false, function(value)
        self:saveSetting("username", safeToString(value))
        self:showMessage(_("Username saved"), 2)
    end)
end

function Grimmlink:configurePassword()
    self:showTextInput(_("Password"), self.auth_key, _("Enter Grimmory password"), true, function(value)
        self:saveSetting("password", safeToString(value))
        self:showMessage(_("Password saved"), 2)
    end)
end

function Grimmlink:promptTestConnectionAfterSetup()
    local confirm_spec = self:wrapUiSpec({
        text = _("Connection settings saved.\n\nTest connection now?"),
        ok_text = _("Test now"),
        ok_callback = function()
            self:testConnection()
        end,
        cancel_text = _("Later"),
    }, "GrimmLink Test Connection After Setup")
    UIManager:show(ConfirmBox:new(confirm_spec))
end

function Grimmlink:saveConnectionSettings(server_url, username, password)
    local normalized_url = safeToString(server_url):gsub("/$", "")
    self:saveSetting("server_url", normalized_url)
    self:saveSetting("username", safeToString(username))
    self:saveSetting("password", safeToString(password))
    self:promptTestConnectionAfterSetup()
end

function Grimmlink:configureConnection()
    local pending = {
        server_url = self.server_url or "",
        username = self.username or "",
        password = self.auth_key or "",
    }

    self:showTextInput(_("Grimmory Server URL"), pending.server_url, "http://192.168.1.100:6060", false, function(server_url)
        pending.server_url = safeToString(server_url)
        self:showTextInput(_("KOReader Username"), pending.username, _("Enter username"), false, function(username)
            pending.username = safeToString(username)
            self:showTextInput(_("Password"), pending.password, _("Enter Grimmory password"), true, function(password)
                pending.password = safeToString(password)
                self:saveConnectionSettings(pending.server_url, pending.username, pending.password)
            end)
        end)
    end)
end

function Grimmlink:configureDeviceName()
    self:showTextInput(_("Device Name"), self.device_name, _("Enter device name"), false, function(value)
        local normalized = safeToString(value)
        if normalized == "" then
            normalized = self:defaultDeviceName()
        end
        self:saveSetting("device_name", normalized)
        self:showMessage(_("Device name saved"), 2)
    end)
end

function Grimmlink:configureDeviceId()
    self:showTextInput(_("Device ID"), self.device_id, _("Enter stable device ID"), false, function(value)
        local normalized = safeToString(value)
        if normalized == "" then
            normalized = self:defaultDeviceId()
        end
        self:saveSetting("device_id", normalized)
        self:showMessage(_("Device ID saved"), 2)
    end)
end

function Grimmlink:testConnection()
    if not self:requireReady({ require_api = true }) then
        return
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)

    local success, response = self.api:testAuth()
    if success then
        self:showMessage(_("GrimmLink connection successful"), 3)
        self:logInfo("GrimmLink test connection succeeded")
        return
    end

    self:showMessage(T(_("Connection failed:\n%1"), safeToString(response)), 5)
    self:logWarn("GrimmLink test connection failed:", response)
end

function Grimmlink:isOnline()
    if NetworkMgr and type(NetworkMgr.isConnected) == "function" then
        local ok, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
        return ok and connected and true or false
    end
    if NetworkMgr and type(NetworkMgr.isOnline) == "function" then
        local ok, connected = pcall(NetworkMgr.isOnline, NetworkMgr)
        return ok and connected and true or false
    end
    return false
end

function Grimmlink:formatDuration(duration_seconds)
    local value = tonumber(duration_seconds)
    if not value or value <= 0 then
        return _("0s")
    end

    local hours = math.floor(value / 3600)
    local minutes = math.floor((value % 3600) / 60)
    local seconds = value % 60
    local parts = {}

    if hours > 0 then
        parts[#parts + 1] = T(_("%1h"), hours)
    end
    if minutes > 0 then
        parts[#parts + 1] = T(_("%1m"), minutes)
    end
    if seconds > 0 or #parts == 0 then
        parts[#parts + 1] = T(_("%1s"), seconds)
    end

    return table.concat(parts, " ")
end

function Grimmlink:getBookType(file_path)
    local extension = safeToString(file_path):match("^.+%.(.+)$")
    if not extension then
        return "EPUB"
    end

    extension = extension:upper()
    if extension == "PDF" then
        return "PDF"
    end
    if extension == "CBZ" or extension == "CBR" then
        return "CBX"
    end
    return "EPUB"
end

function Grimmlink:calculateBookHash(file_path)
    local file = io.open(file_path, "rb")
    if not file then
        self:logWarn("GrimmLink: unable to open file for hashing", file_path)
        return nil
    end

    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or not sha2 or not sha2.md5 then
        file:close()
        self:logErr("GrimmLink: ffi/sha2.md5 unavailable")
        return nil
    end

    local file_size = file:seek("end")
    file:seek("set", 0)

    local base = 1024
    local block_size = 1024
    local chunks = {}

    for i = -1, 10 do
        local position = bit.lshift(base, 2 * i)
        if position >= file_size then
            break
        end

        file:seek("set", position)
        local chunk = file:read(block_size)
        if chunk then
            chunks[#chunks + 1] = chunk
        end
    end

    file:close()
    return sha2.md5(table.concat(chunks))
end

function Grimmlink:getCurrentPageInfo()
    local document = self.ui and self.ui.document or nil
    if not document then
        return nil, nil
    end

    local current_page = nil
    if self.view and self.view.state and self.view.state.page then
        current_page = tonumber(self.view.state.page)
    end

    if current_page == nil and self.ui and self.ui.paging then
        current_page = safeMethodCall(self.ui.paging, "getCurrentPage")
    end

    if current_page == nil then
        current_page = safeMethodCall(document, "getCurrentPage")
    end

    local total_pages = safeMethodCall(document, "getPageCount")
    current_page = maybeNumber(current_page)
    total_pages = maybeNumber(total_pages)

    return current_page, total_pages
end

function Grimmlink:getCurrentProgressSnapshot(file_hash, file_path, book_id)
    local current_page, total_pages = self:getCurrentPageInfo()
    local raw_location = nil
    local document = self.ui and self.ui.document or nil

    if document then
        -- Prefer XPointer for EPUB (needed for CFI conversion); fall back to numeric pos
        local xpointer = safeMethodCall(document, "getXPointer")
        if xpointer and tostring(xpointer):sub(1, 1) == "/" then
            raw_location = xpointer
        else
            raw_location = safeMethodCall(document, "getCurrentPos")
            if raw_location == nil then
                raw_location = safeMethodCall(document, "getCurrentLocation")
            end
            if raw_location == nil then
                raw_location = xpointer
            end
        end
    end

    if raw_location == nil and self.ui and self.ui.doc_settings then
        raw_location = tryReadSetting(self.ui.doc_settings, "last_xpointer")
    end

    if raw_location == nil then
        raw_location = current_page or 0
    end

    local percentage = nil
    if current_page and total_pages and total_pages > 0 then
        percentage = normalizePercent((current_page / total_pages) * 100)
    end

    local snapshot = {
        timestamp = nowUtc(),
        document = file_hash or file_path,
        bookHash = file_hash,
        bookId = book_id,
        fileFormat = self:getBookType(file_path),
        progress = safeToString(raw_location),
        location = safeToString(raw_location),
        percentage = percentage,
        currentPage = current_page,
        totalPages = total_pages,
        device = self.device_name,
        deviceId = self.device_id,
        file_path = file_path,
        current_page = current_page,
        total_pages = total_pages,
    }

    if snapshot.progress == "" and snapshot.currentPage then
        snapshot.progress = tostring(snapshot.currentPage)
    end
    if snapshot.location == "" and snapshot.progress ~= "" then
        snapshot.location = snapshot.progress
    end

    return snapshot
end

function Grimmlink:normalizeRemoteProgress(remote_progress)
    if not remote_progress or type(remote_progress) ~= "table" then
        return nil
    end

    local normalized = cloneTable(remote_progress)
    normalized.bookHash = normalized.bookHash or normalized.document
    normalized.percentage = normalizePercent(normalized.percentage)
    normalized.currentPage = maybeNumber(normalized.currentPage)
    normalized.totalPages = maybeNumber(normalized.totalPages)
    normalized.timestamp = maybeNumber(normalized.timestamp)
    normalized.deviceId = normalized.deviceId or normalized.device_id
    normalized.location = isNonEmpty(normalized.location) and tostring(normalized.location)
        or (isNonEmpty(normalized.progress) and tostring(normalized.progress) or nil)
    normalized.progress = isNonEmpty(normalized.progress) and tostring(normalized.progress)
        or normalized.location
    return normalized
end

function Grimmlink:looksLikeXPointer(value)
    return isNonEmpty(value) and tostring(value):sub(1, 1) == "/"
end

function Grimmlink:documentHasPages()
    local document_info = self.ui and self.ui.document and self.ui.document.info
    if document_info and document_info.has_pages ~= nil then
        return document_info.has_pages and true or false
    end

    return self.ui and self.ui.paging ~= nil or false
end

function Grimmlink:normalizeWebBridgeProgress(remote_progress)
    if not remote_progress or type(remote_progress) ~= "table" then
        return nil
    end

    local normalized = self:normalizeRemoteProgress(remote_progress) or cloneTable(remote_progress)
    normalized.bookFileId = maybeNumber(remote_progress.bookFileId)
    normalized.epubCfi = remote_progress.epubCfi
    normalized.positionHref = remote_progress.positionHref
    normalized.contentSourceProgressPercent = normalizePercent(remote_progress.contentSourceProgressPercent)
    normalized.updatedAt = maybeNumber(remote_progress.timestamp)
    normalized.source = remote_progress.source or "WEB_READER"
    normalized.device = remote_progress.device or "Web Reader"
    normalized.deviceId = remote_progress.deviceId or remote_progress.device_id or "web-reader"
    normalized.conversionStatus = remote_progress.conversionStatus
    normalized.conversionConfidence = maybeNumber(remote_progress.conversionConfidence)
    normalized.currentPage = maybeNumber(remote_progress.currentPage)
    normalized.totalPages = maybeNumber(remote_progress.totalPages)
    return normalized
end

function Grimmlink:hasMeaningfulProgress(snapshot)
    return (snapshot and (
        snapshot.percentage ~= nil
        or isNonEmpty(snapshot.location)
        or isNonEmpty(snapshot.progress)
        or snapshot.currentPage ~= nil
    )) and true or false
end

function Grimmlink:progressDifferenceExceeded(left, right)
    if not left or not right then
        return false
    end

    local percent_delta = absDifference(left.percentage, right.percentage) or 0
    if percent_delta >= (tonumber(self.threshold_percent) or DEFAULTS.threshold_percent) then
        return true
    end

    if left.currentPage ~= nil and right.currentPage ~= nil then
        local page_delta = math.abs((tonumber(left.currentPage) or 0) - (tonumber(right.currentPage) or 0))
        if page_delta >= (tonumber(self.threshold_pages) or DEFAULTS.threshold_pages) then
            return true
        end
    end

    if isNonEmpty(left.location) and isNonEmpty(right.location) and tostring(left.location) ~= tostring(right.location) then
        return true
    end

    return false
end

function Grimmlink:buildStoredLocalSnapshot(state)
    if not state then
        return nil
    end
    return {
        progress = state.local_progress,
        location = state.local_location,
        percentage = state.local_percentage,
        currentPage = state.local_current_page,
        totalPages = state.local_total_pages,
        timestamp = state.local_timestamp,
    }
end

function Grimmlink:buildStoredRemoteSnapshot(state)
    if not state then
        return nil
    end
    return {
        progress = state.remote_progress,
        location = state.remote_location,
        percentage = state.remote_percentage,
        currentPage = state.remote_current_page,
        totalPages = state.remote_total_pages,
        timestamp = state.remote_timestamp,
        device = state.remote_device,
        deviceId = state.remote_device_id,
    }
end

function Grimmlink:compareOpenProgress(local_snapshot, remote_snapshot, state)
    if not self:hasMeaningfulProgress(remote_snapshot) then
        return "none"
    end

    local previous_local = self:buildStoredLocalSnapshot(state)
    local previous_remote = self:buildStoredRemoteSnapshot(state)
    local remote_is_significantly_different = self:progressDifferenceExceeded(local_snapshot, remote_snapshot)

    if not previous_local and not previous_remote then
        if not remote_is_significantly_different then
            return "same"
        end
        return "remote_newer"
    end

    local local_changed = previous_local
        and self:progressDifferenceExceeded(local_snapshot, previous_local)
        or (not previous_local and self:hasMeaningfulProgress(local_snapshot))
    local remote_changed = previous_remote
        and self:progressDifferenceExceeded(remote_snapshot, previous_remote)
        or (not previous_remote and self:hasMeaningfulProgress(remote_snapshot))

    if not remote_is_significantly_different then
        return "same"
    end

    if local_changed and remote_changed then
        return "conflict"
    end

    if remote_changed and not local_changed then
        return "remote_newer"
    end

    if local_changed and not remote_changed then
        return "local_newer"
    end

    if (remote_snapshot.timestamp or 0) > (local_snapshot.timestamp or 0) then
        return "remote_newer"
    end

    return "local_newer"
end

function Grimmlink:rememberLocalSnapshot(file_hash, snapshot, action)
    if not file_hash or not snapshot then
        return
    end

    self.db:upsertLocalProgressState(file_hash, {
        file_path = snapshot.file_path,
        book_id = snapshot.bookId,
        document = snapshot.document,
        file_format = snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        current_page = snapshot.currentPage,
        total_pages = snapshot.totalPages,
        timestamp = snapshot.timestamp,
        last_action = action,
    })
end

function Grimmlink:rememberRemoteSnapshot(file_hash, snapshot, action)
    if not file_hash or not snapshot then
        return
    end

    self.db:upsertRemoteProgressState(file_hash, {
        file_path = snapshot.file_path,
        book_id = snapshot.bookId,
        document = snapshot.document,
        file_format = snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        current_page = snapshot.currentPage,
        total_pages = snapshot.totalPages,
        device = snapshot.device,
        device_id = snapshot.deviceId or snapshot.device_id,
        timestamp = snapshot.timestamp,
        last_action = action,
    })
end

function Grimmlink:rememberLocalWebBridgeSnapshot(file_hash, snapshot, action)
    if not file_hash or not snapshot then
        return
    end

    self.db:upsertLocalWebBridgeState(file_hash, {
        file_path = snapshot.file_path,
        book_id = snapshot.bookId,
        document = snapshot.document,
        file_format = snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        current_page = snapshot.currentPage,
        total_pages = snapshot.totalPages,
        timestamp = snapshot.timestamp,
        last_action = action,
    })
end

function Grimmlink:rememberRemoteWebBridgeSnapshot(file_hash, snapshot, action)
    if not file_hash or not snapshot then
        return
    end

    self.db:upsertRemoteWebBridgeState(file_hash, {
        file_path = snapshot.file_path,
        book_id = snapshot.bookId,
        document = snapshot.document,
        file_format = snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        current_page = snapshot.currentPage,
        total_pages = snapshot.totalPages,
        timestamp = snapshot.timestamp,
        remote_updated_at = snapshot.updatedAt or snapshot.timestamp,
        remote_epub_cfi = snapshot.epubCfi,
        remote_position_href = snapshot.positionHref,
        remote_content_source_progress_percent = snapshot.contentSourceProgressPercent,
        remote_source = snapshot.source,
        device = snapshot.device,
        device_id = snapshot.deviceId or snapshot.device_id,
        last_action = action,
    })
end

function Grimmlink:buildStoredRemoteWebBridgeSnapshot(state)
    if not state then
        return nil
    end
    return {
        progress = state.remote_progress,
        location = state.remote_location,
        percentage = state.remote_percentage,
        currentPage = state.remote_current_page,
        totalPages = state.remote_total_pages,
        timestamp = state.remote_timestamp or state.remote_updated_at,
        updatedAt = state.remote_updated_at,
        epubCfi = state.remote_epub_cfi,
        positionHref = state.remote_position_href,
        contentSourceProgressPercent = state.remote_content_source_progress_percent,
        source = state.remote_source,
        device = state.remote_device,
        deviceId = state.remote_device_id,
    }
end

function Grimmlink:buildWebBridgeConflictDialogText(local_snapshot, remote_snapshot)
    local local_percent = local_snapshot.percentage and string.format("%.1f%%", local_snapshot.percentage) or _("unknown")
    local remote_percent = remote_snapshot.percentage and string.format("%.1f%%", remote_snapshot.percentage) or _("unknown")
    local local_page = local_snapshot.currentPage and local_snapshot.totalPages
        and string.format("%s / %s", local_snapshot.currentPage, local_snapshot.totalPages)
        or _("unknown")
    local remote_page = remote_snapshot.currentPage and remote_snapshot.totalPages
        and string.format("%s / %s", remote_snapshot.currentPage, remote_snapshot.totalPages)
        or _("unknown")

    return table.concat({
        _("Found different Web Reader and KOReader positions"),
        "",
        _("KOReader:"),
        T(_("- progress: %1"), local_percent),
        T(_("- page: %1"), local_page),
        T(_("- updated: %1"), formatTimestamp(local_snapshot.timestamp)),
        "",
        _("Web Reader:"),
        T(_("- progress: %1"), remote_percent),
        T(_("- page: %1"), remote_page),
        T(_("- updated: %1"), formatTimestamp(remote_snapshot.updatedAt or remote_snapshot.timestamp)),
        T(_("- source: %1"), remote_snapshot.source or _("Web Reader")),
        T(_("- conversion: %1"), remote_snapshot.conversionStatus or _("unknown")),
    }, "\n")
end

function Grimmlink:jumpToPage(page_number)
    local page = tonumber(page_number)
    if not page then
        return false
    end

    local function pageReached(expected_page)
        local current_page = select(1, self:getCurrentPageInfo())
        if current_page == nil then
            return false
        end
        return math.abs((tonumber(current_page) or 0) - expected_page) <= 1
    end

    if pageReached(page) then
        self:logDbg("GrimmLink jumpToPage already at target", page)
        return true
    end

    local candidates = {
        { self.ui and self.ui.paging, "onGotoPage" },
        { self.ui and self.ui.paging, "gotoPage" },
        { self.ui and self.ui.paging, "goToPage" },
        { self.ui, "onGotoPage" },
        { self.ui and self.ui.document, "gotoPage" },
        { self.ui and self.ui.document, "goToPage" },
        { self.ui and self.ui.rolling, "gotoPage" },
        { self.ui and self.ui.rolling, "goToPage" },
    }

    local page_values = { page }
    if page > 1 then
        page_values[#page_values + 1] = page - 1
    end

    for _, target_page in ipairs(page_values) do
        safeMethodCall(self.ui and self.ui.link, "addCurrentLocationToStack")
        local event_result, event_ok = safeDispatchEvent(self.ui, "GotoPage", target_page)
        if event_ok and event_result ~= false and pageReached(page) then
            self:logDbg("GrimmLink jumpToPage succeeded via event", "GotoPage", "target:", target_page, "resolved:", page)
            return true
        end

        for _, candidate in ipairs(candidates) do
            local result, ok = safeMethodCall(candidate[1], candidate[2], target_page)
            if ok and result ~= false and pageReached(page) then
                self:logDbg("GrimmLink jumpToPage succeeded via", candidate[2], "target:", target_page, "resolved:", page)
                return true
            end
        end
    end

    self:logWarn("GrimmLink jumpToPage failed for target page", page)
    return false
end

function Grimmlink:jumpToLocation(location)
    if location == nil or tostring(location) == "" then
        return false
    end

    local numeric_page = tonumber(location)
    if numeric_page then
        return self:jumpToPage(numeric_page)
    end

    safeMethodCall(self.ui and self.ui.link, "addCurrentLocationToStack")
    local event_result, event_ok = safeDispatchEvent(self.ui, "GotoXPointer", tostring(location))
    if event_ok and event_result ~= false then
        return true
    end

    local candidates = {
        { self.ui and self.ui.document, "gotoPos" },
        { self.ui and self.ui.document, "gotoPosition" },
        { self.ui and self.ui.document, "gotoXPointer" },
        { self.ui and self.ui.rolling, "gotoPos" },
        { self.ui and self.ui.rolling, "gotoPosition" },
        { self.ui and self.ui.rolling, "gotoXPointer" },
    }

    for _, candidate in ipairs(candidates) do
        local result, ok = safeMethodCall(candidate[1], candidate[2], tostring(location))
        if ok and result ~= false then
            return true
        end
    end

    return false
end

function Grimmlink:getRemotePageTarget(remote_snapshot)
    if not remote_snapshot then
        return nil
    end

    if remote_snapshot.currentPage then
        return tonumber(remote_snapshot.currentPage)
    end

    local numeric_progress = isNonEmpty(remote_snapshot.progress) and tonumber(remote_snapshot.progress) or nil
    if numeric_progress then
        return numeric_progress
    end

    local numeric_location = isNonEmpty(remote_snapshot.location) and tonumber(remote_snapshot.location) or nil
    if numeric_location then
        return numeric_location
    end

    return nil
end

function Grimmlink:applyRemoteProgress(remote_snapshot)
    if not remote_snapshot then
        return false
    end

    local is_paged_document = self:documentHasPages()
    local target_page = self:getRemotePageTarget(remote_snapshot)

    -- Match KOSync for paged documents such as PDFs: page number wins.
    if is_paged_document and target_page and self:jumpToPage(target_page) then
        return true
    end

    if isNonEmpty(remote_snapshot.location)
        and (not is_paged_document or self:looksLikeXPointer(remote_snapshot.location))
        and self:jumpToLocation(remote_snapshot.location)
    then
        return true
    end

    if remote_snapshot.currentPage and self:jumpToPage(remote_snapshot.currentPage) then
        return true
    end

    local _, total_pages = self:getCurrentPageInfo()
    if remote_snapshot.percentage and total_pages and total_pages > 0 then
        local target_page = math.max(1, math.floor((total_pages * remote_snapshot.percentage / 100) + 0.5))
        if self:jumpToPage(target_page) then
            return true
        end
    end

    return false
end

function Grimmlink:buildConflictDialogText(local_snapshot, remote_snapshot)
    local local_percent = local_snapshot.percentage and string.format("%.1f%%", local_snapshot.percentage) or _("unknown")
    local remote_percent = remote_snapshot.percentage and string.format("%.1f%%", remote_snapshot.percentage) or _("unknown")
    local local_page = local_snapshot.currentPage and local_snapshot.totalPages
        and string.format("%s / %s", local_snapshot.currentPage, local_snapshot.totalPages)
        or _("unknown")
    local remote_page = remote_snapshot.currentPage and remote_snapshot.totalPages
        and string.format("%s / %s", remote_snapshot.currentPage, remote_snapshot.totalPages)
        or _("unknown")

    return table.concat({
        _("Found different reading positions"),
        "",
        _("Local:"),
        T(_("- progress: %1"), local_percent),
        T(_("- page: %1"), local_page),
        T(_("- updated: %1"), formatTimestamp(local_snapshot.timestamp)),
        "",
        _("Remote:"),
        T(_("- progress: %1"), remote_percent),
        T(_("- page: %1"), remote_page),
        T(_("- updated: %1"), formatTimestamp(remote_snapshot.timestamp)),
        T(_("- device: %1"), remote_snapshot.device or _("unknown")),
    }, "\n")
end

function Grimmlink:resolveLocalChoice(file_hash, local_snapshot, silent)
    self:rememberLocalSnapshot(file_hash, local_snapshot, "conflict-use-local")
    self:pushProgressSnapshot(local_snapshot, "conflict-use-local", silent)
end

function Grimmlink:getExpectedRemotePage(remote_snapshot)
    if not remote_snapshot then
        return nil
    end

    local explicit_page = self:getRemotePageTarget(remote_snapshot)
    if explicit_page then
        return explicit_page
    end

    local _, total_pages = self:getCurrentPageInfo()
    local resolved_total_pages = tonumber(remote_snapshot.totalPages) or tonumber(total_pages)
    if remote_snapshot.percentage and resolved_total_pages and resolved_total_pages > 0 then
        return math.max(1, math.floor((resolved_total_pages * remote_snapshot.percentage / 100) + 0.5))
    end

    return nil
end

function Grimmlink:isRemoteProgressApplied(remote_snapshot)
    local expected_page = self:getExpectedRemotePage(remote_snapshot)
    if expected_page then
        local current_page = select(1, self:getCurrentPageInfo())
        if current_page ~= nil and math.abs((tonumber(current_page) or 0) - expected_page) <= 1 then
            return true
        end
    end

    if self.ui and self.ui.document and self.ui.document.file and (isNonEmpty(remote_snapshot.location) or isNonEmpty(remote_snapshot.progress)) then
        local current_snapshot = self:getCurrentProgressSnapshot(
            remote_snapshot.bookHash,
            tostring(self.ui.document.file),
            remote_snapshot.bookId
        )
        if current_snapshot then
            local current_location = isNonEmpty(current_snapshot.location) and tostring(current_snapshot.location) or nil
            local current_progress = isNonEmpty(current_snapshot.progress) and tostring(current_snapshot.progress) or nil
            local target_location = isNonEmpty(remote_snapshot.location) and tostring(remote_snapshot.location) or nil
            local target_progress = isNonEmpty(remote_snapshot.progress) and tostring(remote_snapshot.progress) or nil
            if (target_location and current_location == target_location)
                or (target_progress and current_progress == target_progress)
            then
                return true
            end
        end
    end

    return false
end

function Grimmlink:requestReaderRefresh()
    -- KOReader handles its own repaint after GotoXPointer/GotoPage events.
    -- Calling internal rendering methods (redrawCurrentView, updatePos,
    -- updatePageInfo) directly from a plugin can trigger C-level crashes
    -- (SIGSEGV) when the document is mid-navigation. Only schedule a soft
    -- setDirty hint; do not poke the rendering pipeline directly.
    if UIManager and type(UIManager.setDirty) == "function" then
        pcall(UIManager.setDirty, UIManager, nil, "ui")
    end
end

function Grimmlink:runAfterUiSettles(callback)
    if type(callback) ~= "function" then
        return
    end

    if UIManager and type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(0.05, callback)
    else
        callback()
    end
end

function Grimmlink:applyAndFinalizeRemoteProgress(file_hash, remote_snapshot, success_message, failure_message, success_action, failure_action)
    self:runAfterUiSettles(function()
        self:invokeSafely("apply remote progress", function()
            local jumped = self:applyRemoteProgress(remote_snapshot)
            if jumped then
                self:finalizeRemoteJump(
                    file_hash,
                    remote_snapshot,
                    success_message,
                    failure_message,
                    success_action,
                    failure_action
                )
            else
                if failure_action then
                    failure_action(remote_snapshot)
                end
                self:showMessage(failure_message, 4)
            end
        end)
    end)
end

function Grimmlink:finalizeRemoteJump(file_hash, remote_snapshot, success_message, failure_message, success_action, failure_action)
    local verify = function()
        if self:isRemoteProgressApplied(remote_snapshot) then
            local applied_snapshot = remote_snapshot
            if self.ui and self.ui.document and self.ui.document.file then
                applied_snapshot = self:getCurrentProgressSnapshot(
                    file_hash or remote_snapshot.bookHash,
                    tostring(self.ui.document.file),
                    remote_snapshot.bookId
                ) or remote_snapshot
            end
            applied_snapshot.bookHash = applied_snapshot.bookHash or file_hash or remote_snapshot.bookHash
            applied_snapshot.bookId = applied_snapshot.bookId or remote_snapshot.bookId
            applied_snapshot.timestamp = nowUtc()
            if success_action then
                success_action(applied_snapshot)
            end
            self:showMessage(success_message, 2)
        else
            if failure_action then
                failure_action(remote_snapshot)
            end
            self:showMessage(failure_message, 4)
        end
    end

    self:requestReaderRefresh()
    if UIManager and type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(0.2, function()
            self:invokeSafely("finalize jump verify", verify)
        end)
    else
        self:invokeSafely("finalize jump verify", verify)
    end
end

function Grimmlink:resolveRemoteChoice(file_hash, remote_snapshot)
    self:applyAndFinalizeRemoteProgress(
        file_hash,
        remote_snapshot,
        _("Jumped to remote progress"),
        _("Remote progress found, but safe jump was not possible"),
        function(applied_snapshot)
            self:logProgressEvent("info", "remote progress applied", self:buildProgressDebugFields(applied_snapshot, {
                bookHash = file_hash,
                source = "koreader",
                direction = "pull",
                apiStatus = "ok",
                apiErrorClass = "none",
                action = "remote_newer",
            }))
            self:rememberLocalSnapshot(file_hash, applied_snapshot, "conflict-use-remote")
        end,
        function(failed_snapshot)
            self:rememberRemoteSnapshot(file_hash, failed_snapshot, "remote-jump-unsafe")
        end
    )
end

function Grimmlink:beginConflictDialog(kind)
    if self._conflict_dialog_open then
        self:logInfo("GrimmLink skipping", kind, "dialog because another conflict dialog is already open")
        return false
    end
    self._conflict_dialog_open = kind or true
    return true
end

function Grimmlink:endConflictDialog()
    self._conflict_dialog_open = nil
end

function Grimmlink:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, mode)
    if not self:beginConflictDialog("progress") then
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = self:buildConflictDialogText(local_snapshot, remote_snapshot),
        buttons = {
            {
                {
                    text = _("Use Local"),
                    callback = function()
                        self:invokeSafely("conflict use-local", function()
                            self:endConflictDialog()
                            UIManager:close(dialog)
                            self:logInfo("GrimmLink conflict decision: Use Local")
                            self:resolveLocalChoice(file_hash, local_snapshot, true)
                        end)
                    end,
                },
                {
                    text = _("Use Remote"),
                    callback = function()
                        self:invokeSafely("conflict use-remote", function()
                            self:endConflictDialog()
                            UIManager:close(dialog)
                            self:logInfo("GrimmLink conflict decision: Use Remote")
                            self:resolveRemoteChoice(file_hash, remote_snapshot)
                        end)
                    end,
                },
                {
                    text = _("Ignore"),
                    callback = function()
                        self:invokeSafely("conflict ignore", function()
                            self:endConflictDialog()
                            UIManager:close(dialog)
                            self:logInfo("GrimmLink conflict decision: Ignore")
                            self:rememberRemoteSnapshot(file_hash, remote_snapshot, mode == "remote_newer" and "remote-ignored" or "conflict-ignored")
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Grimmlink:prepareProgressPayload(snapshot)
    return {
        timestamp = snapshot.timestamp,
        document = snapshot.document,
        bookHash = snapshot.bookHash,
        bookId = snapshot.bookId,
        percentage = snapshot.percentage,
        progress = snapshot.progress,
        location = snapshot.location,
        fileFormat = snapshot.fileFormat,
        currentPage = snapshot.currentPage,
        totalPages = snapshot.totalPages,
        device = snapshot.device,
        deviceId = snapshot.deviceId,
    }
end

function Grimmlink:queueProgressSnapshot(snapshot)
    if not self.offline_queue_enabled or not snapshot or not snapshot.bookHash then
        return false
    end
    if self:isHashMarkedNotFound(snapshot.bookHash) then
        return false
    end

    local ok, encoded = pcall(json.encode, self:prepareProgressPayload(snapshot))
    if not ok then
        self:logErr("GrimmLink failed to encode pending progress payload")
        return false
    end
    self.db:upsertPendingProgress(snapshot.bookHash, encoded)
    self:logProgressEvent("info", "progress queued", self:buildProgressDebugFields(snapshot, {
        direction = "push",
        source = "koreader",
        apiStatus = "queued",
        apiErrorClass = "offline_queue",
    }))
    self:logInfo("GrimmLink queued progress for hash", snapshot.bookHash)
    return true
end

function Grimmlink:pushProgressSnapshot(snapshot, reason, silent)
    if not snapshot or not snapshot.bookHash then
        return false
    end
    if self:isHashMarkedNotFound(snapshot.bookHash) then
        return false
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)

    if not self:isOnline() then
        self:logProgressEvent("warn", "progress push offline", self:buildProgressDebugFields(snapshot, {
            direction = "push",
            source = "koreader",
            apiStatus = "offline",
            apiErrorClass = "transient_network",
            reason = "offline",
        }))
        self:queueProgressSnapshot(snapshot)
        if not silent then
            self:showMessage(_("Saved progress to offline queue"), 2)
        end
        return false
    end

    local success, response, code = self.api:updateProgress(self:prepareProgressPayload(snapshot))
    if success then
        self:rememberLocalSnapshot(snapshot.bookHash, snapshot, reason or "progress-push")
        self:rememberRemoteSnapshot(snapshot.bookHash, snapshot, reason or "progress-push")
        self.db:setProgressLastAction(snapshot.bookHash, reason or "progress-push")
        self:logProgressEvent("info", "progress push ok", self:buildProgressDebugFields(snapshot, {
            direction = "push",
            source = "koreader",
            apiStatus = "ok",
            apiErrorClass = "none",
            action = reason or "progress-push",
        }))
        self:logInfo("GrimmLink pushed progress for hash", snapshot.bookHash)
        return true
    end

    local api_status, api_error_class = self:classifyApiOutcome(code, response)
    self:logProgressEvent("warn", "progress push failed", self:buildProgressDebugFields(snapshot, {
        direction = "push",
        source = "koreader",
        apiStatus = api_status,
        apiErrorClass = api_error_class,
        reason = safeToString(response),
        action = reason or "progress-push",
    }))
    self:logWarn("GrimmLink progress push failed:", response)
    if api_error_class == "permanent_not_found" then
        self:recordNotFoundHash({
            file_hash = snapshot.bookHash,
            book_id = snapshot.bookId,
            file_path = snapshot.file_path,
            file_format = snapshot.fileFormat,
            source = "koreader",
            reason = safeToString(response),
        })
    else
        self:queueProgressSnapshot(snapshot)
    end
    if not silent then
        self:showMessage(T(_("Progress sync failed:\n%1"), safeToString(response)), 4)
    end
    return false
end

function Grimmlink:syncPendingProgress(silent)
    local synced = 0
    local failed = 0

    if not self:isOnline() then
        return synced, failed
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    local pending = self.db:getPendingProgress(100)
    local retry_cap = 20
    local base_backoff_seconds = 30
    local max_backoff_seconds = 60 * 60
    local now = nowUtc()

    local function retryDelaySeconds(retry_count)
        local count = tonumber(retry_count) or 0
        local delay = base_backoff_seconds * (2 ^ math.min(count, 5))
        if delay > max_backoff_seconds then
            delay = max_backoff_seconds
        end
        return delay
    end

    for _, item in ipairs(pending) do
        if self:isHashMarkedNotFound(item.file_hash) then
            self.db:deletePendingProgress(item.id)
            self:logProgressEvent("warn", "pending progress dropped", self:buildProgressDebugFields({
                bookHash = item.file_hash,
            }, {
                direction = "push",
                source = "koreader",
                apiStatus = "http_404",
                apiErrorClass = "permanent_not_found",
                retryCount = item.retry_count,
                reason = "book not found",
            }))
            failed = failed + 1
        elseif (tonumber(item.retry_count) or 0) >= retry_cap then
            self:logProgressEvent("warn", "pending progress retry cap reached", self:buildProgressDebugFields({
                bookHash = item.file_hash,
            }, {
                direction = "push",
                source = "koreader",
                apiStatus = "retry_cap",
                apiErrorClass = "transient_retry_cap",
                retryCount = item.retry_count,
            }))
        elseif item.last_retry_at and (now - tonumber(item.last_retry_at)) < retryDelaySeconds(item.retry_count) then
            self:logProgressEvent("dbg", "pending progress backoff", self:buildProgressDebugFields({
                bookHash = item.file_hash,
            }, {
                direction = "push",
                source = "koreader",
                apiStatus = "backoff",
                apiErrorClass = "transient_backoff",
                retryCount = item.retry_count,
            }))
        else
            local ok, payload = pcall(json.decode, item.payload_json)
            if ok and type(payload) == "table" then
                self:logProgressEvent("dbg", "pending progress item", self:buildProgressDebugFields(payload, {
                    direction = "push",
                    source = "koreader",
                    apiStatus = "pending",
                    retryCount = item.retry_count,
                }))
            end
            if not ok or type(payload) ~= "table" then
                self.db:deletePendingProgress(item.id)
                failed = failed + 1
            else
                local success, response, code = self.api:updateProgress(payload)
                if success then
                    self.db:deletePendingProgress(item.id)
                    self:rememberLocalSnapshot(item.file_hash, {
                        file_path = nil,
                        bookId = payload.bookId,
                        document = payload.document,
                        fileFormat = payload.fileFormat,
                        progress = payload.progress,
                        location = payload.location,
                        percentage = normalizePercent(payload.percentage),
                        currentPage = payload.currentPage,
                        totalPages = payload.totalPages,
                        timestamp = payload.timestamp or nowUtc(),
                    }, "queued-progress-pushed")
                    self:rememberRemoteSnapshot(item.file_hash, {
                        bookId = payload.bookId,
                        document = payload.document,
                        fileFormat = payload.fileFormat,
                        progress = payload.progress,
                        location = payload.location,
                        percentage = normalizePercent(payload.percentage),
                        currentPage = payload.currentPage,
                        totalPages = payload.totalPages,
                        device = payload.device,
                        deviceId = payload.deviceId or payload.device_id,
                        timestamp = payload.timestamp or nowUtc(),
                    }, "queued-progress-pushed")
                    self:logProgressEvent("info", "pending progress push ok", self:buildProgressDebugFields(payload, {
                        direction = "push",
                        source = "koreader",
                        apiStatus = "ok",
                        apiErrorClass = "none",
                        retryCount = item.retry_count,
                    }))
                    synced = synced + 1
                else
                    local api_status, api_error_class = self:classifyApiOutcome(code, response)
                    self:logProgressEvent("warn", "pending progress push failed", self:buildProgressDebugFields(payload, {
                        direction = "push",
                        source = "koreader",
                        apiStatus = api_status,
                        apiErrorClass = api_error_class,
                        retryCount = item.retry_count,
                        reason = safeToString(response),
                    }))
                    if api_error_class == "permanent_not_found" then
                        self.db:deletePendingProgress(item.id)
                        self:recordNotFoundHash({
                            file_hash = item.file_hash or payload.bookHash,
                            book_id = payload.bookId,
                            file_path = payload.file_path,
                            file_format = payload.fileFormat,
                            source = "koreader",
                            reason = safeToString(response),
                        })
                    else
                        self.db:incrementPendingProgressRetry(item.id)
                    end
                    failed = failed + 1
                end
            end
        end
    end

    if not silent and (synced > 0 or failed > 0) then
        self:showMessage(T(_("Pending progress sync\nSynced: %1\nFailed: %2"), synced, failed), 3)
    end

    self:logProgressEvent("info", "pending progress summary", {
        source = "koreader",
        direction = "push",
        apiStatus = "complete",
        retryCount = failed,
        reason = T(_("synced=%1 failed=%2"), synced, failed),
    })

    return synced, failed
end

function Grimmlink:resolveBookByHash(file_path, file_hash, silent)
    if not file_hash then
        return nil
    end
    if self:isHashMarkedNotFound(file_hash) then
        return nil
    end

    local cached = self.db:getBookByHash(file_hash)
    if cached and cached.book_id then
        self:logProgressEvent("dbg", "book hash cache hit", {
            bookId = cached.book_id,
            bookHash = file_hash,
            source = "koreader",
            direction = "pull",
            apiStatus = "cache",
        })
        return cached
    end

    if not self:isOnline() then
        self.db:saveBookCache(file_path, file_hash, nil, sanitizeTitle(file_path), nil)
        return cached
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    local success, book, code = self.api:getBookByHash(file_hash)
    if success and book and book.id then
        self.db:saveBookCache(file_path, file_hash, tonumber(book.id), book.title, book.author)
        self:logProgressEvent("info", "book hash matched", {
            bookId = tonumber(book.id),
            bookHash = file_hash,
            source = "koreader",
            direction = "pull",
            apiStatus = "ok",
            apiErrorClass = "none",
        })
        return {
            file_path = file_path,
            file_hash = file_hash,
            book_id = tonumber(book.id),
            title = book.title,
            author = book.author,
        }
    end

    self.db:saveBookCache(file_path, file_hash, nil, sanitizeTitle(file_path), nil)
    local api_status, api_error_class = self:classifyApiOutcome(code, book)
    self:logProgressEvent("warn", "book hash missing", {
        bookHash = file_hash,
        source = "koreader",
        direction = "pull",
        apiStatus = api_status,
        apiErrorClass = api_error_class,
        reason = safeToString(book),
    })
    if api_error_class == "permanent_not_found" then
        self:recordNotFoundHash({
            file_hash = file_hash,
            file_path = file_path,
            source = "koreader",
            reason = safeToString(book),
        })
    end
    if not silent then
        self:showMessage(_("No Grimmory match found for this book hash"), 4)
    end
    return nil
end

function Grimmlink:resolveBookByFilePath(file_path)
    if not self.db or not file_path or file_path == "" then
        return nil
    end

    local cached = self.db:getBookByFilePath(file_path)
    if cached and cached.book_id then
        return cached
    end

    if type(self.db.getShelfSyncEntryByLocalPath) == "function" then
        local shelf_entry = self.db:getShelfSyncEntryByLocalPath(file_path)
        if shelf_entry and shelf_entry.book_id then
            self.db:saveBookCache(
                file_path,
                cached and cached.file_hash or "",
                shelf_entry.book_id,
                shelf_entry.remote_title or sanitizeTitle(file_path),
                shelf_entry.remote_author
            )
            return {
                file_path = file_path,
                file_hash = cached and cached.file_hash or nil,
                book_id = tonumber(shelf_entry.book_id),
                title = shelf_entry.remote_title,
                author = shelf_entry.remote_author,
            }
        end
    end

    return cached
end

function Grimmlink:shouldPushProgress(current_snapshot, state, reason)
    if reason == "manual" or reason == "close" or reason == "suspend" then
        return true
    end

    if not state then
        return self:hasMeaningfulProgress(current_snapshot)
    end

    local previous_local = self:buildStoredLocalSnapshot(state)
    if not previous_local then
        return self:hasMeaningfulProgress(current_snapshot)
    end

    if self:progressDifferenceExceeded(current_snapshot, previous_local) then
        return true
    end

    local minutes_threshold = tonumber(self.threshold_minutes) or DEFAULTS.threshold_minutes
    if state.local_timestamp and current_snapshot.timestamp then
        if (current_snapshot.timestamp - state.local_timestamp) >= (minutes_threshold * 60) then
            return true
        end
    end

    return false
end

function Grimmlink:maybePullRemoteProgress(file_hash, file_path, book_id)
    if not self.auto_pull_on_open or not file_hash or file_hash == "" or not book_id then
        return
    end
    if self:isHashMarkedNotFound(file_hash) then
        return
    end
    if not self:isOnline() then
        return
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    local state = self.db:getProgressState(file_hash)
    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id)
    self:logProgressEvent("dbg", "progress pull request", self:buildProgressDebugFields(local_snapshot, {
        bookId = book_id,
        direction = "pull",
        source = "koreader",
        apiStatus = "request",
    }))
    local success, remote, code = self.api:getProgress(file_hash)
    if not success then
        local api_status, api_error_class = self:classifyApiOutcome(code, remote)
        self:logProgressEvent("warn", "progress pull failed", self:buildProgressDebugFields(local_snapshot, {
            bookId = book_id,
            direction = "pull",
            source = "koreader",
            apiStatus = api_status,
            apiErrorClass = api_error_class,
            reason = safeToString(remote),
        }))
        if api_error_class == "permanent_not_found" then
            self:recordNotFoundHash({
                file_hash = file_hash,
                book_id = book_id,
                file_path = file_path,
                file_format = local_snapshot and local_snapshot.fileFormat or self:getBookType(file_path),
                source = "koreader",
                reason = safeToString(remote),
            })
        end
        self:logWarn("GrimmLink remote progress pull failed:", remote)
        self:rememberLocalSnapshot(file_hash, local_snapshot, "open-local")
        return
    end

    local remote_snapshot = self:normalizeRemoteProgress(remote)
    if remote_snapshot then
        remote_snapshot.bookHash = file_hash
        remote_snapshot.bookId = remote_snapshot.bookId or book_id
      remote_snapshot.fileFormat = remote_snapshot.fileFormat or self:getBookType(file_path)
      remote_snapshot.document = remote_snapshot.document or file_hash
      remote_snapshot.file_path = file_path
      end

    self:logProgressEvent("info", "progress pull response", self:buildProgressDebugFields(remote_snapshot or remote, {
        bookId = book_id,
        direction = "pull",
        source = "koreader",
        apiStatus = "ok",
        apiErrorClass = "none",
    }))

    self:rememberLocalSnapshot(file_hash, local_snapshot, "open-local")
    self:rememberRemoteSnapshot(file_hash, remote_snapshot, "open-remote")

    local decision = self:compareOpenProgress(local_snapshot, remote_snapshot, state)
    self:logInfo("GrimmLink open sync decision:", decision or "nil")

    if decision == "local_newer" then
        self:logProgressEvent("info", "progress pull kept local", self:buildProgressDebugFields(local_snapshot, {
            bookId = book_id,
            direction = "pull",
            source = "koreader",
            apiStatus = "ok",
            apiErrorClass = "none",
            action = "local_newer",
        }))
        self:pushProgressSnapshot(local_snapshot, "open-local-newer", true)
        return
    end

    if decision == "remote_newer" then
        self:logProgressEvent("info", "progress pull applying remote", self:buildProgressDebugFields(remote_snapshot, {
            bookId = book_id,
            direction = "pull",
            source = "koreader",
            apiStatus = "ok",
            apiErrorClass = "none",
            action = "remote_newer",
        }))
        self:resolveRemoteChoice(file_hash, remote_snapshot)
        return
    end

    if decision == "conflict" then
        self:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, decision)
    end
end

function Grimmlink:resolveBridgeConversion(book_id, payload)
    if not self.cfi_conversion_enabled or not book_id or not payload then
        return nil
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    self:logProgressEvent("dbg", "bridge conversion request", self:buildProgressDebugFields(payload, {
        bookId = book_id,
        bookFileId = payload.bookFileId,
        bookHash = payload.bookHash,
        fileFormat = payload.fileFormat,
        source = "web",
        direction = "bridge",
        currentPage = payload.currentPage,
        totalPages = payload.totalPages,
        percent = payload.percentage,
        koreaderRawLocation = payload.rawKoreaderLocation,
        koreaderRawXPointer = payload.rawKoreaderXPointer,
        epubCfi = payload.epubCfi,
    }))
    local success, response = self.api:resolveBridgeCfi(book_id, payload)
    if success and type(response) == "table" then
        self:logProgressEvent("info", "bridge conversion response", self:buildProgressDebugFields(response, {
            bookId = book_id,
            bookFileId = response.bookFileId,
            bookHash = response.bookHash,
            fileFormat = response.fileFormat,
            source = "web",
            direction = "bridge",
            apiStatus = "ok",
            apiErrorClass = "none",
        }))
        return response
    end

    local api_status, api_error_class = self:classifyApiOutcome(nil, response)
    self:logProgressEvent("warn", "bridge conversion failed", self:buildProgressDebugFields(payload, {
        bookId = book_id,
        source = "web",
        direction = "bridge",
        apiStatus = api_status,
        apiErrorClass = api_error_class,
        reason = safeToString(response),
    }))
    self:logWarn("GrimmLink Web Reader bridge conversion failed:", response)
    return nil
end

function Grimmlink:buildWebBridgePayload(snapshot, bridge_state, force_update)
    local conversion = nil
    local raw_xpointer = self:looksLikeXPointer(snapshot.location) and tostring(snapshot.location)
        or (self:looksLikeXPointer(snapshot.progress) and tostring(snapshot.progress) or nil)

    local file_format = snapshot.fileFormat and tostring(snapshot.fileFormat):upper() or nil
    if self.cfi_conversion_enabled and file_format == "EPUB" and raw_xpointer and snapshot.bookId then
        conversion = self:resolveBridgeConversion(snapshot.bookId, {
            bookHash = snapshot.bookHash,
            bookFileId = snapshot.bookFileId,
            fileFormat = snapshot.fileFormat,
            rawKoreaderLocation = snapshot.location,
            rawKoreaderXPointer = raw_xpointer,
            currentPage = snapshot.currentPage,
            totalPages = snapshot.totalPages,
            percentage = snapshot.percentage,
        })
    end

    self:logProgressEvent("dbg", "bridge payload build", self:buildProgressDebugFields(snapshot, {
        bookId = snapshot.bookId,
        source = "web",
        direction = "bridge",
        currentPage = snapshot.currentPage,
        totalPages = snapshot.totalPages,
        percent = snapshot.percentage,
        koreaderRawProgress = snapshot.progress,
        koreaderRawLocation = snapshot.location,
        koreaderRawXPointer = raw_xpointer,
        epubCfi = conversion and conversion.epubCfi or nil,
        positionHref = conversion and conversion.converted and conversion.positionHref or nil,
        conversionStatus = conversion and conversion.conversionStatus or nil,
        conversionConfidence = conversion and conversion.conversionConfidence or nil,
    }))

    return {
        bookId = snapshot.bookId,
        bookFileId = snapshot.bookFileId,
        bookHash = snapshot.bookHash,
        fileFormat = snapshot.fileFormat,
        percentage = snapshot.percentage,
        currentPage = snapshot.currentPage,
        totalPages = snapshot.totalPages,
        epubCfi = conversion and conversion.converted and conversion.epubCfi or nil,
        positionHref = conversion and conversion.converted and conversion.positionHref or nil,
        contentSourceProgressPercent = conversion and conversion.contentSourceProgressPercent or nil,
        rawKoreaderLocation = snapshot.location,
        rawKoreaderProgress = snapshot.progress,
        rawKoreaderXPointer = raw_xpointer,
        source = "KOREADER",
        device = self.device_name,
        deviceId = self.device_id,
        timestamp = snapshot.timestamp,
        expectedUpdatedAt = bridge_state and bridge_state.remote_updated_at or nil,
        force = force_update == true,
    }, conversion
end

function Grimmlink:pushWebReaderBridgeSnapshot(snapshot, opts)
    opts = opts or {}
    if not self:isWebReaderSyncEnabled() or not snapshot or not snapshot.bookHash or not snapshot.bookId then
        return { ok = false, skipped = true, reason = "disabled_or_unmatched" }
    end

    if not self:isOnline() then
        self:logProgressEvent("warn", "web bridge push offline", self:buildProgressDebugFields(snapshot, {
            bookId = snapshot.bookId,
            direction = "bridge",
            source = "web",
            apiStatus = "offline",
            apiErrorClass = "transient_network",
            reason = "offline",
        }))
        return { ok = false, skipped = true, reason = "offline" }
    end

    local bridge_state = self.db:getWebBridgeState(snapshot.bookHash)
    local payload, conversion = self:buildWebBridgePayload(snapshot, bridge_state, opts.force)

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    local success, response, code = self.api:updateWebProgress(snapshot.bookId, payload)
    if not success then
        local api_status, api_error_class = self:classifyApiOutcome(code, response)
        self:logProgressEvent("warn", "web bridge push failed", self:buildProgressDebugFields(snapshot, {
            bookId = snapshot.bookId,
            direction = "bridge",
            source = "web",
            apiStatus = api_status,
            apiErrorClass = api_error_class,
            reason = safeToString(response),
        }))
        self.last_web_bridge_result = {
            ok = false,
            reason = tostring(response),
            at = nowUtc(),
        }
        return { ok = false, reason = tostring(response), conversion = conversion }
    end

    local remote_snapshot = self:normalizeWebBridgeProgress(response)
    if remote_snapshot then
        remote_snapshot.bookHash = snapshot.bookHash
        remote_snapshot.bookId = snapshot.bookId
        remote_snapshot.fileFormat = snapshot.fileFormat
        remote_snapshot.document = snapshot.document
        remote_snapshot.file_path = snapshot.file_path
    end

    if response and response.conflictDetected then
        self:logProgressEvent("warn", "web bridge push conflict", self:buildProgressDebugFields(remote_snapshot or snapshot, {
            bookId = snapshot.bookId,
            direction = "bridge",
            source = "web",
            apiStatus = "conflict",
            apiErrorClass = "remote_newer",
            reason = response.message or "remote_newer",
        }))
        if remote_snapshot then
            self:rememberRemoteWebBridgeSnapshot(snapshot.bookHash, remote_snapshot, opts.reason or "web-bridge-conflict")
        end
        self.last_web_bridge_result = {
            ok = false,
            conflict = true,
            reason = response.message or "remote_newer",
            at = nowUtc(),
        }
        return {
            ok = false,
            conflict = true,
            reason = response.message or "remote_newer",
            remote_snapshot = remote_snapshot,
            conversion = conversion,
        }
    end

    self:rememberLocalWebBridgeSnapshot(snapshot.bookHash, snapshot, opts.reason or "web-bridge-push")
    if remote_snapshot then
        self:rememberRemoteWebBridgeSnapshot(snapshot.bookHash, remote_snapshot, opts.reason or "web-bridge-push")
        self.db:setWebBridgeLastAction(snapshot.bookHash, opts.reason or "web-bridge-push")
    end
    self:logProgressEvent("info", "web bridge push ok", self:buildProgressDebugFields(snapshot, {
        bookId = snapshot.bookId,
        direction = "bridge",
        source = "web",
        apiStatus = "ok",
        apiErrorClass = "none",
        conversionStatus = conversion and conversion.conversionStatus or nil,
        conversionConfidence = conversion and conversion.conversionConfidence or nil,
    }))

    self.last_web_bridge_result = {
        ok = true,
        updated = true,
        conversion = conversion and conversion.conversionStatus or nil,
        at = nowUtc(),
    }
    return {
        ok = true,
        remote_snapshot = remote_snapshot,
        conversion = conversion,
    }
end

function Grimmlink:showWebBridgeConflictDialog(file_hash, local_snapshot, remote_snapshot, mode)
    if not self:beginConflictDialog("web-bridge") then
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = self:buildWebBridgeConflictDialogText(local_snapshot, remote_snapshot),
        buttons = {
            {
                {
                    text = _("Use KOReader"),
                    callback = function()
                        self:invokeSafely("web-bridge use-koreader", function()
                            self:endConflictDialog()
                            UIManager:close(dialog)
                            local result = self:pushWebReaderBridgeSnapshot(local_snapshot, {
                                reason = mode == "remote_newer" and "web-bridge-use-local-remote-newer" or "web-bridge-use-local-conflict",
                                force = true,
                            })
                            if result.ok then
                                self:showMessage(_("Updated Web Reader progress from KOReader"), 3)
                            elseif result.conflict then
                                self:showMessage(_("Web Reader changed again; keeping the remote position."), 4)
                            else
                                self:showMessage(_("Web Reader bridge push failed, but KOReader reading continues normally."), 4)
                            end
                        end)
                    end,
                },
                {
                    text = _("Use Web Reader"),
                    callback = function()
                        self:invokeSafely("web-bridge use-web", function()
                            self:endConflictDialog()
                            UIManager:close(dialog)
                              self:applyAndFinalizeRemoteProgress(
                                  file_hash,
                                  remote_snapshot,
                                  _("Jumped to Web Reader progress"),
                                  _("Web Reader progress found, but a safe jump was not possible"),
                                  function(applied_snapshot)
                                      self:logProgressEvent("info", "web bridge progress applied", self:buildProgressDebugFields(applied_snapshot, {
                                          bookHash = file_hash,
                                          source = "web",
                                          direction = "bridge",
                                          apiStatus = "ok",
                                          apiErrorClass = "none",
                                          action = "remote_newer",
                                      }))
                                      self:rememberLocalWebBridgeSnapshot(file_hash, applied_snapshot, "web-bridge-use-remote")
                                      self:rememberRemoteWebBridgeSnapshot(file_hash, remote_snapshot, "web-bridge-use-remote")
                                  end,
                                  function(failed_snapshot)
                                      self:rememberRemoteWebBridgeSnapshot(file_hash, failed_snapshot, "web-bridge-remote-jump-unsafe")
                                end
                            )
                        end)
                    end,
                },
                {
                    text = _("Ignore"),
                    callback = function()
                        self:invokeSafely("web-bridge ignore", function()
                            self:endConflictDialog()
                            UIManager:close(dialog)
                            self:rememberRemoteWebBridgeSnapshot(file_hash, remote_snapshot,
                                mode == "remote_newer" and "web-bridge-remote-ignored" or "web-bridge-conflict-ignored")
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Grimmlink:maybePullWebReaderProgress(file_hash, file_path, book_id, silent)
    if not self:isWebReaderSyncEnabled() or not file_hash or file_hash == "" or not book_id then
        return nil
    end
    if not self:isOnline() then
        return nil
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    local bridge_state = self.db:getWebBridgeState(file_hash)
    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id)
    self:logProgressEvent("dbg", "web bridge pull request", self:buildProgressDebugFields(local_snapshot, {
        bookId = book_id,
        direction = "bridge",
        source = "web",
        apiStatus = "request",
    }))
    local success, remote, code = self.api:getWebProgress(book_id)
    if not success then
        local api_status, api_error_class = self:classifyApiOutcome(code, remote)
        self:logProgressEvent("warn", "web bridge pull failed", self:buildProgressDebugFields(local_snapshot, {
            bookId = book_id,
            direction = "bridge",
            source = "web",
            apiStatus = api_status,
            apiErrorClass = api_error_class,
            reason = safeToString(remote),
        }))
        if api_error_class == "permanent_not_found" then
            self:recordNotFoundHash({
                file_hash = file_hash,
                book_id = book_id,
                file_path = file_path,
                file_format = local_snapshot and local_snapshot.fileFormat or self:getBookType(file_path),
                source = "web",
                reason = safeToString(remote),
            })
        end
        self:logWarn("GrimmLink Web Reader bridge pull failed:", remote)
        self:rememberLocalWebBridgeSnapshot(file_hash, local_snapshot, "web-bridge-open-local")
        return { decision = "error", reason = remote }
    end

    local remote_snapshot = self:normalizeWebBridgeProgress(remote)
    if remote_snapshot then
        remote_snapshot.bookHash = file_hash
        remote_snapshot.bookId = book_id
        remote_snapshot.fileFormat = self:getBookType(file_path)
        remote_snapshot.document = file_hash
        remote_snapshot.file_path = file_path
    end

    self:logProgressEvent("info", "web bridge pull response", self:buildProgressDebugFields(remote_snapshot or remote, {
        bookId = book_id,
        direction = "bridge",
        source = "web",
        apiStatus = "ok",
        apiErrorClass = "none",
    }))

    if remote_snapshot and self.cfi_conversion_enabled and isNonEmpty(remote_snapshot.epubCfi) then
        local resolved = self:resolveBridgeConversion(book_id, {
            epubCfi = remote_snapshot.epubCfi,
            currentPage = remote_snapshot.currentPage,
            totalPages = remote_snapshot.totalPages,
            percentage = remote_snapshot.percentage,
        })
        if resolved and resolved.converted then
            remote_snapshot.location = resolved.rawKoreaderXPointer or resolved.rawLocation or remote_snapshot.location
            remote_snapshot.progress = remote_snapshot.location or remote_snapshot.progress
            remote_snapshot.positionHref = resolved.positionHref or remote_snapshot.positionHref
            remote_snapshot.contentSourceProgressPercent = resolved.contentSourceProgressPercent or remote_snapshot.contentSourceProgressPercent
            remote_snapshot.conversionStatus = resolved.conversionStatus or remote_snapshot.conversionStatus
            remote_snapshot.conversionConfidence = resolved.conversionConfidence or remote_snapshot.conversionConfidence
        elseif resolved then
            remote_snapshot.conversionStatus = resolved.conversionStatus or "conversion_failed"
            remote_snapshot.conversionConfidence = resolved.conversionConfidence or 0
        end
    end

    self:rememberLocalWebBridgeSnapshot(file_hash, local_snapshot, "web-bridge-open-local")
    self:rememberRemoteWebBridgeSnapshot(file_hash, remote_snapshot, "web-bridge-open-remote")

    local bridge_compare_state = nil
    if bridge_state then
        bridge_compare_state = {
            local_progress = bridge_state.local_progress,
            local_location = bridge_state.local_location,
            local_percentage = bridge_state.local_percentage,
            local_current_page = bridge_state.local_current_page,
            local_total_pages = bridge_state.local_total_pages,
            local_timestamp = bridge_state.local_timestamp,
            remote_progress = bridge_state.remote_progress,
            remote_location = bridge_state.remote_location,
            remote_percentage = bridge_state.remote_percentage,
            remote_current_page = bridge_state.remote_current_page,
            remote_total_pages = bridge_state.remote_total_pages,
            remote_timestamp = bridge_state.remote_timestamp or bridge_state.remote_updated_at,
        }
    end

    local decision = self:compareOpenProgress(local_snapshot, remote_snapshot, bridge_compare_state)
    self:logInfo("GrimmLink Web Reader bridge decision:", decision or "nil")

    if decision == "none" and self:hasMeaningfulProgress(local_snapshot) then
        local push_result = self:pushWebReaderBridgeSnapshot(local_snapshot, {
            reason = "web-bridge-open-remote-empty",
        })
        if not silent and push_result.ok then
            self:showMessage(_("Seeded the Web Reader bridge from KOReader progress"), 3)
        end
        return { decision = decision, remote_snapshot = remote_snapshot, local_snapshot = local_snapshot }
    end

    if decision == "local_newer" then
        local push_result = self:pushWebReaderBridgeSnapshot(local_snapshot, {
            reason = "web-bridge-open-local-newer",
        })
        if not silent and push_result.ok then
            self:showMessage(_("Pushed newer KOReader progress to the Web Reader bridge"), 3)
        elseif push_result.conflict then
            self:showWebBridgeConflictDialog(file_hash, local_snapshot, push_result.remote_snapshot or remote_snapshot, "conflict")
        end
        return { decision = decision, remote_snapshot = remote_snapshot, local_snapshot = local_snapshot }
    end

    if decision == "remote_newer" or decision == "conflict" then
        self:showWebBridgeConflictDialog(file_hash, local_snapshot, remote_snapshot, decision)
    elseif not silent and decision == "same" then
        self:showMessage(_("Web Reader bridge is already aligned with KOReader"), 3)
    end

    return {
        decision = decision,
        remote_snapshot = remote_snapshot,
        local_snapshot = local_snapshot,
    }
end

function Grimmlink:syncWebReaderBridgeNow(silent)
    if not self:isWebReaderSyncEnabled() then
        if not silent then
            if not self.enabled then
                self:showMessage(_("GrimmLink sync is disabled."), 3)
            else
                self:showMessage(_("Web Reader bridge is disabled."), 3)
            end
        end
        return nil
    end
    if not self:requireReady({ require_api = true, silent = silent }) then
        return nil
    end
    if not self.ui or not self.ui.document or not self.ui.document.file then
        return nil
    end

    local file_path = tostring(self.ui.document.file)
    local cached = self:resolveBookByFilePath(file_path)
    local file_hash = cached and isNonEmpty(cached.file_hash) and cached.file_hash or self:calculateBookHash(file_path)
    local matched = self:resolveBookByHash(file_path, file_hash, true)
    local book_id = matched and matched.book_id or (cached and cached.book_id or nil)
    if not book_id then
        if not silent then
            self:showMessage(_("No matched Grimmory book for Web Reader bridge."), 3)
        end
        return nil
    end

    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id)
    self:logProgressEvent("info", "web bridge sync start", self:buildProgressDebugFields(local_snapshot, {
        bookId = book_id,
        direction = "bridge",
        source = "web",
        apiStatus = "request",
        action = "manual",
    }))
    self:pushProgressSnapshot(local_snapshot, "manual", true)

    local result = self:maybePullWebReaderProgress(file_hash, file_path, book_id, silent)
    local result_status = "ok"
    local result_error_class = "none"
    if not result or type(result) ~= "table" or result.decision == "error" then
        result_status = "error"
        result_error_class = "unknown"
    end
    self:logProgressEvent("info", "web bridge sync complete", self:buildProgressDebugFields(result or local_snapshot, {
        bookId = book_id,
        direction = "bridge",
        source = "web",
        apiStatus = result_status,
        apiErrorClass = result_error_class,
        action = "manual",
    }))
    return result
end

function Grimmlink:validateSession(duration_seconds, progress_delta, start_page, end_page)
    if duration_seconds < (tonumber(self.session_min_seconds) or DEFAULTS.session_min_seconds) then
        local pages_delta = math.abs((tonumber(end_page) or 0) - (tonumber(start_page) or 0))
        local progress_delta_value = math.abs(tonumber(progress_delta) or 0)
        if pages_delta < 1 and progress_delta_value < 0.1 then
            return false
        end
    end
    return true
end

function Grimmlink:startSession()
    if not self.enabled or not self:requireReady({ require_api = true, silent = true }) or not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end

    local file_path = tostring(self.ui.document.file)
    local cached = self:resolveBookByFilePath(file_path)
    local file_hash = cached and cached.file_hash or nil
    if not file_hash or file_hash == "" then
        file_hash = self:calculateBookHash(file_path)
    end

    local matched = self:resolveBookByHash(file_path, file_hash, true)
    local book_id = matched and matched.book_id or (cached and cached.book_id or nil)
    local title = matched and matched.title or (cached and cached.title or sanitizeTitle(file_path))

    local start_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id)

    self.current_session = {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_title = title,
        start_time = nowUtc(),
        start_snapshot = start_snapshot,
        book_type = self:getBookType(file_path),
    }

    self:logInfo("GrimmLink session started for", title, "hash:", file_hash or "nil")

    -- Defer all network calls so they don't block the document render thread.
    -- Blocking HTTP in onReaderReady corrupts KOReader's internal state and
    -- causes a native crash, especially on EPUB/CRE documents.
    local defer = UIManager and type(UIManager.scheduleIn) == "function"
    local function doNetworkSync()
        -- Guard: skip if user switched books before the deferred sync fired
        if not self.current_session or self.current_session.file_hash ~= file_hash then
            return
        end
        self:invokeSafely("session open sync", function()
            self:maybePullRemoteProgress(file_hash, file_path, book_id)
            self:maybePullWebReaderProgress(file_hash, file_path, book_id, true)
            self:maybePullRemoteAnnotations(book_id)
        end)
    end

    if defer then
        UIManager:scheduleIn(0.5, doNetworkSync)
    else
        doNetworkSync()
    end
end

function Grimmlink:endSession(options)
    options = options or {}
    if not self.current_session or not self:requireReady({ require_api = true, silent = true }) then
        return false
    end

    local file_path = self.current_session.file_path
    local file_hash = self.current_session.file_hash
    local book_id = self.current_session.book_id
    local end_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id)
    local duration_seconds = math.max(0, nowUtc() - (self.current_session.start_time or nowUtc()))
    local start_snapshot = self.current_session.start_snapshot or {}

    local progress_delta = (tonumber(end_snapshot.percentage) or 0) - (tonumber(start_snapshot.percentage) or 0)
    local session_valid = self:validateSession(
        duration_seconds,
        progress_delta,
        start_snapshot.currentPage,
        end_snapshot.currentPage
    )

    self:rememberLocalSnapshot(file_hash, end_snapshot, "local-" .. (options.reason or "close"))

    if session_valid then
        self.db:addPendingSession({
            bookId = book_id,
            bookHash = file_hash,
            bookType = self.current_session.book_type,
            device = self.device_name,
            deviceId = self.device_id,
            startTime = toIso8601(self.current_session.start_time),
            endTime = toIso8601(end_snapshot.timestamp),
            durationSeconds = duration_seconds,
            startProgress = roundToSingleDecimal(start_snapshot.percentage or 0),
            endProgress = roundToSingleDecimal(end_snapshot.percentage or 0),
            progressDelta = roundToSingleDecimal(progress_delta),
            startLocation = start_snapshot.location or "",
            endLocation = end_snapshot.location or "",
        })
    end

    local state = self.db:getProgressState(file_hash)
    local should_push = self:shouldPushProgress(end_snapshot, state, options.reason or "close")
    if should_push and self.auto_push_on_close then
        self:pushProgressSnapshot(end_snapshot, options.reason or "close", true)
        self:pushWebReaderBridgeSnapshot(end_snapshot, {
            reason = "web-bridge-" .. (options.reason or "close"),
        })
    end

    self.current_session = nil
    return true
end

function Grimmlink:buildSingleSessionPayload(group, item)
    return {
        bookId = group.bookId,
        bookHash = group.bookHash,
        bookType = group.bookType,
        startTime = item.startTime,
        endTime = item.endTime,
        durationSeconds = item.durationSeconds,
        durationFormatted = item.durationFormatted,
        startProgress = item.startProgress,
        endProgress = item.endProgress,
        progressDelta = item.progressDelta,
        startLocation = item.startLocation,
        endLocation = item.endLocation,
        device = group.device,
        deviceId = group.deviceId,
    }
end

function Grimmlink:syncPendingSessions(silent)
    local synced = 0
    local failed = 0

    if not self:requireReady({ require_api = true, silent = silent }) then
        return synced, failed
    end
    if not self:isOnline() then
        return synced, failed
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
      local pending = self.db:getPendingSessions(500)
      if #pending == 0 then
          return synced, failed
      end

      self:logProgressEvent("dbg", "pending session batch start", {
          source = "koreader",
          direction = "push",
          apiStatus = "pending",
          retryCount = #pending,
      })

    -- Resolve bookId for sessions that are missing it.
    -- hash_resolved[h] = bookId (integer) if found, false if definitively 404.
    -- At most one API call per unique hash to avoid N calls for N queued sessions.
    local hash_resolved = {}
    local hash_not_found = {}

      for _, session in ipairs(pending) do
          if not session.bookId and session.bookHash and session.bookHash ~= "" then
              local h = session.bookHash
              if hash_resolved[h] then
                  session.bookId = hash_resolved[h]
                self.db:updatePendingSessionBookId(session.id, hash_resolved[h])
            elseif hash_resolved[h] == nil and not hash_not_found[h] then
                local cached = self.db:getBookByHash(h)
                if cached and cached.book_id then
                    hash_resolved[h] = cached.book_id
                    session.bookId = cached.book_id
                    self.db:updatePendingSessionBookId(session.id, cached.book_id)
                else
                    local state = self.db:getProgressState(h)
                    local by_path = state and state.file_path and self:resolveBookByFilePath(state.file_path) or nil
                    if by_path and by_path.book_id then
                        hash_resolved[h] = tonumber(by_path.book_id)
                        session.bookId = hash_resolved[h]
                        self.db:updateBookId(h, hash_resolved[h])
                        self.db:updatePendingSessionBookId(session.id, hash_resolved[h])
                    else
                        local ok_lookup, book, lookup_code = self.api:getBookByHash(h)
                          if ok_lookup and book and book.id then
                              hash_resolved[h] = tonumber(book.id)
                              session.bookId = hash_resolved[h]
                              self.db:updateBookId(h, hash_resolved[h])
                              self.db:updatePendingSessionBookId(session.id, hash_resolved[h])
                              self:logProgressEvent("info", "pending session hash matched", {
                                  bookId = hash_resolved[h],
                                  bookHash = h,
                                  source = "koreader",
                                  direction = "push",
                                  apiStatus = "ok",
                                  apiErrorClass = "none",
                              })
                          elseif lookup_code == 404 then
                              hash_not_found[h] = true
                              hash_resolved[h] = false
                              self:recordNotFoundHash({
                                  file_hash = h,
                                  book_id = session.bookId,
                                  file_format = session.bookType,
                                  source = "koreader",
                                  reason = "book not found",
                              })
                          else
                              hash_resolved[h] = false
                          end
                      end
                  end
            end
        end
    end

    local groups = {}
      for _, session in ipairs(pending) do
          if not session.bookId then
              if hash_not_found[session.bookHash] then
                  self.db:deletePendingSession(session.id)
                  logger.warn("GrimmLink: dropped session for hash not in Grimmory:", session.bookHash)
                  self:logProgressEvent("warn", "pending session dropped", {
                      bookHash = session.bookHash,
                      fileFormat = session.bookType,
                      source = "koreader",
                      direction = "push",
                      apiStatus = "http_404",
                      apiErrorClass = "permanent_not_found",
                  })
              else
                  self.db:incrementSessionRetryCount(session.id)
                  self:logProgressEvent("warn", "pending session retry", {
                      bookHash = session.bookHash,
                      fileFormat = session.bookType,
                      source = "koreader",
                      direction = "push",
                      apiStatus = "retry",
                      apiErrorClass = "transient_unknown",
                      retryCount = session.retry_count,
                  })
              end
              failed = failed + 1
          else
              local group_key = table.concat({
                  tostring(session.bookId),
                session.bookHash or "",
                session.bookType or "EPUB",
                session.device or "",
                session.deviceId or "",
            }, "|")
            groups[group_key] = groups[group_key] or {
                bookId = session.bookId,
                bookHash = session.bookHash,
                bookType = session.bookType,
                device = session.device,
                deviceId = session.deviceId,
                sessions = {},
            }
              groups[group_key].sessions[#groups[group_key].sessions + 1] = session
          end
      end

      for _, group in pairs(groups) do
          local items = {}
          for _, session in ipairs(group.sessions) do
              items[#items + 1] = {
                  startTime = session.startTime,
                endTime = session.endTime,
                durationSeconds = session.durationSeconds,
                durationFormatted = self:formatDuration(session.durationSeconds),
                startProgress = roundToSingleDecimal(session.startProgress),
                endProgress = roundToSingleDecimal(session.endProgress),
                progressDelta = roundToSingleDecimal(session.progressDelta),
                startLocation = session.startLocation,
                  endLocation = session.endLocation,
              }
          end

          self:logProgressEvent("dbg", "pending session group request", {
              bookId = group.bookId,
              bookHash = group.bookHash,
              fileFormat = group.bookType,
              source = "koreader",
              direction = "push",
              apiStatus = "request",
              retryCount = #group.sessions,
          })

          local success = false
          local handled_individually = false
          if #items == 1 then
              success = self.api:submitSession(self:buildSingleSessionPayload(group, items[1]))
          else
            local batch_ok, batch_response, batch_code = self.api:submitSessionBatch(
                group.bookId,
                group.bookHash,
                group.bookType,
                group.device,
                group.deviceId,
                items
              )
              if batch_ok then
                  success = true
                  self:logProgressEvent("info", "pending session group ok", {
                      bookId = group.bookId,
                      bookHash = group.bookHash,
                      fileFormat = group.bookType,
                      source = "koreader",
                      direction = "push",
                      apiStatus = "ok",
                      apiErrorClass = "none",
                      retryCount = #group.sessions,
                  })
              else
                  local api_status, api_error_class = self:classifyApiOutcome(batch_code, batch_response)
                  self:logProgressEvent("warn", "pending session group failed", {
                      bookId = group.bookId,
                      bookHash = group.bookHash,
                      fileFormat = group.bookType,
                      source = "koreader",
                      direction = "push",
                      apiStatus = api_status,
                      apiErrorClass = api_error_class,
                      reason = safeToString(batch_response),
                      retryCount = #group.sessions,
                  })
                  self:logWarn(
                      "GrimmLink batch session sync failed; falling back to individual uploads:",
                      batch_response or ("HTTP " .. tostring(batch_code or "?"))
                  )

                local group_success = true
                handled_individually = true
                for index, session in ipairs(group.sessions) do
                    local single_ok = self.api:submitSession(self:buildSingleSessionPayload(group, items[index]))
                      if single_ok then
                          self.db:deletePendingSession(session.id)
                          synced = synced + 1
                      else
                          self.db:incrementSessionRetryCount(session.id)
                          failed = failed + 1
                          group_success = false
                          self:logProgressEvent("warn", "pending session item failed", {
                              bookId = session.bookId,
                              bookHash = session.bookHash,
                              fileFormat = session.bookType,
                              source = "koreader",
                              direction = "push",
                              apiStatus = "retry",
                              apiErrorClass = "transient_unknown",
                              retryCount = session.retry_count,
                          })
                      end
                  end
                  success = group_success
              end
          end

        if handled_individually then
            -- Results were already applied in the fallback loop above.
        elseif success and #items > 1 then
            for _, session in ipairs(group.sessions) do
                self.db:deletePendingSession(session.id)
                synced = synced + 1
            end
            self:logProgressEvent("info", "pending session group applied", {
                bookId = group.bookId,
                bookHash = group.bookHash,
                fileFormat = group.bookType,
                source = "koreader",
                direction = "push",
                apiStatus = "ok",
                apiErrorClass = "none",
                retryCount = #group.sessions,
            })
        elseif not success and #items > 1 then
            for _, session in ipairs(group.sessions) do
                self.db:incrementSessionRetryCount(session.id)
                failed = failed + 1
            end
            self:logProgressEvent("warn", "pending session group retry", {
                bookId = group.bookId,
                bookHash = group.bookHash,
                fileFormat = group.bookType,
                source = "koreader",
                direction = "push",
                apiStatus = "retry",
                apiErrorClass = "transient_unknown",
                retryCount = #group.sessions,
            })
        elseif success then
            for _, session in ipairs(group.sessions) do
                self.db:deletePendingSession(session.id)
                synced = synced + 1
            end
            self:logProgressEvent("info", "pending session item ok", {
                bookId = group.bookId,
                bookHash = group.bookHash,
                fileFormat = group.bookType,
                source = "koreader",
                direction = "push",
                apiStatus = "ok",
                apiErrorClass = "none",
                retryCount = #group.sessions,
            })
        else
            for _, session in ipairs(group.sessions) do
                self.db:incrementSessionRetryCount(session.id)
                failed = failed + 1
            end
            self:logProgressEvent("warn", "pending session item retry", {
                bookId = group.bookId,
                bookHash = group.bookHash,
                fileFormat = group.bookType,
                source = "koreader",
                direction = "push",
                apiStatus = "retry",
                apiErrorClass = "transient_unknown",
                retryCount = #group.sessions,
            })
        end
      end

    if not silent and (synced > 0 or failed > 0) then
        self:showMessage(T(_("Pending session sync\nSynced: %1\nFailed: %2"), synced, failed), 3)
    end

    return synced, failed
end

function Grimmlink:syncPendingNow(silent)
    if not self:requireReady({ require_api = true, silent = silent }) then
        return
    end

    local progress_synced, progress_failed = self:syncPendingProgress(true)
    local sessions_synced, sessions_failed = self:syncPendingSessions(true)
    local annot_result = self:syncPendingAnnotations(true)

    self:logProgressEvent("info", "pending sync summary", {
        source = "koreader",
        direction = "push",
        apiStatus = "complete",
        retryCount = progress_failed + sessions_failed + (annot_result.failed or 0),
        reason = T(_("progress=%1/%2 sessions=%3/%4 annotations=%5/%6"),
            progress_synced, progress_failed,
            sessions_synced, sessions_failed,
            annot_result.posted, annot_result.failed),
    })

    self.last_sync_summary = {
        progress_synced = progress_synced,
        progress_failed = progress_failed,
        sessions_synced = sessions_synced,
        sessions_failed = sessions_failed,
        annotations_posted = annot_result.posted,
        annotations_failed = annot_result.failed,
    }

    if not silent then
        self:showMessage(T(
            _("GrimmLink sync complete\nProgress: %1 synced, %2 failed\nSessions: %3 synced, %4 failed\nAnnotations: %5 posted, %6 failed"),
            progress_synced,
            progress_failed,
            sessions_synced,
            sessions_failed,
            annot_result.posted,
            annot_result.failed
        ), 4)
    end
end

-- Flush queued annotations / bookmarks / ratings.
-- Returns { posted, failed, skipped, errors }.
function Grimmlink:syncPendingAnnotations(silent)
    local empty = { posted = 0, failed = 0, skipped = 0, errors = {} }
    if not self.enabled then return empty end
    if not (self.annotations_sync_enabled or self.bookmarks_sync_enabled or self.rating_sync_enabled) then
        return empty
    end
    if not self:isOnline() then
        if not silent then self:showMessage(_("Offline — annotation sync queued."), 3) end
        return empty
    end

    local ok, result = pcall(function() return self.annotations:syncPending() end)
    if not ok then
        self:logWarn("GrimmLink: annotation sync error:", tostring(result))
        return empty
    end
    return result or empty
end

function Grimmlink:resolveCurrentDocumentBookId(preferred_book_id)
    if preferred_book_id then
        return tonumber(preferred_book_id)
    end
    if self.current_session and self.current_session.book_id then
        return tonumber(self.current_session.book_id)
    end
    if not self.ui or not self.ui.document or not self.ui.document.file then
        return nil
    end

    local file_path = tostring(self.ui.document.file)
    local cached = self:resolveBookByFilePath(file_path)
    if cached and cached.book_id then
        return tonumber(cached.book_id)
    end

    local file_hash = cached and isNonEmpty(cached.file_hash) and cached.file_hash or self:calculateBookHash(file_path)
    local matched = self:resolveBookByHash(file_path, file_hash, true)
    return matched and matched.book_id or nil
end

function Grimmlink:pullCurrentDocumentAnnotations(silent, opts)
    opts = opts or {}
    local empty = {
        fetched = 0,
        imported = 0,
        updated = 0,
        duplicates = 0,
        conflicts = 0,
        pending = 0,
        skipped = 0,
        errors = {},
    }
    if not self:requireReady({ require_api = true, silent = silent }) then
        return empty
    end
    if not self.enabled then return empty end
    if not (self.annotations_sync_enabled or self.bookmarks_sync_enabled) then
        return empty
    end
    if not self:isOnline() then
        if not silent then self:showMessage(_("Offline - remote annotation pull skipped."), 3) end
        return empty
    end
    if not self.ui or not self.ui.document then
        return empty
    end

    local book_id = self:resolveCurrentDocumentBookId(opts.book_id)
    if not book_id then
        if not silent then self:showMessage(_("No matched Grimmory book for remote annotation pull."), 3) end
        return empty
    end

    self.annotations.annotations_sync_enabled = self.annotations_sync_enabled
    self.annotations.bookmarks_sync_enabled = self.bookmarks_sync_enabled
    self.annotations.rating_sync_enabled = self.rating_sync_enabled

    local ok, result = pcall(function()
        return self.annotations:pullRemoteForCurrentDocument(book_id, self.ui)
    end)
    if not ok then
        self:logWarn("GrimmLink: remote annotation pull error:", tostring(result))
        if not silent then
            self:showMessage(T(_("Remote annotation pull failed: %1"), tostring(result)), 4)
        end
        return empty
    end

    if not silent and result then
        self:showMessage(T(
            _("Remote annotation merge\nImported: %1\nUpdated: %2\nDuplicates: %3\nConflicts: %4\nPending retry: %5"),
            result.imported or 0,
            result.updated or 0,
            result.duplicates or 0,
            result.conflicts or 0,
            result.pending or 0
        ), 4)
    end

    return result or empty
end

function Grimmlink:maybePullRemoteAnnotations(book_id)
    if not self.auto_pull_on_open then
        return
    end
    if not (self.annotations_sync_enabled or self.bookmarks_sync_enabled) then
        return
    end
    if not self:isOnline() then
        return
    end
    self:pullCurrentDocumentAnnotations(true, { book_id = book_id })
end

-- Capture annotations / bookmarks / rating from the current document into the queue.
-- Called on close. Honors per-kind enable flags.
function Grimmlink:captureCurrentDocumentAnnotations()
    if not self:requireReady({ require_api = true, silent = true }) then return false end
    if not self.enabled then return false end
    if not (self.annotations_sync_enabled or self.bookmarks_sync_enabled or self.rating_sync_enabled) then
        return false
    end
    if not self.ui or not self.ui.document then return false end

    local file_path = self.ui.document.file
    if not file_path then return false end

    local cached = self.db:getBookByFilePath(file_path)
    if not cached or not cached.book_id then
        self:logInfo("GrimmLink Annotations: no remote book_id cached for", file_path)
        return false
    end

    -- Refresh annotations module flags (user may toggle at runtime).
    self.annotations.annotations_sync_enabled = self.annotations_sync_enabled
    self.annotations.bookmarks_sync_enabled = self.bookmarks_sync_enabled
    self.annotations.rating_sync_enabled = self.rating_sync_enabled
    self.annotations:captureCurrentDocument(cached.book_id, self.ui)
    return true
end

function Grimmlink:showPendingStats()
    if not self:requireReady({ silent = false }) then
        return
    end

    self:showMessage(table.concat({
        _("GrimmLink cache"),
        table.concat(self:buildDebugSummaryLines(2), "\n"),
    }, "\n"), 6)
end

function Grimmlink:setPrereleaseUpdates(enabled)
    enabled = enabled == true
    if not self:requireReady({ require_api = true, silent = true }) then
        return false
    end

    self:saveSetting("allow_prerelease_updates", enabled)
    self:saveSetting("update_channel", enabled and "prerelease" or "stable")
    if self.updater then
        self.updater:setAllowPrerelease(enabled)
        self.updater:clearCache()
    end
    return true
end

function Grimmlink:toggleAutoUpdateEnabled()
    if not self:saveSetting("auto_update_enabled", not self.auto_update_enabled) then
        return
    end
    self:showMessage(
        self.auto_update_enabled
            and _("GrimmLink update checks are enabled. Installs still require confirmation.")
            or _("GrimmLink update checks are disabled."),
        3
    )
end

function Grimmlink:toggleStartupUpdateChecks()
    if not self:saveSetting("check_update_on_startup", not self.check_update_on_startup) then
        return
    end
    self:showMessage(
        self.check_update_on_startup
            and _("Startup update checks are enabled.")
            or _("Startup update checks are disabled."),
        3
    )
end

function Grimmlink:togglePrereleaseUpdates()
    local enabled = not self.allow_prerelease_updates
    if not self:setPrereleaseUpdates(enabled) then
        return
    end
    self:showMessage(
        enabled
            and _("Pre-release GrimmLink updates are enabled.")
            or _("Only stable GrimmLink updates will be checked."),
        3
    )
end

function Grimmlink:showRestartPrompt(version)
    local text = T(_([[GrimmLink %1 is ready.

Restart KOReader to finish loading the update.

Settings, cache, database, downloaded books, and .sdr files were left untouched.]]), version or _("update"))
    if UIManager and type(UIManager.askForRestart) == "function" then
        UIManager:askForRestart(text)
        return
    end
    self:showMessage(text, 8)
end

function Grimmlink:installUpdate(release_info)
    if type(release_info) ~= "table" or not release_info.download_url then
        self:showMessage(_("Update metadata is incomplete."), 4)
        return
    end

    self:showMessage(_("Downloading GrimmLink update..."), 2)
    local downloaded, zip_path_or_error = self.updater:downloadReleaseAsset(release_info.download_url)
    if not downloaded then
        self:showMessage(T(_([[Update download failed:
%1

Current plugin was left unchanged.]]), tostring(zip_path_or_error)), 6)
        return
    end

    self:showMessage(_("Installing GrimmLink update..."), 2)
    local installed, backup_or_error = self.updater:installDownloadedUpdate(zip_path_or_error)
    if not installed then
        self:showMessage(T(_([[Update install failed:
%1

Current plugin remains usable.]]), tostring(backup_or_error)), 6)
        return
    end

    self.update_available = false
    if self.updater then
        self.updater:clearCache()
    end
    self:showRestartPrompt(release_info.version or _("update"))
end

function Grimmlink:checkForUpdates(silent)
    if not self.updater then
        if not silent then
            self:showMessage(_("Updater is unavailable in this build."), 4)
        end
        return nil
    end
    if not self:requireReady({ silent = silent }) then
        return nil
    end

    if not self:isOnline() then
        if not silent then
            self:showMessage(_("No network connection.\n\nConnect to check for GrimmLink updates."), 4)
        end
        return nil
    end

    if not silent then
        self:showMessage(_("Checking GrimmLink updates..."), 1)
    end

    local result, error_msg = self.updater:checkForUpdates(silent == true)
    if not result then
        self:logWarn("GrimmLink update check failed:", error_msg)
        if not silent then
            self:showMessage(T(_("Update check failed:\n%1"), tostring(error_msg)), 5)
        end
        return nil
    end

    self.last_update_check = nowUtc()
    self:saveSetting("last_update_check", self.last_update_check)
    self.update_available = result.available

    if not result.available then
        if not silent then
            self:showMessage(T(_("GrimmLink is up to date.\nCurrent version: %1"), result.current_version or _("unknown")), 4)
        end
        return result
    end

    if silent then
        self:showMessage(T(_("GrimmLink update available.\nCurrent: %1\nLatest: %2"),
            result.current_version or _("unknown"),
            result.latest_version or _("unknown")), 5)
        return result
    end

    local release_info = result.release_info or {}
    local size_text = self.updater:formatBytes(release_info.size)
    local channel_text = release_info.prerelease and _("prerelease") or _("stable")
    local update_confirm = self:wrapUiSpec({
        text = T(_([[GrimmLink update available

Current version: %1
Latest version: %2
Asset: %3
Size: %4
Channel: %5
Repo: %6

Download and install now?]]),
            result.current_version or _("unknown"),
            result.latest_version or _("unknown"),
            safeToString(release_info.asset_name or self.updater.RELEASE_ASSET_NAME),
            size_text,
            channel_text,
            self.update_repo or DEFAULTS.update_repo),
        ok_text = _("Install"),
        ok_callback = function()
            self:installUpdate(release_info)
        end,
        cancel_text = _("Later"),
    }, "GrimmLink Update Confirm")
    UIManager:show(ConfirmBox:new(update_confirm))

    return result
end

function Grimmlink:maybeCheckForUpdatesOnStartup()
    if not self.auto_update_enabled or not self.check_update_on_startup or not self.updater then
        return
    end
    if not self:isOnline() then
        return
    end

    local now = nowUtc()
    local interval = tonumber(self.updater.STARTUP_CHECK_INTERVAL) or 86400
    if (now - (tonumber(self.last_update_check) or 0)) < interval then
        return
    end

    local result = self:checkForUpdates(true)
    if result and result.available then
        self:logInfo("GrimmLink: update available on startup", result.latest_version)
    end
end

function Grimmlink:showAbout()
    local version = require("plugin_version")
    self:showMessage(table.concat({
        _("GrimmLink"),
        _("KOReader Companion for Grimmory"),
        "",
        T(_("Version: %1"), version.version or "0.1.0-dev"),
        T(_("Auto-update: %1"), self.auto_update_enabled and _("enabled") or _("disabled")),
        T(_("Startup update checks: %1"), self.check_update_on_startup and _("enabled") or _("disabled")),
        T(_("Update channel: %1"), self.allow_prerelease_updates and _("prerelease") or _("stable")),
        T(_("Release repo: %1"), self.update_repo or DEFAULTS.update_repo),
        _("Updates always require confirmation before download/install."),
        _("Updating GrimmLink preserves settings, database, cache, downloaded books, and .sdr files."),
        T(_("Web Reader bridge: %1"), self.web_reader_bridge_enabled and _("enabled") or _("disabled")),
        T(_("Web Reader sync: %1"), self:isWebReaderSyncEnabled() and _("active") or _("disabled")),
        T(_("EPUB CFI conversion: %1"), self.cfi_conversion_enabled and _("enabled") or _("disabled")),
        _("Web Reader progress now follows Reading Sync so KOReader and Web Reader share the same progress source."),
    }, "\n"), 8)
end

function Grimmlink:onReaderReady()
    self:invokeSafely("Reader Ready", function()
        self:logInfo("GrimmLink: reader ready")
        self:startSession()
        -- Defer update check — avoids blocking the document render on startup
        if UIManager and type(UIManager.scheduleIn) == "function" then
            UIManager:scheduleIn(1.5, function()
                self:invokeSafely("startup update check", function()
                    self:maybeCheckForUpdatesOnStartup()
                end)
            end)
        else
            self:maybeCheckForUpdatesOnStartup()
        end
    end, {}, { silent = false })
    return false
end

function Grimmlink:onCloseDocument()
    self:invokeSafely("Close Document", function()
        if not self.enabled then
            return false
        end

        self:logInfo("GrimmLink: document closing")
        self:endSession({ reason = "close" })
        if self.annotations_capture_on_close then
            local ok, err = pcall(function() self:captureCurrentDocumentAnnotations() end)
            if not ok then self:logWarn("GrimmLink: capture annotations error:", tostring(err)) end
        end
        if self:isOnline() then
            self:syncPendingNow(true)
        end
    end, {}, { silent = true })
    return false
end

function Grimmlink:onSuspend()
    self:invokeSafely("Suspend", function()
        if not self.enabled then
            return false
        end

        self:logInfo("GrimmLink: suspend")
        self:endSession({ reason = "suspend" })
        local ok, err = pcall(function() self:captureCurrentDocumentAnnotations() end)
        if not ok then self:logWarn("GrimmLink: suspend annotation capture error:", tostring(err)) end
        if self:isOnline() then
            self:syncPendingNow(true)
        end
    end, {}, { silent = true })
    return false
end

function Grimmlink:onResume()
    self:invokeSafely("Resume", function()
        if not self.enabled then
            return false
        end

        self:logInfo("GrimmLink: resume")
        local now = nowUtc()
        if self:isOnline() and (now - (self.last_auto_sync_time or 0)) >= ((tonumber(self.threshold_minutes) or DEFAULTS.threshold_minutes) * 60) then
            self.last_auto_sync_time = now
            self:syncPendingNow(true)
            self:pullCurrentDocumentAnnotations(true)
        end

        if self.ui and self.ui.document and not self.current_session then
            self:startSession()
        end

        -- Auto-sync shelf on resume (optional, default OFF)
        if self.shelf_sync_enabled and self.auto_sync_shelf_on_resume and self.shelf_id and self:isOnline() then
            self:syncShelfNow(true)
        end
    end, {}, { silent = true })

    return false
end

function Grimmlink:showShelfPicker()
    if not self:requireReady({ require_api = true }) then
        return
    end
    if not self.enabled then
        self:showMessage(_("GrimmLink sync is disabled. Enable it first."), 3)
        return
    end
    if self.server_url == "" or self.username == "" then
        self:showMessage(_("Configure server URL and username first."), 3)
        return
    end

    self:showMessage(_("Fetching shelves from server…"), 2)
    local ok, shelves = self.api:getShelves()
    if not ok then
        self:showMessage(T(_("Failed to fetch shelves: %1"), tostring(shelves)), 4)
        return
    end

    if type(shelves) ~= "table" or #shelves == 0 then
        self:showMessage(_("No shelves available."), 3)
        return
    end

    local buttons = {}
    for shelf_index, shelf in ipairs(shelves) do
        local shelf_id = shelf.id
        local shelf_name = shelf.name or ("Shelf #" .. tostring(shelf_id))
        local count_str = shelf.bookCount and (" (" .. shelf.bookCount .. ")") or ""
        buttons[#buttons + 1] = {
            {
                text = shelf_name .. count_str,
                callback = function()
                    self:saveSetting("shelf_id", shelf_id)
                    self:saveSetting("shelf_name", shelf_name)
                    UIManager:close(self._shelf_picker_dialog)
                    self:showMessage(T(_("Shelf selected: %1"), shelf_name), 2)
                end,
            }
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self._shelf_picker_dialog)
            end,
        }
    }

    buttons = self:wrapUiSpec(buttons, "GrimmLink Shelf Picker")
    self._shelf_picker_dialog = ButtonDialog:new{
        title = _("Select Shelf to Sync"),
        buttons = buttons,
    }
    UIManager:show(self._shelf_picker_dialog)
end

function Grimmlink:configureDownloadDir()
    if not self:requireReady({ silent = false }) then
        return
    end

    local current = self.download_dir or ""
    local dialog
    dialog = InputDialog:new{
        title = _("Download Directory"),
        input = current,
        description = _("Leave empty to auto-create and use a Book folder inside the KOReader books directory."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        if value == nil then value = "" end
                        self:saveSetting("download_dir", value)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Grimmlink:syncShelfNow(silent)
    if not self:requireReady({ require_api = true, silent = silent }) then
        return
    end
    if not self.shelf_sync_enabled then
        if not silent then
            self:showMessage(_("Shelf Sync is disabled. Enable it in Shelf Sync settings."), 3)
        end
        return
    end

    if not self.shelf_id then
        if not silent then
            self:showMessage(_("No shelf selected. Go to Shelf Sync → Select Shelf."), 3)
        end
        return
    end

    if not self:isOnline() then
        if not silent then
            self:showMessage(_("No network connection."), 3)
        end
        return
    end

    if not silent then
        self:showMessage(T(_("Syncing shelf: %1…"), self.shelf_name or tostring(self.shelf_id)), 2)
    end

    local summary = self.shelf_sync:syncShelf({
        shelf_id = self.shelf_id,
        download_dir = self.download_dir,
        use_original_filename = self.shelf_use_original_filename,
        two_way_delete_sync = self.two_way_shelf_delete_sync,
        delete_sdr = self.delete_sdr_on_book_delete,
    })

    if not silent then
        local msg = T(_("Shelf sync complete: %1 downloaded, %2 skipped, %3 failed"),
            summary.synced, summary.skipped, summary.failed)
        if summary.deleted > 0 then
            msg = msg .. "\n" .. T(_("%1 removed"), summary.deleted)
        end
        if #summary.errors > 0 then
            msg = msg .. "\n" .. summary.errors[1]
        end
        self:showMessage(msg, 5)
    end
end

function Grimmlink:onExit()
    if FileManager and FileManager.removeFileDialogButtons then
        FileManager.removeFileDialogButtons(FileManager, "grimmlink_actions")
    end
end

function Grimmlink:registerDispatcherActions()
    Dispatcher:registerAction("grimmlink_sync_pending", {
        category = "none",
        event = "GrimmLinkSyncPending",
        title = _("GrimmLink: Sync Pending"),
        general = true,
    })
    Dispatcher:registerAction("grimmlink_test_connection", {
        category = "none",
        event = "GrimmLinkTestConnection",
        title = _("GrimmLink: Test Connection"),
        general = true,
    })
    Dispatcher:registerAction("grimmlink_sync_shelf", {
        category = "none",
        event = "GrimmLinkSyncShelf",
        title = _("GrimmLink: Sync Shelf"),
        general = true,
    })
end

function Grimmlink:onGrimmLinkSyncPending()
    self:invokeSafely("Dispatcher Sync Pending", function()
        self:syncPendingNow(false)
    end, {}, { silent = false })
    return true
end

function Grimmlink:onGrimmLinkTestConnection()
    self:invokeSafely("Dispatcher Test Connection", function()
        self:testConnection()
    end, {}, { silent = false })
    return true
end

function Grimmlink:onGrimmLinkSyncShelf()
    self:invokeSafely("Dispatcher Sync Shelf", function()
        self:syncShelfNow(false)
    end, {}, { silent = false })
    return true
end

function Grimmlink:showGrimmLinkFileDialog(file)
    local buttons = {
        {
            {
                text = _("Sync Pending Now"),
                callback = function()
                    UIManager:close(self._grimmlink_file_dialog)
                    self:syncPendingNow(false)
                end,
            },
            {
                text = _("Sync Shelf"),
                callback = function()
                    UIManager:close(self._grimmlink_file_dialog)
                    self:syncShelfNow(false)
                end,
            },
        },
        {
            {
                text = _("Test Connection"),
                callback = function()
                    UIManager:close(self._grimmlink_file_dialog)
                    self:testConnection()
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    UIManager:close(self._grimmlink_file_dialog)
                end,
            },
        },
    }
    buttons = self:wrapUiSpec(buttons, "GrimmLink File Dialog")
    self._grimmlink_file_dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(self._grimmlink_file_dialog)
end

function Grimmlink:addToMainMenu(menu_items)
    local function menuReady()
        return self._initialized and self.db ~= nil
    end

    local function safeDbCount(method_name)
        if not menuReady() then
            return 0
        end

        local getter = self.db[method_name]
        if type(getter) ~= "function" then
            return 0
        end

        local ok, value = pcall(getter, self.db)
        if not ok then
            return 0
        end

        return tonumber(value) or 0
    end

    local current_document_match = self:hasMatchedCurrentDocument()

    menu_items.grimmlink = {
        text = _("GrimmLink"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enable Sync"),
                checked_func = function()
                    return self.enabled
                end,
                callback = function()
                    self:saveSetting("enabled", not self.enabled)
                    self:showMessage(self.enabled and _("GrimmLink sync enabled") or _("GrimmLink sync disabled"), 2)
                end,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Connection"),
                        sub_item_table = {
                            {
                                text = _("Configure Connection"),
                                callback = function()
                                    self:configureConnection()
                                end,
                            },
                            {
                                text = _("Test Connection"),
                                callback = function()
                                    self:testConnection()
                                end,
                            },
                        },
                    },
                    {
                        text = _("Device"),
                        sub_item_table = {
                            {
                                text = _("Device Name"),
                                callback = function()
                                    self:configureDeviceName()
                                end,
                            },
                            {
                                text = _("Device ID"),
                                callback = function()
                                    self:configureDeviceId()
                                end,
                            },
                        },
                    },
                    {
                        text = _("Debug Logging"),
                        sub_item_table = {
                            {
                                text = _("Debug logging"),
                                checked_func = function()
                                    return self.debug_logging
                                end,
                                callback = function()
                                    self:saveSetting("debug_logging", not self.debug_logging)
                                end,
                            },
                            {
                                text = _("Write logs to file"),
                                checked_func = function()
                                    return self.log_to_file
                                end,
                                callback = function()
                                    self:saveSetting("log_to_file", not self.log_to_file)
                                end,
                            },
                            {
                                text = _("Show log file location"),
                                callback = function()
                                    self:showLogFileLocation()
                                end,
                            },
                            {
                                text = _("Show recent log lines"),
                                callback = function()
                                    self:showRecentLogLines()
                                end,
                            },
                        },
                    },
                    {
                        text = _("About & Updates"),
                        sub_item_table = {
                            {
                                text = _("Check for Updates"),
                                callback = function()
                                    self:checkForUpdates(false)
                                end,
                            },
                            {
                                text = _("Auto Update Enabled"),
                                checked_func = function()
                                    return self.auto_update_enabled
                                end,
                                callback = function()
                                    self:toggleAutoUpdateEnabled()
                                end,
                            },
                            {
                                text = _("Check on Startup"),
                                checked_func = function()
                                    return self.check_update_on_startup
                                end,
                                callback = function()
                                    self:toggleStartupUpdateChecks()
                                end,
                            },
                            {
                                text = _("Allow Pre-release Updates"),
                                checked_func = function()
                                    return self.allow_prerelease_updates
                                end,
                                callback = function()
                                    self:togglePrereleaseUpdates()
                                end,
                            },
                            {
                                text = _("About GrimmLink"),
                                callback = function()
                                    self:showAbout()
                                end,
                            },
                        },
                    },
                },
            },
            {
                text = _("Sync Behavior"),
                sub_item_table = {
                    {
                        text = _("Auto pull on book open"),
                        checked_func = function()
                            return self.auto_pull_on_open
                        end,
                        callback = function()
                            self:saveSetting("auto_pull_on_open", not self.auto_pull_on_open)
                        end,
                    },
                    {
                        text = _("Auto push on book close"),
                        checked_func = function()
                            return self.auto_push_on_close
                        end,
                        callback = function()
                            self:saveSetting("auto_push_on_close", not self.auto_push_on_close)
                        end,
                    },
                    {
                        text = _("Offline queue enabled"),
                        checked_func = function()
                            return self.offline_queue_enabled
                        end,
                        callback = function()
                            self:saveSetting("offline_queue_enabled", not self.offline_queue_enabled)
                        end,
                    },
                    {
                        text = _("Enable Web Reader Bridge"),
                        checked_func = function()
                            return self.web_reader_bridge_enabled
                        end,
                        callback = function()
                            self:saveSetting("web_reader_bridge_enabled", not self.web_reader_bridge_enabled)
                        end,
                    },
                    {
                        text = _("Exact Web Reader position (EPUB only)"),
                        checked_func = function()
                            return self.cfi_conversion_enabled
                        end,
                        callback = function()
                            self:saveSetting("cfi_conversion_enabled", not self.cfi_conversion_enabled)
                        end,
                    },
                    {
                        text = _("Thresholds"),
                        sub_item_table = {
                            {
                                text = _("Progress threshold (%)"),
                                callback = function()
                                    self:showNumberInput(_("Progress threshold (%)"), self.threshold_percent, "1.0", function(value)
                                        self:saveSetting("threshold_percent", value)
                                    end)
                                end,
                            },
                            {
                                text = _("Time threshold (minutes)"),
                                callback = function()
                                    self:showNumberInput(_("Time threshold (minutes)"), self.threshold_minutes, "5", function(value)
                                        self:saveSetting("threshold_minutes", value)
                                    end)
                                end,
                            },
                            {
                                text = _("Page threshold"),
                                callback = function()
                                    self:showNumberInput(_("Page threshold"), self.threshold_pages, "5", function(value)
                                        self:saveSetting("threshold_pages", value)
                                    end)
                                end,
                            },
                        },
                    },
                    {
                        text_func = function()
                            if not self.web_reader_bridge_enabled then
                                return _("Shared reading progress is off because the Web Reader bridge is disabled")
                            end
                            return self:isWebReaderSyncEnabled()
                                and _("Shared reading progress is active")
                                or _("Shared reading progress is off because Reading Sync is disabled")
                        end,
                        callback = function()
                            if not self.web_reader_bridge_enabled then
                                self:showMessage(_("Enable the Web Reader bridge first."), 4)
                            else
                                self:showMessage(_("Web Reader progress now follows Reading Sync automatically."), 4)
                            end
                        end,
                        enabled_func = function()
                            return current_document_match and self.web_reader_bridge_enabled
                        end,
                    },
                },
            },
            {
                text = _("Shelf Sync"),
                sub_item_table = {
                    {
                        text = _("Enable Shelf Sync"),
                        checked_func = function()
                            return self.shelf_sync_enabled
                        end,
                        callback = function()
                            self:saveSetting("shelf_sync_enabled", not self.shelf_sync_enabled)
                        end,
                    },
                    {
                        text_func = function()
                            local name = self.shelf_name and self.shelf_name ~= "" and self.shelf_name or _("(none)")
                            return T(_("Select Shelf: %1"), name)
                        end,
                        callback = function()
                            self:showShelfPicker()
                        end,
                    },
                    {
                        text_func = function()
                            local dir = self.download_dir and self.download_dir ~= "" and self.download_dir or _("(auto)")
                            return T(_("Download Directory: %1"), dir)
                        end,
                        callback = function()
                            self:configureDownloadDir()
                        end,
                    },
                    {
                        text = _("Use Original Filename"),
                        checked_func = function()
                            return self.shelf_use_original_filename
                        end,
                        callback = function()
                            self:saveSetting("shelf_use_original_filename", not self.shelf_use_original_filename)
                        end,
                    },
                    {
                        text = _("Auto-sync on Resume"),
                        checked_func = function()
                            return self.auto_sync_shelf_on_resume
                        end,
                        callback = function()
                            self:saveSetting("auto_sync_shelf_on_resume", not self.auto_sync_shelf_on_resume)
                        end,
                    },
                    {
                        text = _("Two-way Shelf Delete Sync"),
                        checked_func = function()
                            return self.two_way_shelf_delete_sync
                        end,
                        callback = function(touchmenu_instance)
                            if not self.two_way_shelf_delete_sync then
                                local confirm_spec = self:wrapUiSpec({
                                    text = _("Enable two-way shelf delete sync?\n\nTracked GrimmLink downloads will be mirrored between KOReader and the selected Grimmory shelf."),
                                    ok_text = _("Enable"),
                                    ok_callback = function()
                                        self:saveSetting("two_way_shelf_delete_sync", true)
                                        self:refreshTouchMenu(touchmenu_instance)
                                    end,
                                }, "GrimmLink Two-way Shelf Delete Sync Confirm")
                                UIManager:show(ConfirmBox:new(confirm_spec))
                            else
                                self:saveSetting("two_way_shelf_delete_sync", false)
                                self:refreshTouchMenu(touchmenu_instance)
                            end
                        end,
                    },
                    {
                        text = _("Delete .sdr When Removing"),
                        checked_func = function()
                            return self.delete_sdr_on_book_delete
                        end,
                        callback = function()
                            self:saveSetting("delete_sdr_on_book_delete", not self.delete_sdr_on_book_delete)
                        end,
                    },
                },
            },
            {
                text = _("Sync Shelf Now"),
                callback = function()
                    self:syncShelfNow()
                end,
            },
            {
                text = _("Sync Shared Reading Progress Now"),
                enabled_func = function()
                    return current_document_match
                end,
                callback = function()
                    if not current_document_match then
                        return
                    end
                    self:syncWebReaderBridgeNow(false)
                end,
            },
            {
                text = _("Annotation Sync"),
                sub_item_table = {
                    {
                        text = _("Sync Highlights / Notes"),
                        checked_func = function() return self.annotations_sync_enabled end,
                        callback = function()
                            self.annotations_sync_enabled = not self.annotations_sync_enabled
                            self:saveSetting("annotations_sync_enabled", self.annotations_sync_enabled)
                            if self.annotations then
                                self.annotations.annotations_sync_enabled = self.annotations_sync_enabled
                            end
                        end,
                    },
                    {
                        text = _("Sync Bookmarks"),
                        checked_func = function() return self.bookmarks_sync_enabled end,
                        callback = function()
                            self.bookmarks_sync_enabled = not self.bookmarks_sync_enabled
                            self:saveSetting("bookmarks_sync_enabled", self.bookmarks_sync_enabled)
                            if self.annotations then
                                self.annotations.bookmarks_sync_enabled = self.bookmarks_sync_enabled
                            end
                        end,
                    },
                    {
                        text = _("Sync Personal Rating"),
                        checked_func = function() return self.rating_sync_enabled end,
                        callback = function()
                            self.rating_sync_enabled = not self.rating_sync_enabled
                            self:saveSetting("rating_sync_enabled", self.rating_sync_enabled)
                            if self.annotations then
                                self.annotations.rating_sync_enabled = self.rating_sync_enabled
                            end
                        end,
                    },
                    {
                        text = _("Capture on Book Close"),
                        checked_func = function() return self.annotations_capture_on_close end,
                        callback = function()
                            self.annotations_capture_on_close = not self.annotations_capture_on_close
                            self:saveSetting("annotations_capture_on_close", self.annotations_capture_on_close)
                        end,
                    },
                    {
                        text = _("Capture Current Document Now"),
                        callback = function()
                            if not menuReady() then
                                self:showMessage(_("GrimmLink is still starting up"), 2)
                                return
                            end
                            local ok, captured = pcall(function()
                                return self:captureCurrentDocumentAnnotations()
                            end)
                            if ok and captured then
                                self:showMessage(_("Captured current annotations / bookmarks / rating into queue."), 3)
                            elseif ok then
                                self:showMessage(_("No annotations captured."), 3)
                            else
                                self:showMessage(T(_("Capture failed: %1"), tostring(captured)), 4)
                            end
                        end,
                    },
                    {
                        text = _("Pull Remote Annotations Now"),
                        enabled_func = function()
                            return current_document_match
                        end,
                        callback = function()
                            if not current_document_match then
                                return
                            end
                            self:pullCurrentDocumentAnnotations(false)
                        end,
                    },
                    {
                        text_func = function()
                            local n = safeDbCount("getPendingAnnotationCount")
                            if n == 0 then return _("Sync Annotations Now") end
                            return T(_("Sync Annotations Now (%1 pending)"), n)
                        end,
                        callback = function()
                            if not menuReady() then
                                self:showMessage(_("GrimmLink is still starting up"), 2)
                                return
                            end
                            local pull = self:pullCurrentDocumentAnnotations(true)
                            local r = self:syncPendingAnnotations(false)
                            self:showMessage(T(
                                _("Annotation sync\nPulled: %1 imported, %2 updated\nConflicts: %3\nPosted: %4\nFailed: %5"),
                                pull.imported or 0,
                                pull.updated or 0,
                                pull.conflicts or 0,
                                r.posted, r.failed), 4)
                        end,
                    },
                },
            },
            {
                text_func = function()
                    local pending_progress = safeDbCount("getPendingProgressCount")
                    local pending_sessions = safeDbCount("getPendingSessionCount")
                    local pending_annotations = safeDbCount("getPendingAnnotationCount")
                    if pending_progress == 0 and pending_sessions == 0 and pending_annotations == 0 then
                        return _("Sync Pending Now")
                    end
                    return T(_("Sync Pending Now (%1 P, %2 S, %3 A)"),
                        pending_progress, pending_sessions, pending_annotations)
                end,
                callback = function()
                    if not menuReady() then
                        self:showMessage(_("GrimmLink is still starting up"), 2)
                        return
                    end
                    self:syncPendingNow(false)
                end,
            },
              {
                  text = _("Show Local Cache Stats"),
                  callback = function()
                      if not menuReady() then
                          self:showMessage(_("GrimmLink is still starting up"), 2)
                          return
                      end
                      self:showPendingStats()
                  end,
              },
              {
                  text = _("Status / Debug"),
                  sub_item_table = {
                      {
                          text = _("Show Detailed Cache Stats"),
                          callback = function()
                              if not menuReady() then
                                  self:showMessage(_("GrimmLink is still starting up"), 2)
                                  return
                              end
                              self:showDetailedCacheStats()
                          end,
                      },
                      {
                          text = _("Dump Local DB Summary"),
                          callback = function()
                              if not menuReady() then
                                  self:showMessage(_("GrimmLink is still starting up"), 2)
                                  return
                              end
                              self:showLocalDbSummary()
                          end,
                      },
                      {
                          text = _("Clear Pending Progress"),
                          callback = function()
                              if not menuReady() then
                                  self:showMessage(_("GrimmLink is still starting up"), 2)
                                  return
                              end
                              self:clearPendingProgressQueue()
                          end,
                      },
                      {
                          text = _("Clear Stale Cache"),
                          callback = function()
                              if not menuReady() then
                                  self:showMessage(_("GrimmLink is still starting up"), 2)
                                  return
                              end
                              self:clearStaleCacheEntries()
                          end,
                      },
                      {
                          text = _("Clear Not Found Hashes"),
                          callback = function()
                              if not menuReady() then
                                  self:showMessage(_("GrimmLink is still starting up"), 2)
                                  return
                              end
                              self:clearNotFoundHashes()
                          end,
                      },
                      {
                          text = _("Export Debug Log"),
                          callback = function()
                              if not menuReady() then
                                  self:showMessage(_("GrimmLink is still starting up"), 2)
                                  return
                              end
                              self:exportDebugLog()
                          end,
                      },
                  },
              },
          },
      }
    menu_items.grimmlink = self:wrapUiSpec(menu_items.grimmlink, "GrimmLink Main Menu")
end

return Grimmlink
