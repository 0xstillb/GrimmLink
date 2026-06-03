local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local InfoMessage = deps.InfoMessage
    local UIManager = deps.UIManager
    local NetworkMgr = deps.NetworkMgr
    local logger = deps.logger
    local _ = deps._
    local normalizeSsid = deps.normalizeSsid
    local safeMethodCall = deps.safeMethodCall
    local unpack_values = deps.unpack_values or table.unpack or unpack

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

function Grimmlink:showConfirmAction(message, ok_text, on_confirm)
    local dialog = deps.ConfirmBox:new{
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

end

return M
