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

    local ext = "epub"
    if book_info.fileFormat ~= nil and tostring(book_info.fileFormat) ~= "" then
        ext = tostring(book_info.fileFormat):lower()
    end
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

-- Remote fileSizeKb may be rounded differently across responses.
-- Keep a dynamic tolerance to avoid unnecessary re-downloads.
local function isReasonablyCloseSize(local_bytes, remote_kb)
    local remote_kb_num = tonumber(remote_kb)
    if not remote_kb_num then
        return true, math.floor((local_bytes or 0) / 1024), 0, 0
    end
    local local_kb = math.floor((local_bytes or 0) / 1024)
    local diff_kb = math.abs(local_kb - remote_kb_num)
    local tolerance_kb = math.max(10, math.floor(remote_kb_num * 0.10))
    if tolerance_kb > 512 then
        tolerance_kb = 512
    end
    return diff_kb <= tolerance_kb, local_kb, diff_kb, tolerance_kb
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
        logger.warn("GrimmLink ShelfSync: skip delete â€” not downloaded by GrimmLink:", entry.local_path)
        return false
    end

    if entry.local_path and entry.local_path ~= "" and download_dir and not isPathUnderDirectory(entry.local_path, download_dir) then
        logger.warn("GrimmLink ShelfSync: skip delete â€” outside download directory:", entry.local_path)
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

local function normalizeShelfBooksResponse(remote_books)
    if type(remote_books) ~= "table" then
        return nil
    end
    if type(remote_books.content) == "table" then
        return remote_books.content
    end
    if type(remote_books.items) == "table" then
        return remote_books.items
    end
    return remote_books
end

