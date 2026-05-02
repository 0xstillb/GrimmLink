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

package.loaded["logger"] = nil
package.loaded["socket.http"] = nil
package.loaded["ssl.https"] = nil
package.loaded["ltn12"] = nil
package.loaded["json"] = nil
package.loaded["datastorage"] = nil
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
    local normalized_options = options or {}
    normalized_options.command_runner = normalized_options.command_runner or function()
        return true
    end
    normalized_options.command_reader = normalized_options.command_reader or function()
        return true, ""
    end
    updater:init("/plugins/grimmlink.koplugin", newDb(), normalized_options)
    return updater
end

local function tableContains(values, expected)
    for _, value in ipairs(values) do
        if value == expected then
            return true
        end
    end
    return false
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
            update_repo = "example/not-grimmlink",
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

    it("simulates a release check followed by download and install flow", function()
        local commands = {}
        local progress_updates = {}
        local written_files = {}
        local original_io_open = io.open

        local updater = newUpdater({
            command_runner = function(command)
                commands[#commands + 1] = command
                return true
            end,
            command_reader = function(command)
                if command:find("unzip %-l", 1, false) then
                    return true, table.concat({
                        "Archive: grimmlink-update.zip",
                        "  grimmlink.koplugin/main.lua",
                        "  grimmlink.koplugin/_meta.lua",
                        "  grimmlink.koplugin/plugin_version.lua",
                    }, "\n")
                end
                if command:find("ls %-t", 1, false) then
                    return true, ""
                end
                return true, ""
            end,
        })

        updater.getCurrentVersion = function()
            return {
                version = "v1.2.2",
            }
        end
        updater._makeHttpRequest = function(_, url, headers)
            if headers and headers["Accept"] == "application/octet-stream" then
                return true, "fake-zip-bytes"
            end
            assert.are.equal("https://api.github.com/repos/0xstillb/grimmlink/releases/latest", url)
            return true, "mock-release-response"
        end
        updater._resolveDownloadUrl = function()
            return false, "head disabled in test"
        end

        json_stub.decode = function(payload)
            assert.are.equal("mock-release-response", payload)
            return {
                tag_name = "v1.2.3",
                assets = {
                    releaseAsset("grimmlink.koplugin.zip", 16384),
                },
            }
        end

        io.open = function(path, mode)
            if mode == "wb" then
                written_files[path] = ""
                return {
                    write = function(_, chunk)
                        written_files[path] = written_files[path] .. (chunk or "")
                    end,
                    close = function()
                        return true
                    end,
                }
            end
            if mode == "r" and path:match("grimmlink%.koplugin/main%.lua$") then
                return {
                    close = function()
                        return true
                    end,
                }
            end
            return original_io_open(path, mode)
        end

        local result, error_msg = updater:checkForUpdates(false)
        local downloaded, zip_path
        local installed, backup_path

        local ok, failure = pcall(function()
            assert.is_nil(error_msg)
            assert.is_true(result.available)
            assert.are.equal("v1.2.3", result.latest_version)

            downloaded, zip_path = updater:downloadReleaseAsset(result.release_info.download_url, function(done, total)
                progress_updates[#progress_updates + 1] = { done = done, total = total }
            end)
            assert.is_true(downloaded)
            assert.are.equal("fake-zip-bytes", written_files[zip_path])
            assert.are.same({
                { done = #"fake-zip-bytes", total = #"fake-zip-bytes" },
            }, progress_updates)

            installed, backup_path = updater:installDownloadedUpdate(zip_path)
            assert.is_true(installed)
            assert.is_true(type(backup_path) == "string" and backup_path:find("/tmp/grimmlink%-backups/grimmlink%-v1%.2%.2%-", 1, false) ~= nil)

            assert.are.equal("mkdir -p '/tmp/grimmlink-backups'", commands[1])
            assert.are.equal("mkdir -p '" .. updater.temp_dir .. "'", commands[2])
            assert.are.equal("mkdir -p '" .. updater.temp_dir .. "/extract'", commands[3])
            assert.are.equal("unzip -q -o '" .. zip_path .. "' -d '" .. updater.temp_dir .. "/extract'", commands[4])
            assert.are.equal("mkdir -p '/tmp/grimmlink-backups'", commands[5])
            assert.is_true(commands[6]:find("cp %-R '/plugins/grimmlink%.koplugin' '/tmp/grimmlink%-backups/grimmlink%-v1%.2%.2%-") ~= nil)
            assert.are.equal("rm -rf '" .. updater.temp_dir .. "/rollback-current'", commands[7])
            assert.are.equal("mv '/plugins/grimmlink.koplugin' '" .. updater.temp_dir .. "/rollback-current'", commands[8])
            assert.are.equal("mv '" .. updater.temp_dir .. "/extract/grimmlink.koplugin' '/plugins/grimmlink.koplugin'", commands[9])
            assert.are.equal("rm -rf '" .. updater.temp_dir .. "/rollback-current'", commands[10])
            assert.are.equal("rm -rf '" .. updater.temp_dir .. "'", commands[11])
        end)

        io.open = original_io_open
        if not ok then
            error(failure)
        end
    end)

    it("rolls the staged plugin back when replacing it fails", function()
        local commands = {}
        local original_io_open = io.open
        local updater = newUpdater({
            command_reader = function(command)
                if command:find("unzip %-l", 1, false) then
                    return true, table.concat({
                        "Archive: grimmlink-update.zip",
                        "  grimmlink.koplugin/main.lua",
                        "  grimmlink.koplugin/_meta.lua",
                        "  grimmlink.koplugin/plugin_version.lua",
                    }, "\n")
                end
                if command:find("ls %-t", 1, false) then
                    return true, ""
                end
                return true, ""
            end,
        })
        updater.command_runner = function(command)
            commands[#commands + 1] = command
            if command == "mv '" .. updater.temp_dir .. "/extract/grimmlink.koplugin' '/plugins/grimmlink.koplugin'" then
                return false
            end
            return true
        end

        updater.getCurrentVersion = function()
            return {
                version = "v1.2.2",
            }
        end

        io.open = function(path, mode)
            if mode == "r" and path:match("grimmlink%.koplugin/main%.lua$") then
                return {
                    close = function()
                        return true
                    end,
                }
            end
            return original_io_open(path, mode)
        end

        local installed, error_msg
        local ok, failure = pcall(function()
            installed, error_msg = updater:installDownloadedUpdate("/tmp/fake-release.zip")
            assert.is_false(installed)
            assert.are.equal("failed to install updated grimmlink.koplugin package", error_msg)
            assert.is_true(tableContains(commands, "mv '/plugins/grimmlink.koplugin' '" .. updater.temp_dir .. "/rollback-current'"))
            assert.is_true(tableContains(commands, "mv '" .. updater.temp_dir .. "/extract/grimmlink.koplugin' '/plugins/grimmlink.koplugin'"))
            assert.is_true(tableContains(commands, "mv '" .. updater.temp_dir .. "/rollback-current' '/plugins/grimmlink.koplugin'"))
        end)

        io.open = original_io_open
        if not ok then
            error(failure)
        end
    end)
end)
