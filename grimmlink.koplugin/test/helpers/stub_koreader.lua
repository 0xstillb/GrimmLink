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
    "gettext",
    "ffi/util",
    "json",
    "grimmlink_database",
    "grimmlink_api_client",
    "grimmlink_file_logger",
    "bit",
}

local function install()
    local original = {}
    for _, key in ipairs(STUB_KEYS) do
        original[key] = package.preload[key]
    end

    package.path = table.concat({
        "plugins/grimmlink.koplugin/?.lua",
        "plugins/grimmlink.koplugin/?/init.lua",
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
        return {
            show = function() end,
            close = function() end,
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
