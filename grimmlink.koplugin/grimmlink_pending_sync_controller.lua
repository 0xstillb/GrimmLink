local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local UIManager = deps.UIManager
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS
    local nowUtc = deps.nowUtc
    local safeDbValueCall = deps.safeDbValueCall

function Grimmlink:syncPendingNow(silent, opts)
    if self.pending_sync and type(self.pending_sync.syncPendingNow) == "function" then
        return self.pending_sync:syncPendingNow(self, silent, opts)
    end

    opts = opts or {}

    if not silent then
        local context = self:getCurrentDocumentContext()
        if context and not self:isTrackingEnabledForContext(context) then
            self:showTrackingDisabledMessage()
        else
            self:extractAndQueueCurrentMetadata("manual-sync", context)
        end
        if not self:isOnline() then
            self:maybePromptEnableWifiForManualSync()
            return
        end
    end

    if not self:requireReady({ require_api = true, silent = silent }) then
        return
    end

    local progress_synced, progress_failed = self:syncPendingProgress(true, opts.progress_limit)
    local sessions_synced, sessions_failed = self:syncPendingSessions(true, opts.session_limit)
    local metadata_synced, metadata_failed = self:syncPendingMetadata(true, opts.metadata_limit)

    if not silent then
        self:showMessage(T(
            _("GrimmLink sync complete\nProgress: %1 synced, %2 failed\nSessions: %3 synced, %4 failed\nMetadata: %5 synced, %6 failed"),
            progress_synced,
            progress_failed,
            sessions_synced,
            sessions_failed,
            metadata_synced,
            metadata_failed
        ), 4)
    end
end

function Grimmlink:getQueueSummaryCounters()
    if self.pending_sync and type(self.pending_sync.getQueueSummaryCounters) == "function" then
        return self.pending_sync:getQueueSummaryCounters(self)
    end
    return {
        pending_progress = safeDbValueCall(self.db, "getPendingProgressCount", 0),
        pending_sessions = safeDbValueCall(self.db, "getPendingSessionCount", 0),
        pending_metadata = safeDbValueCall(self.db, "getPendingMetadataCount", 0),
        pending_shelf_removals = safeDbValueCall(self.db, "getPendingShelfRemovalCount", 0),
    }
end

function Grimmlink:shouldRunAutoPendingSync(cooldown_seconds)
    local cooldown = tonumber(cooldown_seconds) or tonumber(self.auto_sync_cooldown_seconds) or DEFAULTS.auto_sync_cooldown_seconds
    if cooldown <= 0 then
        return true
    end

    local now = nowUtc()
    if self._last_auto_pending_sync_at and (now - self._last_auto_pending_sync_at) < cooldown then
        self:logDbg("GrimmLink: skipping auto pending sync; cooldown active")
        return false
    end
    self._last_auto_pending_sync_at = now
    return true
end

function Grimmlink:schedulePendingSync(label, delay_seconds, opts)
    if self._scheduled_pending_sync then
        return
    end
    opts = opts or {}
    if opts.respect_cooldown and not self:shouldRunAutoPendingSync(opts.cooldown_seconds) then
        return
    end

    local function runPendingSync()
        self._scheduled_pending_sync = nil
        if not self:isOnline() then
            return
        end
        self:invokeSafely(label or "pending sync", function()
            self:syncPendingNow(true, opts)
        end, {}, { silent = true })
    end

    if UIManager and type(UIManager.scheduleIn) == "function" then
        self._scheduled_pending_sync = runPendingSync
        UIManager:scheduleIn(delay_seconds or 0.75, runPendingSync)
    else
        runPendingSync()
    end
end

end

return M
