local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local ButtonDialog = deps.ButtonDialog
    local UIManager = deps.UIManager
    local bit = deps.bit
    local json = deps.json
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS
    local FIXED_PAGE_FORMATS = deps.FIXED_PAGE_FORMATS
    local REFLOWABLE_FORMATS = deps.REFLOWABLE_FORMATS
    local absDifference = deps.absDifference
    local cloneTable = deps.cloneTable
    local formatTimestamp = deps.formatTimestamp
    local isNonEmpty = deps.isNonEmpty
    local isNumericOnlyToken = deps.isNumericOnlyToken
    local maybeNumber = deps.maybeNumber
    local normalizePercent = deps.normalizePercent
    local nowUtc = deps.nowUtc
    local safeDispatchEvent = deps.safeDispatchEvent
    local safeMethodCall = deps.safeMethodCall
    local safeToString = deps.safeToString
    local sanitizeTitle = deps.sanitizeTitle
    local tryReadSetting = deps.tryReadSetting

function Grimmlink:getBookType(file_path)
    local extension = safeToString(file_path):match("^.+%.(.+)$")
    if not extension then
        return "EPUB"
    end

    extension = extension:upper()
    if extension == "PDF" then
        return "PDF"
    end
    if extension == "CBZ" or extension == "CBR" or extension == "CB7" then
        return "CBX"
    end
    if extension == "DJVU" or extension == "DJV" then
        return "DJVU"
    end
    if extension == "MOBI" then
        return "MOBI"
    end
    if extension == "AZW" or extension == "AZW3" then
        return "AZW3"
    end
    if extension == "FB2" then
        return "FB2"
    end
    if extension == "HTML" or extension == "HTM" then
        return "HTML"
    end
    if extension == "TXT" then
        return "TXT"
    end
    if extension == "DOCX" then
        return "DOCX"
    end
    return "EPUB"
end

function Grimmlink:normalizeFormatToken(value)
    if value == nil then
        return nil
    end
    local token = safeToString(value):gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" then
        return nil
    end
    token = token:upper()
    if token == "CBZ" or token == "CBR" or token == "CB7" then
        return "CBX"
    end
    return token
end

function Grimmlink:isFixedPageFormat(file_path, book_type, file_format)
    local format = self:normalizeFormatToken(file_format)
        or self:normalizeFormatToken(book_type)
        or self:normalizeFormatToken(self:getBookType(file_path))
    return format ~= nil and FIXED_PAGE_FORMATS[format] == true
end

function Grimmlink:isReflowableFormat(file_path, book_type, file_format)
    if self:isFixedPageFormat(file_path, book_type, file_format) then
        return false
    end
    local format = self:normalizeFormatToken(file_format)
        or self:normalizeFormatToken(book_type)
        or self:normalizeFormatToken(self:getBookType(file_path))
    if format == nil then
        return true
    end
    if REFLOWABLE_FORMATS[format] == true then
        return true
    end
    return not FIXED_PAGE_FORMATS[format]
end

