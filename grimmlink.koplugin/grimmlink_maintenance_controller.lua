local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local ConfirmBox = deps.ConfirmBox
    local UIManager = deps.UIManager
    local _ = deps._
    local T = deps.T
    local safeDbBoolCall = deps.safeDbBoolCall
    local safeDbValueCall = deps.safeDbValueCall
    local safeToString = deps.safeToString

    local function clearPendingSessions(db)
        if not db or type(db.getPendingSessions) ~= "function" or type(db.deletePendingSession) ~= "function" then
            return false
        end

        local ok_all = true
        while true do
            local rows = db:getPendingSessions(500) or {}
            if #rows == 0 then
                break
            end
            for _, row in ipairs(rows) do
                if not db:deletePendingSession(row.id) then
                    ok_all = false
                end
            end
        end
        return ok_all
    end

function Grimmlink:checkForUpdates(silent, options)
    options = options or {}
    if not self.updater or type(self.updater.checkForUpdates) ~= "function" then
        if not silent then
            self:showMessage(_("Updater is unavailable"), 4)
        end
        return nil, "updater unavailable"
    end

    if not silent then
        self:showMessage(_("Checking for updates..."), 2)
    end

    if type(self.updater.setAllowPrerelease) == "function" then
        self.updater:setAllowPrerelease(self.allow_prerelease_updates)
    end
    local use_cache = silent == true and options.force_refresh ~= true
    local result, err = self.updater:checkForUpdates(use_cache)
    if not result then
        if not silent then
            self:showMessage(T(_("Update check failed:\n%1"), safeToString(err)), 4)
        end
        return nil, err
    end

    if result.available then
        if not silent then
            local from_version = safeToString(result.current_version) or _("unknown")
            local to_version = safeToString(result.latest_version) or _("unknown")
            if result.release_info then
                self:showConfirmAction(
                    T(_("Update available: %1 -> %2\nInstall now?"), from_version, to_version),
                    _("Update"),
                    function()
                        self:installUpdate(result.release_info)
                    end
                )
            else
                self:showMessage(T(_("Update available: %1"), to_version), 3)
            end
        end
    elseif not silent then
        self:showMessage(_("Already up to date"), 2)
    end
    return result, nil
end

function Grimmlink:installUpdate(release_info)
    if not self.updater or type(self.updater.installUpdate) ~= "function" then
        return false, "updater unavailable"
    end
    local ok, err = self.updater:installUpdate(release_info)
    if not ok then
        self:showMessage(T(_("Update failed:\n%1"), safeToString(err)), 4)
        return false, err
    end
    local dialog = ConfirmBox:new{
        text        = _("Update installed.\n\nRestart KOReader now to apply it?"),
        ok_text     = _("Restart Now"),
        cancel_text = _("Later"),
        ok_callback = function()
            UIManager:restartKOReader()
        end,
    }
    UIManager:show(dialog)
    return true
end

function Grimmlink:clearUpdateCacheWithConfirm()
    if not self.updater or type(self.updater.clearCache) ~= "function" then
        self:showMessage(_("Updater is unavailable"), 3)
        return
    end

    self:showConfirmAction(
        _("Clear cached update metadata?\nThis only clears update-check cache."),
        _("Clear Cache"),
        function()
            local ok = self.updater:clearCache()
            self:showMessage(ok and _("Update cache cleared") or _("Failed to clear update cache"), 3)
        end
    )
end

