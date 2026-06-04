local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local ButtonDialog = deps.ButtonDialog
    local ConfirmBox = deps.ConfirmBox
    local Event = deps.Event
    local FileManager = deps.FileManager
    local InfoMessage = deps.InfoMessage
    local UIManager = deps.UIManager
    local lfs = deps.lfs
    local logger = deps.logger
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS
    local DISK_SPACE_SAFETY_MARGIN_BYTES = deps.DISK_SPACE_SAFETY_MARGIN_BYTES
    local maybeNumber = deps.maybeNumber
    local normalizeShelfType = deps.normalizeShelfType
    local parseDfAvailableBytes = deps.parseDfAvailableBytes
    local safeToString = deps.safeToString
    local shellQuote = deps.shellQuote

-- ============================================================
-- Async shelf sync — downloads one file at a time, yielding
-- control back to UIManager between each download so the UI
-- stays responsive on weak e-reader CPUs.
-- ============================================================

-- Guard: prevent double-sync.
function Grimmlink:_isShelfSyncRunning()
    return self._shelf_sync_running == true
end

-- Show / update the progress InfoMessage for the current download.
-- progress is optional table: {pct=0-100, bytes=N, total=N}
-- When nil, shows "Connecting..." state.
function Grimmlink:_showSyncProgress(idx, total, title, progress)
    -- Close the plan-phase message popup (showShelfSyncMessage) first —
    -- it uses a different widget ref and would otherwise stay on top
    -- of our progress popup, hiding it completely.
    self:closeShelfSyncMessage()

    -- Close previous progress widget.
    if self._shelf_sync_progress_widget then
        self._shelf_sync_progress_widget.dismiss_callback = nil
        pcall(UIManager.close, UIManager, self._shelf_sync_progress_widget)
        self._shelf_sync_progress_widget = nil
    end

    local short_title = title or "?"
    if #short_title > 40 then short_title = short_title:sub(1, 40) .. "..." end

    local lines = {}
    -- Header
    lines[#lines + 1] = T(_("Downloading  %1 / %2"), idx, total)
    lines[#lines + 1] = ""
    lines[#lines + 1] = short_title

    if progress then
        lines[#lines + 1] = ""
        local pct = progress.pct or 0
        local bytes = progress.bytes or 0

        -- Size + percentage on one line:  62%  -  131.2 / 200.8 MB
        if progress.total and progress.total > 0 then
            lines[#lines + 1] = string.format("%d%%  -  %.1f / %.1f MB",
                pct, bytes / (1024 * 1024), progress.total / (1024 * 1024))
        elseif bytes > 0 then
            lines[#lines + 1] = string.format("%.1f MB", bytes / (1024 * 1024))
        end

        -- Progress bar
        local bar_w = 15
        local filled = math.floor(pct / 100 * bar_w)
        if filled > bar_w then filled = bar_w end
        lines[#lines + 1] = string.rep("\xE2\x96\x88", filled)
                          .. string.rep("\xE2\x96\x91", bar_w - filled)
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Connecting...")
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.rep("\xE2\x94\x80", 15)
    lines[#lines + 1] = "\xE2\x96\xB6  " .. _("Tap to cancel") .. "  \xE2\x97\x80"

    local grimmlink_self = self
    local widget = InfoMessage:new{
        text    = table.concat(lines, "\n"),
        timeout = 600,
        dismiss_callback = function()
            grimmlink_self:_confirmCancelSync()
        end,
    }
    self._shelf_sync_progress_widget = widget
    UIManager:show(widget)
    UIManager:forceRePaint()
end

function Grimmlink:_closeSyncProgress()
    if self._shelf_sync_progress_widget then
        self._shelf_sync_progress_widget.dismiss_callback = nil
        pcall(UIManager.close, UIManager, self._shelf_sync_progress_widget)
        self._shelf_sync_progress_widget = nil
    end
    self:closeShelfSyncMessage()
end

-- Update download progress.  progress = {pct, bytes, total}
function Grimmlink:_updateSyncProgressPct(idx, total, title, progress)
    self:_showSyncProgress(idx, total, title, progress)
end

-- Ask user whether to cancel.  Already-downloaded files are kept.
function Grimmlink:_confirmCancelSync()
    if not self._shelf_sync_running then return end
    local grimmlink_self = self
    local box = ConfirmBox:new{
        text = _("Cancel shelf sync?\nBooks already downloaded will be kept."),
        ok_text = _("Cancel sync"),
        cancel_text = _("Continue"),
        ok_callback = function()
            grimmlink_self._shelf_sync_cancelled = true
        end,
    }
    UIManager:show(box)
end

-- Multi-line completion summary.
function Grimmlink:_showSyncCompletionSummary(result)
    self:_closeSyncProgress()
    local lines = {}
    local synced  = result.synced or 0
    local skipped = result.skipped or 0
    local deleted = result.deleted or 0
    local failed  = result.failed or 0
    local total   = synced + skipped + deleted + failed
    local errors_count = type(result.errors) == "table" and #result.errors or 0

    if result.cancelled then
        lines[#lines + 1] = _("Shelf Sync Cancelled")
    elseif errors_count > 0 then
        lines[#lines + 1] = _("Shelf Sync Completed with Errors")
    else
        lines[#lines + 1] = _("Shelf Sync Complete")
    end
    lines[#lines + 1] = "---------------------------"

    if total == 0 and not result.cancelled then
        if errors_count > 0 then
            lines[#lines + 1] = _("No changes were applied due to errors.")
        else
            lines[#lines + 1] = _("Everything is up to date.")
        end
    else
        local items = {}
        if synced > 0 then items[#items + 1] = { _("Downloaded"), synced } end
        if skipped > 0 then items[#items + 1] = { _("Skipped"), skipped } end
        if deleted > 0 then items[#items + 1] = { _("Removed"), deleted } end
        if failed > 0 then  items[#items + 1] = { _("Failed"), failed } end
        local max_len = 0
        for _, v in ipairs(items) do
            if #v[1] > max_len then max_len = #v[1] end
        end
        for _, v in ipairs(items) do
            local pad = string.rep(" ", max_len - #v[1] + 2)
            lines[#lines + 1] = "\xE2\x96\xB6 " .. v[1] .. pad .. tostring(v[2])
        end
    end

    if type(result.errors) == "table" and #result.errors > 0 then
        lines[#lines + 1] = ""
        local first_err = safeToString(result.errors[1] or "")
        if #first_err > 120 then first_err = first_err:sub(1, 120) .. "..." end
        if first_err ~= "" then
            lines[#lines + 1] = first_err
        end
    end
    UIManager:show(InfoMessage:new{
        text    = table.concat(lines, "\n"),
        timeout = 8,
    })
end

-- Broadcast sync result so other plugins (e.g. SimpleUI) can react.
function Grimmlink:_broadcastSyncResult(result)
    if not Event then return end
    if (result.synced or 0) == 0 and (result.deleted or 0) == 0 then return end
    local event_shelf_type = normalizeShelfType(
        (result and result.shelf_type)
        or self._active_sync_shelf_type
        or self.shelf_type
        or "regular"
    )
    local event_download_dir = (result and result.download_dir)
        or self._active_sync_download_dir
        or self:getShelfSyncTargetDownloadDir(event_shelf_type)
    local ev = Event:new("GrimmLinkShelfSyncComplete", {
        synced              = result.synced or 0,
        deleted             = result.deleted or 0,
        skipped             = result.skipped or 0,
        shelf_type          = event_shelf_type,
        download_dir        = event_download_dir,
        metadata_index_path = result.metadata_index_path,
    })
    local function _emit()
        if UIManager and type(UIManager.broadcastEvent) == "function" then
            pcall(UIManager.broadcastEvent, UIManager, ev)
            return
        end
        local FM2 = FileManager and FileManager.instance
        if FM2 and type(FM2.handleEvent) == "function" then
            pcall(FM2.handleEvent, FM2, ev)
        end
    end
    if UIManager and type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(0.1, _emit)
    else
        pcall(_emit)
    end
end

function Grimmlink:getShelfSyncTargetDownloadDir(shelf_type)
    local normalized_type = normalizeShelfType(shelf_type)
    if self.shelf_sync and type(self.shelf_sync.resolveDownloadDirForShelfType) == "function" then
        return self.shelf_sync:resolveDownloadDirForShelfType(normalized_type, {
            download_dir = self.download_dir,
            use_separate_magic_download_dir = self.use_separate_magic_download_dir == true,
            magic_download_dir = self.magic_download_dir,
        })
    end
    if normalized_type == "magic" and self.use_separate_magic_download_dir == true then
        return self.magic_download_dir
    end
    return self.download_dir
end

function Grimmlink:getShelfSnapshotSettingKey(shelf_id, shelf_type)
    return "shelf_snapshot_" .. normalizeShelfType(shelf_type) .. "_" .. tostring(shelf_id or "")
end

function Grimmlink:readShelfSnapshotToken(shelf_id, shelf_type)
    if not self.db or type(self.db.getPluginSetting) ~= "function" then
        return nil
    end
    return self.db:getPluginSetting(self:getShelfSnapshotSettingKey(shelf_id, shelf_type))
end

function Grimmlink:saveShelfSnapshotToken(shelf_id, shelf_type, token)
    if not token or token == "" then
        return false
    end
    return self:saveSetting(self:getShelfSnapshotSettingKey(shelf_id, shelf_type), token)
end

local function addShelfIdToSet(set, shelf_id)
    local normalized_id = maybeNumber(shelf_id) or shelf_id
    if normalized_id ~= nil then
        set[tostring(normalized_id)] = true
    end
end

function Grimmlink:getSelectedShelfIdsByType(active_selection)
    local selected = { regular = {}, magic = {} }
    if self.sync_regular_shelf_enabled == true then
        addShelfIdToSet(selected.regular, self.selected_regular_shelf_id)
    end
    if self.sync_magic_shelf_enabled == true then
        addShelfIdToSet(selected.magic, self.selected_magic_shelf_id)
    end
    if type(active_selection) == "table" and active_selection.id ~= nil then
        addShelfIdToSet(selected[normalizeShelfType(active_selection.type)], active_selection.id)
    end
    return selected
end

function Grimmlink:getActiveShelfSelection()
    local regular_enabled = self.sync_regular_shelf_enabled == true and self.selected_regular_shelf_id ~= nil
    local magic_enabled = self.sync_magic_shelf_enabled == true and self.selected_magic_shelf_id ~= nil

    if regular_enabled and magic_enabled then
        return {
            id = self.selected_regular_shelf_id,
            name = self.selected_regular_shelf_name or self.shelf_name,
            type = "regular",
            note = "both_enabled_partial",
        }
    end
    if regular_enabled then
        return {
            id = self.selected_regular_shelf_id,
            name = self.selected_regular_shelf_name or self.shelf_name,
            type = "regular",
        }
    end
    if magic_enabled then
        return {
            id = self.selected_magic_shelf_id,
            name = self.selected_magic_shelf_name,
            type = "magic",
        }
    end

    if self.shelf_id ~= nil then
        return {
            id = self.shelf_id,
            name = self.shelf_name,
            type = normalizeShelfType(self.shelf_type),
        }
    end

    return nil
end

function Grimmlink:getAvailableDiskBytes(path)
    local target = safeToString(path)
    if target == "" then
        return nil
    end

    local dir_attr = lfs and lfs.attributes and lfs.attributes(target) or nil
    if not dir_attr then
        local parent = target:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            target = parent
        end
    elseif dir_attr.mode ~= "directory" then
        local parent = target:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            target = parent
        end
    end

    local handle = io.popen("df -Pk " .. shellQuote(target) .. " 2>/dev/null")
    if not handle then
        return nil
    end
    local output = handle:read("*a")
    handle:close()
    return parseDfAvailableBytes(output)
end

function Grimmlink:checkDiskSpaceForShelfItem(item, active_download_dir)
    local book = item and item.book or nil
    local size_kb = book and tonumber(book.fileSizeKb) or nil
    if not size_kb or size_kb <= 0 then
        return true, nil, nil, "size_unavailable"
    end

    local resolved_dir = active_download_dir
    if self.shelf_sync and type(self.shelf_sync.resolveDownloadDir) == "function" then
        resolved_dir = self.shelf_sync:resolveDownloadDir(active_download_dir)
    end
    local available_bytes = self:getAvailableDiskBytes(resolved_dir or active_download_dir or self.download_dir)
    if not available_bytes then
        return true, nil, nil, "space_unavailable"
    end

    local required_bytes = math.floor(size_kb * 1024) + DISK_SPACE_SAFETY_MARGIN_BYTES
    if available_bytes < required_bytes then
        return false, available_bytes, required_bytes, "insufficient_space"
    end
    return true, available_bytes, required_bytes, nil
end

function Grimmlink:syncShelfNow(silent, opts)
    opts = type(opts) == "table" and opts or {}
    local selection_override = type(opts.selection_override) == "table" and opts.selection_override or nil
    local suppress_completion_summary = opts.suppress_completion_summary == true
    local on_complete = type(opts.on_complete) == "function" and opts.on_complete or nil
    local planning_state = type(opts._planning_state) == "table" and opts._planning_state or nil
    local planning_resume = planning_state ~= nil

    if not planning_resume and not self:requireReady({ require_api = true, silent = silent }) then
        return nil
    end
    if not self.shelf_sync_enabled then
        if not silent then
            self:showMessage(_("Shelf Sync is disabled. Enable it first."), 3)
        end
        return nil
    end
    if not self.shelf_sync or type(self.shelf_sync.prepareSyncPlan) ~= "function" then
        if not silent then
            self:showMessage(_("Shelf sync module unavailable"), 3)
        end
        return nil
    end
    local selection = selection_override
    local followup_selection = type(opts._followup_selection) == "table" and opts._followup_selection or nil
    if not selection then
        local regular_enabled = self.sync_regular_shelf_enabled == true and self.selected_regular_shelf_id ~= nil
        local magic_enabled = self.sync_magic_shelf_enabled == true and self.selected_magic_shelf_id ~= nil
        if regular_enabled and magic_enabled then
            selection = {
                id = self.selected_regular_shelf_id,
                name = self.selected_regular_shelf_name or self.shelf_name,
                type = "regular",
            }
            followup_selection = {
                id = self.selected_magic_shelf_id,
                name = self.selected_magic_shelf_name,
                type = "magic",
            }
            suppress_completion_summary = true
            self:logInfo("GrimmLink: both regular and magic shelf sync are enabled; running regular first then magic")
        else
            selection = self:getActiveShelfSelection()
        end
    end

    if not selection or not selection.id then
        if not silent then
            self:showMessage(_("No shelf selected. Go to Shelf Sync -> Select Shelf."), 3)
        end
        return nil
    end

    local active_shelf_id = selection.id
    local active_shelf_name = selection.name and selection.name ~= "" and selection.name or tostring(selection.id)
    local active_shelf_type = normalizeShelfType(selection.type)
    local active_download_dir = self:getShelfSyncTargetDownloadDir(active_shelf_type)
    self._active_sync_shelf_type = active_shelf_type
    self._active_sync_download_dir = active_download_dir

    if active_shelf_type == "magic" and self.use_separate_magic_download_dir then
        if not active_download_dir or active_download_dir == "" then
            if not silent then
                self:showMessage(_("Magic Shelf directory cannot be created"), 4)
            end
            return nil
        end
        local valid_magic_dir, _, validation_reason = self:validateMagicDownloadDirectory(active_download_dir)
        if not valid_magic_dir then
            if not silent then
                self:showMagicDirectoryValidationError(validation_reason)
            end
            return nil
        end
    end
    if not planning_resume then
        if not self:isOnline() then
            if not silent then
                self:showMessage(_("No network connection"), 3)
            end
            return nil
        end
        if not self:refreshApiClient() then
            if not silent then
                self:showMessage(_("Connection not ready"), 3)
            end
            return nil
        end
    end
    -- Prevent double-sync.
    if self:_isShelfSyncRunning() then
        if not silent then
            self:showMessage(_("Shelf sync is already running."), 2)
        end
        return nil
    end

    self._shelf_sync_running   = true
    if not planning_resume then
        self._shelf_sync_cancelled = false
    end

    if not silent and not planning_resume then
        local prefix = active_shelf_type == "magic" and _("Syncing Magic Shelf: %1") or _("Syncing Regular Shelf: %1")
        self:showShelfSyncMessage(T(prefix, active_shelf_name), 2)
    end

    local remote_delete_sync = self.two_way_shelf_delete_sync
    local previous_snapshot_token = self:readShelfSnapshotToken(active_shelf_id, active_shelf_type)
    local preloaded_remote_books = nil
    local cached_books_age = nil
    if self.shelf_fast_sync_enabled and not remote_delete_sync and not planning_resume then
        preloaded_remote_books, cached_books_age = self:getCachedShelfBooks(active_shelf_id, active_shelf_type, self.shelf_fast_sync_cache_seconds or 15)
        if preloaded_remote_books and not silent then
            self:showShelfSyncMessage(T(_("Fast Sync: using cached shelf data (%1s old)"), math.max(0, math.floor(tonumber(cached_books_age) or 0))), 2)
        end
    end

    local process_pending_shelf_removals = nil
    if self.pending_sync and type(self.pending_sync.processPendingShelfRemovals) == "function" then
        process_pending_shelf_removals = function(payload)
            payload = payload or {}
            payload.shelf_sync = self.shelf_sync
            payload.mark_only = true
            payload.retry_cooldown_seconds = self.pending_shelf_removal_retry_cooldown_seconds
            return self.pending_sync:processPendingShelfRemovals(self, payload)
        end
    end

    -- Phase 1: Plan (classify books — fast, no large I/O).
    local ok_plan, plan_or_err = pcall(function()
        return self.shelf_sync:prepareSyncPlan({
            shelf_id = active_shelf_id,
            shelf_type = active_shelf_type,
            download_dir = active_download_dir,
            use_original_filename = self.shelf_use_original_filename,
            remote_delete_sync = remote_delete_sync,
            delete_sdr = self.delete_sdr_on_book_delete,
            previous_snapshot_token = previous_snapshot_token,
            is_cancelled = function()
                return self._shelf_sync_cancelled == true
            end,
            preloaded_remote_books = preloaded_remote_books,
            on_progress = function(msg)
                if not silent then self:showShelfSyncMessage(safeToString(msg), 2) end
            end,
            on_fetched_remote_books = function(remote_books)
                if self.shelf_fast_sync_enabled and type(remote_books) == "table" then
                    self:setShelfBooksCache(active_shelf_id, active_shelf_type, remote_books)
                end
            end,
            process_pending_shelf_removals = process_pending_shelf_removals,
            selected_shelf_ids_by_type = self:getSelectedShelfIdsByType(selection),
            plan_state = planning_state,
            plan_batch_size = math.max(
                10,
                tonumber(opts.plan_batch_size)
                    or tonumber(self.shelf_plan_batch_size)
                    or DEFAULTS.shelf_plan_batch_size
            ),
        })
    end)
    if not ok_plan then
        self._shelf_sync_running = false
        self._active_sync_shelf_type = nil
        self._active_sync_download_dir = nil
        local err_text = safeToString(plan_or_err)
        self:logErr("GrimmLink shelf sync plan crashed:", err_text)
        if not silent then
            self:_closeSyncProgress()
            self:showShelfSyncMessage(T(_("Shelf sync failed:\n%1"), err_text), 5)
        end
        return nil
    end
    if type(plan_or_err) == "table" and type(plan_or_err.plan_state) == "table" then
        local planning_result = type(plan_or_err.result) == "table" and plan_or_err.result or {
            synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {},
        }
        planning_result.shelf_type = active_shelf_type
        planning_result.download_dir = active_download_dir

        if self._shelf_sync_cancelled or planning_result.cancelled then
            planning_result.cancelled = true
            self._shelf_sync_running = false
            self._active_sync_shelf_type = nil
            self._active_sync_download_dir = nil
            if not silent and not suppress_completion_summary then
                self:_showSyncCompletionSummary(planning_result)
            end
            self:_broadcastSyncResult(planning_result)
            if on_complete then
                pcall(on_complete, planning_result)
            end
            return nil
        end

        if not silent then
            self:showShelfSyncMessage(T(
                _("Planning shelf queue %1 / %2"),
                tonumber(planning_result.planning_done) or 0,
                tonumber(planning_result.planning_total) or 0
            ), 2)
        end

        self._shelf_sync_running = false
        self._active_sync_shelf_type = nil
        self._active_sync_download_dir = nil
        UIManager:scheduleIn(0.01, function()
            self:syncShelfNow(silent, {
                selection_override = selection,
                suppress_completion_summary = suppress_completion_summary,
                on_complete = on_complete,
                _planning_state = plan_or_err.plan_state,
                _followup_selection = followup_selection,
                plan_batch_size = opts.plan_batch_size,
                cleanup_batch_size = opts.cleanup_batch_size,
                pending_removal_drain_max_rounds = opts.pending_removal_drain_max_rounds,
            })
        end)
        return nil
    end

    local plan   = plan_or_err
    local result = plan.result
    local queue  = plan.download_queue or {}
    local total  = #queue
    local downloaded_files_to_refresh = plan.cleanup and plan.cleanup.downloaded_files_to_refresh or {}
    local downloaded_files_to_refresh_set = plan.cleanup and plan.cleanup.downloaded_files_to_refresh_set or {}
    result.shelf_type = active_shelf_type
    result.download_dir = active_download_dir
    local grimmlink_self = self

    local function shouldSkipExpensivePostSyncWork()
        return result.snapshot_unchanged == true
            and (tonumber(result.synced) or 0) <= 0
            and (tonumber(result.deleted) or 0) <= 0
    end

    local function runPendingShelfRemovalDrain(done_callback)
        if type(done_callback) ~= "function" then
            return
        end
        if not remote_delete_sync
            or not grimmlink_self.pending_sync
            or type(grimmlink_self.pending_sync.processPendingShelfRemovals) ~= "function" then
            done_callback()
            return
        end

        local drain_batch_size = math.max(1, math.floor(tonumber(opts.pending_removal_drain_batch_size) or 4))
        if drain_batch_size > 25 then
            drain_batch_size = 25
        end
        local rounds_left = math.max(1, tonumber(opts.pending_removal_drain_max_rounds) or 24)
        local function drainStep()
            if grimmlink_self._shelf_sync_cancelled then
                done_callback()
                return
            end

            local counters = {}
            local drain_result = { deleted = 0, failed = 0, errors = {} }
            local ok = grimmlink_self.pending_sync:processPendingShelfRemovals(grimmlink_self, {
                shelf_sync = grimmlink_self.shelf_sync,
                shelf_id = active_shelf_id,
                shelf_type = active_shelf_type,
                download_dir = active_download_dir,
                delete_sdr = grimmlink_self.delete_sdr_on_book_delete,
                retry_cooldown_seconds = grimmlink_self.pending_shelf_removal_retry_cooldown_seconds,
                max_entries = drain_batch_size,
                counters = counters,
                result = drain_result,
            })
            if ok then
                result.deleted = (tonumber(result.deleted) or 0) + (tonumber(drain_result.deleted) or 0)
                result.failed = (tonumber(result.failed) or 0) + (tonumber(drain_result.failed) or 0)
                for _, err in ipairs(drain_result.errors or {}) do
                    result.errors[#result.errors + 1] = err
                end
            end

            rounds_left = rounds_left - 1
            local processed = tonumber(counters.processed) or 0
            local pending_total = tonumber(counters.pending_total) or 0
            if rounds_left > 0 and processed > 0 and pending_total > 0 and not grimmlink_self._shelf_sync_cancelled then
                UIManager:scheduleIn(0.05, drainStep)
                return
            end
            done_callback()
        end

        UIManager:scheduleIn(0.01, drainStep)
    end

    local function runCleanupPhaseAsync(done_callback, mute_progress)
        if type(done_callback) ~= "function" then
            return
        end
        if not plan.cleanup or not plan.cleanup.remote_delete_sync then
            done_callback()
            return
        end

        if not grimmlink_self.shelf_sync or type(grimmlink_self.shelf_sync.runCleanupPhaseBatch) ~= "function" then
            pcall(function()
                grimmlink_self.shelf_sync:runCleanupPhase(plan.cleanup, result, function(msg)
                    if not mute_progress and not silent then
                        grimmlink_self:showShelfSyncMessage(safeToString(msg), 2)
                    end
                end)
            end)
            done_callback()
            return
        end

        local cleanup_state = nil
        local cleanup_batch_size = math.max(10, tonumber(opts.cleanup_batch_size) or 40)
        local function cleanupStep()
            if grimmlink_self._shelf_sync_cancelled then
                done_callback()
                return
            end
            local ok_batch, next_state, done = pcall(function()
                local state, batch_done = grimmlink_self.shelf_sync:runCleanupPhaseBatch(
                    plan.cleanup,
                    result,
                    cleanup_state,
                    cleanup_batch_size,
                    function(msg)
                        if not mute_progress and not silent then
                            grimmlink_self:showShelfSyncMessage(safeToString(msg), 2)
                        end
                    end
                )
                return state, batch_done
            end)
            if not ok_batch then
                logger.warn("GrimmLink: cleanup batch crashed")
                done_callback()
                return
            end
            cleanup_state = next_state
            if done then
                done_callback()
                return
            end
            UIManager:scheduleIn(0.05, cleanupStep)
        end

        UIManager:scheduleIn(0.01, cleanupStep)
    end

    local function runPostSyncMetadataIndexUpdate(done_callback)
        if type(done_callback) ~= "function" then
            return
        end
        if shouldSkipExpensivePostSyncWork() then
            result.metadata_index_path = nil
            done_callback()
            return
        end

        UIManager:scheduleIn(0.01, function()
            local resolved_dir = grimmlink_self.shelf_sync:resolveDownloadDir(active_download_dir)
            local index_path
            pcall(function()
                index_path = grimmlink_self.shelf_sync:writeMetadataIndex(nil, resolved_dir)
            end)
            pcall(function()
                grimmlink_self.shelf_sync:upsertBookInfoCache(nil)
            end)
            result.metadata_index_path = index_path
            done_callback()
        end)
    end

    if result.cancelled then
        self._shelf_sync_running = false
        self._active_sync_shelf_type = nil
        self._active_sync_download_dir = nil
        if not silent and not suppress_completion_summary then
            self:_showSyncCompletionSummary(result)
        end
        self:_broadcastSyncResult(result)
        if on_complete then
            pcall(on_complete, result)
        end
        return nil
    end

    -- Nothing to download → finish immediately.
    if total == 0 then
        local function finalizeNoDownloadSync()
            result.bookinfo_refresh = result.bookinfo_refresh or { total = 0, refreshed = 0, failed = 0 }
            if not result.cancelled and result.snapshot_token and active_shelf_id then
                grimmlink_self:saveShelfSnapshotToken(active_shelf_id, active_shelf_type, result.snapshot_token)
            end
            grimmlink_self._shelf_sync_running = false
            grimmlink_self._active_sync_shelf_type = nil
            grimmlink_self._active_sync_download_dir = nil
            if not silent and not suppress_completion_summary then
                grimmlink_self:_showSyncCompletionSummary(result)
            end
            grimmlink_self:_broadcastSyncResult(result)
            if followup_selection and followup_selection.id and not grimmlink_self._shelf_sync_cancelled then
                UIManager:scheduleIn(0.2, function()
                    grimmlink_self:syncShelfNow(silent, {
                        selection_override = followup_selection,
                        suppress_completion_summary = false,
                        on_complete = on_complete,
                    })
                end)
                return
            end
            if on_complete then
                pcall(on_complete, result)
            end
        end

        if not silent then
            grimmlink_self:showShelfSyncMessage(_("Finalizing shelf sync..."), 2)
        end
        runPendingShelfRemovalDrain(function()
            runCleanupPhaseAsync(function()
                runPostSyncMetadataIndexUpdate(function()
                    result.bookinfo_refresh = { total = 0, refreshed = 0, failed = 0 }
                    finalizeNoDownloadSync()
                end)
            end, false)
        end)
        return nil
    end

    -- Decide whether to use async (curl/wget subprocess) or blocking (LuaSocket).
    local use_async = self.api:isAsyncDownloadAvailable()
    if not use_async and not silent then
        self:showShelfSyncMessage(_("Async downloader unavailable; this device may feel less responsive during downloads."), 4)
    end

    -- Phase 2: Download loop.
    local idx = 0
    local active_handle  = nil  -- current curl download handle (async mode)
    local startNextDownload
    local handleCancel

    -- Helper: build progress info table from byte counts.
    local function fmtProgress(bytes_so_far, total_bytes)
        local info = { bytes = bytes_so_far or 0 }
        if total_bytes and total_bytes > 0 then
            info.total = total_bytes
            info.pct = math.min(100, math.floor(bytes_so_far / total_bytes * 100))
        else
            info.pct = 0
        end
        return info
    end

    local function finalizeSyncState()
        if result and not result.cancelled and result.snapshot_token and active_shelf_id then
            grimmlink_self:saveShelfSnapshotToken(active_shelf_id, active_shelf_type, result.snapshot_token)
        end
        grimmlink_self._shelf_sync_running = false
        grimmlink_self._active_sync_shelf_type = nil
        grimmlink_self._active_sync_download_dir = nil
        if not silent and not suppress_completion_summary then
            grimmlink_self:_showSyncCompletionSummary(result)
        end
        grimmlink_self:_broadcastSyncResult(result)
        if followup_selection and followup_selection.id and not grimmlink_self._shelf_sync_cancelled then
            UIManager:scheduleIn(0.2, function()
                grimmlink_self:syncShelfNow(silent, {
                    selection_override = followup_selection,
                    suppress_completion_summary = false,
                    on_complete = on_complete,
                })
            end)
            return
        end
        if on_complete then
            pcall(on_complete, result)
        end
    end

    local function disableAsyncForThisSync(reason, persist_for_session)
        if not use_async then
            return
        end
        use_async = false
        result.async_fallback = {
            used = true,
            reason = safeToString(reason or "async_disabled"),
        }
        if persist_for_session and grimmlink_self.api then
            grimmlink_self.api._async_available = false
        end
        logger.warn("GrimmLink: disabling async downloader for this sync:", result.async_fallback.reason)
        if not silent then
            grimmlink_self:showShelfSyncMessage(
                _("Async download became unavailable; falling back to blocking downloads."),
                4
            )
        end
    end

    local function runPostSyncBookInfoRefresh(done_callback)
        if type(done_callback) ~= "function" then
            return
        end

        if not grimmlink_self.refresh_bookinfo_after_shelf_sync then
            result.bookinfo_refresh = { total = 0, refreshed = 0, failed = 0, skipped = true }
            done_callback()
            return
        end
        if type(downloaded_files_to_refresh) ~= "table" or #downloaded_files_to_refresh == 0 then
            result.bookinfo_refresh = { total = 0, refreshed = 0, failed = 0 }
            done_callback()
            return
        end
        if not grimmlink_self.shelf_sync or type(grimmlink_self.shelf_sync.refreshBookInfoForFile) ~= "function" then
            result.bookinfo_refresh = {
                total = #downloaded_files_to_refresh,
                refreshed = 0,
                failed = #downloaded_files_to_refresh,
                skipped = true,
                error = "refresh_api_unavailable",
            }
            logger.warn("GrimmLink: shelf sync book-info refresh API unavailable")
            done_callback()
            return
        end

        local refresh_batch_size = math.floor(tonumber(grimmlink_self.refresh_bookinfo_batch_size) or 20)
        if refresh_batch_size < 1 then refresh_batch_size = 1 end
        if refresh_batch_size > 200 then refresh_batch_size = 200 end

        local refresh_result = { total = #downloaded_files_to_refresh, refreshed = 0, failed = 0, errors = {} }
        local refresh_index = 0
        local function rebuildSimpleUiMetadataCache()
            if not grimmlink_self.shelf_sync or type(grimmlink_self.shelf_sync.rebuildBookInfoCacheFromIndex) ~= "function" then
                return nil
            end
            local rebuild_download_dir = active_download_dir
            if type(grimmlink_self.shelf_sync.resolveDownloadDir) == "function" then
                rebuild_download_dir = grimmlink_self.shelf_sync:resolveDownloadDir(active_download_dir)
            end
            local ok_rebuild, counts_or_err = pcall(
                grimmlink_self.shelf_sync.rebuildBookInfoCacheFromIndex,
                grimmlink_self.shelf_sync,
                rebuild_download_dir
            )
            if ok_rebuild then
                return counts_or_err
            end
            return { error = safeToString(counts_or_err) }
        end

        if not silent then
            grimmlink_self:showShelfSyncMessage(_("Refreshing book info..."), 2)
        end

        local function processNextBatch()
            if grimmlink_self._shelf_sync_cancelled then
                result.bookinfo_refresh = refresh_result
                done_callback()
                return
            end

            local batch_processed = 0
            while refresh_index < #downloaded_files_to_refresh and batch_processed < refresh_batch_size do
                refresh_index = refresh_index + 1
                batch_processed = batch_processed + 1
                local file_path = downloaded_files_to_refresh[refresh_index]
                local ok_refresh, method_name, refresh_err = grimmlink_self.shelf_sync:refreshBookInfoForFile(file_path, {})
                if ok_refresh then
                    refresh_result.refreshed = refresh_result.refreshed + 1
                else
                    refresh_result.failed = refresh_result.failed + 1
                    refresh_result.errors[#refresh_result.errors + 1] = {
                        file_path = file_path,
                        method = method_name,
                        error = refresh_err,
                    }
                end
            end

            if not silent then
                grimmlink_self:showShelfSyncMessage(T(_("Refreshing covers %1 / %2"), refresh_index, refresh_result.total), 2)
            end

            if refresh_index >= #downloaded_files_to_refresh then
                result.bookinfo_refresh = refresh_result
                result.simpleui_cache_rebuild = rebuildSimpleUiMetadataCache()
                if not silent then
                    if refresh_result.failed > 0 then
                        grimmlink_self:showShelfSyncMessage(
                            _("Shelf sync complete. Some covers may need manual refresh."),
                            4
                        )
                    else
                        grimmlink_self:showShelfSyncMessage(_("Book info refresh complete"), 2)
                    end
                end
                done_callback()
                return
            end

            UIManager:scheduleIn(0.05, processNextBatch)
        end

        UIManager:scheduleIn(0.05, processNextBatch)
    end

    local function runBlockingDownloadForItem(item, post_delay_seconds)
        UIManager:nextTick(function()
            local book = item.book or {}
            local dl_opts = {
                expected_size_kb = book.fileSizeKb,
                downloaded_files_to_refresh = downloaded_files_to_refresh,
                downloaded_files_to_refresh_set = downloaded_files_to_refresh_set,
                on_progress = function(bytes_so_far, total_bytes_est)
                    if grimmlink_self._shelf_sync_cancelled then
                        return true
                    end
                    if not silent then
                        grimmlink_self:_updateSyncProgressPct(
                            idx, total, item.title,
                            fmtProgress(bytes_so_far, total_bytes_est))
                    end
                end,
                is_cancelled = function()
                    return grimmlink_self._shelf_sync_cancelled
                end,
            }
            local ok_dl, dl_err = pcall(function()
                return grimmlink_self.shelf_sync:executeDownload(
                    item, plan.cleanup.shelf_id, plan.cleanup.sync_start, dl_opts)
            end)

            if grimmlink_self._shelf_sync_cancelled then
                handleCancel()
                return
            end

            if ok_dl and dl_err then
                result.synced = result.synced + 1
                if not silent then
                    local est = (book.fileSizeKb or 0) * 1024
                    grimmlink_self:_updateSyncProgressPct(
                        idx, total, item.title, fmtProgress(est, est))
                end
            else
                result.failed = result.failed + 1
                local err = "Download failed bookId=" .. tostring(item.book_id)
                    .. ": " .. safeToString(dl_err)
                result.errors[#result.errors + 1] = err
                logger.warn("GrimmLink:", err)
            end
            UIManager:scheduleIn(post_delay_seconds or 0.1, startNextDownload)
        end)
    end

    -- Helper: finish sync (cleanup + summary + broadcast).
    local function finishSync()
        if not silent then
            grimmlink_self:_closeSyncProgress()
            grimmlink_self:showShelfSyncMessage(_("Cleaning up..."), 2)
        end
        runPendingShelfRemovalDrain(function()
            runCleanupPhaseAsync(function()
                runPostSyncMetadataIndexUpdate(function()
                    runPostSyncBookInfoRefresh(finalizeSyncState)
                end)
            end, false)
        end)
    end

    -- Helper: handle cancellation.
    handleCancel = function()
        result.cancelled = true
        if active_handle then
            pcall(grimmlink_self.api.cancelAsyncDownload, grimmlink_self.api, active_handle)
            active_handle = nil
        end
        grimmlink_self._shelf_sync_running = false
        grimmlink_self._active_sync_shelf_type = nil
        grimmlink_self._active_sync_download_dir = nil
        if not silent and not suppress_completion_summary then
            grimmlink_self:_showSyncCompletionSummary(result)
        end
        grimmlink_self:_broadcastSyncResult(result)
        if on_complete then
            pcall(on_complete, result)
        end
    end

    startNextDownload = function()
        -- Check cancel.
        if grimmlink_self._shelf_sync_cancelled then
            handleCancel()
            return
        end

        idx = idx + 1
        if idx > total then
            finishSync()
            return
        end

        local item = queue[idx]
        local enough_space, available_bytes, required_bytes, space_reason = grimmlink_self:checkDiskSpaceForShelfItem(item, active_download_dir)
        if not enough_space then
            result.skipped = (result.skipped or 0) + 1
            local msg = T(
                _("Skipped %1 (bookId=%2): insufficient storage.\nAvailable: %3 MB\nRequired (with margin): %4 MB"),
                safeToString(item and item.title or _("unknown")),
                safeToString(item and item.book_id or "?"),
                math.floor((tonumber(available_bytes) or 0) / (1024 * 1024)),
                math.floor((tonumber(required_bytes) or 0) / (1024 * 1024))
            )
            logger.warn("GrimmLink: " .. msg)
            result.errors[#result.errors + 1] = msg
            if not silent then
                grimmlink_self:showShelfSyncMessage(msg, 5)
            end
            UIManager:scheduleIn(0.1, startNextDownload)
            return
        elseif space_reason == "space_unavailable" then
            logger.warn("GrimmLink: storage free-space check unavailable; proceeding with download")
        end
        if not silent then
            grimmlink_self:_showSyncProgress(idx, total, item.title, nil)
        end

        if use_async then
            -- === ASYNC PATH: curl/wget subprocess ===
            UIManager:nextTick(function()
                local ok_start, handle_or_err, start_err = pcall(
                    grimmlink_self.shelf_sync.startAsyncDownload,
                    grimmlink_self.shelf_sync, item)
                if not ok_start or not handle_or_err then
                    local start_reason = handle_or_err
                    if ok_start then
                        start_reason = start_err or handle_or_err
                    end
                    disableAsyncForThisSync(
                        "async_start_failed bookId=" .. tostring(item.book_id)
                            .. ": " .. safeToString(start_reason or ok_start),
                        true
                    )
                    runBlockingDownloadForItem(item, 0.1)
                    return
                end

                active_handle = handle_or_err

                local function pollDownload()
                    if grimmlink_self._shelf_sync_cancelled then
                        handleCancel()
                        return
                    end

                    local ok_poll, status, bytes, total_bytes, exit_code = pcall(
                        grimmlink_self.api.pollAsyncDownload,
                        grimmlink_self.api, active_handle)

                    if not ok_poll then
                        pcall(grimmlink_self.api.cancelAsyncDownload, grimmlink_self.api, active_handle)
                        active_handle = nil
                        disableAsyncForThisSync("async_poll_failed: " .. safeToString(status), false)
                        runBlockingDownloadForItem(item, 0.1)
                        return
                    end

                    if status == "running" then
                        if not silent then
                            grimmlink_self:_updateSyncProgressPct(
                                idx, total, item.title, fmtProgress(bytes, total_bytes))
                        end
                        UIManager:scheduleIn(0.8, pollDownload)
                    elseif status == "done" then
                        pcall(grimmlink_self.shelf_sync.recordDownload,
                            grimmlink_self.shelf_sync,
                            item, plan.cleanup.shelf_id, plan.cleanup.sync_start,
                            downloaded_files_to_refresh, downloaded_files_to_refresh_set)
                        result.synced = result.synced + 1
                        active_handle = nil
                        if not silent then
                            grimmlink_self:_updateSyncProgressPct(
                                idx, total, item.title, fmtProgress(bytes, total_bytes or bytes))
                        end
                        UIManager:scheduleIn(0.5, startNextDownload)
                    else
                        local err = "Download failed for bookId=" .. tostring(item.book_id)
                        if status == "timeout" then
                            err = "Download timeout for bookId=" .. tostring(item.book_id) .. ". Check network quality or server speed."
                        end
                        if exit_code then
                            if exit_code == 127 then
                                err = "Async download tool missing on device (curl/wget not found)."
                            elseif exit_code == 22 then
                                err = "Download HTTP error (server URL may be wrong or access denied)."
                            elseif exit_code == 28 then
                                err = "Download timed out while connecting to server."
                            elseif exit_code == 7 then
                                err = "Download failed: connection refused by server."
                            elseif exit_code == 6 then
                                err = "Download failed: DNS lookup failed (check URL/network)."
                            else
                                err = err .. " (exit " .. tostring(exit_code) .. ")"
                            end
                        end
                        if status == "timeout" or exit_code == 127 or exit_code == 126 then
                            active_handle = nil
                            disableAsyncForThisSync(err, exit_code == 127 or exit_code == 126)
                            runBlockingDownloadForItem(item, 0.1)
                            return
                        end
                        result.failed = result.failed + 1
                        result.errors[#result.errors + 1] = err
                        logger.warn("GrimmLink:", err)
                        active_handle = nil
                        UIManager:scheduleIn(0.1, startNextDownload)
                    end
                end

                UIManager:scheduleIn(0.8, pollDownload)
            end)
        else
            -- === BLOCKING PATH: LuaSocket download with progress callback ===
            -- Works on all devices but UI freezes between progress updates.
            runBlockingDownloadForItem(item, 0.1)
        end
    end

    -- Kick off the first download.
    UIManager:scheduleIn(0.2, startNextDownload)

    -- Return nil because results come asynchronously.
    return nil
end

function Grimmlink:normalizeShelfList(shelves)
    local shelf_list = shelves
    if type(shelf_list) == "table" and type(shelf_list.content) == "table" then
        shelf_list = shelf_list.content
    elseif type(shelf_list) == "table" and type(shelf_list.items) == "table" then
        shelf_list = shelf_list.items
    end
    if type(shelf_list) ~= "table" then
        return {}
    end
    local normalized = {}
    for _, shelf in ipairs(shelf_list) do
        if type(shelf) == "table" then
            local shelf_type = normalizeShelfType(shelf.type or shelf.shelfType or shelf.shelf_type)
            local shelf_id = tonumber(shelf.id or shelf.shelfId or shelf.shelf_id)
            normalized[#normalized + 1] = {
                id = shelf_id,
                shelfId = shelf_id,
                name = shelf.name or shelf.title,
                title = shelf.title,
                type = shelf_type,
                shelfType = shelf_type,
                bookCount = shelf.bookCount or shelf.book_count or shelf.totalBooks or shelf.total_books,
                description = shelf.description,
            }
        end
    end
    return normalized
end

function Grimmlink:setShelfListCache(shelf_list)
    if type(shelf_list) ~= "table" then
        self._shelf_list_cache = nil
        self._shelf_list_cache_ts = nil
        return
    end
    self._shelf_list_cache = {}
    for idx, shelf in ipairs(shelf_list) do
        self._shelf_list_cache[idx] = shelf
    end
    self._shelf_list_cache_ts = os.time()
end

function Grimmlink:getCachedShelfList(max_age_seconds)
    local ttl = tonumber(max_age_seconds) or 90
    if ttl <= 0 then
        return nil, nil
    end
    if type(self._shelf_list_cache) ~= "table" or #self._shelf_list_cache == 0 then
        return nil, nil
    end
    if not self._shelf_list_cache_ts then
        return nil, nil
    end
    local age = os.time() - self._shelf_list_cache_ts
    if age < 0 or age > ttl then
        return nil, age
    end
    return self._shelf_list_cache, age
end

function Grimmlink:setShelfBooksCache(shelf_id, shelf_type, books)
    if not shelf_id or type(books) ~= "table" then
        return
    end
    self._shelf_books_cache = self._shelf_books_cache or {}
    local cache_key = normalizeShelfType(shelf_type) .. ":" .. tostring(shelf_id)
    self._shelf_books_cache[cache_key] = {
        ts = os.time(),
        books = books,
    }
end

function Grimmlink:getCachedShelfBooks(shelf_id, shelf_type, max_age_seconds)
    if not shelf_id then
        return nil, nil
    end
    local ttl = tonumber(max_age_seconds) or 15
    if ttl <= 0 then
        return nil, nil
    end
    local cache_map = self._shelf_books_cache
    if type(cache_map) ~= "table" then
        return nil, nil
    end
    local cache_key = normalizeShelfType(shelf_type) .. ":" .. tostring(shelf_id)
    local entry = cache_map[cache_key]
    -- Backward compatibility with very old cache key format (shelf-id only).
    -- IMPORTANT: only allow this fallback when shelf_type was not explicitly provided,
    -- otherwise regular/magic caches can bleed into each other for the same shelf id.
    local shelf_type_raw = shelf_type
    if type(shelf_type_raw) == "string" then
        shelf_type_raw = shelf_type_raw:gsub("^%s+", ""):gsub("%s+$", "")
    end
    if type(entry) ~= "table" and (shelf_type_raw == nil or shelf_type_raw == "") then
        entry = cache_map[tostring(shelf_id)]
    end
    if type(entry) ~= "table" or type(entry.books) ~= "table" or not entry.ts then
        return nil, nil
    end
    local age = os.time() - entry.ts
    if age < 0 or age > ttl then
        return nil, age
    end
    return entry.books, age
end

function Grimmlink:applyShelfSelection(shelf_id, shelf_name, shelf_type)
    local normalized_id = maybeNumber(shelf_id)
    local normalized_type = normalizeShelfType(shelf_type)
    if not normalized_id then
        return false
    end
    local name = safeToString(shelf_name)

    if normalized_type == "magic" then
        self:saveSetting("selected_magic_shelf_id", normalized_id)
        self:saveSetting("selected_magic_shelf_name", name)
        self:saveSetting("sync_magic_shelf_enabled", true)
    else
        self:saveSetting("selected_regular_shelf_id", normalized_id)
        self:saveSetting("selected_regular_shelf_name", name)
        self:saveSetting("sync_regular_shelf_enabled", true)
    end

    self:saveSetting("shelf_id", normalized_id)
    self:saveSetting("shelf_name", name)
    self:saveSetting("shelf_type", normalized_type)
    return true
end

function Grimmlink:showShelfPickerDialog(shelf_list, from_cache, cache_age_seconds, requested_type)
    if type(shelf_list) ~= "table" or #shelf_list == 0 then
        self:showMessage(_("No shelves available"), 3)
        return
    end

    local buttons = {}
    buttons[#buttons + 1] = {
        {
            text = _("Refresh shelf list"),
            callback = function()
                self:invokeSafely("refresh shelf picker", function()
                    if self._shelf_picker_dialog then
                        UIManager:close(self._shelf_picker_dialog)
                        self._shelf_picker_dialog = nil
                    end
                    self:showShelfPicker(true, requested_type)
                end)
            end,
        },
    }

    local grouped = { regular = {}, magic = {} }
    for _, shelf in ipairs(shelf_list) do
        local shelf_type = normalizeShelfType(shelf.type or shelf.shelfType or shelf.shelf_type)
        grouped[shelf_type][#grouped[shelf_type] + 1] = shelf
    end

    local function addHeader(text)
        buttons[#buttons + 1] = {
            {
                text = text,
                callback = function() end,
            },
        }
    end

    local function addShelfButton(shelf)
        local shelf_id = tonumber(shelf.id or shelf.shelfId or shelf.shelf_id)
        local shelf_type = normalizeShelfType(shelf.type or shelf.shelfType or shelf.shelf_type)
        local shelf_name = safeToString(shelf.name or shelf.title)
        if shelf_name == "" then
            shelf_name = shelf_id and ("Shelf #" .. tostring(shelf_id)) or _("Unnamed shelf")
        end
        local count_value = shelf.bookCount or shelf.book_count or shelf.totalBooks or shelf.total_books
        local count_str = count_value and (" (" .. tostring(count_value) .. ")") or ""
        local type_label = shelf_type == "magic" and _("[Magic] ") or _("[Regular] ")
        buttons[#buttons + 1] = {
            {
                text = type_label .. shelf_name .. count_str,
                callback = function()
                    self:invokeSafely("select shelf", function()
                        if not shelf_id then
                            self:showMessage(_("Invalid shelf ID from server"), 4)
                            return
                        end
                        self:applyShelfSelection(shelf_id, shelf_name, shelf_type)
                        if self._shelf_picker_dialog then
                            UIManager:close(self._shelf_picker_dialog)
                            self._shelf_picker_dialog = nil
                        end
                        self:showMessage(T(_("Shelf selected: %1"), shelf_name), 2)
                    end)
                end,
            },
        }
    end

    if #grouped.regular > 0 then
        addHeader(_("Regular Shelves"))
        for _, shelf in ipairs(grouped.regular) do
            addShelfButton(shelf)
        end
    end
    if #grouped.magic > 0 then
        addHeader(_("Magic Shelves"))
        for _, shelf in ipairs(grouped.magic) do
            addShelfButton(shelf)
        end
    end

    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function()
                self:invokeSafely("cancel shelf picker", function()
                    if self._shelf_picker_dialog then
                        UIManager:close(self._shelf_picker_dialog)
                        self._shelf_picker_dialog = nil
                    end
                end)
            end,
        },
    }

    local title = _("Select Shelf to Sync")
    if requested_type == "magic" then
        title = _("Select Magic Shelf to Sync")
    elseif requested_type == "regular" then
        title = _("Select Regular Shelf to Sync")
    end
    if from_cache then
        local age_value = tostring(math.max(0, math.floor(tonumber(cache_age_seconds) or 0)))
        title = T(_("%1 (cached %2s)"), title, age_value)
    end

    self._shelf_picker_dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(self._shelf_picker_dialog)
end

function Grimmlink:showShelfPicker(force_refresh, requested_type)
    if not self:requireReady({ require_api = true }) then
        return
    end
    if not self.enabled then
        self:showMessage(_("GrimmLink sync is disabled. Enable it first."), 3)
        return
    end
    if self.server_url == "" or self.username == "" then
        self:showMessage(_("Configure server URL and username first."), 3)
        return
    end
    if not force_refresh then
        local cached_list, cache_age = self:getCachedShelfList(90)
        if cached_list then
            self:showShelfPickerDialog(cached_list, true, cache_age, requested_type)
            return
        end
    end

    if not self:isOnline() then
        self:showMessage(_("No network connection"), 3)
        return
    end
    if not self:refreshApiClient() then
        self:showMessage(_("Connection not ready"), 3)
        return
    end

    self:showMessage(_("Fetching shelves from server..."), 2)
    local ok, shelves = self.api:getShelves(requested_type)
    if not ok then
        local cached_list, cache_age = self:getCachedShelfList(300)
        if cached_list then
            self:showMessage(_("Using cached shelf list (server not reachable)"), 3)
            self:showShelfPickerDialog(cached_list, true, cache_age, requested_type)
            return
        end
        self:showMessage(T(_("Failed to fetch shelves: %1"), safeToString(shelves)), 4)
        return
    end

    local shelf_list = self:normalizeShelfList(shelves)
    if type(shelf_list) ~= "table" or #shelf_list == 0 then
        self:showMessage(_("No shelves available"), 3)
        return
    end

    self:setShelfListCache(shelf_list)
    self:showShelfPickerDialog(shelf_list, false, nil, requested_type)
end

function Grimmlink:showShelfTypeChooser(title, on_select)
    local dialog
    local function choose(type_value)
        if dialog then
            UIManager:close(dialog)
        end
        if type(on_select) == "function" then
            on_select(type_value)
        end
    end
    dialog = ButtonDialog:new{
        title = title or _("Select Shelf Type"),
        buttons = {
            {
                {
                    text = _("regular"),
                    callback = function() choose("regular") end,
                },
                {
                    text = _("magic"),
                    callback = function() choose("magic") end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() choose(nil) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Grimmlink:validateShelfIdAndMaybeSave(shelf_id, shelf_type, save_on_success)
    local normalized_id = maybeNumber(shelf_id)
    local normalized_type = normalizeShelfType(shelf_type)
    if not normalized_id then
        self:showMessage(_("Invalid shelf ID"), 3)
        return
    end
    if not self:requireReady({ require_api = true }) then
        return
    end
    if not self:isOnline() then
        self:showMessage(_("No network connection"), 3)
        return
    end
    if not self:refreshApiClient() then
        self:showMessage(_("Connection not ready"), 3)
        return
    end

    self:showMessage(_("Validating shelf access..."), 2)
    local ok_books, books_or_err, code = self.api:getShelfBooks(normalized_id, normalized_type)
    if not ok_books then
        local numeric_code = tonumber(code)
        if numeric_code == 403 then
            self:showMessage(_("Shelf exists but is not accessible to this KOReader user"), 4)
        elseif numeric_code == 404 then
            self:showMessage(_("Shelf not found for this type or user"), 4)
        else
            self:showMessage(T(_("Shelf validation failed: %1"), safeToString(books_or_err)), 4)
        end
        return
    end

    local shelf_name = nil
    local ok_shelves, shelves = self.api:getShelves(normalized_type)
    if ok_shelves and type(shelves) == "table" then
        for _, shelf in ipairs(shelves) do
            if maybeNumber(shelf.id or shelf.shelfId or shelf.shelf_id) == normalized_id then
                shelf_name = safeToString(shelf.name or shelf.title)
                break
            end
        end
    end
    if not shelf_name or shelf_name == "" then
        shelf_name = T(_("Shelf #%1"), normalized_id)
    end

    if save_on_success then
        self:applyShelfSelection(normalized_id, shelf_name, normalized_type)
        self:showMessage(T(_("Shelf saved: %1 (%2)"), shelf_name, normalized_type), 3)
    else
        self:showMessage(T(_("Shelf is accessible: %1 (%2)\nBooks visible: %3"), shelf_name, normalized_type, #(books_or_err or {})), 4)
    end
end

function Grimmlink:promptAndValidateShelfId(save_on_success)
    local verb = save_on_success and _("Add Shelf by ID") or _("Validate Shelf ID")
    self:showShelfTypeChooser(verb, function(chosen_type)
        if not chosen_type then
            return
        end
        self:showNumberInput(_("Shelf ID"), self.shelf_id or 0, _("Enter shelf id"), function(value)
            local shelf_id = maybeNumber(value)
            if not shelf_id then
                self:showMessage(_("Invalid shelf ID"), 3)
                return
            end
            self:validateShelfIdAndMaybeSave(shelf_id, chosen_type, save_on_success == true)
        end)
    end)
end

end

return M
