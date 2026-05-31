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

local _ = require("gettext")
local T = ffiutil.template
local unpack_values = table.unpack or unpack

local Grimmlink = WidgetContainer:extend{
    name = "grimmlink",
    is_doc_only = false,
}

local DEFAULTS = {
    enabled = true,
    settings_tab_enabled = true,
    server_url = "",
    remote_url = "",
    local_url_nickname = "",
    remote_url_nickname = "",
    home_ssid = "",
    username = "",
    password = "",
    device_name = "KOReader",
    device_id = nil,
    auto_pull_on_open = true,
    auto_push_on_close = true,
    offline_queue_enabled = true,
    auto_sync_cooldown_seconds = 300,
    ask_wifi_before_sync = true,
    sync_on_network_connected = false,
    network_sync_cooldown_seconds = 300,
    debug_logging = false,
    log_to_file = false,
    threshold_percent = 1.0,
    threshold_minutes = 5,
    threshold_pages = 5,
    session_min_seconds = 30,
    shelf_sync_enabled = false,
    shelf_id = nil,
    shelf_name = "",
    shelf_type = "regular",
    download_dir = "",
    sync_regular_shelf_enabled = false,
    selected_regular_shelf_id = nil,
    selected_regular_shelf_name = "",
    sync_magic_shelf_enabled = false,
    selected_magic_shelf_id = nil,
    selected_magic_shelf_name = "",
    use_separate_magic_download_dir = false,
    magic_download_dir = "",
    shelf_fast_sync_enabled = true,
    shelf_fast_sync_cache_seconds = 15,
    auto_sync_shelf_on_resume = false,
    two_way_shelf_delete_sync = false,
    shelf_use_original_filename = true,
    delete_sdr_on_book_delete = false,
    refresh_bookinfo_after_shelf_sync = true,
    refresh_bookinfo_batch_size = 20,
    auto_update_enabled = false,
    check_update_on_startup = false,
    update_channel = "stable",
    update_repo = "0xstillb/grimmlink",
    allow_prerelease_updates = false,
    pdf_web_reader_bridge_enabled = false,
    metadata_sync_enabled = false,
    rating_sync_enabled = true,
    annotations_sync_enabled = true,
    bookmarks_sync_enabled = true,
    metadata_retry_max = 5,
    send_reflowable_percentage = true,
}

local DISK_SPACE_SAFETY_MARGIN_BYTES = 20 * 1024 * 1024
local READ_STATUS_CAPABILITY_CACHE_SECONDS = 300
local DIR_PICKER_MAX_SCAN_ENTRIES = 500
local DIR_PICKER_MAX_SHOW_DIRS = 60

local FIXED_PAGE_FORMATS = {
    PDF = true,
    CBX = true,
    CBZ = true,
    CBR = true,
    CB7 = true,
    DJVU = true,
    DJV = true,
}

local REFLOWABLE_FORMATS = {
    EPUB = true,
    MOBI = true,
    AZW = true,
    AZW3 = true,
    FB2 = true,
    HTML = true,
    HTM = true,
    TXT = true,
    DOCX = true,
}

local function safeToString(value)
    if value == nil then
        return ""
    end
    return tostring(value)
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

local function sanitizeTitle(file_path)
    local title = safeToString(file_path):match("([^/\\]+)$") or safeToString(file_path)
    return title:gsub("%.[^.]+$", "")
end

local function normalizeUpdateChannel(value)
    return value == "prerelease" and "prerelease" or "stable"
end

local function normalizeShelfType(value)
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

function Grimmlink:getCurrentSSID()
    if not NetworkMgr then
        return nil
    end
    local candidates = {
        function()
            if type(NetworkMgr.getCurrentNetwork) ~= "function" then
                return nil
            end
            local nw = NetworkMgr:getCurrentNetwork()
            if type(nw) == "table" then
                return nw.ssid
                    or nw.SSID
                    or nw.essid
                    or nw.ESSID
                    or nw.wifi_ssid
                    or nw.wifiSSID
                    or nw.network_name
                    or nw.networkName
                    or nw.name
            end
            if type(nw) == "string" then
                return nw
            end
            return nil
        end,
        function()
            if type(NetworkMgr.getCurrentSSID) == "function" then
                return NetworkMgr:getCurrentSSID()
            end
            return nil
        end,
        function()
            if type(NetworkMgr.getSSID) == "function" then
                return NetworkMgr:getSSID()
            end
            return nil
        end,
    }
    for _, candidate in ipairs(candidates) do
        local ok, ssid = pcall(candidate)
        if ok then
            local normalized = normalizeSsid(ssid)
            if normalized ~= "" then
                return normalized
            end
        end
    end
    return nil
end

function Grimmlink:resolveServerUrl(force_refresh)
    local _force_refresh = force_refresh
    if _force_refresh then
        -- Keep parameter for explicit caller intent; resolution is currently always refreshed.
    end
    local local_url = safeToString(self.server_url):gsub("/$", "")
    local remote_url = safeToString(self.remote_url):gsub("/$", "")
    local current_ssid = self:getCurrentSSID()
    local now_ts = nowUtc()
    local local_fail_cooldown = tonumber(self.local_fail_cooldown_seconds) or 60
    local fallback_until = tonumber(self._local_fail_cooldown_until) or 0
    local recent_local_failure = false

    if self.api and type(self.api.getLastPrimaryFailure) == "function" then
        local failure = self.api:getLastPrimaryFailure()
        if type(failure) == "table"
            and safeToString(failure.url) == local_url
            and tonumber(failure.at) ~= nil
            and ((now_ts - tonumber(failure.at)) <= local_fail_cooldown) then
            recent_local_failure = true
        end
    end

    local selected_url = local_url
    local selected_source = "local"
    local reason = "default_local"

    if local_url == "" and remote_url ~= "" then
        selected_url = remote_url
        selected_source = "remote"
        reason = "local_url_missing"
    elseif remote_url == "" then
        selected_url = local_url
        selected_source = local_url ~= "" and "local" or "unknown"
        reason = "remote_url_missing"
    elseif remote_url ~= "" and (recent_local_failure or fallback_until > now_ts) then
        selected_url = remote_url
        selected_source = "fallback"
        reason = recent_local_failure and "local_recently_failed" or "local_fail_cooldown_active"
    elseif local_url == "" and remote_url ~= "" then
        selected_url = remote_url
        selected_source = "remote"
        reason = "local_url_missing"
    else
        selected_url = local_url
        selected_source = "local"
        reason = "local_first_policy"
    end

    local previous_url = safeToString(self.active_url)
    local previous_source = safeToString(self.active_url_source)
    local changed = (previous_url ~= selected_url) or (previous_source ~= selected_source)

    self.active_url = selected_url
    self.active_url_source = selected_source
    self.last_url_switch_reason = reason
    self.last_resolved_ssid = current_ssid
    self.last_resolved_ssid_redacted = self:redactSSID(current_ssid)
    if changed then
        self.last_url_switch_at = nowUtc()
        if selected_source == "local" then
            self:logInfo("GrimmLink network changed: using Local URL (reason=", reason, ", ssid=", self:redactSSID(current_ssid), ")")
        elseif selected_source == "remote" then
            self:logInfo("GrimmLink network changed: using Remote URL (reason=", reason, ", ssid=", self:redactSSID(current_ssid), ")")
        else
            self:logInfo("GrimmLink network changed: fallback policy active (reason=", reason, ", ssid=", self:redactSSID(current_ssid), ")")
        end
    end
    return selected_url
end

function Grimmlink:refreshApiClient(force_refresh)
    if self:isApiReady() then
        local primary = self:resolveServerUrl(force_refresh)
        self.api:init(primary, self.username, self.password, self.debug_logging)
        local local_timeout = tonumber(self.local_request_timeout_seconds) or 2
        local remote_timeout = tonumber(self.remote_request_timeout_seconds) or 1
        if local_timeout < 1 then local_timeout = 1 end
        if remote_timeout < 1 then remote_timeout = 1 end
        if self.active_url_source == "remote" or self.active_url_source == "fallback" then
            self.api.timeout = remote_timeout
        else
            self.api.timeout = local_timeout
        end
        self.api.fallback_timeout = remote_timeout
        if self.remote_url ~= "" and self.server_url ~= "" and type(self.api.setFallbackUrl) == "function" then
            -- Avoid remote->local fallback because it doubles blocking timeout and
            -- can freeze UI when remote is down.
            if self.active_url_source == "local" then
                self.api:setFallbackUrl(safeToString(self.remote_url):gsub("/$", ""))
            else
                self.api:setFallbackUrl(nil)
            end
        end
        return true
    end
    return false
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

function Grimmlink:readSetting(key, default_value)
    local value = self.db and self.db:getPluginSetting(key)
    if value == nil then
        if default_value ~= nil and self.db then
            self.db:savePluginSetting(key, default_value)
        end
        return default_value
    end
    return value
end

function Grimmlink:saveSetting(key, value)
    if not self.db then
        return false
    end
    local ok = self.db:savePluginSetting(key, value)
    if ok then
        self[key] = value
        if key == "server_url" or key == "remote_url" or key == "home_ssid"
            or key == "username" or key == "password" or key == "debug_logging" then
            self:refreshApiClient()
        elseif key == "allow_prerelease_updates" then
            if self.updater and type(self.updater.setAllowPrerelease) == "function" then
                self.updater:setAllowPrerelease(self.allow_prerelease_updates)
            end
        elseif key == "update_repo" or key == "update_channel" then
            if self.updater and type(self.updater.init) == "function" then
                self.updater:init(self.plugin_dir, self.db, {
                    allow_prerelease = self.allow_prerelease_updates,
                    update_repo = self.update_repo,
                })
            end
        end
    end
    return ok
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
        if self.db then
            self.db:savePluginSetting("device_id", generated)
        end
        return generated
    end

    local fallback = string.format("grimmlink-%d", nowUtc())
    if self.db then
        self.db:savePluginSetting("device_id", fallback)
    end
    return fallback
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

function Grimmlink:isDirectory(path)
    if not lfs or type(lfs.attributes) ~= "function" then
        return false
    end
    local normalized = normalizeDirectoryPath(path)
    if normalized == "" then
        return false
    end
    local ok, attr = pcall(lfs.attributes, normalized)
    return ok and attr and attr.mode == "directory"
end

function Grimmlink:listChildDirectories(path)
    local normalized = normalizeDirectoryPath(path)
    local children = {}
    local scan_count = 0
    local truncated = false
    if not normalized or normalized == "" or not lfs or type(lfs.dir) ~= "function" then
        return children, truncated
    end

    local ok_iter, iter_fn, iter_state = pcall(lfs.dir, normalized)
    if not ok_iter or type(iter_fn) ~= "function" then
        return children, truncated
    end

    local ok_scan = pcall(function()
        for entry in iter_fn, iter_state do
            scan_count = scan_count + 1
            if scan_count > DIR_PICKER_MAX_SCAN_ENTRIES then
                truncated = true
                break
            end
            if entry ~= "." and entry ~= ".." then
                local child_path = joinDirectoryPath(normalized, entry)
                if self:isDirectory(child_path) then
                    children[#children + 1] = {
                        name = entry,
                        path = child_path,
                    }
                    if #children >= DIR_PICKER_MAX_SHOW_DIRS then
                        truncated = true
                        break
                    end
                end
            end
        end
    end)
    if not ok_scan then
        return {}, false
    end

    table.sort(children, function(a, b)
        return safeToString(a.name):lower() < safeToString(b.name):lower()
    end)
    return children, truncated
end

function Grimmlink:getDirectoryPickerStart(start_dir)
    local candidates = {
        normalizeDirectoryPath(start_dir),
        normalizeDirectoryPath(self.download_dir),
        normalizeDirectoryPath(self.magic_download_dir),
        normalizeDirectoryPath(DataStorage and DataStorage:getDataDir() or nil),
        normalizeDirectoryPath(DataStorage and DataStorage:getSettingsDir() or nil),
        "/storage/emulated/0",
        "/mnt/onboard",
        "/",
    }

    for _, candidate in ipairs(candidates) do
        if candidate and candidate ~= "" and self:isDirectory(candidate) then
            return candidate
        end
    end
    return nil
end

function Grimmlink:showDirectoryPicker(options)
    local opts = options or {}
    if not lfs then
        self:showMessage(_("Directory picker unavailable on this device"), 3)
        return
    end

    local current_dir = self:getDirectoryPickerStart(opts.current_dir or opts.start_dir)
    if not current_dir then
        self:showMessage(_("No accessible directories found"), 3)
        return
    end

    local dialog
    local function closePicker()
        if dialog then
            pcall(UIManager.close, UIManager, dialog)
            dialog = nil
        end
    end

    local function reopen(next_dir)
        closePicker()
        opts.current_dir = next_dir
        if UIManager and type(UIManager.scheduleIn) == "function" then
            UIManager:scheduleIn(0.01, function()
                self:showDirectoryPicker(opts)
            end)
        else
            self:showDirectoryPicker(opts)
        end
    end

    local buttons = {}
    local function addRow(text, callback)
        buttons[#buttons + 1] = {
            {
                text = text,
                callback = function()
                    self:invokeSafely("directory picker action", callback)
                end,
            },
        }
    end

    local title_text = opts.title or _("Select directory")
    if opts.allow_clear then
        addRow(opts.clear_label or _("Use default"), function()
            closePicker()
            if type(opts.on_select) == "function" then
                opts.on_select("")
            end
        end)
    end

    addRow(_("Select this folder") .. ": " .. current_dir, function()
        closePicker()
        if type(opts.on_select) == "function" then
            opts.on_select(current_dir)
        end
    end)

    if current_dir ~= "/" then
        addRow(_(".. (Parent folder)"), function()
            reopen(parentDirectoryPath(current_dir))
        end)
    end

    local child_dirs, was_truncated = self:listChildDirectories(current_dir)
    if #child_dirs == 0 then
        addRow(_("No subfolders"), function() end)
    else
        for _, child in ipairs(child_dirs) do
            addRow(_("Open folder") .. ": " .. safeToString(child.name), function()
                reopen(child.path)
            end)
        end
        if was_truncated then
            addRow(_("More folders exist (showing first results)"), function() end)
        end
    end

    addRow(_("Cancel"), function()
        closePicker()
    end)

    dialog = ButtonDialog:new{
        title = title_text,
        buttons = buttons,
    }
    UIManager:show(dialog)
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
    local current_value = safeToString(self.server_url)
    if current_value == "" then
        current_value = "http://"
    end
    self:showTextInput(_("Local URL (home network)"), current_value, "http://192.168.1.100:6060", false, function(value)
        local normalized = safeToString(value):gsub("/$", "")
        self:saveSetting("server_url", normalized)
        self:refreshApiClient()
        self:showTextInput(
            _("Home URL Nickname (optional)"),
            safeToString(self.local_url_nickname),
            _("Example: Home API"),
            false,
            function(nickname)
                self:saveSetting("local_url_nickname", normalizeNickname(nickname))
                self:showMessage(_("Local URL settings saved"), 2)
            end
        )
    end)
end

function Grimmlink:configureRemoteUrl()
    local current_value = safeToString(self.remote_url)
    if current_value == "" then
        current_value = "http://"
    end
    self:showTextInput(_("Remote URL (external)"), current_value, "https://grimmory.example.com", false, function(value)
        local normalized = safeToString(value):gsub("/$", "")
        self:saveSetting("remote_url", normalized)
        self:refreshApiClient()
        self:showTextInput(
            _("Remote URL Nickname (optional)"),
            safeToString(self.remote_url_nickname),
            _("Example: Public API"),
            false,
            function(nickname)
                self:saveSetting("remote_url_nickname", normalizeNickname(nickname))
                self:showMessage(_("Remote URL settings saved"), 2)
            end
        )
    end)
end

function Grimmlink:configureUsername()
    self:showTextInput(_("KOReader Username"), self.username, _("Enter username"), false, function(value)
        self:saveSetting("username", safeToString(value))
        self:showMessage(_("Username saved"), 2)
    end)
end

function Grimmlink:configurePassword()
    self:showTextInput(_("Password"), self.password, _("Enter Grimmory password"), true, function(value)
        self:saveSetting("password", safeToString(value))
        self:showMessage(_("Password saved"), 2)
    end)
end

function Grimmlink:promptTestConnectionAfterSetup()
    local dialog = ConfirmBox:new{
        text = _("Connection settings saved.\n\nTest connection now?"),
        ok_text = _("Test now"),
        ok_callback = function()
            self:testConnection()
        end,
        cancel_text = _("Later"),
    }
    UIManager:show(dialog)
end

function Grimmlink:saveConnectionSettings(server_url, username, password, remote_or_opts, maybe_opts)
    local remote_url = self.remote_url or ""
    local local_url_nickname = self.local_url_nickname or ""
    local remote_url_nickname = self.remote_url_nickname or ""
    local opts = maybe_opts
    if type(remote_or_opts) == "table" and opts == nil then
        opts = remote_or_opts
    elseif type(remote_or_opts) == "string" then
        remote_url = remote_or_opts
    end
    opts = opts or {}
    if type(opts.local_url_nickname) == "string" then
        local_url_nickname = opts.local_url_nickname
    end
    if type(opts.remote_url_nickname) == "string" then
        remote_url_nickname = opts.remote_url_nickname
    end
    local normalized_url = safeToString(server_url):gsub("/$", "")
    local normalized_remote = safeToString(remote_url):gsub("/$", "")
    self:saveSetting("server_url", normalized_url)
    self:saveSetting("remote_url", normalized_remote)
    self:saveSetting("local_url_nickname", normalizeNickname(local_url_nickname))
    self:saveSetting("remote_url_nickname", normalizeNickname(remote_url_nickname))
    self:saveSetting("username", safeToString(username))
    self:saveSetting("password", safeToString(password))
    if type(opts.on_saved) == "function" then
        opts.on_saved()
    end
    if opts.prompt_test ~= false then
        self:promptTestConnectionAfterSetup()
    end
