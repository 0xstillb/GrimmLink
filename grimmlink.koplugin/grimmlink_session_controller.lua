local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local UIManager = deps.UIManager
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS
    local maybeNumber = deps.maybeNumber
    local nowUtc = deps.nowUtc
    local roundToSingleDecimal = deps.roundToSingleDecimal
    local sanitizeTitle = deps.sanitizeTitle
    local toIso8601 = deps.toIso8601

function Grimmlink:validateSession(duration_seconds, progress_delta, start_page, end_page)
    if duration_seconds < (tonumber(self.session_min_seconds) or DEFAULTS.session_min_seconds) then
        local pages_delta = math.abs((tonumber(end_page) or 0) - (tonumber(start_page) or 0))
        local progress_delta_value = math.abs(tonumber(progress_delta) or 0)
        if pages_delta < 1 and progress_delta_value < 0.1 then
            return false
        end
    end
    return true
end

function Grimmlink:buildSingleSessionPayload(group, item)
    return {
        bookId = maybeNumber(group.bookId) or group.bookId,
        bookHash = group.bookHash,
        bookType = group.bookType,
        startTime = item.startTime,
        endTime = item.endTime,
        durationSeconds = maybeNumber(item.durationSeconds) or 0,
        durationFormatted = item.durationFormatted,
        startProgress = roundToSingleDecimal(item.startProgress),
        endProgress = roundToSingleDecimal(item.endProgress),
        progressDelta = roundToSingleDecimal(item.progressDelta),
        startLocation = item.startLocation,
        endLocation = item.endLocation,
        currentPage = maybeNumber(item.currentPage),
        totalPages = maybeNumber(item.totalPages),
        device = group.device,
        deviceId = group.deviceId,
    }
end

function Grimmlink:startSession()
    if not self.enabled or not self:requireReady({ require_api = false, silent = true }) or not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end

    local file_path = tostring(self.ui.document.file)
    local cached = self:resolveBookByFilePath(file_path)
    local file_hash = cached and cached.file_hash or nil
    if not file_hash or file_hash == "" then
        file_hash = self:calculateBookHash(file_path)
    end

    local tracking_enabled = self:isTrackingEnabled(file_hash, file_path)
    local matched = nil
    if tracking_enabled then
        matched = self:resolveBookByHash(file_path, file_hash, true)
    end
    local book_id = maybeNumber(matched and matched.book_id or (cached and cached.book_id or nil))
    local book_file_id = maybeNumber(matched and matched.bookFileId or (cached and cached.book_file_id or nil))
    local title = matched and matched.title or (cached and cached.title or sanitizeTitle(file_path))
    local start_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)

    self.current_session = {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
        book_title = title,
        start_time = nowUtc(),
        start_snapshot = start_snapshot,
        book_type = self:getBookType(file_path),
        tracking_enabled = tracking_enabled,
    }

    local function doNetworkSync()
        -- Clear handle first so this task is not reused across sessions.
        self._scheduled_session_open_sync = nil
        if not self.current_session or self.current_session.file_hash ~= file_hash then
            return
        end
        if self.current_session.tracking_enabled == false then
            return
        end
        self:invokeSafely("session open sync", function()
            local use_pdf_bridge = self:getBookType(file_path) == "PDF"
                and self:isPdfWebReaderBridgeEnabled()
            if use_pdf_bridge then
                self:maybePullPdfWebProgress(file_hash, file_path, book_id, book_file_id, true)
            else
                self:maybePullRemoteProgress(file_hash, file_path, book_id, book_file_id, true)
            end
            if self:isOnline() then
                self:schedulePendingSync("session open pending sync", 0.75, {
                    progress_limit = 10,
                    session_limit = 25,
                    respect_cooldown = true,
                })
            end
        end, {}, { silent = true })
    end

    if UIManager and type(UIManager.scheduleIn) == "function" then
        if self._scheduled_session_open_sync and type(UIManager.unschedule) == "function" then
            pcall(UIManager.unschedule, UIManager, self._scheduled_session_open_sync)
        end
        self._scheduled_session_open_sync = doNetworkSync
        UIManager:scheduleIn(0.5, doNetworkSync)
    else
        doNetworkSync()
    end
end

