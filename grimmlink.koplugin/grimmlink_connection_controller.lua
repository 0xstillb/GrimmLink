local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local ConfirmBox = deps.ConfirmBox
    local InfoMessage = deps.InfoMessage
    local NetworkMgr = deps.NetworkMgr
    local UIManager = deps.UIManager
    local _ = deps._
    local T = deps.T
    local formatUrlForDisplay = deps.formatUrlForDisplay
    local normalizeNickname = deps.normalizeNickname
    local normalizeSsid = deps.normalizeSsid
    local nowUtc = deps.nowUtc
    local safeToString = deps.safeToString
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
    if self:isConnectionConfigured() then
        self:markFirstRunSetupCompleted()
    end
    if type(opts.on_saved) == "function" then
        opts.on_saved()
    end
    if opts.prompt_test ~= false then
        self:promptTestConnectionAfterSetup()
    end
end

function Grimmlink:isConnectionConfigured()
    return safeToString(self.server_url) ~= ""
        and safeToString(self.username) ~= ""
        and safeToString(self.password) ~= ""
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

function Grimmlink:getTargetDisplayLabel(active_source)
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
            T(_("Active server: %1"), self:getTargetDisplayLabel(active_source)),
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
        T(_("Active server: %1"), self:getTargetDisplayLabel(active_source)),
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
end

return M