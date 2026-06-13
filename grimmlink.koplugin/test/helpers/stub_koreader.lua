local STUB_KEYS = {
    "logger",
    "datastorage",
    "ui/widget/inputdialog",
    "ui/widget/infomessage",
    "ui/uimanager",
    "ui/widget/container/widgetcontainer",
    "ui/widget/confirmbox",
    "ui/widget/buttondialog",
    "ui/network/manager",
    "ui/event",
    "dispatcher",
    "gettext",
    "ffi/util",
    "json",
    "grimmlink_database",
    "grimmlink_api_client",
    "grimmlink_file_logger",
    "grimmlink_updater",
    "ffi/sha2",
    "device",
    "bit",
}

local function install()
    local original = {}
    for _, key in ipairs(STUB_KEYS) do
        original[key] = package.preload[key]
    end

    package.path = table.concat({
        "./?.lua",
        "./?/init.lua",
        "./test/?.lua",
        "./test/?/init.lua",
        package.path,
    }, ";")

    package.preload["logger"] = function()
        return {
            info = function() end,
            warn = function() end,
            err = function() end,
            dbg = function() end,
        }
    end

    package.preload["datastorage"] = function()
        return {
            getDataDir = function() return "/tmp" end,
            getSettingsDir = function() return "/tmp" end,
        }
    end

    package.preload["ui/widget/inputdialog"] = function()
        return { new = function(_, o) return o or {} end }
    end

    package.preload["ui/widget/infomessage"] = function()
        return { new = function(_, o) return o or {} end }
    end

    package.preload["ui/uimanager"] = function()
        local UIManager = {
            last_shown = nil,
            last_closed = nil,
            dirty_calls = 0,
            shown_texts = {},
        }
        return {
            show = function(_, widget)
                UIManager.last_shown = widget
                UIManager.shown_texts[#UIManager.shown_texts + 1] = widget and widget.text
            end,
            close = function(_, widget)
                UIManager.last_closed = widget
            end,
            setDirty = function()
                UIManager.dirty_calls = UIManager.dirty_calls + 1
            end,
            scheduleIn = function(_, _delay, callback)
                if type(callback) == "function" then
                    callback()
                end
            end,
            nextTick = function(_, callback)
                if type(callback) == "function" then
                    callback()
                end
            end,
            askForRestart = function() end,
            getLastShown = function()
                return UIManager.last_shown
            end,
            getLastClosed = function()
                return UIManager.last_closed
            end,
            getDirtyCalls = function()
                return UIManager.dirty_calls
            end,
            getShownTexts = function()
                return UIManager.shown_texts
            end,
            reset = function()
                UIManager.last_shown = nil
                UIManager.last_closed = nil
                UIManager.dirty_calls = 0
                UIManager.shown_texts = {}
            end,
        }
    end

    package.preload["ui/widget/container/widgetcontainer"] = function()
        local WidgetContainer = {}
        function WidgetContainer:extend(o)
            o = o or {}
            o.__index = o
            setmetatable(o, self)
            self.__index = self
            return o
        end
        return WidgetContainer
    end

    package.preload["ui/widget/confirmbox"] = function()
        return { new = function(_, o) return o or {} end }
    end

    package.preload["ui/widget/buttondialog"] = function()
        local ButtonDialog = {}
        function ButtonDialog:new(o)
            o = o or {}
            setmetatable(o, { __index = self })
            return o
        end
        return ButtonDialog
    end

    package.preload["ui/network/manager"] = function()
        return {
            isConnected = function() return false end,
            isOnline = function() return false end,
        }
    end

    package.preload["ui/event"] = function()
        local Event = {}
        function Event:new(name, ...)
            local o = {
                handler = "on" .. name,
                args = table.pack(...),
            }
            setmetatable(o, self)
            self.__index = self
            return o
        end
        return Event
    end

    package.preload["dispatcher"] = function()
        return {
            registered_actions = {},
            registerAction = function(self, name, action)
                self.registered_actions[name] = action
            end,
        }
    end

    package.preload["gettext"] = function()
        return function(text) return text end
    end

    package.preload["ffi/util"] = function()
        return {
            template = function(fmt, ...)
                local args = { ... }
                return (fmt:gsub("%%(%d+)", function(index)
                    return tostring(args[tonumber(index)] or "")
                end))
            end,
        }
    end

    package.preload["json"] = function()
        return {
            encode = function(value)
                return value
            end,
            decode = function(value)
                return value
            end,
        }
    end

    package.preload["grimmlink_database"] = function()
        return {
            new = function()
                return {
                    init = function() return true end,
                    getPluginSetting = function() return nil end,
                    savePluginSetting = function() return true end,
                }
            end,
        }
    end

    package.preload["grimmlink_api_client"] = function()
        return {
            new = function()
                return {
                    init = function() end,
                }
            end,
        }
    end

    package.preload["grimmlink_file_logger"] = function()
        return {
            new = function()
                return {
                    init = function() return true end,
                    write = function() return true end,
                }
            end,
        }
    end

    package.preload["grimmlink_updater"] = function()
        return {
            new = function()
                return {
                    STARTUP_CHECK_INTERVAL = 86400,
                    init = function() return true end,
                    setAllowPrerelease = function() return true end,
                    clearCache = function() return true end,
                    checkForUpdates = function()
                        return {
                            available = false,
                            current_version = "0.1.0-dev",
                            latest_version = "0.1.0-dev",
                            release_info = {},
                        }, nil
                    end,
                    formatBytes = function(_, bytes)
                        return tostring(bytes or 0)
                    end,
                }
            end,
        }
    end

    package.preload["ffi/sha2"] = function()
        return {
            md5 = function(value)
                return "md5:" .. tostring(value or "")
            end,
        }
    end

    package.preload["device"] = function()
        return {
            model = "KOReader",
            name = "KOReader",
        }
    end

    package.preload["bit"] = function()
        return {
            lshift = function(value, shift)
                return value * (2 ^ shift)
            end,
        }
    end

    return function()
        for _, key in ipairs(STUB_KEYS) do
            package.preload[key] = original[key]
        end
    end
end

return {
    install = install,
}
