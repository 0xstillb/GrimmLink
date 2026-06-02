local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local ButtonDialog = deps.ButtonDialog
    local UIManager = deps.UIManager
    local _ = deps._
    local T = deps.T
    local READ_STATUS_CAPABILITY_CACHE_SECONDS = deps.READ_STATUS_CAPABILITY_CACHE_SECONDS
    local READING_COMPLETION_PROMPT_THRESHOLD_PERCENT = deps.READING_COMPLETION_PROMPT_THRESHOLD_PERCENT
    local READING_COMPLETION_PROMPT_RESET_PERCENT = deps.READING_COMPLETION_PROMPT_RESET_PERCENT
    local READING_COMPLETION_PROMPT_STATE_KEY = deps.READING_COMPLETION_PROMPT_STATE_KEY
    local READING_COMPLETION_RATING_STATE_KEY = deps.READING_COMPLETION_RATING_STATE_KEY
    local READING_COMPLETION_END_DIALOG_POLL_SECONDS = deps.READING_COMPLETION_END_DIALOG_POLL_SECONDS
    local READING_COMPLETION_END_DIALOG_MAX_ATTEMPTS = deps.READING_COMPLETION_END_DIALOG_MAX_ATTEMPTS
    local buildReadingCompletionRatingState = deps.buildReadingCompletionRatingState
    local cloneTable = deps.cloneTable
    local convertTenScaleRatingToSummaryRating = deps.convertTenScaleRatingToSummaryRating
    local maybeNumber = deps.maybeNumber
    local normalizeManualReadStatus = deps.normalizeManualReadStatus
    local normalizeTenScaleRating = deps.normalizeTenScaleRating
    local nowUtc = deps.nowUtc
    local safeToString = deps.safeToString
    local tryCloseDocSettings = deps.tryCloseDocSettings
    local tryFlushDocSettings = deps.tryFlushDocSettings
    local tryReadSetting = deps.tryReadSetting
    local tryWriteSetting = deps.tryWriteSetting
function Grimmlink:readReadingCompletionPromptState(doc_settings)
    local state = tryReadSetting(doc_settings, READING_COMPLETION_PROMPT_STATE_KEY)
    if type(state) == "table" then
        return cloneTable(state)
    end
    return {}
end

function Grimmlink:writeReadingCompletionPromptState(doc_settings, state)
    local normalized = type(state) == "table" and cloneTable(state) or {}
    if normalized.prompted ~= true then
        normalized.prompted = false
    end
    normalized.updated_at = nowUtc()
    return tryWriteSetting(doc_settings, READING_COMPLETION_PROMPT_STATE_KEY, normalized)
end

function Grimmlink:loadReadingCompletionPromptState(context)
    if type(context) ~= "table" or not context.file_path or context.file_path == "" then
        return nil, false, nil
    end
    local doc_settings, should_close = self:loadWritableDocSettings(context.file_path)
    if type(doc_settings) ~= "table" then
        return nil, false, nil
    end
    return self:readReadingCompletionPromptState(doc_settings), should_close, doc_settings
end

function Grimmlink:updateReadingCompletionPromptState(context, prompted, percentage)
    local state, should_close, doc_settings = self:loadReadingCompletionPromptState(context)
    if type(doc_settings) ~= "table" then
        return false
    end
    state = type(state) == "table" and state or {}
    state.prompted = prompted == true
    state.progress_percentage = tonumber(percentage) or 0
    state.threshold_percentage = READING_COMPLETION_PROMPT_THRESHOLD_PERCENT
    state.reset_percentage = READING_COMPLETION_PROMPT_RESET_PERCENT
    state.file_hash = safeToString(context and context.file_hash)
    state.book_id = maybeNumber(context and context.book_id)
    if prompted == true then
        state.prompted_at = nowUtc()
    else
        state.prompted_at = nil
    end
    self:writeReadingCompletionPromptState(doc_settings, state)
    tryFlushDocSettings(doc_settings)
    if should_close then
        tryCloseDocSettings(doc_settings)
    end
    return true
end

function Grimmlink:shouldShowReadingCompletionPrompt(context, percentage)
    if type(context) ~= "table" or not context.file_path or context.file_path == "" then
        return false
    end
    if not self.enabled or not self:isTrackingEnabledForContext(context) then
        return false
    end

    local numeric_percentage = tonumber(percentage) or 0
    if numeric_percentage < READING_COMPLETION_PROMPT_RESET_PERCENT then
        self:updateReadingCompletionPromptState(context, false, numeric_percentage)
        return false
    end
    if numeric_percentage < READING_COMPLETION_PROMPT_THRESHOLD_PERCENT then
        return false
    end

    local state = self:loadReadingCompletionPromptState(context)
    if type(state) == "table" and state.prompted == true then
        return false
    end
    return true