function Grimmlink:calculateBookHash(file_path)
    local file = io.open(file_path, "rb")
    if not file then
        self:logWarn("GrimmLink: unable to open file for hashing", file_path)
        return nil
    end

    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or not sha2 or not sha2.md5 then
        file:close()
        self:logErr("GrimmLink: ffi/sha2.md5 unavailable")
        return nil
    end

    local file_size = file:seek("end")
    file:seek("set", 0)

    local base = 1024
    local block_size = 1024
    local chunks = {}

    for i = -1, 10 do
        local position = bit.lshift(base, 2 * i)
        if position >= file_size then
            break
        end
        file:seek("set", position)
        local chunk = file:read(block_size)
        if chunk then
            chunks[#chunks + 1] = chunk
        end
    end

    file:close()
    return sha2.md5(table.concat(chunks))
end

function Grimmlink:getCurrentPageInfo()
    local document = self.ui and self.ui.document or nil
    if not document then
        return nil, nil
    end

    local current_page = nil
    if self.view and self.view.state and self.view.state.page then
        current_page = tonumber(self.view.state.page)
    end
    if current_page == nil and self.ui and self.ui.paging then
        current_page = safeMethodCall(self.ui.paging, "getCurrentPage")
    end
    if current_page == nil then
        current_page = safeMethodCall(document, "getCurrentPage")
    end

    local total_pages = safeMethodCall(document, "getPageCount")
    current_page = maybeNumber(current_page)
    total_pages = maybeNumber(total_pages)
    return current_page, total_pages
end

function Grimmlink:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local current_page, total_pages = self:getCurrentPageInfo()
    local document = self.ui and self.ui.document or nil
    local file_format = self:getBookType(file_path)
    local is_fixed_page = self:isFixedPageFormat(file_path, file_format, file_format)
    local is_reflowable = self:isReflowableFormat(file_path, file_format, file_format)
    local allow_reflowable_percentage = self.send_reflowable_percentage == true
    local raw_location = nil

    if document then
        local position = safeMethodCall(document, "getCurrentPos")
        local xpointer = safeMethodCall(document, "getXPointer")
        if is_fixed_page and current_page and file_format == "PDF" then
            raw_location = tostring(current_page)
        else
            raw_location = xpointer
            if raw_location == nil then
                raw_location = safeMethodCall(document, "getCurrentLocation")
            end
            if raw_location == nil then
                raw_location = position
            end
            if is_reflowable and isNumericOnlyToken(raw_location) then
                raw_location = nil
            end
        end
    end

    if (raw_location == nil or (is_reflowable and isNumericOnlyToken(raw_location))) and self.ui and self.ui.doc_settings then
        local last_xpointer = tryReadSetting(self.ui.doc_settings, "last_xpointer")
        if isNonEmpty(last_xpointer) and (not is_reflowable or not isNumericOnlyToken(last_xpointer)) then
            raw_location = last_xpointer
        end
    end
    if raw_location == nil then
        if is_fixed_page and current_page then
            raw_location = current_page
        end
    end

    local percentage = nil
    if current_page and total_pages and total_pages > 0 and (is_fixed_page or allow_reflowable_percentage) then
        percentage = normalizePercent(current_page / total_pages)
    end

    local snapshot = {
        timestamp = nowUtc(),
        document = file_hash or file_path,
        bookHash = file_hash,
        bookId = book_id,
        bookFileId = book_file_id,
        fileFormat = file_format,
        bookType = file_format,
        progress = safeToString(raw_location),
        location = safeToString(raw_location),
        percentage = percentage,
        currentPage = current_page,
        totalPages = total_pages,
        device = self.device_name,
        deviceId = self.device_id,
        file_path = file_path,
    }

    if snapshot.progress == "" and snapshot.currentPage and is_fixed_page then
        snapshot.progress = tostring(snapshot.currentPage)
    end
    if snapshot.location == "" and snapshot.progress ~= "" then
        snapshot.location = snapshot.progress
    end

    return snapshot
end

function Grimmlink:normalizeRemoteProgress(remote_progress)
    if not remote_progress or type(remote_progress) ~= "table" then
        return nil
    end

    local normalized = cloneTable(remote_progress)
    normalized.bookHash = normalized.bookHash or normalized.document
    normalized.bookId = maybeNumber(normalized.bookId)
    normalized.bookFileId = maybeNumber(normalized.bookFileId or normalized.book_file_id)
    normalized.percentage = normalizePercent(normalized.percentage)
    normalized.currentPage = maybeNumber(normalized.currentPage)
    normalized.totalPages = maybeNumber(normalized.totalPages)
    normalized.timestamp = maybeNumber(normalized.timestamp or normalized.updatedAt)
    normalized.deviceId = normalized.deviceId or normalized.device_id
    normalized.bookType = normalized.bookType or normalized.fileFormat
    normalized.fileFormat = normalized.fileFormat and tostring(normalized.fileFormat):upper() or nil
    normalized.location = isNonEmpty(normalized.location) and tostring(normalized.location)
        or (isNonEmpty(normalized.progress) and tostring(normalized.progress) or nil)
    normalized.progress = isNonEmpty(normalized.progress) and tostring(normalized.progress)
        or normalized.location
    normalized.source = normalized.source or normalized.device or normalized.fileFormat
    return self:applyFormatProgressPolicy(normalized)
end

function Grimmlink:applyFormatProgressPolicy(snapshot)
    if not snapshot or type(snapshot) ~= "table" then
        return snapshot
    end

    if self:isReflowableFormat(snapshot.file_path, snapshot.bookType, snapshot.fileFormat) then
        if self.send_reflowable_percentage ~= true then
            snapshot.percentage = nil
        end
        snapshot.cfi = nil
    end

    return snapshot
end

function Grimmlink:hasMeaningfulProgress(snapshot)
    return (snapshot and (
        snapshot.percentage ~= nil
        or isNonEmpty(snapshot.location)
        or isNonEmpty(snapshot.progress)
        or snapshot.currentPage ~= nil
    )) and true or false
end

function Grimmlink:progressDifferenceExceeded(left, right)
    if not left or not right then
        return false
    end

    local left_reflowable = self:isReflowableFormat(left.file_path, left.bookType, left.fileFormat)
    local right_reflowable = self:isReflowableFormat(right.file_path, right.bookType, right.fileFormat)
    local both_reflowable = left_reflowable and right_reflowable

    if not both_reflowable then
        local percent_delta = absDifference(left.percentage, right.percentage) or 0
        if percent_delta >= (tonumber(self.threshold_percent) or DEFAULTS.threshold_percent) then
            return true
        end

        if left.currentPage ~= nil and right.currentPage ~= nil then
            local page_delta = math.abs((tonumber(left.currentPage) or 0) - (tonumber(right.currentPage) or 0))
            if page_delta >= (tonumber(self.threshold_pages) or DEFAULTS.threshold_pages) then
                return true
            end
        end
    end

    if isNonEmpty(left.location) and isNonEmpty(right.location) and tostring(left.location) ~= tostring(right.location) then
        return true
    end

    return false
end

function Grimmlink:shouldPromptBeforeApplyingRemoteProgress(local_snapshot, remote_snapshot)
    if not self:hasMeaningfulProgress(remote_snapshot) then
        return false
    end
    if not self:hasMeaningfulProgress(local_snapshot) then
        return true
    end
    return self:progressDifferenceExceeded(local_snapshot, remote_snapshot)
end

function Grimmlink:buildStoredLocalSnapshot(state)
    if not state then
        return nil
    end
    return {
        progress = state.local_progress,
        location = state.local_location,
        percentage = state.local_percentage,
        currentPage = state.local_current_page,
        totalPages = state.local_total_pages,
        timestamp = state.local_timestamp,
        bookType = state.book_type,
        fileFormat = state.book_type,
        file_path = state.file_path,
    }
end

function Grimmlink:buildStoredRemoteSnapshot(state)
    if not state then
        return nil
    end
    return {
        progress = state.remote_progress,
        location = state.remote_location,
        percentage = state.remote_percentage,
        currentPage = state.remote_current_page,
        totalPages = state.remote_total_pages,
        timestamp = state.remote_timestamp,
        device = state.remote_device,
        deviceId = state.remote_device_id,
        source = state.remote_source,
        bookType = state.book_type,
        fileFormat = state.book_type,
        file_path = state.file_path,
    }
end

function Grimmlink:compareOpenProgress(local_snapshot, remote_snapshot, state)
    if not self:hasMeaningfulProgress(remote_snapshot) then
        return "none"
    end

    if not self:hasMeaningfulProgress(local_snapshot) then
        return "remote_newer"
    end

    if not state then
        if self:progressDifferenceExceeded(local_snapshot, remote_snapshot) then
            return "remote_newer"
        end
        return "same"
    end

    local previous_local = self:buildStoredLocalSnapshot(state)
    local previous_remote = self:buildStoredRemoteSnapshot(state)

    if not self:progressDifferenceExceeded(local_snapshot, remote_snapshot) then
        return "same"
    end

    local local_changed = previous_local and self:progressDifferenceExceeded(local_snapshot, previous_local) or false
    local remote_changed = previous_remote and self:progressDifferenceExceeded(remote_snapshot, previous_remote) or false

    if (not previous_local and not previous_remote) or (not local_snapshot.timestamp or not remote_snapshot.timestamp) then
        return "conflict"
    end

    if local_changed and remote_changed then
        return "conflict"
    end

    if remote_changed and not local_changed then
        return "remote_newer"
    end

    if local_changed and not remote_changed then
        return "local_newer"
    end

    if (remote_snapshot.timestamp or 0) > (local_snapshot.timestamp or 0) then
        return "remote_newer"
    end

    return "local_newer"
end

function Grimmlink:rememberLocalSnapshot(file_hash, snapshot, action)
    if not self.db or not file_hash or not snapshot then
        return
    end

    self.db:upsertLocalProgressState(file_hash, {
        file_path = snapshot.file_path,
        book_id = snapshot.bookId,
        document = snapshot.document,
        book_type = snapshot.bookType or snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        current_page = snapshot.currentPage,
        total_pages = snapshot.totalPages,
        timestamp = snapshot.timestamp,
        last_action = action,
    })
end

function Grimmlink:rememberRemoteSnapshot(file_hash, snapshot, action)
    if not self.db or not file_hash or not snapshot then
        return
    end

    self.db:upsertRemoteProgressState(file_hash, {
        file_path = snapshot.file_path,
        book_id = snapshot.bookId,
        document = snapshot.document,
        book_type = snapshot.bookType or snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        current_page = snapshot.currentPage,
        total_pages = snapshot.totalPages,
        device = snapshot.device,
        device_id = snapshot.deviceId or snapshot.device_id,
        source = snapshot.source,
        timestamp = snapshot.timestamp,
        last_action = action,
    })
end

function Grimmlink:getRemotePageTarget(remote_snapshot)
    if not remote_snapshot then
        return nil
    end
    if remote_snapshot.currentPage then
        return tonumber(remote_snapshot.currentPage)
    end
    local numeric_progress = isNonEmpty(remote_snapshot.progress) and tonumber(remote_snapshot.progress) or nil
    if numeric_progress then
        return numeric_progress
    end
    local numeric_location = isNonEmpty(remote_snapshot.location) and tonumber(remote_snapshot.location) or nil
    if numeric_location then
        return numeric_location
    end
    return nil
end

function Grimmlink:jumpToPage(page_number)
    local page = tonumber(page_number)
    if not page then
        return false
    end

    local function pageReached(expected_page)
        local current_page = select(1, self:getCurrentPageInfo())
        if current_page == nil then
            return false
        end
        return math.abs((tonumber(current_page) or 0) - expected_page) <= 1
    end

    if pageReached(page) then
        return true
    end

    local candidates = {
        { self.ui and self.ui.paging, "onGotoPage" },
        { self.ui and self.ui.paging, "gotoPage" },
        { self.ui and self.ui.paging, "goToPage" },
        { self.ui, "onGotoPage" },
        { self.ui and self.ui.document, "gotoPage" },
        { self.ui and self.ui.document, "goToPage" },
        { self.ui and self.ui.rolling, "gotoPage" },
        { self.ui and self.ui.rolling, "goToPage" },
    }

    local page_values = { page }
    if page > 1 then
        page_values[#page_values + 1] = page - 1
    end

    for _, target_page in ipairs(page_values) do
        safeMethodCall(self.ui and self.ui.link, "addCurrentLocationToStack")
        local event_result, event_ok = safeDispatchEvent(self.ui, "GotoPage", target_page)
        if event_ok and event_result ~= false and pageReached(page) then
            return true
        end

        for _, candidate in ipairs(candidates) do
            local result, ok = safeMethodCall(candidate[1], candidate[2], target_page)
            if ok and result ~= false and pageReached(page) then
                return true
            end
        end
    end

    return false
end

function Grimmlink:jumpToLocation(location, opts)
    opts = opts or {}
    if location == nil or tostring(location) == "" then
        return false
    end

    local numeric_page = nil
    if opts.allow_numeric_page ~= false then
        numeric_page = tonumber(location)
    end
    if numeric_page then
        return self:jumpToPage(numeric_page)
    end

    safeMethodCall(self.ui and self.ui.link, "addCurrentLocationToStack")
    local event_result, event_ok = safeDispatchEvent(self.ui, "GotoXPointer", tostring(location))
    if event_ok and event_result ~= false then
        return true
    end

    local candidates = {
        { self.ui and self.ui.document, "gotoPos" },
        { self.ui and self.ui.document, "gotoPosition" },
        { self.ui and self.ui.document, "gotoXPointer" },
        { self.ui and self.ui.rolling, "gotoPos" },
        { self.ui and self.ui.rolling, "gotoPosition" },
        { self.ui and self.ui.rolling, "gotoXPointer" },
    }

    for _, candidate in ipairs(candidates) do
        local result, ok = safeMethodCall(candidate[1], candidate[2], tostring(location))
        if ok and result ~= false then
            return true
        end
    end

    return false
end

function Grimmlink:documentHasPages()
    local document_info = self.ui and self.ui.document and self.ui.document.info
    if document_info and document_info.has_pages ~= nil then
        return document_info.has_pages and true or false
    end
    return self.ui and self.ui.paging ~= nil or false
end

function Grimmlink:applyRemoteProgress(remote_snapshot, opts)
    opts = opts or {}
    if not remote_snapshot then
        return false
    end

    self._last_progress_apply_error = nil
    local file_format = remote_snapshot.fileFormat and tostring(remote_snapshot.fileFormat):upper() or nil
    local book_type = remote_snapshot.bookType or file_format
    local is_reflowable = self:isReflowableFormat(remote_snapshot.file_path, book_type, file_format)

    if is_reflowable then
        local location_value = isNonEmpty(remote_snapshot.location) and tostring(remote_snapshot.location) or nil
        local progress_value = isNonEmpty(remote_snapshot.progress) and tostring(remote_snapshot.progress) or nil
        local location_is_native = location_value and not isNumericOnlyToken(location_value)
        local progress_is_native = progress_value and not isNumericOnlyToken(progress_value)
        local native_location = location_is_native and location_value
            or (progress_is_native and progress_value or nil)
        if not isNonEmpty(native_location) then
            self._last_progress_apply_error = _("No KOReader-native location available for this book.")
            return false
        end
        if self:jumpToLocation(native_location, { allow_numeric_page = false }) then
            return true
        end
        return false
    end

    local target_page = self:getRemotePageTarget(remote_snapshot)
    local prefer_page = opts.prefer_page == true or file_format == "PDF"

    if prefer_page and target_page and self:jumpToPage(target_page) then
        return true
    end

    if isNonEmpty(remote_snapshot.location) and self:jumpToLocation(remote_snapshot.location) then
        return true
    end

    if remote_snapshot.currentPage and self:jumpToPage(remote_snapshot.currentPage) then
        return true
    end

    local _, total_pages = self:getCurrentPageInfo()
    if remote_snapshot.percentage and total_pages and total_pages > 0 then
        local page = math.max(1, math.floor((total_pages * remote_snapshot.percentage / 100) + 0.5))
        if self:jumpToPage(page) then
            return true
        end
    end

    return false
end

function Grimmlink:progressLabel(snapshot)
    if not snapshot then
        return _("unknown")
    end
    local percent = snapshot.percentage and string.format("%.1f%%", snapshot.percentage) or _("unknown")
    local page = snapshot.currentPage and snapshot.totalPages and string.format("%s / %s", snapshot.currentPage, snapshot.totalPages) or _("unknown")
    return T(_("%1, page %2"), percent, page)
end

function Grimmlink:sourceLabel(snapshot, mode)
    if mode == "pdf" then
        return _("Grimmory Web Reader")
    end
    if snapshot and isNonEmpty(snapshot.source) then
        return snapshot.source
    end
    if snapshot and isNonEmpty(snapshot.device) then
        return snapshot.device
    end
    return _("KOReader")
end

function Grimmlink:buildConflictDialogText(local_snapshot, remote_snapshot, mode)
    local local_percent = local_snapshot.percentage and string.format("%.1f%%", local_snapshot.percentage) or _("unknown")
    local remote_percent = remote_snapshot.percentage and string.format("%.1f%%", remote_snapshot.percentage) or _("unknown")
    local local_page = local_snapshot.currentPage and local_snapshot.totalPages
        and string.format("%s / %s", local_snapshot.currentPage, local_snapshot.totalPages)
        or _("unknown")
    local remote_page = remote_snapshot.currentPage and remote_snapshot.totalPages
        and string.format("%s / %s", remote_snapshot.currentPage, remote_snapshot.totalPages)
        or _("unknown")
    local remote_heading = mode == "pdf" and _("Web Reader:") or _("Remote:")
    local title = mode == "pdf"
        and _("Found newer Web Reader page")
        or _("Found different reading positions")

    return table.concat({
        title,
        "",
        _("Local:"),
        T(_("- progress: %1"), local_percent),
        T(_("- page: %1"), local_page),
        T(_("- updated: %1"), formatTimestamp(local_snapshot.timestamp)),
        T(_("- device: %1"), local_snapshot.device or _("unknown")),
        "",
        remote_heading,
        T(_("- progress: %1"), remote_percent),
        T(_("- page: %1"), remote_page),
        T(_("- updated: %1"), formatTimestamp(remote_snapshot.timestamp)),
        T(_("- source: %1"), self:sourceLabel(remote_snapshot, mode)),
    }, "\n")
end

function Grimmlink:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, mode)
    local dialog
    local use_remote_text = mode == "pdf" and _("Use Web Reader page") or _("Use Remote")
    local keep_local_text = mode == "pdf" and _("Keep KOReader position") or _("Keep Local")
    local remote_action = function()
        if dialog then
            UIManager:close(dialog)
        end
        if self:applyRemoteProgress(remote_snapshot, { prefer_page = mode == "pdf" }) then
            self:rememberRemoteSnapshot(file_hash, remote_snapshot, mode == "pdf" and "pdf-remote-use" or "remote-use")
            self:rememberLocalSnapshot(file_hash, remote_snapshot, mode == "pdf" and "pdf-remote-use" or "remote-use")
        else
            local message = self._last_progress_apply_error or _("Failed to jump to remote position")
            self._last_progress_apply_error = nil
            self:showMessage(message, 4)
        end
    end
    local local_action = function()
        if dialog then
            UIManager:close(dialog)
        end
        self:rememberLocalSnapshot(file_hash, local_snapshot, mode == "pdf" and "pdf-keep-local" or "keep-local")
    end
    local ignore_action = function()
        if dialog then
            UIManager:close(dialog)
        end
    end

    dialog = ButtonDialog:new{
        title = self:buildConflictDialogText(local_snapshot, remote_snapshot, mode),
        buttons = {
            {
                {
                    text = keep_local_text,
                    callback = local_action,
                },
                {
                    text = use_remote_text,
                    callback = remote_action,
                },
                {
                    text = _("Ignore this time"),
                    callback = ignore_action,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

function Grimmlink:classifyApiOutcome(code, response)
    if code == 404 then
        return "http_404", "permanent_not_found"
    end
    if code == 400 or code == 415 or code == 422 then
        return "http_" .. tostring(code), "permanent_invalid"
    end
    if code and code >= 500 then
        return "http_" .. tostring(code), "transient_http"
    end
    local response_text = safeToString(response):lower()
    if response_text:find("unsupported_format", 1, true) then
        return "http_415", "permanent_invalid"
    end
    if response_text:find("not found", 1, true) then
        return "http_404", "permanent_not_found"
    end
    return "unknown", "transient_unknown"
end

function Grimmlink:prepareNativeProgressPayload(snapshot)
    local payload = {
        document = snapshot.document,
        bookHash = snapshot.bookHash,
        bookId = snapshot.bookId,
        bookFileId = snapshot.bookFileId,
        fileFormat = snapshot.fileFormat,
        progress = snapshot.progress,
        location = snapshot.location,
        percentage = snapshot.percentage,
        currentPage = snapshot.currentPage,
        totalPages = snapshot.totalPages,
        device = snapshot.device,
        deviceId = snapshot.deviceId,
        timestamp = snapshot.timestamp,
    }
    self:applyFormatProgressPolicy(payload)
    return {
        document = payload.document,
        bookHash = payload.bookHash,
        bookId = payload.bookId,
        bookFileId = payload.bookFileId,
        fileFormat = payload.fileFormat,
        progress = payload.progress,
        location = payload.location,
        percentage = payload.percentage,
        currentPage = payload.currentPage,
        totalPages = payload.totalPages,
        device = payload.device,
        deviceId = payload.deviceId,
        timestamp = payload.timestamp,
    }
end

function Grimmlink:preparePdfBridgePayload(snapshot, opts)
    opts = opts or {}
    local payload = {
        bookHash = snapshot.bookHash,
        bookFileId = snapshot.bookFileId,
        fileFormat = "PDF",
        currentPage = snapshot.currentPage,
        totalPages = snapshot.totalPages,
        percentage = snapshot.percentage,
        rawKoreaderLocation = snapshot.location,
        rawKoreaderProgress = snapshot.progress,
        source = "KOReader",
        device = snapshot.device,
        deviceId = snapshot.deviceId,
        timestamp = snapshot.timestamp,
    }
    if opts.expectedUpdatedAt then
        payload.expectedUpdatedAt = opts.expectedUpdatedAt
    end
    if opts.force ~= nil then
        payload.force = opts.force
    end
    return payload
end


function Grimmlink:queueProgressSnapshot(snapshot, kind, payload)
    if not self.db or not self.offline_queue_enabled or not snapshot or not snapshot.bookHash then
        return false
    end

    local encoded = payload
    if type(encoded) ~= "string" then
        local ok, json_payload = pcall(json.encode, payload or self:prepareNativeProgressPayload(snapshot))
        if not ok then
            self:logErr("GrimmLink failed to encode pending progress payload")
            return false
        end
        encoded = json_payload
    end
    self.db:upsertPendingProgress(snapshot.bookHash, encoded, kind or "native")
    return true
end

function Grimmlink:pushProgressSnapshot(snapshot, reason, silent)
    if not snapshot or not snapshot.bookHash then
        return false
    end
    if not self:isTrackingEnabled(snapshot.bookHash, snapshot.file_path) then
        if not silent then
            self:showTrackingDisabledMessage()
        end
        return false
    end

    if not self:isApiReady({ "updateProgress" }) then
        self:queueProgressSnapshot(snapshot, "native", self:prepareNativeProgressPayload(snapshot))
        return false
    end
    if not self:refreshApiClient() then
        return false
    end
    if not self:isOnline() then
        self:queueProgressSnapshot(snapshot, "native", self:prepareNativeProgressPayload(snapshot))
        if not silent then
            self:showMessage(_("Saved progress to offline queue"), 2)
        end
        return false
    end

    local payload = self:prepareNativeProgressPayload(snapshot)
    local success, response, code = self.api:updateProgress(payload)
    if success then
        self:rememberLocalSnapshot(snapshot.bookHash, snapshot, reason or "progress-push")
        self:rememberRemoteSnapshot(snapshot.bookHash, snapshot, reason or "progress-push")
        if self.db and type(self.db.setProgressLastAction) == "function" then
            self.db:setProgressLastAction(snapshot.bookHash, reason or "progress-push")
        end
        return true
    end

    local _, api_error_class = self:classifyApiOutcome(code, response)
    self:logWarn("GrimmLink progress push failed:", response)
    if api_error_class == "permanent_not_found" or api_error_class == "permanent_invalid" then
        if not silent then
            self:showMessage(T(_("Progress sync failed:\n%1"), safeToString(response)), 4)
        end
        return false
    end

    self:queueProgressSnapshot(snapshot, "native", payload)
    if not silent then
        self:showMessage(T(_("Progress sync failed:\n%1"), safeToString(response)), 4)
    end
    return false
end

function Grimmlink:pushPdfWebProgress(snapshot, reason, silent)
    if not snapshot or not snapshot.bookHash or not snapshot.bookId then
        return false
    end
    if not self:isTrackingEnabled(snapshot.bookHash, snapshot.file_path) then
        if not silent then
            self:showTrackingDisabledMessage()
        end
        return false
    end
    if not self:isPdfWebReaderBridgeEnabled() then
        return false
    end
    if snapshot.fileFormat ~= "PDF" then
        return false
    end

    if not self:isApiReady({ "updatePdfProgress" }) then
        self:queueProgressSnapshot(snapshot, "pdf_bridge", {
            bookId = snapshot.bookId,
            bookHash = snapshot.bookHash,
            request = self:preparePdfBridgePayload(snapshot, {
                force = reason == "manual" or reason == "close",
            }),
        })
        return false
    end
    if not self:refreshApiClient() then
        return false
    end
    local payload = self:preparePdfBridgePayload(snapshot, {
        force = reason == "manual" or reason == "close",
    })

    if not self:isOnline() then
        self:queueProgressSnapshot(snapshot, "pdf_bridge", {
            bookId = snapshot.bookId,
            bookHash = snapshot.bookHash,
            request = payload,
        })
        if not silent then
            self:showMessage(_("Saved PDF bridge progress to offline queue"), 2)
        end
        return false
    end

    local success, response, code = self.api:updatePdfProgress(snapshot.bookId, payload)
    if success then
        local normalized = self:normalizeRemoteProgress(response or payload)
        normalized.source = "WEB_READER"
        self:rememberRemoteSnapshot(snapshot.bookHash, normalized, reason or "pdf-bridge-push")
        return true
    end

    local _, api_error_class = self:classifyApiOutcome(code, response)
    self:logWarn("GrimmLink PDF bridge push failed:", response)
    if api_error_class ~= "permanent_not_found" and api_error_class ~= "permanent_invalid" then
        self:queueProgressSnapshot(snapshot, "pdf_bridge", payload)
    end
    if not silent then
        self:showMessage(T(_("PDF bridge sync failed:\n%1"), safeToString(response)), 4)
    end
    return false
end

function Grimmlink:syncPendingProgress(silent, limit)
    local synced = 0
    local failed = 0
    if not self.db then
        return synced, failed
    end
    if not self:isOnline() then
        return synced, failed
    end

    if not self:isApiReady({ "updateProgress", "updatePdfProgress" }) then
        return synced, failed
    end
    if not self:refreshApiClient() then
        return synced, failed
    end
    local pending = self.db:getPendingProgress(limit or 100)
    local now = nowUtc()

    local function retryDelaySeconds(retry_count)
        local count = tonumber(retry_count) or 0
        local delay = 30 * (2 ^ math.min(count, 5))
        if delay > 3600 then
            delay = 3600
        end
        return delay
    end

    for _, item in ipairs(pending) do
        if not self:isTrackingEnabled(item.file_hash, nil) then
            -- Keep queued rows for this book untouched while tracking is disabled.
        else
            local can_try = true
            if item.last_retry_at and (now - tonumber(item.last_retry_at)) < retryDelaySeconds(item.retry_count) then
                can_try = false
            end

            if can_try then
                local ok, payload = pcall(json.decode, item.payload_json)
                if not ok or type(payload) ~= "table" then
                    self.db:deletePendingProgress(item.id)
                    failed = failed + 1
                else
                    local success, response, code
                    if item.kind == "pdf_bridge" then
                        local request_payload = payload.request or payload
                        local book_id = payload.bookId or request_payload.bookId
                        if not book_id and (payload.bookHash or request_payload.bookHash) then
                            local matched = self:resolveBookByHash(nil, payload.bookHash or request_payload.bookHash, true)
                            book_id = matched and matched.book_id or nil
                        end
                        if book_id then
                            success, response, code = self.api:updatePdfProgress(book_id, request_payload)
                        else
                            success = false
                            response = "Book ID not resolved"
                            code = 400
                        end
                    else
                        success, response, code = self.api:updateProgress(payload)
                    end

                    if success then
                        self.db:deletePendingProgress(item.id)
                        synced = synced + 1
                        if item.kind == "pdf_bridge" then
                            local request_payload = payload.request or payload
                            local normalized = self:normalizeRemoteProgress(request_payload)
                            normalized.source = "WEB_READER"
                            self:rememberRemoteSnapshot(item.file_hash, normalized, "queued-pdf-bridge-pushed")
                        else
                            self:rememberLocalSnapshot(item.file_hash, {
                                file_path = payload.file_path,
                                bookId = payload.bookId,
                                document = payload.document,
                                bookType = payload.bookType or payload.fileFormat,
                                progress = payload.progress,
                                location = payload.location,
                                percentage = normalizePercent(payload.percentage),
                                currentPage = payload.currentPage,
                                totalPages = payload.totalPages,
                                timestamp = payload.timestamp or nowUtc(),
                            }, "queued-progress-pushed")
                            self:rememberRemoteSnapshot(item.file_hash, {
                                bookId = payload.bookId,
                                document = payload.document,
                                bookType = payload.bookType or payload.fileFormat,
                                progress = payload.progress,
                                location = payload.location,
                                percentage = normalizePercent(payload.percentage),
                                currentPage = payload.currentPage,
                                totalPages = payload.totalPages,
                                device = payload.device,
                                deviceId = payload.deviceId or payload.device_id,
                                timestamp = payload.timestamp or nowUtc(),
                            }, "queued-progress-pushed")
                        end
                    else
                        local _, api_error_class = self:classifyApiOutcome(code, response)
                        if api_error_class == "permanent_not_found" or api_error_class == "permanent_invalid" then
                            self.db:deletePendingProgress(item.id)
                        else
                            self.db:incrementPendingProgressRetry(item.id)
                        end
                        failed = failed + 1
                    end
                end
            end
        end
    end

    if not silent and (synced > 0 or failed > 0) then
        self:showMessage(T(_("Pending progress sync\nSynced: %1\nFailed: %2"), synced, failed), 3)
    end
    return synced, failed
end

function Grimmlink:resolveBookByHash(file_path, file_hash, silent)
    if not file_hash then
        return nil
    end

    local cached = self.db and self.db:getBookByHash(file_hash) or nil
    if cached and cached.book_id then
        return cached
    end

    if not self:isOnline() then
        if self.db and file_path and file_path ~= "" then
            self.db:saveBookCache(file_path, file_hash, nil, sanitizeTitle(file_path), nil)
        end
        return cached
    end

    if not self:isApiReady({ "getBookByHash" }) or not self:refreshApiClient() then
        return cached
    end
    local success, book, code = self.api:getBookByHash(file_hash)
    if success and book and book.id then
        if self.db then
            self.db:saveBookCache(file_path or sanitizeTitle(file_hash), file_hash, tonumber(book.id), book.title, book.author)
        end
        return {
            file_path = file_path,
            file_hash = file_hash,
            book_id = tonumber(book.id),
            bookFileId = maybeNumber(book.bookFileId or book.book_file_id),
            title = book.title,
            author = book.author,
        }
    end

    if self.db and file_path and file_path ~= "" then
        self.db:saveBookCache(file_path, file_hash, nil, sanitizeTitle(file_path), nil)
    end
    if not silent then
        self:showMessage(_("No Grimmory match found for this book hash"), 4)
    end
    return nil
end

function Grimmlink:resolveBookByFilePath(file_path)
    if not self.db or not file_path or file_path == "" then
        return nil
    end

    local cached = self.db:getBookByFilePath(file_path)
    if cached and cached.book_id then
        return cached
    end

    local shelf_entry = self.db:getShelfSyncEntryByLocalPath(file_path)
    if shelf_entry and shelf_entry.book_id then
        self.db:saveBookCache(
            file_path,
            cached and cached.file_hash or "",
            shelf_entry.book_id,
            shelf_entry.remote_title or sanitizeTitle(file_path),
            shelf_entry.remote_author
        )
        return {
            file_path = file_path,
            file_hash = cached and cached.file_hash or nil,
            book_id = tonumber(shelf_entry.book_id),
            title = shelf_entry.remote_title,
            author = shelf_entry.remote_author,
        }
    end

    return cached
end

function Grimmlink:shouldPushProgress(current_snapshot, state, reason)
    if reason == "manual" or reason == "close" or reason == "suspend" then
        return true
    end

    if not state then
        return self:hasMeaningfulProgress(current_snapshot)
    end

    local previous_local = self:buildStoredLocalSnapshot(state)
    if not previous_local then
        return self:hasMeaningfulProgress(current_snapshot)
    end

    if self:progressDifferenceExceeded(current_snapshot, previous_local) then
        return true
    end

    local minutes_threshold = tonumber(self.threshold_minutes) or DEFAULTS.threshold_minutes
    if state.local_timestamp and current_snapshot.timestamp then
        if (current_snapshot.timestamp - state.local_timestamp) >= (minutes_threshold * 60) then
            return true
        end
    end

    return false
end


function Grimmlink:maybePullRemoteProgress(file_hash, file_path, book_id, book_file_id, silent)
    if not self.db or not self.auto_pull_on_open or not file_hash or file_hash == "" or not book_id then
        return
    end
    if not self:isTrackingEnabled(file_hash, file_path) then
        return
    end
    if not self:isOnline() then
        return
    end

    if not self:isApiReady({ "getProgress" }) or not self:refreshApiClient() then
        return
    end
    local state = self.db:getProgressState(file_hash)
    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local comparison_local = cloneTable(local_snapshot)
    if state and state.local_timestamp then
        comparison_local.timestamp = state.local_timestamp
    end

    local success, remote, code = self.api:getProgress(file_hash)
    if not success then
        local _, api_error_class = self:classifyApiOutcome(code, remote)
        if not silent and api_error_class ~= "permanent_not_found" then
            self:showMessage(T(_("Remote progress fetch failed:\n%1"), safeToString(remote)), 4)
        end
        self:rememberLocalSnapshot(file_hash, local_snapshot, "open-local")
        return
    end

    local remote_snapshot = self:normalizeRemoteProgress(remote)
    if remote_snapshot then
        remote_snapshot.bookHash = file_hash
        remote_snapshot.bookId = remote_snapshot.bookId or book_id
        remote_snapshot.bookFileId = remote_snapshot.bookFileId or book_file_id
        remote_snapshot.fileFormat = remote_snapshot.fileFormat or self:getBookType(file_path)
        remote_snapshot.bookType = remote_snapshot.bookType or remote_snapshot.fileFormat
        remote_snapshot.document = remote_snapshot.document or file_hash
        remote_snapshot.file_path = file_path
        remote_snapshot.source = remote_snapshot.source or remote_snapshot.device or "KOReader"
        self:applyFormatProgressPolicy(remote_snapshot)
    end

    self:rememberLocalSnapshot(file_hash, local_snapshot, "open-local")
    self:rememberRemoteSnapshot(file_hash, remote_snapshot, "open-remote")

    local decision = self:compareOpenProgress(comparison_local, remote_snapshot, state)
    if decision == "remote_newer" or decision == "conflict" then
        self:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, "native")
    elseif decision == "local_newer" or decision == "same" then
        return
    end
end

function Grimmlink:manualPullProgress()
    if not self.current_session then
        self:showMessage(_("No book currently open"), 3)
        return
    end
    if not self:isOnline() then
        self:showMessage(_("Not connected to server"), 3)
        return
    end
    if not self:isApiReady({ "getProgress" }) or not self:refreshApiClient() then
        return
    end

    local file_hash    = self.current_session.file_hash
    local file_path    = self.current_session.file_path
    local book_id      = self.current_session.book_id
    local book_file_id = self.current_session.book_file_id

    if not self:isTrackingEnabled(file_hash, file_path) then
        self:showTrackingDisabledMessage()
        return
    end

    if not file_hash or not book_id then
        self:showMessage(_("Book not registered on server"), 3)
        return
    end

    self:showMessage(_("Fetching remote progress…"), 2)

    local success, remote, code = self.api:getProgress(file_hash)
    if not success then
        local _, api_error_class = self:classifyApiOutcome(code, remote)
        if api_error_class == "permanent_not_found" then
            self:showMessage(_("No remote progress found for this book"), 3)
        else
            self:showMessage(T(_("Fetch failed:\n%1"), safeToString(remote)), 4)
        end
        return
    end

    local remote_snapshot = self:normalizeRemoteProgress(remote)
    if not remote_snapshot then
        self:showMessage(_("No remote progress found for this book"), 3)
        return
    end

    remote_snapshot.bookHash    = file_hash
    remote_snapshot.bookId      = remote_snapshot.bookId      or book_id
    remote_snapshot.bookFileId  = remote_snapshot.bookFileId  or book_file_id
    remote_snapshot.fileFormat  = remote_snapshot.fileFormat  or self:getBookType(file_path)
    remote_snapshot.bookType    = remote_snapshot.bookType    or remote_snapshot.fileFormat
    remote_snapshot.document    = remote_snapshot.document    or file_hash
    remote_snapshot.file_path   = file_path
    remote_snapshot.source      = remote_snapshot.source or remote_snapshot.device or "KOReader"
    self:applyFormatProgressPolicy(remote_snapshot)

    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)

    self:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, "native")
end

function Grimmlink:maybePullPdfWebProgress(file_hash, file_path, book_id, book_file_id, silent)
    if not self.db or not self:isPdfWebReaderBridgeEnabled() or not file_hash or file_hash == "" or not book_id then
        return
    end
    if not self:isTrackingEnabled(file_hash, file_path) then
        return
    end
    local normalized_book_id = maybeNumber(book_id) or book_id
    if not normalized_book_id then
        return
    end
    if self:getBookType(file_path) ~= "PDF" then
        return
    end
    if not self:isOnline() then
        return
    end

    if not self:isApiReady({ "getPdfProgress" }) or not self:refreshApiClient() then
        return
    end
    local state = self.db:getProgressState(file_hash)
    local local_snapshot = self:getCurrentProgressSnapshot(file_hash, file_path, book_id, book_file_id)
    local success, remote, code = self.api:getPdfProgress(normalized_book_id)
    if not success then
        local _, api_error_class = self:classifyApiOutcome(code, remote)
        if not silent and api_error_class ~= "permanent_not_found" then
            self:showMessage(T(_("PDF bridge fetch failed:\n%1"), safeToString(remote)), 4)
        end
        return
    end

    local remote_snapshot = self:normalizeRemoteProgress(remote)
    if remote_snapshot then
        remote_snapshot.bookHash = file_hash
        remote_snapshot.bookId = normalized_book_id
        remote_snapshot.bookFileId = remote_snapshot.bookFileId or book_file_id
        remote_snapshot.fileFormat = "PDF"
        remote_snapshot.document = remote_snapshot.document or file_hash
        remote_snapshot.file_path = file_path
        remote_snapshot.source = remote_snapshot.source or "WEB_READER"
    end

    local decision = self:compareOpenProgress(local_snapshot, remote_snapshot, state)
    if decision == "remote_newer" or decision == "conflict" then
        self:showProgressConflictDialog(file_hash, local_snapshot, remote_snapshot, "pdf")
    end
end


function Grimmlink:isPdfWebReaderBridgeEnabled()
    return self.enabled == true and self.pdf_web_reader_bridge_enabled == true
end

function Grimmlink:syncPdfWebProgress(silent)
    if not self:isPdfWebReaderBridgeEnabled() or not self.current_session then
        return false
    end

    local snapshot = self:getCurrentProgressSnapshot(
        self.current_session.file_hash,
        self.current_session.file_path,
        self.current_session.book_id,
        self.current_session.book_file_id
    )
    if snapshot and snapshot.fileFormat == "PDF" then
        return self:pushPdfWebProgress(snapshot, "manual", silent)
    end
    return false
end

function Grimmlink:resolveCurrentDocumentBookId(preferred_book_id)
    if preferred_book_id then
        return maybeNumber(preferred_book_id) or preferred_book_id
    end
    if self.current_session and self.current_session.book_id then
        return maybeNumber(self.current_session.book_id) or self.current_session.book_id
    end
    if self.ui and self.ui.document and self.ui.document.file then
        local cached = self:resolveBookByFilePath(tostring(self.ui.document.file))
        if cached and cached.book_id then
            return maybeNumber(cached.book_id) or cached.book_id
        end
    end
    return nil
end

function Grimmlink:pushPdfWebProgressForCurrentDocument(reason, silent)
    if not self.current_session then
        return false
    end
    local snapshot = self:getCurrentProgressSnapshot(
        self.current_session.file_hash,
        self.current_session.file_path,
        self.current_session.book_id,
        self.current_session.book_file_id
    )
    if not snapshot or snapshot.fileFormat ~= "PDF" then
        return false
    end
    return self:pushPdfWebProgress(snapshot, reason or "manual", silent)
end

end

return M
