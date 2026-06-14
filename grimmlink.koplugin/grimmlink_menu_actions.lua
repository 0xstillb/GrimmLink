local _ = require("gettext")
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local function fallbackTemplate(text, ...)
    local args = { ... }
    return (tostring(text or ""):gsub("%%(%d+)", function(index)
        local value = args[tonumber(index)]
        return value == nil and "" or tostring(value)
    end))
end
local T = ok_ffiutil and ffiutil and ffiutil.template or fallbackTemplate
local M = {}

function M.new()
    local o = {}
    setmetatable(o, { __index = M })
    return o
end

function M:buildFileManagerActionItems(plugin, path_resolver)
    local resolve = path_resolver
    local function filePath()
        if type(resolve) == "function" then
            local ok, value = pcall(resolve)
            if ok and value and value ~= "" then
                return tostring(value)
            end
        end
        return nil
    end

    local function requireFilePath()
        local file_path = filePath()
        if file_path then
            return file_path
        end
        plugin:showMessage(_("Long-press on a book file first"), 3)
        return nil
    end

    local actions = {
        { text = _("GrimmLink: Sync This Book"), method = "syncThisBookFromPath" },
        { text = _("GrimmLink: Toggle Tracking"), method = "toggleTrackingByPath" },
        { text = _("GrimmLink: Match Book"), method = "matchBookByPath" },
        { text = _("GrimmLink: Show Debug Info"), method = "showBookDebugInfoByPath" },
    }

    local items = {}
    for _, action in ipairs(actions) do
        items[#items + 1] = {
            text = action.text,
            callback = function()
                local file_path = requireFilePath()
                if not file_path then
                    return
                end
                local fn = plugin and plugin[action.method]
                if type(fn) == "function" then
                    fn(plugin, file_path)
                end
            end,
        }
    end
    return items
end

function M:isReaderBookContext(plugin)
    local session = plugin and plugin.current_session or nil
    return session ~= nil and session.book_id ~= nil and session.file_path ~= nil
end

function M:showSyncSummary(plugin, safe_db_value_call)
    if not plugin or not plugin.db then
        if plugin and type(plugin.showMessage) == "function" then
            plugin:showMessage(_("Database not available"), 3)
        end
        return
    end

    local db = plugin.db
    local pending_progress = type(db.getPendingProgressCount) == "function" and db:getPendingProgressCount() or 0
    local pending_sessions = type(db.getPendingSessionCount) == "function" and db:getPendingSessionCount() or 0
    local pending_metadata = 0
    if type(safe_db_value_call) == "function" then
        pending_metadata = safe_db_value_call(db, "getPendingMetadataCount", 0)
    elseif type(db.getPendingMetadataCount) == "function" then
        pending_metadata = db:getPendingMetadataCount()
    end

    plugin:showMessage(T(
        _("Pending progress: %1\nPending sessions: %2\nPending metadata: %3"),
        pending_progress,
        pending_sessions,
        pending_metadata
    ), 3)
end

function M:buildStatusItems(plugin, options)
    options = options or {}
    local sync_summary_callback = options.sync_summary_callback
    if type(sync_summary_callback) ~= "function" then
        sync_summary_callback = function()
            self:showSyncSummary(plugin, options.safe_db_value_call)
        end
    end

    local items = {
        {
            text = _("Show About"),
            callback = function()
                plugin:showAbout()
            end,
        },
        {
            text = _("Export GrimmLink Debug Info"),
            callback = function()
                plugin:exportDebugInfo()
            end,
        },
        {
            text = _("Export Local Diagnostics Bundle"),
            callback = function()
                plugin:exportLocalDiagnosticsBundle()
            end,
        },
        {
            text = _("Sync Summary"),
            callback = sync_summary_callback,
        },
    }

    local load_errors = options.load_errors
    if type(load_errors) == "table" and #load_errors > 0 then
        items[#items + 1] = {
            text = _("Load Errors"),
            callback = function()
                plugin:showMessage(table.concat(load_errors, "\n"), 8)
            end,
        }
    end
    return items
end

function M:applyReaderBookTopLevelOverrides(plugin, sub_items, options)
    if type(sub_items) ~= "table" then
        return
    end
    options = options or {}
    local remove_ids = options.remove_ids or {
        connection = true,
        sync_shelf_now = true,
        advanced_setting = true,
        status_about = true,
    }
    for i = #sub_items, 1, -1 do
        local item = sub_items[i]
        if item and item.id and remove_ids[item.id] then
            table.remove(sub_items, i)
        end
    end

    local sync_summary_callback = options.sync_summary_callback
    if type(sync_summary_callback) ~= "function" then
        sync_summary_callback = function()
            self:showSyncSummary(plugin, options.safe_db_value_call)
        end
    end

    local injected = {
        {
            id = "reading_completion",
            text = _("Reading Completion"),
            callback = function()
                plugin:showReadingCompletionMenu()
            end,
        },
        {
            id = "pull_remote_progress",
            text = _("Pull Remote Progress"),
            callback = function()
                plugin:manualPullProgress()
            end,
        },
        {
            id = "preview_metadata",
            text = _("Preview Metadata"),
            callback = function()
                plugin:showMetadataPreview()
            end,
        },
        {
            id = "sync_metadata_now",
            text = _("Sync Metadata Now"),
            callback = function()
                plugin:syncMetadataNow()
            end,
        },
        {
            id = "force_metadata_reupload",
            text = _("Force Metadata Re-upload"),
            callback = function()
                plugin:forceMetadataResyncForCurrentBook()
            end,
        },
        {
            id = "pull_remote_metadata",
            text = _("Pull Remote Metadata Now"),
            callback = function()
                plugin:pullRemoteMetadataNow(false, 100)
            end,
        },
        {
            id = "manual_reading_status",
            text = _("Manual Reading Status"),
            callback = function()
                plugin:showManualReadStatusMenu()
            end,
        },
        {
            id = "sync_summary",
            text = _("Sync Summary"),
            callback = sync_summary_callback,
        },
    }

    local pos = tonumber(options.insert_pos) or 3
    for _, item in ipairs(injected) do
        table.insert(sub_items, pos, item)
        pos = pos + 1
    end