end

function Grimmlink:getReadingCompletionContext(context_override)
    if type(context_override) == "table" and context_override.file_path then
        return context_override
    end

    local metadata_context = self:getMetadataExtractionContext()
    if type(metadata_context) == "table" and metadata_context.file_path then
        return metadata_context
    end

    local current_context = self:getCurrentDocumentContext()
    if type(current_context) == "table" and current_context.file_path then
        return current_context
    end

    if self.current_session and self.current_session.file_path then
        return {
            file_path = self.current_session.file_path,
            file_hash = self.current_session.file_hash,
            book_id = self.current_session.book_id,
            book_file_id = self.current_session.book_file_id,
        }
    end
    return nil
end

function Grimmlink:cancelScheduledReadingCompletionPrompt()
    if self._scheduled_reading_completion_prompt and UIManager and type(UIManager.unschedule) == "function" then
        pcall(UIManager.unschedule, UIManager, self._scheduled_reading_completion_prompt)
    end
    self._scheduled_reading_completion_prompt = nil
    self._scheduled_reading_completion_prompt_file = nil
end

function Grimmlink:isKoreaderEndOfBookDialogVisible()
    if not UIManager or type(UIManager.getTopmostVisibleWidget) ~= "function" then
        return false
    end
    local top_widget = UIManager:getTopmostVisibleWidget() or {}
    return top_widget.name == "end_document"
end

function Grimmlink:waitForKoreaderEndOfBookUi(callback, attempt)
    attempt = tonumber(attempt) or 0
    if type(callback) ~= "function" then
        return false
    end
    if not self:isKoreaderEndOfBookDialogVisible() then
        callback()
        return true
    end
    if attempt >= READING_COMPLETION_END_DIALOG_MAX_ATTEMPTS then
        callback()
        return true
    end
    if UIManager and type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(READING_COMPLETION_END_DIALOG_POLL_SECONDS, function()
            self:waitForKoreaderEndOfBookUi(callback, attempt + 1)
        end)
        return true
    end
    callback()
    return true
end

function Grimmlink:scheduleReadingCompletionPrompt(context, end_snapshot, options)
    options = options or {}
    local completion_context = self:getReadingCompletionContext(context)
    local percentage = end_snapshot and end_snapshot.percentage or nil
    if not self:shouldShowReadingCompletionPrompt(completion_context, percentage) then
        return false
    end
    if self._scheduled_reading_completion_prompt_file == completion_context.file_path then
        return false
    end

    local function present_prompt()
        local latest_percentage = percentage
        local active_context = self:getReadingCompletionContext(completion_context)
        if active_context and active_context.file_path == completion_context.file_path then
            local latest_snapshot = self:getCurrentProgressSnapshot(
                active_context.file_hash,
                active_context.file_path,
                active_context.book_id,
                active_context.book_file_id
            )
            if latest_snapshot and latest_snapshot.percentage ~= nil then
                latest_percentage = latest_snapshot.percentage
            end
        end
        if not self:shouldShowReadingCompletionPrompt(completion_context, latest_percentage) then
            return
        end

        self:updateReadingCompletionPromptState(completion_context, true, latest_percentage)
        self:showReadingCompletionMenu({
            context = completion_context,
            prompt_source = options.prompt_source or "close",
        })
    end

    local function show_prompt()
        self._scheduled_reading_completion_prompt = nil
        self._scheduled_reading_completion_prompt_file = nil
        if options.wait_for_koreader_end_dialog == true then
            self:waitForKoreaderEndOfBookUi(present_prompt, 0)
        else
            present_prompt()
        end
    end

    self:cancelScheduledReadingCompletionPrompt()
    self._scheduled_reading_completion_prompt = show_prompt
    self._scheduled_reading_completion_prompt_file = completion_context.file_path
    if UIManager and type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(tonumber(options.initial_delay_seconds) or 0, show_prompt)
    else
        show_prompt()
    end
    return true
end

