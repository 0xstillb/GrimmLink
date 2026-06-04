local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local APIClient = deps.APIClient
    local Database = deps.Database
    local Deletion = deps.Deletion
    local Dispatcher = deps.Dispatcher
    local FileLogger = deps.FileLogger
    local MenuActions = deps.MenuActions
    local Matching = deps.Matching
    local PendingSync = deps.PendingSync
    local ProgressSync = deps.ProgressSync
    local ShelfSync = deps.ShelfSync
    local UIManager = deps.UIManager
    local Updater = deps.Updater
    local Util = deps.Util
    local DEFAULTS = deps.DEFAULTS
    local READING_COMPLETION_END_DIALOG_INITIAL_DELAY_SECONDS = deps.READING_COMPLETION_END_DIALOG_INITIAL_DELAY_SECONDS
    local detectPluginDir = deps.detectPluginDir
    local normalizeNickname = deps.normalizeNickname
    local normalizeShelfType = deps.normalizeShelfType
    local normalizeSsid = deps.normalizeSsid
    local normalizeUpdateChannel = deps.normalizeUpdateChannel
    local nowUtc = deps.nowUtc

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
    self.util = Util or nil
    self.pending_sync = PendingSync and type(PendingSync.new) == "function" and PendingSync.new() or nil
    self.progress_sync = ProgressSync and type(ProgressSync.new) == "function" and ProgressSync.new() or nil
    self.deletion = Deletion and type(Deletion.new) == "function" and Deletion.new() or nil
    self.matching = Matching and type(Matching.new) == "function" and Matching.new() or nil
    self.menu_actions = MenuActions and type(MenuActions.new) == "function" and MenuActions.new() or nil

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
    self.first_run_setup_completed = self:readSetting("first_run_setup_completed", DEFAULTS.first_run_setup_completed)
    self.first_run_setup_dismissed = self:readSetting("first_run_setup_dismissed", DEFAULTS.first_run_setup_dismissed)
    self.device_name = self:readSetting("device_name", self:defaultDeviceName())
    self.device_id = self:readSetting("device_id", self:defaultDeviceId())
    self.auto_pull_on_open = self:readSetting("auto_pull_on_open", DEFAULTS.auto_pull_on_open)
    self.auto_push_on_close = self:readSetting("auto_push_on_close", DEFAULTS.auto_push_on_close)
    self.offline_queue_enabled = self:readSetting("offline_queue_enabled", DEFAULTS.offline_queue_enabled)
    self.e_reader_friendly_mode = self:readSetting("e_reader_friendly_mode", DEFAULTS.e_reader_friendly_mode)
    self.auto_sync_cooldown_seconds = DEFAULTS.auto_sync_cooldown_seconds
    self.ask_wifi_before_sync = self:readSetting("ask_wifi_before_sync", DEFAULTS.ask_wifi_before_sync)
    self.sync_on_network_connected = self:readSetting("sync_on_network_connected", DEFAULTS.sync_on_network_connected)
    self.network_sync_cooldown_seconds = self:readSetting("network_sync_cooldown_seconds", DEFAULTS.network_sync_cooldown_seconds)
    self.pending_shelf_removal_retry_cooldown_seconds = self:readSetting(
        "pending_shelf_removal_retry_cooldown_seconds",
        DEFAULTS.pending_shelf_removal_retry_cooldown_seconds
    )
    self.pending_shelf_removal_retry_cooldown_seconds = math.floor(
        tonumber(self.pending_shelf_removal_retry_cooldown_seconds)
            or DEFAULTS.pending_shelf_removal_retry_cooldown_seconds
    )
    if self.pending_shelf_removal_retry_cooldown_seconds < 0 then
        self.pending_shelf_removal_retry_cooldown_seconds = 0
    elseif self.pending_shelf_removal_retry_cooldown_seconds > 86400 then
        self.pending_shelf_removal_retry_cooldown_seconds = 86400
    end
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
    self.shelf_plan_batch_size = math.floor(tonumber(
        self:readSetting("shelf_plan_batch_size", DEFAULTS.shelf_plan_batch_size)
    ) or DEFAULTS.shelf_plan_batch_size)
    if self.shelf_plan_batch_size < 10 then
        self.shelf_plan_batch_size = 10
    elseif self.shelf_plan_batch_size > 500 then
        self.shelf_plan_batch_size = 500
    end
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

    if self.shelf_sync then
        self.shelf_sync.pending_sync = self.pending_sync
        self.shelf_sync.deletion = self.deletion
        self.shelf_sync.plugin = self
        self.shelf_sync.pending_shelf_removal_retry_cooldown_seconds = self.pending_shelf_removal_retry_cooldown_seconds
    end

    self:refreshApiClient()
    self:syncFirstRunSetupState()
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
    self:maybePromptFirstRunSetup()
    self:processDeviceDebugCommandFile("init")
    return true
end

function Grimmlink:onReaderReady()
    self:ensureMainMenuRegistered()
    if not self.enabled or not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end
    self:runAfterUiSettles(function()
        self:startSession()
        self:processDeviceDebugCommandFile("reader_ready")
    end)
end

function Grimmlink:onEndOfBook()
    self:invokeSafely("end of book reading completion", function()
        if not self.current_session or self.current_session.tracking_enabled == false then
            return
        end
        local context = self:getReadingCompletionContext()
        if not context then
            return
        end
        local snapshot = self:getCurrentProgressSnapshot(
            context.file_hash,
            context.file_path,
            context.book_id,
            context.book_file_id
        )
        self:scheduleReadingCompletionPrompt(context, snapshot, {
            prompt_source = "end_of_book",
            wait_for_koreader_end_dialog = true,
            initial_delay_seconds = READING_COMPLETION_END_DIALOG_INITIAL_DELAY_SECONDS,
        })
    end, {}, { silent = true })
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
                metadata_limit = 20,
                followup_rounds = 2,
                followup_delay_seconds = 1.0,
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

    self:processDeviceDebugCommandFile("resume")
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
            metadata_limit = 20,
            followup_rounds = 2,
            followup_delay_seconds = 1.0,
            respect_cooldown = true,
            cooldown_seconds = tonumber(self.network_sync_cooldown_seconds) or DEFAULTS.network_sync_cooldown_seconds,
        })
    end
end

function Grimmlink:onExit()
    self:endSession({ reason = "exit" })
end

function Grimmlink:onTeardown()
    self:clearTabItemsCache()
end

end

return M