function Grimmlink:endSession(options)
    options = options or {}
    if not self.db or not self.current_session then
        return false
    end

    -- Prevent open-session deferred work from racing close-session handling.
    if self._scheduled_session_open_sync and UIManager and type(UIManager.unschedule) == "function" then
        pcall(UIManager.unschedule, UIManager, self._scheduled_session_open_sync)
        self._scheduled_session_open_sync = nil
    end
    if self._progress_conflict_dialog and UIManager then
        pcall(UIManager.close, UIManager, self._progress_conflict_dialog)
        self._progress_conflict_dialog = nil
    end

    local session = self.current_session
    local metadata_context = {
        file_path = session.file_path,
        file_hash = session.file_hash,
        book_id = session.book_id,
        book_file_id = session.book_file_id,
    }
    self.current_session = nil

    if not self:requireReady({ require_api = false, silent = true }) then
        return false
    end

    local file_path = session.file_path
    local file_hash = session.file_hash
    local book_id = session.book_id
    local book_file_id = session.book_file_id
    local end_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local duration_seconds = math.max(0, nowUtc() - (session.start_time or nowUtc()))
    local start_snapshot = session.start_snapshot or {}
    local state = self.db:getProgressState(file_hash)
    local progress_delta = (tonumber(end_snapshot.percentage) or 0) - (tonumber(start_snapshot.percentage) or 0)
    local session_valid = self:validateSession(
        duration_seconds,
        progress_delta,
        start_snapshot.currentPage,
        end_snapshot.currentPage
    )

    self:rememberLocalSnapshot(file_hash, end_snapshot, "local-" .. (options.reason or "close"))
    if session.tracking_enabled ~= false then
        self:extractAndQueueCurrentMetadata("document-" .. (options.reason or "close"), metadata_context)
    end

    if session_valid and session.tracking_enabled ~= false then
        self.db:addPendingSession({
            bookId = book_id,
            bookHash = file_hash,
            bookType = session.book_type,
            device = self.device_name,
            deviceId = self.device_id,
            startTime = toIso8601(session.start_time),
            endTime = toIso8601(end_snapshot.timestamp),
            durationSeconds = duration_seconds,
            durationFormatted = self:formatDuration(duration_seconds),
            startProgress = roundToSingleDecimal(start_snapshot.percentage or 0),
            endProgress = roundToSingleDecimal(end_snapshot.percentage or 0),
            progressDelta = roundToSingleDecimal(progress_delta),
            startLocation = start_snapshot.location or "",
            endLocation = end_snapshot.location or "",
            currentPage = end_snapshot.currentPage,
            totalPages = end_snapshot.totalPages,
        })
    end

    local should_push = session.tracking_enabled ~= false and self:shouldPushProgress(end_snapshot, state, options.reason or "close")
    if should_push and self.auto_push_on_close then
        local reason = options.reason or "close"
        if reason == "close" or reason == "suspend" or reason == "exit" then
            local native_payload = self:prepareNativeProgressPayload(end_snapshot)
            local queued = self:queueProgressSnapshot(end_snapshot, "native", native_payload)
            if not queued then
                self:pushProgressSnapshot(end_snapshot, reason, true)
            end

            if self:isPdfWebReaderBridgeEnabled() and end_snapshot.fileFormat == "PDF" and end_snapshot.bookId then
                local bridge_payload = self:preparePdfBridgePayload(end_snapshot, {
                    force = reason == "close" or reason == "exit",
                })
                local bridge_queued = self:queueProgressSnapshot(end_snapshot, "pdf_bridge", {
                    bookId = end_snapshot.bookId,
                    bookHash = end_snapshot.bookHash,
                    request = bridge_payload,
                })
                if not bridge_queued then
                    self:pushPdfWebProgress(end_snapshot, reason, true)
                end
            end
        else
            self:pushProgressSnapshot(end_snapshot, reason, true)
            self:pushPdfWebProgress(end_snapshot, reason, true)
        end
    end

    if self:isOnline() then
        self:schedulePendingSync("session close sync", 0.75, {
            progress_limit = 10,
            session_limit = 25,
        })
    end
    if (options.reason or "close") == "close" then
        self:scheduleReadingCompletionPrompt(metadata_context, end_snapshot)
    end
    return true
end