function Grimmlink:getCurrentBookIdForManualStatus()
    local context = self:getCurrentDocumentContext()
    if context and context.book_id then
        return context.book_id
    end
    if self.current_session and self.current_session.book_id then
        return self.current_session.book_id
    end
    if context and context.file_hash and self.db and type(self.db.getBookByHash) == "function" then
        local cached = self.db:getBookByHash(context.file_hash)
        if cached and cached.book_id then
            return cached.book_id
        end
    end
    return nil
end

function Grimmlink:getReadStatusCapabilities(force_refresh)
    if not force_refresh and self._read_status_capabilities and self._read_status_capabilities_ts then
        local age = os.time() - self._read_status_capabilities_ts
        if age >= 0 and age <= READ_STATUS_CAPABILITY_CACHE_SECONDS then
            return self._read_status_capabilities
        end
    end

    if not self:isApiReady({ "getSupportedReadStatuses" }) then
        return nil
    end
    if not self:refreshApiClient() then
        return nil
    end

    local ok, statuses = self.api:getSupportedReadStatuses()
    if not ok or type(statuses) ~= "table" then
        return nil
    end

    local supported = {}
    for _, status_value in ipairs(statuses) do
        local normalized = normalizeManualReadStatus(status_value)
        if normalized then
            supported[normalized] = true
        end
    end

    self._read_status_capabilities = supported
    self._read_status_capabilities_ts = os.time()
    return supported
end

