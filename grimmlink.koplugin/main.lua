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

local Database = require("grimmlink_database")
local APIClient = require("grimmlink_api_client")
local FileLogger = require("grimmlink_file_logger")

local _ = require("gettext")
local T = ffiutil.template

local Grimmlink = WidgetContainer:extend{
    name = "grimmlink",
    is_doc_only = false,
}

local DEFAULTS = {
    enabled = true,
    server_url = "",
    username = "",
    auth_key = "",
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

function Grimmlink:init()
    self.db = Database:new()
    if not self.db:init() then
        UIManager:show(InfoMessage:new{
            text = _("Failed to initialize GrimmLink database"),
            timeout = 4,
        })
        return
    end

    self.enabled = self:readSetting("enabled", DEFAULTS.enabled)
    self.server_url = self:readSetting("server_url", DEFAULTS.server_url)
    self.username = self:readSetting("username", DEFAULTS.username)
    self.auth_key = self:readSetting("auth_key", DEFAULTS.auth_key)
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
        self.file_logger = FileLogger:new()
        if not self.file_logger:init() then
            self.file_logger = nil
        end
    end

    self.api = APIClient:new()
    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)

    self.current_session = nil
    self.last_auto_sync_time = 0
    self.last_sync_summary = nil

    self:logInfo("GrimmLink initialized")

    if self.ui and self.ui.menu and type(self.ui.menu.registerToMainMenu) == "function" then
        self.ui.menu:registerToMainMenu(self)
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
    self.db:savePluginSetting(key, value)
    self[key] = value

    if key == "server_url" or key == "username" or key == "auth_key" or key == "debug_logging" then
        self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    end

    if key == "log_to_file" then
        if value and not self.file_logger then
            self.file_logger = FileLogger:new()
            if not self.file_logger:init() then
                self.file_logger = nil
            end
        elseif not value then
            self.file_logger = nil
        end
    end
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

