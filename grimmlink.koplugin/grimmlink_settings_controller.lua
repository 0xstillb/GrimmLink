local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local ButtonDialog = deps.ButtonDialog
    local ConfirmBox = deps.ConfirmBox
    local DataStorage = deps.DataStorage
    local InputDialog = deps.InputDialog
    local UIManager = deps.UIManager
    local lfs = deps.lfs
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS
    local E_READER_FRIENDLY_PRESET = deps.E_READER_FRIENDLY_PRESET
    local DIR_PICKER_MAX_SCAN_ENTRIES = deps.DIR_PICKER_MAX_SCAN_ENTRIES
    local DIR_PICKER_MAX_SHOW_DIRS = deps.DIR_PICKER_MAX_SHOW_DIRS
    local joinDirectoryPath = deps.joinDirectoryPath
    local normalizeDeviceIdentityText = deps.normalizeDeviceIdentityText
    local normalizeDirectoryPath = deps.normalizeDirectoryPath
    local nowUtc = deps.nowUtc
    local parentDirectoryPath = deps.parentDirectoryPath
    local safeToString = deps.safeToString
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
        return normalizeDeviceIdentityText(device.model or device.name, DEFAULTS.device_name, 80)
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

function Grimmlink:ensureDirectoryExists(path)
    if not lfs or type(lfs.mkdir) ~= "function" then
        return false, "lfs_unavailable"
    end
    local normalized = normalizeDirectoryPath(path)
    if normalized == "" then
        return false, "empty_path"
    end
    if self:isDirectory(normalized) then
        return true
    end

    local parent = parentDirectoryPath(normalized)
    if parent and parent ~= normalized and not self:isDirectory(parent) then
        local ok_parent, parent_err = self:ensureDirectoryExists(parent)
        if not ok_parent then
            return false, parent_err
        end
    end

    local ok_mkdir, mkdir_err = pcall(lfs.mkdir, normalized)
    if not ok_mkdir then
        return false, tostring(mkdir_err)
    end
    if self:isDirectory(normalized) then
        return true
    end
    return false, tostring(mkdir_err or "mkdir_failed")
end

function Grimmlink:isDirectoryWritable(path)
    local normalized = normalizeDirectoryPath(path)
    if normalized == "" or not self:isDirectory(normalized) then
        return false
    end

    local probe = joinDirectoryPath(
        normalized,
        ".grimmlink-write-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 999999))
    )
    local handle = io.open(probe, "w")
    if not handle then
        return false
    end
    handle:write("grimmlink")
    handle:close()
    pcall(os.remove, probe)
    return true
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

function Grimmlink:markFirstRunSetupCompleted()
    self:saveSetting("first_run_setup_completed", true)
    self:saveSetting("first_run_setup_dismissed", false)
end

function Grimmlink:dismissFirstRunSetupPrompt()
    self:saveSetting("first_run_setup_dismissed", true)
end

function Grimmlink:syncFirstRunSetupState()
    if self:isConnectionConfigured() and self.first_run_setup_completed ~= true then
        self:markFirstRunSetupCompleted()
        return true
    end
    return false
end

function Grimmlink:needsFirstRunSetup()
    if self.first_run_setup_completed == true then
        return false
    end
    return not self:isConnectionConfigured()
end

function Grimmlink:showChoiceAction(message, ok_text, cancel_text, on_confirm, on_cancel)
    local dialog = ConfirmBox:new{
        text = message,
        ok_text = ok_text or _("Confirm"),
        cancel_text = cancel_text or _("Cancel"),
        ok_callback = function()
            if type(on_confirm) == "function" then
                on_confirm()
            end
        end,
        cancel_callback = function()
            if type(on_cancel) == "function" then
                on_cancel()
            end
        end,
    }
    UIManager:show(dialog)
end

