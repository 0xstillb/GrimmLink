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

    it("applies metadata table migration during schema repair", function()
        local executed_sql = {}
        local pragma_stmt = {
            rows = function()
                local done = false
                return function()
                    if done then return nil end
                    done = true
                    return { 1, "remote_series_name" }
                end
            end,
            close = function() end,
        }

        local db = setmetatable({
            conn = {
                exec = function(_, sql)
                    executed_sql[#executed_sql + 1] = sql
                    return 0
                end,
                prepare = function(_, sql)
                    if sql == "PRAGMA table_info(shelf_sync_map)" then
                        return pragma_stmt
                    end
                    return nil
                end,
                errmsg = function()
                    return "ok"
                end,
            },
        }, { __index = Database })

        assert.is_true(db:repairSchema())
        local joined = table.concat(executed_sql, "\n")
        assert.is_true(joined:find("pending_metadata_items", 1, true) ~= nil)
        assert.is_true(joined:find("synced_metadata_items", 1, true) ~= nil)
        assert.is_true(joined:find("book_tracking_state", 1, true) ~= nil)
    end)

    it("supports metadata queue helpers", function()
        local pending_rows = {}
        local synced_rows = {}
        local last_bind = {}

        local function stmtFor(sql)
            local stmt = {}
            function stmt:bind(...)
                last_bind[sql] = { ... }
            end
            function stmt:step()
                if sql:find("INSERT INTO pending_metadata_items", 1, true) then
                    local args = last_bind[sql]
                    pending_rows[1] = {
                        file_hash = args[1],
                        book_id = args[2],
                        book_file_id = args[3],
                        item_type = args[4],
                        dedupe_key = args[5],
                        payload_json = args[6],
                    }
                elseif sql:find("INSERT INTO synced_metadata_items", 1, true) then
                    local args = last_bind[sql]
                    synced_rows[1] = {
                        file_hash = args[1],
                        book_id = args[2],
                        item_type = args[3],
                        dedupe_key = args[4],
                    }
                elseif sql:find("DELETE FROM pending_metadata_items", 1, true) then
                    pending_rows = {}
                elseif sql:find("DELETE FROM synced_metadata_items", 1, true) then
                    synced_rows = {}
                end
                return 101
            end
            function stmt:rows()
                local emitted = false
                return function()
                    if emitted then return nil end
                    emitted = true
                    if sql:find("SELECT 1 FROM synced_metadata_items", 1, true) then
                        local args = last_bind[sql] or {}
                        if synced_rows[1]
                            and synced_rows[1].file_hash == args[1]
                            and synced_rows[1].item_type == args[2]
                            and synced_rows[1].dedupe_key == args[3] then
                            return { 1 }
                        end
                        return nil
                    end
                    if sql:find("SELECT COUNT%(%*%) FROM pending_metadata_items") then
                        return { #pending_rows }
                    end
                    if sql:find("SELECT id, file_hash, book_id, book_file_id, item_type, dedupe_key", 1, true) then
                        if pending_rows[1] then
                            return {
                                1,
                                pending_rows[1].file_hash,
                                pending_rows[1].book_id,
                                pending_rows[1].book_file_id,
                                pending_rows[1].item_type,
                                pending_rows[1].dedupe_key,
                                pending_rows[1].payload_json,
                                0,
                                nil,
                                os.time(),
                                os.time(),
                            }
                        end
                        return nil
                    end
                    return nil
                end
            end
            function stmt:close() end
            return stmt
        end

        local db = setmetatable({
            conn = {
                prepare = function(_, sql)
                    return stmtFor(sql)
                end,
                exec = function()
                    return 0
                end,
            },
        }, { __index = Database })

        assert.is_true(db:upsertPendingMetadataItem({
            file_hash = "hash-1",
            book_id = 12,
            book_file_id = 34,
            item_type = "rating",
            dedupe_key = "hash-1:rating",
            payload_json = "{\"rating\":5}",
        }))
        local rows = db:getPendingMetadataItems(10)
        assert.are.equal(1, #rows)
        assert.are.equal("hash-1:rating", rows[1].dedupe_key)
        assert.are.equal(1, db:getPendingMetadataCount())

        assert.is_true(db:markMetadataItemSynced({
            file_hash = "hash-1",
            book_id = 12,
            item_type = "rating",
            dedupe_key = "hash-1:rating",
        }))
        assert.is_true(db:isMetadataItemSynced("hash-1", "rating", "hash-1:rating"))
        assert.is_true(db:deletePendingMetadataItem(1))
        assert.is_true(db:deleteAllPendingMetadata())
        assert.is_true(db:deletePendingMetadataByFileHash("hash-1"))
        assert.is_true(db:clearSyncedMetadataHistory())
        assert.is_true(db:clearSyncedMetadataHistoryForFileHash("hash-1"))
    end)

    it("supports shelf maintenance counters and clear helpers", function()
        local executed_sql = {}
        local function stmtFor(sql)
            local stmt = {}
            function stmt:bind() end
            function stmt:step()
                return 101
            end
            function stmt:rows()
                local emitted = false
                return function()
                    if emitted then return nil end
                    emitted = true
                    if sql:find("COUNT%(%*%) FROM pending_shelf_removals") then
                        return { 3 }
                    end
                    if sql:find("COUNT%(%*%) FROM shelf_sync_tombstones") then
                        return { 5 }
                    end
                    if sql:find("COUNT%(%*%) FROM synced_metadata_items") then
                        return { 7 }
                    end
                    return { 0 }
                end
            end
            function stmt:close() end
            return stmt
        end

        local db = setmetatable({
            conn = {
                prepare = function(_, sql)
                    return stmtFor(sql)
                end,
                exec = function(_, sql)
                    executed_sql[#executed_sql + 1] = sql
                    return 0
                end,
            },
        }, { __index = Database })

        assert.are.equal(3, db:getPendingShelfRemovalCount())
        assert.are.equal(5, db:getShelfTombstoneCount())
        assert.are.equal(7, db:getSyncedMetadataCount())
        assert.is_true(db:clearPendingShelfRemovals())
        assert.is_true(db:clearShelfTombstones())
        assert.is_true(db:deleteAllPendingSessions())
        assert.is_true(table.concat(executed_sql, "\n"):find("DELETE FROM pending_shelf_removals", 1, true) ~= nil)
        assert.is_true(table.concat(executed_sql, "\n"):find("DELETE FROM shelf_sync_tombstones", 1, true) ~= nil)
        assert.is_true(table.concat(executed_sql, "\n"):find("DELETE FROM pending_sessions", 1, true) ~= nil)
    end)

    it("supports per-book tracking helpers", function()
        local tracking_rows = {}
        local last_bind = {}

        local function stmtFor(sql)
            local stmt = {}
            function stmt:bind(...)
                last_bind[sql] = { ... }
            end
            function stmt:step()
                if sql:find("INSERT INTO book_tracking_state", 1, true) then
                    local args = last_bind[sql]
                    tracking_rows[1] = {
                        file_hash = args[1],
                        file_path = args[2],
                        tracking_enabled = tonumber(args[3]) == 1,
                    }
                end
                return 101
            end
            function stmt:rows()
                local emitted = false
                return function()
                    if emitted then return nil end
                    emitted = true
                    if sql:find("FROM book_tracking_state", 1, true) then
                        if tracking_rows[1] then
                            return {
                                1,
                                tracking_rows[1].file_hash,
                                tracking_rows[1].file_path,
                                tracking_rows[1].tracking_enabled and 1 or 0,
                                os.time(),
                                os.time(),
                            }
                        end
                        return nil
                    end
                    return nil
                end
            end
            function stmt:close() end
            return stmt
        end

        local db = setmetatable({
            conn = {
                prepare = function(_, sql)
                    return stmtFor(sql)
                end,
                exec = function()
                    return 0
                end,
            },
        }, { __index = Database })

        assert.is_true(db:isTrackingEnabled("hash-1", "/book.epub"))
        assert.is_true(db:setTrackingEnabled("hash-1", "/book.epub", false))
        assert.is_false(db:isTrackingEnabled("hash-1", "/book.epub"))
        local toggled = db:toggleTracking("hash-1", "/book.epub")
        assert.is_true(toggled)
        assert.is_true(db:isTrackingEnabled("hash-1", "/book.epub"))
    end)
end)
