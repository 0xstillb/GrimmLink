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
local _ok_lfs, lfs = pcall(require, "lfs")
if not _ok_lfs then lfs = nil end

local _gl_load_errors = {}
local function _glRequire(name)
    local ok, mod = pcall(require, name)
    if not ok then
        _gl_load_errors[#_gl_load_errors + 1] = name .. ": " .. tostring(mod)
        return {}
    end
    return mod
end

local Database   = _glRequire("grimmlink_database")
local APIClient  = _glRequire("grimmlink_api_client")
local FileLogger = _glRequire("grimmlink_file_logger")
local ShelfSync  = _glRequire("grimmlink_shelf_sync")
local Updater    = _glRequire("grimmlink_updater")
local MetadataExtractor = _glRequire("grimmlink_metadata_extractor")
local Util = _glRequire("grimmlink_util")
local PendingSync = _glRequire("grimmlink_pending_sync")
local ProgressSync = _glRequire("grimmlink_progress_sync")
local Deletion = _glRequire("grimmlink_deletion")
local Matching = _glRequire("grimmlink_matching")
local MenuActions = _glRequire("grimmlink_menu_actions")
local Constants = _glRequire("grimmlink_constants")
local DiagnosticsController = _glRequire("grimmlink_diagnostics_controller")
local ReadingCompletionController = _glRequire("grimmlink_reading_completion_controller")
local MetadataController = _glRequire("grimmlink_metadata_controller")
local MagicShelfController = _glRequire("grimmlink_magic_shelf_controller")
local FileManagerActions = _glRequire("grimmlink_filemanager_actions")
local ConnectionController = _glRequire("grimmlink_connection_controller")
local SettingsController = _glRequire("grimmlink_settings_controller")
local MenuBuilder = _glRequire("grimmlink_menu_builder")
local LifecycleController = _glRequire("grimmlink_lifecycle_controller")
local ShelfController = _glRequire("grimmlink_shelf_controller")

local _ = require("gettext")
local T = ffiutil.template
local unpack_values = table.unpack or unpack
local safeDbBoolCall
local safeDbValueCall

local function hasUtilFn(name)
    return Util and type(Util[name]) == "function"
end

local function callUtil(name, ...)
    if hasUtilFn(name) then
        return Util[name](...)
    end
    return nil
end

local Grimmlink = WidgetContainer:extend{
    name = "grimmlink",
    is_doc_only = false,
}

local DEFAULTS = Constants.DEFAULTS
local E_READER_FRIENDLY_PRESET = Constants.E_READER_FRIENDLY_PRESET
local DISK_SPACE_SAFETY_MARGIN_BYTES = Constants.DISK_SPACE_SAFETY_MARGIN_BYTES
local READ_STATUS_CAPABILITY_CACHE_SECONDS = Constants.READ_STATUS_CAPABILITY_CACHE_SECONDS
local DIR_PICKER_MAX_SCAN_ENTRIES = Constants.DIR_PICKER_MAX_SCAN_ENTRIES
local DIR_PICKER_MAX_SHOW_DIRS = Constants.DIR_PICKER_MAX_SHOW_DIRS
local READING_COMPLETION_PROMPT_THRESHOLD_PERCENT = Constants.READING_COMPLETION_PROMPT_THRESHOLD_PERCENT
local READING_COMPLETION_PROMPT_RESET_PERCENT = Constants.READING_COMPLETION_PROMPT_RESET_PERCENT
local READING_COMPLETION_PROMPT_STATE_KEY = Constants.READING_COMPLETION_PROMPT_STATE_KEY
local READING_COMPLETION_RATING_STATE_KEY = Constants.READING_COMPLETION_RATING_STATE_KEY
local READING_COMPLETION_END_DIALOG_INITIAL_DELAY_SECONDS = Constants.READING_COMPLETION_END_DIALOG_INITIAL_DELAY_SECONDS
local READING_COMPLETION_END_DIALOG_POLL_SECONDS = Constants.READING_COMPLETION_END_DIALOG_POLL_SECONDS
local READING_COMPLETION_END_DIALOG_MAX_ATTEMPTS = Constants.READING_COMPLETION_END_DIALOG_MAX_ATTEMPTS
local SETTINGS_BACKUP_SCHEMA_VERSION = Constants.SETTINGS_BACKUP_SCHEMA_VERSION
local SETTINGS_BACKUP_DIRECTORY_NAME = Constants.SETTINGS_BACKUP_DIRECTORY_NAME
local SETTINGS_BACKUP_FILE_NAME = Constants.SETTINGS_BACKUP_FILE_NAME
local LOCAL_DIAGNOSTICS_SCHEMA_VERSION = Constants.LOCAL_DIAGNOSTICS_SCHEMA_VERSION
local LOCAL_DIAGNOSTICS_DIRECTORY_NAME = Constants.LOCAL_DIAGNOSTICS_DIRECTORY_NAME
local LOCAL_DIAGNOSTICS_FILE_NAME = Constants.LOCAL_DIAGNOSTICS_FILE_NAME
local HISTORICAL_IMPORT_DEFAULT_FILE_NAME = Constants.HISTORICAL_IMPORT_DEFAULT_FILE_NAME
local HISTORICAL_IMPORT_GAP_SECONDS = Constants.HISTORICAL_IMPORT_GAP_SECONDS
local SETTINGS_BACKUP_KEYS = Constants.SETTINGS_BACKUP_KEYS
local FIXED_PAGE_FORMATS = Constants.FIXED_PAGE_FORMATS
local REFLOWABLE_FORMATS = Constants.REFLOWABLE_FORMATS

local function safeToString(value)
    local util_value = callUtil("safeToString", value)
    if util_value ~= nil then
        return util_value
    end
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function normalizeIntegerInRange(value, min_value, max_value)
    local number = tonumber(value)
    if not number then
        return nil
    end
    number = math.floor(number + 0.0)
    if number < min_value or number > max_value then
        return nil
    end
    return number
end

local function normalizeTenScaleRating(value)
    return normalizeIntegerInRange(value, 1, 10)
end

local function normalizeFiveScaleRating(value)
    return normalizeIntegerInRange(value, 1, 5)
end

local function convertTenScaleRatingToSummaryRating(value)
    local ten_scale_rating = normalizeTenScaleRating(value)
    if not ten_scale_rating then
        return nil
    end
    return math.ceil(ten_scale_rating / 2)
end

local function buildReadingCompletionRatingState(value, summary_rating)
    local ten_scale_rating = normalizeTenScaleRating(value)
    local five_scale_rating = normalizeFiveScaleRating(summary_rating)
    if not ten_scale_rating or not five_scale_rating then
        return nil
    end
    return {
        value = ten_scale_rating,
        scale = 10,
        summary_rating = five_scale_rating,
    }
end

local function readReadingCompletionRatingState(doc_settings, summary_rating)
    if not doc_settings then
        return nil
    end
    local state = nil
    if type(doc_settings.readSetting) == "function" then
        local ok, value = pcall(doc_settings.readSetting, doc_settings, READING_COMPLETION_RATING_STATE_KEY)
        if ok then
            state = value
        else
            ok, value = pcall(doc_settings.readSetting, READING_COMPLETION_RATING_STATE_KEY)
            if ok then
                state = value
            end
        end
    end
    if type(state) ~= "table" then
        return nil
    end

    local ten_scale_rating = normalizeTenScaleRating(state.value)
    local five_scale_rating = normalizeFiveScaleRating(state.summary_rating or state.raw or state.koreader_rating)
    if not ten_scale_rating or not five_scale_rating then
        return nil
    end

    local current_summary_rating = normalizeFiveScaleRating(summary_rating)
    if current_summary_rating and current_summary_rating ~= five_scale_rating then
        return nil
    end

    return {
        value = ten_scale_rating,
        scale = 10,
        summary_rating = five_scale_rating,
    }
end

local function normalizeMetadataRatingPayload(payload)
    local value = tonumber(payload and payload.rating)
    if not value then
        return nil
    end
    value = math.floor(value + 0.5)

    local scale = math.floor(tonumber(payload and payload.ratingScale) or 0)
    if scale == 10 then
        if value < 1 or value > 10 then
            return nil
        end
        return {
            value = value,
            scale = 10,
            normalized = value,
        }
    end

    if scale == 0 then
        scale = 5
    end
    if scale ~= 5 or value < 1 or value > 5 then
        return nil
    end
    return {
        value = value,
        scale = 5,
        normalized = value * 2,
    }
end

local function isNonEmpty(value)
    return value ~= nil and tostring(value) ~= ""
end

local function isNumericOnlyToken(value)
    if value == nil then
        return false
    end
    local token = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" then
        return false
    end
    return token:match("^[+-]?%d+%.?%d*$") ~= nil
end

local function cloneTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function nowUtc()
    return os.time()
end

local function toIso8601(epoch_seconds)
    local util_value = callUtil("toIso8601", epoch_seconds)
    if util_value ~= nil then
        return util_value
    end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch_seconds)
end

local function formatTimestamp(epoch_seconds)
    if hasUtilFn("formatTimestamp") then
        local value = Util.formatTimestamp(epoch_seconds)
        if value and value ~= "unknown" then
            return value
        end
    end
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

local function countMapKeys(value)
    if type(value) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    return count
end

local function roundToSingleDecimal(value)
    if value == nil then
        return nil
    end
    return math.floor((tonumber(value) or 0) * 10 + 0.5) / 10
end

local function normalizePercent(value)
    local util_value = callUtil("normalizePercent", value)
    if util_value ~= nil then
        return util_value
    end
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

local function historicalPageToPercent(page, total_pages)
    local normalized_page = tonumber(page)
    local normalized_total = tonumber(total_pages)
    if not normalized_page or not normalized_total or normalized_total <= 0 then
        return 0
    end
    if normalized_page < 0 then
        normalized_page = 0
    end
    if normalized_page > normalized_total then
        normalized_page = normalized_total
    end
    return normalizePercent((normalized_page / normalized_total) * 100) or 0
end

local function absDifference(a, b)
    if a == nil or b == nil then
        return nil
    end
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0))
end

local function sanitizeTitle(file_path)
    local title = safeToString(file_path):match("([^/\\]+)$") or safeToString(file_path)
    return title:gsub("%.[^.]+$", "")
end

local function normalizeUpdateChannel(value)
    return value == "prerelease" and "prerelease" or "stable"
end

local function normalizeShelfType(value)
    local util_value = callUtil("normalizeShelfType", value)
    if util_value ~= nil then
        return util_value
    end
    local shelf_type = tostring(value or "regular"):lower()
    if shelf_type ~= "magic" then
        return "regular"
    end
    return shelf_type
end

