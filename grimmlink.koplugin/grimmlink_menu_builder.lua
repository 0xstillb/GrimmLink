local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local ButtonDialog = deps.ButtonDialog
    local ConfirmBox = deps.ConfirmBox
    local UIManager = deps.UIManager
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS
    local _gl_load_errors = deps._gl_load_errors or {}
    local normalizeDeviceIdentityText = deps.normalizeDeviceIdentityText
    local normalizeShelfType = deps.normalizeShelfType
    local normalizeUpdateChannel = deps.normalizeUpdateChannel
    local safeDbValueCall = deps.safeDbValueCall
    local safeToString = deps.safeToString
    local shortPrefix = deps.shortPrefix
function Grimmlink:installSettingsTab()
    local function normalizeTabField(value)
        if type(value) ~= "string" then return "" end
        return value:lower():gsub("[%s_%-]+", "")
    end

    local function findInsertPos(tab_table)
        return 1
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

            tab_items.icon = tab_items.icon or "book.opened"
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

function Grimmlink:showConnectionMenu(touchmenu_instance)
    local items = {
        {
            text = _("First Run Setup Wizard"),
            callback = function()
                self:runFirstRunSetupWizard()
            end,
        },
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
    local function showSyncSummary()
        if self.menu_actions and type(self.menu_actions.showSyncSummary) == "function" then
            self.menu_actions:showSyncSummary(self, safeDbValueCall)
        elseif not self.db then
            self:showMessage(_("Database not available"), 3)
        else
            self:showMessage(T(
                _("Pending progress: %1\nPending sessions: %2\nPending metadata: %3"),
                self.db:getPendingProgressCount(),
                self.db:getPendingSessionCount(),
                safeDbValueCall(self.db, "getPendingMetadataCount", 0)
            ), 3)
        end
    end

    local status_items = nil
    if self.menu_actions and type(self.menu_actions.buildStatusItems) == "function" then
        status_items = self.menu_actions:buildStatusItems(self, {
            load_errors = _gl_load_errors,
            safe_db_value_call = safeDbValueCall,
            sync_summary_callback = showSyncSummary,
        })
    else
        status_items = {
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
                callback = showSyncSummary,
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
    end

    local maintenance_item = self.menu_actions
        and type(self.menu_actions.buildMaintenanceItem) == "function"
        and self.menu_actions:buildMaintenanceItem(self)
        or {
            text = _("Maintenance"),
            sub_item_table = {},
        }

    menu_items.grimmlink = {
        text = _("GrimmLink"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                id = "enable_grimmlink",
                text = _("Enable GrimmLink"),
                keep_menu_open = true,
                checked_func = function() return self.enabled end,
                callback = function()
                    self.enabled = not self.enabled
                    self:saveSetting("enabled", self.enabled)
                end,
            },
            {
                id = "connection",
                text = _("Connection"),
                sub_item_table = {
                    { text = _("First Run Setup Wizard"), callback = function() self:runFirstRunSetupWizard() end },
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
                id = "sync_pending_now",
                text = _("Sync Pending Now"),
                callback = function() self:syncPendingNow(false) end,
            },
            {
                id = "sync_shelf_now",
                text = _("Sync Shelf Now"),
                callback = function() self:syncShelfNow(false) end,
            },
            {
                id = "advanced_setting",
                separator = true,
                text = _("Advanced Setting"),
                sub_item_table = {
                    {
                        text = _("Setup & Backup"),
                        sub_item_table = {
                            {
                                text = _("Run First Setup Wizard"),
                                callback = function()
                                    self:runFirstRunSetupWizard()
                                end,
                            },
                            {
                                text = _("Export Settings Backup"),
                                callback = function()
                                    self:exportSettingsBackup()
                                end,
                            },
                            {
                                text = _("Restore Settings Backup"),
                                callback = function()
                                    self:promptRestoreSettingsBackup()
                                end,
                            },
                        },
                    },
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
                                        text = _("Shelf Sync Download Directory"),
                                        sub_item_table = {
                                            {
                                                text_func = function()
                                                    local mode = self:isShelfDownloadDirectoryCustom() and _("Custom") or _("Default (Auto)")
                                                    return T(_("Current: %1"), mode)
                                                end,
                                                callback = function() end,
                                            },
                                            {
                                                text = _("Default (Auto)"),
                                                callback = function()
                                                    self:setShelfDownloadDirectoryAuto()
                                                end,
                                            },
                                            {
                                                text = _("Select folder"),
                                                callback = function()
                                                    self:configureDownloadDir()
                                                end,
                                            },
                                        },
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
                                        text_func = function()
                                            return T(
                                                _("Separate magic shelf folder: %1"),
                                                self.use_separate_magic_download_dir == true and _("ON") or _("OFF")
                                            )
                                        end,
                                        keep_menu_open = true,
                                        checked_func = function() return self.use_separate_magic_download_dir == true end,
                                        callback = function()
                                            self:toggleSeparateMagicDownloadDirectory()
                                        end,
                                        sub_item_table = {
                                            {
                                                text_func = function()
                                                    return self.use_separate_magic_download_dir == true and _("Turn OFF") or _("Turn ON")
                                                end,
                                                callback = function()
                                                    self:toggleSeparateMagicDownloadDirectory()
                                                end,
                                            },
                                            {
                                                text = _("Default (Auto)"),
                                                callback = function()
                                                    self:setSeparateMagicDownloadDirectoryDefault()
                                                end,
                                            },
                                            {
                                                text = _("Select folder"),
                                                callback = function()
                                                    self:selectSeparateMagicDownloadDirectory()
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
                                        text_func = function()
                                            return T(
                                                _("Planning Batch Size: %1"),
                                                tonumber(self.shelf_plan_batch_size) or DEFAULTS.shelf_plan_batch_size
                                            )
                                        end,
                                        callback = function()
                                            self:showNumberInput(
                                                _("Planning Batch Size"),
                                                self.shelf_plan_batch_size or DEFAULTS.shelf_plan_batch_size,
                                                _("Recommended: 40-120"),
                                                function(value)
                                                    local normalized = math.floor(
                                                        tonumber(value) or DEFAULTS.shelf_plan_batch_size
                                                    )
                                                    if normalized < 10 then normalized = 10 end
                                                    if normalized > 500 then normalized = 500 end
                                                    self:saveSetting("shelf_plan_batch_size", normalized)
                                                end
                                            )
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
                        text = _("Device Identity"),
                        sub_item_table = {
                            {
                                text_func = function()
                                    return T(
                                        _("Device Name: %1"),
                                        normalizeDeviceIdentityText(self.device_name, self:defaultDeviceName(), 80)
                                    )
                                end,
                                callback = function() self:configureDeviceName() end,
                            },
                            {
                                text_func = function()
                                    return T(_("Device ID: %1"), shortPrefix(self.device_id, 16))
                                end,
                                callback = function() self:configureDeviceId() end,
                            },
                        },
                    },
                    {
                        text = _("Tracking & Network"),
                        sub_item_table = {
                            {
                                text_func = function()
                                    return T(_("Network Mode: %1"), self:getNetworkModeLabel())
                                end,
                                keep_menu_open = true,
                                callback = function() end,
                            },
                            {
                                text = _("E-reader Friendly Mode"),
                                help_text = _("Queue offline progress, ask before enabling Wi-Fi, and sync pending items only when network/resume timing is safe."),
                                keep_menu_open = true,
                                checked_func = function() return self:isEreaderFriendlyModeActive() end,
                                callback = function()
                                    if self:isEreaderFriendlyModeActive() then
                                        self:disableEreaderFriendlyMode()
                                    else
                                        self:applyEreaderFriendlyMode()
                                    end
                                end,
                            },
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
                            {
                                text_func = function()
                                    return T(
                                        _("Pending Shelf Removal Retry Cooldown: %1s"),
                                        tonumber(self.pending_shelf_removal_retry_cooldown_seconds)
                                            or DEFAULTS.pending_shelf_removal_retry_cooldown_seconds
                                    )
                                end,
                                callback = function()
                                    self:showNumberInput(
                                        _("Pending Shelf Removal Retry Cooldown (seconds)"),
                                        self.pending_shelf_removal_retry_cooldown_seconds
                                            or DEFAULTS.pending_shelf_removal_retry_cooldown_seconds,
                                        _("Recommended: 30"),
                                        function(value)
                                            local normalized = math.floor(
                                                tonumber(value) or DEFAULTS.pending_shelf_removal_retry_cooldown_seconds
                                            )
                                            if normalized < 0 then normalized = 0 end
                                            if normalized > 86400 then normalized = 86400 end
                                            self:saveSetting("pending_shelf_removal_retry_cooldown_seconds", normalized)
                                            if self.shelf_sync then
                                                self.shelf_sync.pending_shelf_removal_retry_cooldown_seconds = normalized
                                            end
                                        end
                                    )
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
                    maintenance_item,
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
                id = "status_about",
                text = _("Status / About"),
                sub_item_table = status_items,
            },
        },
    }

    local in_reader_book = self.menu_actions
        and type(self.menu_actions.isReaderBookContext) == "function"
        and self.menu_actions:isReaderBookContext(self)
        or (self.current_session and self.current_session.book_id ~= nil and self.current_session.file_path ~= nil)
    if in_reader_book then
        local sub_items = menu_items.grimmlink.sub_item_table
        if self.menu_actions and type(self.menu_actions.applyReaderBookTopLevelOverrides) == "function" then
            self.menu_actions:applyReaderBookTopLevelOverrides(self, sub_items, {
                insert_pos = 3,
                safe_db_value_call = safeDbValueCall,
                sync_summary_callback = showSyncSummary,
            })
        else
            for i = #sub_items, 1, -1 do
                local item = sub_items[i]
                if item and (
                    item.id == "connection"
                    or item.id == "sync_shelf_now"
                    or item.id == "advanced_setting"
                    or item.id == "status_about"
                ) then
                    table.remove(sub_items, i)
                end
            end
            table.insert(sub_items, 3, {
                id = "reading_completion",
                text = _("Reading Completion"),
                callback = function() self:showReadingCompletionMenu() end,
            })
            table.insert(sub_items, 4, {
                id = "pull_remote_progress",
                text = _("Pull Remote Progress"),
                callback = function() self:manualPullProgress() end,
            })
            table.insert(sub_items, 5, {
                id = "manual_reading_status",
                text = _("Manual Reading Status"),
                callback = function() self:showManualReadStatusMenu() end,
            })
            table.insert(sub_items, 6, {
                id = "sync_summary",
                text = _("Sync Summary"),
                callback = showSyncSummary,
            })
        end
    end
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
end

return M