function Grimmlink:configureAuthKey()
    self:showTextInput(_("Auth Key / Password Hash"), self.auth_key, _("Enter x-auth-key value"), true, function(value)
        self:saveSetting("auth_key", safeToString(value))
        self:showMessage(_("Auth key saved"), 2)
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
        raw_location = safeMethodCall(document, "getCurrentPos")
        if raw_location == nil then
            raw_location = safeMethodCall(document, "getCurrentLocation")
        end
        if raw_location == nil then
            raw_location = safeMethodCall(document, "getXPointer")
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

    local local_changed = previous_local and self:progressDifferenceExceeded(local_snapshot, previous_local)
        or self:hasMeaningfulProgress(local_snapshot)
    local remote_changed = previous_remote and self:progressDifferenceExceeded(remote_snapshot, previous_remote)
        or self:hasMeaningfulProgress(remote_snapshot)

    local remote_is_significantly_different = self:progressDifferenceExceeded(local_snapshot, remote_snapshot)
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

function Grimmlink:jumpToPage(page_number)
    local page = tonumber(page_number)
    if not page then
        return false
    end

    local candidates = {
        { self.ui and self.ui.paging, "gotoPage" },
        { self.ui and self.ui.paging, "goToPage" },
        { self.ui and self.ui.document, "gotoPage" },
        { self.ui and self.ui.document, "goToPage" },
    }

    for _, candidate in ipairs(candidates) do
        local result, ok = safeMethodCall(candidate[1], candidate[2], page)
        if ok and result ~= false then
            return true
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

function Grimmlink:applyRemoteProgress(remote_snapshot)
    if not remote_snapshot then
        return false
    end

    if isNonEmpty(remote_snapshot.location) and self:jumpToLocation(remote_snapshot.location) then
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

function Grimmlink:resolveRemoteChoice(file_hash, remote_snapshot)
    local jumped = self:applyRemoteProgress(remote_snapshot)
    if jumped then
        remote_snapshot.timestamp = nowUtc()
        self:rememberLocalSnapshot(file_hash, remote_snapshot, "conflict-use-remote")
        self:showMessage(_("Jumped to remote progress"), 2)
    else
        self:showMessage(_("Remote progress found, but safe jump was not possible"), 4)
        self:rememberRemoteSnapshot(file_hash, remote_snapshot, "remote-jump-unsafe")
    end
end

function Grimmlink:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, mode)
    local dialog
    dialog = ButtonDialog:new{
        title = self:buildConflictDialogText(local_snapshot, remote_snapshot),
        buttons = {
            {
                {
                    text = _("Use Local"),
                    callback = function()
                        UIManager:close(dialog)
                        self:logInfo("GrimmLink conflict decision: Use Local")
                        self:resolveLocalChoice(file_hash, local_snapshot, true)
                    end,
                },
                {
                    text = _("Use Remote"),
                    callback = function()
                        UIManager:close(dialog)
                        self:logInfo("GrimmLink conflict decision: Use Remote")
                        self:resolveRemoteChoice(file_hash, remote_snapshot)
                    end,
                },
                {
                    text = _("Ignore"),
                    callback = function()
                        UIManager:close(dialog)
                        self:logInfo("GrimmLink conflict decision: Ignore")
                        self:rememberRemoteSnapshot(file_hash, remote_snapshot, mode == "remote_newer" and "remote-ignored" or "conflict-ignored")
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

    local ok, encoded = pcall(json.encode, self:prepareProgressPayload(snapshot))
    if not ok then
        self:logErr("GrimmLink failed to encode pending progress payload")
        return false
    end
    self.db:upsertPendingProgress(snapshot.bookHash, encoded)
    self:logInfo("GrimmLink queued progress for hash", snapshot.bookHash)
    return true
end

function Grimmlink:pushProgressSnapshot(snapshot, reason, silent)
    if not snapshot or not snapshot.bookHash then
        return false
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)

    if not self:isOnline() then
        self:queueProgressSnapshot(snapshot)
        if not silent then
            self:showMessage(_("Saved progress to offline queue"), 2)
        end
        return false
    end

    local success, response = self.api:updateProgress(self:prepareProgressPayload(snapshot))
    if success then
        self:rememberLocalSnapshot(snapshot.bookHash, snapshot, reason or "progress-push")
        self:rememberRemoteSnapshot(snapshot.bookHash, snapshot, reason or "progress-push")
        self.db:setProgressLastAction(snapshot.bookHash, reason or "progress-push")
        self:logInfo("GrimmLink pushed progress for hash", snapshot.bookHash)
        return true
    end

    self:logWarn("GrimmLink progress push failed:", response)
    self:queueProgressSnapshot(snapshot)
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

    for _, item in ipairs(pending) do
        local ok, payload = pcall(json.decode, item.payload_json)
        if not ok or type(payload) ~= "table" then
            self.db:deletePendingProgress(item.id)
            failed = failed + 1
            goto continue
        end

        local success = self.api:updateProgress(payload)
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
            synced = synced + 1
        else
            self.db:incrementPendingProgressRetry(item.id)
            failed = failed + 1
        end

        ::continue::
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

    local cached = self.db:getBookByHash(file_hash)
    if cached and cached.book_id then
        return cached
    end

    if not self:isOnline() then
        self.db:saveBookCache(file_path, file_hash, nil, sanitizeTitle(file_path), nil)
        return cached
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    local success, book = self.api:getBookByHash(file_hash)
    if success and book and book.id then
        self.db:saveBookCache(file_path, file_hash, tonumber(book.id), book.title, book.author)
        return {
            file_path = file_path,
            file_hash = file_hash,
            book_id = tonumber(book.id),
            title = book.title,
            author = book.author,
        }
    end

    self.db:saveBookCache(file_path, file_hash, nil, sanitizeTitle(file_path), nil)
    if not silent then
        self:showMessage(_("No Grimmory match found for this book hash"), 4)
    end
    return nil
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
    if not self.auto_pull_on_open or not file_hash or file_hash == "" then
        return
    end
    if not self:isOnline() then
        return
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    local state = self.db:getProgressState(file_hash)
    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id)
    local success, remote = self.api:getProgress(file_hash)
    if not success then
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

    self:rememberLocalSnapshot(file_hash, local_snapshot, "open-local")
    self:rememberRemoteSnapshot(file_hash, remote_snapshot, "open-remote")

    local decision = self:compareOpenProgress(local_snapshot, remote_snapshot, state)
    self:logInfo("GrimmLink open sync decision:", decision or "nil")

    if decision == "local_newer" then
        self:pushProgressSnapshot(local_snapshot, "open-local-newer", true)
        return
    end

    if decision == "remote_newer" or decision == "conflict" then
        self:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, decision)
    end
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
    if not self.enabled or not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end

    local file_path = tostring(self.ui.document.file)
    local cached = self.db:getBookByFilePath(file_path)
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
    self:maybePullRemoteProgress(file_hash, file_path, book_id)
end

function Grimmlink:endSession(options)
    options = options or {}
    if not self.current_session then
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
    end

    self.current_session = nil
    return true
end

function Grimmlink:syncPendingSessions(silent)
    local synced = 0
    local failed = 0

    if not self:isOnline() then
        return synced, failed
    end

    self.api:init(self.server_url, self.username, self.auth_key, self.debug_logging)
    local pending = self.db:getPendingSessions(500)
    if #pending == 0 then
        return synced, failed
    end

    for _, session in ipairs(pending) do
        if not session.bookId and session.bookHash and session.bookHash ~= "" then
            local cached = self.db:getBookByHash(session.bookHash)
            if cached and cached.book_id then
                session.bookId = cached.book_id
                self.db:updatePendingSessionBookId(session.id, cached.book_id)
            else
                local ok_lookup, book = self.api:getBookByHash(session.bookHash)
                if ok_lookup and book and book.id then
                    session.bookId = tonumber(book.id)
                    self.db:updateBookId(session.bookHash, session.bookId)
                    self.db:updatePendingSessionBookId(session.id, session.bookId)
                end
            end
        end
    end

    local groups = {}
    for _, session in ipairs(pending) do
        if not session.bookId then
            self.db:incrementSessionRetryCount(session.id)
            failed = failed + 1
            goto continue_group
        end

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
        ::continue_group::
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

        local success = false
        if #items == 1 then
            success = self.api:submitSession({
                bookId = group.bookId,
                bookHash = group.bookHash,
                bookType = group.bookType,
                startTime = items[1].startTime,
                endTime = items[1].endTime,
                durationSeconds = items[1].durationSeconds,
                durationFormatted = items[1].durationFormatted,
                startProgress = items[1].startProgress,
                endProgress = items[1].endProgress,
                progressDelta = items[1].progressDelta,
                startLocation = items[1].startLocation,
                endLocation = items[1].endLocation,
                device = group.device,
                deviceId = group.deviceId,
            })
        else
            success = self.api:submitSessionBatch(
                group.bookId,
                group.bookHash,
                group.bookType,
                group.device,
                group.deviceId,
                items
            )
        end

        if success then
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
    local progress_synced, progress_failed = self:syncPendingProgress(true)
    local sessions_synced, sessions_failed = self:syncPendingSessions(true)

    self.last_sync_summary = {
        progress_synced = progress_synced,
        progress_failed = progress_failed,
        sessions_synced = sessions_synced,
        sessions_failed = sessions_failed,
    }

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

function Grimmlink:showPendingStats()
    local stats = self.db:getBookCacheStats()
    local pending_progress = self.db:getPendingProgressCount()
    local pending_sessions = self.db:getPendingSessionCount()

    self:showMessage(T(
        _("GrimmLink cache\nBooks cached: %1\nMatched: %2\nUnmatched: %3\nPending progress: %4\nPending sessions: %5"),
        stats.total,
        stats.matched,
        stats.unmatched,
        pending_progress,
        pending_sessions
    ), 5)
end

function Grimmlink:showAbout()
    local version = require("plugin_version")
    self:showMessage(table.concat({
        _("GrimmLink"),
        _("KOReader Companion for Grimmory"),
        "",
        T(_("Version: %1"), version.version or "0.1.0-dev"),
        _("Auto-update: disabled for MVP"),
        _("Phase 6 Web Reader Bridge / EPUB CFI conversion is intentionally not included."),
    }, "\n"), 6)
end

function Grimmlink:onReaderReady()
    self:logInfo("GrimmLink: reader ready")
    self:startSession()
    return false
end

function Grimmlink:onCloseDocument()
    if not self.enabled then
        return false
    end

    self:logInfo("GrimmLink: document closing")
    self:endSession({ reason = "close" })
    if self:isOnline() then
        self:syncPendingNow(true)
    end
    return false
end

function Grimmlink:onSuspend()
    if not self.enabled then
        return false
    end

    self:logInfo("GrimmLink: suspend")
    self:endSession({ reason = "suspend" })
    if self:isOnline() then
        self:syncPendingNow(true)
    end
    return false
end

function Grimmlink:onResume()
    if not self.enabled then
        return false
    end

    self:logInfo("GrimmLink: resume")
    local now = nowUtc()
    if self:isOnline() and (now - (self.last_auto_sync_time or 0)) >= ((tonumber(self.threshold_minutes) or DEFAULTS.threshold_minutes) * 60) then
        self.last_auto_sync_time = now
        self:syncPendingNow(true)
    end

    if self.ui and self.ui.document and not self.current_session then
        self:startSession()
    end

    return false
end

function Grimmlink:addToMainMenu(menu_items)
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
                text = _("Connection"),
                sub_item_table = {
                    {
                        text = _("Grimmory Server URL"),
                        callback = function()
                            self:configureServerUrl()
                        end,
                    },
                    {
                        text = _("KOReader Username"),
                        callback = function()
                            self:configureUsername()
                        end,
                    },
                    {
                        text = _("Auth Key / Password Hash"),
                        callback = function()
                            self:configureAuthKey()
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
                        text = _("Debug logging"),
                        checked_func = function()
                            return self.debug_logging
                        end,
                        callback = function()
                            self:saveSetting("debug_logging", not self.debug_logging)
                        end,
                    },
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
                    local pending_progress = self.db:getPendingProgressCount()
                    local pending_sessions = self.db:getPendingSessionCount()
                    if pending_progress == 0 and pending_sessions == 0 then
                        return _("Sync Pending Now")
                    end
                    return T(_("Sync Pending Now (%1 P, %2 S)"), pending_progress, pending_sessions)
                end,
                callback = function()
                    self:syncPendingNow(false)
                end,
            },
            {
                text = _("Show Local Cache Stats"),
                callback = function()
                    self:showPendingStats()
                end,
            },
            {
                text = _("About"),
                callback = function()
                    self:showAbout()
                end,
            },
        },
    }
end

return Grimmlink
