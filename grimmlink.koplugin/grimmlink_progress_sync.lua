local _ = require("gettext")
local M = {}

function M.new()
    local o = {}
    setmetatable(o, { __index = M })
    return o
end

function M:syncThisBookFromPath(plugin, file_path)
    local context = plugin:resolveBookContextByPath(file_path)
    if not context then
        plugin:showMessage(_("No file selected"), 3)
        return
    end
    if not plugin:isTrackingEnabled(context.file_hash, context.file_path) then
        plugin:showTrackingDisabledMessage()
        return
    end

    if plugin.current_session and plugin.current_session.file_path == context.file_path then
        local snapshot = plugin:getCurrentProgressSnapshot(
            plugin.current_session.file_hash,
            plugin.current_session.file_path,
            plugin.current_session.book_id,
            plugin.current_session.book_file_id
        )
        plugin:pushProgressSnapshot(snapshot, "manual", false)
        plugin:syncPendingNow(false, { progress_limit = 20, session_limit = 50 })
    else
        plugin:showMessage(_("Open the book to sync progress"), 3)
    end
end

function M:pullRemoteProgressFromPath(plugin, file_path)
    if not plugin.current_session or plugin.current_session.file_path ~= file_path then
        plugin:showMessage(_("Open the book first to pull progress"), 3)
        return
    end
    if not plugin:isTrackingEnabled(plugin.current_session.file_hash, plugin.current_session.file_path) then
        plugin:showTrackingDisabledMessage()
        return
    end
    plugin:manualPullProgress()
end

function M:buildProgressPayload(snapshot, reason)
    if type(snapshot) ~= "table" then
        return nil
    end
    return {
        bookHash = snapshot.bookHash,
        bookId = snapshot.bookId,
        bookFileId = snapshot.bookFileId,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        currentPage = snapshot.currentPage,
        totalPages = snapshot.totalPages,
        timestamp = snapshot.timestamp,
        fileFormat = snapshot.fileFormat,
        reason = reason or "manual",
    }
end

return M