local function shellQuote(value)
    local raw = safeToString(value)
    return "'" .. raw:gsub("'", [["'"']]) .. "'"
end

local function parseDfAvailableBytes(output)
    local text = safeToString(output)
    local available_kb = nil
    for line in text:gmatch("[^\r\n]+") do
        local candidate = line:match("^%S+%s+%d+%s+%d+%s+(%d+)%s+%S+%s+.+$")
        if candidate then
            available_kb = tonumber(candidate)
        end
    end
    if not available_kb then
        return nil
    end
    return math.max(0, available_kb) * 1024
end

local function normalizeManualReadStatus(value)
    local normalized = safeToString(value):upper()
    if normalized == "" then
        return nil
    end
    if normalized == "ON_HOLD" then
        return "PAUSED"
    end
    return normalized
end

local function stableTextHash(value)
    local text = safeToString(value)
    if text == "" then
        return ""
    end
    local ok_sha2, sha2 = pcall(require, "ffi/sha2")
    if ok_sha2 and sha2 and type(sha2.md5) == "function" then
        return sha2.md5(text)
    end
    local fallback = text:gsub("%s+", " "):sub(1, 32)
    return fallback:gsub("[^%w%-_]", "_")
end

local function shortPrefix(value, max_len)
    local text = safeToString(value)
    local length = tonumber(max_len) or 8
    if text == "" then
        return "-"
    end
    if #text <= length then
        return text
    end
    return text:sub(1, length)
end

local function redactSimple(value, keep_prefix)
    local util_value = callUtil("redactSimple", value, keep_prefix)
    if util_value ~= nil then
        return util_value
    end
    local text = safeToString(value)
    if text == "" then
        return ""
    end
    local keep = tonumber(keep_prefix) or 0
    if keep <= 0 then
        return "[REDACTED]"
    end
    if #text <= keep then
        return text
    end
    return text:sub(1, keep) .. "..."
end

local function redactUrl(url)
    local util_value = callUtil("redactUrl", url)
    if util_value ~= nil then
        return util_value
    end
    local text = safeToString(url)
    if text == "" then
        return ""
    end
    local protocol, host = text:match("^(https?://)([^/%?]+)")
    if protocol and host then
        local host_prefix = host:sub(1, math.min(#host, 4))
        return protocol .. host_prefix .. "..."
    end
    return redactSimple(text, 8)
end

local function formatUrlForDisplay(url, max_len)
    local util_value = callUtil("formatUrlForDisplay", url, max_len)
    if util_value ~= nil then
        return util_value
    end
    local text = safeToString(url)
    if text == "" then
        return ""
    end

    local limit = tonumber(max_len) or 60
    local cleaned = text:gsub("%?.*$", ""):gsub("#.*$", "")
    local protocol, host, path = cleaned:match("^(https?://)([^/%?]+)(/?.*)$")
    if not protocol or not host then
        if #cleaned <= limit then
            return cleaned
        end
        return cleaned:sub(1, limit - 3) .. "..."
    end

    local normalized_path = safeToString(path):gsub("^/*", "")
    if normalized_path == "" then
        local base = protocol .. host
        if #base <= limit then
            return base
        end
        return base:sub(1, limit - 3) .. "..."
    end

    local last_segment = normalized_path:match("([^/\\]+)$") or normalized_path
    local compact = protocol .. host .. "/.../" .. last_segment
    if #compact <= limit then
        return compact
    end

    local host_only = protocol .. host
    if #host_only <= limit then
        return host_only
    end
    return host_only:sub(1, limit - 3) .. "..."
end

local function normalizeNickname(value)
    local text = safeToString(value)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function normalizeDeviceIdentityText(value, fallback, max_len)
    local text = safeToString(value)
    text = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if text == "" then
        text = safeToString(fallback)
    end
    local limit = tonumber(max_len) or 80
    if limit > 0 and #text > limit then
        text = text:sub(1, limit)
    end
    return text
end

local function normalizeSsid(value)
    local ssid = safeToString(value)
    ssid = ssid:gsub("^%s+", ""):gsub("%s+$", "")
    return ssid
end

local function normalizeSsidForCompare(value)
    return normalizeSsid(value):lower()
end

local function ssidEquals(left, right)
    local a = normalizeSsidForCompare(left)
    local b = normalizeSsidForCompare(right)
    if a == "" or b == "" then
        return false
    end
    return a == b
end

local function isValidHttpUrl(url)
    local text = safeToString(url)
    if text == "" then
        return false
    end
    return text:match("^https?://[%w%._%-:%[%]]+") ~= nil
end

local function basenameOf(path)
    local value = safeToString(path)
    if value == "" then
        return ""
    end
    return value:match("([^/\\]+)$") or value
end

local function normalizeDirectoryPath(path)
    local util_value = callUtil("normalizeDirectoryPath", path)
    if util_value ~= nil then
        return util_value
    end
    local value = safeToString(path):gsub("\\", "/")
    if value == "" then
        return ""
    end
    value = value:gsub("/+$", "")
    if value == "" then
        return "/"
    end
    return value
end

local function joinDirectoryPath(base, child)
    local normalized_base = normalizeDirectoryPath(base)
    if normalized_base == "/" then
        return "/" .. safeToString(child)
    end
    return normalized_base .. "/" .. safeToString(child)
end

local function parentDirectoryPath(path)
    local normalized = normalizeDirectoryPath(path)
    if normalized == "" or normalized == "/" then
        return "/"
    end
    local parent = normalized:match("^(.*)/[^/]+$")
    if not parent or parent == "" then
        return "/"
    end
    return parent
end

local function detectPluginDir()
    local source = debug.getinfo(1, "S").source or ""
    local from_source = source:match("^@(.*)[/\\]main%.lua$")
    if from_source and from_source:match("grimmlink%.koplugin$") then
        return from_source
    end
    return DataStorage:getDataDir() .. "/plugins/grimmlink.koplugin"
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

local function tryWriteSetting(doc_settings, key, value)
    if not doc_settings then
        return false
    end
    local methods = { "saveSetting", "writeSetting", "setSetting", "set" }
    for _, method_name in ipairs(methods) do
        if type(doc_settings[method_name]) == "function" then
            local ok = pcall(doc_settings[method_name], doc_settings, key, value)
            if ok then
                return true
            end
            ok = pcall(doc_settings[method_name], key, value)
            if ok then
                return true
            end
        end
    end
    return false
end

local function tryFlushDocSettings(doc_settings)
    if not doc_settings then
        return false
    end
    local methods = { "flush", "save" }
    for _, method_name in ipairs(methods) do
        if type(doc_settings[method_name]) == "function" then
            local ok = pcall(doc_settings[method_name], doc_settings)
            if ok then
                return true
            end
            ok = pcall(doc_settings[method_name])
            if ok then
                return true
            end
        end
    end
    return false
end

local function tryCloseDocSettings(doc_settings)
    if not doc_settings or type(doc_settings.close) ~= "function" then
        return false
    end
    local ok = pcall(doc_settings.close, doc_settings)
    if ok then
        return true
    end
    return pcall(doc_settings.close)
end

function Grimmlink:log(level, ...)
    local args = { ... }
    if level == "warn" then
        logger.warn(unpack_values(args))
    elseif level == "err" then
        logger.err(unpack_values(args))
    elseif level == "dbg" then
        if self.debug_logging then
            logger.dbg(unpack_values(args))
        end
    else
        logger.info(unpack_values(args))
    end

    if self.file_logger and self.log_to_file then
        self.file_logger:write(level:upper(), unpack_values(args))
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

function Grimmlink:isReady(require_api)
    if not self.enabled then
        return false
    end
    if not self.db then
        return false
    end
    if require_api and not self:isApiReady() then
        return false
    end
    return true
end

function Grimmlink:isApiReady(required_methods)
    if not self.api or type(self.api.init) ~= "function" then
        return false
    end
    for _, method in ipairs(required_methods or {}) do
        if type(self.api[method]) ~= "function" then
            return false
        end
    end
    return true
end

function Grimmlink:requireReady(opts)
    opts = opts or {}
    if self:isReady(opts.require_api) then
        return true
    end
    if not opts.silent then
        self:showMessage(_("GrimmLink is still starting up"), 2)
    end
    return false
end

function Grimmlink:invokeSafely(_label, fn, args)
    if type(fn) ~= "function" then
        return nil, false
    end
    return pcall(fn, unpack_values(args or {}))
end

function Grimmlink:redactSSID(ssid)
    local normalized = normalizeSsid(ssid)
    if normalized == "" then
        return ""
    end
    if #normalized <= 4 then
        return normalized:sub(1, 1) .. "***"
    end
    local prefix_len = math.min(3, #normalized - 1)
    local suffix_len = math.min(2, #normalized - prefix_len)
    return normalized:sub(1, prefix_len) .. "***" .. normalized:sub(#normalized - suffix_len + 1)
end

function Grimmlink:ensureMainMenuRegistered()
    if self._menu_registered then
        return true
    end
    if self.ui and self.ui.menu and type(self.ui.menu.registerToMainMenu) == "function" then
        local ok = pcall(function()
            self.ui.menu:registerToMainMenu(self)
        end)
        if ok then
            self._menu_registered = true
            return true
        end
    end
    return false
end

function Grimmlink:scheduleMenuRegistrationRetry()
    if self._menu_registered then
        return
    end
    self._menu_register_attempts = (self._menu_register_attempts or 0) + 1
    if self._menu_register_attempts > 8 then
        return
    end
    if UIManager and type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(0.25, function()
            if not self:ensureMainMenuRegistered() then
                self:scheduleMenuRegistrationRetry()
            end
        end)
    end
end

function Grimmlink:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 3,
    })
end

-- Shelf sync status popup controller.
-- Keeps at most one popup alive during shelf sync progress updates to avoid
-- stacked/toast spam when many progress callbacks fire in a short burst.
function Grimmlink:closeShelfSyncMessage()
    self._shelf_sync_message_pending = nil
    self._shelf_sync_message_flush_scheduled = nil
    if self._shelf_sync_message_widget then
        pcall(UIManager.close, UIManager, self._shelf_sync_message_widget)
        self._shelf_sync_message_widget = nil
    end
end

function Grimmlink:showShelfSyncMessage(text, timeout)
    self._shelf_sync_message_pending = {
        text = text,
        timeout = timeout or 2,
    }
    if self._shelf_sync_message_flush_scheduled then
        return
    end
    self._shelf_sync_message_flush_scheduled = true
    self:runAfterUiSettles(function()
        self._shelf_sync_message_flush_scheduled = nil
        local pending = self._shelf_sync_message_pending
        if not pending then
            return
        end
        self._shelf_sync_message_pending = nil

        if self._shelf_sync_message_widget then
            pcall(UIManager.close, UIManager, self._shelf_sync_message_widget)
            self._shelf_sync_message_widget = nil
        end

        local widget = InfoMessage:new{
            text = pending.text,
            timeout = pending.timeout or 2,
        }
        self._shelf_sync_message_widget = widget
        UIManager:show(widget)
    end)
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

function Grimmlink:isOnline()
    local ok, network = pcall(function()
        return NetworkMgr
    end)
    if not ok or not network then
        return false
    end
    if type(network.isConnected) == "function" then
        local connected = network.isConnected(network)
        if connected ~= nil then
            return connected and true or false
        end
    end
    if type(network.isOnline) == "function" then
        local online = network.isOnline(network)
        if online ~= nil then
            return online and true or false
        end
    end
    return false
end

function Grimmlink:isTrackingEnabled(file_hash, file_path)
    if not self.db or type(self.db.isTrackingEnabled) ~= "function" then
        return true
    end
    local ok, enabled = pcall(self.db.isTrackingEnabled, self.db, file_hash, file_path)
    if not ok then
        return true
    end
    return enabled ~= false
end

function Grimmlink:setTrackingEnabled(file_hash, file_path, enabled)
    if not self.db or type(self.db.setTrackingEnabled) ~= "function" then
        return false
    end
    local ok, result = pcall(self.db.setTrackingEnabled, self.db, file_hash, file_path, enabled)
    return ok and result == true or false
end

function Grimmlink:toggleTracking(file_hash, file_path)
    if not self.db or type(self.db.toggleTracking) ~= "function" then
        return nil
    end
    local ok, toggled = pcall(self.db.toggleTracking, self.db, file_hash, file_path)
    if not ok then
        return nil
    end
    return toggled
end

function Grimmlink:isTrackingEnabledForContext(context)
    if type(context) ~= "table" then
        return true
    end
    if not self.db then
        return true
    end
    local ok, enabled = pcall(self.db.isTrackingEnabled, self.db, context.file_hash, context.file_path)
    if not ok then
        return true
    end
    return enabled ~= false
end

function Grimmlink:getCurrentDocumentContext()
    local file_path = nil
    local file_hash = nil
    local book_id = nil
    local book_file_id = nil

    if self.current_session then
        file_path = self.current_session.file_path
        file_hash = self.current_session.file_hash
        book_id = self.current_session.book_id
        book_file_id = self.current_session.book_file_id
    elseif self.ui and self.ui.document and self.ui.document.file then
        file_path = tostring(self.ui.document.file)
    end

    if not file_path or file_path == "" then
        return nil
    end
    if (not file_hash or file_hash == "") and type(self.calculateBookHash) == "function" then
        local ok_hash, value = pcall(self.calculateBookHash, self, file_path)
        if ok_hash then
            file_hash = value
        end
    end
    if (not book_id or not book_file_id) and type(self.resolveBookByFilePath) == "function" then
        local ok_cached, cached = pcall(self.resolveBookByFilePath, self, file_path)
        if ok_cached and type(cached) == "table" then
            file_hash = file_hash or cached.file_hash
            book_id = book_id or cached.book_id
            book_file_id = book_file_id or cached.book_file_id
        end
    end

    return {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
    }
end

function Grimmlink:showTrackingDisabledMessage()
    self:showMessage(_("Tracking disabled for this book"), 3)
end

function Grimmlink:formatDuration(duration_seconds)
    local total = math.max(0, math.floor(tonumber(duration_seconds) or 0))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local seconds = total % 60
    local parts = {}
    if hours > 0 then
        parts[#parts + 1] = T(_("%1h"), hours)
    end
    if hours > 0 or minutes > 0 then
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
    if extension == "CBZ" or extension == "CBR" or extension == "CB7" then
        return "CBX"
    end
    if extension == "DJVU" or extension == "DJV" then
        return "DJVU"
    end
    if extension == "MOBI" then
        return "MOBI"
    end
    if extension == "AZW" or extension == "AZW3" then
        return "AZW3"
    end
    if extension == "FB2" then
        return "FB2"
    end
    if extension == "HTML" or extension == "HTM" then
        return "HTML"
    end
    if extension == "TXT" then
        return "TXT"
    end
    if extension == "DOCX" then
        return "DOCX"
    end
    return "EPUB"
end

function Grimmlink:normalizeFormatToken(value)
    if value == nil then
        return nil
    end
    local token = safeToString(value):gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" then
        return nil
    end
    token = token:upper()
    if token == "CBZ" or token == "CBR" or token == "CB7" then
        return "CBX"
    end
    return token
end

function Grimmlink:isFixedPageFormat(file_path, book_type, file_format)
    local format = self:normalizeFormatToken(file_format)
        or self:normalizeFormatToken(book_type)
        or self:normalizeFormatToken(self:getBookType(file_path))
    return format ~= nil and FIXED_PAGE_FORMATS[format] == true
end

function Grimmlink:isReflowableFormat(file_path, book_type, file_format)
    if self:isFixedPageFormat(file_path, book_type, file_format) then
        return false
    end
    local format = self:normalizeFormatToken(file_format)
        or self:normalizeFormatToken(book_type)
        or self:normalizeFormatToken(self:getBookType(file_path))
    if format == nil then
        return true
    end
    if REFLOWABLE_FORMATS[format] == true then
        return true
    end
    return not FIXED_PAGE_FORMATS[format]
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

function Grimmlink:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local current_page, total_pages = self:getCurrentPageInfo()
    local document = self.ui and self.ui.document or nil
    local file_format = self:getBookType(file_path)
    local is_fixed_page = self:isFixedPageFormat(file_path, file_format, file_format)
    local is_reflowable = self:isReflowableFormat(file_path, file_format, file_format)
    local allow_reflowable_percentage = self.send_reflowable_percentage == true
    local raw_location = nil

    if document then
        local position = safeMethodCall(document, "getCurrentPos")
        local xpointer = safeMethodCall(document, "getXPointer")
        if is_fixed_page and current_page and file_format == "PDF" then
            raw_location = tostring(current_page)
        else
            raw_location = xpointer
            if raw_location == nil then
                raw_location = safeMethodCall(document, "getCurrentLocation")
            end
            if raw_location == nil then
                raw_location = position
            end
            if is_reflowable and isNumericOnlyToken(raw_location) then
                raw_location = nil
            end
        end
    end

    if (raw_location == nil or (is_reflowable and isNumericOnlyToken(raw_location))) and self.ui and self.ui.doc_settings then
        local last_xpointer = tryReadSetting(self.ui.doc_settings, "last_xpointer")
        if isNonEmpty(last_xpointer) and (not is_reflowable or not isNumericOnlyToken(last_xpointer)) then
            raw_location = last_xpointer
        end
    end
    if raw_location == nil then
        if is_fixed_page and current_page then
            raw_location = current_page
        end
    end

    local percentage = nil
    if current_page and total_pages and total_pages > 0 and (is_fixed_page or allow_reflowable_percentage) then
        percentage = normalizePercent((current_page / total_pages) * 100)
    end

    local snapshot = {
        timestamp = nowUtc(),
        document = file_hash or file_path,
        bookHash = file_hash,
        bookId = book_id,
        bookFileId = book_file_id,
        fileFormat = file_format,
        bookType = file_format,
        progress = safeToString(raw_location),
        location = safeToString(raw_location),
        percentage = percentage,
        currentPage = current_page,
        totalPages = total_pages,
        device = self.device_name,
        deviceId = self.device_id,
        file_path = file_path,
    }

    if snapshot.progress == "" and snapshot.currentPage and is_fixed_page then
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
    normalized.bookId = maybeNumber(normalized.bookId)
    normalized.bookFileId = maybeNumber(normalized.bookFileId or normalized.book_file_id)
    normalized.percentage = normalizePercent(normalized.percentage)
    normalized.currentPage = maybeNumber(normalized.currentPage)
    normalized.totalPages = maybeNumber(normalized.totalPages)
    normalized.timestamp = maybeNumber(normalized.timestamp or normalized.updatedAt)
    normalized.deviceId = normalized.deviceId or normalized.device_id
    normalized.bookType = normalized.bookType or normalized.fileFormat
    normalized.fileFormat = normalized.fileFormat and tostring(normalized.fileFormat):upper() or nil
    normalized.location = isNonEmpty(normalized.location) and tostring(normalized.location)
        or (isNonEmpty(normalized.progress) and tostring(normalized.progress) or nil)
    normalized.progress = isNonEmpty(normalized.progress) and tostring(normalized.progress)
        or normalized.location
    normalized.source = normalized.source or normalized.device or normalized.fileFormat
    return self:applyFormatProgressPolicy(normalized)
end

function Grimmlink:applyFormatProgressPolicy(snapshot)
    if not snapshot or type(snapshot) ~= "table" then
        return snapshot
    end

    if self:isReflowableFormat(snapshot.file_path, snapshot.bookType, snapshot.fileFormat) then
        if self.send_reflowable_percentage ~= true then
            snapshot.percentage = nil
        end
        snapshot.cfi = nil
    end

    return snapshot
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

    local left_reflowable = self:isReflowableFormat(left.file_path, left.bookType, left.fileFormat)
    local right_reflowable = self:isReflowableFormat(right.file_path, right.bookType, right.fileFormat)
    local both_reflowable = left_reflowable and right_reflowable

    if not both_reflowable then
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
    end

    if isNonEmpty(left.location) and isNonEmpty(right.location) and tostring(left.location) ~= tostring(right.location) then
        return true
    end

    return false
end

function Grimmlink:shouldPromptBeforeApplyingRemoteProgress(local_snapshot, remote_snapshot)
    if not self:hasMeaningfulProgress(remote_snapshot) then
        return false
    end
    if not self:hasMeaningfulProgress(local_snapshot) then
        return true
    end
    return self:progressDifferenceExceeded(local_snapshot, remote_snapshot)
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
        bookType = state.book_type,
        fileFormat = state.book_type,
        file_path = state.file_path,
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
        source = state.remote_source,
        bookType = state.book_type,
        fileFormat = state.book_type,
        file_path = state.file_path,
    }
end

function Grimmlink:compareOpenProgress(local_snapshot, remote_snapshot, state)
    if not self:hasMeaningfulProgress(remote_snapshot) then
        return "none"
    end

    if not self:hasMeaningfulProgress(local_snapshot) then
        return "remote_newer"
    end

    if not state then
        if self:progressDifferenceExceeded(local_snapshot, remote_snapshot) then
            return "remote_newer"
        end
        return "same"
    end

    local previous_local = self:buildStoredLocalSnapshot(state)
    local previous_remote = self:buildStoredRemoteSnapshot(state)

    if not self:progressDifferenceExceeded(local_snapshot, remote_snapshot) then
        return "same"
    end

    local local_changed = previous_local and self:progressDifferenceExceeded(local_snapshot, previous_local) or false
    local remote_changed = previous_remote and self:progressDifferenceExceeded(remote_snapshot, previous_remote) or false

    if (not previous_local and not previous_remote) or (not local_snapshot.timestamp or not remote_snapshot.timestamp) then
        return "conflict"
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
    if not self.db or not file_hash or not snapshot then
        return
    end

    self.db:upsertLocalProgressState(file_hash, {
        file_path = snapshot.file_path,
        book_id = snapshot.bookId,
        document = snapshot.document,
        book_type = snapshot.bookType or snapshot.fileFormat,
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
    if not self.db or not file_hash or not snapshot then
        return
    end

    self.db:upsertRemoteProgressState(file_hash, {
        file_path = snapshot.file_path,
        book_id = snapshot.bookId,
        document = snapshot.document,
        book_type = snapshot.bookType or snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        current_page = snapshot.currentPage,
        total_pages = snapshot.totalPages,
        device = snapshot.device,
        device_id = snapshot.deviceId or snapshot.device_id,
        source = snapshot.source,
        timestamp = snapshot.timestamp,
        last_action = action,
    })
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
            return true
        end

        for _, candidate in ipairs(candidates) do
            local result, ok = safeMethodCall(candidate[1], candidate[2], target_page)
            if ok and result ~= false and pageReached(page) then
                return true
            end
        end
    end

    return false
end

function Grimmlink:jumpToLocation(location, opts)
    opts = opts or {}
    if location == nil or tostring(location) == "" then
        return false
    end

    local numeric_page = nil
    if opts.allow_numeric_page ~= false then
        numeric_page = tonumber(location)
    end
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

function Grimmlink:documentHasPages()
    local document_info = self.ui and self.ui.document and self.ui.document.info
    if document_info and document_info.has_pages ~= nil then
        return document_info.has_pages and true or false
    end
    return self.ui and self.ui.paging ~= nil or false
end

function Grimmlink:applyRemoteProgress(remote_snapshot, opts)
    opts = opts or {}
    if not remote_snapshot then
        return false
    end

    self._last_progress_apply_error = nil
    local file_format = remote_snapshot.fileFormat and tostring(remote_snapshot.fileFormat):upper() or nil
    local book_type = remote_snapshot.bookType or file_format
    local is_reflowable = self:isReflowableFormat(remote_snapshot.file_path, book_type, file_format)

    if is_reflowable then
        local location_value = isNonEmpty(remote_snapshot.location) and tostring(remote_snapshot.location) or nil
        local progress_value = isNonEmpty(remote_snapshot.progress) and tostring(remote_snapshot.progress) or nil
        local location_is_native = location_value and not isNumericOnlyToken(location_value)
        local progress_is_native = progress_value and not isNumericOnlyToken(progress_value)
        local native_location = location_is_native and location_value
            or (progress_is_native and progress_value or nil)
        if not isNonEmpty(native_location) then
            self._last_progress_apply_error = _("No KOReader-native location available for this book.")
            return false
        end
        if self:jumpToLocation(native_location, { allow_numeric_page = false }) then
            return true
        end
        return false
    end

    local target_page = self:getRemotePageTarget(remote_snapshot)
    local prefer_page = opts.prefer_page == true or file_format == "PDF"

    if prefer_page and target_page and self:jumpToPage(target_page) then
        return true
    end

    if isNonEmpty(remote_snapshot.location) and self:jumpToLocation(remote_snapshot.location) then
        return true
    end

    if remote_snapshot.currentPage and self:jumpToPage(remote_snapshot.currentPage) then
        return true
    end

    local _, total_pages = self:getCurrentPageInfo()
    if remote_snapshot.percentage and total_pages and total_pages > 0 then
        local page = math.max(1, math.floor((total_pages * remote_snapshot.percentage / 100) + 0.5))
        if self:jumpToPage(page) then
            return true
        end
    end

    return false
end

function Grimmlink:progressLabel(snapshot)
    if not snapshot then
        return _("unknown")
    end
    local percent = snapshot.percentage and string.format("%.1f%%", snapshot.percentage) or _("unknown")
    local page = snapshot.currentPage and snapshot.totalPages and string.format("%s / %s", snapshot.currentPage, snapshot.totalPages) or _("unknown")
    return T(_("%1, page %2"), percent, page)
end

function Grimmlink:sourceLabel(snapshot, mode)
    if mode == "pdf" then
        return _("Grimmory Web Reader")
    end
    if snapshot and isNonEmpty(snapshot.source) then
        return snapshot.source
    end
    if snapshot and isNonEmpty(snapshot.device) then
        return snapshot.device
    end
    return _("KOReader")
end

function Grimmlink:buildConflictDialogText(local_snapshot, remote_snapshot, mode)
    local local_percent = local_snapshot.percentage and string.format("%.1f%%", local_snapshot.percentage) or _("unknown")
    local remote_percent = remote_snapshot.percentage and string.format("%.1f%%", remote_snapshot.percentage) or _("unknown")
    local local_page = local_snapshot.currentPage and local_snapshot.totalPages
        and string.format("%s / %s", local_snapshot.currentPage, local_snapshot.totalPages)
        or _("unknown")
    local remote_page = remote_snapshot.currentPage and remote_snapshot.totalPages
        and string.format("%s / %s", remote_snapshot.currentPage, remote_snapshot.totalPages)
        or _("unknown")
    local remote_heading = mode == "pdf" and _("Web Reader:") or _("Remote:")
    local title = mode == "pdf"
        and _("Found newer Web Reader page")
        or _("Found different reading positions")

    return table.concat({
        title,
        "",
        _("Local:"),
        T(_("- progress: %1"), local_percent),
        T(_("- page: %1"), local_page),
        T(_("- updated: %1"), formatTimestamp(local_snapshot.timestamp)),
        T(_("- device: %1"), local_snapshot.device or _("unknown")),
        "",
        remote_heading,
        T(_("- progress: %1"), remote_percent),
        T(_("- page: %1"), remote_page),
        T(_("- updated: %1"), formatTimestamp(remote_snapshot.timestamp)),
        T(_("- source: %1"), self:sourceLabel(remote_snapshot, mode)),
    }, "\n")
end

function Grimmlink:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, mode)
    local dialog
    local use_remote_text = mode == "pdf" and _("Use Web Reader page") or _("Use Remote")
    local keep_local_text = mode == "pdf" and _("Keep KOReader position") or _("Keep Local")
    local remote_action = function()
        if dialog then
            UIManager:close(dialog)
        end
        if self:applyRemoteProgress(remote_snapshot, { prefer_page = mode == "pdf" }) then
            self:rememberRemoteSnapshot(file_hash, remote_snapshot, mode == "pdf" and "pdf-remote-use" or "remote-use")
            self:rememberLocalSnapshot(file_hash, remote_snapshot, mode == "pdf" and "pdf-remote-use" or "remote-use")
        else
            local message = self._last_progress_apply_error or _("Failed to jump to remote position")
            self._last_progress_apply_error = nil
            self:showMessage(message, 4)
        end
    end
    local local_action = function()
        if dialog then
            UIManager:close(dialog)
        end
        self:rememberLocalSnapshot(file_hash, local_snapshot, mode == "pdf" and "pdf-keep-local" or "keep-local")
    end
    local ignore_action = function()
        if dialog then
            UIManager:close(dialog)
        end
    end

    dialog = ButtonDialog:new{
        title = self:buildConflictDialogText(local_snapshot, remote_snapshot, mode),
        buttons = {
            {
                {
                    text = keep_local_text,
                    callback = local_action,
                },
                {
                    text = use_remote_text,
                    callback = remote_action,
                },
                {
                    text = _("Ignore this time"),
                    callback = ignore_action,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

function Grimmlink:classifyApiOutcome(code, response)
    if code == 404 then
        return "http_404", "permanent_not_found"
    end
    if code == 400 or code == 415 or code == 422 then
        return "http_" .. tostring(code), "permanent_invalid"
    end
    if code and code >= 500 then
        return "http_" .. tostring(code), "transient_http"
    end
    local response_text = safeToString(response):lower()
    if response_text:find("unsupported_format", 1, true) then
        return "http_415", "permanent_invalid"
    end
    if response_text:find("not found", 1, true) then
        return "http_404", "permanent_not_found"
    end
    return "unknown", "transient_unknown"
end

function Grimmlink:prepareNativeProgressPayload(snapshot)
    local payload = {
        document = snapshot.document,
        bookHash = snapshot.bookHash,
        bookId = snapshot.bookId,
        bookFileId = snapshot.bookFileId,
        fileFormat = snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        currentPage = snapshot.currentPage,
        totalPages = snapshot.totalPages,
        device = snapshot.device,
        deviceId = snapshot.deviceId,
        timestamp = snapshot.timestamp,
    }
    self:applyFormatProgressPolicy(payload)
    return {
        document = payload.document,
        bookHash = payload.bookHash,
        bookId = payload.bookId,
        bookFileId = payload.bookFileId,
        fileFormat = payload.fileFormat,
        progress = payload.progress,
        location = payload.location,
        percentage = payload.percentage,
        currentPage = payload.currentPage,
        totalPages = payload.totalPages,
        device = payload.device,
        deviceId = payload.deviceId,
        timestamp = payload.timestamp,
    }
end

function Grimmlink:preparePdfBridgePayload(snapshot, opts)
    opts = opts or {}
    local payload = {
        bookHash = snapshot.bookHash,
        bookFileId = snapshot.bookFileId,
        fileFormat = "PDF",
        currentPage = snapshot.currentPage,
        totalPages = snapshot.totalPages,
        percentage = snapshot.percentage,
        rawKoreaderLocation = snapshot.location,
        rawKoreaderProgress = snapshot.progress,
        source = "KOReader",
        device = snapshot.device,
        deviceId = snapshot.deviceId,
        timestamp = snapshot.timestamp,
    }
    if opts.expectedUpdatedAt then
        payload.expectedUpdatedAt = opts.expectedUpdatedAt
    end
    if opts.force ~= nil then
        payload.force = opts.force
    end
    return payload
end

function Grimmlink:loadWritableDocSettings(file_path)
    local active_file = self.ui and self.ui.document and self.ui.document.file or nil
    if self.ui and type(self.ui.doc_settings) == "table" and ((not file_path or file_path == "") or active_file == file_path) then
        return self.ui.doc_settings, false
    end
    if not file_path or file_path == "" then
        return nil, false
    end

    local ok_docsettings, docsettings = pcall(require, "docsettings")
    if not ok_docsettings or not docsettings then
        return nil, false
    end

    local loaders = {
        "open",
        "openDocSettings",
        "openDocSetting",
        "load",
        "new",
    }
    for _, loader in ipairs(loaders) do
        if type(docsettings[loader]) == "function" then
            local ok_loaded, loaded = pcall(docsettings[loader], file_path)
            if ok_loaded and type(loaded) == "table" then
                return loaded, true
            end
            ok_loaded, loaded = pcall(docsettings[loader], docsettings, file_path)
            if ok_loaded and type(loaded) == "table" then
                return loaded, true
            end
        end
    end
    return nil, false
end

function Grimmlink:getPluginVersionLabel()
    if not self.plugin_dir or self.plugin_dir == "" then
        return _("unknown")
    end
    local ok, info = pcall(dofile, self.plugin_dir .. "/plugin_version.lua")
    if ok and type(info) == "table" and info.version and info.version ~= "" then
        return tostring(info.version)
    end
    return _("unknown")
end

safeDbBoolCall = function(db, method_name, ...)
    if not db or type(db[method_name]) ~= "function" then
        return false
    end
    local ok, result = pcall(db[method_name], db, ...)
    return ok and result == true or false
end

safeDbValueCall = function(db, method_name, default_value, ...)
    if not db or type(db[method_name]) ~= "function" then
        return default_value
    end
    local ok, result = pcall(db[method_name], db, ...)
    if not ok or result == nil then
        return default_value
    end
    return result
end

if MenuBuilder and type(MenuBuilder.install) == "function" then
    MenuBuilder.install(Grimmlink, {
        ButtonDialog = ButtonDialog,
        ConfirmBox = ConfirmBox,
        UIManager = UIManager,
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
        _gl_load_errors = _gl_load_errors,
        normalizeDeviceIdentityText = normalizeDeviceIdentityText,
        normalizeShelfType = normalizeShelfType,
        normalizeUpdateChannel = normalizeUpdateChannel,
        safeDbValueCall = safeDbValueCall,
        safeToString = safeToString,
        shortPrefix = shortPrefix,
    })
end
if SettingsController and type(SettingsController.install) == "function" then
    SettingsController.install(Grimmlink, {
        ButtonDialog = ButtonDialog,
        ConfirmBox = ConfirmBox,
        DataStorage = DataStorage,
        InputDialog = InputDialog,
        UIManager = UIManager,
        lfs = lfs,
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
        E_READER_FRIENDLY_PRESET = E_READER_FRIENDLY_PRESET,
        DIR_PICKER_MAX_SCAN_ENTRIES = DIR_PICKER_MAX_SCAN_ENTRIES,
        DIR_PICKER_MAX_SHOW_DIRS = DIR_PICKER_MAX_SHOW_DIRS,
        joinDirectoryPath = joinDirectoryPath,
        normalizeDeviceIdentityText = normalizeDeviceIdentityText,
        normalizeDirectoryPath = normalizeDirectoryPath,
        nowUtc = nowUtc,
        parentDirectoryPath = parentDirectoryPath,
        safeToString = safeToString,
    })
end
if ConnectionController and type(ConnectionController.install) == "function" then
    ConnectionController.install(Grimmlink, {
        ConfirmBox = ConfirmBox,
        InfoMessage = InfoMessage,
        NetworkMgr = NetworkMgr,
        UIManager = UIManager,
        _ = _,
        T = T,
        formatUrlForDisplay = formatUrlForDisplay,
        normalizeNickname = normalizeNickname,
        normalizeSsid = normalizeSsid,
        nowUtc = nowUtc,
        safeToString = safeToString,
    })
end
if FileManagerActions and type(FileManagerActions.install) == "function" then
    FileManagerActions.install(Grimmlink, {
        FileManager = FileManager,
        UIManager = UIManager,
        _ = _,
        T = T,
        safeToString = safeToString,
        sanitizeTitle = sanitizeTitle,
    })
end
if MagicShelfController and type(MagicShelfController.install) == "function" then
    MagicShelfController.install(Grimmlink, {
        _ = _,
        T = T,
        joinDirectoryPath = joinDirectoryPath,
        normalizeDirectoryPath = normalizeDirectoryPath,
        safeToString = safeToString,
    })
end
if ReadingCompletionController and type(ReadingCompletionController.install) == "function" then
    ReadingCompletionController.install(Grimmlink, {
        ButtonDialog = ButtonDialog,
        UIManager = UIManager,
        _ = _,
        T = T,
        READ_STATUS_CAPABILITY_CACHE_SECONDS = READ_STATUS_CAPABILITY_CACHE_SECONDS,
        READING_COMPLETION_PROMPT_THRESHOLD_PERCENT = READING_COMPLETION_PROMPT_THRESHOLD_PERCENT,
        READING_COMPLETION_PROMPT_RESET_PERCENT = READING_COMPLETION_PROMPT_RESET_PERCENT,
        READING_COMPLETION_PROMPT_STATE_KEY = READING_COMPLETION_PROMPT_STATE_KEY,
        READING_COMPLETION_RATING_STATE_KEY = READING_COMPLETION_RATING_STATE_KEY,
        READING_COMPLETION_END_DIALOG_POLL_SECONDS = READING_COMPLETION_END_DIALOG_POLL_SECONDS,
        READING_COMPLETION_END_DIALOG_MAX_ATTEMPTS = READING_COMPLETION_END_DIALOG_MAX_ATTEMPTS,
        buildReadingCompletionRatingState = buildReadingCompletionRatingState,
        cloneTable = cloneTable,
        convertTenScaleRatingToSummaryRating = convertTenScaleRatingToSummaryRating,
        maybeNumber = maybeNumber,
        normalizeManualReadStatus = normalizeManualReadStatus,
        normalizeTenScaleRating = normalizeTenScaleRating,
        nowUtc = nowUtc,
        safeToString = safeToString,
        tryCloseDocSettings = tryCloseDocSettings,
        tryFlushDocSettings = tryFlushDocSettings,
        tryReadSetting = tryReadSetting,
        tryWriteSetting = tryWriteSetting,
    })
end
if DiagnosticsController and type(DiagnosticsController.install) == "function" then
    DiagnosticsController.install(Grimmlink, {
        DataStorage = DataStorage,
        json = json,
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
        SETTINGS_BACKUP_KEYS = SETTINGS_BACKUP_KEYS,
        SETTINGS_BACKUP_SCHEMA_VERSION = SETTINGS_BACKUP_SCHEMA_VERSION,
        SETTINGS_BACKUP_DIRECTORY_NAME = SETTINGS_BACKUP_DIRECTORY_NAME,
        SETTINGS_BACKUP_FILE_NAME = SETTINGS_BACKUP_FILE_NAME,
        LOCAL_DIAGNOSTICS_SCHEMA_VERSION = LOCAL_DIAGNOSTICS_SCHEMA_VERSION,
        LOCAL_DIAGNOSTICS_DIRECTORY_NAME = LOCAL_DIAGNOSTICS_DIRECTORY_NAME,
        LOCAL_DIAGNOSTICS_FILE_NAME = LOCAL_DIAGNOSTICS_FILE_NAME,
        HISTORICAL_IMPORT_DEFAULT_FILE_NAME = HISTORICAL_IMPORT_DEFAULT_FILE_NAME,
        HISTORICAL_IMPORT_GAP_SECONDS = HISTORICAL_IMPORT_GAP_SECONDS,
        _gl_load_errors = _gl_load_errors,
        basenameOf = basenameOf,
        cloneTable = cloneTable,
        countMapKeys = countMapKeys,
        formatTimestamp = formatTimestamp,
        historicalPageToPercent = historicalPageToPercent,
        isValidHttpUrl = isValidHttpUrl,
        maybeNumber = maybeNumber,
        normalizeDeviceIdentityText = normalizeDeviceIdentityText,
        normalizeDirectoryPath = normalizeDirectoryPath,
        normalizeShelfType = normalizeShelfType,
        nowUtc = nowUtc,
        parentDirectoryPath = parentDirectoryPath,
        redactSimple = redactSimple,
        redactUrl = redactUrl,
        roundToSingleDecimal = roundToSingleDecimal,
        safeDbBoolCall = safeDbBoolCall,
        safeDbValueCall = safeDbValueCall,
        safeToString = safeToString,
        shortPrefix = shortPrefix,
        toIso8601 = toIso8601,
    })
end
function Grimmlink:queueProgressSnapshot(snapshot, kind, payload)
    if not self.db or not self.offline_queue_enabled or not snapshot or not snapshot.bookHash then
        return false
    end

    local encoded = payload
    if type(encoded) ~= "string" then
        local ok, json_payload = pcall(json.encode, payload or self:prepareNativeProgressPayload(snapshot))
        if not ok then
            self:logErr("GrimmLink failed to encode pending progress payload")
            return false
        end
        encoded = json_payload
    end
    self.db:upsertPendingProgress(snapshot.bookHash, encoded, kind or "native")
    return true
end

function Grimmlink:pushProgressSnapshot(snapshot, reason, silent)
    if not snapshot or not snapshot.bookHash then
        return false
    end
    if not self:isTrackingEnabled(snapshot.bookHash, snapshot.file_path) then
        if not silent then
            self:showTrackingDisabledMessage()
        end
        return false
    end

    if not self:isApiReady({ "updateProgress" }) then
        self:queueProgressSnapshot(snapshot, "native", self:prepareNativeProgressPayload(snapshot))
        return false
    end
    if not self:refreshApiClient() then
        return false
    end
    if not self:isOnline() then
        self:queueProgressSnapshot(snapshot, "native", self:prepareNativeProgressPayload(snapshot))
        if not silent then
            self:showMessage(_("Saved progress to offline queue"), 2)
        end
        return false
    end

    local payload = self:prepareNativeProgressPayload(snapshot)
    local success, response, code = self.api:updateProgress(payload)
    if success then
        self:rememberLocalSnapshot(snapshot.bookHash, snapshot, reason or "progress-push")
        self:rememberRemoteSnapshot(snapshot.bookHash, snapshot, reason or "progress-push")
        if self.db and type(self.db.setProgressLastAction) == "function" then
            self.db:setProgressLastAction(snapshot.bookHash, reason or "progress-push")
        end
        return true
    end

    local _, api_error_class = self:classifyApiOutcome(code, response)
    self:logWarn("GrimmLink progress push failed:", response)
    if api_error_class == "permanent_not_found" or api_error_class == "permanent_invalid" then
        if not silent then
            self:showMessage(T(_("Progress sync failed:\n%1"), safeToString(response)), 4)
        end
        return false
    end

    self:queueProgressSnapshot(snapshot, "native", payload)
    if not silent then
        self:showMessage(T(_("Progress sync failed:\n%1"), safeToString(response)), 4)
    end
    return false
end

function Grimmlink:pushPdfWebProgress(snapshot, reason, silent)
    if not snapshot or not snapshot.bookHash or not snapshot.bookId then
        return false
    end
    if not self:isTrackingEnabled(snapshot.bookHash, snapshot.file_path) then
        if not silent then
            self:showTrackingDisabledMessage()
        end
        return false
    end
    if not self:isPdfWebReaderBridgeEnabled() then
        return false
    end
    if snapshot.fileFormat ~= "PDF" then
        return false
    end

    if not self:isApiReady({ "updatePdfProgress" }) then
        self:queueProgressSnapshot(snapshot, "pdf_bridge", {
            bookId = snapshot.bookId,
            bookHash = snapshot.bookHash,
            request = self:preparePdfBridgePayload(snapshot, {
                force = reason == "manual" or reason == "close",
            }),
        })
        return false
    end
    if not self:refreshApiClient() then
        return false
    end
    local payload = self:preparePdfBridgePayload(snapshot, {
        force = reason == "manual" or reason == "close",
    })

    if not self:isOnline() then
        self:queueProgressSnapshot(snapshot, "pdf_bridge", {
            bookId = snapshot.bookId,
            bookHash = snapshot.bookHash,
            request = payload,
        })
        if not silent then
            self:showMessage(_("Saved PDF bridge progress to offline queue"), 2)
        end
        return false
    end

    local success, response, code = self.api:updatePdfProgress(snapshot.bookId, payload)
    if success then
        local normalized = self:normalizeRemoteProgress(response or payload)
        normalized.source = "WEB_READER"
        self:rememberRemoteSnapshot(snapshot.bookHash, normalized, reason or "pdf-bridge-push")
        return true
    end

    local _, api_error_class = self:classifyApiOutcome(code, response)
    self:logWarn("GrimmLink PDF bridge push failed:", response)
    if api_error_class ~= "permanent_not_found" and api_error_class ~= "permanent_invalid" then
        self:queueProgressSnapshot(snapshot, "pdf_bridge", payload)
    end
    if not silent then
        self:showMessage(T(_("PDF bridge sync failed:\n%1"), safeToString(response)), 4)
    end
    return false
end

function Grimmlink:syncPendingProgress(silent, limit)
    local synced = 0
    local failed = 0
    if not self.db then
        return synced, failed
    end
    if not self:isOnline() then
        return synced, failed
    end

    if not self:isApiReady({ "updateProgress", "updatePdfProgress" }) then
        return synced, failed
    end
    if not self:refreshApiClient() then
        return synced, failed
    end
    local pending = self.db:getPendingProgress(limit or 100)
    local now = nowUtc()

    local function retryDelaySeconds(retry_count)
        local count = tonumber(retry_count) or 0
        local delay = 30 * (2 ^ math.min(count, 5))
        if delay > 3600 then
            delay = 3600
        end
        return delay
    end

    for _, item in ipairs(pending) do
        if not self:isTrackingEnabled(item.file_hash, nil) then
            -- Keep queued rows for this book untouched while tracking is disabled.
        else
            local can_try = true
            if item.last_retry_at and (now - tonumber(item.last_retry_at)) < retryDelaySeconds(item.retry_count) then
                can_try = false
            end

            if can_try then
                local ok, payload = pcall(json.decode, item.payload_json)
                if not ok or type(payload) ~= "table" then
                    self.db:deletePendingProgress(item.id)
                    failed = failed + 1
                else
                    local success, response, code
                    if item.kind == "pdf_bridge" then
                        local request_payload = payload.request or payload
                        local book_id = payload.bookId or request_payload.bookId
                        if not book_id and (payload.bookHash or request_payload.bookHash) then
                            local matched = self:resolveBookByHash(nil, payload.bookHash or request_payload.bookHash, true)
                            book_id = matched and matched.book_id or nil
                        end
                        if book_id then
                            success, response, code = self.api:updatePdfProgress(book_id, request_payload)
                        else
                            success = false
                            response = "Book ID not resolved"
                            code = 400
                        end
                    else
                        success, response, code = self.api:updateProgress(payload)
                    end

                    if success then
                        self.db:deletePendingProgress(item.id)
                        synced = synced + 1
                        if item.kind == "pdf_bridge" then
                            local request_payload = payload.request or payload
                            local normalized = self:normalizeRemoteProgress(request_payload)
                            normalized.source = "WEB_READER"
                            self:rememberRemoteSnapshot(item.file_hash, normalized, "queued-pdf-bridge-pushed")
                        else
                            self:rememberLocalSnapshot(item.file_hash, {
                                file_path = payload.file_path,
                                bookId = payload.bookId,
                                document = payload.document,
                                bookType = payload.bookType or payload.fileFormat,
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
                                bookType = payload.bookType or payload.fileFormat,
                                progress = payload.progress,
                                location = payload.location,
                                percentage = normalizePercent(payload.percentage),
                                currentPage = payload.currentPage,
                                totalPages = payload.totalPages,
                                device = payload.device,
                                deviceId = payload.deviceId or payload.device_id,
                                timestamp = payload.timestamp or nowUtc(),
                            }, "queued-progress-pushed")
                        end
                    else
                        local _, api_error_class = self:classifyApiOutcome(code, response)
                        if api_error_class == "permanent_not_found" or api_error_class == "permanent_invalid" then
                            self.db:deletePendingProgress(item.id)
                        else
                            self.db:incrementPendingProgressRetry(item.id)
                        end
                        failed = failed + 1
                    end
                end
            end
        end
    end

    if not silent and (synced > 0 or failed > 0) then
        self:showMessage(T(_("Pending progress sync\nSynced: %1\nFailed: %2"), synced, failed), 3)
    end
    return synced, failed
end

function Grimmlink:resolveBookByHash(file_path, file_hash, silent)
    if not file_hash then
        return nil
    end

    local cached = self.db and self.db:getBookByHash(file_hash) or nil
    if cached and cached.book_id then
        return cached
    end

    if not self:isOnline() then
        if self.db and file_path and file_path ~= "" then
            self.db:saveBookCache(file_path, file_hash, nil, sanitizeTitle(file_path), nil)
        end
        return cached
    end

    if not self:isApiReady({ "getBookByHash" }) or not self:refreshApiClient() then
        return cached
    end
    local success, book, code = self.api:getBookByHash(file_hash)
    if success and book and book.id then
        if self.db then
            self.db:saveBookCache(file_path or sanitizeTitle(file_hash), file_hash, tonumber(book.id), book.title, book.author)
        end
        return {
            file_path = file_path,
            file_hash = file_hash,
            book_id = tonumber(book.id),
            bookFileId = maybeNumber(book.bookFileId or book.book_file_id),
            title = book.title,
            author = book.author,
        }
    end

    if self.db and file_path and file_path ~= "" then
        self.db:saveBookCache(file_path, file_hash, nil, sanitizeTitle(file_path), nil)
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

function Grimmlink:maybePullRemoteProgress(file_hash, file_path, book_id, book_file_id, silent)
    if not self.db or not self.auto_pull_on_open or not file_hash or file_hash == "" or not book_id then
        return
    end
    if not self:isTrackingEnabled(file_hash, file_path) then
        return
    end
    if not self:isOnline() then
        return
    end

    if not self:isApiReady({ "getProgress" }) or not self:refreshApiClient() then
        return
    end
    local state = self.db:getProgressState(file_hash)
    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local comparison_local = cloneTable(local_snapshot)
    if state and state.local_timestamp then
        comparison_local.timestamp = state.local_timestamp
    end

    local success, remote, code = self.api:getProgress(file_hash)
    if not success then
        local _, api_error_class = self:classifyApiOutcome(code, remote)
        if not silent and api_error_class ~= "permanent_not_found" then
            self:showMessage(T(_("Remote progress fetch failed:\n%1"), safeToString(remote)), 4)
        end
        self:rememberLocalSnapshot(file_hash, local_snapshot, "open-local")
        return
    end

    local remote_snapshot = self:normalizeRemoteProgress(remote)
    if remote_snapshot then
        remote_snapshot.bookHash = file_hash
        remote_snapshot.bookId = remote_snapshot.bookId or book_id
        remote_snapshot.bookFileId = remote_snapshot.bookFileId or book_file_id
        remote_snapshot.fileFormat = remote_snapshot.fileFormat or self:getBookType(file_path)
        remote_snapshot.bookType = remote_snapshot.bookType or remote_snapshot.fileFormat
        remote_snapshot.document = remote_snapshot.document or file_hash
        remote_snapshot.file_path = file_path
        remote_snapshot.source = remote_snapshot.source or remote_snapshot.device or "KOReader"
        self:applyFormatProgressPolicy(remote_snapshot)
    end

    self:rememberLocalSnapshot(file_hash, local_snapshot, "open-local")
    self:rememberRemoteSnapshot(file_hash, remote_snapshot, "open-remote")

    local decision = self:compareOpenProgress(comparison_local, remote_snapshot, state)
    if decision == "remote_newer" or decision == "conflict" then
        self:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, "native")
    elseif decision == "local_newer" or decision == "same" then
        return
    end
end

function Grimmlink:manualPullProgress()
    if not self.current_session then
        self:showMessage(_("No book currently open"), 3)
        return
    end
    if not self:isOnline() then
        self:showMessage(_("Not connected to server"), 3)
        return
    end
    if not self:isApiReady({ "getProgress" }) or not self:refreshApiClient() then
        return
    end

    local file_hash    = self.current_session.file_hash
    local file_path    = self.current_session.file_path
    local book_id      = self.current_session.book_id
    local book_file_id = self.current_session.book_file_id

    if not self:isTrackingEnabled(file_hash, file_path) then
        self:showTrackingDisabledMessage()
        return
    end

    if not file_hash or not book_id then
        self:showMessage(_("Book not registered on server"), 3)
        return
    end

    self:showMessage(_("Fetching remote progress…"), 2)

    local success, remote, code = self.api:getProgress(file_hash)
    if not success then
        local _, api_error_class = self:classifyApiOutcome(code, remote)
        if api_error_class == "permanent_not_found" then
            self:showMessage(_("No remote progress found for this book"), 3)
        else
            self:showMessage(T(_("Fetch failed:\n%1"), safeToString(remote)), 4)
        end
        return
    end

    local remote_snapshot = self:normalizeRemoteProgress(remote)
    if not remote_snapshot then
        self:showMessage(_("No remote progress found for this book"), 3)
        return
    end

    remote_snapshot.bookHash    = file_hash
    remote_snapshot.bookId      = remote_snapshot.bookId      or book_id
    remote_snapshot.bookFileId  = remote_snapshot.bookFileId  or book_file_id
    remote_snapshot.fileFormat  = remote_snapshot.fileFormat  or self:getBookType(file_path)
    remote_snapshot.bookType    = remote_snapshot.bookType    or remote_snapshot.fileFormat
    remote_snapshot.document    = remote_snapshot.document    or file_hash
    remote_snapshot.file_path   = file_path
    remote_snapshot.source      = remote_snapshot.source or remote_snapshot.device or "KOReader"
    self:applyFormatProgressPolicy(remote_snapshot)

    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)

    self:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, "native")
end

function Grimmlink:maybePullPdfWebProgress(file_hash, file_path, book_id, book_file_id, silent)
    if not self.db or not self:isPdfWebReaderBridgeEnabled() or not file_hash or file_hash == "" or not book_id then
        return
    end
    if not self:isTrackingEnabled(file_hash, file_path) then
        return
    end
    local normalized_book_id = maybeNumber(book_id) or book_id
    if not normalized_book_id then
        return
    end
    if self:getBookType(file_path) ~= "PDF" then
        return
    end
    if not self:isOnline() then
        return
    end

    if not self:isApiReady({ "getPdfProgress" }) or not self:refreshApiClient() then
        return
    end
    local state = self.db:getProgressState(file_hash)
    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local success, remote, code = self.api:getPdfProgress(normalized_book_id)
    if not success then
        local _, api_error_class = self:classifyApiOutcome(code, remote)
        if not silent and api_error_class ~= "permanent_not_found" then
            self:showMessage(T(_("PDF bridge fetch failed:\n%1"), safeToString(remote)), 4)
        end
        return
    end

    local remote_snapshot = self:normalizeRemoteProgress(remote)
    if remote_snapshot then
        remote_snapshot.bookHash = file_hash
        remote_snapshot.bookId = normalized_book_id
        remote_snapshot.bookFileId = remote_snapshot.bookFileId or book_file_id
        remote_snapshot.fileFormat = "PDF"
        remote_snapshot.document = remote_snapshot.document or file_hash
        remote_snapshot.file_path = file_path
        remote_snapshot.source = remote_snapshot.source or "WEB_READER"
    end

    local decision = self:compareOpenProgress(local_snapshot, remote_snapshot, state)
    if decision == "remote_newer" or decision == "conflict" then
        self:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, "pdf")
    end
end

function Grimmlink:buildSingleSessionPayload(group, item)
    return {
        bookId = maybeNumber(group.bookId) or group.bookId,
        bookHash = group.bookHash,
        bookType = group.bookType,
        startTime = item.startTime,
        endTime = item.endTime,
        durationSeconds = maybeNumber(item.durationSeconds) or 0,
        durationFormatted = item.durationFormatted,
        startProgress = roundToSingleDecimal(item.startProgress),
        endProgress = roundToSingleDecimal(item.endProgress),
        progressDelta = roundToSingleDecimal(item.progressDelta),
        startLocation = item.startLocation,
        endLocation = item.endLocation,
        currentPage = maybeNumber(item.currentPage),
        totalPages = maybeNumber(item.totalPages),
        device = group.device,
        deviceId = group.deviceId,
    }
end

function Grimmlink:startSession()
    if not self.enabled or not self:requireReady({ require_api = false, silent = true }) or not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end

    local file_path = tostring(self.ui.document.file)
    local cached = self:resolveBookByFilePath(file_path)
    local file_hash = cached and cached.file_hash or nil
    if not file_hash or file_hash == "" then
        file_hash = self:calculateBookHash(file_path)
    end

    local tracking_enabled = self:isTrackingEnabled(file_hash, file_path)
    local matched = nil
    if tracking_enabled then
        matched = self:resolveBookByHash(file_path, file_hash, true)
    end
    local book_id = maybeNumber(matched and matched.book_id or (cached and cached.book_id or nil))
    local book_file_id = maybeNumber(matched and matched.bookFileId or (cached and cached.book_file_id or nil))
    local title = matched and matched.title or (cached and cached.title or sanitizeTitle(file_path))
    local start_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)

    self.current_session = {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
        book_title = title,
        start_time = nowUtc(),
        start_snapshot = start_snapshot,
        book_type = self:getBookType(file_path),
        tracking_enabled = tracking_enabled,
    }

    local function doNetworkSync()
        -- Clear handle first so this task is not reused across sessions.
        self._scheduled_session_open_sync = nil
        if not self.current_session or self.current_session.file_hash ~= file_hash then
            return
        end
        if self.current_session.tracking_enabled == false then
            return
        end
        self:invokeSafely("session open sync", function()
            self:maybePullRemoteProgress(file_hash, file_path, book_id, book_file_id, true)
            self:maybePullPdfWebProgress(file_hash, file_path, book_id, book_file_id, true)
            if self:isOnline() then
                self:schedulePendingSync("session open pending sync", 0.75, {
                    progress_limit = 10,
                    session_limit = 25,
                    respect_cooldown = true,
                })
            end
        end, {}, { silent = true })
    end

    if UIManager and type(UIManager.scheduleIn) == "function" then
        if self._scheduled_session_open_sync and type(UIManager.unschedule) == "function" then
            pcall(UIManager.unschedule, UIManager, self._scheduled_session_open_sync)
        end
        self._scheduled_session_open_sync = doNetworkSync
        UIManager:scheduleIn(0.5, doNetworkSync)
    else
        doNetworkSync()
    end
end

function Grimmlink:endSession(options)
    options = options or {}
    if not self.db or not self.current_session then
        return false
    end

    -- Prevent open-session deferred work from racing close-session handling.
    if self._scheduled_session_open_sync and UIManager and type(UIManager.unschedule) == "function" then
        pcall(UIManager.unschedule, UIManager, self._scheduled_session_open_sync)
        self._scheduled_session_open_sync = nil
    end

    local session = self.current_session
    local metadata_context = {
        file_path = session.file_path,
        file_hash = session.file_hash,
        book_id = session.book_id,
        book_file_id = session.book_file_id,
    }
    self.current_session = nil

    if not self:requireReady({ require_api = false, silent = true }) then
        return false
    end

    local file_path = session.file_path
    local file_hash = session.file_hash
    local book_id = session.book_id
    local book_file_id = session.book_file_id
    local end_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local duration_seconds = math.max(0, nowUtc() - (session.start_time or nowUtc()))
    local start_snapshot = session.start_snapshot or {}
    local state = self.db:getProgressState(file_hash)
    local progress_delta = (tonumber(end_snapshot.percentage) or 0) - (tonumber(start_snapshot.percentage) or 0)
    local session_valid = self:validateSession(
        duration_seconds,
        progress_delta,
        start_snapshot.currentPage,
        end_snapshot.currentPage
    )

    self:rememberLocalSnapshot(file_hash, end_snapshot, "local-" .. (options.reason or "close"))
    if session.tracking_enabled ~= false then
        self:extractAndQueueCurrentMetadata("document-" .. (options.reason or "close"), metadata_context)
    end

    if session_valid and session.tracking_enabled ~= false then
        self.db:addPendingSession({
            bookId = book_id,
            bookHash = file_hash,
            bookType = session.book_type,
            device = self.device_name,
            deviceId = self.device_id,
            startTime = toIso8601(session.start_time),
            endTime = toIso8601(end_snapshot.timestamp),
            durationSeconds = duration_seconds,
            durationFormatted = self:formatDuration(duration_seconds),
            startProgress = roundToSingleDecimal(start_snapshot.percentage or 0),
            endProgress = roundToSingleDecimal(end_snapshot.percentage or 0),
            progressDelta = roundToSingleDecimal(progress_delta),
            startLocation = start_snapshot.location or "",
            endLocation = end_snapshot.location or "",
            currentPage = end_snapshot.currentPage,
            totalPages = end_snapshot.totalPages,
        })
    end

    local should_push = session.tracking_enabled ~= false and self:shouldPushProgress(end_snapshot, state, options.reason or "close")
    if should_push and self.auto_push_on_close then
        local reason = options.reason or "close"
        if reason == "close" or reason == "suspend" or reason == "exit" then
            local native_payload = self:prepareNativeProgressPayload(end_snapshot)
            local queued = self:queueProgressSnapshot(end_snapshot, "native", native_payload)
            if not queued then
                self:pushProgressSnapshot(end_snapshot, reason, true)
            end

            if self:isPdfWebReaderBridgeEnabled() and end_snapshot.fileFormat == "PDF" and end_snapshot.bookId then
                local bridge_payload = self:preparePdfBridgePayload(end_snapshot, {
                    force = reason == "close" or reason == "exit",
                })
                local bridge_queued = self:queueProgressSnapshot(end_snapshot, "pdf_bridge", {
                    bookId = end_snapshot.bookId,
                    bookHash = end_snapshot.bookHash,
                    request = bridge_payload,
                })
                if not bridge_queued then
                    self:pushPdfWebProgress(end_snapshot, reason, true)
                end
            end
        else
            self:pushProgressSnapshot(end_snapshot, reason, true)
            self:pushPdfWebProgress(end_snapshot, reason, true)
        end
    end

    if self:isOnline() then
        self:schedulePendingSync("session close sync", 0.75, {
            progress_limit = 10,
            session_limit = 25,
        })
    end
    if (options.reason or "close") == "close" then
        self:scheduleReadingCompletionPrompt(metadata_context, end_snapshot)
    end
    return true
end

function Grimmlink:syncPendingSessions(silent, limit)
    local synced = 0
    local failed = 0

    if not self.db then
        return synced, failed
    end
    if not self:requireReady({ require_api = true, silent = silent }) then
        return synced, failed
    end
    if not self:isOnline() then
        return synced, failed
    end

    if not self:isApiReady({ "getBookByHash", "submitSession", "submitSessionBatch" }) then
        return synced, failed
    end
    if not self:refreshApiClient() then
        return synced, failed
    end
    local pending = self.db:getPendingSessions(limit or 500)
    if #pending == 0 then
        return synced, failed
    end

    local hash_resolved = {}
    local hash_not_found = {}
    for _, session in ipairs(pending) do
        if self:isTrackingEnabled(session.bookHash, nil) then
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
                        local ok_lookup, book, lookup_code = self.api:getBookByHash(h)
                        if ok_lookup and book and book.id then
                            hash_resolved[h] = tonumber(book.id)
                            session.bookId = hash_resolved[h]
                            self.db:updateBookId(h, hash_resolved[h])
                            self.db:updatePendingSessionBookId(session.id, hash_resolved[h])
                        elseif lookup_code == 404 then
                            hash_not_found[h] = true
                            hash_resolved[h] = false
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
        if not self:isTrackingEnabled(session.bookHash, nil) then
            -- Keep queued rows untouched while tracking is disabled for this book.
        elseif not session.bookId then
            if hash_not_found[session.bookHash] then
                self.db:deletePendingSession(session.id)
                failed = failed + 1
            else
                self.db:incrementSessionRetryCount(session.id)
                failed = failed + 1
            end
        else
            local group_key = table.concat({
                tostring(session.bookId),
                session.bookHash or "",
                session.bookType or "EPUB",
                session.device or "",
                session.deviceId or "",
            }, "|")
            groups[group_key] = groups[group_key] or {
                bookId = maybeNumber(session.bookId) or session.bookId,
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
                durationFormatted = session.durationFormatted or session.duration_formatted or self:formatDuration(session.durationSeconds),
                startProgress = roundToSingleDecimal(session.startProgress),
                endProgress = roundToSingleDecimal(session.endProgress),
                progressDelta = roundToSingleDecimal(session.progressDelta),
                startLocation = session.startLocation,
                endLocation = session.endLocation,
                currentPage = session.currentPage,
                totalPages = session.totalPages,
            }
        end

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
            else
                handled_individually = true
                local group_success = true
                for index, session in ipairs(group.sessions) do
                    local single_ok = self.api:submitSession(self:buildSingleSessionPayload(group, items[index]))
                    if single_ok then
                        self.db:deletePendingSession(session.id)
                        synced = synced + 1
                    else
                        self.db:incrementSessionRetryCount(session.id)
                        failed = failed + 1
                        group_success = false
                    end
                end
                success = group_success
            end
        end

        if handled_individually then
            -- counts already applied above
        elseif success and #items > 1 then
            for _, session in ipairs(group.sessions) do
                self.db:deletePendingSession(session.id)
                synced = synced + 1
            end
        elseif success then
            for _, session in ipairs(group.sessions) do
                self.db:deletePendingSession(session.id)
                synced = synced + 1
            end
        else
            for _, session in ipairs(group.sessions) do
                self.db:incrementSessionRetryCount(session.id)
                failed = failed + 1
            end
        end
    end

    if not silent and (synced > 0 or failed > 0) then
        self:showMessage(T(_("Pending session sync\nSynced: %1\nFailed: %2"), synced, failed), 3)
    end
    return synced, failed
end

local function parseIsoOrNil(value)
    if value == nil then
        return nil
    end

    if type(value) == "number" then
        return toIso8601(value)
    end

    if type(value) ~= "string" then
        return nil
    end

    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end

    -- Common KOReader timestamp format: "YYYY-MM-DD HH:MM:SS"
    if trimmed:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") then
        return (trimmed:gsub(" ", "T")) .. "Z"
    end
    if trimmed:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d+$") then
        return (trimmed:gsub(" ", "T")) .. "Z"
    end

    -- Already ISO-local without timezone: append Z for Instant parsing.
    if trimmed:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d$") then
        return trimmed .. "Z"
    end
    if trimmed:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d+$") then
        return trimmed .. "Z"
    end

    -- Keep explicit timezone ISO strings as-is.
    if trimmed:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.?%d*[Zz]$") then
        return trimmed
    end
    if trimmed:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.?%d*[%+%-]%d%d:%d%d$") then
        return trimmed
    end

    -- Unknown format: omit timestamp to avoid backend JSON parse failures.
    return nil
end

if MetadataController and type(MetadataController.install) == "function" then
    MetadataController.install(Grimmlink, {
        MetadataExtractor = MetadataExtractor,
        json = json,
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
        cloneTable = cloneTable,
        maybeNumber = maybeNumber,
        normalizeMetadataRatingPayload = normalizeMetadataRatingPayload,
        nowUtc = nowUtc,
        parseIsoOrNil = parseIsoOrNil,
        safeDbBoolCall = safeDbBoolCall,
        safeDbValueCall = safeDbValueCall,
        safeToString = safeToString,
        shortPrefix = shortPrefix,
        stableTextHash = stableTextHash,
    })
end
if ShelfController and type(ShelfController.install) == "function" then
    ShelfController.install(Grimmlink, {
        ButtonDialog = ButtonDialog,
        ConfirmBox = ConfirmBox,
        Event = Event,
        FileManager = FileManager,
        InfoMessage = InfoMessage,
        UIManager = UIManager,
        lfs = lfs,
        logger = logger,
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
        DISK_SPACE_SAFETY_MARGIN_BYTES = DISK_SPACE_SAFETY_MARGIN_BYTES,
        maybeNumber = maybeNumber,
        normalizeShelfType = normalizeShelfType,
        parseDfAvailableBytes = parseDfAvailableBytes,
        safeToString = safeToString,
        shellQuote = shellQuote,
    })
end
if LifecycleController and type(LifecycleController.install) == "function" then
    LifecycleController.install(Grimmlink, {
        APIClient = APIClient,
        Database = Database,
        Deletion = Deletion,
        Dispatcher = Dispatcher,
        FileLogger = FileLogger,
        MenuActions = MenuActions,
        Matching = Matching,
        PendingSync = PendingSync,
        ProgressSync = ProgressSync,
        ShelfSync = ShelfSync,
        UIManager = UIManager,
        Updater = Updater,
        Util = Util,
        DEFAULTS = DEFAULTS,
        READING_COMPLETION_END_DIALOG_INITIAL_DELAY_SECONDS = READING_COMPLETION_END_DIALOG_INITIAL_DELAY_SECONDS,
        detectPluginDir = detectPluginDir,
        normalizeNickname = normalizeNickname,
        normalizeShelfType = normalizeShelfType,
        normalizeSsid = normalizeSsid,
        normalizeUpdateChannel = normalizeUpdateChannel,
        nowUtc = nowUtc,
    })
end
function Grimmlink:syncPendingNow(silent, opts)
    if self.pending_sync and type(self.pending_sync.syncPendingNow) == "function" then
        return self.pending_sync:syncPendingNow(self, silent, opts)
    end

    opts = opts or {}

    if not silent then
        local context = self:getCurrentDocumentContext()
        if context and not self:isTrackingEnabledForContext(context) then
            self:showTrackingDisabledMessage()
        else
            self:extractAndQueueCurrentMetadata("manual-sync", context)
        end
        if not self:isOnline() then
            self:maybePromptEnableWifiForManualSync()
            return
        end
    end

    if not self:requireReady({ require_api = true, silent = silent }) then
        return
    end

    local progress_synced, progress_failed = self:syncPendingProgress(true, opts.progress_limit)
    local sessions_synced, sessions_failed = self:syncPendingSessions(true, opts.session_limit)
    local metadata_synced, metadata_failed = self:syncPendingMetadata(true, opts.metadata_limit)

    if not silent then
        self:showMessage(T(
            _("GrimmLink sync complete\nProgress: %1 synced, %2 failed\nSessions: %3 synced, %4 failed\nMetadata: %5 synced, %6 failed"),
            progress_synced,
            progress_failed,
            sessions_synced,
            sessions_failed,
            metadata_synced,
            metadata_failed
        ), 4)
    end
end

function Grimmlink:getQueueSummaryCounters()
    if self.pending_sync and type(self.pending_sync.getQueueSummaryCounters) == "function" then
        return self.pending_sync:getQueueSummaryCounters(self)
    end
    return {
        pending_progress = safeDbValueCall(self.db, "getPendingProgressCount", 0),
        pending_sessions = safeDbValueCall(self.db, "getPendingSessionCount", 0),
        pending_metadata = safeDbValueCall(self.db, "getPendingMetadataCount", 0),
        pending_shelf_removals = safeDbValueCall(self.db, "getPendingShelfRemovalCount", 0),
    }
end

function Grimmlink:shouldRunAutoPendingSync(cooldown_seconds)
    local cooldown = tonumber(cooldown_seconds) or tonumber(self.auto_sync_cooldown_seconds) or DEFAULTS.auto_sync_cooldown_seconds
    if cooldown <= 0 then
        return true
    end

    local now = nowUtc()
    if self._last_auto_pending_sync_at and (now - self._last_auto_pending_sync_at) < cooldown then
        self:logDbg("GrimmLink: skipping auto pending sync; cooldown active")
        return false
    end
    self._last_auto_pending_sync_at = now
    return true
end

function Grimmlink:schedulePendingSync(label, delay_seconds, opts)
    if self._scheduled_pending_sync then
        return
    end
    opts = opts or {}
    if opts.respect_cooldown and not self:shouldRunAutoPendingSync(opts.cooldown_seconds) then
        return
    end

    local function runPendingSync()
        self._scheduled_pending_sync = nil
        if not self:isOnline() then
            return
        end
        self:invokeSafely(label or "pending sync", function()
            self:syncPendingNow(true, opts)
        end, {}, { silent = true })
    end

    if UIManager and type(UIManager.scheduleIn) == "function" then
        self._scheduled_pending_sync = runPendingSync
        UIManager:scheduleIn(delay_seconds or 0.75, runPendingSync)
    else
        runPendingSync()
    end
end

function Grimmlink:isPdfWebReaderBridgeEnabled()
    return self.enabled == true and self.pdf_web_reader_bridge_enabled == true
end

function Grimmlink:syncPdfWebProgress(silent)
    if not self:isPdfWebReaderBridgeEnabled() or not self.current_session then
        return false
    end

    local snapshot = self:getCurrentProgressSnapshot(
        self.current_session.file_hash,
        self.current_session.file_path,
        self.current_session.book_id,
        self.current_session.book_file_id
    )
    if snapshot and snapshot.fileFormat == "PDF" then
        return self:pushPdfWebProgress(snapshot, "manual", silent)
    end
    return false
end

function Grimmlink:resolveCurrentDocumentBookId(preferred_book_id)
    if preferred_book_id then
        return maybeNumber(preferred_book_id) or preferred_book_id
    end
    if self.current_session and self.current_session.book_id then
        return maybeNumber(self.current_session.book_id) or self.current_session.book_id
    end
    if self.ui and self.ui.document and self.ui.document.file then
        local cached = self:resolveBookByFilePath(tostring(self.ui.document.file))
        if cached and cached.book_id then
            return maybeNumber(cached.book_id) or cached.book_id
        end
    end
    return nil
end

function Grimmlink:pushPdfWebProgressForCurrentDocument(reason, silent)
    if not self.current_session then
        return false
    end
    local snapshot = self:getCurrentProgressSnapshot(
        self.current_session.file_hash,
        self.current_session.file_path,
        self.current_session.book_id,
        self.current_session.book_file_id
    )
    if not snapshot or snapshot.fileFormat ~= "PDF" then
        return false
    end
    return self:pushPdfWebProgress(snapshot, reason or "manual", silent)
end

function Grimmlink:checkForUpdates(silent, options)
    options = options or {}
    if not self.updater or type(self.updater.checkForUpdates) ~= "function" then
        if not silent then
            self:showMessage(_("Updater is unavailable"), 4)
        end
        return nil, "updater unavailable"
    end

    if not silent then
        self:showMessage(_("Checking for updates..."), 2)
    end

    if type(self.updater.setAllowPrerelease) == "function" then
        self.updater:setAllowPrerelease(self.allow_prerelease_updates)
    end
    local use_cache = silent == true and options.force_refresh ~= true
    local result, err = self.updater:checkForUpdates(use_cache)
    if not result then
        if not silent then
            self:showMessage(T(_("Update check failed:\n%1"), safeToString(err)), 4)
        end
        return nil, err
    end

    if result.available then
        if not silent then
            local from_version = safeToString(result.current_version) or _("unknown")
            local to_version = safeToString(result.latest_version) or _("unknown")
            if result.release_info then
                self:showConfirmAction(
                    T(_("Update available: %1 -> %2\nInstall now?"), from_version, to_version),
                    _("Update"),
                    function()
                        self:installUpdate(result.release_info)
                    end
                )
            else
                self:showMessage(T(_("Update available: %1"), to_version), 3)
            end
        end
    elseif not silent then
        self:showMessage(_("Already up to date"), 2)
    end
    return result, nil
end

function Grimmlink:installUpdate(release_info)
    if not self.updater or type(self.updater.installUpdate) ~= "function" then
        return false, "updater unavailable"
    end
    local ok, err = self.updater:installUpdate(release_info)
    if not ok then
        self:showMessage(T(_("Update failed:\n%1"), safeToString(err)), 4)
        return false, err
    end
    local dialog = ConfirmBox:new{
        text        = _("Update installed.\n\nRestart KOReader now to apply it?"),
        ok_text     = _("Restart Now"),
        cancel_text = _("Later"),
        ok_callback = function()
            UIManager:restartKOReader()
        end,
    }
    UIManager:show(dialog)
    return true
end

function Grimmlink:showConfirmAction(message, ok_text, on_confirm)
    local dialog = ConfirmBox:new{
        text = message,
        ok_text = ok_text or _("Confirm"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            if type(on_confirm) == "function" then
                on_confirm()
            end
        end,
    }
    UIManager:show(dialog)
end

function Grimmlink:clearUpdateCacheWithConfirm()
    if not self.updater or type(self.updater.clearCache) ~= "function" then
        self:showMessage(_("Updater is unavailable"), 3)
        return
    end

    self:showConfirmAction(
        _("Clear cached update metadata?\nThis only clears update-check cache."),
        _("Clear Cache"),
        function()
            local ok = self.updater:clearCache()
            self:showMessage(ok and _("Update cache cleared") or _("Failed to clear update cache"), 3)
        end
    )
end

function Grimmlink:clearUnmatchedBookCacheWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = type(self.db.getUnmatchedCacheCount) == "function" and self.db:getUnmatchedCacheCount() or 0
    if (count or 0) <= 0 then
        self:showMessage(_("No unmatched cache entries"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear unmatched book cache (%1 entries)?"), count),
        _("Clear"),
        function()
            local ok = type(self.db.clearUnmatchedCache) == "function" and self.db:clearUnmatchedCache() or false
            self:showMessage(ok and _("Unmatched book cache cleared") or _("Failed to clear unmatched cache"), 3)
        end
    )
end

function Grimmlink:clearAllBookCacheWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = type(self.db.getStaleCacheCount) == "function" and self.db:getStaleCacheCount() or 0
    if (count or 0) <= 0 then
        self:showMessage(_("Book cache is already empty"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear all book cache (%1 entries)?\nYou may need to re-match books on next sync."), count),
        _("Clear All"),
        function()
            local ok = type(self.db.clearStaleCache) == "function" and self.db:clearStaleCache() or false
            self:showMessage(ok and _("All book cache cleared") or _("Failed to clear book cache"), 3)
        end
    )
end

function Grimmlink:clearNotFoundHashesWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    if type(self.db.clearNotFoundHashes) ~= "function" then
        self:showMessage(_("Not Found hash cache is not supported in this build"), 3)
        return
    end

    local count = type(self.db.getNotFoundHashesCount) == "function" and self.db:getNotFoundHashesCount() or nil
    if count and count <= 0 then
        self:showMessage(_("No not-found hash entries"), 2)
        return
    end

    local prompt = count
        and T(_("Clear not-found hash entries (%1)?"), count)
        or _("Clear not-found hash entries?")

    self:showConfirmAction(
        prompt,
        _("Clear"),
        function()
            local ok = self.db:clearNotFoundHashes()
            self:showMessage(ok and _("Not-found hash cache cleared") or _("Failed to clear not-found hash cache"), 3)
        end
    )
end

function Grimmlink:clearPendingProgressQueueWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = type(self.db.getPendingProgressCount) == "function" and self.db:getPendingProgressCount() or 0
    if (count or 0) <= 0 then
        self:showMessage(_("No pending progress queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear pending progress queue (%1 items)?"), count),
        _("Clear Queue"),
        function()
            local ok = type(self.db.deleteAllPendingProgress) == "function" and self.db:deleteAllPendingProgress() or false
            self:showMessage(ok and _("Pending progress queue cleared") or _("Failed to clear pending progress queue"), 3)
        end
    )
end

function Grimmlink:clearPendingSessionsQueueWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = type(self.db.getPendingSessionCount) == "function" and self.db:getPendingSessionCount() or 0
    if (count or 0) <= 0 then
        self:showMessage(_("No pending session queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear pending session queue (%1 items)?"), count),
        _("Clear Queue"),
        function()
            local ok_all = true
            if type(self.db.getPendingSessions) == "function" and type(self.db.deletePendingSession) == "function" then
                while true do
                    local rows = self.db:getPendingSessions(500) or {}
                    if #rows == 0 then
                        break
                    end
                    for _, row in ipairs(rows) do
                        if not self.db:deletePendingSession(row.id) then
                            ok_all = false
                        end
                    end
                end
            else
                ok_all = false
            end
            self:showMessage(ok_all and _("Pending session queue cleared") or _("Failed to clear pending session queue"), 3)
        end
    )
end

function Grimmlink:clearPendingMetadataQueueWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    if (count or 0) <= 0 then
        self:showMessage(_("No pending metadata queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear pending metadata queue (%1 items)?"), count),
        _("Clear Queue"),
        function()
            local ok = safeDbBoolCall(self.db, "deleteAllPendingMetadata")
            self:showMessage(ok and _("Pending metadata queue cleared") or _("Failed to clear pending metadata queue"), 3)
        end
    )
end

function Grimmlink:clearSyncedMetadataHistoryWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    self:showConfirmAction(
        _("Clear synced metadata history?\nThis only affects local dedupe history and does not remove server metadata."),
        _("Clear History"),
        function()
            local ok = safeDbBoolCall(self.db, "clearSyncedMetadataHistory")
            self:showMessage(ok and _("Synced metadata history cleared") or _("Failed to clear synced metadata history"), 3)
        end
    )
end

function Grimmlink:clearShelfTombstonesWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local count = safeDbValueCall(self.db, "getShelfTombstoneCount", 0)
    if (count or 0) <= 0 then
        self:showMessage(_("No shelf tombstones"), 2)
        return
    end
    self:showConfirmAction(
        T(_("Clear shelf tombstones (%1 items)?"), count),
        _("Clear Tombstones"),
        function()
            local ok = safeDbBoolCall(self.db, "clearShelfTombstones")
            self:showMessage(ok and _("Shelf tombstones cleared") or _("Failed to clear shelf tombstones"), 3)
        end
    )
end

function Grimmlink:clearPendingShelfRemovalsWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local count = safeDbValueCall(self.db, "getPendingShelfRemovalCount", 0)
    if (count or 0) <= 0 then
        self:showMessage(_("No pending shelf removals"), 2)
        return
    end
    self:showConfirmAction(
        T(_("Clear pending shelf removals (%1 items)?"), count),
        _("Clear Queue"),
        function()
            local ok = safeDbBoolCall(self.db, "clearPendingShelfRemovals")
            self:showMessage(ok and _("Pending shelf removals cleared") or _("Failed to clear pending shelf removals"), 3)
        end
    )
end

function Grimmlink:showDatabaseStatus()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local queues = self:getQueueSummaryCounters()
    local pending_progress = queues.pending_progress or 0
    local pending_sessions = queues.pending_sessions or 0
    local pending_metadata = queues.pending_metadata or 0
    local synced_metadata = safeDbValueCall(self.db, "getSyncedMetadataCount", 0)
    local pending_shelf_removals = queues.pending_shelf_removals or 0
    local shelf_tombstones = safeDbValueCall(self.db, "getShelfTombstoneCount", 0)
    local shelf_stats = safeDbValueCall(self.db, "getShelfSyncStats", { total = 0, downloaded_by_grimmlink = 0 })

    self:showMessage(T(
        _("DB Status\nPending progress: %1\nPending sessions: %2\nPending metadata: %3\nSynced metadata history: %4\nPending shelf removals: %5\nShelf tombstones: %6\nShelf map rows: %7"),
        pending_progress,
        pending_sessions,
        pending_metadata,
        synced_metadata,
        pending_shelf_removals,
        shelf_tombstones,
        shelf_stats and shelf_stats.total or 0
    ), 6)
end

function Grimmlink:rematchCurrentBook()
    local context = self:getCurrentDocumentContext()
    if not context or not context.file_path then
        self:showMessage(_("No file selected"), 3)
        return
    end
    self:matchBookByPath(context.file_path, { force = true })
end

function Grimmlink:clearSyncQueuesWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local progress_count = type(self.db.getPendingProgressCount) == "function" and self.db:getPendingProgressCount() or 0
    local session_count = type(self.db.getPendingSessionCount) == "function" and self.db:getPendingSessionCount() or 0
    local metadata_count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    local total = (progress_count or 0) + (session_count or 0) + (metadata_count or 0)
    if total <= 0 then
        self:showMessage(_("No pending sync queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear sync queues?\nProgress: %1\nSessions: %2\nMetadata: %3"), progress_count, session_count, metadata_count),
        _("Clear Queues"),
        function()
            local progress_ok = true
            local sessions_ok = true
            local metadata_ok = true

            if (progress_count or 0) > 0 and type(self.db.deleteAllPendingProgress) == "function" then
                progress_ok = self.db:deleteAllPendingProgress()
            end

            if (session_count or 0) > 0 and type(self.db.getPendingSessions) == "function" and type(self.db.deletePendingSession) == "function" then
                while true do
                    local rows = self.db:getPendingSessions(500) or {}
                    if #rows == 0 then
                        break
                    end
                    for _, row in ipairs(rows) do
                        if not self.db:deletePendingSession(row.id) then
                            sessions_ok = false
                        end
                    end
                end
            end

            if (metadata_count or 0) > 0 then
                metadata_ok = safeDbBoolCall(self.db, "deleteAllPendingMetadata")
            end

            local ok_all = progress_ok and sessions_ok and metadata_ok
            self:showMessage(ok_all and _("Sync queues cleared") or _("Failed to clear one or more sync queues"), 3)
        end
    )
end

function Grimmlink:runQuickCleanupWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local unmatched_count = type(self.db.getUnmatchedCacheCount) == "function" and self.db:getUnmatchedCacheCount() or 0
    local progress_count = safeDbValueCall(self.db, "getPendingProgressCount", 0)
    local session_count = safeDbValueCall(self.db, "getPendingSessionCount", 0)
    local metadata_count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    local can_clear_update_cache = self.updater and type(self.updater.clearCache) == "function"

    self:showConfirmAction(
        T(
            _("Run quick cleanup?\n- Clear update cache: %1\n- Clear unmatched book cache: %2\n- Clear pending progress queue: %3\n- Clear pending session queue: %4\n- Clear pending metadata queue: %5"),
            can_clear_update_cache and _("yes") or _("no"),
            unmatched_count,
            progress_count,
            session_count,
            metadata_count
        ),
        _("Run Cleanup"),
        function()
            local all_ok = true

            if can_clear_update_cache then
                if not self.updater:clearCache() then
                    all_ok = false
                end
            end

            if (unmatched_count or 0) > 0 and type(self.db.clearUnmatchedCache) == "function" then
                if not self.db:clearUnmatchedCache() then
                    all_ok = false
                end
            end

            if (progress_count or 0) > 0 and type(self.db.deleteAllPendingProgress) == "function" then
                if not self.db:deleteAllPendingProgress() then
                    all_ok = false
                end
            end

            if (session_count or 0) > 0 and type(self.db.getPendingSessions) == "function" and type(self.db.deletePendingSession) == "function" then
                while true do
                    local rows = self.db:getPendingSessions(500) or {}
                    if #rows == 0 then
                        break
                    end
                    for _, row in ipairs(rows) do
                        if not self.db:deletePendingSession(row.id) then
                            all_ok = false
                        end
                    end
                end
            end

            if (metadata_count or 0) > 0 then
                if not safeDbBoolCall(self.db, "deleteAllPendingMetadata") then
                    all_ok = false
                end
            end

            self:showMessage(all_ok and _("Quick cleanup complete") or _("Quick cleanup finished with some failures"), 4)
        end
    )
end

function Grimmlink:maybeCheckForUpdatesOnStartup()
    if not self.check_update_on_startup then return end
    -- Delay check to allow network to connect after startup
    self:runAfterUiSettles(function()
        if not self:isOnline() then return end
        local result = self:checkForUpdates(true, { force_refresh = true })
        if result and result.available and result.release_info then
            local from_version = safeToString(result.current_version) or _("unknown")
            local to_version = safeToString(result.latest_version) or _("unknown")
            self:showConfirmAction(
                T(_("Update available: %1 -> %2\nInstall now?"), from_version, to_version),
                _("Update"),
                function()
                    self:installUpdate(result.release_info)
                end
            )
        end
    end)
end

function Grimmlink:showAbout()
    local version_info = nil
    if self.plugin_dir then
        local ok, data = pcall(dofile, self.plugin_dir .. "/plugin_version.lua")
        if ok and type(data) == "table" then
            version_info = data
        end
    end

    local lines = {
        _("GrimmLink"),
        version_info and T(_("Version: %1"), version_info.version or _("unknown")) or _("Version: unknown"),
        _("Stable minimal companion for Grimmory."),
        _("EPUB Web Reader Bridge is intentionally disabled."),
    }
    self:showMessage(table.concat(lines, "\n"), 5)
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

function Grimmlink:showPdfBridgeStatus()
    self:showMessage(self:isPdfWebReaderBridgeEnabled() and _("PDF Web Reader Bridge enabled") or _("PDF Web Reader Bridge disabled"), 2)
end

return Grimmlink


