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

local Database   = _glRequire("grimmlink_database")
local APIClient  = _glRequire("grimmlink_api_client")
local FileLogger = _glRequire("grimmlink_file_logger")
local ShelfSync  = _glRequire("grimmlink_shelf_sync")
local Updater    = _glRequire("grimmlink_updater")

local _ = require("gettext")
local T = ffiutil.template
local unpack_values = table.unpack or unpack

local Grimmlink = WidgetContainer:extend{
    name = "grimmlink",
    is_doc_only = false,
}

local DEFAULTS = {
    enabled = true,
    server_url = "",
    remote_url = "",
    home_ssid = "",
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
    shelf_sync_enabled = false,
    shelf_id = nil,
    shelf_name = "",
    download_dir = "",
    shelf_fast_sync_enabled = true,
    shelf_fast_sync_cache_seconds = 15,
    auto_sync_shelf_on_resume = false,
    two_way_shelf_delete_sync = false,
    shelf_use_original_filename = true,
    delete_sdr_on_book_delete = false,
    auto_update_enabled = false,
    check_update_on_startup = false,
    update_channel = "stable",
    update_repo = "0xstillb/grimmlink",
    allow_prerelease_updates = false,
    pdf_web_reader_bridge_enabled = false,
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
    if require_api and not self.api then
        return false
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

function Grimmlink:resolveServerUrl()
    if self.home_ssid == "" or self.remote_url == "" then
        return self.server_url
    end
    local ok, nw = pcall(function() return NetworkMgr:getCurrentNetwork() end)
    if ok and nw and nw.ssid == self.home_ssid then
        return self.server_url
    end
    return self.remote_url
end

function Grimmlink:refreshApiClient()
    if self.api and type(self.api.init) == "function" then
        local primary = self:resolveServerUrl()
        self.api:init(primary, self.username, self.password, self.debug_logging)
        -- Set fallback: if primary is local, fallback is remote; and vice versa
        if self.remote_url ~= "" and self.server_url ~= "" then
            local fallback = (primary == self.server_url) and self.remote_url or self.server_url
            self.api:setFallbackUrl(fallback)
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
        if key == "server_url" or key == "username" or key == "password" or key == "debug_logging" then
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
    self:showTextInput(_("Local URL (home network)"), self.server_url, "http://192.168.1.100:6060", false, function(value)
        local normalized = safeToString(value):gsub("/$", "")
        self:saveSetting("server_url", normalized)
        self:refreshApiClient()
        self:showMessage(_("Local URL saved"), 2)
    end)
end

function Grimmlink:configureRemoteUrl()
    self:showTextInput(_("Remote URL (external)"), self.remote_url, "https://grimmory.example.com", false, function(value)
        local normalized = safeToString(value):gsub("/$", "")
        self:saveSetting("remote_url", normalized)
        self:refreshApiClient()
        self:showMessage(_("Remote URL saved"), 2)
    end)
end

function Grimmlink:configureHomeSSID()
    local current_ssid = ""
    pcall(function()
        local nw = NetworkMgr:getCurrentNetwork()
        if nw and nw.ssid then current_ssid = nw.ssid end
    end)
    local hint = current_ssid ~= "" and T(_("Current: %1"), current_ssid) or _("Enter home WiFi name")
    self:showTextInput(_("Home SSID"), self.home_ssid, hint, false, function(value)
        self:saveSetting("home_ssid", safeToString(value))
        self:refreshApiClient()
        self:showMessage(_("Home SSID saved"), 2)
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
        password = self.password or "",
    }

    self:showTextInput(_("Local URL (home network)"), pending.server_url, "http://192.168.1.100:6060", false, function(server_url)
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

function Grimmlink:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local current_page, total_pages = self:getCurrentPageInfo()
    local document = self.ui and self.ui.document or nil
    local file_format = self:getBookType(file_path)
    local raw_location = nil

    if document then
        local position = safeMethodCall(document, "getCurrentPos")
        local xpointer = safeMethodCall(document, "getXPointer")
        if file_format == "PDF" and current_page then
            raw_location = tostring(current_page)
        else
            raw_location = position or xpointer
            if raw_location == nil then
                raw_location = safeMethodCall(document, "getCurrentLocation")
            end
            if raw_location == nil then
                raw_location = xpointer or position
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

    local target_page = self:getRemotePageTarget(remote_snapshot)
    local file_format = remote_snapshot.fileFormat and tostring(remote_snapshot.fileFormat):upper() or nil
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
            self:showMessage(_("Failed to jump to remote position"), 4)
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
    return {
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
    if not self:isPdfWebReaderBridgeEnabled() then
        return false
    end
    if snapshot.fileFormat ~= "PDF" then
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

function Grimmlink:syncPendingProgress(silent)
    local synced = 0
    local failed = 0
    if not self.db then
        return synced, failed
    end
    if not self:isOnline() then
        return synced, failed
    end

    if not self:refreshApiClient() then
        return synced, failed
    end
    local pending = self.db:getPendingProgress(100)
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

    if not self:refreshApiClient() then
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
    if not self:isOnline() then
        return
    end

    if not self:refreshApiClient() then
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
        remote_snapshot.document = remote_snapshot.document or file_hash
        remote_snapshot.file_path = file_path
        remote_snapshot.source = remote_snapshot.source or remote_snapshot.device or "KOReader"
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

function Grimmlink:maybePullPdfWebProgress(file_hash, file_path, book_id, book_file_id, silent)
    if not self.db or not self:isPdfWebReaderBridgeEnabled() or not file_hash or file_hash == "" or not book_id then
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

    if not self:refreshApiClient() then
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
    }

    local function doNetworkSync()
        -- Clear handle first so this task is not reused across sessions.
        self._scheduled_session_open_sync = nil
        if not self.current_session or self.current_session.file_hash ~= file_hash then
            return
        end
        self:invokeSafely("session open sync", function()
            self:maybePullRemoteProgress(file_hash, file_path, book_id, book_file_id, true)
            self:maybePullPdfWebProgress(file_hash, file_path, book_id, book_file_id, true)
            if self:isOnline() then
                self:syncPendingNow(true)
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
    self.current_session = nil

    if not self:requireReady({ require_api = true, silent = true }) then
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

    if session_valid then
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

    local should_push = self:shouldPushProgress(end_snapshot, state, options.reason or "close")
    if should_push and self.auto_push_on_close then
        self:pushProgressSnapshot(end_snapshot, options.reason or "close", true)
        self:pushPdfWebProgress(end_snapshot, options.reason or "close", true)
    end

    if self:isOnline() then
        self:runAfterUiSettles(function()
            self:invokeSafely("session close sync", function()
                self:syncPendingNow(true)
            end, {}, { silent = true })
        end)
    end
    return true
end

function Grimmlink:syncPendingSessions(silent)
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

    if not self:refreshApiClient() then
        return synced, failed
    end
    local pending = self.db:getPendingSessions(500)
    if #pending == 0 then
        return synced, failed
    end

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

    local groups = {}
    for _, session in ipairs(pending) do
        if not session.bookId then
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

function Grimmlink:syncPendingNow(silent)
    if not self:requireReady({ require_api = true, silent = silent }) then
        return
    end

    local progress_synced, progress_failed = self:syncPendingProgress(true)
    local sessions_synced, sessions_failed = self:syncPendingSessions(true)

    if not silent then
        self:showMessage(T(
            _("GrimmLink sync complete\nProgress: %1 synced, %2 failed\nSessions: %3 synced, %4 failed"),
            progress_synced,
            progress_failed,
            sessions_synced,
            sessions_failed
        ), 4)
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
    self:showMessage(_("Update installed. Restart KOReader to finish."), 4)
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

function Grimmlink:clearSyncQueuesWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local progress_count = type(self.db.getPendingProgressCount) == "function" and self.db:getPendingProgressCount() or 0
    local session_count = type(self.db.getPendingSessionCount) == "function" and self.db:getPendingSessionCount() or 0
    local total = (progress_count or 0) + (session_count or 0)
    if total <= 0 then
        self:showMessage(_("No pending sync queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear sync queues?\nProgress: %1\nSessions: %2"), progress_count, session_count),
        _("Clear Queues"),
        function()
            local progress_ok = true
            local sessions_ok = true

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

            local ok_all = progress_ok and sessions_ok
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
    local progress_count = type(self.db.getPendingProgressCount) == "function" and self.db:getPendingProgressCount() or 0
    local session_count = type(self.db.getPendingSessionCount) == "function" and self.db:getPendingSessionCount() or 0
    local can_clear_update_cache = self.updater and type(self.updater.clearCache) == "function"

    self:showConfirmAction(
        T(
            _("Run quick cleanup?\n- Clear update cache: %1\n- Clear unmatched book cache: %2\n- Clear pending progress queue: %3\n- Clear pending session queue: %4"),
            can_clear_update_cache and _("yes") or _("no"),
            unmatched_count,
            progress_count,
            session_count
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

    if result.cancelled then
        lines[#lines + 1] = _("Shelf Sync Cancelled")
    else
        lines[#lines + 1] = _("Shelf Sync Complete")
    end
    lines[#lines + 1] = "---------------------------"

    if total == 0 and not result.cancelled then
        lines[#lines + 1] = _("Everything is up to date.")
    else
        local items = {}
        if synced > 0 then items[#items + 1] = { _("Downloaded"), synced } end
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
    local ev = Event:new("GrimmLinkShelfSyncComplete", {
        synced              = result.synced or 0,
        deleted             = result.deleted or 0,
        skipped             = result.skipped or 0,
        download_dir        = self.download_dir,
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

function Grimmlink:syncShelfNow(silent)
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
    if not self.shelf_id then
        if not silent then
            self:showMessage(_("No shelf selected. Go to Shelf Sync -> Select Shelf."), 3)
        end
        return nil
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
        self:showShelfSyncMessage(T(_("Syncing shelf: %1..."), self.shelf_name or tostring(self.shelf_id)), 2)
    end

    local remote_delete_sync = self.two_way_shelf_delete_sync
    local preloaded_remote_books = nil
    local cached_books_age = nil
    if self.shelf_fast_sync_enabled and not remote_delete_sync then
        preloaded_remote_books, cached_books_age = self:getCachedShelfBooks(self.shelf_id, self.shelf_fast_sync_cache_seconds or 15)
        if preloaded_remote_books and not silent then
            self:showShelfSyncMessage(T(_("Fast Sync: using cached shelf data (%1s old)"), math.max(0, math.floor(tonumber(cached_books_age) or 0))), 2)
        end
    end

    -- Phase 1: Plan (classify books — fast, no large I/O).
    local ok_plan, plan_or_err = pcall(function()
        return self.shelf_sync:prepareSyncPlan({
            shelf_id = self.shelf_id,
            download_dir = self.download_dir,
            use_original_filename = self.shelf_use_original_filename,
            remote_delete_sync = remote_delete_sync,
            delete_sdr = self.delete_sdr_on_book_delete,
            preloaded_remote_books = preloaded_remote_books,
            on_progress = function(msg)
                if not silent then self:showShelfSyncMessage(safeToString(msg), 2) end
            end,
            on_fetched_remote_books = function(remote_books)
                if self.shelf_fast_sync_enabled and type(remote_books) == "table" then
                    self:setShelfBooksCache(self.shelf_id, remote_books)
                end
            end,
        })
    end)
    if not ok_plan then
        self._shelf_sync_running = false
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
        local resolved_dir = self.shelf_sync:resolveDownloadDir(self.download_dir)
        local index_path
        pcall(function()
            index_path = self.shelf_sync:writeMetadataIndex(self.shelf_id, resolved_dir)
        end)
        pcall(function()
            self.shelf_sync:upsertBookInfoCache(self.shelf_id)
        end)
        result.metadata_index_path = index_path
        self._shelf_sync_running = false
        if not silent then
            self:_showSyncCompletionSummary(result)
        end
        self:_broadcastSyncResult(result)
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
        local resolved_dir = grimmlink_self.shelf_sync:resolveDownloadDir(grimmlink_self.download_dir)
        local index_path
        pcall(function()
            index_path = grimmlink_self.shelf_sync:writeMetadataIndex(
                grimmlink_self.shelf_id, resolved_dir)
        end)
        pcall(function()
            grimmlink_self.shelf_sync:upsertBookInfoCache(grimmlink_self.shelf_id)
        end)
        result.metadata_index_path = index_path
        grimmlink_self._shelf_sync_running = false
        if not silent then
            grimmlink_self:_showSyncCompletionSummary(result)
        end
        grimmlink_self:_broadcastSyncResult(result)
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
        if not silent then
            grimmlink_self:_showSyncCompletionSummary(result)
        end
        grimmlink_self:_broadcastSyncResult(result)
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
                            item, plan.cleanup.shelf_id, plan.cleanup.sync_start)
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
    return shelf_list
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

function Grimmlink:setShelfBooksCache(shelf_id, books)
    if not shelf_id or type(books) ~= "table" then
        return
    end
    self._shelf_books_cache = self._shelf_books_cache or {}
    self._shelf_books_cache[tostring(shelf_id)] = {
        ts = os.time(),
        books = books,
    }
end

function Grimmlink:getCachedShelfBooks(shelf_id, max_age_seconds)
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
    local entry = cache_map[tostring(shelf_id)]
    if type(entry) ~= "table" or type(entry.books) ~= "table" or not entry.ts then
        return nil, nil
    end
    local age = os.time() - entry.ts
    if age < 0 or age > ttl then
        return nil, age
    end
    return entry.books, age
end

function Grimmlink:showShelfPickerDialog(shelf_list, from_cache, cache_age_seconds)
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
                    self:showShelfPicker(true)
                end)
            end,
        },
    }
    for _, shelf in ipairs(shelf_list) do
        local shelf_id = tonumber(shelf.id or shelf.shelfId or shelf.shelf_id)
        local shelf_name = safeToString(shelf.name or shelf.title)
        if shelf_name == "" then
            shelf_name = shelf_id and ("Shelf #" .. tostring(shelf_id)) or _("Unnamed shelf")
        end
        local count_value = shelf.bookCount or shelf.book_count or shelf.totalBooks or shelf.total_books
        local count_str = count_value and (" (" .. tostring(count_value) .. ")") or ""
        buttons[#buttons + 1] = {
            {
                text = shelf_name .. count_str,
                callback = function()
                    self:invokeSafely("select shelf", function()
                        if not shelf_id then
                            self:showMessage(_("Invalid shelf ID from server"), 4)
                            return
                        end
                        self:saveSetting("shelf_id", shelf_id)
                        self:saveSetting("shelf_name", shelf_name)
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
    if from_cache then
        local age_value = tostring(math.max(0, math.floor(tonumber(cache_age_seconds) or 0)))
        title = T(_("Select Shelf to Sync (cached %1s)"), age_value)
    end

    self._shelf_picker_dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(self._shelf_picker_dialog)
end

function Grimmlink:showShelfPicker(force_refresh)
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
            self:showShelfPickerDialog(cached_list, true, cache_age)
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
    local ok, shelves = self.api:getShelves()
    if not ok then
        local cached_list, cache_age = self:getCachedShelfList(300)
        if cached_list then
            self:showMessage(_("Using cached shelf list (server not reachable)"), 3)
            self:showShelfPickerDialog(cached_list, true, cache_age)
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
    self:showShelfPickerDialog(shelf_list, false, nil)
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

function Grimmlink:showPdfBridgeStatus()
    self:showMessage(self:isPdfWebReaderBridgeEnabled() and _("PDF Web Reader Bridge enabled") or _("PDF Web Reader Bridge disabled"), 2)
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

function Grimmlink:registerSimpleUIAction()
    local ok, QA = pcall(require, "sui_quickactions")
    if not ok or not QA or type(QA.register) ~= "function" then
        return
    end
    local icon_path = self.plugin_dir .. "/icons/sync.svg"
    local grimmlink = self
    pcall(function()
        QA.register({
            id = "grimmlink_sync",
            label = _("GrimmLink"),
            icon = icon_path,
            is_in_place = true,
            execute = function(ctx)
                if grimmlink.shelf_sync_enabled and grimmlink.shelf_id then
                    grimmlink:runAfterUiSettles(function()
                        grimmlink:syncShelfNow(false)
                    end)
                else
                    grimmlink:syncPendingNow(false)
                end
            end,
        })
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

function Grimmlink:testConnection()
    if not self:requireReady({ require_api = true }) then
        return false
    end

    if not self:refreshApiClient() then
        self:showMessage(_("Connection failed:\nAPI client not available"), 4)
        return false
    end
    local success, response = self.api:testAuth()
    if success then
        local used_url = self.api.server_url or ""
        local mode = (used_url == self.server_url) and _("local") or _("remote")
        self:showMessage(T(_("Connection successful (%1)\n%2"), mode, used_url), 3)
        return true
    end

    local used_url = self.api.server_url or ""
    self:showMessage(T(_("Connection failed:\n%1\n\nURL: %2"), safeToString(response), used_url), 4)
    return false
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
    local legacy_auth_key = self.db and self.db:getPluginSetting("auth_key") or nil
    self.server_url = self:readSetting("server_url", DEFAULTS.server_url)
    self.remote_url = self:readSetting("remote_url", DEFAULTS.remote_url)
    self.home_ssid = self:readSetting("home_ssid", DEFAULTS.home_ssid)
    self.username = self:readSetting("username", DEFAULTS.username)
    self.password = self:readSetting("password", legacy_auth_key or DEFAULTS.password)
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
    self.shelf_sync_enabled = self:readSetting("shelf_sync_enabled", DEFAULTS.shelf_sync_enabled)
    self.shelf_id = self:readSetting("shelf_id", DEFAULTS.shelf_id)
    self.shelf_name = self:readSetting("shelf_name", DEFAULTS.shelf_name)
    self.download_dir = self:readSetting("download_dir", DEFAULTS.download_dir)
    self.shelf_fast_sync_enabled = self:readSetting("shelf_fast_sync_enabled", DEFAULTS.shelf_fast_sync_enabled)
    self.shelf_fast_sync_cache_seconds = self:readSetting("shelf_fast_sync_cache_seconds", DEFAULTS.shelf_fast_sync_cache_seconds)
    self.auto_sync_shelf_on_resume = self:readSetting("auto_sync_shelf_on_resume", DEFAULTS.auto_sync_shelf_on_resume)
    self.two_way_shelf_delete_sync = self:readSetting("two_way_shelf_delete_sync", DEFAULTS.two_way_shelf_delete_sync)
    self.shelf_use_original_filename = self:readSetting("shelf_use_original_filename", DEFAULTS.shelf_use_original_filename)
    self.delete_sdr_on_book_delete = self:readSetting("delete_sdr_on_book_delete", DEFAULTS.delete_sdr_on_book_delete)
    self.auto_update_enabled = self:readSetting("auto_update_enabled", DEFAULTS.auto_update_enabled)
    self.check_update_on_startup = self:readSetting("check_update_on_startup", DEFAULTS.check_update_on_startup)
    self.update_channel = normalizeUpdateChannel(self:readSetting("update_channel", DEFAULTS.update_channel))
    self.update_repo = self:readSetting("update_repo", DEFAULTS.update_repo)
    self.allow_prerelease_updates = self:readSetting("allow_prerelease_updates", DEFAULTS.allow_prerelease_updates)
    self.pdf_web_reader_bridge_enabled = self:readSetting("pdf_web_reader_bridge_enabled", DEFAULTS.pdf_web_reader_bridge_enabled)

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
    self:registerSimpleUIAction()
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
    self:refreshApiClient()
    if self:isOnline() then
        self:syncPendingNow(true)
    end
    if self.auto_sync_shelf_on_resume then
        self:syncShelfNow(true)
    end
end

function Grimmlink:onExit()
    self:endSession({ reason = "exit" })
    self:syncPendingNow(true)
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
                self:testConnection()
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
            text = _("Sync Summary"),
            callback = function()
                if not self.db then
                    self:showMessage(_("Database not available"), 3)
                    return
                end
                self:showMessage(T(_("Pending progress: %1\nPending sessions: %2"), self.db:getPendingProgressCount(), self.db:getPendingSessionCount()), 3)
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
                separator = true,
                text = _("Shelf Sync"),
                sub_item_table = {
                    {
                        text = _("Sync Now"),
                        callback = function() self:syncShelfNow(false) end,
                    },
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
                            local name = self.shelf_name and self.shelf_name ~= "" and self.shelf_name or _("(none)")
                            return T(_("Select Shelf: %1"), name)
                        end,
                        callback = function() self:showShelfPicker() end,
                    },
                    {
                        separator = true,
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
                        },
                    },
                    {
                        text = _("Rebuild SimpleUI metadata cache"),
                        keep_menu_open = true,
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
                },
            },
            {
                text = _("Sync Progress Now"),
                callback = function() self:syncPendingNow(false) end,
            },
            {
                separator = true,
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Connection"),
                        sub_item_table = {
                            { text = _("Setup Connection"), callback = function() self:configureConnection() end },
                            { text = _("Local URL"), callback = function() self:configureServerUrl() end },
                            { text = _("Remote URL"), callback = function() self:configureRemoteUrl() end },
                            { text = _("Home SSID"), callback = function() self:configureHomeSSID() end },
                            { text = _("Username"), callback = function() self:configureUsername() end },
                            { text = _("Password"), callback = function() self:configurePassword() end },
                            { text = _("Test Connection"), keep_menu_open = true, callback = function() self:testConnection() end },
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
                        text = _("Shelf ID (Advanced)"),
                        callback = function()
                            self:showNumberInput(_("Shelf ID"), self.shelf_id or 0, _("Enter shelf id"), function(value)
                                self:saveSetting("shelf_id", value)
                                self:saveSetting("shelf_name", "")
                            end)
                        end,
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
                                text = _("Advanced Cleanup"),
                                sub_item_table = {
                                    { text = _("Clear Update Cache"), callback = function() self:clearUpdateCacheWithConfirm() end },
                                    { text = _("Clear Unmatched Book Cache"), callback = function() self:clearUnmatchedBookCacheWithConfirm() end },
                                    { text = _("Clear All Book Cache"), callback = function() self:clearAllBookCacheWithConfirm() end },
                                    { text = _("Clear Not Found Hashes"), callback = function() self:clearNotFoundHashesWithConfirm() end },
                                    { text = _("Clear Pending Progress"), callback = function() self:clearPendingProgressQueueWithConfirm() end },
                                    { text = _("Clear Pending Sessions"), callback = function() self:clearPendingSessionsQueueWithConfirm() end },
                                },
                            },
                        },
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

return Grimmlink