function Grimmlink:clearUnmatchedBookCacheWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = type(self.db.getUnmatchedCacheCount) == "function" and self.db:getUnmatchedCacheCount() or 0
    if (count or 0) <= 0 then
        self:showMessage(_("No unmatched cache entries"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear unmatched book cache (%1 entries)?"), count),
        _("Clear"),
        function()
            local ok = type(self.db.clearUnmatchedCache) == "function" and self.db:clearUnmatchedCache() or false
            self:showMessage(ok and _("Unmatched book cache cleared") or _("Failed to clear unmatched cache"), 3)
        end
    )
end

function Grimmlink:clearAllBookCacheWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = type(self.db.getStaleCacheCount) == "function" and self.db:getStaleCacheCount() or 0
    if (count or 0) <= 0 then
        self:showMessage(_("Book cache is already empty"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear all book cache (%1 entries)?\nYou may need to re-match books on next sync."), count),
        _("Clear All"),
        function()
            local ok = type(self.db.clearStaleCache) == "function" and self.db:clearStaleCache() or false
            self:showMessage(ok and _("All book cache cleared") or _("Failed to clear book cache"), 3)
        end
    )
end

function Grimmlink:clearNotFoundHashesWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    if type(self.db.clearNotFoundHashes) ~= "function" then
        self:showMessage(_("Not Found hash cache is not supported in this build"), 3)
        return
    end

    local count = type(self.db.getNotFoundHashesCount) == "function" and self.db:getNotFoundHashesCount() or nil
    if count and count <= 0 then
        self:showMessage(_("No not-found hash entries"), 2)
        return
    end

    local prompt = count
        and T(_("Clear not-found hash entries (%1)?"), count)
        or _("Clear not-found hash entries?")

    self:showConfirmAction(
        prompt,
        _("Clear"),
        function()
            local ok = self.db:clearNotFoundHashes()
            self:showMessage(ok and _("Not-found hash cache cleared") or _("Failed to clear not-found hash cache"), 3)
        end
    )
end

function Grimmlink:clearPendingProgressQueueWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = type(self.db.getPendingProgressCount) == "function" and self.db:getPendingProgressCount() or 0
    if (count or 0) <= 0 then
        self:showMessage(_("No pending progress queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear pending progress queue (%1 items)?"), count),
        _("Clear Queue"),
        function()
            local ok = type(self.db.deleteAllPendingProgress) == "function" and self.db:deleteAllPendingProgress() or false
            self:showMessage(ok and _("Pending progress queue cleared") or _("Failed to clear pending progress queue"), 3)
        end
    )
end

function Grimmlink:clearPendingSessionsQueueWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = type(self.db.getPendingSessionCount) == "function" and self.db:getPendingSessionCount() or 0
    if (count or 0) <= 0 then
        self:showMessage(_("No pending session queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear pending session queue (%1 items)?"), count),
        _("Clear Queue"),
        function()
            local ok_all = clearPendingSessions(self.db)
            self:showMessage(ok_all and _("Pending session queue cleared") or _("Failed to clear pending session queue"), 3)
        end
    )
end

function Grimmlink:clearPendingMetadataQueueWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    if (count or 0) <= 0 then
        self:showMessage(_("No pending metadata queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear pending metadata queue (%1 items)?"), count),
        _("Clear Queue"),
        function()
            local ok = safeDbBoolCall(self.db, "deleteAllPendingMetadata")
            self:showMessage(ok and _("Pending metadata queue cleared") or _("Failed to clear pending metadata queue"), 3)
        end
    )
end

function Grimmlink:clearSyncedMetadataHistoryWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    self:showConfirmAction(
        _("Clear synced metadata history?\nThis only affects local dedupe history and does not remove server metadata."),
        _("Clear History"),
        function()
            local ok = safeDbBoolCall(self.db, "clearSyncedMetadataHistory")
            self:showMessage(ok and _("Synced metadata history cleared") or _("Failed to clear synced metadata history"), 3)
        end
    )
end

function Grimmlink:clearShelfTombstonesWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local count = safeDbValueCall(self.db, "getShelfTombstoneCount", 0)
    if (count or 0) <= 0 then
        self:showMessage(_("No shelf tombstones"), 2)
        return
    end
    self:showConfirmAction(
        T(_("Clear shelf tombstones (%1 items)?"), count),
        _("Clear Tombstones"),
        function()
            local ok = safeDbBoolCall(self.db, "clearShelfTombstones")
            self:showMessage(ok and _("Shelf tombstones cleared") or _("Failed to clear shelf tombstones"), 3)
        end
    )
end

function Grimmlink:clearPendingShelfRemovalsWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local count = safeDbValueCall(self.db, "getPendingShelfRemovalCount", 0)
    if (count or 0) <= 0 then
        self:showMessage(_("No pending shelf removals"), 2)
        return
    end
    self:showConfirmAction(
        T(_("Clear pending shelf removals (%1 items)?"), count),
        _("Clear Queue"),
        function()
            local ok = safeDbBoolCall(self.db, "clearPendingShelfRemovals")
            self:showMessage(ok and _("Pending shelf removals cleared") or _("Failed to clear pending shelf removals"), 3)
        end
    )
end

function Grimmlink:showDatabaseStatus()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local queues = self:getQueueSummaryCounters()
    local pending_progress = queues.pending_progress or 0
    local pending_sessions = queues.pending_sessions or 0
    local pending_metadata = queues.pending_metadata or 0
    local synced_metadata = safeDbValueCall(self.db, "getSyncedMetadataCount", 0)
    local pending_shelf_removals = queues.pending_shelf_removals or 0
    local shelf_tombstones = safeDbValueCall(self.db, "getShelfTombstoneCount", 0)
    local shelf_stats = safeDbValueCall(self.db, "getShelfSyncStats", { total = 0, downloaded_by_grimmlink = 0 })

    self:showMessage(T(
        _("DB Status\nPending progress: %1\nPending sessions: %2\nPending metadata: %3\nSynced metadata history: %4\nPending shelf removals: %5\nShelf tombstones: %6\nShelf map rows: %7"),
        pending_progress,
        pending_sessions,
        pending_metadata,
        synced_metadata,
        pending_shelf_removals,
        shelf_tombstones,
        shelf_stats and shelf_stats.total or 0
    ), 6)