function Grimmlink:buildManualReadStatusActions()
    local supported = self:getReadStatusCapabilities(false)
    if type(supported) ~= "table" then
        return {}
    end

    local candidates = {
        { backend = "READING", label = _("Mark as Reading") },
        { backend = "READ", label = _("Mark as Read") },
        { backend = "UNREAD", label = _("Mark as Unread") },
        { backend = "PAUSED", label = _("Mark as On Hold") },
        { backend = "ABANDONED", label = _("Mark as Abandoned") },
        { backend = "RE_READING", label = _("Mark as Re-reading") },
    }

    local actions = {}
    for _, candidate in ipairs(candidates) do
        if supported[candidate.backend] then
            actions[#actions + 1] = candidate
        end
    end
    return actions
end

function Grimmlink:getReadingCompletionReadAction()
    local actions = self:buildManualReadStatusActions()
    for _, action in ipairs(actions) do
        if action.backend == "READ" then
            return action
        end
    end
    return nil
end

function Grimmlink:setManualReadStatusForBook(book_id, backend_status, label_text)
    if not book_id then
        self:showMessage(_("No matched book ID for current document"), 4)
        return false
    end
    if not self:isOnline() then
        self:showMessage(_("No network connection"), 3)
        return false
    end
    if not self:isApiReady({ "updateBookReadStatus" }) or not self:refreshApiClient() then
        self:showMessage(_("Connection not ready"), 3)
        return false
    end

    local ok, response_or_err = self.api:updateBookReadStatus(book_id, backend_status)
    if ok then
        self:showMessage(T(_("%1 completed"), label_text), 3)
        return true
    else
        self:showMessage(T(_("Failed to set read status: %1"), safeToString(response_or_err)), 4)
        return false
    end
end

function Grimmlink:setManualReadStatusForContext(context, backend_status, label_text)
    local book_id = maybeNumber(context and context.book_id) or self:getCurrentBookIdForManualStatus()
    return self:setManualReadStatusForBook(book_id, backend_status, label_text)
end

function Grimmlink:setManualReadStatusForCurrentBook(backend_status, label_text)
    return self:setManualReadStatusForContext(nil, backend_status, label_text)
end

function Grimmlink:setBookRatingForContext(context, raw_rating)
    local ten_scale_rating = normalizeTenScaleRating(raw_rating)
    if not ten_scale_rating then
        self:showMessage(_("Rating must be between 1 and 10"), 3)
        return false
    end
    local summary_rating = convertTenScaleRatingToSummaryRating(ten_scale_rating)

    local completion_context = self:getReadingCompletionContext(context)
    if not completion_context or not completion_context.file_path or completion_context.file_path == "" then
        self:showMessage(_("No active document"), 3)
        return false
    end

    local doc_settings, should_close = self:loadWritableDocSettings(completion_context.file_path)
    if type(doc_settings) ~= "table" then
        self:showMessage(_("Unable to access document settings"), 4)
        return false
    end

    local summary = tryReadSetting(doc_settings, "summary")
    if type(summary) ~= "table" then
        summary = type(doc_settings.summary) == "table" and cloneTable(doc_settings.summary) or {}
    else
        summary = cloneTable(summary)
    end
    summary.rating = summary_rating
    doc_settings.summary = summary
    tryWriteSetting(doc_settings, "summary", summary)
    tryWriteSetting(doc_settings, READING_COMPLETION_RATING_STATE_KEY,
        buildReadingCompletionRatingState(ten_scale_rating, summary_rating))
    tryFlushDocSettings(doc_settings)
    if should_close then
        tryCloseDocSettings(doc_settings)
    end

    local queue_result = self:extractAndQueueCurrentMetadata("reading-completion-rating", completion_context)
    local queued_count = queue_result and queue_result.queued and tonumber(queue_result.queued.queued) or 0
    if self.metadata_sync_enabled and self.rating_sync_enabled then
        self:showMessage(T(_("Rating saved: %1/10 (KOReader %2/5)\nQueued metadata: %3"),
            ten_scale_rating, summary_rating, queued_count or 0), 3)
    else
        self:showMessage(T(_("Rating saved locally: %1/10 (KOReader %2/5)"),
            ten_scale_rating, summary_rating), 3)
    end
    return true
end

function Grimmlink:setCurrentBookRating(raw_rating)
    return self:setBookRatingForContext(nil, raw_rating)
end

function Grimmlink:showReadingCompletionRatingDialog(options)
    options = options or {}
    local current_rating = nil
    local context = self:getReadingCompletionContext(options.context)
    if context then
        local extracted = self:extractMetadataForContext(context)
        if extracted and extracted.rating and extracted.rating.raw then
            if tonumber(extracted.rating.scale) == 10 and tonumber(extracted.rating.value) then
                current_rating = extracted.rating.value
            else
                current_rating = extracted.rating.normalized or (extracted.rating.raw * 2)
            end
        end
    end

    self:showNumberInput(_("Set Rating"), current_rating or "", _("Enter a rating from 1 to 10"), function(value)
        self:setBookRatingForContext(context, value)
    end)
end

function Grimmlink:pushReadingCompletionProgress(options)
    options = options or {}
    local context = self:getReadingCompletionContext(options.context)
    if not context or not context.file_path or context.file_path == "" then
        self:showMessage(_("No book available for Reading Completion"), 3)
        return false
    end

    local current_context = self:getCurrentDocumentContext()
    if current_context and current_context.file_path == context.file_path then
        self:syncThisBookFromPath(context.file_path)
        return true
    end

    self:syncPendingNow(false, {
        progress_limit = 20,
        session_limit = 50,
        metadata_limit = 50,
    })
    return true
end

function Grimmlink:finishCurrentBookAndSync(options)
    options = options or {}
    local context = self:getReadingCompletionContext(options.context)
    local read_action = self:getReadingCompletionReadAction()
    if read_action then
        self:setManualReadStatusForContext(context, read_action.backend, read_action.label)
    end
    return self:pushReadingCompletionProgress({ context = context })
end

function Grimmlink:showReadingCompletionMenu(options)
    options = options or {}
    local context = self:getReadingCompletionContext(options.context)
    if not context then
        self:showMessage(_("No book currently open"), 3)
        return
    end

    local read_action = self:getReadingCompletionReadAction()
    local primary_label = read_action and _("Finish & Sync Now") or _("Sync Completion Now")
    local buttons = {
        {
            {
                text = primary_label,
                callback = function()
                    self:finishCurrentBookAndSync({ context = context })
                end,
            },
        },
    }
    if read_action then
        buttons[#buttons + 1] = {
            {
                text = read_action.label,
                callback = function()
                    self:setManualReadStatusForContext(context, read_action.backend, read_action.label)
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Set Rating"),
            callback = function()
                self:showReadingCompletionRatingDialog({ context = context })
            end,
        },
    }
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function() end,
        },
    }

    UIManager:show(ButtonDialog:new{
        title = options.title or _("Reading Completion"),
        buttons = buttons,
    })
end

function Grimmlink:showManualReadStatusMenu(options)
    options = options or {}
    local context = self:getReadingCompletionContext(options.context)
    local actions = self:buildManualReadStatusActions()
    if #actions == 0 then
        self:showMessage(_("Manual reading status is not supported by this backend"), 4)
        return
    end

    local buttons = {}
    for _, action in ipairs(actions) do
        buttons[#buttons + 1] = {
            {
                text = action.label,
                callback = function()
                    self:setManualReadStatusForContext(context, action.backend, action.label)
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function() end,
        },
    }

    UIManager:show(ButtonDialog:new{
        title = _("Manual Reading Status"),
        buttons = buttons,
    })
end
end

return M
