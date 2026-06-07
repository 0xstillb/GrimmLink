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

local function normalizeShelfType(value)
    local shelf_type = tostring(value or "regular"):lower()
    if shelf_type ~= "magic" then
        return "regular"
    end
    return shelf_type
end

local function resolveBookFormat(book_info)
    if type(book_info) ~= "table" then
        return nil
    end

    local raw = book_info.fileFormat or book_info.file_format or book_info.extension
    if (raw == nil or tostring(raw) == "") and book_info.fileName then
        raw = tostring(book_info.fileName):match("%.([%w]+)$")
    end
    if raw == nil then
        return nil
    end

    local normalized = tostring(raw):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%.", ""):lower()
    normalized = normalized:gsub("[?#].*$", "")
    local slash_value = normalized:match("/([%w%+%-%.]+)$")
    if slash_value and slash_value ~= "" then
        normalized = slash_value
    end
    if normalized == "epub+zip" or normalized == "x-epub+zip" then
        normalized = "epub"
    elseif normalized == "x-pdf" then
        normalized = "pdf"
    end
    if normalized == "" then
        return nil
    end
    return normalized
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

local function safeLfsAttributes(path)
    if not path or path == "" or not lfs or type(lfs.attributes) ~= "function" then
        return nil
    end
    local ok, attr = pcall(lfs.attributes, path)
    if ok then
        return attr
    end
    return nil
end

local function safeRequireAny(names)
    if type(names) ~= "table" then
        return nil, nil
    end
    for _, name in ipairs(names) do
        local ok, mod = pcall(require, name)
        if ok and mod then
            return mod, name
        end
    end
    return nil, nil
end

