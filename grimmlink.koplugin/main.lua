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
local ProgressController = _glRequire("grimmlink_progress_controller")
local SessionController = _glRequire("grimmlink_session_controller")
local MaintenanceController = _glRequire("grimmlink_maintenance_controller")
local PendingSyncController = _glRequire("grimmlink_pending_sync_controller")
local RuntimeController = _glRequire("grimmlink_runtime_controller")
local TrackingController = _glRequire("grimmlink_tracking_controller")
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

if RuntimeController and type(RuntimeController.install) == "function" then
    RuntimeController.install(Grimmlink, {
        ConfirmBox = ConfirmBox,
        InfoMessage = InfoMessage,
        UIManager = UIManager,
        NetworkMgr = NetworkMgr,
        logger = logger,
        _ = _,
        normalizeSsid = normalizeSsid,
        safeMethodCall = safeMethodCall,
        unpack_values = unpack_values,
    })
end
if TrackingController and type(TrackingController.install) == "function" then
    TrackingController.install(Grimmlink, {
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
    })
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
if ProgressController and type(ProgressController.install) == "function" then
    ProgressController.install(Grimmlink, {
        ButtonDialog = ButtonDialog,
        UIManager = UIManager,
        bit = bit,
        json = json,
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
        FIXED_PAGE_FORMATS = FIXED_PAGE_FORMATS,
        REFLOWABLE_FORMATS = REFLOWABLE_FORMATS,
        absDifference = absDifference,
        cloneTable = cloneTable,
        formatTimestamp = formatTimestamp,
        isNonEmpty = isNonEmpty,
        isNumericOnlyToken = isNumericOnlyToken,
        maybeNumber = maybeNumber,
        normalizePercent = normalizePercent,
        nowUtc = nowUtc,
        safeDispatchEvent = safeDispatchEvent,
        safeMethodCall = safeMethodCall,
        safeToString = safeToString,
        sanitizeTitle = sanitizeTitle,
        tryReadSetting = tryReadSetting,
    })
end
if SessionController and type(SessionController.install) == "function" then
    SessionController.install(Grimmlink, {
        UIManager = UIManager,
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
        maybeNumber = maybeNumber,
        nowUtc = nowUtc,
        roundToSingleDecimal = roundToSingleDecimal,
        sanitizeTitle = sanitizeTitle,
        toIso8601 = toIso8601,
    })
end
if MaintenanceController and type(MaintenanceController.install) == "function" then
    MaintenanceController.install(Grimmlink, {
        ConfirmBox = ConfirmBox,
        UIManager = UIManager,
        _ = _,
        T = T,
        safeDbBoolCall = safeDbBoolCall,
        safeDbValueCall = safeDbValueCall,
        safeToString = safeToString,
    })
end
if PendingSyncController and type(PendingSyncController.install) == "function" then
    PendingSyncController.install(Grimmlink, {
        UIManager = UIManager,
        _ = _,
        T = T,
        DEFAULTS = DEFAULTS,
        nowUtc = nowUtc,
        safeDbValueCall = safeDbValueCall,
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
        lfs = lfs,
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
        READING_COMPLETION_RATING_STATE_KEY = READING_COMPLETION_RATING_STATE_KEY,
        buildReadingCompletionRatingState = buildReadingCompletionRatingState,
        convertTenScaleRatingToSummaryRating = convertTenScaleRatingToSummaryRating,
        tryCloseDocSettings = tryCloseDocSettings,
        tryFlushDocSettings = tryFlushDocSettings,
        tryReadSetting = tryReadSetting,
        tryWriteSetting = tryWriteSetting,
        lfs = lfs,
        InfoMessage = InfoMessage,
        UIManager = UIManager,
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

return Grimmlink


