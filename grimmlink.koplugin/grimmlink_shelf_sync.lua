local DataStorage = require("datastorage")
local lfs = require("lfs")
local logger = require("logger")

local ShelfSync = {}
ShelfSync.__index = ShelfSync

function ShelfSync:new(db, api)
    local o = { db = db, api = api }
    setmetatable(o, self)
    return o
end

-- Sanitize a filename: strip path separators, control chars, collapse spaces,
-- truncate to max_len characters.
local function sanitizeFilename(name, max_len)
    max_len = max_len or 200
    if not name or name == "" then return nil end
    -- Replace path separators and control characters with underscores
    local s = name:gsub("[/\\%c]", "_")
    -- Collapse multiple underscores
    s = s:gsub("_+", "_")
    -- Strip leading/trailing dots and spaces (dangerous on Windows)
    s = s:match("^[%. ]*(.-)[ %.]*$") or s
    if #s > max_len then
        s = s:sub(1, max_len)
    end
    return s ~= "" and s or nil
end

local function normalizePathForCompare(path)
    if not path or path == "" then
        return nil
    end

    local normalized = tostring(path):gsub("\\", "/")
    normalized = normalized:gsub("/+", "/")
    if #normalized > 1 then
        normalized = normalized:gsub("/$", "")
    end
    return normalized
end

local function joinPath(base, child)
    if not base or base == "" then
        return child
    end
    local sep = base:sub(-1) == "/" and "" or "/"
    return base .. sep .. child
end

local function ensureDirectory(path)
    if not path or path == "" then
        return false
    end

    local attr = lfs.attributes(path)
    if attr and attr.mode == "directory" then
        return true
    end

    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and not ensureDirectory(parent) then
        return false
    end

    local ok, err = lfs.mkdir(path)
    if ok then
        return true
    end

    attr = lfs.attributes(path)
    return attr and attr.mode == "directory" or false
end

local function isPathUnderDirectory(path, root_dir)
    local normalized_path = normalizePathForCompare(path)
    local normalized_root = normalizePathForCompare(root_dir)
    if not normalized_path or not normalized_root then
        return false
    end
    return normalized_path == normalized_root
        or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

-- Build a safe local filename for a book.
-- Prefers the remote filename when use_original is true and remote_filename is set.
-- Falls back to title + book_id + extension.
function ShelfSync:buildSafeFilename(book_info, use_original)
    if use_original and book_info.fileName and book_info.fileName ~= "" then
        local sanitized = sanitizeFilename(book_info.fileName)
        if sanitized then return sanitized end
    end

    local ext = book_info.fileFormat and book_info.fileFormat:lower() or "epub"
    local base = ""
    if book_info.title and book_info.title ~= "" then
        base = sanitizeFilename(book_info.title) or ("book_" .. tostring(book_info.bookId))
    else
        base = "book_" .. tostring(book_info.bookId)
    end

    return base .. "_" .. tostring(book_info.bookId) .. "." .. ext
end

-- Resolve the download directory.
-- Uses the explicit setting if provided and writable; otherwise auto-detects.
function ShelfSync:resolveDownloadDir(setting_value)
    if setting_value and setting_value ~= "" then
        local attr = lfs.attributes(setting_value)
        if attr and attr.mode == "directory" then
            return setting_value
        end
        logger.warn("GrimmLink ShelfSync: configured download_dir not accessible:", setting_value)
    end

    -- Auto-detect a sensible KOReader books directory, then dedicate a
    -- subfolder to GrimmLink downloads so synced books stay grouped together.
    local data_dir = DataStorage:getDataDir()
    local candidates = {
        data_dir .. "/books",
        data_dir,
    }
    for _, dir in ipairs(candidates) do
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            local book_dir = joinPath(dir, "Book")
            if ensureDirectory(book_dir) then
                return book_dir
            end
            return dir
        end
    end

    -- Last resort: settings dir
    local fallback_dir = joinPath(DataStorage:getSettingsDir(), "Book")
    if ensureDirectory(fallback_dir) then
        return fallback_dir
    end
    return DataStorage:getSettingsDir()
end

-- Generate a unique filename in dir, avoiding collisions.
local function uniquePath(dir, filename)
    local sep = dir:sub(-1) == "/" and "" or "/"
    local full = dir .. sep .. filename
    if not lfs.attributes(full) then return full end

    -- Split basename and extension
    local base, ext = filename:match("^(.+)%.([^%.]+)$")
    if not base then
        base = filename
        ext = nil
    end

    local counter = 2
    while counter < 1000 do
        local candidate
        if ext then
            candidate = dir .. sep .. base .. "_" .. counter .. "." .. ext
        else
            candidate = dir .. sep .. base .. "_" .. counter
        end
        if not lfs.attributes(candidate) then return candidate end
        counter = counter + 1
    end
    return full -- give up; let the download overwrite
end

