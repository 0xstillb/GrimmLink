local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("logger")
local _ok_util, Util = pcall(require, "grimmlink_util")
if not _ok_util then
    Util = nil
end
local M = {}
local DEFAULT_PENDING_SHELF_REMOVAL_RETRY_COOLDOWN_SECONDS = 30

local function safeToString(value)
    local ok, result = pcall(tostring, value)
    if ok then
        return result
    end
    return "<tostring_failed>"
end

local function normalizeCount(value)
    local number = tonumber(value)
    if not number then
        return 0
    end
    return math.max(0, math.floor(number))
end

function M.new()
    local o = {}
    setmetatable(o, { __index = M })
    return o
end

function M:runQueueStep(plugin, method_name, limit)
    if not plugin or type(plugin[method_name]) ~= "function" then
        return 0, 0, method_name .. "_unavailable"
    end

    local ok, synced, failed = pcall(plugin[method_name], plugin, true, limit)
    if not ok then
        return 0, 1, safeToString(synced)
    end

    return normalizeCount(synced), normalizeCount(failed), nil
end

function M:syncPendingNow(plugin, silent, opts)
    opts = opts or {}

    if not silent then
        local context = plugin:getCurrentDocumentContext()
        if context and not plugin:isTrackingEnabledForContext(context) then
            plugin:showTrackingDisabledMessage()
        else
            plugin:extractAndQueueCurrentMetadata("manual-sync")
        end
        if not plugin:isOnline() then
            plugin:maybePromptEnableWifiForManualSync()
            return
        end
    end

    if not plugin:requireReady({ require_api = true, silent = silent }) then
        return {
            progress_synced = 0,
            progress_failed = 0,
            sessions_synced = 0,
            sessions_failed = 0,
            metadata_synced = 0,
            metadata_failed = 0,
            queue_remaining = self:getQueueSummaryCounters(plugin),
            processed_total = 0,
            step_errors = {},
        }
    end

    local step_errors = {}
    local progress_synced, progress_failed, progress_err = self:runQueueStep(
        plugin,
        "syncPendingProgress",
        opts.progress_limit
    )
    if progress_err then
        step_errors[#step_errors + 1] = "Progress queue error: " .. progress_err
    end

    local sessions_synced, sessions_failed, sessions_err = self:runQueueStep(
        plugin,
        "syncPendingSessions",
        opts.session_limit
    )
    if sessions_err then
        step_errors[#step_errors + 1] = "Session queue error: " .. sessions_err
    end

    local metadata_synced, metadata_failed, metadata_err = self:runQueueStep(
        plugin,
        "syncPendingMetadata",
        opts.metadata_limit
    )
    if metadata_err then
        step_errors[#step_errors + 1] = "Metadata queue error: " .. metadata_err
    end

    local summary = {
        progress_synced = progress_synced,
        progress_failed = progress_failed,
        sessions_synced = sessions_synced,
        sessions_failed = sessions_failed,
        metadata_synced = metadata_synced,
        metadata_failed = metadata_failed,
        queue_remaining = self:getQueueSummaryCounters(plugin),
        processed_total = progress_synced + progress_failed
            + sessions_synced + sessions_failed
            + metadata_synced + metadata_failed,
        step_errors = step_errors,
    }

    if not silent then
        plugin:showMessage(T(
            _("GrimmLink sync complete\nProgress: %1 synced, %2 failed\nSessions: %3 synced, %4 failed\nMetadata: %5 synced, %6 failed"),
            progress_synced,
            progress_failed,
            sessions_synced,
            sessions_failed,
            metadata_synced,
            metadata_failed
        ), 4)
    end

    return summary
end

function M:getQueueSummaryCounters(plugin)
    local db = plugin and plugin.db or nil
    local function safeCount(method_name)
        if not db or type(db[method_name]) ~= "function" then
            return 0
        end
        return db[method_name](db)
    end

    if not db then
        return {
            pending_progress = 0,
            pending_sessions = 0,
            pending_metadata = 0,
            pending_shelf_removals = 0,
        }
    end
    return {
        pending_progress = safeCount("getPendingProgressCount"),
        pending_sessions = safeCount("getPendingSessionCount"),
        pending_metadata = safeCount("getPendingMetadataCount"),
        pending_shelf_removals = safeCount("getPendingShelfRemovalCount"),
    }
end

local function normalizeShelfType(value)
    if Util and type(Util.normalizeShelfType) == "function" then
        return Util.normalizeShelfType(value)
    end
    local shelf_type = tostring(value or "regular"):lower()
    if shelf_type ~= "magic" then
        return "regular"
    end
    return shelf_type
end

function M:shouldRetryPendingShelfRemoval(entry, now_ts, retry_cooldown_seconds)
    local retry_count = tonumber(entry and entry.retry_count) or 0
    local last_retry_at = tonumber(entry and entry.last_retry_at)
    local cooldown = tonumber(retry_cooldown_seconds) or DEFAULT_PENDING_SHELF_REMOVAL_RETRY_COOLDOWN_SECONDS
    if retry_count <= 0 or cooldown <= 0 or not last_retry_at then
        return true
    end
    local now_value = tonumber(now_ts) or os.time()
    return (now_value - last_retry_at) >= cooldown
end

function M:processPendingShelfRemovals(plugin, args)
    args = args or {}

    local sync = args.shelf_sync or (plugin and plugin.shelf_sync) or nil
    local db = args.db or (plugin and plugin.db) or (sync and sync.db) or nil
    local api = args.api or (plugin and plugin.api) or (sync and sync.api) or nil
    if not db or type(db.getPendingShelfRemovals) ~= "function" or not api or type(api.removeBookFromShelf) ~= "function" then
        return false
    end

    local shelf_id = args.shelf_id
    local shelf_type = normalizeShelfType(args.shelf_type)
    local delete_sdr = args.delete_sdr == true
    local download_dir = args.download_dir
    local skip_download_ids = type(args.skip_download_ids) == "table" and args.skip_download_ids or {}
    local result = type(args.result) == "table" and args.result or { deleted = 0, failed = 0, errors = {} }
    result.errors = type(result.errors) == "table" and result.errors or {}
    local progress = type(args.progress) == "function" and args.progress or nil
    local now_ts = tonumber(args.now_ts) or os.time()
    local retry_cooldown_seconds = args.retry_cooldown_seconds
    if retry_cooldown_seconds == nil and plugin then
        retry_cooldown_seconds = plugin.pending_shelf_removal_retry_cooldown_seconds
    end

    local pending_entries = db:getPendingShelfRemovals(shelf_id, shelf_type)
    local mark_only = args.mark_only == true
    local max_entries = tonumber(args.max_entries)
    if max_entries and max_entries < 1 then
        max_entries = 1
    end
    local processed_entries = 0
    local remaining_entries = 0

    for _, entry in ipairs(pending_entries or {}) do
        if entry.book_id then
            skip_download_ids[tostring(entry.book_id)] = true
            remaining_entries = remaining_entries + 1

            if mark_only then
                -- Planning phase optimization: mark skip IDs only, do not perform network I/O.
            elseif max_entries and processed_entries >= max_entries then
                -- Keep remaining queue items for later scheduled passes.
            else
                if not self:shouldRetryPendingShelfRemoval(entry, now_ts, retry_cooldown_seconds) then
                    if progress then
                        progress("Pending removal retry cooldown: " .. (entry.local_path or tostring(entry.book_id)))
                    end
                else
                    processed_entries = processed_entries + 1
                    if progress then
                        progress("Removing pending: " .. (entry.local_path or tostring(entry.book_id)))
                    end

                    local ok, response_or_err = api:removeBookFromShelf(entry.shelf_id, entry.book_id, shelf_type)
                    if ok then
                        local tracked = nil
                        if type(db.getShelfMapping) == "function" then
                            tracked = db:getShelfMapping(entry.book_id, entry.shelf_id, shelf_type)
                        elseif type(db.getShelfSyncEntry) == "function" then
                            tracked = db:getShelfSyncEntry(entry.book_id)
                        end

                        local keep_local = tracked
                            and type(db.isBookTrackedInOtherShelf) == "function"
                            and db:isBookTrackedInOtherShelf(entry.book_id, entry.shelf_id, shelf_type)

                        local deleted_ok = true
                        if tracked and keep_local then
                            logger.info("GrimmLink PendingSync: kept local file because another shelf still tracks bookId=" .. tostring(entry.book_id))
                            if type(db.removeShelfMappingOnly) == "function" then
                                deleted_ok = db:removeShelfMappingOnly(entry.book_id, entry.shelf_id, shelf_type)
                            elseif type(db.deleteShelfSyncEntry) == "function" then
                                deleted_ok = db:deleteShelfSyncEntry(entry.book_id)
                            end
                        elseif tracked then
                            if type(args.delete_local_book_fn) == "function" then
                                deleted_ok = args.delete_local_book_fn(tracked, delete_sdr, download_dir) ~= false
                            elseif sync and type(sync.deleteLocalBook) == "function" then
                                deleted_ok = sync:deleteLocalBook(tracked, delete_sdr, download_dir)
                            else
                                deleted_ok = false
                            end
                        end

                        if deleted_ok then
                            if tracked and not keep_local then
                                if type(args.remove_book_metadata_fn) == "function" then
                                    args.remove_book_metadata_fn(tracked, shelf_id, shelf_type)
                                elseif sync and type(sync.removeBookMetadata) == "function" then
                                    sync:removeBookMetadata(tracked, shelf_id, shelf_type)
                                end
                            end
                            if type(db.deletePendingShelfRemoval) == "function" then
                                db:deletePendingShelfRemoval(entry.book_id, entry.shelf_id, shelf_type)
                            end
                            result.deleted = (tonumber(result.deleted) or 0) + 1
                        else
                            if type(db.incrementPendingShelfRemovalRetryCount) == "function" then
                                db:incrementPendingShelfRemovalRetryCount(entry.book_id, entry.shelf_id, shelf_type)
                            end
                            result.failed = (tonumber(result.failed) or 0) + 1
                            result.errors[#result.errors + 1] = "Failed to delete local file for pending bookId=" .. tostring(entry.book_id)
                        end
                    else
                        if type(db.incrementPendingShelfRemovalRetryCount) == "function" then
                            db:incrementPendingShelfRemovalRetryCount(entry.book_id, entry.shelf_id, shelf_type)
                        end
                        result.failed = (tonumber(result.failed) or 0) + 1
                        result.errors[#result.errors + 1] = "Failed to remove pending bookId=" .. tostring(entry.book_id) .. ": " .. tostring(response_or_err)
                        logger.warn("GrimmLink PendingSync:", result.errors[#result.errors])
                    end
                end
            end
        end
    end

    local counters = args.counters
    if type(counters) == "table" then
        counters.pending_total = remaining_entries
        counters.processed = processed_entries
        counters.mark_only = mark_only
    end

    return true
end

return M
