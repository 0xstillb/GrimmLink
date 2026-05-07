local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

local original_sqlite = package.preload["lua-ljsqlite3/init"]
package.preload["lua-ljsqlite3/init"] = function()
    return {
        OK = 0,
        DONE = 101,
        open = function()
            return nil
        end,
    }
end

package.preload["grimmlink_database"] = nil
package.loaded["grimmlink_database"] = nil
local Database = require("grimmlink_database")

package.preload["lua-ljsqlite3/init"] = original_sqlite
restore_stubs()

describe("GrimmLink database helpers", function()
    it("repairs the schema before retrying plugin setting writes", function()
        local repaired = false
        local prepare_calls = 0
        local fake_stmt = {
            bind = function() end,
            step = function()
                return 101
            end,
            close = function() end,
        }

        local db = setmetatable({
            conn = {
                prepare = function(_, sql)
                    prepare_calls = prepare_calls + 1
                    if sql:find("INSERT INTO plugin_settings", 1, true) and not repaired then
                        return nil
                    end
                    return fake_stmt
                end,
                exec = function()
                    return 0
                end,
                errmsg = function()
                    return "no such table: plugin_settings"
                end,
            },
            repairSchema = function()
                repaired = true
                return true
            end,
        }, { __index = Database })

        assert.is_true(db:savePluginSetting("enabled", true))
        assert.is_true(repaired)
        assert.are.equal(2, prepare_calls)
    end)
end)