function Grimmlink:runFirstRunSetupWizard(options)
    options = options or {}
    local pending = {
        server_url = safeToString(options.server_url ~= nil and options.server_url or self.server_url),
        username = safeToString(options.username ~= nil and options.username or self.username),
        password = safeToString(options.password ~= nil and options.password or self.password),
        device_name = safeToString(options.device_name ~= nil and options.device_name or self.device_name),
    }
    if pending.server_url == "" then
        pending.server_url = "http://"
    end
    if pending.device_name == "" then
        pending.device_name = self:defaultDeviceName()
    end

    local function finishWizard()
        self:saveConnectionSettings(pending.server_url, pending.username, pending.password, self.remote_url, {
            local_url_nickname = self.local_url_nickname,
            remote_url_nickname = self.remote_url_nickname,
            prompt_test = false,
            on_saved = function()
                self:saveSetting("device_name", normalizeDeviceIdentityText(
                    pending.device_name,
                    self:defaultDeviceName(),
                    80
                ))
                self:markFirstRunSetupCompleted()
                self:showMessage(_("First-time setup saved"), 3)
                if options.prompt_test ~= false then
                    self:promptTestConnectionAfterSetup()
                end
            end,
        })
    end

    local function askEreaderMode()
        self:showChoiceAction(
            _("Enable E-reader Friendly Mode?\n\nRecommended for Kindle and e-ink devices."),
            _("Enable"),
            _("Skip"),
            function()
                self:applyEreaderFriendlyMode()
                finishWizard()
            end,
            function()
                finishWizard()
            end
        )
    end

    local function askDeviceName()
        self:showTextInput(_("Device Name"), pending.device_name, _("Example: Kindle PW5"), false, function(device_name)
            local normalized = normalizeDeviceIdentityText(device_name, self:defaultDeviceName(), 80)
            if normalized == "" then
                self:showMessage(_("Device name is required"), 2)
                askDeviceName()
                return
            end
            pending.device_name = normalized
            askEreaderMode()
        end)
    end

    local function askPassword()
        self:showTextInput(_("Password"), pending.password, _("Enter Grimmory password"), true, function(password)
            local normalized = safeToString(password)
            if normalized == "" then
                self:showMessage(_("Password is required"), 2)
                askPassword()
                return
            end
            pending.password = normalized
            askDeviceName()
        end)
    end

    local function askUsername()
        self:showTextInput(_("KOReader Username"), pending.username, _("Enter username"), false, function(username)
            local normalized = safeToString(username)
            if normalized == "" then
                self:showMessage(_("Username is required"), 2)
                askUsername()
                return
            end
            pending.username = normalized
            askPassword()
        end)
    end

    local function askLocalUrl()
        self:showTextInput(_("Local URL (home network)"), pending.server_url, "http://192.168.1.100:6060", false, function(server_url)
            local normalized = safeToString(server_url):gsub("/$", "")
            if normalized == "" or normalized == "http:/" or normalized == "https:/" then
                self:showMessage(_("Local URL is required"), 2)
                askLocalUrl()
                return
            end
            pending.server_url = normalized
            askUsername()
        end)
    end

    askLocalUrl()
end

function Grimmlink:maybePromptFirstRunSetup()
    if self._first_run_setup_prompted_this_session == true then
        return false
    end
    if self.first_run_setup_dismissed == true or not self:needsFirstRunSetup() then
        return false
    end
    self._first_run_setup_prompted_this_session = true
    self:runAfterUiSettles(function()
        self:showChoiceAction(
            _("Welcome to GrimmLink.\n\nRun the first-time setup wizard now?"),
            _("Start Setup"),
            _("Later"),
            function()
                self:runFirstRunSetupWizard()
            end,
            function()
                self:dismissFirstRunSetupPrompt()
            end
        )
    end)
    return true
end

function Grimmlink:configureDeviceName()
    self:showTextInput(_("Device Name"), self.device_name, _("Enter device name"), false, function(value)
        local normalized = normalizeDeviceIdentityText(value, self:defaultDeviceName(), 80)
        self:saveSetting("device_name", normalized)
        self:showMessage(_("Device name saved"), 2)
    end)
end

function Grimmlink:configureDeviceId()
    self:showTextInput(_("Device ID"), self.device_id, _("Enter stable device ID"), false, function(value)
        local normalized = normalizeDeviceIdentityText(value, self:defaultDeviceId(), 128)
        self:saveSetting("device_id", normalized)
        self:showMessage(_("Device ID saved"), 2)
    end)
end

function Grimmlink:isEreaderFriendlyModeActive()
    if self.e_reader_friendly_mode ~= true then
        return false
    end
    for key, value in pairs(E_READER_FRIENDLY_PRESET) do
        if self[key] ~= value then
            return false
        end
    end
    return true
end

function Grimmlink:getNetworkModeLabel()
    if self:isEreaderFriendlyModeActive() then
        return _("E-reader Friendly")
    end
    return _("Custom")
end

function Grimmlink:applyEreaderFriendlyMode()
    for key, value in pairs(E_READER_FRIENDLY_PRESET) do
        self:saveSetting(key, value)
    end
    self:saveSetting("e_reader_friendly_mode", true)
    self:showMessage(_("E-reader Friendly Mode enabled"), 3)
end

function Grimmlink:disableEreaderFriendlyMode()
    self:saveSetting("e_reader_friendly_mode", false)
    self:showMessage(_("E-reader Friendly Mode disabled"), 3)
end
end

return M