local function addUniquePathToList(file_paths, seen_paths, file_path)
    if type(file_paths) ~= "table" then
        return false
    end
    local normalized = normalizePathForCompare(file_path)
    if not normalized then
        return false
    end
    if type(seen_paths) == "table" then
        if seen_paths[normalized] then
            return false
        end
        seen_paths[normalized] = true
    end
    file_paths[#file_paths + 1] = file_path
    return true
end

local function resolveCoverSpecs(cover_specs)
    if type(cover_specs) == "table"
        and tonumber(cover_specs.max_cover_w)
        and tonumber(cover_specs.max_cover_h)
        and tonumber(cover_specs.max_cover_w) > 0
        and tonumber(cover_specs.max_cover_h) > 0 then
        return {
            max_cover_w = math.floor(tonumber(cover_specs.max_cover_w)),
            max_cover_h = math.floor(tonumber(cover_specs.max_cover_h)),
        }
    end

    local FileManager = safeRequireAny({
        "apps/filemanager/filemanager",
    })
    local fm_instance = FileManager and FileManager.instance or nil
    local chooser_specs = fm_instance and fm_instance.file_chooser and fm_instance.file_chooser.cover_specs or nil
    if type(chooser_specs) == "table"
        and tonumber(chooser_specs.max_cover_w)
        and tonumber(chooser_specs.max_cover_h)
        and tonumber(chooser_specs.max_cover_w) > 0
        and tonumber(chooser_specs.max_cover_h) > 0 then
        return {
            max_cover_w = math.floor(tonumber(chooser_specs.max_cover_w)),
            max_cover_h = math.floor(tonumber(chooser_specs.max_cover_h)),
        }
    end

    local ok_device, Device = pcall(require, "device")
    local screen = ok_device and Device and Device.screen or nil
    local width = screen and screen.getWidth and tonumber(screen:getWidth()) or nil
    local height = screen and screen.getHeight and tonumber(screen:getHeight()) or nil
    if width and width > 0 and height and height > 0 then
        return {
            max_cover_w = math.max(96, math.floor(width * 0.42)),
            max_cover_h = math.max(128, math.floor(height * 0.52)),
        }
    end

    return {
        max_cover_w = 256,
        max_cover_h = 384,
    }
end

-- Build a safe local filename for a book.
-- Prefers the remote filename when use_original is true and remote_filename is set.
-- Falls back to title + book_id + extension.
function ShelfSync:buildSafeFilename(book_info, use_original)
    if use_original and book_info.fileName and book_info.fileName ~= "" then
        local sanitized = sanitizeFilename(book_info.fileName)
        if sanitized then return sanitized end
    end

    local ext = resolveBookFormat(book_info) or "epub"
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

    -- Read KOReader Home folder as an optional fallback root.
    -- Do not prioritize it over DataStorage:getDataDir() because we want
    -- stable auto-path behavior at "<koreader>/Book".
    local home_dir = nil
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local ok_home, value = pcall(G_reader_settings.readSetting, G_reader_settings, "home_dir")
        if ok_home and type(value) == "string" and value ~= "" then
            home_dir = value
        end
    end

    -- Auto-detect a sensible KOReader books directory, then dedicate a
    -- subfolder to GrimmLink downloads so synced books stay grouped together.
    -- Prefer "<base>/Book" directly (for example: ".../koreader/Book").
    -- /mnt/us/documents is Kindle-specific and indexed by Kindle's native library.
    local data_dir = DataStorage:getDataDir()
    local candidates = {
        "/mnt/us/documents",
        data_dir,
        data_dir .. "/books",
    }
    if home_dir and home_dir ~= "" then
        candidates[#candidates + 1] = home_dir
    end
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

local function basenameOfPath(path)
    if not path or path == "" then
        return ""
    end
    return path:match("([^/\\]+)$") or path
end

local function normalizeManagedRoots(roots)
    local normalized = {}
    for _, root in ipairs(roots or {}) do
        if root and root ~= "" then
            normalized[#normalized + 1] = root
        end
    end
    return normalized
end

local function buildManagedDeleteRoots(sync, download_dir)
    local managed_roots = {
        download_dir,
    }

    if sync and type(sync.resolveDownloadDir) == "function" then
        local ok_resolve, resolved_dir = pcall(sync.resolveDownloadDir, sync, download_dir)
        if ok_resolve and resolved_dir and resolved_dir ~= "" then
            managed_roots[#managed_roots + 1] = resolved_dir
        end
    end

    managed_roots[#managed_roots + 1] = DataStorage:getDataDir()
    managed_roots[#managed_roots + 1] = DataStorage:getSettingsDir()
    return normalizeManagedRoots(managed_roots)
end

local function chooseSdrTargetPath(source_sdr_path, source_book_path, target_book_path)
    if source_sdr_path == source_book_path .. ".sdr" then
        return target_book_path .. ".sdr"
    end
    local source_base = source_book_path:match("^(.*)%.([^/\\]+)$")
    local target_base = target_book_path:match("^(.*)%.([^/\\]+)$")
    if source_base and target_base and source_sdr_path == source_base .. ".sdr" then
        return target_base .. ".sdr"
    end
    return target_book_path .. ".sdr"
end

local function moveSdrSidecarsWithWarning(source_path, target_path)
    local warning_count = 0
    for _, sdr_path in ipairs(getSdrCandidatePaths(source_path)) do
        local attr = safeLfsAttributes(sdr_path)
        if attr and attr.mode == "directory" then
            local target_sdr_path = chooseSdrTargetPath(sdr_path, source_path, target_path)
            if sdr_path ~= target_sdr_path then
                local target_attr = safeLfsAttributes(target_sdr_path)
                if target_attr then
                    warning_count = warning_count + 1
                    logger.warn("GrimmLink ShelfSync: .sdr target already exists, keeping source sidecar:", target_sdr_path)
                else
                    local moved, move_err = os.rename(sdr_path, target_sdr_path)
                    if moved then
                        logger.info("GrimmLink ShelfSync: moved .sdr sidecar:", sdr_path, "=>", target_sdr_path)
                    else
                        warning_count = warning_count + 1
                        logger.warn(
                            "GrimmLink ShelfSync: failed to move .sdr sidecar:",
                            sdr_path,
                            "=>",
                            target_sdr_path,
                            tostring(move_err)
                        )
                    end
                end
            end
        end
    end
    return warning_count
end

-- Safely delete a tracked book and optionally its .sdr sidecar.
-- Only deletes files where downloaded_by_grimmlink == 1.
function ShelfSync:deleteLocalBook(entry, delete_sdr, download_dir)
    local managed_roots = buildManagedDeleteRoots(self, download_dir)
    if self.deletion and type(self.deletion.evaluateLocalDeletePolicy) == "function" then
        local allow_delete, reason = self.deletion:evaluateLocalDeletePolicy(entry, {
            managed_roots = managed_roots,
        })
        if not allow_delete then
            logger.warn("GrimmLink ShelfSync: skip delete (" .. tostring(reason) .. "):", entry and entry.local_path or "")
            return false, reason
        end
    else
        if entry.downloaded_by_grimmlink ~= 1 then
            logger.warn("GrimmLink ShelfSync: skip delete (not downloaded by GrimmLink):", entry.local_path)
            return false, "not_downloaded_by_grimmlink"
        end
        if entry.local_path and entry.local_path ~= "" then
            if not isPathUnderAnyDirectory(entry.local_path, managed_roots) then
                logger.warn("GrimmLink ShelfSync: skip delete (outside managed roots):", entry.local_path)
                return false, "outside_managed_roots"
            end
        end
    end

    if not entry.local_path or entry.local_path == "" then
        self.db:deleteShelfSyncEntry(entry.book_id, entry.shelf_id, entry.shelf_type)
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

    self.db:deleteShelfSyncEntry(entry.book_id, entry.shelf_id, entry.shelf_type)
    return true
end

function ShelfSync:resolveDownloadDirForShelfType(shelf_type, settings)
    local normalized_type = normalizeShelfType(shelf_type)
    local current_settings = settings or {}
    if normalized_type == "magic"
        and current_settings.use_separate_magic_download_dir == true
        and current_settings.magic_download_dir
        and current_settings.magic_download_dir ~= "" then
        return current_settings.magic_download_dir
    end
    return current_settings.download_dir
end

local function upsertMagicMappingsForBook(db, book_id, local_path)
    if not db or type(db.getShelfMappingsForBook) ~= "function" then
        return false
    end
    local mappings = db:getShelfMappingsForBook(book_id)
    local updated = false
    for _, mapping in ipairs(mappings) do
        if normalizeShelfType(mapping.shelf_type) == "magic" then
            local ok = false
            if type(db.updateShelfMappingLocalPath) == "function" then
                ok = db:updateShelfMappingLocalPath(mapping.book_id, mapping.shelf_id, mapping.shelf_type, local_path)
            elseif type(db.upsertShelfSyncEntry) == "function" then
                mapping.local_path = local_path
                ok = db:upsertShelfSyncEntry(mapping)
            end
            updated = ok or updated
        end
    end
    return updated
end

local function collectMagicOnlyMappings(db)
    if not db then
        return {}
    end
    if type(db.getMagicOnlyShelfMappings) == "function" then
        return db:getMagicOnlyShelfMappings()
    end
    local all = type(db.getAllShelfSyncEntries) == "function" and db:getAllShelfSyncEntries() or {}
    local regular_books = {}
    for _, entry in ipairs(all) do
        if normalizeShelfType(entry.shelf_type) == "regular" then
            regular_books[tostring(entry.book_id)] = true
        end
    end
    local result = {}
    for _, entry in ipairs(all) do
        if normalizeShelfType(entry.shelf_type) == "magic"
            and not regular_books[tostring(entry.book_id)] then
            result[#result + 1] = entry
        end
    end
    return result
end

local function incrementSummary(summary, key)
    summary[key] = (tonumber(summary[key]) or 0) + 1
end

local function recordMoveSkip(summary, reason, warning)
    summary.skipped = summary.skipped + 1
    if reason and reason ~= "" then
        incrementSummary(summary, reason)
    end
    if warning and warning ~= "" then
        summary.warnings[#summary.warnings + 1] = warning
    end
end

local function addFallbackCandidate(candidates, seen, source_root, filename)
    if not source_root or source_root == "" or not filename or filename == "" then
        return
    end
    local cleaned = basenameOfPath(tostring(filename))
    if cleaned == "" or cleaned == "." or cleaned == ".." then
        return
    end
    local path = joinPath(source_root, cleaned)
    local normalized = normalizePathForCompare(path)
    if normalized and not seen[normalized] then
        seen[normalized] = true
        candidates[#candidates + 1] = path
    end
end

local function addSanitizedFallbackCandidate(candidates, seen, source_root, filename)
    local sanitized = sanitizeFilename(filename)
    if sanitized and sanitized ~= "" then
        addFallbackCandidate(candidates, seen, source_root, sanitized)
    end
end

local function getMappingFallbackExtension(mapping)
    local ext = resolveBookFormat({
        fileName = mapping.remote_filename,
        fileFormat = mapping.remote_format,
        extension = mapping.remote_format,
    })
    if ext and ext ~= "" then
        return ext
    end
    local local_ext = mapping.local_path and tostring(mapping.local_path):match("%.([%w]+)$") or nil
    if local_ext and local_ext ~= "" then
        return local_ext:lower()
    end
    return nil
end

local function findFallbackSourcePath(mapping, source_root)
    if not source_root or source_root == "" or type(mapping) ~= "table" then
        return nil
    end

    local candidates = {}
    local seen = {}
    addFallbackCandidate(candidates, seen, source_root, basenameOfPath(mapping.local_path))
    addFallbackCandidate(candidates, seen, source_root, mapping.remote_filename)
    addSanitizedFallbackCandidate(candidates, seen, source_root, mapping.remote_filename)

    local ext = getMappingFallbackExtension(mapping)
    if ext and ext ~= "" then
        if mapping.remote_title and tostring(mapping.remote_title) ~= "" and mapping.book_id then
            addSanitizedFallbackCandidate(
                candidates,
                seen,
                source_root,
                tostring(mapping.remote_title) .. "_" .. tostring(mapping.book_id) .. "." .. ext
            )
        end
        if mapping.book_id then
            addSanitizedFallbackCandidate(
                candidates,
                seen,
                source_root,
                "book_" .. tostring(mapping.book_id) .. "." .. ext
            )
        end
    end

    for _, candidate in ipairs(candidates) do
        local attr = safeLfsAttributes(candidate)
        if attr and attr.mode == "file" then
            return candidate
        end
    end
    return nil
end

local function resolveMoveSourcePath(mapping, source_root, managed_roots, options)
    local local_path = mapping.local_path
    local allow_fallback = options and options.allow_source_fallback == true
    local source_path = local_path
    local used_fallback = false

    if not source_path or source_path == "" then
        return nil, "skipped_empty_local_path"
    end

    local source_attr = safeLfsAttributes(source_path)
    if source_root and source_root ~= "" and not isPathUnderDirectory(source_path, source_root) then
        if allow_fallback then
            local fallback_path = findFallbackSourcePath(mapping, source_root)
            if fallback_path then
                source_path = fallback_path
                source_attr = safeLfsAttributes(source_path)
                used_fallback = true
            else
                return nil, "skipped_not_magic_path"
            end
        else
            return nil, "skipped_not_magic_path"
        end
    end

    if not isPathUnderAnyDirectory(source_path, managed_roots) then
        return nil, "skipped_outside_managed_roots"
    end

    if not source_attr or source_attr.mode ~= "file" then
        if allow_fallback then
            local fallback_path = findFallbackSourcePath(mapping, source_root)
            if fallback_path and normalizePathForCompare(fallback_path) ~= normalizePathForCompare(source_path) then
                source_path = fallback_path
                source_attr = safeLfsAttributes(source_path)
                used_fallback = true
            end
        end
    end

    if not source_attr or source_attr.mode ~= "file" then
        return nil, "skipped_missing_file"
    end

    return source_path, nil, used_fallback
end

local function logMoveSkipSummary(summary)
    if not summary or not logger or type(logger.info) ~= "function" then
        return
    end
    logger.info(
        "GrimmLink ShelfSync: Magic file move summary:",
        "moved=" .. tostring(summary.moved),
        "shared=" .. tostring(summary.shared),
        "skipped=" .. tostring(summary.skipped),
        "failed=" .. tostring(summary.failed),
        "skipped_not_magic_path=" .. tostring(summary.skipped_not_magic_path or 0),
        "skipped_not_downloaded_by_grimmlink=" .. tostring(summary.skipped_not_downloaded_by_grimmlink or 0),
        "skipped_missing_file=" .. tostring(summary.skipped_missing_file or 0),
        "skipped_outside_managed_roots=" .. tostring(summary.skipped_outside_managed_roots or 0)
    )
end

local function moveMagicOnlyFiles(self, source_root, target_root, opts)
    local options = opts or {}
    local summary = {
        moved = 0,
        skipped = 0,
        failed = 0,
        shared = 0,
        sidecar_warnings = 0,
        skipped_empty_local_path = 0,
        skipped_not_magic_path = 0,
        skipped_not_downloaded_by_grimmlink = 0,
        skipped_shared_regular = 0,
        skipped_missing_file = 0,
        skipped_outside_managed_roots = 0,
        warnings = {},
        errors = {},
    }

    if not target_root or target_root == "" then
        summary.errors[#summary.errors + 1] = "target directory is empty"
        summary.failed = summary.failed + 1
        return summary
    end

    if not ensureDirectory(target_root) then
        summary.errors[#summary.errors + 1] = "target directory cannot be created: " .. tostring(target_root)
        summary.failed = summary.failed + 1
        return summary
    end

    local managed_roots = normalizeManagedRoots({
        source_root,
        target_root,
        options.download_dir,
        options.magic_download_dir,
        DataStorage:getDataDir(),
        DataStorage:getSettingsDir(),
    })

    local mappings = collectMagicOnlyMappings(self.db)
    local processed_books = {}
    for _, mapping in ipairs(mappings) do
        local book_id = mapping.book_id
        local book_key = tostring(book_id or "")
        if book_id and not processed_books[book_key] then
            processed_books[book_key] = true

            if mapping.downloaded_by_grimmlink ~= 1 and mapping.downloaded_by_grimmlink ~= true then
                recordMoveSkip(summary, "skipped_not_downloaded_by_grimmlink")
            elseif type(self.db.isBookTrackedByRegularShelf) == "function" and self.db:isBookTrackedByRegularShelf(book_id) then
                summary.shared = summary.shared + 1
                incrementSummary(summary, "skipped_shared_regular")
            else
                local local_path = mapping.local_path
                local source_path, skip_reason, used_fallback = resolveMoveSourcePath(mapping, source_root, managed_roots, options)
                if not source_path then
                    local warning = nil
                    if skip_reason == "skipped_outside_managed_roots" then
                        warning = "Skipped outside managed roots for bookId=" .. tostring(book_id)
                    elseif skip_reason == "skipped_not_magic_path" and options.allow_source_fallback == true then
                        warning = "Skipped missing Magic folder source for bookId=" .. tostring(book_id)
                    end
                    recordMoveSkip(summary, skip_reason, warning)
                else
                    local filename = basenameOfPath(source_path)
                    local desired_target = joinPath(target_root, filename)
                    local final_target = desired_target
                    local reuse_existing = false

                    local target_attr = safeLfsAttributes(final_target)
                    if target_attr and target_attr.mode == "file" then
                        local same_target_entry = type(self.db.getShelfSyncEntryByLocalPath) == "function"
                            and self.db:getShelfSyncEntryByLocalPath(final_target) or nil
                        if same_target_entry and tonumber(same_target_entry.book_id) == tonumber(book_id) then
                            reuse_existing = true
                        else
                            final_target = uniquePath(target_root, filename)
                            local final_attr = safeLfsAttributes(final_target)
                            if final_attr then
                                summary.failed = summary.failed + 1
                                summary.errors[#summary.errors + 1] =
                                    "Target exists and unique path unavailable for bookId=" .. tostring(book_id)
                                final_target = nil
                            end
                        end
                    end

                    if final_target then
                        local move_ok = true
                        local moved_file = false
                        if not reuse_existing and normalizePathForCompare(source_path) ~= normalizePathForCompare(final_target) then
                            local renamed, rename_err = os.rename(source_path, final_target)
                            move_ok = renamed and true or false
                            if not move_ok then
                                summary.failed = summary.failed + 1
                                summary.errors[#summary.errors + 1] =
                                    "Failed to move bookId=" .. tostring(book_id) .. ": " .. tostring(rename_err)
                            else
                                moved_file = true
                            end
                        end

                        if move_ok then
                            local mapping_ok = upsertMagicMappingsForBook(self.db, book_id, final_target)
                            if mapping_ok then
                                local sidecar_warnings = 0
                                if moved_file then
                                    sidecar_warnings = moveSdrSidecarsWithWarning(source_path, final_target)
                                    if type(self.deleteFromBookInfoCache) == "function" then
                                        self:deleteFromBookInfoCache(source_path)
                                        if local_path and normalizePathForCompare(local_path) ~= normalizePathForCompare(source_path) then
                                            self:deleteFromBookInfoCache(local_path)
                                        end
                                    end
                                end
                                summary.sidecar_warnings = summary.sidecar_warnings + sidecar_warnings
                                if moved_file then
                                    summary.moved = summary.moved + 1
                                    if used_fallback then
                                        incrementSummary(summary, "fallback_sources_used")
                                    end
                                else
                                    recordMoveSkip(summary, "skipped_already_at_target")
                                end
                                if self.db and type(self.db.saveBookCache) == "function" then
                                    self.db:saveBookCache(final_target, "", book_id, mapping.remote_title, mapping.remote_author)
                                end
                            else
                                if moved_file then
                                    local rolled_back, rollback_err = os.rename(final_target, source_path)
                                    if not rolled_back then
                                        summary.warnings[#summary.warnings + 1] =
                                            "Rollback failed after DB update failure for bookId="
                                            .. tostring(book_id)
                                            .. ": "
                                            .. tostring(rollback_err)
                                    end
                                end
                                summary.failed = summary.failed + 1
                                summary.errors[#summary.errors + 1] =
                                    "Failed to update DB local_path for magic mappings, bookId=" .. tostring(book_id)
                            end
                        end
                    end
                end
            end
        end
    end

    logMoveSkipSummary(summary)
    return summary
end

function ShelfSync:moveMagicShelfFilesToDirectory(target_dir, opts)
    local options = opts or {}
    return moveMagicOnlyFiles(self, options.shared_dir, target_dir, {
        download_dir = options.download_dir,
        magic_download_dir = target_dir,
    })
end

function ShelfSync:moveMagicShelfFilesBackToSharedDirectory(shared_dir, opts)
    local options = opts or {}
    return moveMagicOnlyFiles(self, options.magic_dir, shared_dir, {
        download_dir = shared_dir,
        magic_download_dir = options.magic_dir,
        allow_source_fallback = true,
    })
end

function ShelfSync:processPendingShelfRemovals(shelf_id, shelf_type, download_dir, delete_sdr, skip_download_ids, result, progress)
    if self.pending_sync and type(self.pending_sync.processPendingShelfRemovals) == "function" then
        local pending_plugin = self.plugin
        if not pending_plugin then
            pending_plugin = {
                db = self.db,
                api = self.api,
            }
            if self.pending_shelf_removal_retry_cooldown_seconds then
                pending_plugin.pending_shelf_removal_retry_cooldown_seconds = self.pending_shelf_removal_retry_cooldown_seconds
            end
        end
        local handled = self.pending_sync:processPendingShelfRemovals(pending_plugin, {
            shelf_sync = self,
            shelf_id = shelf_id,
            shelf_type = shelf_type,
            download_dir = download_dir,
            delete_sdr = delete_sdr,
            skip_download_ids = skip_download_ids,
            result = result,
            progress = progress,
            retry_cooldown_seconds = self.pending_shelf_removal_retry_cooldown_seconds,
        })
        if handled then
            return
        end
    end

    local normalized_type = normalizeShelfType(shelf_type)
    local pending_entries = self.db:getPendingShelfRemovals(shelf_id, normalized_type)
    for _, entry in ipairs(pending_entries) do
        if entry.book_id then
            skip_download_ids[tostring(entry.book_id)] = true
            if progress then
                progress("Removing pending: " .. (entry.local_path or tostring(entry.book_id)))
            end
            local ok, response_or_err = self.api:removeBookFromShelf(entry.shelf_id, entry.book_id, normalized_type)
            if ok then
                local tracked = nil
                if self.db.getShelfMapping then
                    tracked = self.db:getShelfMapping(entry.book_id, entry.shelf_id, normalized_type)
                else
                    tracked = self.db:getShelfSyncEntry(entry.book_id)
                end
                local keep_local = tracked
                    and self.db.isBookTrackedInOtherShelf
                    and self.db:isBookTrackedInOtherShelf(entry.book_id, entry.shelf_id, normalized_type)
                local deleted_ok = true
                if tracked and keep_local then
                    logger.info("GrimmLink ShelfSync: kept local file because another shelf still tracks bookId=" .. tostring(entry.book_id))
                    if self.db.removeShelfMappingOnly then
                        deleted_ok = self.db:removeShelfMappingOnly(entry.book_id, entry.shelf_id, normalized_type)
                    else
                        deleted_ok = self.db:deleteShelfSyncEntry(entry.book_id)
                    end
                elseif tracked then
                    deleted_ok = self:deleteLocalBook(tracked, delete_sdr, download_dir)
                end
                if deleted_ok then
                    if tracked and not keep_local then
                        self:removeBookMetadata(tracked, shelf_id, normalized_type)
                    end
                    self.db:deletePendingShelfRemoval(entry.book_id, entry.shelf_id, normalized_type)
                    result.deleted = result.deleted + 1
                else
                    self.db:incrementPendingShelfRemovalRetryCount(entry.book_id, entry.shelf_id, normalized_type)
                    result.failed = result.failed + 1
                    result.errors[#result.errors + 1] = "Failed to delete local file for pending bookId=" .. tostring(entry.book_id)
                end
            else
                self.db:incrementPendingShelfRemovalRetryCount(entry.book_id, entry.shelf_id, normalized_type)
                result.failed = result.failed + 1
                result.errors[#result.errors + 1] = "Failed to remove pending bookId=" .. tostring(entry.book_id) .. ": " .. tostring(response_or_err)
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

local function classifyShelfFetchError(fetch_code, fetch_error)
    local message = tostring(fetch_error or "")
    local lower = message:lower()
    if tonumber(fetch_code) == 401 then
        return "Shelf sync failed: authentication failed (401). Check username/password."
    end
    if tonumber(fetch_code) == 403 then
        return "Shelf sync failed: access denied to shelf (403)."
    end
    if tonumber(fetch_code) == 404 then
        return "Shelf sync failed: shelf endpoint not found (404). Check server URL and shelf settings."
    end
    if lower:find("server url not configured", 1, true) then
        return "Shelf sync failed: server URL is not configured."
    end
    if lower:find("dns", 1, true) or lower:find("name resolution", 1, true) then
        return "Shelf sync failed: DNS lookup failed. Verify URL and network."
    end
    if lower:find("timeout", 1, true) then
        return "Shelf sync failed: network timeout while fetching shelf books."
    end
    if lower:find("connection", 1, true) or lower:find("refused", 1, true) then
        return "Shelf sync failed: cannot reach server (connection error)."
    end
    local err = "Shelf sync failed to fetch shelf books"
    if fetch_code ~= nil then
        err = err .. " (HTTP " .. tostring(fetch_code) .. ")"
    end
    return err .. ": " .. message
end

local function computeShelfSnapshotToken(remote_books)
    if type(remote_books) ~= "table" then
        return nil
    end
    local lines = {}
    for _, book in ipairs(remote_books) do
        local book_id = tonumber(book.bookId or book.id or book.book_id) or 0
        local name = tostring(book.fileName or "")
        local size_kb = tonumber(book.fileSizeKb or book.file_size_kb) or 0
        local fmt = tostring(book.fileFormat or book.file_format or book.extension or "")
        lines[#lines + 1] = tostring(book_id) .. "|" .. name .. "|" .. tostring(size_kb) .. "|" .. fmt
    end
    table.sort(lines)

    local mod = 65521
    local a, b = 1, 0
    for _, line in ipairs(lines) do
        for i = 1, #line do
            a = (a + string.byte(line, i)) % mod
            b = (b + a) % mod
        end
    end
    return tostring(#lines) .. ":" .. tostring(a) .. ":" .. tostring(b)
end

local buildShelfIdSet

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
    local default_result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
    local default_plan = { result = default_result, download_queue = {}, cleanup = nil }

    if type(opts) ~= "table" then
        default_result.errors[#default_result.errors + 1] = "Invalid shelf sync options"
        return default_plan
    end
    if not self.db then
        default_result.errors[#default_result.errors + 1] = "Database unavailable"
        return default_plan
    end
    if not self.api then
        default_result.errors[#default_result.errors + 1] = "API client unavailable"
        return default_plan
    end

    local plan_batch_size = tonumber(opts.plan_batch_size)
    if plan_batch_size and plan_batch_size < 1 then
        plan_batch_size = 1
    end

    local function progress(msg)
        if opts.on_progress then opts.on_progress(msg) end
        logger.info("GrimmLink ShelfSync:", msg)
    end

    local state = opts.plan_state
    local plan = nil
    local result = nil
    local shelf_id = nil
    local shelf_type = nil
    local remote_books = nil
    local sync_start = nil
    local download_dir = nil
    local use_original = nil
    local skip_download_ids = nil
    local shelf_entry_by_book = nil
    local reusable_mapping_by_book = nil

    if type(state) == "table"
        and type(state.remote_books) == "table"
        and type(state.result) == "table"
        and type(state.download_queue) == "table"
        and type(state.cleanup) == "table" then
        result = state.result
        plan = {
            result = result,
            download_queue = state.download_queue,
            cleanup = state.cleanup,
        }
        shelf_id = state.shelf_id
        shelf_type = state.shelf_type
        remote_books = state.remote_books
        sync_start = state.sync_start
        download_dir = state.download_dir
        use_original = state.use_original
        skip_download_ids = state.skip_download_ids or {}
        shelf_entry_by_book = state.shelf_entry_by_book or {}
        reusable_mapping_by_book = state.reusable_mapping_by_book or {}
        state.next_index = math.max(1, tonumber(state.next_index) or 1)
    else
        result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
        plan = { result = result, download_queue = {}, cleanup = nil }

        shelf_id = tonumber(opts.shelf_id) or opts.shelf_id
        shelf_type = normalizeShelfType(opts.shelf_type)

        remote_books = opts.preloaded_remote_books
        if type(remote_books) == "table" then
            progress("Using cached shelf books snapshot...")
        else
            progress("Fetching shelf books from server...")
            local ok, fetched_books, fetch_code = self.api:getShelfBooks(shelf_id, shelf_type)
            if not ok then
                local err = classifyShelfFetchError(fetch_code, fetched_books)
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

        sync_start = os.time()
        download_dir = self:resolveDownloadDir(opts.download_dir)
        use_original = opts.use_original_filename ~= false
        local remote_delete_sync = opts.remote_delete_sync ~= false
        local delete_sdr = opts.delete_sdr == true
        skip_download_ids = {}
        local snapshot_token = computeShelfSnapshotToken(remote_books)
        result.snapshot_token = snapshot_token

        plan.cleanup = {
            shelf_id            = shelf_id,
            shelf_type          = shelf_type,
            download_dir        = download_dir,
            delete_sdr          = delete_sdr,
            remote_delete_sync  = remote_delete_sync,
            sync_start          = sync_start,
            selected_shelf_ids_by_type = opts.selected_shelf_ids_by_type,
            downloaded_files_to_refresh = {},
            downloaded_files_to_refresh_set = {},
        }

        local process_pending_cb = type(opts.process_pending_shelf_removals) == "function" and opts.process_pending_shelf_removals or nil
        if remote_delete_sync and process_pending_cb then
            local ok_cb = pcall(process_pending_cb, {
                shelf_sync = self,
                shelf_id = shelf_id,
                shelf_type = shelf_type,
                download_dir = download_dir,
                delete_sdr = delete_sdr,
                skip_download_ids = skip_download_ids,
                result = result,
                progress = progress,
            })
            if not ok_cb then
                logger.warn("GrimmLink ShelfSync: pending-removal callback failed; falling back to ShelfSync method")
                if type(self.processPendingShelfRemovals) == "function"
                    and self.db
                    and type(self.db.getPendingShelfRemovals) == "function" then
                    self:processPendingShelfRemovals(
                        shelf_id,
                        shelf_type,
                        download_dir,
                        delete_sdr,
                        skip_download_ids,
                        result,
                        progress
                    )
                end
            end
        elseif remote_delete_sync
            and type(self.processPendingShelfRemovals) == "function"
            and self.db
            and type(self.db.getPendingShelfRemovals) == "function" then
            self:processPendingShelfRemovals(
                shelf_id,
                shelf_type,
                download_dir,
                delete_sdr,
                skip_download_ids,
                result,
                progress
            )
        end

        local shelf_entries = {}
        if type(self.db.getShelfMappingsByShelf) == "function" then
            shelf_entries = self.db:getShelfMappingsByShelf(shelf_id, shelf_type) or {}
        else
            shelf_entries = self.db:getAllShelfSyncEntries(shelf_id, shelf_type) or {}
        end
        shelf_entry_by_book = {}
        for _, entry in ipairs(shelf_entries) do
            local key = tostring(entry.book_id or "")
            if key ~= "" and not shelf_entry_by_book[key] then
                shelf_entry_by_book[key] = entry
            end
        end

        reusable_mapping_by_book = {}
        if type(self.db.getAllShelfSyncEntries) == "function" then
            local all_entries = self.db:getAllShelfSyncEntries() or {}
            for _, mapping in ipairs(all_entries) do
                local key = tostring(mapping.book_id or "")
                if key ~= "" and not reusable_mapping_by_book[key] then
                    reusable_mapping_by_book[key] = mapping
                end
            end
        end

        if opts.previous_snapshot_token
            and snapshot_token
            and tostring(opts.previous_snapshot_token) == tostring(snapshot_token) then
            local remote_book_ids = {}
            for _, book in ipairs(remote_books) do
                local bid = tonumber(book.bookId or book.id or book.book_id)
                if bid then
                    remote_book_ids[tostring(bid)] = true
                end
            end

            local has_stale_tracked_entries = false
            for _, entry in ipairs(shelf_entries) do
                local entry_book_id = tonumber(entry.book_id)
                if entry_book_id and not remote_book_ids[tostring(entry_book_id)] then
                    has_stale_tracked_entries = true
                    break
                end
            end

            if not has_stale_tracked_entries
                and type(opts.selected_shelf_ids_by_type) == "table"
                and type(self.db.getAllShelfSyncEntries) == "function" then
                local selected_ids = buildShelfIdSet(opts.selected_shelf_ids_by_type[shelf_type])
                if next(selected_ids) ~= nil then
                    for _, entry in ipairs(self.db:getAllShelfSyncEntries() or {}) do
                        if normalizeShelfType(entry.shelf_type) == shelf_type
                            and not selected_ids[tostring(entry.shelf_id)] then
                            has_stale_tracked_entries = true
                            break
                        end
                    end
                end
            end

            local all_present = true
            for _, book in ipairs(remote_books) do
                local bid = tonumber(book.bookId or book.id or book.book_id)
                if bid then
                    local existing = shelf_entry_by_book[tostring(bid)]
                    local path = existing and existing.local_path or nil
                    local attr = path and lfs.attributes(path) or nil
                    if not (attr and attr.mode == "file") then
                        all_present = false
                        break
                    end
                end
            end
            if all_present and not has_stale_tracked_entries then
                result.skipped = result.skipped + #remote_books
                result.snapshot_unchanged = true
                if plan.cleanup then
                    plan.cleanup.remote_delete_sync = false
                end
                progress("Shelf snapshot unchanged; skipping full re-process.")
                return plan
            end
        end

        state = {
            shelf_id = shelf_id,
            shelf_type = shelf_type,
            remote_books = remote_books,
            sync_start = sync_start,
            download_dir = download_dir,
            use_original = use_original,
            skip_download_ids = skip_download_ids,
            shelf_entry_by_book = shelf_entry_by_book,
            reusable_mapping_by_book = reusable_mapping_by_book,
            next_index = 1,
            result = result,
            cleanup = plan.cleanup,
            download_queue = plan.download_queue,
        }
    end

    local total_books = #remote_books
    if state.next_index <= 1 then
        progress("Processing " .. total_books .. " books in shelf...")
    end

    local processed_in_call = 0
    local index = state.next_index
    while index <= total_books do
        if opts.is_cancelled and opts.is_cancelled() then
            result.cancelled = true
            result.errors[#result.errors + 1] = "Shelf sync cancelled during planning."
            return plan
        end
        if index % 40 == 0 then
            progress("Planning " .. tostring(index) .. " / " .. tostring(total_books))
        end

        local book = remote_books[index]
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

            existing = shelf_entry_by_book[book_id_key]
            if not should_continue and existing then
                self.db:upsertShelfSyncEntry({
                    book_id = book_id,
                    shelf_id = shelf_id,
                    shelf_type = shelf_type,
                    remote_filename = existing.remote_filename or book.fileName,
                    remote_title = existing.remote_title or book.title,
                    remote_author = existing.remote_author or book.author,
                    remote_format = existing.remote_format or resolveBookFormat(book) or book.fileFormat,
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
                                shelf_type = shelf_type,
                                remote_filename = existing.remote_filename or book.fileName,
                                remote_title = existing.remote_title or book.title,
                                remote_author = existing.remote_author or book.author,
                                remote_format = existing.remote_format or resolveBookFormat(book) or book.fileFormat,
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

            if not should_continue then
                local mapping = reusable_mapping_by_book[book_id_key]
                if mapping and mapping.local_path and mapping.local_path ~= "" then
                    local mapped_attr = lfs.attributes(mapping.local_path)
                    if mapped_attr and mapped_attr.mode == "file" then
                        self.db:upsertShelfSyncEntry({
                            book_id = book_id,
                            shelf_id = shelf_id,
                            shelf_type = shelf_type,
                            remote_filename = book.fileName,
                            remote_title = book.title,
                            remote_author = book.author,
                            remote_format = resolveBookFormat(book) or book.fileFormat,
                            remote_file_size_kb = book.fileSizeKb,
                            remote_series_name = book.seriesName,
                            remote_series_number = book.seriesNumber,
                            local_path = mapping.local_path,
                            downloaded_at = mapping.downloaded_at or os.time(),
                            last_seen_in_shelf_at = sync_start,
                            downloaded_by_grimmlink = mapping.downloaded_by_grimmlink == 1,
                        })
                        result.skipped = result.skipped + 1
                        should_continue = true
                        progress("Same book found in multiple shelves; using existing local file")
                    end
                end
            end
        end

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
                            shelf_type = shelf_type,
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
                    shelf_type = shelf_type,
                    dest_path = dest_path,
                    title     = book.title or filename,
                }
            end
        end

        index = index + 1
        state.next_index = index
        processed_in_call = processed_in_call + 1
        if plan_batch_size and processed_in_call >= plan_batch_size and index <= total_books then
            result.planning_in_progress = true
            result.planning_done = index - 1
            result.planning_total = total_books
            plan.plan_state = state
            return plan
        end
    end

    result.planning_in_progress = nil
    result.planning_done = total_books
    result.planning_total = total_books
    plan.plan_state = nil
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
    local resolved_format = resolveBookFormat(book)
    if resolved_format then
        dl_opts.expected_format = resolved_format
    end

    local dl_ok, dl_err = self.api:downloadBookToFile(book_id, item.dest_path, dl_opts)
    if dl_ok then
        self.db:upsertShelfSyncEntry({
            book_id              = book_id,
            shelf_id             = shelf_id,
            shelf_type           = normalizeShelfType(item.shelf_type),
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
        self:queueDownloadedFileForRefresh(
            item.dest_path,
            dl_opts.downloaded_files_to_refresh,
            dl_opts.downloaded_files_to_refresh_set
        )
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
    local resolved_format = resolveBookFormat(book)
    if resolved_format then
        opts.expected_format = resolved_format
    end
    return self.api:startAsyncDownload(item.book_id, item.dest_path, opts)
end

--- Record a completed download in the database.
function ShelfSync:recordDownload(item, shelf_id, sync_start, downloaded_files_to_refresh, downloaded_files_to_refresh_set)
    if not item then return end
    local book = item.book or {}
    self.db:upsertShelfSyncEntry({
        book_id              = item.book_id,
        shelf_id             = shelf_id,
        shelf_type           = normalizeShelfType(item.shelf_type),
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
    self:queueDownloadedFileForRefresh(item.dest_path, downloaded_files_to_refresh, downloaded_files_to_refresh_set)
    logger.info("GrimmLink ShelfSync: downloaded bookId=" .. tostring(item.book_id) .. " to " .. item.dest_path)
end

-- Add a downloaded file to the post-sync refresh queue.
function ShelfSync:queueDownloadedFileForRefresh(file_path, file_paths, seen_paths)
    return addUniquePathToList(file_paths, seen_paths, file_path)
end

-- Refresh KOReader cached metadata/cover for a single file.
-- Returns: ok (bool), method_name (string), error_message (string|nil)
function ShelfSync:refreshBookInfoForFile(file_path, opts)
    opts = type(opts) == "table" and opts or {}
    local normalized = normalizePathForCompare(file_path)
    if not normalized then
        return false, "invalid_path", "invalid_path"
    end

    local attr = safeLfsAttributes(normalized)
    if not attr or attr.mode ~= "file" then
        return false, "missing_file", "missing_file"
    end

    -- Keep in-memory file-browser cache coherent if BookList is available.
    local BookList = safeRequireAny({
        "ui/widget/booklist",
    })
    if BookList and type(BookList.resetBookInfoCache) == "function" then
        pcall(BookList.resetBookInfoCache, normalized)
    end

    local FileManager = safeRequireAny({
        "apps/filemanager/filemanager",
    })
    local fm_instance = FileManager and FileManager.instance or nil
    if fm_instance and fm_instance.file_chooser and type(fm_instance.file_chooser.resetBookInfoCache) == "function" then
        pcall(fm_instance.file_chooser.resetBookInfoCache, fm_instance.file_chooser, normalized)
    end

    local cover_specs = resolveCoverSpecs(opts.cover_specs)
    local BookInfoManager = safeRequireAny({
        "bookinfomanager",
        "plugins/coverbrowser.koplugin/bookinfomanager",
    })
    if BookInfoManager then
        if type(BookInfoManager.deleteBookInfo) == "function" then
            pcall(BookInfoManager.deleteBookInfo, BookInfoManager, normalized)
        end
        if type(BookInfoManager.extractBookInfo) == "function" then
            local ok_extract, extracted_or_err = pcall(BookInfoManager.extractBookInfo, BookInfoManager, normalized, cover_specs)
            if ok_extract and extracted_or_err ~= false then
                return true, "BookInfoManager.extractBookInfo", nil
            end
            local reason = ok_extract and "extract_failed" or tostring(extracted_or_err)
            return false, "BookInfoManager.extractBookInfo", reason
        end
        if type(BookInfoManager.getBookInfo) == "function" then
            local ok_info, info_or_err = pcall(BookInfoManager.getBookInfo, BookInfoManager, normalized, true)
            if ok_info and info_or_err then
                return true, "BookInfoManager.getBookInfo", nil
            end
            local reason = ok_info and "get_bookinfo_failed" or tostring(info_or_err)
            return false, "BookInfoManager.getBookInfo", reason
        end
    end

    -- Fallback: touch metadata via FileManagerBookInfo so KOReader can at least parse props.
    local FileManagerBookInfo = safeRequireAny({
        "apps/filemanager/filemanagerbookinfo",
    })
    if FileManagerBookInfo and type(FileManagerBookInfo.getDocProps) == "function" then
        local shim = {
            ui = {},
            getCoverImage = type(FileManagerBookInfo.getCoverImage) == "function" and FileManagerBookInfo.getCoverImage or nil,
        }
        local ok_props, props_or_err = pcall(FileManagerBookInfo.getDocProps, shim, normalized)
        if ok_props and props_or_err then
            return true, "FileManagerBookInfo.getDocProps", nil
        end
        local reason = ok_props and "doc_props_unavailable" or tostring(props_or_err)
        return false, "FileManagerBookInfo.getDocProps", reason
    end

    return false, "unavailable", "bookinfo_api_unavailable"
end

-- Refresh KOReader cached metadata/cover for a list of files.
-- Returns: { total, refreshed, failed, errors = {} }
function ShelfSync:refreshBookInfoForDownloadedFiles(file_paths, opts)
    opts = type(opts) == "table" and opts or {}
    local counts = { total = 0, refreshed = 0, failed = 0, errors = {} }
    if type(file_paths) ~= "table" then
        return counts
    end

    for _, file_path in ipairs(file_paths) do
        counts.total = counts.total + 1
        local ok_refresh, method_name, refresh_err = self:refreshBookInfoForFile(file_path, opts)
        if ok_refresh then
            counts.refreshed = counts.refreshed + 1
        else
            counts.failed = counts.failed + 1
            counts.errors[#counts.errors + 1] = {
                file_path = file_path,
                method = method_name,
                error = refresh_err,
            }
        end
    end

    return counts
end

function buildShelfIdSet(input)
    local set = {}
    if type(input) ~= "table" then
        return set
    end
    for key, value in pairs(input) do
        if value == true then
            set[tostring(key)] = true
        elseif value ~= nil and value ~= false then
            set[tostring(value)] = true
        end
    end
    return set
end

local function addCleanupEntry(entries, seen, entry, orphaned)
    if type(entry) ~= "table" then
        return
    end
    local key = table.concat({
        tostring(entry.book_id or ""),
        tostring(entry.shelf_id or ""),
        normalizeShelfType(entry.shelf_type),
    }, "|")
    if seen[key] then
        return
    end
    seen[key] = true
    if not orphaned then
        entries[#entries + 1] = entry
        return
    end

    local copy = {}
    for copy_key, copy_value in pairs(entry) do
        copy[copy_key] = copy_value
    end
    copy._grimmlink_orphaned_shelf_mapping = true
    entries[#entries + 1] = copy
end

local function buildCleanupEntries(sync, cleanup, shelf_type)
    local entries = {}
    local seen = {}
    for _, entry in ipairs(sync.db:getAllShelfSyncEntries(cleanup.shelf_id, shelf_type) or {}) do
        addCleanupEntry(entries, seen, entry, false)
    end

    local selected_by_type = type(cleanup.selected_shelf_ids_by_type) == "table"
        and cleanup.selected_shelf_ids_by_type
        or nil
    local selected_ids = buildShelfIdSet(selected_by_type and selected_by_type[shelf_type])
    if next(selected_ids) == nil then
        return entries
    end

    for _, entry in ipairs(sync.db:getAllShelfSyncEntries() or {}) do
        if normalizeShelfType(entry.shelf_type) == shelf_type
            and not selected_ids[tostring(entry.shelf_id)] then
            addCleanupEntry(entries, seen, entry, true)
        end
    end
    return entries
end

--- Phase 3: Delete local files for books removed from the remote shelf.
-- cleanup table comes from prepareSyncPlan().cleanup.
-- result  table is the running result accumulator.
-- progress_fn is optional function(msg).
function ShelfSync:runCleanupPhase(cleanup, result, progress_fn)
    local cleanup_state = nil
    local done = false
    while not done do
        cleanup_state, done = self:runCleanupPhaseBatch(cleanup, result, cleanup_state, nil, progress_fn)
    end
end

function ShelfSync:runCleanupPhaseBatch(cleanup, result, cleanup_state, max_items, progress_fn)
    if not cleanup or not cleanup.remote_delete_sync then
        return cleanup_state or { done = true }, true
    end
    if not self.db or type(self.db.getAllShelfSyncEntries) ~= "function" then
        return cleanup_state or { done = true }, true
    end

    result = result or { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
    result.errors = type(result.errors) == "table" and result.errors or {}

    if not cleanup_state then
        local shelf_type = normalizeShelfType(cleanup.shelf_type)
        cleanup_state = {
            index = 1,
            shelf_type = shelf_type,
            entries = buildCleanupEntries(self, cleanup, shelf_type),
            done = false,
        }
    end
    if cleanup_state.done then
        return cleanup_state, true
    end

    local item_limit = tonumber(max_items)
    if item_limit and item_limit < 1 then
        item_limit = 1
    end
    local processed = 0

    while cleanup_state.index <= #cleanup_state.entries do
        if item_limit and processed >= item_limit then
            break
        end
        local entry = cleanup_state.entries[cleanup_state.index]
        cleanup_state.index = cleanup_state.index + 1
        processed = processed + 1

        local orphaned_mapping = entry._grimmlink_orphaned_shelf_mapping == true
        if orphaned_mapping or entry.last_seen_in_shelf_at == nil or entry.last_seen_in_shelf_at < cleanup.sync_start then
            local tracked_elsewhere = self.db.isBookTrackedInOtherShelf
                and self.db:isBookTrackedInOtherShelf(entry.book_id, entry.shelf_id, entry.shelf_type)
            if tracked_elsewhere then
                if self.db.removeShelfMappingOnly then
                    self.db:removeShelfMappingOnly(entry.book_id, entry.shelf_id, entry.shelf_type)
                else
                    self.db:deleteShelfSyncEntry(entry.book_id)
                end
                if progress_fn then
                    if orphaned_mapping then
                        progress_fn("Removed stale shelf mapping; book kept locally because another shelf still tracks it")
                    else
                        progress_fn("Book kept locally because it is still tracked by another shelf")
                    end
                end
            elseif entry.downloaded_by_grimmlink == 1 then
                if progress_fn then
                    progress_fn("Removing: " .. (entry.remote_title or entry.remote_filename or tostring(entry.book_id)))
                end
                local delete_ok, delete_err = self:deleteLocalBook(entry, cleanup.delete_sdr, cleanup.download_dir)
                if delete_ok then
                    self:removeBookMetadata(entry, cleanup.shelf_id, cleanup_state.shelf_type)
                    result.deleted = (tonumber(result.deleted) or 0) + 1
                else
                    result.failed = (tonumber(result.failed) or 0) + 1
                    local err = "Failed to delete local bookId=" .. tostring(entry.book_id) .. ": " .. tostring(delete_err)
                    result.errors[#result.errors + 1] = err
                    logger.warn("GrimmLink ShelfSync:", err)
                end
            else
                if self.db.removeShelfMappingOnly then
                    self.db:removeShelfMappingOnly(entry.book_id, entry.shelf_id, entry.shelf_type)
                else
                    self.db:deleteShelfSyncEntry(entry.book_id)
                end
            end
        end
    end

    cleanup_state.done = cleanup_state.index > #cleanup_state.entries
    return cleanup_state, cleanup_state.done
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
        local ok, err = self:executeDownload(item, plan.cleanup.shelf_id, plan.cleanup.sync_start, {
            downloaded_files_to_refresh = plan.cleanup and plan.cleanup.downloaded_files_to_refresh or nil,
            downloaded_files_to_refresh_set = plan.cleanup and plan.cleanup.downloaded_files_to_refresh_set or nil,
        })
        if ok then
            result.synced = result.synced + 1
        else
            result.failed = result.failed + 1
            result.errors[#result.errors + 1] = err
        end
    end

    -- Phase 3: cleanup.
    self:runCleanupPhase(plan.cleanup, result, progress)

    -- Blocking fallback path: refresh metadata/cover cache for newly downloaded files.
    if plan.cleanup and type(plan.cleanup.downloaded_files_to_refresh) == "table"
        and #plan.cleanup.downloaded_files_to_refresh > 0 then
        local refresh_counts = self:refreshBookInfoForDownloadedFiles(plan.cleanup.downloaded_files_to_refresh, {})
        result.bookinfo_refresh = refresh_counts
        if refresh_counts.failed > 0 then
            result.errors[#result.errors + 1] = "Some downloaded files could not refresh cached book information"
        end
    end

    return result
end

-- Normalize a local path for consistent metadata key matching.
local function normalizePath(path)
    if not path or path == "" then return nil end
    local p = tostring(path):gsub("\\", "/"):gsub("/+", "/")
    if #p > 1 then p = p:gsub("/$", "") end
    return p
end

local function normalizeDirectoryValue(directory)
    if not directory or directory == "" then
        return ""
    end
    local dir = tostring(directory):gsub("\\", "/"):gsub("/+", "/")
    if dir ~= "/" then
        dir = dir:gsub("/$", "")
    end
    return dir
end

local function canonicalDirectorySqlExpr()
    return "(CASE WHEN directory = '/' THEN '/' ELSE rtrim(directory, '/') END)"
end

--- Write a metadata index JSON file to download_dir after sync.
-- Source of truth for GrimmLink-managed metadata; survives bookinfo_cache rescans.
function ShelfSync:writeMetadataIndex(shelf_id, shelf_type_or_download_dir, download_dir)
    if not self.db then return nil end

    local shelf_type = nil
    if download_dir == nil then
        download_dir = shelf_type_or_download_dir
    else
        shelf_type = normalizeShelfType(shelf_type_or_download_dir)
    end

    local entries = nil
    if shelf_id ~= nil then
        entries = self.db:getAllShelfSyncEntries(shelf_id, shelf_type)
    else
        entries = self.db:getAllShelfSyncEntries()
    end
    if type(entries) ~= "table" or #entries == 0 then return nil end

    local index = {}
    local skipped = 0
    for _, e in ipairs(entries) do
        local norm = normalizePath(e.local_path)
        if norm then
            if download_dir and download_dir ~= "" and not isPathUnderDirectory(norm, download_dir) then
                skipped = skipped + 1
            else
                local file_attr = lfs.attributes(norm)
                if file_attr and file_attr.mode == "file" then
                    local dir = norm:match("^(.*)/[^/]+$") or ""
                    local fname = norm:match("([^/]+)$") or ""
                    index[#index + 1] = {
                        bookId       = e.book_id,
                        shelfType    = e.shelf_type,
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
    if not self.db then return { inserted = 0, updated = 0, skipped = 0 } end

    local cache_conn, cache_path, columns = openBookInfoCache()
    if not cache_conn then return { inserted = 0, updated = 0, skipped = 0 } end

    backupBookInfoCacheOnce(cache_path)

    local entries = nil
    if shelf_id ~= nil then
        entries = self.db:getAllShelfSyncEntries(shelf_id)
    else
        entries = self.db:getAllShelfSyncEntries()
    end
    if type(entries) ~= "table" then
        entries = {}
    end
    local counts = { inserted = 0, updated = 0, skipped = 0 }

    local has_series = columns["series"]
    local has_series_index = columns["series_index"]
    local has_keywords = columns["keywords"]
    local canonical_dir_expr = canonicalDirectorySqlExpr()
    local dedupe_sql = "DELETE FROM bookinfo WHERE bcid NOT IN ("
        .. "SELECT MAX(bcid) FROM bookinfo GROUP BY " .. canonical_dir_expr .. ", filename)"

    cache_conn:exec("BEGIN TRANSACTION")
    cache_conn:exec(dedupe_sql)

    for _, e in ipairs(entries) do
        local norm = normalizePath(e.local_path)
        local file_attr = norm and lfs.attributes(norm)
        if norm and file_attr and file_attr.mode == "file" then
            local dir = normalizeDirectoryValue(norm:match("^(.*)/[^/]+$") or "")
            local fname = norm:match("([^/]+)$") or ""
            if fname ~= "" then
                local exists = false
                local check_stmt = cache_conn:prepare(
                    "SELECT 1 FROM bookinfo WHERE filename = ? AND " .. canonical_dir_expr .. " = ?"
                )
                if check_stmt then
                    check_stmt:bind(fname, dir)
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
                        vals[#vals + 1] = fname
                        vals[#vals + 1] = dir
                        local sql = "UPDATE bookinfo SET " .. table.concat(sets, ", ")
                            .. " WHERE filename = ? AND " .. canonical_dir_expr .. " = ?"
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
    local dir = normalizeDirectoryValue(norm:match("^(.*)/[^/]+$") or "")
    local fname = norm:match("([^/]+)$") or ""
    if fname == "" then return false end

    local cache_conn = openBookInfoCache()
    if not cache_conn then return false end

    local SQ3 = require("lua-ljsqlite3/init")
    local stmt = cache_conn:prepare(
        "DELETE FROM bookinfo WHERE filename = ? AND " .. canonicalDirectorySqlExpr() .. " = ?"
    )
    local ok = false
    if stmt then
        stmt:bind(fname, dir)
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
    local canonical_dir_expr = canonicalDirectorySqlExpr()
    local dedupe_sql = "DELETE FROM bookinfo WHERE bcid NOT IN ("
        .. "SELECT MAX(bcid) FROM bookinfo GROUP BY " .. canonical_dir_expr .. ", filename)"

    cache_conn:exec("BEGIN TRANSACTION")
    cache_conn:exec(dedupe_sql)

    for _, entry in ipairs(index) do
        local dir = normalizeDirectoryValue(entry.directory or "")
        local fname = entry.filename or ""
        local full_path = dir ~= "" and (dir .. "/" .. fname) or fname
        local file_attr = fname ~= "" and lfs.attributes(full_path)
        if fname ~= "" and file_attr and file_attr.mode == "file" then
            local exists = false
            local chk = cache_conn:prepare(
                "SELECT 1 FROM bookinfo WHERE filename = ? AND " .. canonical_dir_expr .. " = ?"
            )
            if chk then
                chk:bind(fname, dir)
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
                    vals[#vals + 1] = fname
                    vals[#vals + 1] = dir
                    local sql = "UPDATE bookinfo SET " .. table.concat(sets, ", ")
                        .. " WHERE filename = ? AND " .. canonical_dir_expr .. " = ?"
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
function ShelfSync:removeBookMetadata(entry, shelf_id, shelf_type)
    if not entry or not entry.book_id then return end
    local normalized_type = normalizeShelfType(shelf_type or entry.shelf_type)

    if self.db and self.db.addShelfSyncTombstone then
        self.db:addShelfSyncTombstone({
            book_id = entry.book_id,
            shelf_id = shelf_id,
            shelf_type = normalized_type,
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
