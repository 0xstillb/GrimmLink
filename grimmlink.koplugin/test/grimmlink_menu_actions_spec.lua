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

package.loaded["grimmlink_menu_actions"] = nil
local menu_actions = require("grimmlink_menu_actions").new()

local function findMenuItem(items, expected_text)
    for _, item in ipairs(items or {}) do
        if item.text == expected_text then
            return item
        end
    end
    return nil
end

describe("grimmlink_menu_actions", function()
    it("builds file manager actions with unchanged labels", function()
        local plugin = {
            showMessage = function() end,
            syncThisBookFromPath = function() end,
            toggleTrackingByPath = function() end,
            matchBookByPath = function() end,
            showBookDebugInfoByPath = function() end,
        }

        local items = menu_actions:buildFileManagerActionItems(plugin, function()
            return "/books/title.epub"
        end)
        local labels = {}
        for _, item in ipairs(items) do
            labels[#labels + 1] = item.text
        end

        assert.are.same({
            "GrimmLink: Sync This Book",
            "GrimmLink: Toggle Tracking",
            "GrimmLink: Match Book",
            "GrimmLink: Show Debug Info",
        }, labels)
    end)

    it("builds status items and includes load errors when present", function()
        local messages = {}
        local plugin = {
            db = {
                getPendingProgressCount = function() return 1 end,
                getPendingSessionCount = function() return 2 end,
                getPendingMetadataCount = function() return 3 end,
            },
            showAbout = function() end,
            exportDebugInfo = function() end,
            exportLocalDiagnosticsBundle = function() end,
            showMessage = function(_, text)
                messages[#messages + 1] = text
            end,
        }

        local items = menu_actions:buildStatusItems(plugin, {
            load_errors = { "a", "b" },
        })

        assert.are.equal(5, #items)
        assert.are.equal("Show About", items[1].text)
        assert.are.equal("Export GrimmLink Debug Info", items[2].text)
        assert.are.equal("Export Local Diagnostics Bundle", items[3].text)
        assert.are.equal("Sync Summary", items[4].text)
        assert.are.equal("Load Errors", items[5].text)

        items[4].callback()
        items[5].callback()
        assert.is_true(#messages >= 2)
    end)

    it("detects reader book context correctly", function()
        local plugin = { current_session = nil }
        assert.is_false(menu_actions:isReaderBookContext(plugin))

        plugin.current_session = { book_id = 10, file_path = "/book.epub" }
        assert.is_true(menu_actions:isReaderBookContext(plugin))
    end)

    it("applies reader-book top-level overrides by id", function()
        local called = {}
        local plugin = {
            showReadingCompletionMenu = function() called.completion = true end,
            manualPullProgress = function() called.pull = true end,
            showMetadataPreview = function() called.preview = true end,
            syncMetadataNow = function() called.sync_metadata = true end,
            pullRemoteMetadataNow = function(_, silent, limit)
                called.metadata = silent == false and limit == 100
            end,
            showManualReadStatusMenu = function() called.status = true end,
            showMessage = function() called.summary = true end,
            db = {
                getPendingProgressCount = function() return 0 end,
                getPendingSessionCount = function() return 0 end,
                getPendingMetadataCount = function() return 0 end,
            },
        }
        local sub_items = {
            { id = "enable_grimmlink", text = "Enable" },
            { id = "connection", text = "Connection" },
            { id = "sync_pending_now", text = "Sync Pending" },
            { id = "sync_shelf_now", text = "Sync Shelf" },
            { id = "advanced_setting", text = "Advanced" },
            { id = "status_about", text = "Status" },
        }

        menu_actions:applyReaderBookTopLevelOverrides(plugin, sub_items, {})

        local ids = {}
        for _, item in ipairs(sub_items) do
            ids[#ids + 1] = item.id
        end
        assert.are.same({
            "enable_grimmlink",
            "sync_pending_now",
            "reading_completion",
            "pull_remote_progress",
            "preview_metadata",
            "sync_metadata_now",
            "pull_remote_metadata",
            "manual_reading_status",
            "sync_summary",
        }, ids)

        sub_items[3].callback()
        sub_items[4].callback()
        sub_items[5].callback()
        sub_items[6].callback()
        sub_items[7].callback()
        sub_items[8].callback()
        sub_items[9].callback()
        assert.is_true(called.completion == true)
        assert.is_true(called.pull == true)
        assert.is_true(called.preview == true)
        assert.is_true(called.sync_metadata == true)
        assert.is_true(called.metadata == true)
        assert.is_true(called.status == true)
        assert.is_true(called.summary == true)
    end)

    it("builds Maintenance menu sections", function()
        local plugin = {
            current_session = { book_id = 1 },
            syncMetadataNow = function() end,
            showDatabaseStatus = function() end,
            promptHistoricalImport = function() end,
            exportLocalDiagnosticsBundle = function() end,
            exportDebugInfo = function() end,
            rebuildMetadataQueueForCurrentBook = function() end,
            forceMetadataResyncForCurrentBook = function() end,
            rematchCurrentBook = function() end,
            runQuickCleanupWithConfirm = function() end,
            clearSyncQueuesWithConfirm = function() end,
            clearLogsWithConfirm = function() end,
            showMessage = function() end,
            shelf_sync = {
                resolveDownloadDir = function() return "/books" end,
                rebuildBookInfoCacheFromIndex = function()
                    return { inserted = 0, updated = 0, skipped = 0 }
                end,
            },
            download_dir = "/books",
            clearUpdateCacheWithConfirm = function() end,
            clearUnmatchedBookCacheWithConfirm = function() end,
            clearAllBookCacheWithConfirm = function() end,
            clearNotFoundHashesWithConfirm = function() end,
            clearPendingProgressQueueWithConfirm = function() end,
            clearPendingSessionsQueueWithConfirm = function() end,
            clearPendingMetadataQueueWithConfirm = function() end,
            clearSyncedMetadataHistoryWithConfirm = function() end,
            clearShelfTombstonesWithConfirm = function() end,
            clearPendingShelfRemovalsWithConfirm = function() end,
        }

        local item = menu_actions:buildMaintenanceItem(plugin)
        assert.are.equal("Maintenance", item.text)
        assert.are.equal(5, #(item.sub_item_table or {}))
        assert.are.equal("Quick Actions", item.sub_item_table[1].text)
        assert.are.equal("Current Book Tools", item.sub_item_table[2].text)
        assert.are.equal("Cleanup", item.sub_item_table[3].text)
        assert.are.equal("Rebuild Caches", item.sub_item_table[4].text)
        assert.are.equal("Advanced Cleanup", item.sub_item_table[5].text)
        assert.is_not_nil(findMenuItem(item.sub_item_table[1].sub_item_table, "Import KOReader Reading History"))
        assert.is_not_nil(findMenuItem(item.sub_item_table[1].sub_item_table, "Export Local Diagnostics Bundle"))
    end)
end)