end

function Grimmlink:clearSyncQueuesWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local progress_count = type(self.db.getPendingProgressCount) == "function" and self.db:getPendingProgressCount() or 0
    local session_count = type(self.db.getPendingSessionCount) == "function" and self.db:getPendingSessionCount() or 0
    local metadata_count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    local total = (progress_count or 0) + (session_count or 0) + (metadata_count or 0)
    if total <= 0 then
        self:showMessage(_("No pending sync queue items"), 2)
        return
    end

    self:showConfirmAction(
        T(_("Clear sync queues?\nProgress: %1\nSessions: %2\nMetadata: %3"), progress_count, session_count, metadata_count),
        _("Clear Queues"),
        function()
            local progress_ok = true
            local sessions_ok = true
            local metadata_ok = true

            if (progress_count or 0) > 0 and type(self.db.deleteAllPendingProgress) == "function" then
                progress_ok = self.db:deleteAllPendingProgress()
            end

            if (session_count or 0) > 0 then
                sessions_ok = clearPendingSessions(self.db)
            end

            if (metadata_count or 0) > 0 then
                metadata_ok = safeDbBoolCall(self.db, "deleteAllPendingMetadata")
            end

            local ok_all = progress_ok and sessions_ok and metadata_ok
            self:showMessage(ok_all and _("Sync queues cleared") or _("Failed to clear one or more sync queues"), 3)
        end
    )
end

function Grimmlink:runQuickCleanupWithConfirm()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local unmatched_count = type(self.db.getUnmatchedCacheCount) == "function" and self.db:getUnmatchedCacheCount() or 0
    local progress_count = safeDbValueCall(self.db, "getPendingProgressCount", 0)
    local session_count = safeDbValueCall(self.db, "getPendingSessionCount", 0)
    local metadata_count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    local can_clear_update_cache = self.updater and type(self.updater.clearCache) == "function"

    self:showConfirmAction(
        T(
            _("Run quick cleanup?\n- Clear update cache: %1\n- Clear unmatched book cache: %2\n- Clear pending progress queue: %3\n- Clear pending session queue: %4\n- Clear pending metadata queue: %5"),
            can_clear_update_cache and _("yes") or _("no"),
            unmatched_count,
            progress_count,
            session_count,
            metadata_count
        ),
        _("Run Cleanup"),
        function()
            local all_ok = true

            if can_clear_update_cache then
                if not self.updater:clearCache() then
                    all_ok = false
                end
            end

            if (unmatched_count or 0) > 0 and type(self.db.clearUnmatchedCache) == "function" then
                if not self.db:clearUnmatchedCache() then
                    all_ok = false
                end
            end

            if (progress_count or 0) > 0 and type(self.db.deleteAllPendingProgress) == "function" then
                if not self.db:deleteAllPendingProgress() then
                    all_ok = false
                end
            end

            if (session_count or 0) > 0 then
                if not clearPendingSessions(self.db) then
                    all_ok = false
                end
            end

            if (metadata_count or 0) > 0 then
                if not safeDbBoolCall(self.db, "deleteAllPendingMetadata") then
                    all_ok = false
                end
            end

            self:showMessage(all_ok and _("Quick cleanup complete") or _("Quick cleanup finished with some failures"), 4)
        end
    )
end

function Grimmlink:maybeCheckForUpdatesOnStartup()
    if not self.check_update_on_startup then
        return
    end
    self:runAfterUiSettles(function()
        if not self:isOnline() then
            return
        end
        local result = self:checkForUpdates(true, { force_refresh = true })
        if result and result.available and result.release_info then
            local from_version = safeToString(result.current_version) or _("unknown")
            local to_version = safeToString(result.latest_version) or _("unknown")
            self:showConfirmAction(
                T(_("Update available: %1 -> %2\nInstall now?"), from_version, to_version),
                _("Update"),
                function()
                    self:installUpdate(result.release_info)
                end
            )
        end
    end)
end

function Grimmlink:showAbout()
    local version_info = nil
    if self.plugin_dir then
        local ok, data = pcall(dofile, self.plugin_dir .. "/plugin_version.lua")
        if ok and type(data) == "table" then
            version_info = data
        end
    end

    local lines = {
        _("GrimmLink"),
        version_info and T(_("Version: %1"), version_info.version or _("unknown")) or _("Version: unknown"),
        _("Stable minimal companion for Grimmory."),
        _("EPUB Web Reader Bridge is intentionally disabled."),
    }
    self:showMessage(table.concat(lines, "\n"), 5)
end

function Grimmlink:showPdfBridgeStatus()
    self:showMessage(self:isPdfWebReaderBridgeEnabled() and _("PDF Web Reader Bridge enabled") or _("PDF Web Reader Bridge disabled"), 2)
end

end

return M
