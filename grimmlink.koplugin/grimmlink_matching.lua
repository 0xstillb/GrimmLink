local _ = require("gettext")
local T = require("ffi/util").template
local M = {}

function M.new()
    local o = {}
    setmetatable(o, { __index = M })
    return o
end

local function sanitizeTitle(value)
    local text = tostring(value or "")
    if text == "" then
        return "Unknown"
    end
    local title = text:match("([^/\\]+)$") or text
    return title:gsub("%.[^.]+$", "")
end

function M:buildMatchResult(state, data)
    return {
        state = state,
        data = data or {},
    }
end

function M:resolveBookContextByPath(plugin, file_path)
    if not file_path or file_path == "" then
        return nil
    end
    local cached = plugin:resolveBookByFilePath(file_path)
    local file_hash = cached and cached.file_hash or nil
    if (not file_hash or file_hash == "") and type(plugin.calculateBookHash) == "function" then
        local ok_hash, hash = pcall(plugin.calculateBookHash, plugin, file_path)
        if ok_hash then
            file_hash = hash
        end
    end
    local book_id = cached and cached.book_id or nil
    local book_file_id = cached and cached.book_file_id or nil
    return {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
    }
end

function M:matchBookByPath(plugin, file_path, options)
    options = options or {}
    local force_rematch = options.force == true
    local context = self:resolveBookContextByPath(plugin, file_path)
    if not context or not context.file_hash then
        plugin:showMessage(_("Could not calculate book hash"), 3)
        return self:buildMatchResult("error", { reason = "hash_unavailable" })
    end

    local cached = plugin.db and plugin.db:getBookByHash(context.file_hash) or nil
    if cached and cached.book_id and not force_rematch then
        plugin:showMessage(T(_("Book already matched: %1"), cached.book_id), 3)
        return self:buildMatchResult("matched", { source = "cache", book_id = cached.book_id })
    end

    local remote_matched = nil
    if plugin:isOnline() and plugin:isApiReady({ "getBookByHash" }) and plugin:refreshApiClient() then
        local ok_lookup, book = plugin.api:getBookByHash(context.file_hash)
        if ok_lookup and type(book) == "table" and book.id then
            remote_matched = tonumber(book.id) or book.id
        end
    end

    if remote_matched then
        plugin.db:saveBookCache(file_path, context.file_hash, remote_matched, sanitizeTitle(file_path), nil)
        plugin:showMessage(force_rematch and T(_("Re-matched by hash: %1"), remote_matched) or T(_("Matched by hash: %1"), remote_matched), 3)
        return self:buildMatchResult("matched", { source = "remote_hash", book_id = remote_matched })
    end

    plugin:showTextInput(_("Manual Book ID"), "", _("Enter Grimmory book id"), false, function(value)
        local manual_id = tonumber(value)
        if not manual_id then
            plugin:showMessage(_("Invalid book id"), 3)
            return
        end
        plugin.db:saveBookCache(file_path, context.file_hash, manual_id, sanitizeTitle(file_path), nil)
        plugin:showMessage(T(_("Book mapping saved: %1"), manual_id), 3)
    end)

    return self:buildMatchResult("not_found", { reason = "manual_input_requested" })
end

return M