end

function Grimmlink:configureConnection()
    local pending = {
        server_url = self.server_url or "",
        remote_url = self.remote_url or "",
        local_url_nickname = self.local_url_nickname or "",
        remote_url_nickname = self.remote_url_nickname or "",
        username = self.username or "",
        password = self.password or "",
    }

    local pending_local = safeToString(pending.server_url)
    if pending_local == "" then
        pending_local = "http://"
    end
    self:showTextInput(_("Local URL (home network)"), pending_local, "http://192.168.1.100:6060", false, function(server_url)
        pending.server_url = safeToString(server_url)
        self:showTextInput(_("Home URL Nickname (optional)"), pending.local_url_nickname, _("Example: Home API"), false, function(local_nickname)
            pending.local_url_nickname = normalizeNickname(local_nickname)
            local pending_remote = safeToString(pending.remote_url)
            if pending_remote == "" then
                pending_remote = "http://"
            end
            self:showTextInput(_("Remote URL (external)"), pending_remote, "https://grimmory.example.com", false, function(remote_url)
                pending.remote_url = safeToString(remote_url)
                self:showTextInput(_("Remote URL Nickname (optional)"), pending.remote_url_nickname, _("Example: Public API"), false, function(remote_nickname)
                    pending.remote_url_nickname = normalizeNickname(remote_nickname)
                    self:showTextInput(_("KOReader Username"), pending.username, _("Enter username"), false, function(username)
                        pending.username = safeToString(username)
                        self:showTextInput(_("Password"), pending.password, _("Enter Grimmory password"), true, function(password)
                            pending.password = safeToString(password)
                            self:saveConnectionSettings(pending.server_url, pending.username, pending.password, pending.remote_url, {
                                local_url_nickname = pending.local_url_nickname,
                                remote_url_nickname = pending.remote_url_nickname,
                                prompt_test = false,
                                on_saved = function()
                                    self:promptTestConnectionAfterSetup()
                                end,
                            })
                        end)
                    end)
                end)
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

function Grimmlink:tryEnableNetworkConnection()
    if not NetworkMgr then
        return false
    end

    local methods = {
        "turnOnWifi",
        "enableWifi",
        "enableNetwork",
        "connect",
        "reconnect",
    }
    for _, name in ipairs(methods) do
        if type(NetworkMgr[name]) == "function" then
            local ok, result = pcall(NetworkMgr[name], NetworkMgr)
            if ok and result ~= false then
                return true
            end
        end
    end
    return false
end

function Grimmlink:maybePromptEnableWifiForManualSync()
    if self:isOnline() then
        return true
    end

    if self.ask_wifi_before_sync ~= true then
        self:showMessage(_("No network connection"), 3)
        return false
    end

    local asked = false
    self:showConfirmAction(
        _("No network connection.\nEnable Wi-Fi and try sync again?"),
        _("Enable Wi-Fi"),
        function()
            local enabled = self:tryEnableNetworkConnection()
            if enabled then
                self:showMessage(_("Trying to enable network..."), 2)
                self:schedulePendingSync("manual sync after network", 2.0, {
                    progress_limit = 20,
                    session_limit = 50,
                    respect_cooldown = false,
                })
            else
                self:showMessage(_("No network connection"), 3)
            end
        end
    )
    asked = true
    return not asked
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

function Grimmlink:getMetadataExtractionContext()
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

    if (not file_hash or file_hash == "") and type(self.resolveBookByFilePath) == "function" then
        local ok_cached, cached = pcall(self.resolveBookByFilePath, self, file_path)
        if ok_cached and type(cached) == "table" then
            file_hash = cached.file_hash or file_hash
            book_id = book_id or cached.book_id
        end
    end

    if (not file_hash or file_hash == "") and type(self.calculateBookHash) == "function" then
        local ok_hash, computed_hash = pcall(self.calculateBookHash, self, file_path)
        if ok_hash then
            file_hash = computed_hash
        end
    end

    return {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
    }
end

local function safeDbBoolCall(db, method_name, ...)
    if not db or type(db[method_name]) ~= "function" then
        return false
    end
    local ok, result = pcall(db[method_name], db, ...)
    return ok and result == true or false
end

local function safeDbValueCall(db, method_name, default_value, ...)
    if not db or type(db[method_name]) ~= "function" then
        return default_value
    end
    local ok, result = pcall(db[method_name], db, ...)
    if not ok or result == nil then
        return default_value
    end
    return result
end

function Grimmlink:extractMetadataForContext(context)
    local empty = {
        rating = nil,
        highlights = {},
        bookmarks = {},
        counts = {
            rating_present = false,
            highlights_count = 0,
            notes_count = 0,
            bookmarks_count = 0,
        },
    }
    if not context or type(context) ~= "table" then
        return empty
    end
    if not MetadataExtractor or type(MetadataExtractor.extract) ~= "function" then
        return empty
    end

    local ok, extracted = pcall(MetadataExtractor.extract, {
        file_path = context.file_path,
        doc_settings = self.ui and self.ui.doc_settings or nil,
    })
    if not ok or type(extracted) ~= "table" then
        return empty
    end

    extracted.highlights = type(extracted.highlights) == "table" and extracted.highlights or {}
    extracted.bookmarks = type(extracted.bookmarks) == "table" and extracted.bookmarks or {}
    extracted.counts = type(extracted.counts) == "table" and extracted.counts or {}
    extracted.counts.rating_present = extracted.rating ~= nil
    extracted.counts.highlights_count = tonumber(extracted.counts.highlights_count) or #extracted.highlights
    extracted.counts.notes_count = tonumber(extracted.counts.notes_count) or 0
    extracted.counts.bookmarks_count = tonumber(extracted.counts.bookmarks_count) or #extracted.bookmarks
    return extracted
end

function Grimmlink:buildMetadataDedupeKey(file_hash, item_type, payload)
    if not file_hash or file_hash == "" then
        return nil
    end

    if item_type == "rating" then
        return file_hash .. ":rating"
    end

    if item_type == "annotation" then
        local datetime = safeToString(payload and payload.datetime) or ""
        local pos0 = safeToString(payload and payload.pos0) or ""
        local text_hash = stableTextHash((payload and payload.text) or (payload and payload.note) or "")
        return table.concat({ file_hash, "annotation", datetime, pos0, text_hash }, ":")
    end

    if item_type == "bookmark" then
        local datetime = safeToString(payload and payload.datetime) or ""
        local anchor = safeToString(payload and (payload.pos0 or payload.page or payload.pageno or payload.location)) or ""
        return table.concat({ file_hash, "bookmark", datetime, anchor }, ":")
    end

    return nil
end

function Grimmlink:queueMetadataFromContext(context, extracted, reason)
    local result = {
        queued = 0,
        skipped_synced = 0,
        failed = 0,
        total = 0,
    }

    if not self.enabled or not self.db or type(context) ~= "table" then
        return result
    end
    if not context.file_hash or context.file_hash == "" then
        return result
    end

    local items = {}
    if extracted and type(extracted.rating) == "table" and extracted.rating.raw then
        items[#items + 1] = {
            item_type = "rating",
            payload = {
                rating = extracted.rating.raw,
                ratingNormalized = extracted.rating.normalized,
                datetime = nowUtc(),
                source = reason,
            },
        }
    end

    for _, annotation in ipairs((extracted and extracted.highlights) or {}) do
        if type(annotation) == "table" then
            items[#items + 1] = {
                item_type = "annotation",
                payload = annotation,
            }
        end
    end

    for _, bookmark in ipairs((extracted and extracted.bookmarks) or {}) do
        if type(bookmark) == "table" then
            items[#items + 1] = {
                item_type = "bookmark",
                payload = bookmark,
            }
        end
    end

    result.total = #items
    for _, item in ipairs(items) do
        local dedupe_key = self:buildMetadataDedupeKey(context.file_hash, item.item_type, item.payload)
        if dedupe_key then
            local is_synced = safeDbBoolCall(self.db, "isMetadataItemSynced", context.file_hash, item.item_type, dedupe_key)
            if is_synced then
                result.skipped_synced = result.skipped_synced + 1
            else
                local payload_json = nil
                local ok_payload, encoded = pcall(json.encode, item.payload)
                if ok_payload and encoded ~= nil then
                    payload_json = encoded
                end
                if payload_json and safeDbBoolCall(self.db, "upsertPendingMetadataItem", {
                    file_hash = context.file_hash,
                    book_id = context.book_id,
                    book_file_id = context.book_file_id,
                    item_type = item.item_type,
                    dedupe_key = dedupe_key,
                    payload_json = payload_json,
                }) then
                    result.queued = result.queued + 1
                else
                    result.failed = result.failed + 1
                end
            end
        else
            result.failed = result.failed + 1
        end
    end

    return result
end

function Grimmlink:extractAndQueueCurrentMetadata(reason, context_override)
    if not self.enabled or not self.db then
        return nil
    end
    local context = context_override or self:getMetadataExtractionContext()
    if not context then
        return nil
    end
    if not self:isTrackingEnabledForContext(context) then
        return nil
    end
    local ok_extract, extracted = pcall(self.extractMetadataForContext, self, context)
    if not ok_extract then
        self:logWarn("GrimmLink metadata extract failed:", extracted)
        return nil
    end
    local ok_queue, queued = pcall(self.queueMetadataFromContext, self, context, extracted, reason or "metadata")
    if not ok_queue then
        self:logWarn("GrimmLink metadata queue failed:", queued)
        return nil
    end
    return {
        context = context,
        extracted = extracted,
        queued = queued,
    }
end

function Grimmlink:showMetadataPreview()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local context = self:getMetadataExtractionContext()
    if not context then
        self:showMessage(_("No active document to preview metadata"), 3)
        return
    end

    local ok_extract, extracted = pcall(self.extractMetadataForContext, self, context)
    if not ok_extract or type(extracted) ~= "table" then
        self:showMessage(_("Failed to preview metadata"), 3)
        return
    end
    local rating_text = _("none")
    if extracted.rating and extracted.rating.raw then
        rating_text = T(_("%1 (normalized %2)"), extracted.rating.raw, extracted.rating.normalized or "-")
    end

    local pending_count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    self:showMessage(T(
        _("Metadata Preview\nRating: %1\nHighlights: %2\nNotes: %3\nBookmarks: %4\nPending metadata: %5"),
        rating_text,
        extracted.counts and extracted.counts.highlights_count or 0,
        extracted.counts and extracted.counts.notes_count or 0,
        extracted.counts and extracted.counts.bookmarks_count or 0,
        pending_count
    ), 5)
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
    local device_name = self:defaultDeviceName()
    local log_path = self.file_logger and type(self.file_logger.getLogPath) == "function"
        and self.file_logger:getLogPath() or ""
    local current_ssid = self:getCurrentSSID()

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
        T(_("network_sync_cooldown_seconds: %1"), tonumber(self.network_sync_cooldown_seconds) or DEFAULTS.network_sync_cooldown_seconds),
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
        T(_("Download dir: %1"), safeToString(self.download_dir)),
        T(_("Magic download dir: %1"), safeToString(self.magic_download_dir)),
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

function Grimmlink:buildMetadataRatingPayload(row, payload)
    local value = tonumber(payload and payload.rating)
    if not value then
        return nil
    end
    value = math.floor(value + 0.5)
    if value < 1 or value > 5 then
        return nil
    end
    return {
        dedupeKey = row.dedupe_key,
        value = value,
        scale = 5,
        source = "koreader",
        updatedAt = parseIsoOrNil(payload and payload.datetime),
    }
end

function Grimmlink:buildMetadataAnnotationPayload(row, payload)
    payload = payload or {}
    return {
        dedupeKey = row.dedupe_key,
        type = "highlight",
        text = payload.text,
        note = payload.note,
        color = payload.color,
        drawer = payload.drawer,
        style = payload.style,
        chapter = payload.chapter,
        page = tonumber(payload.page) or tonumber(payload.pageno),
        location = {
            kind = "koreader",
            pos0 = payload.pos0,
            pos1 = payload.pos1,
            pageno = tonumber(payload.pageno),
            raw = payload.location,
        },
        createdAt = parseIsoOrNil(payload.datetime),
        updatedAt = parseIsoOrNil(payload.datetime),
    }
end

function Grimmlink:buildMetadataBookmarkPayload(row, payload)
    payload = payload or {}
    local bookmark_title = payload.title or payload.text
    return {
        dedupeKey = row.dedupe_key,
        title = bookmark_title,
        notes = payload.notes or payload.note,
        chapter = payload.chapter,
        page = tonumber(payload.page) or tonumber(payload.pageno),
        location = {
            kind = "koreader",
            pos0 = payload.pos0,
            pos1 = payload.pos1,
            pageno = tonumber(payload.pageno),
            raw = payload.location,
        },
        createdAt = parseIsoOrNil(payload.datetime),
        updatedAt = parseIsoOrNil(payload.datetime),
    }
end

function Grimmlink:markMetadataRowSynced(row, server_id)
    safeDbBoolCall(self.db, "markMetadataItemSynced", {
        file_hash = row.file_hash,
        book_id = row.book_id,
        item_type = row.item_type,
        dedupe_key = row.dedupe_key,
        server_id = server_id,
    })
    safeDbBoolCall(self.db, "deletePendingMetadataItem", row.id)
end

function Grimmlink:handleMetadataRowRetry(row, reason)
    local max_retry = tonumber(self.metadata_retry_max) or DEFAULTS.metadata_retry_max
    local retry_count = tonumber(row.retry_count) or 0
    if retry_count >= max_retry then
        self:logWarn("GrimmLink metadata drop after max retry itemType=", row.item_type,
            " dedupe=", shortPrefix(row.dedupe_key, 16), " reason=", reason)
        safeDbBoolCall(self.db, "deletePendingMetadataItem", row.id)
        return false
    end
    safeDbBoolCall(self.db, "incrementPendingMetadataRetry", row.id)
    return true
end

function Grimmlink:syncPendingMetadata(silent, limit)
    local synced = 0
    local failed = 0

    if not self.db or not self.metadata_sync_enabled then
        return synced, failed
    end
    if not self:requireReady({ require_api = true, silent = silent }) then
        return synced, failed
    end
    if not self:isOnline() then
        return synced, failed
    end
    if not self:isApiReady({ "submitMetadataBatch" }) then
        return synced, failed
    end
    if not self:refreshApiClient() then
        return synced, failed
    end

    local pending = safeDbValueCall(self.db, "getPendingMetadataItems", {}, limit or 100)
    if #pending == 0 then
        return synced, failed
    end

    local groups = {}
    for _, row in ipairs(pending) do
        if self:isTrackingEnabled(row.file_hash, nil) then
            local should_consider = (row.item_type ~= "rating" or self.rating_sync_enabled)
                and (row.item_type ~= "annotation" or self.annotations_sync_enabled)
                and (row.item_type ~= "bookmark" or self.bookmarks_sync_enabled)
            if should_consider then
                local ok_payload, payload = pcall(json.decode, row.payload_json or "")
                if not ok_payload or type(payload) ~= "table" then
                    safeDbBoolCall(self.db, "deletePendingMetadataItem", row.id)
                    failed = failed + 1
                else
                    local key = table.concat({
                        safeToString(row.book_id or ""),
                        safeToString(row.file_hash or ""),
                        safeToString(row.book_file_id or ""),
                    }, "|")
                    if not groups[key] then
                        groups[key] = {
                            book_id = row.book_id,
                            book_hash = row.file_hash,
                            book_file_id = row.book_file_id,
                            file_format = payload.fileFormat or payload.bookType or "EPUB",
                            rows = {},
                            item_by_dedupe = {},
                            rating = nil,
                            annotations = {},
                            bookmarks = {},
                        }
                    end
                    local group = groups[key]
                    group.rows[#group.rows + 1] = row
                    group.item_by_dedupe[row.dedupe_key] = row

                    if row.item_type == "rating" then
                        group.rating = self:buildMetadataRatingPayload(row, payload)
                    elseif row.item_type == "annotation" then
                        group.annotations[#group.annotations + 1] = self:buildMetadataAnnotationPayload(row, payload)
                    elseif row.item_type == "bookmark" then
                        group.bookmarks[#group.bookmarks + 1] = self:buildMetadataBookmarkPayload(row, payload)
                    end
                end
            end
        end
    end

    local function handleResult(group, item_result, fallback_item_type, processed_ids)
        if type(item_result) ~= "table" then
            return
        end
        local dedupe_key = item_result.dedupeKey
        local row = dedupe_key and group.item_by_dedupe[dedupe_key] or nil
        if not row then
            return
        end
        processed_ids[row.id] = true
        local status = tostring(item_result.status or "")
        if status == "synced" or status == "duplicate" or status == "updated" then
            self:markMetadataRowSynced(row, item_result.serverId)
            synced = synced + 1
            return
        end
        if status == "invalid" then
            self:logWarn("GrimmLink metadata invalid dropped itemType=", fallback_item_type,
                " dedupe=", shortPrefix(dedupe_key, 16), " error=", safeToString(item_result.error))
            safeDbBoolCall(self.db, "deletePendingMetadataItem", row.id)
            failed = failed + 1
            return
        end
        self:handleMetadataRowRetry(row, status ~= "" and status or "failed")
        failed = failed + 1
    end

    for _, group in pairs(groups) do
        local has_payload_items = not (group.rating == nil and #group.annotations == 0 and #group.bookmarks == 0)
        if has_payload_items then
            local payload = self.api:buildMetadataBatchPayload(
                group.book_id,
                group.book_hash,
                group.book_file_id,
                group.file_format,
                self.device_name,
                self.device_id,
                group.rating,
                group.annotations,
                group.bookmarks
            )

            local ok_submit, response, code = self.api:submitMetadataBatch(payload)
            if not ok_submit or type(response) ~= "table" then
                for _, row in ipairs(group.rows) do
                    self:handleMetadataRowRetry(row, safeToString(response or code or "network_error"))
                    failed = failed + 1
                end
            else
                local processed_ids = {}
                local results = response.results or {}
                if type(results.rating) == "table" then
                    handleResult(group, results.rating, "rating", processed_ids)
                end
                for _, item in ipairs(results.annotations or {}) do
                    handleResult(group, item, "annotation", processed_ids)
                end
                for _, item in ipairs(results.bookmarks or {}) do
                    handleResult(group, item, "bookmark", processed_ids)
                end

                -- Any item with no explicit result is treated as retryable failure.
                for _, row in ipairs(group.rows) do
                    if not processed_ids[row.id] then
                        self:handleMetadataRowRetry(row, "missing_result")
                        failed = failed + 1
                    end
                end
            end
        end
    end

    if not silent and (synced > 0 or failed > 0) then
        self:showMessage(T(_("Pending metadata sync\nSynced: %1\nFailed: %2"), synced, failed), 3)
    end
    return synced, failed
end

function Grimmlink:syncPendingNow(silent, opts)
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
    local pending_progress = safeDbValueCall(self.db, "getPendingProgressCount", 0)
    local pending_sessions = safeDbValueCall(self.db, "getPendingSessionCount", 0)
    local pending_metadata = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    local synced_metadata = safeDbValueCall(self.db, "getSyncedMetadataCount", 0)
    local pending_shelf_removals = safeDbValueCall(self.db, "getPendingShelfRemovalCount", 0)
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

function Grimmlink:rebuildMetadataQueueForCurrentBook()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local context = self:getMetadataExtractionContext()
    if not context or not context.file_hash then
        self:showMessage(_("No active document to rebuild metadata queue"), 3)
        return
    end
    if not self:isTrackingEnabledForContext(context) then
        self:showTrackingDisabledMessage()
        return
    end

    self:showConfirmAction(
        _("Rebuild metadata queue for current book?\nThis replaces local pending metadata rows for this file."),
        _("Rebuild Queue"),
        function()
            safeDbBoolCall(self.db, "deletePendingMetadataByFileHash", context.file_hash)
            local queued = self:extractAndQueueCurrentMetadata("rebuild-metadata-queue", context)
            if queued then
                local pending_count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
                self:showMessage(T(_("Metadata queue rebuilt for current book.\nPending metadata: %1"), pending_count), 4)
            else
                self:showMessage(_("Failed to rebuild metadata queue for current book"), 4)
            end
        end
    )
end

function Grimmlink:forceMetadataResyncForCurrentBook()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local context = self:getMetadataExtractionContext()
    if not context or not context.file_hash then
        self:showMessage(_("No active document to force metadata resync"), 3)
        return
    end
    if not self:isTrackingEnabledForContext(context) then
        self:showTrackingDisabledMessage()
        return
    end

    self:showConfirmAction(
        _("Force metadata re-upload for current book?\nThis clears local synced-history for this file only."),
        _("Force Resync"),
        function()
            local cleared_synced = safeDbBoolCall(self.db, "clearSyncedMetadataHistoryForFileHash", context.file_hash)
            local cleared_pending = safeDbBoolCall(self.db, "deletePendingMetadataByFileHash", context.file_hash)
            local queued = self:extractAndQueueCurrentMetadata("force-metadata-resync", context)
            if queued and (cleared_synced or cleared_pending) then
                self:syncPendingMetadata(false)
                self:showMessage(_("Forced metadata resync queued for current book"), 4)
            elseif queued then
                self:syncPendingMetadata(false)
                self:showMessage(_("Metadata resync queued (history clear partially unavailable)"), 4)
            else
                self:showMessage(_("Failed to queue forced metadata resync"), 4)
            end
        end
    )
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

-- ============================================================
-- Async shelf sync — downloads one file at a time, yielding
-- control back to UIManager between each download so the UI
-- stays responsive on weak e-reader CPUs.
-- ============================================================

-- Guard: prevent double-sync.
function Grimmlink:_isShelfSyncRunning()
    return self._shelf_sync_running == true
end

-- Show / update the progress InfoMessage for the current download.
-- progress is optional table: {pct=0-100, bytes=N, total=N}
-- When nil, shows "Connecting..." state.
function Grimmlink:_showSyncProgress(idx, total, title, progress)
    -- Close the plan-phase message popup (showShelfSyncMessage) first —
    -- it uses a different widget ref and would otherwise stay on top
    -- of our progress popup, hiding it completely.
    self:closeShelfSyncMessage()

    -- Close previous progress widget.
    if self._shelf_sync_progress_widget then
        self._shelf_sync_progress_widget.dismiss_callback = nil
        pcall(UIManager.close, UIManager, self._shelf_sync_progress_widget)
        self._shelf_sync_progress_widget = nil
    end

    local short_title = title or "?"
    if #short_title > 40 then short_title = short_title:sub(1, 40) .. "..." end

    local lines = {}
    -- Header
    lines[#lines + 1] = T(_("Downloading  %1 / %2"), idx, total)
    lines[#lines + 1] = ""
    lines[#lines + 1] = short_title

    if progress then
        lines[#lines + 1] = ""
        local pct = progress.pct or 0
        local bytes = progress.bytes or 0

        -- Size + percentage on one line:  62%  -  131.2 / 200.8 MB
        if progress.total and progress.total > 0 then
            lines[#lines + 1] = string.format("%d%%  -  %.1f / %.1f MB",
                pct, bytes / (1024 * 1024), progress.total / (1024 * 1024))
        elseif bytes > 0 then
            lines[#lines + 1] = string.format("%.1f MB", bytes / (1024 * 1024))
        end

        -- Progress bar
        local bar_w = 15
        local filled = math.floor(pct / 100 * bar_w)
        if filled > bar_w then filled = bar_w end
        lines[#lines + 1] = string.rep("\xE2\x96\x88", filled)
                          .. string.rep("\xE2\x96\x91", bar_w - filled)
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Connecting...")
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.rep("\xE2\x94\x80", 15)
    lines[#lines + 1] = "\xE2\x96\xB6  " .. _("Tap to cancel") .. "  \xE2\x97\x80"

    local grimmlink_self = self
    local widget = InfoMessage:new{
        text    = table.concat(lines, "\n"),
        timeout = 600,
        dismiss_callback = function()
            grimmlink_self:_confirmCancelSync()
        end,
    }
    self._shelf_sync_progress_widget = widget
    UIManager:show(widget)
    UIManager:forceRePaint()
end

function Grimmlink:_closeSyncProgress()
    if self._shelf_sync_progress_widget then
        self._shelf_sync_progress_widget.dismiss_callback = nil
        pcall(UIManager.close, UIManager, self._shelf_sync_progress_widget)
        self._shelf_sync_progress_widget = nil
    end
    self:closeShelfSyncMessage()
end

-- Update download progress.  progress = {pct, bytes, total}
function Grimmlink:_updateSyncProgressPct(idx, total, title, progress)
    self:_showSyncProgress(idx, total, title, progress)
end

-- Ask user whether to cancel.  Already-downloaded files are kept.
function Grimmlink:_confirmCancelSync()
    if not self._shelf_sync_running then return end
    local grimmlink_self = self
    local box = ConfirmBox:new{
        text = _("Cancel shelf sync?\nBooks already downloaded will be kept."),
        ok_text = _("Cancel sync"),
        cancel_text = _("Continue"),
        ok_callback = function()
            grimmlink_self._shelf_sync_cancelled = true
        end,
    }
    UIManager:show(box)
end

-- Multi-line completion summary.
function Grimmlink:_showSyncCompletionSummary(result)
    self:_closeSyncProgress()
    local lines = {}
    local synced  = result.synced or 0
    local skipped = result.skipped or 0
    local deleted = result.deleted or 0
    local failed  = result.failed or 0
    local total   = synced + skipped + deleted + failed
    local errors_count = type(result.errors) == "table" and #result.errors or 0

    if result.cancelled then
        lines[#lines + 1] = _("Shelf Sync Cancelled")
    elseif errors_count > 0 then
        lines[#lines + 1] = _("Shelf Sync Completed with Errors")
    else
        lines[#lines + 1] = _("Shelf Sync Complete")
    end
    lines[#lines + 1] = "---------------------------"

    if total == 0 and not result.cancelled then
        if errors_count > 0 then
            lines[#lines + 1] = _("No changes were applied due to errors.")
        else
            lines[#lines + 1] = _("Everything is up to date.")
        end
    else
        local items = {}
        if synced > 0 then items[#items + 1] = { _("Downloaded"), synced } end
        if skipped > 0 then items[#items + 1] = { _("Skipped"), skipped } end
        if deleted > 0 then items[#items + 1] = { _("Removed"), deleted } end
        if failed > 0 then  items[#items + 1] = { _("Failed"), failed } end
        local max_len = 0
        for _, v in ipairs(items) do
            if #v[1] > max_len then max_len = #v[1] end
        end
        for _, v in ipairs(items) do
            local pad = string.rep(" ", max_len - #v[1] + 2)
            lines[#lines + 1] = "\xE2\x96\xB6 " .. v[1] .. pad .. tostring(v[2])
        end
    end

    if type(result.errors) == "table" and #result.errors > 0 then
        lines[#lines + 1] = ""
        local first_err = safeToString(result.errors[1] or "")
        if #first_err > 120 then first_err = first_err:sub(1, 120) .. "..." end
        if first_err ~= "" then
            lines[#lines + 1] = first_err
        end
    end
    UIManager:show(InfoMessage:new{
        text    = table.concat(lines, "\n"),
        timeout = 8,
    })
end

-- Broadcast sync result so other plugins (e.g. SimpleUI) can react.
function Grimmlink:_broadcastSyncResult(result)
    if not Event then return end
    if (result.synced or 0) == 0 and (result.deleted or 0) == 0 then return end
    local event_shelf_type = normalizeShelfType(
        (result and result.shelf_type)
        or self._active_sync_shelf_type
        or self.shelf_type
        or "regular"
    )
    local event_download_dir = (result and result.download_dir)
        or self._active_sync_download_dir
        or self:getShelfSyncTargetDownloadDir(event_shelf_type)
    local ev = Event:new("GrimmLinkShelfSyncComplete", {
        synced              = result.synced or 0,
        deleted             = result.deleted or 0,
        skipped             = result.skipped or 0,
        shelf_type          = event_shelf_type,
        download_dir        = event_download_dir,
        metadata_index_path = result.metadata_index_path,
    })
    local function _emit()
        if UIManager and type(UIManager.broadcastEvent) == "function" then
            pcall(UIManager.broadcastEvent, UIManager, ev)
            return
        end
        local FM2 = FileManager and FileManager.instance
        if FM2 and type(FM2.handleEvent) == "function" then
            pcall(FM2.handleEvent, FM2, ev)
        end
    end
    if UIManager and type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(0.1, _emit)
    else
        pcall(_emit)
    end
end

function Grimmlink:getShelfSyncTargetDownloadDir(shelf_type)
    local normalized_type = normalizeShelfType(shelf_type)
    if normalized_type == "magic" and self.use_separate_magic_download_dir then
        return self.magic_download_dir
    end
    return self.download_dir
end

function Grimmlink:getActiveShelfSelection()
    local regular_enabled = self.sync_regular_shelf_enabled == true and self.selected_regular_shelf_id ~= nil
    local magic_enabled = self.sync_magic_shelf_enabled == true and self.selected_magic_shelf_id ~= nil

    if regular_enabled and magic_enabled then
        return {
            id = self.selected_regular_shelf_id,
            name = self.selected_regular_shelf_name or self.shelf_name,
            type = "regular",
            note = "both_enabled_partial",
        }
    end
    if regular_enabled then
        return {
            id = self.selected_regular_shelf_id,
            name = self.selected_regular_shelf_name or self.shelf_name,
            type = "regular",
        }
    end
    if magic_enabled then
        return {
            id = self.selected_magic_shelf_id,
            name = self.selected_magic_shelf_name,
            type = "magic",
        }
    end

    if self.shelf_id ~= nil then
        return {
            id = self.shelf_id,
            name = self.shelf_name,
            type = normalizeShelfType(self.shelf_type),
        }
    end

    return nil
end

function Grimmlink:getAvailableDiskBytes(path)
    local target = safeToString(path)
    if target == "" then
        return nil
    end

    local dir_attr = lfs and lfs.attributes and lfs.attributes(target) or nil
    if not dir_attr then
        local parent = target:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            target = parent
        end
    elseif dir_attr.mode ~= "directory" then
        local parent = target:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            target = parent
        end
    end

    local handle = io.popen("df -Pk " .. shellQuote(target) .. " 2>/dev/null")
    if not handle then
        return nil
    end
    local output = handle:read("*a")
    handle:close()
    return parseDfAvailableBytes(output)
end

function Grimmlink:checkDiskSpaceForShelfItem(item, active_download_dir)
    local book = item and item.book or nil
    local size_kb = book and tonumber(book.fileSizeKb) or nil
    if not size_kb or size_kb <= 0 then
        return true, nil, nil, "size_unavailable"
    end

    local resolved_dir = active_download_dir
    if self.shelf_sync and type(self.shelf_sync.resolveDownloadDir) == "function" then
        resolved_dir = self.shelf_sync:resolveDownloadDir(active_download_dir)
    end
    local available_bytes = self:getAvailableDiskBytes(resolved_dir or active_download_dir or self.download_dir)
    if not available_bytes then
        return true, nil, nil, "space_unavailable"
    end

    local required_bytes = math.floor(size_kb * 1024) + DISK_SPACE_SAFETY_MARGIN_BYTES
    if available_bytes < required_bytes then
        return false, available_bytes, required_bytes, "insufficient_space"
    end
    return true, available_bytes, required_bytes, nil
end

function Grimmlink:syncShelfNow(silent, opts)
    opts = type(opts) == "table" and opts or {}
    local selection_override = type(opts.selection_override) == "table" and opts.selection_override or nil
    local suppress_completion_summary = opts.suppress_completion_summary == true
    local on_complete = type(opts.on_complete) == "function" and opts.on_complete or nil

    if not self:requireReady({ require_api = true, silent = silent }) then
        return nil
    end
    if not self.shelf_sync_enabled then
        if not silent then
            self:showMessage(_("Shelf Sync is disabled. Enable it first."), 3)
        end
        return nil
    end
    if not self.shelf_sync or type(self.shelf_sync.prepareSyncPlan) ~= "function" then
        if not silent then
            self:showMessage(_("Shelf sync module unavailable"), 3)
        end
        return nil
    end
    local selection = selection_override
    local followup_selection = nil
    if not selection then
        local regular_enabled = self.sync_regular_shelf_enabled == true and self.selected_regular_shelf_id ~= nil
        local magic_enabled = self.sync_magic_shelf_enabled == true and self.selected_magic_shelf_id ~= nil
        if regular_enabled and magic_enabled then
            selection = {
                id = self.selected_regular_shelf_id,
                name = self.selected_regular_shelf_name or self.shelf_name,
                type = "regular",
            }
            followup_selection = {
                id = self.selected_magic_shelf_id,
                name = self.selected_magic_shelf_name,
                type = "magic",
            }
            suppress_completion_summary = true
            self:logInfo("GrimmLink: both regular and magic shelf sync are enabled; running regular first then magic")
        else
            selection = self:getActiveShelfSelection()
        end
    end

    if not selection or not selection.id then
        if not silent then
            self:showMessage(_("No shelf selected. Go to Shelf Sync -> Select Shelf."), 3)
        end
        return nil
    end

    local active_shelf_id = selection.id
    local active_shelf_name = selection.name and selection.name ~= "" and selection.name or tostring(selection.id)
    local active_shelf_type = normalizeShelfType(selection.type)
    local active_download_dir = self:getShelfSyncTargetDownloadDir(active_shelf_type)
    self._active_sync_shelf_type = active_shelf_type
    self._active_sync_download_dir = active_download_dir

    if active_shelf_type == "magic" and self.use_separate_magic_download_dir then
        if not active_download_dir or active_download_dir == "" then
            if not silent then
                self:showMessage(_("Magic Shelf directory cannot be created"), 4)
            end
            return nil
        end
        local resolved_magic_dir = self.shelf_sync and self.shelf_sync.resolveDownloadDir
            and self.shelf_sync:resolveDownloadDir(active_download_dir) or active_download_dir
        if resolved_magic_dir ~= active_download_dir then
            if not silent then
                self:showMessage(_("Magic Shelf directory cannot be created"), 4)
            end
            return nil
        end
    end
    if not self:isOnline() then
        if not silent then
            self:showMessage(_("No network connection"), 3)
        end
        return nil
    end
    if not self:refreshApiClient() then
        if not silent then
            self:showMessage(_("Connection not ready"), 3)
        end
        return nil
    end
    -- Prevent double-sync.
    if self:_isShelfSyncRunning() then
        if not silent then
            self:showMessage(_("Shelf sync is already running."), 2)
        end
        return nil
    end

    self._shelf_sync_running   = true
    self._shelf_sync_cancelled = false

    if not silent then
        local prefix = active_shelf_type == "magic" and _("Syncing Magic Shelf: %1") or _("Syncing Regular Shelf: %1")
        self:showShelfSyncMessage(T(prefix, active_shelf_name), 2)
    end

    local remote_delete_sync = self.two_way_shelf_delete_sync
    local preloaded_remote_books = nil
    local cached_books_age = nil
    if self.shelf_fast_sync_enabled and not remote_delete_sync then
        preloaded_remote_books, cached_books_age = self:getCachedShelfBooks(active_shelf_id, active_shelf_type, self.shelf_fast_sync_cache_seconds or 15)
        if preloaded_remote_books and not silent then
            self:showShelfSyncMessage(T(_("Fast Sync: using cached shelf data (%1s old)"), math.max(0, math.floor(tonumber(cached_books_age) or 0))), 2)
        end
    end

    -- Phase 1: Plan (classify books — fast, no large I/O).
    local ok_plan, plan_or_err = pcall(function()
        return self.shelf_sync:prepareSyncPlan({
            shelf_id = active_shelf_id,
            shelf_type = active_shelf_type,
            download_dir = active_download_dir,
            use_original_filename = self.shelf_use_original_filename,
            remote_delete_sync = remote_delete_sync,
            delete_sdr = self.delete_sdr_on_book_delete,
            preloaded_remote_books = preloaded_remote_books,
            on_progress = function(msg)
                if not silent then self:showShelfSyncMessage(safeToString(msg), 2) end
            end,
            on_fetched_remote_books = function(remote_books)
                if self.shelf_fast_sync_enabled and type(remote_books) == "table" then
                    self:setShelfBooksCache(active_shelf_id, active_shelf_type, remote_books)
                end
            end,
        })
    end)
    if not ok_plan then
        self._shelf_sync_running = false
        self._active_sync_shelf_type = nil
        self._active_sync_download_dir = nil
        local err_text = safeToString(plan_or_err)
        self:logErr("GrimmLink shelf sync plan crashed:", err_text)
        if not silent then
            self:_closeSyncProgress()
            self:showShelfSyncMessage(T(_("Shelf sync failed:\n%1"), err_text), 5)
        end
        return nil
    end

    local plan   = plan_or_err
    local result = plan.result
    local queue  = plan.download_queue or {}
    local total  = #queue
    local downloaded_files_to_refresh = plan.cleanup and plan.cleanup.downloaded_files_to_refresh or {}
    local downloaded_files_to_refresh_set = plan.cleanup and plan.cleanup.downloaded_files_to_refresh_set or {}
    result.shelf_type = active_shelf_type
    result.download_dir = active_download_dir

    -- Nothing to download → finish immediately.
    if total == 0 then
        -- Still run cleanup phase.
        if plan.cleanup then
            pcall(function()
                self.shelf_sync:runCleanupPhase(plan.cleanup, result, function(msg)
                    if not silent then self:showShelfSyncMessage(safeToString(msg), 2) end
                end)
            end)
        end
        -- Write metadata index + update bookinfo_cache for series browsing
        local resolved_dir = self.shelf_sync:resolveDownloadDir(active_download_dir)
        local index_path
        pcall(function()
            index_path = self.shelf_sync:writeMetadataIndex(nil, resolved_dir)
        end)
        pcall(function()
            self.shelf_sync:upsertBookInfoCache(nil)
        end)
        result.metadata_index_path = index_path
        result.bookinfo_refresh = { total = 0, refreshed = 0, failed = 0 }
        self._shelf_sync_running = false
        self._active_sync_shelf_type = nil
        self._active_sync_download_dir = nil
        if not silent and not suppress_completion_summary then
            self:_showSyncCompletionSummary(result)
        end
        self:_broadcastSyncResult(result)
        if followup_selection and followup_selection.id and not self._shelf_sync_cancelled then
            UIManager:scheduleIn(0.2, function()
                self:syncShelfNow(silent, {
                    selection_override = followup_selection,
                    suppress_completion_summary = false,
                    on_complete = on_complete,
                })
            end)
            return nil
        end
        if on_complete then
            pcall(on_complete, result)
        end
        return result
    end

    -- Decide whether to use async (curl/wget subprocess) or blocking (LuaSocket).
    local use_async = self.api:isAsyncDownloadAvailable()

    -- Phase 2: Download loop.
    local idx = 0
    local grimmlink_self = self
    local active_handle  = nil  -- current curl download handle (async mode)

    -- Helper: build progress info table from byte counts.
    local function fmtProgress(bytes_so_far, total_bytes)
        local info = { bytes = bytes_so_far or 0 }
        if total_bytes and total_bytes > 0 then
            info.total = total_bytes
            info.pct = math.min(100, math.floor(bytes_so_far / total_bytes * 100))
        else
            info.pct = 0
        end
        return info
    end

    local function finalizeSyncState()
        grimmlink_self._shelf_sync_running = false
        grimmlink_self._active_sync_shelf_type = nil
        grimmlink_self._active_sync_download_dir = nil
        if not silent and not suppress_completion_summary then
            grimmlink_self:_showSyncCompletionSummary(result)
        end
        grimmlink_self:_broadcastSyncResult(result)
        if followup_selection and followup_selection.id and not grimmlink_self._shelf_sync_cancelled then
            UIManager:scheduleIn(0.2, function()
                grimmlink_self:syncShelfNow(silent, {
                    selection_override = followup_selection,
                    suppress_completion_summary = false,
                    on_complete = on_complete,
                })
            end)
            return
        end
        if on_complete then
            pcall(on_complete, result)
        end
    end

    local function runPostSyncBookInfoRefresh(done_callback)
        if type(done_callback) ~= "function" then
            return
        end

        if not grimmlink_self.refresh_bookinfo_after_shelf_sync then
            result.bookinfo_refresh = { total = 0, refreshed = 0, failed = 0, skipped = true }
            done_callback()
            return
        end
        if type(downloaded_files_to_refresh) ~= "table" or #downloaded_files_to_refresh == 0 then
            result.bookinfo_refresh = { total = 0, refreshed = 0, failed = 0 }
            done_callback()
            return
        end
        if not grimmlink_self.shelf_sync or type(grimmlink_self.shelf_sync.refreshBookInfoForFile) ~= "function" then
            result.bookinfo_refresh = {
                total = #downloaded_files_to_refresh,
                refreshed = 0,
                failed = #downloaded_files_to_refresh,
                skipped = true,
                error = "refresh_api_unavailable",
            }
            logger.warn("GrimmLink: shelf sync book-info refresh API unavailable")
            done_callback()
            return
        end

        local refresh_batch_size = math.floor(tonumber(grimmlink_self.refresh_bookinfo_batch_size) or 20)
        if refresh_batch_size < 1 then refresh_batch_size = 1 end
        if refresh_batch_size > 200 then refresh_batch_size = 200 end

        local refresh_result = { total = #downloaded_files_to_refresh, refreshed = 0, failed = 0, errors = {} }
        local refresh_index = 0
        local function rebuildSimpleUiMetadataCache()
            if not grimmlink_self.shelf_sync or type(grimmlink_self.shelf_sync.rebuildBookInfoCacheFromIndex) ~= "function" then
                return nil
            end
            local rebuild_download_dir = active_download_dir
            if type(grimmlink_self.shelf_sync.resolveDownloadDir) == "function" then
                rebuild_download_dir = grimmlink_self.shelf_sync:resolveDownloadDir(active_download_dir)
            end
            local ok_rebuild, counts_or_err = pcall(
                grimmlink_self.shelf_sync.rebuildBookInfoCacheFromIndex,
                grimmlink_self.shelf_sync,
                rebuild_download_dir
            )
            if ok_rebuild then
                return counts_or_err
            end
            return { error = safeToString(counts_or_err) }
        end

        if not silent then
            grimmlink_self:showShelfSyncMessage(_("Refreshing book info..."), 2)
        end

        local function processNextBatch()
            if grimmlink_self._shelf_sync_cancelled then
                result.bookinfo_refresh = refresh_result
                done_callback()
                return
            end

            local batch_processed = 0
            while refresh_index < #downloaded_files_to_refresh and batch_processed < refresh_batch_size do
                refresh_index = refresh_index + 1
                batch_processed = batch_processed + 1
                local file_path = downloaded_files_to_refresh[refresh_index]
                local ok_refresh, method_name, refresh_err = grimmlink_self.shelf_sync:refreshBookInfoForFile(file_path, {})
                if ok_refresh then
                    refresh_result.refreshed = refresh_result.refreshed + 1
                else
                    refresh_result.failed = refresh_result.failed + 1
                    refresh_result.errors[#refresh_result.errors + 1] = {
                        file_path = file_path,
                        method = method_name,
                        error = refresh_err,
                    }
                end
            end

            if not silent then
                grimmlink_self:showShelfSyncMessage(T(_("Refreshing covers %1 / %2"), refresh_index, refresh_result.total), 2)
            end

            if refresh_index >= #downloaded_files_to_refresh then
                result.bookinfo_refresh = refresh_result
                result.simpleui_cache_rebuild = rebuildSimpleUiMetadataCache()
                if not silent then
                    if refresh_result.failed > 0 then
                        grimmlink_self:showShelfSyncMessage(
                            _("Shelf sync complete. Some covers may need manual refresh."),
                            4
                        )
                    else
                        grimmlink_self:showShelfSyncMessage(_("Book info refresh complete"), 2)
                    end
                end
                done_callback()
                return
            end

            UIManager:scheduleIn(0.05, processNextBatch)
        end

        UIManager:scheduleIn(0.05, processNextBatch)
    end

    -- Helper: finish sync (cleanup + summary + broadcast).
    local function finishSync()
        if not silent then
            grimmlink_self:_closeSyncProgress()
            grimmlink_self:showShelfSyncMessage(_("Cleaning up..."), 2)
        end
        if plan.cleanup then
            pcall(function()
                grimmlink_self.shelf_sync:runCleanupPhase(plan.cleanup, result, function(msg)
                    if not silent then grimmlink_self:showShelfSyncMessage(safeToString(msg), 2) end
                end)
            end)
        end
        -- Write metadata index + update bookinfo_cache for series browsing
        local resolved_dir = grimmlink_self.shelf_sync:resolveDownloadDir(active_download_dir)
        local index_path
        pcall(function()
            index_path = grimmlink_self.shelf_sync:writeMetadataIndex(nil, resolved_dir)
        end)
        pcall(function()
            grimmlink_self.shelf_sync:upsertBookInfoCache(nil)
        end)
        result.metadata_index_path = index_path
        runPostSyncBookInfoRefresh(finalizeSyncState)
    end

    -- Helper: handle cancellation.
    local function handleCancel()
        result.cancelled = true
        if active_handle then
            pcall(grimmlink_self.api.cancelAsyncDownload, grimmlink_self.api, active_handle)
            active_handle = nil
        end
        if plan.cleanup then
            pcall(function()
                grimmlink_self.shelf_sync:runCleanupPhase(plan.cleanup, result, function() end)
            end)
        end
        grimmlink_self._shelf_sync_running = false
        grimmlink_self._active_sync_shelf_type = nil
        grimmlink_self._active_sync_download_dir = nil
        if not silent and not suppress_completion_summary then
            grimmlink_self:_showSyncCompletionSummary(result)
        end
        grimmlink_self:_broadcastSyncResult(result)
        if on_complete then
            pcall(on_complete, result)
        end
    end

    local function startNextDownload()
        -- Check cancel.
        if grimmlink_self._shelf_sync_cancelled then
            handleCancel()
            return
        end

        idx = idx + 1
        if idx > total then
            finishSync()
            return
        end

        local item = queue[idx]
        local enough_space, available_bytes, required_bytes, space_reason = grimmlink_self:checkDiskSpaceForShelfItem(item, active_download_dir)
        if not enough_space then
            result.skipped = (result.skipped or 0) + 1
            local msg = T(
                _("Skipped %1 (bookId=%2): insufficient storage.\nAvailable: %3 MB\nRequired (with margin): %4 MB"),
                safeToString(item and item.title or _("unknown")),
                safeToString(item and item.book_id or "?"),
                math.floor((tonumber(available_bytes) or 0) / (1024 * 1024)),
                math.floor((tonumber(required_bytes) or 0) / (1024 * 1024))
            )
            logger.warn("GrimmLink: " .. msg)
            result.errors[#result.errors + 1] = msg
            if not silent then
                grimmlink_self:showShelfSyncMessage(msg, 5)
            end
            UIManager:scheduleIn(0.1, startNextDownload)
            return
        elseif space_reason == "space_unavailable" then
            logger.warn("GrimmLink: storage free-space check unavailable; proceeding with download")
        end
        if not silent then
            grimmlink_self:_showSyncProgress(idx, total, item.title, nil)
        end

        if use_async then
            -- === ASYNC PATH: curl/wget subprocess ===
            UIManager:nextTick(function()
                local ok_start, handle_or_err = pcall(
                    grimmlink_self.shelf_sync.startAsyncDownload,
                    grimmlink_self.shelf_sync, item)
                if not ok_start or not handle_or_err then
                    result.failed = result.failed + 1
                    local err = "Async start failed bookId=" .. tostring(item.book_id)
                        .. ": " .. safeToString(handle_or_err or ok_start)
                    result.errors[#result.errors + 1] = err
                    logger.warn("GrimmLink:", err)
                    UIManager:scheduleIn(0.1, startNextDownload)
                    return
                end

                active_handle = handle_or_err

                local function pollDownload()
                    if grimmlink_self._shelf_sync_cancelled then
                        handleCancel()
                        return
                    end

                    local ok_poll, status, bytes, total_bytes, exit_code = pcall(
                        grimmlink_self.api.pollAsyncDownload,
                        grimmlink_self.api, active_handle)

                    if not ok_poll then
                        logger.warn("GrimmLink: poll error:", safeToString(status))
                        result.failed = result.failed + 1
                        result.errors[#result.errors + 1] = "Poll error: " .. safeToString(status)
                        active_handle = nil
                        UIManager:scheduleIn(0.1, startNextDownload)
                        return
                    end

                    if status == "running" then
                        if not silent then
                            grimmlink_self:_updateSyncProgressPct(
                                idx, total, item.title, fmtProgress(bytes, total_bytes))
                        end
                        UIManager:scheduleIn(2, pollDownload)
                    elseif status == "done" then
                        pcall(grimmlink_self.shelf_sync.recordDownload,
                            grimmlink_self.shelf_sync,
                            item, plan.cleanup.shelf_id, plan.cleanup.sync_start,
                            downloaded_files_to_refresh, downloaded_files_to_refresh_set)
                        result.synced = result.synced + 1
                        active_handle = nil
                        if not silent then
                            grimmlink_self:_updateSyncProgressPct(
                                idx, total, item.title, fmtProgress(bytes, total_bytes or bytes))
                        end
                        UIManager:scheduleIn(0.5, startNextDownload)
                    else
                        result.failed = result.failed + 1
                        local err = "Download " .. status .. " bookId=" .. tostring(item.book_id)
                        if exit_code then
                            if exit_code == 127 then
                                err = err .. " (curl/wget not found)"
                            else
                                err = err .. " (exit " .. tostring(exit_code) .. ")"
                            end
                        end
                        result.errors[#result.errors + 1] = err
                        logger.warn("GrimmLink:", err)
                        active_handle = nil
                        UIManager:scheduleIn(0.1, startNextDownload)
                    end
                end

                UIManager:scheduleIn(2, pollDownload)
            end)
        else
            -- === BLOCKING PATH: LuaSocket download with progress callback ===
            -- Works on all devices but UI freezes between progress updates.
            UIManager:nextTick(function()
                local book = item.book or {}
                local dl_opts = {
                    expected_size_kb = book.fileSizeKb,
                    downloaded_files_to_refresh = downloaded_files_to_refresh,
                    downloaded_files_to_refresh_set = downloaded_files_to_refresh_set,
                    on_progress = function(bytes_so_far, total_bytes_est)
                        if grimmlink_self._shelf_sync_cancelled then
                            return true  -- signal cancellation
                        end
                        if not silent then
                            grimmlink_self:_updateSyncProgressPct(
                                idx, total, item.title,
                                fmtProgress(bytes_so_far, total_bytes_est))
                        end
                    end,
                    is_cancelled = function()
                        return grimmlink_self._shelf_sync_cancelled
                    end,
                }
                local ok_dl, dl_err = pcall(function()
                    return grimmlink_self.shelf_sync:executeDownload(
                        item, plan.cleanup.shelf_id, plan.cleanup.sync_start, dl_opts)
                end)

                if grimmlink_self._shelf_sync_cancelled then
                    handleCancel()
                    return
                end

                if ok_dl and dl_err then
                    result.synced = result.synced + 1
                    if not silent then
                        local est = (book.fileSizeKb or 0) * 1024
                        grimmlink_self:_updateSyncProgressPct(
                            idx, total, item.title, fmtProgress(est, est))
                    end
                else
                    result.failed = result.failed + 1
                    local err = "Download failed bookId=" .. tostring(item.book_id)
                        .. ": " .. safeToString(dl_err)
                    result.errors[#result.errors + 1] = err
                    logger.warn("GrimmLink:", err)
                end
                UIManager:scheduleIn(0.1, startNextDownload)
            end)
        end
    end

    -- Kick off the first download.
    UIManager:scheduleIn(0.2, startNextDownload)

    -- Return nil because results come asynchronously.
    return nil
end

function Grimmlink:normalizeShelfList(shelves)
    local shelf_list = shelves
    if type(shelf_list) == "table" and type(shelf_list.content) == "table" then
        shelf_list = shelf_list.content
    elseif type(shelf_list) == "table" and type(shelf_list.items) == "table" then
        shelf_list = shelf_list.items
    end
    if type(shelf_list) ~= "table" then
        return {}
    end
    local normalized = {}
    for _, shelf in ipairs(shelf_list) do
        if type(shelf) == "table" then
            local shelf_type = normalizeShelfType(shelf.type or shelf.shelfType or shelf.shelf_type)
            local shelf_id = tonumber(shelf.id or shelf.shelfId or shelf.shelf_id)
            normalized[#normalized + 1] = {
                id = shelf_id,
                shelfId = shelf_id,
                name = shelf.name or shelf.title,
                title = shelf.title,
                type = shelf_type,
                shelfType = shelf_type,
                bookCount = shelf.bookCount or shelf.book_count or shelf.totalBooks or shelf.total_books,
                description = shelf.description,
            }
        end
    end
    return normalized
end

function Grimmlink:setShelfListCache(shelf_list)
    if type(shelf_list) ~= "table" then
        self._shelf_list_cache = nil
        self._shelf_list_cache_ts = nil
        return
    end
    self._shelf_list_cache = {}
    for idx, shelf in ipairs(shelf_list) do
        self._shelf_list_cache[idx] = shelf
    end
    self._shelf_list_cache_ts = os.time()
end

function Grimmlink:getCachedShelfList(max_age_seconds)
    local ttl = tonumber(max_age_seconds) or 90
    if ttl <= 0 then
        return nil, nil
    end
    if type(self._shelf_list_cache) ~= "table" or #self._shelf_list_cache == 0 then
        return nil, nil
    end
    if not self._shelf_list_cache_ts then
        return nil, nil
    end
    local age = os.time() - self._shelf_list_cache_ts
    if age < 0 or age > ttl then
        return nil, age
    end
    return self._shelf_list_cache, age
end

function Grimmlink:setShelfBooksCache(shelf_id, shelf_type, books)
    if not shelf_id or type(books) ~= "table" then
        return
    end
    self._shelf_books_cache = self._shelf_books_cache or {}
    local cache_key = normalizeShelfType(shelf_type) .. ":" .. tostring(shelf_id)
    self._shelf_books_cache[cache_key] = {
        ts = os.time(),
        books = books,
    }
end

function Grimmlink:getCachedShelfBooks(shelf_id, shelf_type, max_age_seconds)
    if not shelf_id then
        return nil, nil
    end
    local ttl = tonumber(max_age_seconds) or 15
    if ttl <= 0 then
        return nil, nil
    end
    local cache_map = self._shelf_books_cache
    if type(cache_map) ~= "table" then
        return nil, nil
    end
    local cache_key = normalizeShelfType(shelf_type) .. ":" .. tostring(shelf_id)
    local entry = cache_map[cache_key]
    -- Backward compatibility with very old cache key format (shelf-id only).
    -- IMPORTANT: only allow this fallback when shelf_type was not explicitly provided,
    -- otherwise regular/magic caches can bleed into each other for the same shelf id.
    local shelf_type_raw = shelf_type
    if type(shelf_type_raw) == "string" then
        shelf_type_raw = shelf_type_raw:gsub("^%s+", ""):gsub("%s+$", "")
    end
    if type(entry) ~= "table" and (shelf_type_raw == nil or shelf_type_raw == "") then
        entry = cache_map[tostring(shelf_id)]
    end
    if type(entry) ~= "table" or type(entry.books) ~= "table" or not entry.ts then
        return nil, nil
    end
    local age = os.time() - entry.ts
    if age < 0 or age > ttl then
        return nil, age
    end
    return entry.books, age
end

function Grimmlink:applyShelfSelection(shelf_id, shelf_name, shelf_type)
    local normalized_id = maybeNumber(shelf_id)
    local normalized_type = normalizeShelfType(shelf_type)
    if not normalized_id then
        return false
    end
    local name = safeToString(shelf_name)

    if normalized_type == "magic" then
        self:saveSetting("selected_magic_shelf_id", normalized_id)
        self:saveSetting("selected_magic_shelf_name", name)
        self:saveSetting("sync_magic_shelf_enabled", true)
    else
        self:saveSetting("selected_regular_shelf_id", normalized_id)
        self:saveSetting("selected_regular_shelf_name", name)
        self:saveSetting("sync_regular_shelf_enabled", true)
    end

    self:saveSetting("shelf_id", normalized_id)
    self:saveSetting("shelf_name", name)
    self:saveSetting("shelf_type", normalized_type)
    return true
end

function Grimmlink:showShelfPickerDialog(shelf_list, from_cache, cache_age_seconds, requested_type)
    if type(shelf_list) ~= "table" or #shelf_list == 0 then
        self:showMessage(_("No shelves available"), 3)
        return
    end

    local buttons = {}
    buttons[#buttons + 1] = {
        {
            text = _("Refresh shelf list"),
            callback = function()
                self:invokeSafely("refresh shelf picker", function()
                    if self._shelf_picker_dialog then
                        UIManager:close(self._shelf_picker_dialog)
                        self._shelf_picker_dialog = nil
                    end
                    self:showShelfPicker(true, requested_type)
                end)
            end,
        },
    }

    local grouped = { regular = {}, magic = {} }
    for _, shelf in ipairs(shelf_list) do
        local shelf_type = normalizeShelfType(shelf.type or shelf.shelfType or shelf.shelf_type)
        grouped[shelf_type][#grouped[shelf_type] + 1] = shelf
    end

    local function addHeader(text)
        buttons[#buttons + 1] = {
            {
                text = text,
                callback = function() end,
            },
        }
    end

    local function addShelfButton(shelf)
        local shelf_id = tonumber(shelf.id or shelf.shelfId or shelf.shelf_id)
        local shelf_type = normalizeShelfType(shelf.type or shelf.shelfType or shelf.shelf_type)
        local shelf_name = safeToString(shelf.name or shelf.title)
        if shelf_name == "" then
            shelf_name = shelf_id and ("Shelf #" .. tostring(shelf_id)) or _("Unnamed shelf")
        end
        local count_value = shelf.bookCount or shelf.book_count or shelf.totalBooks or shelf.total_books
        local count_str = count_value and (" (" .. tostring(count_value) .. ")") or ""
        local type_label = shelf_type == "magic" and _("[Magic] ") or _("[Regular] ")
        buttons[#buttons + 1] = {
            {
                text = type_label .. shelf_name .. count_str,
                callback = function()
                    self:invokeSafely("select shelf", function()
                        if not shelf_id then
                            self:showMessage(_("Invalid shelf ID from server"), 4)
                            return
                        end
                        self:applyShelfSelection(shelf_id, shelf_name, shelf_type)
                        if self._shelf_picker_dialog then
                            UIManager:close(self._shelf_picker_dialog)
                            self._shelf_picker_dialog = nil
                        end
                        self:showMessage(T(_("Shelf selected: %1"), shelf_name), 2)
                    end)
                end,
            },
        }
    end

    if #grouped.regular > 0 then
        addHeader(_("Regular Shelves"))
        for _, shelf in ipairs(grouped.regular) do
            addShelfButton(shelf)
        end
    end
    if #grouped.magic > 0 then
        addHeader(_("Magic Shelves"))
        for _, shelf in ipairs(grouped.magic) do
            addShelfButton(shelf)
        end
    end

    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function()
                self:invokeSafely("cancel shelf picker", function()
                    if self._shelf_picker_dialog then
                        UIManager:close(self._shelf_picker_dialog)
                        self._shelf_picker_dialog = nil
                    end
                end)
            end,
        },
    }

    local title = _("Select Shelf to Sync")
    if requested_type == "magic" then
        title = _("Select Magic Shelf to Sync")
    elseif requested_type == "regular" then
        title = _("Select Regular Shelf to Sync")
    end
    if from_cache then
        local age_value = tostring(math.max(0, math.floor(tonumber(cache_age_seconds) or 0)))
        title = T(_("%1 (cached %2s)"), title, age_value)
    end

    self._shelf_picker_dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(self._shelf_picker_dialog)
end

function Grimmlink:showShelfPicker(force_refresh, requested_type)
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
    if not force_refresh then
        local cached_list, cache_age = self:getCachedShelfList(90)
        if cached_list then
            self:showShelfPickerDialog(cached_list, true, cache_age, requested_type)
            return
        end
    end

    if not self:isOnline() then
        self:showMessage(_("No network connection"), 3)
        return
    end
    if not self:refreshApiClient() then
        self:showMessage(_("Connection not ready"), 3)
        return
    end

    self:showMessage(_("Fetching shelves from server..."), 2)
    local ok, shelves = self.api:getShelves(requested_type)
    if not ok then
        local cached_list, cache_age = self:getCachedShelfList(300)
        if cached_list then
            self:showMessage(_("Using cached shelf list (server not reachable)"), 3)
            self:showShelfPickerDialog(cached_list, true, cache_age, requested_type)
            return
        end
        self:showMessage(T(_("Failed to fetch shelves: %1"), safeToString(shelves)), 4)
        return
    end

    local shelf_list = self:normalizeShelfList(shelves)
    if type(shelf_list) ~= "table" or #shelf_list == 0 then
        self:showMessage(_("No shelves available"), 3)
        return
    end

    self:setShelfListCache(shelf_list)
    self:showShelfPickerDialog(shelf_list, false, nil, requested_type)
end

function Grimmlink:showShelfTypeChooser(title, on_select)
    local dialog
    local function choose(type_value)
        if dialog then
            UIManager:close(dialog)
        end
        if type(on_select) == "function" then
            on_select(type_value)
        end
    end
    dialog = ButtonDialog:new{
        title = title or _("Select Shelf Type"),
        buttons = {
            {
                {
                    text = _("regular"),
                    callback = function() choose("regular") end,
                },
                {
                    text = _("magic"),
                    callback = function() choose("magic") end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() choose(nil) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Grimmlink:validateShelfIdAndMaybeSave(shelf_id, shelf_type, save_on_success)
    local normalized_id = maybeNumber(shelf_id)
    local normalized_type = normalizeShelfType(shelf_type)
    if not normalized_id then
        self:showMessage(_("Invalid shelf ID"), 3)
        return
    end
    if not self:requireReady({ require_api = true }) then
        return
    end
    if not self:isOnline() then
        self:showMessage(_("No network connection"), 3)
        return
    end
    if not self:refreshApiClient() then
        self:showMessage(_("Connection not ready"), 3)
        return
    end

    self:showMessage(_("Validating shelf access..."), 2)
    local ok_books, books_or_err, code = self.api:getShelfBooks(normalized_id, normalized_type)
    if not ok_books then
        local numeric_code = tonumber(code)
        if numeric_code == 403 then
            self:showMessage(_("Shelf exists but is not accessible to this KOReader user"), 4)
        elseif numeric_code == 404 then
            self:showMessage(_("Shelf not found for this type or user"), 4)
        else
            self:showMessage(T(_("Shelf validation failed: %1"), safeToString(books_or_err)), 4)
        end
        return
    end

    local shelf_name = nil
    local ok_shelves, shelves = self.api:getShelves(normalized_type)
    if ok_shelves and type(shelves) == "table" then
        for _, shelf in ipairs(shelves) do
            if maybeNumber(shelf.id or shelf.shelfId or shelf.shelf_id) == normalized_id then
                shelf_name = safeToString(shelf.name or shelf.title)
                break
            end
        end
    end
    if not shelf_name or shelf_name == "" then
        shelf_name = T(_("Shelf #%1"), normalized_id)
    end

    if save_on_success then
        self:applyShelfSelection(normalized_id, shelf_name, normalized_type)
        self:showMessage(T(_("Shelf saved: %1 (%2)"), shelf_name, normalized_type), 3)
    else
        self:showMessage(T(_("Shelf is accessible: %1 (%2)\nBooks visible: %3"), shelf_name, normalized_type, #(books_or_err or {})), 4)
    end
end

function Grimmlink:promptAndValidateShelfId(save_on_success)
    local verb = save_on_success and _("Add Shelf by ID") or _("Validate Shelf ID")
    self:showShelfTypeChooser(verb, function(chosen_type)
        if not chosen_type then
            return
        end
        self:showNumberInput(_("Shelf ID"), self.shelf_id or 0, _("Enter shelf id"), function(value)
            local shelf_id = maybeNumber(value)
            if not shelf_id then
                self:showMessage(_("Invalid shelf ID"), 3)
                return
            end
            self:validateShelfIdAndMaybeSave(shelf_id, chosen_type, save_on_success == true)
        end)
    end)
end

function Grimmlink:getCurrentBookIdForManualStatus()
    local context = self:getCurrentDocumentContext()
    if context and context.book_id then
        return context.book_id
    end
    if self.current_session and self.current_session.book_id then
        return self.current_session.book_id
    end
    if context and context.file_hash and self.db and type(self.db.getBookByHash) == "function" then
        local cached = self.db:getBookByHash(context.file_hash)
        if cached and cached.book_id then
            return cached.book_id
        end
    end
    return nil
end

function Grimmlink:getReadStatusCapabilities(force_refresh)
    if not force_refresh and self._read_status_capabilities and self._read_status_capabilities_ts then
        local age = os.time() - self._read_status_capabilities_ts
        if age >= 0 and age <= READ_STATUS_CAPABILITY_CACHE_SECONDS then
            return self._read_status_capabilities
        end
    end

    if not self:isApiReady({ "getSupportedReadStatuses" }) then
        return nil
    end
    if not self:refreshApiClient() then
        return nil
    end

    local ok, statuses = self.api:getSupportedReadStatuses()
    if not ok or type(statuses) ~= "table" then
        return nil
    end

    local supported = {}
    for _, status_value in ipairs(statuses) do
        local normalized = normalizeManualReadStatus(status_value)
        if normalized then
            supported[normalized] = true
        end
    end

    self._read_status_capabilities = supported
    self._read_status_capabilities_ts = os.time()
    return supported
end

function Grimmlink:buildManualReadStatusActions()
    local supported = self:getReadStatusCapabilities(false)
    if type(supported) ~= "table" then
        return {}
    end

    local candidates = {
        { backend = "READING", label = _("Mark as Reading") },
        { backend = "READ", label = _("Mark as Read") },
        { backend = "UNREAD", label = _("Mark as Unread") },
        { backend = "PAUSED", label = _("Mark as On Hold") },
        { backend = "ABANDONED", label = _("Mark as Abandoned") },
        { backend = "RE_READING", label = _("Mark as Re-reading") },
    }

    local actions = {}
    for _, candidate in ipairs(candidates) do
        if supported[candidate.backend] then
            actions[#actions + 1] = candidate
        end
    end
    return actions
end

function Grimmlink:setManualReadStatusForCurrentBook(backend_status, label_text)
    local book_id = self:getCurrentBookIdForManualStatus()
    if not book_id then
        self:showMessage(_("No matched book ID for current document"), 4)
        return
    end
    if not self:isOnline() then
        self:showMessage(_("No network connection"), 3)
        return
    end
    if not self:isApiReady({ "updateBookReadStatus" }) or not self:refreshApiClient() then
        self:showMessage(_("Connection not ready"), 3)
        return
    end

    local ok, response_or_err = self.api:updateBookReadStatus(book_id, backend_status)
    if ok then
        self:showMessage(T(_("%1 completed"), label_text), 3)
    else
        self:showMessage(T(_("Failed to set read status: %1"), safeToString(response_or_err)), 4)
    end
end

function Grimmlink:showManualReadStatusMenu()
    local actions = self:buildManualReadStatusActions()
    if #actions == 0 then
        self:showMessage(_("Manual reading status is not supported by this backend"), 4)
        return
    end

    local buttons = {}
    for _, action in ipairs(actions) do
        buttons[#buttons + 1] = {
            {
                text = action.label,
                callback = function()
                    self:setManualReadStatusForCurrentBook(action.backend, action.label)
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function() end,
        },
    }

    UIManager:show(ButtonDialog:new{
        title = _("Manual Reading Status"),
        buttons = buttons,
    })
end

function Grimmlink:configureDownloadDir()
    self:showTextInput(
        _("Download Directory"),
        self.download_dir or "",
        _("Enter folder (leave empty to auto-create Book folder)"),
        false,
        function(value)
            self:saveSetting("download_dir", safeToString(value))
        end
    )
end

function Grimmlink:configureMagicDownloadDir()
    self:showTextInput(
        _("Magic Download Directory"),
        self.magic_download_dir or "",
        _("Used when separate magic directory is enabled"),
        false,
        function(value)
            self:saveSetting("magic_download_dir", safeToString(value))
        end
    )
end

function Grimmlink:showPdfBridgeStatus()
    self:showMessage(self:isPdfWebReaderBridgeEnabled() and _("PDF Web Reader Bridge enabled") or _("PDF Web Reader Bridge disabled"), 2)
end

function Grimmlink:resolveBookContextByPath(file_path)
    if not file_path or file_path == "" then
        return nil
    end
    local cached = self:resolveBookByFilePath(file_path)
    local file_hash = cached and cached.file_hash or nil
    if (not file_hash or file_hash == "") and type(self.calculateBookHash) == "function" then
        local ok_hash, hash = pcall(self.calculateBookHash, self, file_path)
        if ok_hash then
            file_hash = hash
        end
    end
    local book_id = cached and cached.book_id or nil
    local book_file_id = cached and cached.book_file_id or nil
    return {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
    }
end

function Grimmlink:syncThisBookFromPath(file_path)
    local context = self:resolveBookContextByPath(file_path)
    if not context then
        self:showMessage(_("No file selected"), 3)
        return
    end
    if not self:isTrackingEnabled(context.file_hash, context.file_path) then
        self:showTrackingDisabledMessage()
        return
    end

    if self.current_session and self.current_session.file_path == context.file_path then
        local snapshot = self:getCurrentProgressSnapshot(
            self.current_session.file_hash,
            self.current_session.file_path,
            self.current_session.book_id,
            self.current_session.book_file_id
        )
        self:pushProgressSnapshot(snapshot, "manual", false)
        if self:isPdfWebReaderBridgeEnabled() then
            self:pushPdfWebProgress(snapshot, "manual", true)
        end
        self:syncPendingNow(false, { progress_limit = 20, session_limit = 50 })
    else
        self:showMessage(_("Open the book to sync progress"), 3)
    end
end

function Grimmlink:pullRemoteProgressFromPath(file_path)
    if not self.current_session or self.current_session.file_path ~= file_path then
        self:showMessage(_("Open the book first to pull progress"), 3)
        return
    end
    if not self:isTrackingEnabled(self.current_session.file_hash, self.current_session.file_path) then
        self:showTrackingDisabledMessage()
        return
    end
    self:manualPullProgress()
end

function Grimmlink:toggleTrackingByPath(file_path)
    local context = self:resolveBookContextByPath(file_path)
    if not context then
        self:showMessage(_("No file selected"), 3)
        return
    end
    local toggled = self:toggleTracking(context.file_hash, context.file_path)
    if toggled == nil then
        self:showMessage(_("Failed to update tracking state"), 3)
        return
    end
    self:showMessage(toggled and _("Tracking enabled for this book") or _("Tracking disabled for this book"), 3)
end

function Grimmlink:matchBookByPath(file_path, options)
    options = options or {}
    local force_rematch = options.force == true
    local context = self:resolveBookContextByPath(file_path)
    if not context or not context.file_hash then
        self:showMessage(_("Could not calculate book hash"), 3)
        return
    end

    local cached = self.db and self.db:getBookByHash(context.file_hash) or nil
    if cached and cached.book_id and not force_rematch then
        self:showMessage(T(_("Book already matched: %1"), cached.book_id), 3)
        return
    end

    local remote_matched = nil
    if self:isOnline() and self:isApiReady({ "getBookByHash" }) and self:refreshApiClient() then
        local ok_lookup, book = self.api:getBookByHash(context.file_hash)
        if ok_lookup and type(book) == "table" and book.id then
            remote_matched = tonumber(book.id) or book.id
        end
    end

    if remote_matched then
        self.db:saveBookCache(file_path, context.file_hash, remote_matched, sanitizeTitle(file_path), nil)
        self:showMessage(force_rematch and T(_("Re-matched by hash: %1"), remote_matched) or T(_("Matched by hash: %1"), remote_matched), 3)
        return
    end

    self:showTextInput(_("Manual Book ID"), "", _("Enter Grimmory book id"), false, function(value)
        local manual_id = tonumber(value)
        if not manual_id then
            self:showMessage(_("Invalid book id"), 3)
            return
        end
        self.db:saveBookCache(file_path, context.file_hash, manual_id, sanitizeTitle(file_path), nil)
        self:showMessage(T(_("Book mapping saved: %1"), manual_id), 3)
    end)
end

function Grimmlink:showBookDebugInfoByPath(file_path)
    local context = self:resolveBookContextByPath(file_path)
    if not context then
        self:showMessage(_("No file selected"), 3)
        return
    end
    self:showMessage(self:buildDebugInfo(context), 8)
end

function Grimmlink:buildFileManagerActionItems(path_resolver)
    local resolve = path_resolver
    local function filePath()
        if type(resolve) == "function" then
            local ok, value = pcall(resolve)
            if ok and value and value ~= "" then
                return tostring(value)
            end
        end
        return nil
    end

    return {
        {
            text = _("GrimmLink: Sync This Book"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("No file selected"), 3)
                    return
                end
                self:syncThisBookFromPath(file_path)
            end,
        },
        {
            text = _("GrimmLink: Pull Remote Progress"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("Open the book first to pull progress"), 3)
                    return
                end
                self:pullRemoteProgressFromPath(file_path)
            end,
        },
        {
            text = _("GrimmLink: Toggle Tracking"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("No file selected"), 3)
                    return
                end
                self:toggleTrackingByPath(file_path)
            end,
        },
        {
            text = _("GrimmLink: Match Book"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("No file selected"), 3)
                    return
                end
                self:matchBookByPath(file_path)
            end,
        },
        {
            text = _("GrimmLink: Show Debug Info"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("No file selected"), 3)
                    return
                end
                self:showBookDebugInfoByPath(file_path)
            end,
        },
    }
end

function Grimmlink:registerFileManagerHoldActions()
    local function resolvePathFromValue(value)
        if type(value) == "string" and value ~= "" then
            return value
        end
        if type(value) == "table" then
            local candidates = {
                value.path,
                value.file,
                value.filepath,
                value.selected_file,
                value.selected_path,
            }
            for _, candidate in ipairs(candidates) do
                if candidate and candidate ~= "" then
                    return tostring(candidate)
                end
            end
        end
        return nil
    end

    local function registerViaFileDialogButtons()
        local fm = nil
        local fm_candidates = {
            self and self.ui,
            FileManager and FileManager.instance,
        }
        for _, candidate in ipairs(fm_candidates) do
            if type(candidate) == "table" and type(candidate.addFileDialogButtons) == "function" then
                fm = candidate
                break
            end
        end
        if not fm then
            return false
        end

        local function closeFileDialogSafe()
            local dialog = fm.file_dialog
            if dialog then
                pcall(function()
                    UIManager:close(dialog)
                end)
            end
        end

        local function wrapAction(action_item)
            if type(action_item) ~= "table" then
                return nil
            end
            return {
                text = action_item.text,
                callback = function()
                    closeFileDialogSafe()
                    if type(action_item.callback) == "function" then
                        action_item.callback()
                    end
                end,
            }
        end

        local function buildRows(file_path)
            local action_items = self:buildFileManagerActionItems(function()
                return file_path
            end)
            return {
                {}, -- separator between KOReader default actions and GrimmLink actions
                {
                    wrapAction(action_items[1]),
                    wrapAction(action_items[2]),
                    wrapAction(action_items[3]),
                },
                {
                    wrapAction(action_items[4]),
                    wrapAction(action_items[5]),
                },
            }
        end

        local function rowAt(index)
            return function(file, is_file, _book_props)
                if not is_file then
                    return nil
                end
                local file_path = resolvePathFromValue(file)
                if not file_path then
                    return nil
                end
                local rows = buildRows(file_path)
                return rows[index]
            end
        end

        local ok, err = pcall(function()
            fm:addFileDialogButtons("grimmlink_file_dialog_separator", rowAt(1))
            fm:addFileDialogButtons("grimmlink_file_dialog_primary", rowAt(2))
            fm:addFileDialogButtons("grimmlink_file_dialog_secondary", rowAt(3))
        end)
        if not ok then
            self:logWarn("GrimmLink: failed to register FileManager file-dialog actions:", tostring(err))
            return false
        end

        return true
    end

    if registerViaFileDialogButtons() then
        return true
    end

    local ok_fm_menu, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok_fm_menu or not FileManagerMenu then
        self:logDbg("GrimmLink: FileManager hold actions unavailable")
        return false
    end
    if FileManagerMenu.__grimmlink_hold_actions_patched then
        return true
    end

    local function resolvePathFromMenu(menu_self)
        local candidates = {
            menu_self and menu_self.selected_file,
            menu_self and menu_self.selected_path,
            menu_self and menu_self.file,
            menu_self and menu_self.filepath,
            menu_self and menu_self.path,
        }
        for _, value in ipairs(candidates) do
            local resolved = resolvePathFromValue(value)
            if resolved then
                return resolved
            end
        end
        return nil
    end

    local orig_set_update_item_table = FileManagerMenu.setUpdateItemTable
    FileManagerMenu.setUpdateItemTable = function(menu_self)
        if type(orig_set_update_item_table) == "function" then
            pcall(orig_set_update_item_table, menu_self)
        end
        if type(menu_self) ~= "table" then
            return
        end
        menu_self.pathhold_menu_table = menu_self.pathhold_menu_table or menu_self.hold_menu_table
        if type(menu_self.pathhold_menu_table) ~= "table" then
            return
        end
        local grimmlink_items = self:buildFileManagerActionItems(function()
            return resolvePathFromMenu(menu_self)
        end)
        for _, item in ipairs(grimmlink_items) do
            menu_self.pathhold_menu_table[#menu_self.pathhold_menu_table + 1] = item
        end
    end

    FileManagerMenu.__grimmlink_hold_actions_patched = true
    return true
end

function Grimmlink:registerDispatcherActions()
    if not Dispatcher or type(Dispatcher.registerAction) ~= "function" then
        return
    end
    pcall(function()
        Dispatcher:registerAction("GrimmLinkSyncPending", { title = "GrimmLink Sync Pending", category = "none" })
        Dispatcher:registerAction("GrimmLinkTestConnection", { title = "GrimmLink Test Connection", category = "none" })
        Dispatcher:registerAction("GrimmLinkSyncShelf", { title = "GrimmLink Sync Shelf", category = "none" })
    end)
end

function Grimmlink:onGrimmLinkSyncPending()
    self:syncPendingNow(false)
end

function Grimmlink:onGrimmLinkTestConnection()
    self:testConnection()
end

function Grimmlink:onGrimmLinkSyncShelf()
    self:runAfterUiSettles(function()
        self:syncShelfNow(false)
    end)
end

function Grimmlink:getNetworkStateLabel(current_ssid)
    if not current_ssid or current_ssid == "" then
        return "SSID unavailable"
    end
    return "Connected"
end

function Grimmlink:getActiveSourceLabel(active_source)
    local source = safeToString(active_source)
    if source == "local" then
        return _("Local")
    elseif source == "remote" then
        return _("Remote")
    elseif source == "fallback" then
        return _("Remote")
    end
    return _("Unknown")
end

function Grimmlink:getTargetDisplayLabel(active_source, tested_url)
    local source = safeToString(active_source)
    local nickname = ""
    if source == "local" then
        nickname = normalizeNickname(self.local_url_nickname)
    elseif source == "remote" or source == "fallback" then
        nickname = normalizeNickname(self.remote_url_nickname)
    end
    if nickname ~= "" then
        return nickname
    end
    return self:getActiveSourceLabel(source)
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

function Grimmlink:testConnection(diagnostics_mode)
    local show_diagnostics = diagnostics_mode == true
    if not self:requireReady({ require_api = true }) then
        return false
    end

    if not self:isOnline() then
        self:showMessage(_("No network connection"), 3)
        return false
    end

    if not self:refreshApiClient(true) then
        self:showMessage(_("Connection failed:\nAPI client not available"), 4)
        return false
    end

    local tested_url = safeToString(self.active_url or self.server_url):gsub("/$", "")
    local current_ssid = self.last_resolved_ssid or self:getCurrentSSID()
    local active_source = self.active_url_source or "unknown"
    local auth_timeout = 1.5
    if active_source == "remote" or active_source == "fallback" then
        auth_timeout = 0.8
    end
    local loading_widget = InfoMessage:new{
        text = _("Testing connection..."),
        timeout = 120,
    }
    UIManager:show(loading_widget)
    if UIManager and type(UIManager.forceRePaint) == "function" then
        pcall(UIManager.forceRePaint, UIManager)
    end
    local started_at = nowUtc()
    local saved_fallback_url = nil
    local fallback_temporarily_disabled = false
    if self.api and type(self.api.setFallbackUrl) == "function" then
        saved_fallback_url = safeToString(self.api.fallback_url)
        if saved_fallback_url ~= "" then
            self.api:setFallbackUrl(nil)
            fallback_temporarily_disabled = true
        end
    end
    local success, response, code, details = self.api:testAuth(auth_timeout)
    if fallback_temporarily_disabled and self.api and type(self.api.setFallbackUrl) == "function" then
        self.api:setFallbackUrl(saved_fallback_url)
    end
    pcall(UIManager.close, UIManager, loading_widget)
    local elapsed_seconds = math.max(0, nowUtc() - started_at)
    local used_fallback = details and details.used_fallback == true
    if used_fallback and details.used_url and details.used_url ~= "" then
        tested_url = details.used_url
        active_source = "fallback"
    end

    if success then
        self.last_connection_test_at = nowUtc()
        self.last_connection_test_result = "success"
        self.last_connection_error_category = nil
        self.last_connection_error_message_safe = nil
        local lines = {
            _("Connection Test"),
            _("Result: success"),
            T(_("Active server: %1"), self:getTargetDisplayLabel(active_source, tested_url)),
            T(_("Duration: %1s"), tostring(elapsed_seconds)),
        }
        if show_diagnostics then
            lines[#lines + 1] = T(_("Tested URL: %1"), formatUrlForDisplay(tested_url, 64))
            lines[#lines + 1] = T(_("Route source: %1"), safeToString(active_source))
            lines[#lines + 1] = T(_("Switch reason: %1"), safeToString(self.last_url_switch_reason))
        end
        if used_fallback then
            local cooldown_seconds = tonumber(self.local_fail_cooldown_seconds) or 60
            self._local_fail_cooldown_until = nowUtc() + cooldown_seconds
            self.active_url_source = "fallback"
            self.active_url = tested_url
            self.last_url_switch_at = nowUtc()
            self.last_url_switch_reason = "local_failed_remote_fallback"
            lines[#lines + 1] = _("Local URL failed. Tried Remote URL temporarily.")
            lines[#lines + 1] = _("Remote fallback succeeded.")
        elseif active_source == "remote" then
            lines[#lines + 1] = _("Using Remote URL.")
        end
        self:showMessage(table.concat(lines, "\n"), 6)
        return true
    end

    local diagnosed = self:diagnoseConnectionFailure(tested_url, response, code, current_ssid, active_source)
    if active_source == "local" and self.remote_url and self.remote_url ~= "" then
        local is_local_connectivity_issue = diagnosed.category == "timeout"
            or diagnosed.category == "connection_refused"
            or diagnosed.category == "host_unreachable"
            or diagnosed.category == "no_route_to_host"
            or diagnosed.category == "dns_failed"
        if is_local_connectivity_issue then
            local cooldown_seconds = tonumber(self.local_fail_cooldown_seconds) or 60
            self._local_fail_cooldown_until = nowUtc() + cooldown_seconds
        end
    end
    self.last_connection_test_at = nowUtc()
    self.last_connection_test_result = "failed"
    self.last_connection_error_category = diagnosed.category
    self.last_connection_error_message_safe = diagnosed.safe_error

    if diagnosed.category == "no_wifi" then
        self:showMessage(_("No network connection"), 3)
        return false
    end

    local lines = {
        _("Connection Test"),
        _("Result: failed"),
        T(_("Active server: %1"), self:getTargetDisplayLabel(active_source, tested_url)),
        T(_("Duration: %1s"), tostring(elapsed_seconds)),
    }
    if show_diagnostics then
        lines[#lines + 1] = T(_("Tested URL: %1"), formatUrlForDisplay(tested_url, 64))
        lines[#lines + 1] = T(_("Route source: %1"), safeToString(active_source))
        lines[#lines + 1] = T(_("Failure reason: %1"), diagnosed.category)
        lines[#lines + 1] = T(_("Details: %1"), diagnosed.safe_error)
        lines[#lines + 1] = T(_("Next suggestion: %1"), diagnosed.suggestion)
    else
        lines[#lines + 1] = T(_("Failure reason: %1"), diagnosed.category)
    end
    if details and details.fallback_attempted == true then
        lines[#lines + 1] = _("Local URL failed. Trying Remote URL temporarily.")
        if details.fallback_success ~= true then
            lines[#lines + 1] = _("Remote fallback failed.")
        end
    end
    self:showMessage(table.concat(lines, "\n"), 8)
    return false
end

-- ---------------------------------------------------------------------------
-- Dedicated menu-bar tab injection
-- ---------------------------------------------------------------------------
function Grimmlink:installSettingsTab()
    local function normalizeTabField(value)
        if type(value) ~= "string" then return "" end
        return value:lower():gsub("[%s_%-]+", "")
    end

    local function findInsertPos(tab_table)
        local tools_pos = nil
        for i, tab in ipairs(tab_table or {}) do
            local id   = normalizeTabField(tab.id)
            local name = normalizeTabField(tab.name)
            local icon = normalizeTabField(tab.icon)
            if id == "quicksettings" or name == "quicksettings" or icon == "quicksettings" then
                return i + 1
            end
            if id == "tools" or name == "tools" or icon == "appbar.tools" or icon == "appbartools" then
                tools_pos = i + 1
            end
        end
        return tools_pos or 1
    end

    local function installOnMenuClass(MenuClass, class_label)
        if type(MenuClass) ~= "table" then
            return false
        end

        MenuClass.__grimmlink_tab_plugin = self
        if MenuClass.__grimmlink_tab_patched then
            return true
        end
        MenuClass.__grimmlink_tab_patched = true

        local orig_set_update_item_table = MenuClass.setUpdateItemTable
        MenuClass.setUpdateItemTable = function(menu_self)
            if type(orig_set_update_item_table) == "function" then
                orig_set_update_item_table(menu_self)
            end

            local plugin_self = MenuClass.__grimmlink_tab_plugin
            if not plugin_self or plugin_self.settings_tab_enabled == false then
                return
            end
            if type(menu_self.tab_item_table) ~= "table" then
                return
            end

            for _, tab in ipairs(menu_self.tab_item_table) do
                if type(tab) == "table" and tab._grimmlink_settings_tab == true then
                    return
                end
            end

            local build_fn = plugin_self.buildTabItems
            if type(build_fn) ~= "function" then return end

            local ok_items, tab_items = pcall(build_fn, plugin_self)
            if not ok_items or type(tab_items) ~= "table" then
                if plugin_self.logWarn then
                    plugin_self:logWarn("GrimmLink: failed to build settings tab (" .. safeToString(class_label) .. ")", tostring(tab_items))
                end
                return
            end

            tab_items.icon = tab_items.icon or "appbar.navigation"
            tab_items.text = tab_items.text or _("GrimmLink")
            tab_items._grimmlink_settings_tab = true

            table.insert(menu_self.tab_item_table, findInsertPos(menu_self.tab_item_table), tab_items)
        end
        return true
    end

    local targets = {
        { label = "FileManagerMenu", modules = { "apps/filemanager/filemanagermenu" } },
        { label = "ReaderMenu", modules = { "apps/reader/modules/readermenu", "readermenu" } },
    }

    local installed_any = false
    for _, target in ipairs(targets) do
        local menu_class = nil
        for _, module_name in ipairs(target.modules or {}) do
            local ok_mod, mod = pcall(require, module_name)
            if ok_mod and type(mod) == "table" then
                menu_class = mod
                break
            end
        end
        if menu_class then
            installed_any = installOnMenuClass(menu_class, target.label) or installed_any
        else
            self:logDbg("GrimmLink: " .. safeToString(target.label) .. " unavailable; settings tab not installed for this menu")
        end
    end

    if not installed_any then
        self:logWarn("GrimmLink: no compatible menu class found for settings tab")
    end
    return installed_any
end

function Grimmlink:init()
    self.plugin_dir = detectPluginDir()

    -- Register menu as early as possible so Tools->GrimmLink can appear
    -- even if later module initialization fails.
    if not self:ensureMainMenuRegistered() then
        self:scheduleMenuRegistrationRetry()
    end

    self.db = Database and type(Database.new) == "function" and Database:new() or nil
    if self.db and type(self.db.init) == "function" then
        local ok, err = pcall(self.db.init, self.db)
        if not ok then
            self:logErr("GrimmLink database init error:", tostring(err))
        end
    else
        self:logErr("GrimmLink database module unavailable")
    end

    self.file_logger = FileLogger and FileLogger.new and FileLogger:new() or nil
    if self.file_logger and type(self.file_logger.init) == "function" then
        pcall(function()
            self.file_logger:init(self.plugin_dir)
        end)
    end

    self.api = APIClient and type(APIClient.new) == "function" and APIClient:new() or nil
    self.shelf_sync = ShelfSync and type(ShelfSync.new) == "function" and ShelfSync:new(self.db, self.api) or nil
    self.updater = Updater and type(Updater.new) == "function" and Updater:new() or nil

    self.enabled = self:readSetting("enabled", DEFAULTS.enabled)
    self.settings_tab_enabled = self:readSetting("settings_tab_enabled", DEFAULTS.settings_tab_enabled)
    self:installSettingsTab()
    self:registerFileManagerHoldActions()
    local legacy_auth_key = self.db and self.db:getPluginSetting("auth_key") or nil
    self.server_url = self:readSetting("server_url", DEFAULTS.server_url)
    self.remote_url = self:readSetting("remote_url", DEFAULTS.remote_url)
    self.local_url_nickname = normalizeNickname(self:readSetting("local_url_nickname", DEFAULTS.local_url_nickname))
    self.remote_url_nickname = normalizeNickname(self:readSetting("remote_url_nickname", DEFAULTS.remote_url_nickname))
    self.home_ssid = normalizeSsid(self:readSetting("home_ssid", DEFAULTS.home_ssid))
    self.username = self:readSetting("username", DEFAULTS.username)
    self.password = self:readSetting("password", legacy_auth_key or DEFAULTS.password)
    self.device_name = self:readSetting("device_name", self:defaultDeviceName())
    self.device_id = self:readSetting("device_id", self:defaultDeviceId())
    self.auto_pull_on_open = self:readSetting("auto_pull_on_open", DEFAULTS.auto_pull_on_open)
    self.auto_push_on_close = self:readSetting("auto_push_on_close", DEFAULTS.auto_push_on_close)
    self.offline_queue_enabled = self:readSetting("offline_queue_enabled", DEFAULTS.offline_queue_enabled)
    self.auto_sync_cooldown_seconds = DEFAULTS.auto_sync_cooldown_seconds
    self.ask_wifi_before_sync = self:readSetting("ask_wifi_before_sync", DEFAULTS.ask_wifi_before_sync)
    self.sync_on_network_connected = self:readSetting("sync_on_network_connected", DEFAULTS.sync_on_network_connected)
    self.network_sync_cooldown_seconds = self:readSetting("network_sync_cooldown_seconds", DEFAULTS.network_sync_cooldown_seconds)
    self.local_fail_cooldown_seconds = 60
    self.local_request_timeout_seconds = 2
    self.remote_request_timeout_seconds = 1
    self.resume_refresh_delay_seconds = 1.0
    self.resume_shelf_sync_delay_seconds = 4.0
    self.resume_network_grace_seconds = 12
    self._local_fail_cooldown_until = 0
    self.active_url = ""
    self.active_url_source = "unknown"
    self.last_url_switch_reason = ""
    self.last_url_switch_at = nil
    self.last_connection_error_category = nil
    self.last_connection_error_message_safe = nil
    self.last_connection_test_at = nil
    self.last_connection_test_result = nil
    self.debug_logging = self:readSetting("debug_logging", DEFAULTS.debug_logging)
    self.log_to_file = self:readSetting("log_to_file", DEFAULTS.log_to_file)
    self.threshold_percent = self:readSetting("threshold_percent", DEFAULTS.threshold_percent)
    self.send_reflowable_percentage = self:readSetting("send_reflowable_percentage", DEFAULTS.send_reflowable_percentage)
    if self.send_reflowable_percentage ~= true then
        self.send_reflowable_percentage = true
        if self.db then
            self.db:savePluginSetting("send_reflowable_percentage", true)
        end
    end
    self.threshold_minutes = self:readSetting("threshold_minutes", DEFAULTS.threshold_minutes)
    self.threshold_pages = self:readSetting("threshold_pages", DEFAULTS.threshold_pages)
    self.session_min_seconds = self:readSetting("session_min_seconds", DEFAULTS.session_min_seconds)
    self.shelf_sync_enabled = self:readSetting("shelf_sync_enabled", DEFAULTS.shelf_sync_enabled)
    self.shelf_id = self:readSetting("shelf_id", DEFAULTS.shelf_id)
    self.shelf_name = self:readSetting("shelf_name", DEFAULTS.shelf_name)
    self.shelf_type = normalizeShelfType(self:readSetting("shelf_type", DEFAULTS.shelf_type))
    self.download_dir = self:readSetting("download_dir", DEFAULTS.download_dir)
    self.sync_regular_shelf_enabled = self:readSetting("sync_regular_shelf_enabled", DEFAULTS.sync_regular_shelf_enabled)
    self.selected_regular_shelf_id = self:readSetting("selected_regular_shelf_id", DEFAULTS.selected_regular_shelf_id)
    self.selected_regular_shelf_name = self:readSetting("selected_regular_shelf_name", DEFAULTS.selected_regular_shelf_name)
    self.sync_magic_shelf_enabled = self:readSetting("sync_magic_shelf_enabled", DEFAULTS.sync_magic_shelf_enabled)
    self.selected_magic_shelf_id = self:readSetting("selected_magic_shelf_id", DEFAULTS.selected_magic_shelf_id)
    self.selected_magic_shelf_name = self:readSetting("selected_magic_shelf_name", DEFAULTS.selected_magic_shelf_name)
    self.use_separate_magic_download_dir = self:readSetting("use_separate_magic_download_dir", DEFAULTS.use_separate_magic_download_dir)
    self.magic_download_dir = self:readSetting("magic_download_dir", DEFAULTS.magic_download_dir)

    if self.shelf_id ~= nil and self.selected_regular_shelf_id == nil then
        self.selected_regular_shelf_id = self.shelf_id
        self.selected_regular_shelf_name = self.shelf_name
        self.sync_regular_shelf_enabled = self.shelf_sync_enabled == true
        self:saveSetting("selected_regular_shelf_id", self.selected_regular_shelf_id)
        self:saveSetting("selected_regular_shelf_name", self.selected_regular_shelf_name)
        self:saveSetting("sync_regular_shelf_enabled", self.sync_regular_shelf_enabled)
    end

    self.shelf_fast_sync_enabled = self:readSetting("shelf_fast_sync_enabled", DEFAULTS.shelf_fast_sync_enabled)
    self.shelf_fast_sync_cache_seconds = self:readSetting("shelf_fast_sync_cache_seconds", DEFAULTS.shelf_fast_sync_cache_seconds)
    self.auto_sync_shelf_on_resume = self:readSetting("auto_sync_shelf_on_resume", DEFAULTS.auto_sync_shelf_on_resume)
    self.two_way_shelf_delete_sync = self:readSetting("two_way_shelf_delete_sync", DEFAULTS.two_way_shelf_delete_sync)
    self.shelf_use_original_filename = self:readSetting("shelf_use_original_filename", DEFAULTS.shelf_use_original_filename)
    self.delete_sdr_on_book_delete = self:readSetting("delete_sdr_on_book_delete", DEFAULTS.delete_sdr_on_book_delete)
    self.refresh_bookinfo_after_shelf_sync = self:readSetting("refresh_bookinfo_after_shelf_sync", DEFAULTS.refresh_bookinfo_after_shelf_sync)
    self.refresh_bookinfo_batch_size = math.floor(tonumber(
        self:readSetting("refresh_bookinfo_batch_size", DEFAULTS.refresh_bookinfo_batch_size)
    ) or DEFAULTS.refresh_bookinfo_batch_size)
    if self.refresh_bookinfo_batch_size < 1 then
        self.refresh_bookinfo_batch_size = 1
    elseif self.refresh_bookinfo_batch_size > 200 then
        self.refresh_bookinfo_batch_size = 200
    end
    self.auto_update_enabled = self:readSetting("auto_update_enabled", DEFAULTS.auto_update_enabled)
    self.check_update_on_startup = self:readSetting("check_update_on_startup", DEFAULTS.check_update_on_startup)
    self.update_channel = normalizeUpdateChannel(self:readSetting("update_channel", DEFAULTS.update_channel))
    self.update_repo = self:readSetting("update_repo", DEFAULTS.update_repo)
    self.allow_prerelease_updates = self:readSetting("allow_prerelease_updates", DEFAULTS.allow_prerelease_updates)
    self.pdf_web_reader_bridge_enabled = self:readSetting("pdf_web_reader_bridge_enabled", DEFAULTS.pdf_web_reader_bridge_enabled)
    self.metadata_sync_enabled = self:readSetting("metadata_sync_enabled", DEFAULTS.metadata_sync_enabled)
    self.rating_sync_enabled = self:readSetting("rating_sync_enabled", DEFAULTS.rating_sync_enabled)
    self.annotations_sync_enabled = self:readSetting("annotations_sync_enabled", DEFAULTS.annotations_sync_enabled)
    self.bookmarks_sync_enabled = self:readSetting("bookmarks_sync_enabled", DEFAULTS.bookmarks_sync_enabled)
    self.metadata_retry_max = self:readSetting("metadata_retry_max", DEFAULTS.metadata_retry_max)

    self:refreshApiClient()
    if self.updater and type(self.updater.init) == "function" then
        self.updater:init(self.plugin_dir, self.db, {
            allow_prerelease = self.allow_prerelease_updates,
            update_repo = self.update_repo,
        })
    end
    if self.updater and type(self.updater.setAllowPrerelease) == "function" then
        self.updater:setAllowPrerelease(self.allow_prerelease_updates)
    end
    self:registerDispatcherActions()
    self:maybeCheckForUpdatesOnStartup()
    return true
end

function Grimmlink:onReaderReady()
    self:ensureMainMenuRegistered()
    if not self.enabled or not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end
    self:runAfterUiSettles(function()
        self:startSession()
    end)
end

function Grimmlink:onCloseDocument()
    self:invokeSafely("close document", function()
        self:endSession({ reason = "close" })
    end, {}, { silent = true })
end

function Grimmlink:onSuspend()
    self:invokeSafely("suspend document", function()
        self:endSession({ reason = "suspend" })
    end, {}, { silent = true })
end

function Grimmlink:onResume()
    self:ensureMainMenuRegistered()
    self._last_resume_at = nowUtc()

    local run_resume_network_tasks = function()
        self:refreshApiClient(true)
        if self:isOnline() and self.sync_on_network_connected == true then
            self:schedulePendingSync("resume pending sync", 0.75, {
                progress_limit = 10,
                session_limit = 25,
                respect_cooldown = true,
                cooldown_seconds = tonumber(self.network_sync_cooldown_seconds) or DEFAULTS.network_sync_cooldown_seconds,
            })
        end
    end

    if UIManager and type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(tonumber(self.resume_refresh_delay_seconds) or 1.0, run_resume_network_tasks)
    else
        run_resume_network_tasks()
    end

    if self.auto_sync_shelf_on_resume then
        local run_shelf_sync = function()
            if self:isOnline() then
                self:syncShelfNow(true)
            end
        end
        if UIManager and type(UIManager.scheduleIn) == "function" then
            UIManager:scheduleIn(tonumber(self.resume_shelf_sync_delay_seconds) or 4.0, run_shelf_sync)
        else
            run_shelf_sync()
        end
    end
end

function Grimmlink:onNetworkConnected()
    local grace_seconds = tonumber(self.resume_network_grace_seconds) or 12
    if self._last_resume_at and grace_seconds > 0 and (nowUtc() - self._last_resume_at) < grace_seconds then
        return
    end
    self:refreshApiClient(true)
    if self.sync_on_network_connected == true then
        self:schedulePendingSync("network connected pending sync", 0.75, {
            progress_limit = 10,
            session_limit = 25,
            respect_cooldown = true,
            cooldown_seconds = tonumber(self.network_sync_cooldown_seconds) or DEFAULTS.network_sync_cooldown_seconds,
        })
    end
end

function Grimmlink:onExit()
    self:endSession({ reason = "exit" })
end

function Grimmlink:showConnectionMenu(touchmenu_instance)
    local items = {
        {
            text = _("Setup"),
            callback = function()
                self:configureConnection()
            end,
        },
        {
            text = _("Advanced"),
            callback = function()
                local advanced_items = {
                    {
                        text = _("Server URL"),
                        callback = function()
                            self:configureServerUrl()
                        end,
                    },
                    {
                        text = _("Username"),
                        callback = function()
                            self:configureUsername()
                        end,
                    },
                    {
                        text = _("Password"),
                        callback = function()
                            self:configurePassword()
                        end,
                    },
                }
                UIManager:show(ButtonDialog:new{
                    title = _("Connection Advanced"),
                    buttons = { advanced_items },
                })
            end,
        },
        {
            text = _("Test Connection"),
            callback = function()
                self:testConnection(false)
            end,
        },
        {
            text = _("Test Connection with Diagnostics"),
            callback = function()
                self:testConnection(true)
            end,
        },
    }
    UIManager:show(ButtonDialog:new{
        title = _("Connection"),
        buttons = { items },
    })
    self:refreshTouchMenu(touchmenu_instance)
end

function Grimmlink:addToMainMenu(menu_items)
    local status_items = {
        {
            text = _("Show About"),
            callback = function()
                self:showAbout()
            end,
        },
        {
            text = _("Export GrimmLink Debug Info"),
            callback = function()
                self:exportDebugInfo()
            end,
        },
        {
            text = _("Sync Summary"),
            callback = function()
                if not self.db then
                    self:showMessage(_("Database not available"), 3)
                    return
                end
                self:showMessage(T(
                    _("Pending progress: %1\nPending sessions: %2\nPending metadata: %3"),
                    self.db:getPendingProgressCount(),
                    self.db:getPendingSessionCount(),
                    safeDbValueCall(self.db, "getPendingMetadataCount", 0)
                ), 3)
            end,
        },
    }
    if #_gl_load_errors > 0 then
        status_items[#status_items + 1] = {
            text = _("Load Errors"),
            callback = function()
                self:showMessage(table.concat(_gl_load_errors, "\n"), 8)
            end,
        }
    end

    menu_items.grimmlink = {
        text = _("GrimmLink"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enable GrimmLink"),
                keep_menu_open = true,
                checked_func = function() return self.enabled end,
                callback = function()
                    self.enabled = not self.enabled
                    self:saveSetting("enabled", self.enabled)
                end,
            },
            {
                text = _("Connection"),
                sub_item_table = {
                    { text = _("Setup Connection"), callback = function() self:configureConnection() end },
                    { text = _("Local URL"), callback = function() self:configureServerUrl() end },
                    { text = _("Remote URL"), callback = function() self:configureRemoteUrl() end },
                    { text = _("Username"), callback = function() self:configureUsername() end },
                    { text = _("Password"), callback = function() self:configurePassword() end },
                    { text = _("Test Connection"), keep_menu_open = true, callback = function() self:testConnection(false) end },
                    { text = _("Test Connection with Diagnostics"), keep_menu_open = true, callback = function() self:testConnection(true) end },
                },
            },
            {
                text = _("Sync Progress Now"),
                callback = function() self:syncPendingNow(false) end,
            },
            {
                text = _("Sync Shelf Now"),
                callback = function() self:syncShelfNow(false) end,
            },
            {
                text = _("Sync Metadata Now"),
                callback = function()
                    local context = self:getCurrentDocumentContext()
                    if context and not self:isTrackingEnabledForContext(context) then
                        self:showTrackingDisabledMessage()
                        return
                    end
                    self:extractAndQueueCurrentMetadata("manual-metadata-sync", context)
                    self:syncPendingMetadata(false)
                end,
            },
            {
                separator = true,
                text = _("Pull Remote Progress"),
                enabled_func = function()
                    return self.current_session ~= nil
                        and self.current_session.book_id ~= nil
                end,
                callback = function() self:manualPullProgress() end,
            },
            {
                text = _("Manual Reading Status"),
                callback = function()
                    self:showManualReadStatusMenu()
                end,
            },
            {
                text = _("Toggle Tracking (Current Book)"),
                callback = function()
                    local context = self:getCurrentDocumentContext()
                    if not context then
                        self:showMessage(_("No file selected"), 3)
                        return
                    end
                    self:toggleTrackingByPath(context.file_path)
                end,
            },
            {
                separator = true,
                text = _("Advanced Setting"),
                sub_item_table = {
                    {
                        text = _("Shelf Sync Settings"),
                        sub_item_table = {
                            {
                                text = _("Enable Shelf Sync"),
                                keep_menu_open = true,
                                checked_func = function() return self.shelf_sync_enabled end,
                                callback = function()
                                    self.shelf_sync_enabled = not self.shelf_sync_enabled
                                    self:saveSetting("shelf_sync_enabled", self.shelf_sync_enabled)
                                end,
                            },
                            {
                                text_func = function()
                                    local regular_name = self.selected_regular_shelf_name and self.selected_regular_shelf_name ~= "" and self.selected_regular_shelf_name or _("(none)")
                                    return T(_("Select Regular Shelf: %1"), regular_name)
                                end,
                                callback = function() self:showShelfPicker(false, "regular") end,
                            },
                            {
                                text_func = function()
                                    local magic_name = self.selected_magic_shelf_name and self.selected_magic_shelf_name ~= "" and self.selected_magic_shelf_name or _("(none)")
                                    return T(_("Select Magic Shelf: %1"), magic_name)
                                end,
                                callback = function() self:showShelfPicker(false, "magic") end,
                            },
                            {
                                text = _("Enable Regular Shelf Sync"),
                                keep_menu_open = true,
                                checked_func = function() return self.sync_regular_shelf_enabled == true end,
                                callback = function()
                                    self.sync_regular_shelf_enabled = not (self.sync_regular_shelf_enabled == true)
                                    self:saveSetting("sync_regular_shelf_enabled", self.sync_regular_shelf_enabled)
                                end,
                            },
                            {
                                text = _("Enable Magic Shelf Sync"),
                                keep_menu_open = true,
                                checked_func = function() return self.sync_magic_shelf_enabled == true end,
                                callback = function()
                                    self.sync_magic_shelf_enabled = not (self.sync_magic_shelf_enabled == true)
                                    self:saveSetting("sync_magic_shelf_enabled", self.sync_magic_shelf_enabled)
                                end,
                            },
                            {
                                text = _("Download Settings"),
                                sub_item_table = {
                                    {
                                        text_func = function()
                                            local dir = self.download_dir and self.download_dir ~= "" and self.download_dir or _("(auto)")
                                            return T(_("Download Directory: %1"), dir)
                                        end,
                                        callback = function() self:configureDownloadDir() end,
                                    },
                                    {
                                        text = _("Original Filenames"),
                                        keep_menu_open = true,
                                        checked_func = function() return self.shelf_use_original_filename end,
                                        callback = function()
                                            self.shelf_use_original_filename = not self.shelf_use_original_filename
                                            self:saveSetting("shelf_use_original_filename", self.shelf_use_original_filename)
                                        end,
                                    },
                                    {
                                        text = _("Use Separate Magic Directory"),
                                        keep_menu_open = true,
                                        checked_func = function() return self.use_separate_magic_download_dir == true end,
                                        callback = function()
                                            self.use_separate_magic_download_dir = not (self.use_separate_magic_download_dir == true)
                                            self:saveSetting("use_separate_magic_download_dir", self.use_separate_magic_download_dir)
                                        end,
                                    },
                                    {
                                        text_func = function()
                                            local dir = self.magic_download_dir and self.magic_download_dir ~= "" and self.magic_download_dir or _("(same as regular)")
                                            return T(_("Magic Download Directory: %1"), dir)
                                        end,
                                        callback = function()
                                            self:configureMagicDownloadDir()
                                        end,
                                    },
                                },
                            },
                            {
                                text = _("Sync Behavior"),
                                sub_item_table = {
                                    {
                                        text = _("Auto-sync on Resume"),
                                        keep_menu_open = true,
                                        checked_func = function() return self.auto_sync_shelf_on_resume end,
                                        callback = function()
                                            self.auto_sync_shelf_on_resume = not self.auto_sync_shelf_on_resume
                                            self:saveSetting("auto_sync_shelf_on_resume", self.auto_sync_shelf_on_resume)
                                        end,
                                    },
                                    {
                                        text = _("Fast Sync (Short Cache)"),
                                        keep_menu_open = true,
                                        checked_func = function() return self.shelf_fast_sync_enabled end,
                                        callback = function()
                                            self.shelf_fast_sync_enabled = not self.shelf_fast_sync_enabled
                                            self:saveSetting("shelf_fast_sync_enabled", self.shelf_fast_sync_enabled)
                                        end,
                                    },
                                    {
                                        text_func = function()
                                            return T(_("Cache Duration: %1s"), tonumber(self.shelf_fast_sync_cache_seconds) or 15)
                                        end,
                                        callback = function()
                                            self:showNumberInput(_("Fast Sync Cache Seconds"), self.shelf_fast_sync_cache_seconds or 15, _("Recommended: 10-30"), function(value)
                                                local normalized = math.floor(tonumber(value) or 15)
                                                if normalized < 0 then normalized = 0 end
                                                if normalized > 120 then normalized = 120 end
                                                self:saveSetting("shelf_fast_sync_cache_seconds", normalized)
                                            end)
                                        end,
                                    },
                                    {
                                        text = _("Two-way Delete Sync"),
                                        keep_menu_open = true,
                                        checked_func = function() return self.two_way_shelf_delete_sync end,
                                        callback = function()
                                            self.two_way_shelf_delete_sync = not self.two_way_shelf_delete_sync
                                            self:saveSetting("two_way_shelf_delete_sync", self.two_way_shelf_delete_sync)
                                        end,
                                    },
                                    {
                                        text = _("Delete .sdr on Remove"),
                                        keep_menu_open = true,
                                        checked_func = function() return self.delete_sdr_on_book_delete end,
                                        callback = function()
                                            self.delete_sdr_on_book_delete = not self.delete_sdr_on_book_delete
                                            self:saveSetting("delete_sdr_on_book_delete", self.delete_sdr_on_book_delete)
                                        end,
                                    },
                                    {
                                        text = _("Refresh Book Info After Download"),
                                        keep_menu_open = true,
                                        checked_func = function() return self.refresh_bookinfo_after_shelf_sync ~= false end,
                                        callback = function()
                                            self.refresh_bookinfo_after_shelf_sync = not (self.refresh_bookinfo_after_shelf_sync ~= false)
                                            self:saveSetting("refresh_bookinfo_after_shelf_sync", self.refresh_bookinfo_after_shelf_sync)
                                        end,
                                    },
                                    {
                                        text_func = function()
                                            return T(
                                                _("Book Info Refresh Batch Size: %1"),
                                                tonumber(self.refresh_bookinfo_batch_size) or DEFAULTS.refresh_bookinfo_batch_size
                                            )
                                        end,
                                        callback = function()
                                            self:showNumberInput(
                                                _("Refresh Batch Size"),
                                                self.refresh_bookinfo_batch_size or DEFAULTS.refresh_bookinfo_batch_size,
                                                _("Recommended: 10-40"),
                                                function(value)
                                                    local normalized = math.floor(
                                                        tonumber(value) or DEFAULTS.refresh_bookinfo_batch_size
                                                    )
                                                    if normalized < 1 then normalized = 1 end
                                                    if normalized > 200 then normalized = 200 end
                                                    self:saveSetting("refresh_bookinfo_batch_size", normalized)
                                                end
                                            )
                                        end,
                                    },
                                },
                            },
                            {
                                text = _("Shelf ID Tools"),
                                sub_item_table = {
                                    {
                                        text = _("Add Shelf by ID"),
                                        callback = function()
                                            self:promptAndValidateShelfId(true)
                                        end,
                                    },
                                    {
                                        text = _("Validate Shelf ID"),
                                        callback = function()
                                            self:promptAndValidateShelfId(false)
                                        end,
                                    },
                                    {
                                        text = _("Set Legacy Shelf ID"),
                                        callback = function()
                                            self:showNumberInput(_("Shelf ID"), self.shelf_id or 0, _("Enter shelf id"), function(value)
                                                self:saveSetting("shelf_id", value)
                                                self:saveSetting("shelf_name", "")
                                                self:saveSetting("shelf_type", "regular")
                                                self:saveSetting("selected_regular_shelf_id", value)
                                                self:saveSetting("selected_regular_shelf_name", "")
                                            end)
                                        end,
                                    },
                                },
                            },
                        },
                    },
                    {
                        text = _("Tracking & Network"),
                        sub_item_table = {
                            {
                                text = _("Ask Wi-Fi Before Manual Sync"),
                                keep_menu_open = true,
                                checked_func = function() return self.ask_wifi_before_sync == true end,
                                callback = function()
                                    self.ask_wifi_before_sync = not (self.ask_wifi_before_sync == true)
                                    self:saveSetting("ask_wifi_before_sync", self.ask_wifi_before_sync)
                                end,
                            },
                            {
                                text = _("Sync on Network Resume"),
                                keep_menu_open = true,
                                checked_func = function() return self.sync_on_network_connected == true end,
                                callback = function()
                                    self.sync_on_network_connected = not (self.sync_on_network_connected == true)
                                    self:saveSetting("sync_on_network_connected", self.sync_on_network_connected)
                                end,
                            },
                            {
                                text_func = function()
                                    return T(_("Network Sync Cooldown: %1s"), tonumber(self.network_sync_cooldown_seconds) or DEFAULTS.network_sync_cooldown_seconds)
                                end,
                                callback = function()
                                    self:showNumberInput(_("Network Sync Cooldown (seconds)"), self.network_sync_cooldown_seconds or DEFAULTS.network_sync_cooldown_seconds, _("Recommended: 300"), function(value)
                                        local normalized = math.floor(tonumber(value) or DEFAULTS.network_sync_cooldown_seconds)
                                        if normalized < 0 then normalized = 0 end
                                        if normalized > 86400 then normalized = 86400 end
                                        self:saveSetting("network_sync_cooldown_seconds", normalized)
                                    end)
                                end,
                            },
                        },
                    },
                    {
                        text = _("Metadata Sync"),
                        sub_item_table = {
                            {
                                text = _("Enable Metadata Sync"),
                                keep_menu_open = true,
                                checked_func = function() return self.metadata_sync_enabled == true end,
                                callback = function()
                                    self.metadata_sync_enabled = not (self.metadata_sync_enabled == true)
                                    self:saveSetting("metadata_sync_enabled", self.metadata_sync_enabled)
                                end,
                            },
                            {
                                text = _("Sync Rating"),
                                keep_menu_open = true,
                                checked_func = function() return self.rating_sync_enabled == true end,
                                callback = function()
                                    self.rating_sync_enabled = not (self.rating_sync_enabled == true)
                                    self:saveSetting("rating_sync_enabled", self.rating_sync_enabled)
                                end,
                            },
                            {
                                text = _("Sync Highlights / Notes"),
                                keep_menu_open = true,
                                checked_func = function() return self.annotations_sync_enabled == true end,
                                callback = function()
                                    self.annotations_sync_enabled = not (self.annotations_sync_enabled == true)
                                    self:saveSetting("annotations_sync_enabled", self.annotations_sync_enabled)
                                end,
                            },
                            {
                                text = _("Sync Bookmarks"),
                                keep_menu_open = true,
                                checked_func = function() return self.bookmarks_sync_enabled == true end,
                                callback = function()
                                    self.bookmarks_sync_enabled = not (self.bookmarks_sync_enabled == true)
                                    self:saveSetting("bookmarks_sync_enabled", self.bookmarks_sync_enabled)
                                end,
                            },
                            {
                                text = _("Preview Metadata"),
                                callback = function() self:showMetadataPreview() end,
                            },
                            {
                                text_func = function()
                                    return T(_("Pending Metadata Count: %1"), safeDbValueCall(self.db, "getPendingMetadataCount", 0))
                                end,
                                keep_menu_open = true,
                                callback = function() end,
                            },
                        },
                    },
                    {
                        text = _("PDF Web Reader Bridge"),
                        sub_item_table = {
                            {
                                text = _("Enable PDF Bridge"),
                                keep_menu_open = true,
                                checked_func = function() return self.pdf_web_reader_bridge_enabled end,
                                callback = function()
                                    self.pdf_web_reader_bridge_enabled = not self.pdf_web_reader_bridge_enabled
                                    self:saveSetting("pdf_web_reader_bridge_enabled", self.pdf_web_reader_bridge_enabled)
                                end,
                            },
                            {
                                text = _("Sync PDF Bridge Now"),
                                enabled_func = function()
                                    return self.current_session and self.current_session.book_id ~= nil and self:isPdfWebReaderBridgeEnabled()
                                end,
                                callback = function() self:syncPdfWebProgress(false) end,
                            },
                            {
                                text = _("PDF Bridge Status"),
                                keep_menu_open = true,
                                callback = function() self:showPdfBridgeStatus() end,
                            },
                        },
                    },
                    {
                        text = _("Auto Update"),
                        sub_item_table = {
                            {
                                text = _("Enable Auto Update"),
                                keep_menu_open = true,
                                checked_func = function() return self.auto_update_enabled end,
                                callback = function()
                                    self.auto_update_enabled = not self.auto_update_enabled
                                    self:saveSetting("auto_update_enabled", self.auto_update_enabled)
                                end,
                            },
                            {
                                text = _("Check on Startup"),
                                keep_menu_open = true,
                                checked_func = function() return self.check_update_on_startup end,
                                callback = function()
                                    self.check_update_on_startup = not self.check_update_on_startup
                                    self:saveSetting("check_update_on_startup", self.check_update_on_startup)
                                end,
                            },
                            {
                                text = _("Update Channel"),
                                callback = function()
                                    self:showTextInput(_("Update Channel"), self.update_channel, _("stable or prerelease"), false, function(value)
                                        self:saveSetting("update_channel", normalizeUpdateChannel(value))
                                    end)
                                end,
                            },
                            {
                                text = _("Check for Updates Now"),
                                callback = function() self:checkForUpdates(false) end,
                            },
                        },
                    },
                    {
                        text = _("Maintenance"),
                        sub_item_table = {
                            {
                                text = _("Quick Cleanup"),
                                callback = function() self:runQuickCleanupWithConfirm() end,
                            },
                            {
                                text = _("Clear Sync Queues"),
                                callback = function() self:clearSyncQueuesWithConfirm() end,
                            },
                            {
                                text = _("Clear Logs"),
                                callback = function() self:clearLogsWithConfirm() end,
                            },
                            {
                                text = _("Export GrimmLink Debug Info"),
                                callback = function() self:exportDebugInfo() end,
                            },
                            {
                                text = _("Show DB Status / Pending Counts"),
                                callback = function() self:showDatabaseStatus() end,
                            },
                            {
                                text = _("Rebuild metadata queue for current book"),
                                callback = function() self:rebuildMetadataQueueForCurrentBook() end,
                            },
                            {
                                text = _("Force resync metadata for current book"),
                                callback = function() self:forceMetadataResyncForCurrentBook() end,
                            },
                            {
                                text = _("Re-match current book"),
                                callback = function() self:rematchCurrentBook() end,
                            },
                            {
                                text = _("Rebuild SimpleUI metadata cache"),
                                callback = function()
                                    if not self.shelf_sync or not self.download_dir then
                                        self:showMessage(_("Shelf sync not configured."), 3)
                                        return
                                    end
                                    local counts = self.shelf_sync:rebuildBookInfoCacheFromIndex(
                                        self.shelf_sync:resolveDownloadDir(self.download_dir))
                                    if counts.error then
                                        self:showMessage(T(_("Rebuild failed: %1"), counts.error), 4)
                                    else
                                        self:showMessage(T(
                                            _("Rebuild complete\nInserted: %1  Updated: %2  Skipped: %3"),
                                            counts.inserted, counts.updated, counts.skipped), 5)
                                    end
                                end,
                            },
                            {
                                text = _("Advanced Cleanup"),
                                sub_item_table = {
                                    { text = _("Clear Update Cache"), callback = function() self:clearUpdateCacheWithConfirm() end },
                                    { text = _("Clear Unmatched Book Cache"), callback = function() self:clearUnmatchedBookCacheWithConfirm() end },
                                    { text = _("Clear All Book Cache"), callback = function() self:clearAllBookCacheWithConfirm() end },
                                    { text = _("Clear Not Found Hashes"), callback = function() self:clearNotFoundHashesWithConfirm() end },
                                    { text = _("Clear Pending Progress"), callback = function() self:clearPendingProgressQueueWithConfirm() end },
                                    { text = _("Clear Pending Sessions"), callback = function() self:clearPendingSessionsQueueWithConfirm() end },
                                    { text = _("Clear Pending Metadata"), callback = function() self:clearPendingMetadataQueueWithConfirm() end },
                                    { text = _("Clear Synced Metadata History"), callback = function() self:clearSyncedMetadataHistoryWithConfirm() end },
                                    { text = _("Clear Shelf Tombstones"), callback = function() self:clearShelfTombstonesWithConfirm() end },
                                    { text = _("Clear Pending Shelf Removals"), callback = function() self:clearPendingShelfRemovalsWithConfirm() end },
                                },
                            },
                        },
                    },
                    {
                        text = _("Settings Tab"),
                        help_text = _("Show or hide the dedicated GrimmLink tab in the menu bar.\nWhen hidden, GrimmLink settings remain accessible via Tools > GrimmLink.\nTakes effect after a restart."),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings_tab_enabled
                        end,
                        callback = function()
                            local on = self.settings_tab_enabled
                            self.settings_tab_enabled = not on
                            self:saveSetting("settings_tab_enabled", self.settings_tab_enabled)
                            UIManager:show(ConfirmBox:new{
                                text = T(
                                    _("The GrimmLink settings tab will be %1 after restart.\n\nRestart now?"),
                                    on and _("hidden") or _("shown")
                                ),
                                ok_text     = _("Restart"),
                                cancel_text = _("Later"),
                                ok_callback = function()
                                    if self.db and type(self.db.flush) == "function" then
                                        pcall(self.db.flush, self.db)
                                    end
                                    UIManager:restartKOReader()
                                end,
                            })
                        end,
                    },
                },
            },
            {
                text = _("Status / About"),
                sub_item_table = status_items,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Dedicated settings tab support
-- ---------------------------------------------------------------------------
-- buildTabItems() reuses addToMainMenu() to produce the tab's item list.
-- A menu-tab injector can call this when settings_tab_enabled is true.
function Grimmlink:buildTabItems()
    if self._tab_item_cache then
        return self._tab_item_cache
    end
    local fake_items = {}
    self:addToMainMenu(fake_items)
    local entry = fake_items.grimmlink
    self._tab_item_cache = entry and entry.sub_item_table or {}
    return self._tab_item_cache
end

function Grimmlink:clearTabItemsCache()
    self._tab_item_cache = nil
end

function Grimmlink:onTeardown()
    self:clearTabItemsCache()
end

return Grimmlink