local function deletePathRecursive(path)
    local attr = lfs.attributes(path)
    if not attr then
        return true
    end

    if attr.mode == "file" then
        return os.remove(path) and true or false
    end

    if attr.mode ~= "directory" then
        return false
    end

    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local child = path .. "/" .. entry
            if not deletePathRecursive(child) then
                return false
            end
        end
    end

    return lfs.rmdir(path) and true or false
end

local function getSdrCandidatePaths(local_path)
    local candidates = { local_path .. ".sdr" }
    local base_path = local_path:match("^(.*)%.([^/\\]+)$")
    if base_path then
        local legacy_path = base_path .. ".sdr"
        if legacy_path ~= candidates[1] then
            candidates[#candidates + 1] = legacy_path
        end
    end
    return candidates
end

-- Delete a .sdr sidecar directory if it exists.
local function deleteSdr(local_path)
    for _, sdr_path in ipairs(getSdrCandidatePaths(local_path)) do
        local attr = lfs.attributes(sdr_path)
        if attr and attr.mode == "directory" then
            if deletePathRecursive(sdr_path) then
                logger.info("GrimmLink ShelfSync: removed .sdr sidecar:", sdr_path)
            else
                logger.warn("GrimmLink ShelfSync: failed to remove .sdr sidecar:", sdr_path)
            end
        end
    end
end

-- Safely delete a tracked book and optionally its .sdr sidecar.
-- Only deletes files where downloaded_by_grimmlink == 1.
function ShelfSync:deleteLocalBook(entry, delete_sdr, download_dir)
    if entry.downloaded_by_grimmlink ~= 1 then
        logger.warn("GrimmLink ShelfSync: skip delete — not downloaded by GrimmLink:", entry.local_path)
        return false
    end

    if entry.local_path and entry.local_path ~= "" and download_dir and not isPathUnderDirectory(entry.local_path, download_dir) then
        logger.warn("GrimmLink ShelfSync: skip delete — outside download directory:", entry.local_path)
        return false
    end

    if not entry.local_path or entry.local_path == "" then
        self.db:deleteShelfSyncEntry(entry.book_id)
        return true
    end

    local attr = lfs.attributes(entry.local_path)
    if attr and attr.mode == "file" then
        os.remove(entry.local_path)
        logger.info("GrimmLink ShelfSync: deleted local book:", entry.local_path)
        if delete_sdr then
            deleteSdr(entry.local_path)
        end
    end

    self.db:deleteShelfSyncEntry(entry.book_id)
    return true
end

function ShelfSync:processPendingShelfRemovals(shelf_id, download_dir, delete_sdr, skip_download_ids, result, progress)
    local pending_entries = self.db:getPendingShelfRemovals(shelf_id)
    for _, entry in ipairs(pending_entries) do
        if entry.book_id then
            skip_download_ids[tostring(entry.book_id)] = true
            if progress then
                progress("Removing pending: " .. (entry.local_path or tostring(entry.book_id)))
            end
            local ok, err = self.api:removeBookFromShelf(entry.shelf_id, entry.book_id)
            if ok then
                local tracked = self.db:getShelfSyncEntry(entry.book_id)
                if tracked then
                    self:deleteLocalBook(tracked, delete_sdr, download_dir)
                end
                self.db:deletePendingShelfRemoval(entry.book_id)
                result.deleted = result.deleted + 1
            else
                self.db:incrementPendingShelfRemovalRetryCount(entry.book_id)
                result.failed = result.failed + 1
                result.errors[#result.errors + 1] = "Failed to remove pending bookId=" .. tostring(entry.book_id) .. ": " .. tostring(err)
                logger.warn("GrimmLink ShelfSync:", result.errors[#result.errors])
            end
        end
    end
end

-- Main sync function.
-- opts = {
--   shelf_id          = number,
--   download_dir      = string (setting value, may be empty → auto-detect),
--   use_original_filename = bool,
--   two_way_delete_sync = bool,
--   delete_sdr        = bool,
--   on_progress       = function(msg) (optional),
-- }
-- Returns: { synced=n, skipped=n, failed=n, deleted=n, errors={} }
function ShelfSync:syncShelf(opts)
    local shelf_id = opts.shelf_id
    local result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }

    local function progress(msg)
        if opts.on_progress then opts.on_progress(msg) end
        logger.info("GrimmLink ShelfSync:", msg)
    end

    -- Phase 1: Fetch shelf books
    progress("Fetching shelf books from server…")
    local ok, remote_books = self.api:getShelfBooks(shelf_id)
    if not ok then
        local err = "Failed to fetch shelf books: " .. tostring(remote_books)
        result.errors[#result.errors + 1] = err
        logger.warn("GrimmLink ShelfSync:", err)
        return result
    end

    if type(remote_books) ~= "table" then
        result.errors[#result.errors + 1] = "Unexpected shelf books response"
        return result
    end

    local sync_start = os.time()
    local download_dir = self:resolveDownloadDir(opts.download_dir)
    local use_original = opts.use_original_filename ~= false -- default true
    local two_way_delete_sync = opts.two_way_delete_sync == true
    local delete_sdr = opts.delete_sdr == true
    local skip_download_ids = {}

    if two_way_delete_sync then
        self:processPendingShelfRemovals(shelf_id, download_dir, delete_sdr, skip_download_ids, result, progress)
    end

    -- Phase 2: Download missing books
    progress("Processing " .. #remote_books .. " books in shelf…")
    for _, book in ipairs(remote_books) do
        local book_id = book.bookId
        local should_continue = false
        if book_id then
            local book_id_key = tostring(book_id)
            should_continue = skip_download_ids[book_id_key] == true

            -- Mark as seen in this sync
            local existing = self.db:getShelfSyncEntry(book_id)
            if not should_continue and two_way_delete_sync and existing and existing.downloaded_by_grimmlink == 1 and existing.local_path and existing.local_path ~= "" and isPathUnderDirectory(existing.local_path, download_dir) then
                local attr = lfs.attributes(existing.local_path)
                if not attr then
                    progress("Removing locally deleted book: " .. (book.title or tostring(book_id)))
                    local removal_ok, removal_err = self.api:removeBookFromShelf(shelf_id, book_id)
                    if removal_ok then
                        self.db:deleteShelfSyncEntry(book_id)
                        result.deleted = result.deleted + 1
                        skip_download_ids[book_id_key] = true
                        should_continue = true
                    else
                        self.db:upsertPendingShelfRemoval({
                            book_id = book_id,
                            shelf_id = shelf_id,
                            local_path = existing.local_path,
                            delete_sdr = delete_sdr,
                        })
                        self.db:incrementPendingShelfRemovalRetryCount(book_id)
                        result.failed = result.failed + 1
                        local err = "Failed to remove bookId=" .. tostring(book_id) .. " from shelf: " .. tostring(removal_err)
                        result.errors[#result.errors + 1] = err
                        logger.warn("GrimmLink ShelfSync:", err)
                        skip_download_ids[book_id_key] = true
                        should_continue = true
                    end
                end
            end
            if not should_continue and existing then
                -- Touch last_seen_in_shelf_at
                self.db:upsertShelfSyncEntry({
                    book_id = book_id,
                    shelf_id = shelf_id,
                    last_seen_in_shelf_at = sync_start,
                })

                -- Check if local file still exists and size roughly matches
                if existing.local_path and existing.local_path ~= "" then
                    local attr = lfs.attributes(existing.local_path)
                    if attr and attr.mode == "file" then
                        local remote_kb = book.fileSizeKb
                        local local_kb = math.floor(attr.size / 1024)
                        if remote_kb == nil or math.abs(local_kb - remote_kb) < 10 then
                            result.skipped = result.skipped + 1
                            should_continue = true
                        else
                            -- File size mismatch - re-download
                            logger.info("GrimmLink ShelfSync: re-downloading due to size mismatch, bookId=", book_id)
                        end
                    end
                end
            end
        end

        if book_id and not should_continue then
            -- Need to download
            local filename = self:buildSafeFilename(book, use_original)
            local dest_path = uniquePath(download_dir, filename)

            progress("Downloading: " .. (book.title or filename))
            local dl_ok, dl_err = self.api:downloadBookToFile(book_id, dest_path)
            if dl_ok then
                self.db:upsertShelfSyncEntry({
                    book_id = book_id,
                    shelf_id = shelf_id,
                    remote_filename = book.fileName,
                    remote_title = book.title,
                    remote_author = book.author,
                    remote_format = book.fileFormat,
                    remote_file_size_kb = book.fileSizeKb,
                    local_path = dest_path,
                    downloaded_at = os.time(),
                    last_seen_in_shelf_at = sync_start,
                    downloaded_by_grimmlink = 1,
                })
                if self.db.saveBookCache then
                    self.db:saveBookCache(dest_path, "", book_id, book.title, book.author)
                end
                result.synced = result.synced + 1
                logger.info("GrimmLink ShelfSync: downloaded bookId=" .. tostring(book_id) .. " to " .. dest_path)
            else
                result.failed = result.failed + 1
                local err = "Failed to download bookId=" .. tostring(book_id) .. ": " .. tostring(dl_err)
                result.errors[#result.errors + 1] = err
                logger.warn("GrimmLink ShelfSync:", err)
            end
        end

    end

    -- Phase 3: Delete removed books (only when two-way shelf delete sync is enabled)
    if two_way_delete_sync then
        local all_entries = self.db:getAllShelfSyncEntries(shelf_id)
        for _, entry in ipairs(all_entries) do
            -- If this book was not seen in the current sync, it was removed from the shelf
            if entry.last_seen_in_shelf_at == nil or entry.last_seen_in_shelf_at < sync_start then
                if entry.downloaded_by_grimmlink == 1 then
                    progress("Removing: " .. (entry.remote_title or entry.remote_filename or tostring(entry.book_id)))
                    self:deleteLocalBook(entry, delete_sdr, download_dir)
                    result.deleted = result.deleted + 1
                end
            end
        end
    end

    return result
end

return ShelfSync
