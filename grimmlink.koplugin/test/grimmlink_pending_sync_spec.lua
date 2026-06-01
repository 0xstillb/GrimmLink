package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./test/?.lua",
    package.path,
}, ";")

package.preload["gettext"] = function()
    return function(text)
        return text
    end
end

package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                local value = values[tonumber(index)]
                if value == nil then
                    return ""
                end
                return tostring(value)
            end))
        end,
    }
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end

package.loaded["grimmlink_pending_sync"] = nil
local pending_sync = require("grimmlink_pending_sync").new()

describe("grimmlink_pending_sync", function()
    it("syncs pending queues and shows summary message", function()
        local calls = {
            extract = 0,
            wifi_prompt = 0,
            require_ready = 0,
            sync_progress = 0,
            sync_sessions = 0,
            sync_metadata = 0,
            show = 0,
        }
        local plugin = {
            getCurrentDocumentContext = function() return { file_hash = "h1" } end,
            isTrackingEnabledForContext = function() return true end,
            extractAndQueueCurrentMetadata = function() calls.extract = calls.extract + 1 end,
            isOnline = function() return true end,
            maybePromptEnableWifiForManualSync = function() calls.wifi_prompt = calls.wifi_prompt + 1 end,
            requireReady = function()
                calls.require_ready = calls.require_ready + 1
                return true
            end,
            syncPendingProgress = function(_, _, limit)
                calls.sync_progress = calls.sync_progress + 1
                calls.progress_limit = limit
                return 2, 1
            end,
            syncPendingSessions = function(_, _, limit)
                calls.sync_sessions = calls.sync_sessions + 1
                calls.session_limit = limit
                return 3, 0
            end,
            syncPendingMetadata = function(_, _, limit)
                calls.sync_metadata = calls.sync_metadata + 1
                calls.metadata_limit = limit
                return 4, 1
            end,
            showMessage = function()
                calls.show = calls.show + 1
            end,
        }

        pending_sync:syncPendingNow(plugin, false, {
            progress_limit = 10,
            session_limit = 20,
            metadata_limit = 30,
        })

        assert.are.equal(1, calls.extract)
        assert.are.equal(0, calls.wifi_prompt)
        assert.are.equal(1, calls.require_ready)
        assert.are.equal(1, calls.sync_progress)
        assert.are.equal(1, calls.sync_sessions)
        assert.are.equal(1, calls.sync_metadata)
        assert.are.equal(10, calls.progress_limit)
        assert.are.equal(20, calls.session_limit)
        assert.are.equal(30, calls.metadata_limit)
        assert.are.equal(1, calls.show)
    end)

    it("prompts for wifi and skips queue processing when offline in manual mode", function()
        local calls = { wifi_prompt = 0, require_ready = 0, sync_progress = 0 }
        local plugin = {
            getCurrentDocumentContext = function() return { file_hash = "h2" } end,
            isTrackingEnabledForContext = function() return true end,
            extractAndQueueCurrentMetadata = function() end,
            isOnline = function() return false end,
            maybePromptEnableWifiForManualSync = function() calls.wifi_prompt = calls.wifi_prompt + 1 end,
            requireReady = function()
                calls.require_ready = calls.require_ready + 1
                return true
            end,
            syncPendingProgress = function()
                calls.sync_progress = calls.sync_progress + 1
                return 0, 0
            end,
            syncPendingSessions = function() return 0, 0 end,
            syncPendingMetadata = function() return 0, 0 end,
            showMessage = function() end,
        }

        pending_sync:syncPendingNow(plugin, false, {})
        assert.are.equal(1, calls.wifi_prompt)
        assert.are.equal(0, calls.require_ready)
        assert.are.equal(0, calls.sync_progress)
    end)

    it("reads queue summary counters with safe defaults", function()
        local plugin = {
            db = {
                getPendingProgressCount = function() return 5 end,
                getPendingSessionCount = function() return 4 end,
                getPendingMetadataCount = function() return 3 end,
                getPendingShelfRemovalCount = function() return 2 end,
            },
        }
        local counters = pending_sync:getQueueSummaryCounters(plugin)
        assert.are.same({
            pending_progress = 5,
            pending_sessions = 4,
            pending_metadata = 3,
            pending_shelf_removals = 2,
        }, counters)
    end)

    it("retries pending shelf removals on remote delete failure", function()
        local retry_called = 0
        local plugin = {
            db = {
                getPendingShelfRemovals = function()
                    return {
                        {
                            book_id = 12,
                            shelf_id = 99,
                            shelf_type = "regular",
                            local_path = "/books/fail.epub",
                            retry_count = 0,
                        },
                    }
                end,
                incrementPendingShelfRemovalRetryCount = function()
                    retry_called = retry_called + 1
                    return true
                end,
            },
            api = {
                removeBookFromShelf = function()
                    return false, "network_fail"
                end,
            },
        }

        local result = { deleted = 0, failed = 0, errors = {} }
        local skip_ids = {}
        pending_sync:processPendingShelfRemovals(plugin, {
            shelf_id = 99,
            shelf_type = "regular",
            skip_download_ids = skip_ids,
            result = result,
        })

        assert.are.equal(1, retry_called)
        assert.are.equal(1, result.failed)
        assert.is_true(skip_ids["12"] == true)
        assert.is_true(#result.errors > 0)
    end)

    it("respects retry cooldown for pending shelf removals", function()
        local remove_called = 0
        local plugin = {
            db = {
                getPendingShelfRemovals = function()
                    return {
                        {
                            book_id = 55,
                            shelf_id = 2,
                            shelf_type = "magic",
                            local_path = "/books/cooldown.epub",
                            retry_count = 2,
                            last_retry_at = 100,
                        },
                    }
                end,
            },
            api = {
                removeBookFromShelf = function()
                    remove_called = remove_called + 1
                    return true, {}
                end,
            },
        }

        local result = { deleted = 0, failed = 0, errors = {} }
        pending_sync:processPendingShelfRemovals(plugin, {
            shelf_id = 2,
            shelf_type = "magic",
            result = result,
            now_ts = 120,
            retry_cooldown_seconds = 30,
        })

        assert.are.equal(0, remove_called)
        assert.are.equal(0, result.failed)
        assert.are.equal(0, result.deleted)
    end)

    it("uses plugin cooldown setting when args cooldown is omitted", function()
        local remove_called = 0
        local plugin = {
            pending_shelf_removal_retry_cooldown_seconds = 45,
            db = {
                getPendingShelfRemovals = function()
                    return {
                        {
                            book_id = 89,
                            shelf_id = 3,
                            shelf_type = "regular",
                            local_path = "/books/cooldown-setting.epub",
                            retry_count = 1,
                            last_retry_at = 100,
                        },
                    }
                end,
            },
            api = {
                removeBookFromShelf = function()
                    remove_called = remove_called + 1
                    return true, {}
                end,
            },
        }

        pending_sync:processPendingShelfRemovals(plugin, {
            shelf_id = 3,
            shelf_type = "regular",
            result = { deleted = 0, failed = 0, errors = {} },
            now_ts = 130,
        })

        assert.are.equal(0, remove_called)
    end)

    it("deletes pending shelf removal and local mapping when remote delete succeeds", function()
        local delete_local_calls = 0
        local delete_pending_calls = 0
        local remove_metadata_calls = 0
        local plugin = {
            db = {
                getPendingShelfRemovals = function()
                    return {
                        {
                            book_id = 77,
                            shelf_id = 5,
                            shelf_type = "regular",
                            local_path = "/books/ok.epub",
                            retry_count = 0,
                        },
                    }
                end,
                getShelfMapping = function()
                    return {
                        book_id = 77,
                        shelf_id = 5,
                        shelf_type = "regular",
                        local_path = "/books/ok.epub",
                        downloaded_by_grimmlink = 1,
                    }
                end,
                isBookTrackedInOtherShelf = function()
                    return false
                end,
                deletePendingShelfRemoval = function()
                    delete_pending_calls = delete_pending_calls + 1
                    return true
                end,
            },
            api = {
                removeBookFromShelf = function()
                    return true, {}
                end,
            },
            shelf_sync = {
                deleteLocalBook = function()
                    delete_local_calls = delete_local_calls + 1
                    return true
                end,
                removeBookMetadata = function()
                    remove_metadata_calls = remove_metadata_calls + 1
                end,
            },
        }

        local result = { deleted = 0, failed = 0, errors = {} }
        pending_sync:processPendingShelfRemovals(plugin, {
            shelf_id = 5,
            shelf_type = "regular",
            download_dir = "/books",
            delete_sdr = false,
            result = result,
        })

        assert.are.equal(1, delete_local_calls)
        assert.are.equal(1, delete_pending_calls)
        assert.are.equal(1, remove_metadata_calls)
        assert.are.equal(1, result.deleted)
        assert.are.equal(0, result.failed)
    end)

    it("supports mark-only mode without network deletion", function()
        local remove_called = 0
        local plugin = {
            db = {
                getPendingShelfRemovals = function()
                    return {
                        { book_id = 1, shelf_id = 8, shelf_type = "regular", retry_count = 0 },
                        { book_id = 2, shelf_id = 8, shelf_type = "regular", retry_count = 0 },
                    }
                end,
            },
            api = {
                removeBookFromShelf = function()
                    remove_called = remove_called + 1
                    return true, {}
                end,
            },
        }
        local skip_ids = {}
        local counters = {}
        pending_sync:processPendingShelfRemovals(plugin, {
            shelf_id = 8,
            shelf_type = "regular",
            mark_only = true,
            skip_download_ids = skip_ids,
            counters = counters,
            result = { deleted = 0, failed = 0, errors = {} },
        })

        assert.are.equal(0, remove_called)
        assert.is_true(skip_ids["1"] == true)
        assert.is_true(skip_ids["2"] == true)
        assert.are.equal(true, counters.mark_only)
    end)

    it("limits pending-removal processing by max_entries", function()
        local remove_called = 0
        local plugin = {
            db = {
                getPendingShelfRemovals = function()
                    return {
                        { book_id = 10, shelf_id = 4, shelf_type = "regular", retry_count = 0 },
                        { book_id = 11, shelf_id = 4, shelf_type = "regular", retry_count = 0 },
                    }
                end,
                deletePendingShelfRemoval = function() return true end,
            },
            api = {
                removeBookFromShelf = function()
                    remove_called = remove_called + 1
                    return true, {}
                end,
            },
        }

        local counters = {}
        pending_sync:processPendingShelfRemovals(plugin, {
            shelf_id = 4,
            shelf_type = "regular",
            max_entries = 1,
            counters = counters,
            result = { deleted = 0, failed = 0, errors = {} },
        })

        assert.are.equal(1, remove_called)
        assert.are.equal(1, counters.processed)
        assert.are.equal(2, counters.pending_total)
    end)
end)
