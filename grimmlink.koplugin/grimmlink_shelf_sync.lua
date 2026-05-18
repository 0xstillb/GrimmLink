local DataStorage = require("datastorage")
local _ok_lfs, lfs = pcall(require, "lfs")
if not _ok_lfs then
    -- Minimal lfs fallback for platforms where the module is unavailable (e.g. some Kindle builds).
    -- Uses io + os.execute (POSIX tools available on KOReader/Kindle Linux).
    local function shellEscape(path)
        return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
    end
    lfs = {
        attributes = function(path)
            if not path or path == "" then return nil end
            local ok = os.execute("test -d " .. shellEscape(path))
            if ok == 0 or ok == true then
                return { size = 0, mode = "directory" }
            end
            local f = io.open(path, "r")
            if f then
                local size = f:seek("end") or 0
                f:close()
                return { size = size, mode = "file" }
            end
            return nil
        end,
        mkdir = function(path)
            if not path or path == "" then return nil, "invalid path" end
            local ok = os.execute("mkdir " .. shellEscape(path))
            if ok == 0 or ok == true then return true end
            return nil, "mkdir failed"
        end,
        dir = function(path)
            if not path or path == "" then return function() return nil end end
            local handle = io.popen("ls -a " .. shellEscape(path) .. " 2>/dev/null")
            if not handle then return function() return nil end end
            local entries = {}
            for line in handle:lines() do
                entries[#entries + 1] = line
            end
            handle:close()
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end
        end,
        rmdir = function(path)
            if not path or path == "" then return false end
            local ok = os.execute("rmdir " .. shellEscape(path))
            return ok == 0 or ok == true
        end,
    }
end
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

local function isPathUnderAnyDirectory(path, roots)
    if type(roots) ~= "table" then
        return false
    end
    for _, root in ipairs(roots) do
        if root and root ~= "" and isPathUnderDirectory(path, root) then
            return true
        end
    end
    return false
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
    -- /mnt/us/documents is Kindle-specific and indexed by Kindle's native library.
    local data_dir = DataStorage:getDataDir()
    local candidates = {
        "/mnt/us/documents",
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
        logger.warn("GrimmLink ShelfSync: skip delete (not downloaded by GrimmLink):", entry.local_path)
        return false, "not_downloaded_by_grimmlink"
    end

    if entry.local_path and entry.local_path ~= "" then
        local managed_roots = {
            download_dir,
            DataStorage:getDataDir(),
            DataStorage:getSettingsDir(),
        }
        if not isPathUnderAnyDirectory(entry.local_path, managed_roots) then
            logger.warn("GrimmLink ShelfSync: skip delete (outside managed roots):", entry.local_path)
            return false, "outside_managed_roots"
        end
    end

    if not entry.local_path or entry.local_path == "" then
        self.db:deleteShelfSyncEntry(entry.book_id)
        return true
    end

    local attr = lfs.attributes(entry.local_path)
    if attr and attr.mode == "file" then
        local removed, remove_err = os.remove(entry.local_path)
        if not removed then
            logger.warn("GrimmLink ShelfSync: failed to delete local book:", entry.local_path, tostring(remove_err))
            return false, "remove_failed: " .. tostring(remove_err)
        end
        logger.info("GrimmLink ShelfSync: deleted local book:", entry.local_path)
        if delete_sdr then
            deleteSdr(entry.local_path)
        end
    elseif attr and attr.mode ~= "file" then
        logger.warn("GrimmLink ShelfSync: skip delete (local path is not a file):", entry.local_path)
        return false, "local_path_not_file"
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
                local deleted_ok = true
                if tracked then
                    deleted_ok = self:deleteLocalBook(tracked, delete_sdr, download_dir)
                end
                if deleted_ok then
                    if tracked then
                        self:removeBookMetadata(tracked, shelf_id)
                    end
                    self.db:deletePendingShelfRemoval(entry.book_id)
                    result.deleted = result.deleted + 1
                else
                    self.db:incrementPendingShelfRemovalRetryCount(entry.book_id)
                    result.failed = result.failed + 1
                    result.errors[#result.errors + 1] = "Failed to delete local file for pending bookId=" .. tostring(entry.book_id)
                end
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

-- ============================================================
-- Async-friendly sync architecture.
-- The monolithic syncShelf is split into:
--   prepareSyncPlan()  -- classify books (skip / download), no I/O
--   executeDownload()  -- download ONE book + DB upsert
--   runCleanupPhase()  -- Phase 3 remote-deletion pass
--   syncShelf()        -- backward-compatible blocking wrapper
-- The caller (main.lua) can drive downloads one-at-a-time via
-- UIManager:scheduleIn to keep the UI responsive on weak CPUs.
-- ============================================================

--- Classify every book in the remote shelf without downloading anything.
-- Returns: plan = {
--   result         = { synced=0, skipped=N, failed=N, deleted=0, errors={} },
--   download_queue = { {book=<table>, book_id=N, dest_path=<string>, title=<string>}, ... },
--   cleanup        = { shelf_id, download_dir, delete_sdr, remote_delete_sync, sync_start },
-- }
-- On error the returned plan.result.errors is non-empty and download_queue is {}.
function ShelfSync:prepareSyncPlan(opts)
    local result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
    local plan   = { result = result, download_queue = {}, cleanup = nil }

    if type(opts) ~= "table" then
        result.errors[#result.errors + 1] = "Invalid shelf sync options"
        return plan
    end
    local shelf_id = tonumber(opts.shelf_id) or opts.shelf_id
    if not self.db then
        result.errors[#result.errors + 1] = "Database unavailable"
        return plan
    end
    if not self.api then
        result.errors[#result.errors + 1] = "API client unavailable"
        return plan
    end

    local function progress(msg)
        if opts.on_progress then opts.on_progress(msg) end
        logger.info("GrimmLink ShelfSync:", msg)
    end

    -- Fetch remote book list.
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
            return plan
        end
        remote_books = fetched_books
    end

    remote_books = normalizeShelfBooksResponse(remote_books)
    if type(remote_books) ~= "table" then
        result.errors[#result.errors + 1] = "Unexpected shelf books response"
        return plan
    end
    if opts.on_fetched_remote_books and type(opts.on_fetched_remote_books) == "function" then
        pcall(opts.on_fetched_remote_books, remote_books)
    end

    local sync_start   = os.time()
    local download_dir = self:resolveDownloadDir(opts.download_dir)
    local use_original = opts.use_original_filename ~= false
    local remote_delete_sync = opts.remote_delete_sync ~= false
    local delete_sdr   = opts.delete_sdr == true
    local skip_download_ids = {}

    plan.cleanup = {
        shelf_id            = shelf_id,
        download_dir        = download_dir,
        delete_sdr          = delete_sdr,
        remote_delete_sync  = remote_delete_sync,
        sync_start          = sync_start,
    }

    -- Classify each book.
    progress("Processing " .. #remote_books .. " books in shelf...")
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

            existing = self.db:getShelfSyncEntry(book_id)
            if not should_continue and existing then
                self.db:upsertShelfSyncEntry({
                    book_id = book_id,
                    shelf_id = shelf_id,
                    remote_filename = existing.remote_filename or book.fileName,
                    remote_title = existing.remote_title or book.title,
                    remote_author = existing.remote_author or book.author,
                    remote_format = existing.remote_format or book.fileFormat,
                    remote_file_size_kb = existing.remote_file_size_kb or book.fileSizeKb,
                    remote_series_name = book.seriesName or existing.remote_series_name,
                    remote_series_number = book.seriesNumber or existing.remote_series_number,
                    local_path = existing.local_path,
                    downloaded_at = existing.downloaded_at,
                    last_seen_in_shelf_at = sync_start,
                    downloaded_by_grimmlink = existing.downloaded_by_grimmlink == 1,
                })

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
                                remote_series_name = book.seriesName or existing.remote_series_name,
                                remote_series_number = book.seriesNumber or existing.remote_series_number,
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

        -- Check on-disk candidate before queuing for download.
        if entry_ok and book_id and not should_continue then
            local filename = self:buildSafeFilename(book, use_original)
            if not filename or filename == "" then
                result.failed = result.failed + 1
                result.errors[#result.errors + 1] = "Invalid filename for bookId=" .. tostring(book_id)
                entry_ok = false
            end
            if entry_ok then
                local sep = download_dir:sub(-1) == "/" and "" or "/"
                local candidate_path = download_dir .. sep .. filename

                local candidate_attr = lfs.attributes(candidate_path)
                if candidate_attr and candidate_attr.mode == "file" then
                    local close_size = isReasonablyCloseSize(candidate_attr.size, book.fileSizeKb)
                    if close_size or (existing and (existing.local_path == nil or existing.local_path == "")) then
                        self.db:upsertShelfSyncEntry({
                            book_id = book_id,
                            shelf_id = shelf_id,
                            remote_filename = book.fileName,
                            remote_title = book.title,
                            remote_author = book.author,
                            remote_format = book.fileFormat,
                            remote_file_size_kb = book.fileSizeKb,
                            remote_series_name = book.seriesName,
                            remote_series_number = book.seriesNumber,
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

        -- Still needs download — queue it.
        if entry_ok and book_id and not should_continue then
            local filename = self:buildSafeFilename(book, use_original)
            if not filename or filename == "" then
                result.failed = result.failed + 1
                result.errors[#result.errors + 1] = "Invalid filename for bookId=" .. tostring(book_id)
            else
                local dest_path = uniquePath(download_dir, filename)
                plan.download_queue[#plan.download_queue + 1] = {
                    book      = book,
                    book_id   = book_id,
                    dest_path = dest_path,
                    title     = book.title or filename,
                }
            end
        end
    end

    return plan
end

--- Download ONE book + DB upsert.  Returns true on success, false+error on failure.
--- Execute a single book download.
-- download_opts (optional table) is forwarded to api:downloadBookToFile:
--   on_progress(bytes, total)  progress callback
--   is_cancelled() → bool     cancel check
function ShelfSync:executeDownload(item, shelf_id, sync_start, download_opts)
    if not item or not item.book_id or not item.dest_path then
        return false, "invalid download item"
    end
    local book    = item.book
    local book_id = item.book_id

    -- Build download options, including expected file size for timeout scaling.
    local dl_opts = download_opts or {}
    if book and book.fileSizeKb then
        dl_opts.expected_size_kb = book.fileSizeKb
    end

    local dl_ok, dl_err = self.api:downloadBookToFile(book_id, item.dest_path, dl_opts)
    if dl_ok then
        self.db:upsertShelfSyncEntry({
            book_id              = book_id,
            shelf_id             = shelf_id,
            remote_filename      = book.fileName,
            remote_title         = book.title,
            remote_author        = book.author,
            remote_format        = book.fileFormat,
            remote_file_size_kb  = book.fileSizeKb,
            remote_series_name   = book.seriesName,
            remote_series_number = book.seriesNumber,
            local_path           = item.dest_path,
            downloaded_at        = os.time(),
            last_seen_in_shelf_at = sync_start,
            downloaded_by_grimmlink = 1,
        })
        if self.db.saveBookCache then
            self.db:saveBookCache(item.dest_path, "", book_id, book.title, book.author)
        end
        logger.info("GrimmLink ShelfSync: downloaded bookId=" .. tostring(book_id) .. " to " .. item.dest_path)
        return true
    else
        local err = "Failed to download bookId=" .. tostring(book_id) .. ": " .. tostring(dl_err)
        logger.warn("GrimmLink ShelfSync:", err)
        return false, err
    end
end

--- Start an async (non-blocking) download for one book.
-- Returns a download handle for polling, or nil + error.
function ShelfSync:startAsyncDownload(item)
    if not item or not item.book_id or not item.dest_path then
        return nil, "invalid download item"
    end
    local book = item.book
    local opts = {}
    if book and book.fileSizeKb then
        opts.expected_size_kb = book.fileSizeKb
    end
    return self.api:startAsyncDownload(item.book_id, item.dest_path, opts)
end

--- Record a completed download in the database.
function ShelfSync:recordDownload(item, shelf_id, sync_start)
    if not item then return end
    local book = item.book or {}
    self.db:upsertShelfSyncEntry({
        book_id              = item.book_id,
        shelf_id             = shelf_id,
        remote_filename      = book.fileName,
        remote_title         = book.title,
        remote_author        = book.author,
        remote_format        = book.fileFormat,
        remote_file_size_kb  = book.fileSizeKb,
        remote_series_name   = book.seriesName,
        remote_series_number = book.seriesNumber,
        local_path           = item.dest_path,
        downloaded_at        = os.time(),
        last_seen_in_shelf_at = sync_start,
        downloaded_by_grimmlink = 1,
    })
    if self.db.saveBookCache then
        self.db:saveBookCache(item.dest_path, "", item.book_id, book.title, book.author)
    end
    logger.info("GrimmLink ShelfSync: downloaded bookId=" .. tostring(item.book_id) .. " to " .. item.dest_path)
end

--- Phase 3: Delete local files for books removed from the remote shelf.
-- cleanup table comes from prepareSyncPlan().cleanup.
-- result  table is the running result accumulator.
-- progress_fn is optional function(msg).
function ShelfSync:runCleanupPhase(cleanup, result, progress_fn)
    if not cleanup or not cleanup.remote_delete_sync then return end
    local all_entries = self.db:getAllShelfSyncEntries(cleanup.shelf_id)
    for _, entry in ipairs(all_entries) do
        if entry.last_seen_in_shelf_at == nil or entry.last_seen_in_shelf_at < cleanup.sync_start then
            if entry.downloaded_by_grimmlink == 1 then
                if progress_fn then
                    progress_fn("Removing: " .. (entry.remote_title or entry.remote_filename or tostring(entry.book_id)))
                end
                local delete_ok, delete_err = self:deleteLocalBook(entry, cleanup.delete_sdr, cleanup.download_dir)
                if delete_ok then
                    self:removeBookMetadata(entry, cleanup.shelf_id)
                    result.deleted = result.deleted + 1
                else
                    result.failed = result.failed + 1
                    local err = "Failed to delete local bookId=" .. tostring(entry.book_id) .. ": " .. tostring(delete_err)
                    result.errors[#result.errors + 1] = err
                    logger.warn("GrimmLink ShelfSync:", err)
                end
            end
        end
    end
end

-- Backward-compatible blocking wrapper.
-- Calls prepareSyncPlan, downloads sequentially, runs cleanup — all synchronous.
-- opts = {
--   shelf_id          = number,
--   download_dir      = string (setting value, may be empty -> auto-detect),
--   use_original_filename = bool,
--   remote_delete_sync = bool (remote shelf removals -> local delete),
--   delete_sdr        = bool,
--   on_progress       = function(msg) (optional),
--   preloaded_remote_books = table (optional),
--   on_fetched_remote_books = function (optional),
-- }
-- Returns: { synced=n, skipped=n, failed=n, deleted=n, errors={} }
function ShelfSync:syncShelf(opts)
    local plan = self:prepareSyncPlan(opts)
    local result = plan.result

    -- If planning itself failed, return immediately.
    if #result.errors > 0 and #plan.download_queue == 0 then
        return result
    end

    local function progress(msg)
        if opts and opts.on_progress then opts.on_progress(msg) end
        logger.info("GrimmLink ShelfSync:", msg)
    end

    -- Download sequentially (blocking — same behaviour as before).
    for i, item in ipairs(plan.download_queue) do
        progress("Downloading " .. i .. "/" .. #plan.download_queue .. ": " .. (item.title or "?"))
        local ok, err = self:executeDownload(item, plan.cleanup.shelf_id, plan.cleanup.sync_start)
        if ok then
            result.synced = result.synced + 1
        else
            result.failed = result.failed + 1
            result.errors[#result.errors + 1] = err
        end
    end

    -- Phase 3: cleanup.
    self:runCleanupPhase(plan.cleanup, result, progress)

    return result
end

-- Normalize a local path for consistent metadata key matching.
local function normalizePath(path)
    if not path or path == "" then return nil end
    local p = tostring(path):gsub("\\", "/"):gsub("/+", "/")
    if #p > 1 then p = p:gsub("/$", "") end
    return p
end

--- Write a metadata index JSON file to download_dir after sync.
-- Source of truth for GrimmLink-managed metadata; survives bookinfo_cache rescans.
function ShelfSync:writeMetadataIndex(shelf_id, download_dir)
    if not self.db or not shelf_id then return nil end
    local entries = self.db:getAllShelfSyncEntries(shelf_id)
    if #entries == 0 then return nil end

    local index = {}
    local skipped = 0
    for _, e in ipairs(entries) do
        local norm = normalizePath(e.local_path)
        if norm then
            local file_attr = lfs.attributes(norm)
            if file_attr and file_attr.mode == "file" then
                local dir = norm:match("^(.*)/[^/]+$") or ""
                local fname = norm:match("([^/]+)$") or ""
                index[#index + 1] = {
                    bookId       = e.book_id,
                    directory    = dir,
                    filename     = fname,
                    title        = e.remote_title,
                    author       = e.remote_author,
                    series       = e.remote_series_name,
                    seriesIndex  = e.remote_series_number,
                    format       = e.remote_format,
                }
            else
                skipped = skipped + 1
            end
        end
    end

    local index_path = joinPath(download_dir, "grimmlink_metadata_index.json")
    local json = require("json")
    local ok, encoded = pcall(json.encode, index)
    if not ok then
        logger.warn("GrimmLink ShelfSync: failed to encode metadata index:", encoded)
        return nil
    end
    local fh = io.open(index_path, "w")
    if not fh then
        logger.warn("GrimmLink ShelfSync: cannot write metadata index:", index_path)
        return nil
    end
    fh:write(encoded)
    fh:close()
    logger.info("GrimmLink ShelfSync: wrote metadata index:", index_path,
        "| entries:", #index, "| skipped_missing:", skipped)
    return index_path
end

-- Open bookinfo_cache.sqlite3, validate schema, return conn or nil.
local function openBookInfoCache()
    local cache_path = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
    local attr = lfs.attributes(cache_path)
    if not attr then
        logger.info("GrimmLink: bookinfo_cache.sqlite3 not found, skipping")
        return nil, cache_path
    end

    local SQ3 = require("lua-ljsqlite3/init")
    local ok_open, cache_conn = pcall(SQ3.open, cache_path)
    if not ok_open or not cache_conn then
        logger.warn("GrimmLink: cannot open bookinfo_cache:", tostring(cache_conn))
        return nil, cache_path
    end

    -- Rule 25/26: inspect schema before writing
    local has_bookinfo = false
    local columns = {}
    local pragma_ok, pragma_err = pcall(function()
        local stmt = cache_conn:prepare("PRAGMA table_info(bookinfo)")
        if stmt then
            for row in stmt:rows() do
                columns[row[2]] = true
            end
            stmt:close()
            has_bookinfo = columns["directory"] and columns["filename"]
        end
    end)
    if not pragma_ok then
        logger.warn("GrimmLink: PRAGMA check failed:", tostring(pragma_err))
        cache_conn:close()
        return nil, cache_path
    end
    if not has_bookinfo then
        logger.warn("GrimmLink: bookinfo table missing or schema mismatch, skipping")
        cache_conn:close()
        return nil, cache_path
    end

    return cache_conn, cache_path, columns
end

-- Backup bookinfo_cache.sqlite3 once before first GrimmLink write.
local _backup_done = false
local function backupBookInfoCacheOnce(cache_path)
    if _backup_done then return end
    local backup_path = cache_path .. ".grimmlink_backup"
    if not lfs.attributes(backup_path) then
        local src = io.open(cache_path, "rb")
        if src then
            local dst = io.open(backup_path, "wb")
            if dst then
                dst:write(src:read("*a"))
                dst:close()
                logger.info("GrimmLink: backed up bookinfo_cache to", backup_path)
            end
            src:close()
        end
    end
    _backup_done = true
end

--- Upsert display metadata into KOReader's bookinfo_cache.sqlite3.
-- Updates: title, authors, series, series_index, keywords.
-- Inserts a minimal valid row if no existing row matches.
function ShelfSync:upsertBookInfoCache(shelf_id)
    if not self.db or not shelf_id then return { inserted = 0, updated = 0, skipped = 0 } end

    local cache_conn, cache_path, columns = openBookInfoCache()
    if not cache_conn then return { inserted = 0, updated = 0, skipped = 0 } end

    backupBookInfoCacheOnce(cache_path)

    local entries = self.db:getAllShelfSyncEntries(shelf_id)
    local counts = { inserted = 0, updated = 0, skipped = 0 }

    local has_series = columns["series"]
    local has_series_index = columns["series_index"]
    local has_keywords = columns["keywords"]

    cache_conn:exec("BEGIN TRANSACTION")

    for _, e in ipairs(entries) do
        local norm = normalizePath(e.local_path)
        local file_attr = norm and lfs.attributes(norm)
        if norm and file_attr and file_attr.mode == "file" then
            local dir = norm:match("^(.*)/[^/]+$") or ""
            if dir ~= "" and not dir:match("/$") then dir = dir .. "/" end
            local fname = norm:match("([^/]+)$") or ""
            if fname ~= "" then
                local exists = false
                local check_stmt = cache_conn:prepare("SELECT 1 FROM bookinfo WHERE directory = ? AND filename = ?")
                if check_stmt then
                    check_stmt:bind(dir, fname)
                    for _ in check_stmt:rows() do exists = true; break end
                    check_stmt:close()
                end

                if exists then
                    local sets = {}
                    local vals = {}
                    if e.remote_title and e.remote_title ~= "" then
                        sets[#sets + 1] = "title = ?"; vals[#vals + 1] = e.remote_title
                    end
                    if e.remote_author and e.remote_author ~= "" then
                        sets[#sets + 1] = "authors = ?"; vals[#vals + 1] = e.remote_author
                    end
                    if has_series and e.remote_series_name and e.remote_series_name ~= "" then
                        sets[#sets + 1] = "series = ?"; vals[#vals + 1] = e.remote_series_name
                    end
                    if has_series_index and e.remote_series_number then
                        sets[#sets + 1] = "series_index = ?"; vals[#vals + 1] = e.remote_series_number
                    end
                    if #sets > 0 then
                        vals[#vals + 1] = dir; vals[#vals + 1] = fname
                        local sql = "UPDATE bookinfo SET " .. table.concat(sets, ", ") .. " WHERE directory = ? AND filename = ?"
                        local upd_stmt = cache_conn:prepare(sql)
                        if upd_stmt then
                            upd_stmt:bind(unpack(vals)); upd_stmt:step(); upd_stmt:close()
                            counts.updated = counts.updated + 1
                        else counts.skipped = counts.skipped + 1 end
                    else counts.skipped = counts.skipped + 1 end
                else
                    local col_names = { "directory", "filename" }
                    local placeholders = { "?", "?" }
                    local vals = { dir, fname }
                    if e.remote_title and e.remote_title ~= "" then
                        col_names[#col_names+1]="title"; placeholders[#placeholders+1]="?"; vals[#vals+1]=e.remote_title
                    end
                    if e.remote_author and e.remote_author ~= "" then
                        col_names[#col_names+1]="authors"; placeholders[#placeholders+1]="?"; vals[#vals+1]=e.remote_author
                    end
                    if has_series and e.remote_series_name and e.remote_series_name ~= "" then
                        col_names[#col_names+1]="series"; placeholders[#placeholders+1]="?"; vals[#vals+1]=e.remote_series_name
                    end
                    if has_series_index and e.remote_series_number then
                        col_names[#col_names+1]="series_index"; placeholders[#placeholders+1]="?"; vals[#vals+1]=e.remote_series_number
                    end
                    if columns["has_meta"] then
                        col_names[#col_names+1]="has_meta"; placeholders[#placeholders+1]="?"; vals[#vals+1]="Y"
                    end
                    local sql = "INSERT INTO bookinfo (" .. table.concat(col_names, ", ") ..
                        ") VALUES (" .. table.concat(placeholders, ", ") .. ")"
                    local ins_stmt = cache_conn:prepare(sql)
                    if ins_stmt then
                        ins_stmt:bind(unpack(vals)); ins_stmt:step(); ins_stmt:close()
                        counts.inserted = counts.inserted + 1
                    else counts.skipped = counts.skipped + 1 end
                end
            else counts.skipped = counts.skipped + 1 end
        else counts.skipped = counts.skipped + 1 end
    end

    cache_conn:exec("COMMIT")
    cache_conn:close()

    logger.info("GrimmLink: bookinfo_cache upsert complete",
        "| inserted:", counts.inserted,
        "| updated:", counts.updated,
        "| skipped:", counts.skipped)
    return counts
end

--- Delete a single book's row from bookinfo_cache.sqlite3.
function ShelfSync:deleteFromBookInfoCache(local_path)
    local norm = normalizePath(local_path)
    if not norm then return false end
    local dir = norm:match("^(.*)/[^/]+$") or ""
    local fname = norm:match("([^/]+)$") or ""
    if fname == "" then return false end

    local cache_conn = openBookInfoCache()
    if not cache_conn then return false end

    local SQ3 = require("lua-ljsqlite3/init")
    local stmt = cache_conn:prepare("DELETE FROM bookinfo WHERE directory = ? AND filename = ?")
    local ok = false
    if stmt then
        stmt:bind(dir, fname)
        ok = stmt:step() == SQ3.DONE
        stmt:close()
    end
    cache_conn:close()
    if ok then
        logger.info("GrimmLink: removed bookinfo_cache row:", dir .. "/" .. fname)
    end
    return ok
end

--- Rebuild bookinfo_cache from grimmlink_metadata_index.json.
-- Use when CoverBrowser rescan has overwritten GrimmLink metadata.
function ShelfSync:rebuildBookInfoCacheFromIndex(download_dir)
    local index_path = joinPath(download_dir, "grimmlink_metadata_index.json")
    local fh = io.open(index_path, "r")
    if not fh then
        logger.warn("GrimmLink: metadata index not found:", index_path)
        return { inserted = 0, updated = 0, skipped = 0, error = "index_not_found" }
    end
    local raw = fh:read("*a")
    fh:close()

    local json = require("json")
    local ok_decode, index = pcall(json.decode, raw)
    if not ok_decode or type(index) ~= "table" then
        logger.warn("GrimmLink: failed to parse metadata index")
        return { inserted = 0, updated = 0, skipped = 0, error = "parse_failed" }
    end

    local cache_conn, cache_path, columns = openBookInfoCache()
    if not cache_conn then
        return { inserted = 0, updated = 0, skipped = 0, error = "cache_unavailable" }
    end

    backupBookInfoCacheOnce(cache_path)

    local has_series = columns["series"]
    local has_series_index = columns["series_index"]
    local counts = { inserted = 0, updated = 0, skipped = 0 }

    cache_conn:exec("BEGIN TRANSACTION")

    for _, entry in ipairs(index) do
        local dir = entry.directory or ""
        local fname = entry.filename or ""
        local full_path = dir ~= "" and (dir .. "/" .. fname) or fname
        local file_attr = fname ~= "" and lfs.attributes(full_path)
        if fname ~= "" and file_attr and file_attr.mode == "file" then
            local exists = false
            local chk = cache_conn:prepare("SELECT 1 FROM bookinfo WHERE directory = ? AND filename = ?")
            if chk then
                chk:bind(dir, fname)
                for _ in chk:rows() do exists = true; break end
                chk:close()
            end

            if exists then
                local sets, vals = {}, {}
                if entry.title and entry.title ~= "" then
                    sets[#sets + 1] = "title = ?"; vals[#vals + 1] = entry.title
                end
                if entry.author and entry.author ~= "" then
                    sets[#sets + 1] = "authors = ?"; vals[#vals + 1] = entry.author
                end
                if has_series and entry.series and entry.series ~= "" then
                    sets[#sets + 1] = "series = ?"; vals[#vals + 1] = entry.series
                end
                if has_series_index and entry.seriesIndex then
                    sets[#sets + 1] = "series_index = ?"; vals[#vals + 1] = entry.seriesIndex
                end
                if #sets > 0 then
                    vals[#vals + 1] = dir; vals[#vals + 1] = fname
                    local sql = "UPDATE bookinfo SET " .. table.concat(sets, ", ") .. " WHERE directory = ? AND filename = ?"
                    local s = cache_conn:prepare(sql)
                    if s then s:bind(unpack(vals)); s:step(); s:close(); counts.updated = counts.updated + 1 end
                end
            else
                local col_names = { "directory", "filename" }
                local placeholders = { "?", "?" }
                local vals = { dir, fname }
                if entry.title then col_names[#col_names+1]="title"; placeholders[#placeholders+1]="?"; vals[#vals+1]=entry.title end
                if entry.author then col_names[#col_names+1]="authors"; placeholders[#placeholders+1]="?"; vals[#vals+1]=entry.author end
                if has_series and entry.series then col_names[#col_names+1]="series"; placeholders[#placeholders+1]="?"; vals[#vals+1]=entry.series end
                if has_series_index and entry.seriesIndex then col_names[#col_names+1]="series_index"; placeholders[#placeholders+1]="?"; vals[#vals+1]=entry.seriesIndex end
                if columns["has_meta"] then col_names[#col_names+1]="has_meta"; placeholders[#placeholders+1]="?"; vals[#vals+1]="Y" end
                local sql = "INSERT INTO bookinfo (" .. table.concat(col_names, ", ") .. ") VALUES (" .. table.concat(placeholders, ", ") .. ")"
                local s = cache_conn:prepare(sql)
                if s then s:bind(unpack(vals)); s:step(); s:close(); counts.inserted = counts.inserted + 1 end
            end
        else
            counts.skipped = counts.skipped + 1
        end
    end

    cache_conn:exec("COMMIT")
    cache_conn:close()

    logger.info("GrimmLink: bookinfo_cache rebuild complete",
        "| inserted:", counts.inserted, "| updated:", counts.updated, "| skipped:", counts.skipped)
    return counts
end

--- Remove a book from metadata tracking (called on shelf remove).
-- Adds tombstone and deletes from bookinfo_cache.
-- The caller is responsible for rewriting the metadata index after
-- the batch operation completes (writeMetadataIndex in finishSync).
function ShelfSync:removeBookMetadata(entry, shelf_id)
    if not entry or not entry.book_id then return end

    if self.db and self.db.addShelfSyncTombstone then
        self.db:addShelfSyncTombstone({
            book_id = entry.book_id,
            shelf_id = shelf_id,
            local_path = entry.local_path,
            remote_title = entry.remote_title,
            remote_series_name = entry.remote_series_name,
        })
    end

    if entry.local_path and entry.local_path ~= "" then
        self:deleteFromBookInfoCache(entry.local_path)
    end
end

return ShelfSync
