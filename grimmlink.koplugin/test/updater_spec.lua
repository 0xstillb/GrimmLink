package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./test/?.lua",
    "./test/?/init.lua",
    package.path,
}, ";")

local json_stub = {
    encode = function(value)
        return value
    end,
    decode = function(value)
        return value
    end,
}

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end

package.preload["socket.http"] = function()
    return {
        request = function()
            error("network request should be stubbed in updater_spec")
        end,
    }
end

package.preload["ssl.https"] = function()
    return {
        request = function()
            error("network request should be stubbed in updater_spec")
        end,
    }
end

package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(target)
                return function(chunk)
                    if chunk then
                        target[#target + 1] = chunk
                    end
                    return 1
                end
            end,
        },
    }
end

package.preload["json"] = function()
    return json_stub
end

package.preload["datastorage"] = function()
    return {
        getDataDir = function()
            return "/tmp"
        end,
    }
end

package.loaded["grimmlink_updater"] = nil
local Updater = require("grimmlink_updater")

local function newDb()
    local store = {}
    return {
        getPluginSetting = function(_, key)
            return store[key]
        end,
        savePluginSetting = function(_, key, value)
            store[key] = value
            return true
        end,
        store = store,
    }
end

local function releaseAsset(name, size)
    return {
        name = name,
        browser_download_url = "https://example.invalid/" .. name,
        size = size or 1234,
    }
end

local function newUpdater(options)
    local updater = Updater:new()
    updater:init("/plugins/grimmlink.koplugin", newDb(), options or {})
    return updater
end

describe("GrimmLink updater", function()
    before_each(function()
        json_stub.encode = function(value)
            return value
        end
        json_stub.decode = function(value)
            return value
        end
    end)

    it("forces the official GrimmLink release repo", function()
        local updater = newUpdater({
            update_repo = "WorldTeacher/BookLoreSync-plugin",
        })

        assert.are.equal("0xstillb/grimmlink", updater.update_repo)
    end)

    it("treats development builds as older than tagged releases", function()
        local updater = newUpdater()

        assert.are.equal(-1, updater:compareVersions(
            updater:parseVersion("0.1.0-dev"),
            updater:parseVersion("v0.1.0")
        ))
        assert.are.equal(1, updater:compareVersions(
            updater:parseVersion("v1.2.4"),
            updater:parseVersion("v1.2.3")
        ))
    end)

    it("accepts the expected GrimmLink release asset names", function()
        local updater = newUpdater()
        local release_info = {
            tag_name = "v1.2.3",
            assets = {
                releaseAsset("notes.txt"),
                releaseAsset("grimmlink-v1.2.3.zip", 2048),
            },
        }

        local selected = updater:selectReleaseAsset(release_info)
        assert.is_not_nil(selected)
        assert.are.equal("grimmlink-v1.2.3.zip", selected.name)
    end)

    it("uses the stable latest-release endpoint by default", function()
        local updater = newUpdater()
        local captured_url = nil

        updater._makeHttpRequest = function(_, url)
            captured_url = url
            return true, "mock-response"
        end
        json_stub.decode = function()
            return {
                tag_name = "v1.2.3",
                assets = {
                    releaseAsset("grimmlink.koplugin.zip", 8192),
                },
            }
        end

        local release_info, error_msg = updater:getLatestRelease()
        assert.is_nil(error_msg)
        assert.are.equal("https://api.github.com/repos/0xstillb/grimmlink/releases/latest", captured_url)
        assert.are.equal("v1.2.3", release_info.version)
    end)

    it("handles invalid GitHub JSON safely", function()
        local updater = newUpdater()

        updater._makeHttpRequest = function()
            return true, "broken-json"
        end
        json_stub.decode = function()
            error("invalid json")
        end

        local release_info, error_msg = updater:getLatestRelease()
        assert.is_nil(release_info)
        assert.are.equal("invalid GitHub JSON response", error_msg)
    end)
end)