function Grimmlink:syncPendingSessions(silent, limit)
    local synced = 0
    local failed = 0

    if not self.db then
        return synced, failed
    end
    if not self:requireReady({ require_api = true, silent = silent }) then
        return synced, failed
    end
    if not self:isOnline() then
        return synced, failed
    end

    if not self:isApiReady({ "getBookByHash", "submitSession", "submitSessionBatch" }) then
        return synced, failed
    end
    if not self:refreshApiClient() then
        return synced, failed
    end
    local pending = self.db:getPendingSessions(limit or 500)
    if #pending == 0 then
        return synced, failed
    end

    local hash_resolved = {}
    local hash_not_found = {}
    for _, session in ipairs(pending) do
        if self:isTrackingEnabled(session.bookHash, nil) then
            if not session.bookId and session.bookHash and session.bookHash ~= "" then
                local h = session.bookHash
                if hash_resolved[h] then
                    session.bookId = hash_resolved[h]
                    self.db:updatePendingSessionBookId(session.id, hash_resolved[h])
                elseif hash_resolved[h] == nil and not hash_not_found[h] then
                    local cached = self.db:getBookByHash(h)
                    if cached and cached.book_id then
                        hash_resolved[h] = cached.book_id
                        session.bookId = cached.book_id
                        self.db:updatePendingSessionBookId(session.id, cached.book_id)
                    else
                        local ok_lookup, book, lookup_code = self.api:getBookByHash(h)
                        if ok_lookup and book and book.id then
                            hash_resolved[h] = tonumber(book.id)
                            session.bookId = hash_resolved[h]
                            self.db:updateBookId(h, hash_resolved[h])
                            self.db:updatePendingSessionBookId(session.id, hash_resolved[h])
                        elseif lookup_code == 404 then
                            hash_not_found[h] = true
                            hash_resolved[h] = false
                        else
                            hash_resolved[h] = false
                        end
                    end
                end
            end
        end
    end

    local groups = {}
    for _, session in ipairs(pending) do
        if not self:isTrackingEnabled(session.bookHash, nil) then
            -- Keep queued rows untouched while tracking is disabled for this book.
        elseif not session.bookId then
            if hash_not_found[session.bookHash] then
                self.db:deletePendingSession(session.id)
                failed = failed + 1
            else
                self.db:incrementSessionRetryCount(session.id)
                failed = failed + 1
            end
        else
            local group_key = table.concat({
                tostring(session.bookId),
                session.bookHash or "",
                session.bookType or "EPUB",
                session.device or "",
                session.deviceId or "",
            }, "|")
            groups[group_key] = groups[group_key] or {
                bookId = maybeNumber(session.bookId) or session.bookId,
                bookHash = session.bookHash,
                bookType = session.bookType,
                device = session.device,
                deviceId = session.deviceId,
                sessions = {},
            }
            groups[group_key].sessions[#groups[group_key].sessions + 1] = session
        end
    end

    for _, group in pairs(groups) do
        local items = {}
        for _, session in ipairs(group.sessions) do
            items[#items + 1] = {
                startTime = session.startTime,
                endTime = session.endTime,
                durationSeconds = session.durationSeconds,
                durationFormatted = session.durationFormatted or session.duration_formatted or self:formatDuration(session.durationSeconds),
                startProgress = roundToSingleDecimal(session.startProgress),
                endProgress = roundToSingleDecimal(session.endProgress),
                progressDelta = roundToSingleDecimal(session.progressDelta),
                startLocation = session.startLocation,
                endLocation = session.endLocation,
                currentPage = session.currentPage,
                totalPages = session.totalPages,
            }
        end

        local success = false
        local handled_individually = false
        if #items == 1 then
            success = self.api:submitSession(self:buildSingleSessionPayload(group, items[1]))
        else
            local batch_ok, batch_response, batch_code = self.api:submitSessionBatch(
                group.bookId,
                group.bookHash,
                group.bookType,
                group.device,
                group.deviceId,
                items
            )
            if batch_ok then
                success = true
            else
                handled_individually = true
                local group_success = true
                for index, session in ipairs(group.sessions) do
                    local single_ok = self.api:submitSession(self:buildSingleSessionPayload(group, items[index]))
                    if single_ok then
                        self.db:deletePendingSession(session.id)
                        synced = synced + 1
                    else
                        self.db:incrementSessionRetryCount(session.id)
                        failed = failed + 1
                        group_success = false
                    end
                end
                success = group_success
            end
        end

        if handled_individually then
            -- counts already applied above
        elseif success and #items > 1 then
            for _, session in ipairs(group.sessions) do
                self.db:deletePendingSession(session.id)
                synced = synced + 1
            end
        elseif success then
            for _, session in ipairs(group.sessions) do
                self.db:deletePendingSession(session.id)
                synced = synced + 1
            end
        else
            for _, session in ipairs(group.sessions) do
                self.db:incrementSessionRetryCount(session.id)
                failed = failed + 1
            end
        end
    end

    if not silent and (synced > 0 or failed > 0) then
        self:showMessage(T(_("Pending session sync\nSynced: %1\nFailed: %2"), synced, failed), 3)
    end
    return synced, failed
end

end

return M