-- Main sync function.
-- opts = {
--   shelf_id          = number,
--   download_dir      = string (setting value, may be empty ? auto-detect),
--   use_original_filename = bool,
--   two_way_delete_sync = bool,
--   allow_local_delete_remote = bool (default false; safety guard),
--   delete_sdr        = bool,
--   on_progress       = function(msg) (optional),
-- }
-- Returns: { synced=n, skipped=n, failed=n, deleted=n, errors={} }
function ShelfSync:syncShelf(opts)
    local result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
    if type(opts) ~= "table" then
        result.errors[#result.errors + 1] = "Invalid shelf sync options"
        return result
    end
    local shelf_id = tonumber(opts.shelf_id) or opts.shelf_id
    if not self.db then
        result.errors[#result.errors + 1] = "Database unavailable"
        return result
    end
    if not self.api then
        result.errors[#result.errors + 1] = "API client unavailable"
        return result
    end

    local function progress(msg)
        if opts.on_progress then opts.on_progress(msg) end
        logger.info("GrimmLink ShelfSync:", msg)
    end

    local remote_books = opts.preloaded_remote_books
    if type(remote_books) == "table" then
        progress("Using cached shelf books snapshot...")
    else
        progress("Fetching shelf books from server...")
        local ok, fetched_books = self.api:getShelfBooks(shelf_id)
        if not ok then
            local err = "Failed to fetch shelf books: " .. tostring(fetched_books)
            result.errors[#result.errors + 1] = err
            logger.warn("GrimmLink ShelfSync:", err)
            return result
        end
        remote_books = fetched_books
    end

    remote_books = normalizeShelfBooksResponse(remote_books)
    if type(remote_books) ~= "table" then
        result.errors[#result.errors + 1] = "Unexpected shelf books response"
        return result
    end
    if opts.on_fetched_remote_books and type(opts.on_fetched_remote_books) == "function" then
        pcall(opts.on_fetched_remote_books, remote_books)
    end

    local sync_start = os.time()
    local download_dir = self:resolveDownloadDir(opts.download_dir)
    local use_original = opts.use_original_filename ~= false -- default true
    local two_way_delete_sync = opts.two_way_delete_sync == true
    local allow_local_delete_remote = opts.allow_local_delete_remote == true
    local delete_sdr = opts.delete_sdr == true
    local skip_download_ids = {}

    if two_way_delete_sync and allow_local_delete_remote then
        self:processPendingShelfRemovals(shelf_id, download_dir, delete_sdr, skip_download_ids, result, progress)
    end

    -- Phase 2: Download missing books
    progress("Processing " .. #remote_books .. " books in shelfâ€¦")
    for _, book in ipairs(remote_books) do
        local should_continue = false
        local existing = nil
        local book_id = nil
        local entry_ok = true

        if type(book) ~= "table" then
            result.failed = result.failed + 1
            result.errors[#result.errors + 1] = "Invalid shelf entry type: " .. type(book)
            entry_ok = false
        else
            book_id = tonumber(book.bookId or book.id or book.book_id)
            if not book_id then
                result.failed = result.failed + 1
                result.errors[#result.errors + 1] = "Missing bookId in shelf entry"
                entry_ok = false
            end
        end

        if entry_ok and book_id then
            local book_id_key = tostring(book_id)
            should_continue = skip_download_ids[book_id_key] == true

            -- Mark as seen in this sync
            existing = self.db:getShelfSyncEntry(book_id)
            if not should_continue and two_way_delete_sync and allow_local_delete_remote and existing and existing.downloaded_by_grimmlink == 1 and existing.local_path and existing.local_path ~= "" and isPathUnderDirectory(existing.local_path, download_dir) then
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
                -- Touch last_seen_in_shelf_at without dropping existing fields.
                self.db:upsertShelfSyncEntry({
                    book_id = book_id,
                    shelf_id = shelf_id,
                    remote_filename = existing.remote_filename or book.fileName,
                    remote_title = existing.remote_title or book.title,
                    remote_author = existing.remote_author or book.author,
                    remote_format = existing.remote_format or book.fileFormat,
                    remote_file_size_kb = existing.remote_file_size_kb or book.fileSizeKb,
                    local_path = existing.local_path,
                    downloaded_at = existing.downloaded_at,
                    last_seen_in_shelf_at = sync_start,
                    downloaded_by_grimmlink = existing.downloaded_by_grimmlink == 1,
                })

                -- Reuse tracked file whenever it still exists for this book_id.
                if existing.local_path and existing.local_path ~= "" then
                    local attr = lfs.attributes(existing.local_path)
                    if attr and attr.mode == "file" then
                        local close_size, local_kb, diff_kb, tolerance_kb = isReasonablyCloseSize(attr.size, book.fileSizeKb)
                        if not close_size then
                            logger.info(
                                "GrimmLink ShelfSync: reusing tracked file despite size delta, bookId=" .. tostring(book_id)
                                    .. ", localKB=" .. tostring(local_kb)
                                    .. ", remoteKB=" .. tostring(book.fileSizeKb)
                                    .. ", diffKB=" .. tostring(diff_kb)
                                    .. ", toleranceKB=" .. tostring(tolerance_kb)
                            )
                        end
                        result.skipped = result.skipped + 1
                        should_continue = true
                    end
                end

                -- Recovery: if shelf map lost local_path, try restoring from book_cache.
                if not should_continue and (existing.local_path == nil or existing.local_path == "")
                    and self.db and type(self.db.getLatestBookPathByBookId) == "function" then
                    local cached_path = self.db:getLatestBookPathByBookId(book_id)
                    if cached_path and cached_path ~= "" then
                        local cached_attr = lfs.attributes(cached_path)
                        if cached_attr and cached_attr.mode == "file" then
                            self.db:upsertShelfSyncEntry({
                                book_id = book_id,
                                shelf_id = shelf_id,
                                remote_filename = existing.remote_filename or book.fileName,
                                remote_title = existing.remote_title or book.title,
                                remote_author = existing.remote_author or book.author,
                                remote_format = existing.remote_format or book.fileFormat,
                                remote_file_size_kb = existing.remote_file_size_kb or book.fileSizeKb,
                                local_path = cached_path,
                                downloaded_at = existing.downloaded_at,
                                last_seen_in_shelf_at = sync_start,
                                downloaded_by_grimmlink = existing.downloaded_by_grimmlink == 1,
                            })
                            result.skipped = result.skipped + 1
                            should_continue = true
                            logger.info("GrimmLink ShelfSync: restored local_path from book_cache for bookId=" .. tostring(book_id))
                        end
                    end
                end
            end
        end

        if entry_ok and book_id and not should_continue then
            -- Need to download
            local filename = self:buildSafeFilename(book, use_original)
            if not filename or filename == "" then
                result.failed = result.failed + 1
                result.errors[#result.errors + 1] = "Invalid filename for bookId=" .. tostring(book_id)
                entry_ok = false
            end
            if entry_ok then
                local sep = download_dir:sub(-1) == "/" and "" or "/"
                local candidate_path = download_dir .. sep .. filename

                -- Check if the file already exists on disk (e.g. from a previous
                -- sync session whose DB was cleared).  When the size roughly
                -- matches the remote, reuse the existing file instead of
                -- downloading a duplicate with a _2 suffix.
                local candidate_attr = lfs.attributes(candidate_path)
                if candidate_attr and candidate_attr.mode == "file" then
                    local close_size = isReasonablyCloseSize(candidate_attr.size, book.fileSizeKb)
                    -- Recovery path: if DB mapping exists but local_path was lost,
                    -- trust candidate path and restore mapping.
                    if close_size or (existing and (existing.local_path == nil or existing.local_path == "")) then
                        self.db:upsertShelfSyncEntry({
                            book_id = book_id,
                            shelf_id = shelf_id,
                            remote_filename = book.fileName,
                            remote_title = book.title,
                            remote_author = book.author,
                            remote_format = book.fileFormat,
                            remote_file_size_kb = book.fileSizeKb,
                            local_path = candidate_path,
                            downloaded_at = os.time(),
                            last_seen_in_shelf_at = sync_start,
                            downloaded_by_grimmlink = 1,
                        })
                        if self.db.saveBookCache then
                            self.db:saveBookCache(candidate_path, "", book_id, book.title, book.author)
                        end
                        result.skipped = result.skipped + 1
                        logger.info("GrimmLink ShelfSync: reused existing file for bookId=" .. tostring(book_id) .. " at " .. candidate_path)
                        should_continue = true
                    end
                end
            end
        end

        if entry_ok and book_id and not should_continue then
            local filename = self:buildSafeFilename(book, use_original)
            if not filename or filename == "" then
                result.failed = result.failed + 1
                result.errors[#result.errors + 1] = "Invalid filename for bookId=" .. tostring(book_id)
            else
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