end

function M:buildMaintenanceItem(plugin)
    return {
        text = _("Maintenance"),
        sub_item_table = {
            {
                text = _("Quick Actions"),
                sub_item_table = {
                    {
                        text = _("Sync Metadata Now"),
                        callback = function()
                            plugin:syncMetadataNow()
                        end,
                    },
                    {
                        text = _("Pull Remote Metadata Now"),
                        callback = function() plugin:pullRemoteMetadataNow(false, 100) end,
                    },
                    {
                        text = _("Show DB Status / Pending Counts"),
                        callback = function() plugin:showDatabaseStatus() end,
                    },
                    {
                        text = _("Import KOReader Reading History"),
                        callback = function() plugin:promptHistoricalImport() end,
                    },
                    {
                        text = _("Export Local Diagnostics Bundle"),
                        callback = function() plugin:exportLocalDiagnosticsBundle() end,
                    },
                    {
                        text = _("Export GrimmLink Debug Info"),
                        callback = function() plugin:exportDebugInfo() end,
                    },
                },
            },
            {
                text = _("Current Book Tools"),
                sub_item_table = {
                    {
                        text = _("Rebuild metadata queue for current book"),
                        callback = function() plugin:rebuildMetadataQueueForCurrentBook() end,
                    },
                    {
                        text = _("Force resync metadata for current book"),
                        callback = function() plugin:forceMetadataResyncForCurrentBook() end,
                    },
                    {
                        text = _("Pull remote metadata for current book"),
                        callback = function() plugin:pullRemoteMetadataForCurrentBook(false, 100) end,
                    },
                    {
                        text = _("Reset metadata pull cursor for current book"),
                        callback = function() plugin:resetMetadataPullCursorForCurrentBook() end,
                    },
                    {
                        text = _("Re-match current book"),
                        callback = function() plugin:rematchCurrentBook() end,
                    },
                },
            },
            {
                text = _("Cleanup"),
                sub_item_table = {
                    {
                        text = _("Quick Cleanup"),
                        callback = function() plugin:runQuickCleanupWithConfirm() end,
                    },
                    {
                        text = _("Clear Sync Queues"),
                        callback = function() plugin:clearSyncQueuesWithConfirm() end,
                    },
                    {
                        text = _("Clear Logs"),
                        callback = function() plugin:clearLogsWithConfirm() end,
                    },
                },
            },
            {
                text = _("Rebuild Caches"),
                sub_item_table = {
                    {
                        text = _("Rebuild SimpleUI metadata cache"),
                        callback = function()
                            if not plugin.shelf_sync or not plugin.download_dir then
                                plugin:showMessage(_("Shelf sync not configured."), 3)
                                return
                            end
                            local counts = plugin.shelf_sync:rebuildBookInfoCacheFromIndex(
                                plugin.shelf_sync:resolveDownloadDir(plugin.download_dir))
                            if counts.error then
                                plugin:showMessage(T(_("Rebuild failed: %1"), counts.error), 4)
                            else
                                plugin:showMessage(T(
                                    _("Rebuild complete\nInserted: %1  Updated: %2  Skipped: %3"),
                                    counts.inserted, counts.updated, counts.skipped), 5)
                            end
                        end,
                    },
                },
            },
            {
                text = _("Advanced Cleanup"),
                sub_item_table = {
                    { text = _("Clear Update Cache"), callback = function() plugin:clearUpdateCacheWithConfirm() end },
                    { text = _("Clear Unmatched Book Cache"), callback = function() plugin:clearUnmatchedBookCacheWithConfirm() end },
                    { text = _("Clear All Book Cache"), callback = function() plugin:clearAllBookCacheWithConfirm() end },
                    { text = _("Clear Not Found Hashes"), callback = function() plugin:clearNotFoundHashesWithConfirm() end },
                    { text = _("Clear Pending Progress"), callback = function() plugin:clearPendingProgressQueueWithConfirm() end },
                    { text = _("Clear Pending Sessions"), callback = function() plugin:clearPendingSessionsQueueWithConfirm() end },
                    { text = _("Clear Pending Metadata"), callback = function() plugin:clearPendingMetadataQueueWithConfirm() end },
                    { text = _("Clear Synced Metadata History"), callback = function() plugin:clearSyncedMetadataHistoryWithConfirm() end },
                    { text = _("Clear Shelf Tombstones"), callback = function() plugin:clearShelfTombstonesWithConfirm() end },
                    { text = _("Clear Pending Shelf Removals"), callback = function() plugin:clearPendingShelfRemovalsWithConfirm() end },
                },
            },
        },
    }
end

return M
