local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local MetadataExtractor = deps.MetadataExtractor
    local json = deps.json
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS
    local cloneTable = deps.cloneTable
    local maybeNumber = deps.maybeNumber
    local normalizeMetadataRatingPayload = deps.normalizeMetadataRatingPayload
    local nowUtc = deps.nowUtc
    local parseIsoOrNil = deps.parseIsoOrNil
    local safeDbBoolCall = deps.safeDbBoolCall
    local safeDbValueCall = deps.safeDbValueCall
    local safeToString = deps.safeToString
    local shortPrefix = deps.shortPrefix
    local stableTextHash = deps.stableTextHash
    local READING_COMPLETION_RATING_STATE_KEY = deps.READING_COMPLETION_RATING_STATE_KEY or "grimmlink_rating_state"
    local buildReadingCompletionRatingState = deps.buildReadingCompletionRatingState
    local convertTenScaleRatingToSummaryRating = deps.convertTenScaleRatingToSummaryRating
    local tryReadSetting = deps.tryReadSetting
    local tryWriteSetting = deps.tryWriteSetting
    local tryFlushDocSettings = deps.tryFlushDocSettings
    local tryCloseDocSettings = deps.tryCloseDocSettings
    local lfs = deps.lfs

    local function cloneForMetadata(value)
        if type(cloneTable) == "function" then
            return cloneTable(value)
        end
        if type(value) ~= "table" then
            return value
        end
        local out = {}
        for k, v in pairs(value) do
            out[k] = v
        end
        return out
    end

function Grimmlink:getMetadataExtractionContext()
    local file_path = nil
    local file_hash = nil
    local book_id = nil
    local book_file_id = nil

    if self.current_session then
        file_path = self.current_session.file_path
        file_hash = self.current_session.file_hash
        book_id = self.current_session.book_id
        book_file_id = self.current_session.book_file_id
    elseif self.ui and self.ui.document and self.ui.document.file then
        file_path = tostring(self.ui.document.file)
    end

    if not file_path or file_path == "" then
        return nil
    end

    if (not file_hash or file_hash == "") and type(self.resolveBookByFilePath) == "function" then
        local ok_cached, cached = pcall(self.resolveBookByFilePath, self, file_path)
        if ok_cached and type(cached) == "table" then
            file_hash = cached.file_hash or file_hash
            book_id = book_id or cached.book_id
        end
    end

    if (not file_hash or file_hash == "") and type(self.calculateBookHash) == "function" then
        local ok_hash, computed_hash = pcall(self.calculateBookHash, self, file_path)
        if ok_hash then
            file_hash = computed_hash
        end
    end

    return {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
    }
end

function Grimmlink:extractMetadataForContext(context)
    local empty = {
        rating = nil,
        highlights = {},
        bookmarks = {},
        counts = {
            rating_present = false,
            highlights_count = 0,
            notes_count = 0,
            bookmarks_count = 0,
        },
    }
    if not context or type(context) ~= "table" then
        return empty
    end
    if not MetadataExtractor or type(MetadataExtractor.extract) ~= "function" then
        return empty
    end

    local ok, extracted = pcall(MetadataExtractor.extract, {
        file_path = context.file_path,
        doc_settings = self.ui and self.ui.doc_settings or nil,
    })
    if not ok or type(extracted) ~= "table" then
        return empty
    end

    extracted.highlights = type(extracted.highlights) == "table" and extracted.highlights or {}
    extracted.bookmarks = type(extracted.bookmarks) == "table" and extracted.bookmarks or {}
    extracted.counts = type(extracted.counts) == "table" and extracted.counts or {}
    extracted.counts.rating_present = extracted.rating ~= nil
    extracted.counts.highlights_count = tonumber(extracted.counts.highlights_count) or #extracted.highlights
    extracted.counts.notes_count = tonumber(extracted.counts.notes_count) or 0
    extracted.counts.bookmarks_count = tonumber(extracted.counts.bookmarks_count) or #extracted.bookmarks
    return extracted
end

function Grimmlink:buildMetadataDedupeKey(file_hash, item_type, payload)
    if not file_hash or file_hash == "" then
        return nil
    end

    if item_type == "rating" then
        local normalized_rating = normalizeMetadataRatingPayload(payload)
        if not normalized_rating then
            return nil
        end
        return table.concat({ file_hash, "rating", normalized_rating.normalized }, ":")
    end

    if item_type == "annotation" then
        local datetime = safeToString(payload and payload.datetime) or ""
        local pos0 = safeToString(payload and payload.pos0) or ""
        local text_hash = stableTextHash((payload and payload.text) or (payload and payload.note) or "")
        return table.concat({ file_hash, "annotation", datetime, pos0, text_hash }, ":")
    end

    if item_type == "bookmark" then
        local datetime = safeToString(payload and payload.datetime) or ""
        local anchor = safeToString(payload and (payload.pos0 or payload.page or payload.pageno or payload.location)) or ""
        return table.concat({ file_hash, "bookmark", datetime, anchor }, ":")
    end

    return nil
end

function Grimmlink:queueMetadataFromContext(context, extracted, reason)
    local result = {
        queued = 0,
        skipped_synced = 0,
        failed = 0,
        total = 0,
    }

    if not self.enabled or not self.db or type(context) ~= "table" then
        return result
    end
    if not context.file_hash or context.file_hash == "" then
        return result
    end

    local items = {}
    if extracted and type(extracted.rating) == "table" and extracted.rating.raw then
        items[#items + 1] = {
            item_type = "rating",
            payload = {
                rating = extracted.rating.value or extracted.rating.raw,
                ratingScale = extracted.rating.scale or 5,
                ratingNormalized = extracted.rating.normalized,
                ratingRaw = extracted.rating.raw,
                datetime = nowUtc(),
                source = reason,
            },
        }
    end

    for _, annotation in ipairs((extracted and extracted.highlights) or {}) do
        if type(annotation) == "table" then
            items[#items + 1] = {
                item_type = "annotation",
                payload = annotation,
            }
        end
    end

    for _, bookmark in ipairs((extracted and extracted.bookmarks) or {}) do
        if type(bookmark) == "table" then
            items[#items + 1] = {
                item_type = "bookmark",
                payload = bookmark,
            }
        end
    end

    result.total = #items
    for _, item in ipairs(items) do
        local dedupe_key = self:buildMetadataDedupeKey(context.file_hash, item.item_type, item.payload)
        if dedupe_key then
            local is_synced = safeDbBoolCall(self.db, "isMetadataItemSynced", context.file_hash, item.item_type, dedupe_key)
            if is_synced then
                result.skipped_synced = result.skipped_synced + 1
            else
                local payload_json = nil
                local ok_payload, encoded = pcall(json.encode, item.payload)
                if ok_payload and encoded ~= nil then
                    payload_json = encoded
                end
                if payload_json and safeDbBoolCall(self.db, "upsertPendingMetadataItem", {
                    file_hash = context.file_hash,
                    book_id = context.book_id,
                    book_file_id = context.book_file_id,
                    item_type = item.item_type,
                    dedupe_key = dedupe_key,
                    payload_json = payload_json,
                }) then
                    result.queued = result.queued + 1
                else
                    result.failed = result.failed + 1
                end
            end
        else
            result.failed = result.failed + 1
        end
    end

    return result
end

function Grimmlink:extractAndQueueCurrentMetadata(reason, context_override)
    if not self.enabled or not self.db then
        return nil
    end
    local context = context_override or self:getMetadataExtractionContext()
    if not context then
        return nil
    end
    if not self:isTrackingEnabledForContext(context) then
        return nil
    end
    local ok_extract, extracted = pcall(self.extractMetadataForContext, self, context)
    if not ok_extract then
        self:logWarn("GrimmLink metadata extract failed:", extracted)
        return nil
    end
    local ok_queue, queued = pcall(self.queueMetadataFromContext, self, context, extracted, reason or "metadata")
    if not ok_queue then
        self:logWarn("GrimmLink metadata queue failed:", queued)
        return nil
    end
    return {
        context = context,
        extracted = extracted,
        queued = queued,
    }
end

function Grimmlink:showMetadataPreview()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end

    local context = self:getMetadataExtractionContext()
    if not context then
        self:showMessage(_("No active document to preview metadata"), 3)
        return
    end

    local ok_extract, extracted = pcall(self.extractMetadataForContext, self, context)
    if not ok_extract or type(extracted) ~= "table" then
        self:showMessage(_("Failed to preview metadata"), 3)
        return
    end
    local rating_text = _("none")
    if extracted.rating and extracted.rating.raw then
        if tonumber(extracted.rating.scale) == 10 and tonumber(extracted.rating.value) then
            rating_text = T(_("%1/10 (KOReader %2/5)"), extracted.rating.value, extracted.rating.raw)
        else
            rating_text = T(_("%1/5 (normalized %2)"), extracted.rating.raw, extracted.rating.normalized or "-")
        end
    end

    local pending_count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    self:showMessage(T(
        _("Metadata Preview\nRating: %1\nHighlights: %2\nNotes: %3\nBookmarks: %4\nPending metadata: %5"),
        rating_text,
        extracted.counts and extracted.counts.highlights_count or 0,
        extracted.counts and extracted.counts.notes_count or 0,
        extracted.counts and extracted.counts.bookmarks_count or 0,
        pending_count
    ), 5)
end

function Grimmlink:buildMetadataRatingPayload(row, payload)
    local rating_payload = normalizeMetadataRatingPayload(payload)
    if not rating_payload then
        return nil
    end
    return {
        dedupeKey = row.dedupe_key,
        value = rating_payload.value,
        scale = rating_payload.scale,
        source = "koreader",
        updatedAt = parseIsoOrNil(payload and payload.datetime),
    }
end

function Grimmlink:buildMetadataAnnotationPayload(row, payload)
    payload = payload or {}
    return {
        dedupeKey = row.dedupe_key,
        type = "highlight",
        text = payload.text,
        note = payload.note,
        color = payload.color,
        drawer = payload.drawer,
        style = payload.style,
        chapter = payload.chapter,
        page = tonumber(payload.page) or tonumber(payload.pageno),
        location = {
            kind = "koreader",
            pos0 = payload.pos0,
            pos1 = payload.pos1,
            pageno = tonumber(payload.pageno),
            raw = payload.location,
        },
        createdAt = parseIsoOrNil(payload.datetime),
        updatedAt = parseIsoOrNil(payload.datetime),
    }
end

function Grimmlink:buildMetadataBookmarkPayload(row, payload)
    payload = payload or {}
    local bookmark_title = payload.title or payload.text
    return {
        dedupeKey = row.dedupe_key,
        title = bookmark_title,
        notes = payload.notes or payload.note,
        chapter = payload.chapter,
        page = tonumber(payload.page) or tonumber(payload.pageno),
        location = {
            kind = "koreader",
            pos0 = payload.pos0,
            pos1 = payload.pos1,
            pageno = tonumber(payload.pageno),
            raw = payload.location,
        },
        createdAt = parseIsoOrNil(payload.datetime),
        updatedAt = parseIsoOrNil(payload.datetime),
    }
end

function Grimmlink:markMetadataRowSynced(row, server_id)
    safeDbBoolCall(self.db, "markMetadataItemSynced", {
        file_hash = row.file_hash,
        book_id = row.book_id,
        item_type = row.item_type,
        dedupe_key = row.dedupe_key,
        server_id = server_id,
    })
    safeDbBoolCall(self.db, "deletePendingMetadataItem", row.id)
end

function Grimmlink:metadataCursorKey(file_hash, book_id, book_file_id)
    local identity = safeToString(file_hash)
    if identity == "" then
        identity = "book:" .. safeToString(book_id)
    end
    if identity == "book:" then
        identity = "book_file:" .. safeToString(book_file_id)
    end
    if identity == "book_file:" then
        return nil
    end
    return "metadata_cursor:" .. identity
end

local function normalizeMetadataCursor(cursor)
    if type(cursor) ~= "string" then
        return nil
    end
    local text = cursor:match("^%s*(.-)%s*$")
    if text == "" then
        return nil
    end
    if text:match("^function:") then
        return nil
    end
    if text:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d+Z$")
        or text:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
        or text:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d+[+-]%d%d:%d%d$")
        or text:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[+-]%d%d:%d%d$") then
        return text
    end
    return nil
end

local function clearMetadataCursorSetting(db, key)
    if type(key) ~= "string" or key == "" then
        return false
    end
    if db and type(db.deletePluginSetting) == "function" then
        return safeDbBoolCall(db, "deletePluginSetting", key)
    end
    return safeDbBoolCall(db, "savePluginSetting", key, "")
end

function Grimmlink:getMetadataCursor(file_hash, book_id, book_file_id)
    local key = self:metadataCursorKey(file_hash, book_id, book_file_id)
    if not key then
        return nil
    end
    local cursor = safeDbValueCall(self.db, "getPluginSetting", nil, key)
    local normalized = normalizeMetadataCursor(cursor)
    if normalized then
        return normalized
    end
    if cursor ~= nil and cursor ~= "" then
        clearMetadataCursorSetting(self.db, key)
    end
    return nil
end

function Grimmlink:saveMetadataCursor(file_hash, book_id, book_file_id, cursor)
    local normalized = normalizeMetadataCursor(cursor)
    if not normalized then
        return false
    end
    local key = self:metadataCursorKey(file_hash, book_id, book_file_id)
    if not key then
        return false
    end
    return safeDbBoolCall(self.db, "savePluginSetting", key, normalized)
end

local function normalizeRemoteMetadataType(value)
    local text = safeToString(value)
    if not text or text == "" then
        return nil
    end
    text = text:lower()
    if text == "rating" or text == "annotation" or text == "bookmark" then
        return text
    end
    return nil
end

local function remoteItemDedupeKey(item)
    if type(item) ~= "table" then
        return nil
    end
    return safeToString(item.dedupeKey or item.dedupe_key or item.dedupe or item.id)
end

local function remoteItemPayload(item)
    if type(item) ~= "table" then
        return nil
    end
    if type(item.payload) == "table" then
        return item.payload
    end
    local payload_json = item.payloadJson or item.payload_json
    if type(payload_json) == "string" and payload_json ~= "" and json and type(json.decode) == "function" then
        local ok, decoded = pcall(json.decode, payload_json)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end
    return nil
end

local function remoteItemDeviceId(item)
    if type(item) ~= "table" then
        return nil
    end
    return safeToString(item.deviceId or item.device_id or item.sourceDeviceId or item.source_device_id)
end

local function firstNonEmpty(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        local text = safeToString(value)
        if text and text ~= "" then
            return text
        end
    end
    return nil
end

local function firstNumber(...)
    for i = 1, select("#", ...) do
        local value = tonumber(select(i, ...))
        if value then
            return value
        end
    end
    return nil
end

local function payloadLocation(payload)
    if type(payload) ~= "table" then
        return {}
    end
    if type(payload.location) == "table" then
        return payload.location
    end
    return {}
end

local function normalizeRemoteRatingPayload(payload)
    if type(payload) ~= "table" then
        return nil
    end

    -- Defensive compatibility: the first backend island draft stored the whole
    -- batch request for rating rows. Prefer the nested rating object when seen.
    if type(payload.rating) == "table" then
        payload = payload.rating
    end

    local value = tonumber(payload.value or payload.ratingNormalized or payload.normalized or payload.rating or payload.ratingRaw)
    if not value then
        return nil
    end
    value = math.floor(value + 0.5)

    local scale = tonumber(payload.scale or payload.ratingScale)
    if not scale then
        if payload.ratingNormalized or payload.normalized or payload.value then
            scale = 10
        else
            scale = 5
        end
    end
    scale = math.floor(scale + 0.5)

    local ten_scale = nil
    local summary_rating = nil
    if scale == 10 then
        if value < 1 or value > 10 then
            return nil
        end
        ten_scale = value
        summary_rating = type(convertTenScaleRatingToSummaryRating) == "function"
            and convertTenScaleRatingToSummaryRating(ten_scale)
            or math.ceil(ten_scale / 2)
    elseif scale == 5 then
        if value < 1 or value > 5 then
            return nil
        end
        summary_rating = value
        ten_scale = math.max(1, math.min(10, value * 2))
    else
        return nil
    end

    if not summary_rating or summary_rating < 1 or summary_rating > 5 then
        return nil
    end
    return {
        value = ten_scale,
        scale = 10,
        summary_rating = summary_rating,
    }
end

local function annotationListHasRemoteDedupe(annotations, dedupe_key)
    if type(annotations) ~= "table" or not dedupe_key or dedupe_key == "" then
        return false
    end
    for _, entry in pairs(annotations) do
        if type(entry) == "table" then
            local existing = entry.grimmlink_dedupe_key or entry.dedupeKey or entry.dedupe_key
            if existing ~= nil and safeToString(existing) == dedupe_key then
                return true
            end
        end
    end
    return false
end

function Grimmlink:getMetadataFilePathForIdentity(file_hash, book_id)
    local current = self:getMetadataExtractionContext()
    if current and current.file_path and current.file_path ~= "" then
        if (file_hash and current.file_hash == file_hash) or (book_id and tostring(current.book_id or "") == tostring(book_id)) then
            return current.file_path
        end
    end
    if self.db then
        if file_hash and file_hash ~= "" and type(self.db.getBookByHash) == "function" then
            local cached = safeDbValueCall(self.db, "getBookByHash", nil, file_hash)
            if type(cached) == "table" and cached.file_path and cached.file_path ~= "" then
                return cached.file_path
            end
        end
        if book_id and type(self.db.getLatestBookPathByBookId) == "function" then
            local cached_path = safeDbValueCall(self.db, "getLatestBookPathByBookId", nil, book_id)
            if cached_path and cached_path ~= "" then
                return cached_path
            end
        end
    end
    return current and current.file_path or nil
end

function Grimmlink:applyPulledRating(doc_settings, item, payload)
    local rating = normalizeRemoteRatingPayload(payload)
    if not rating then
        return false, "invalid_rating"
    end

    local summary = type(tryReadSetting) == "function" and tryReadSetting(doc_settings, "summary") or nil
    if type(summary) ~= "table" then
        summary = type(doc_settings.summary) == "table" and cloneForMetadata(doc_settings.summary) or {}
    else
        summary = cloneForMetadata(summary)
    end
    summary.rating = rating.summary_rating
    doc_settings.summary = summary
    if type(tryWriteSetting) == "function" then
        tryWriteSetting(doc_settings, "summary", summary)
        if type(buildReadingCompletionRatingState) == "function" then
            tryWriteSetting(doc_settings, READING_COMPLETION_RATING_STATE_KEY,
                buildReadingCompletionRatingState(rating.value, rating.summary_rating))
        else
            tryWriteSetting(doc_settings, READING_COMPLETION_RATING_STATE_KEY, rating)
        end
    end
    return true, "rating_applied"
end

function Grimmlink:buildRemoteBookmarkEntry(item, payload, as_annotation_note)
    local location = payloadLocation(payload)
    local text = firstNonEmpty(payload.title, payload.text, payload.highlight)
    local notes = firstNonEmpty(payload.notes, payload.note)
    local page = firstNonEmpty(payload.page, payload.pageno, location.pageno)
    local pos0 = firstNonEmpty(payload.pos0, location.pos0)
    return {
        pos0 = pos0,
        page = page,
        pageno = firstNumber(payload.pageno, location.pageno),
        location = firstNonEmpty(payload.raw, payload.location, location.raw, location.cfi, location.pos0, pos0),
        text = text,
        title = text or (as_annotation_note and _("Remote annotation") or _("Remote bookmark")),
        notes = notes,
        datetime = firstNonEmpty(payload.createdAt, payload.created_at, payload.datetime, payload.updatedAt, payload.updated_at,
            item.clientUpdatedAt, item.updatedAt, item.syncedAt, nowUtc()),
        chapter = firstNonEmpty(payload.chapter),
        grimmlink_remote_id = safeToString(item.id),
        grimmlink_dedupe_key = remoteItemDedupeKey(item),
        grimmlink_source = "remote",
        grimmlink_remote_type = normalizeRemoteMetadataType(item.type),
    }
end

function Grimmlink:buildRemoteAnnotationEntry(item, payload)
    local location = payloadLocation(payload)
    local pos0 = firstNonEmpty(payload.pos0, location.pos0)
    local pos1 = firstNonEmpty(payload.pos1, location.pos1)
    local has_anchor = (pos0 ~= nil and pos0 ~= "") or (pos1 ~= nil and pos1 ~= "")
    if not has_anchor then
        return self:buildRemoteBookmarkEntry(item, payload, true), "downgraded_to_note"
    end
    return {
        text = firstNonEmpty(payload.text, payload.highlight, payload.title),
        note = firstNonEmpty(payload.note, payload.notes),
        datetime = firstNonEmpty(payload.createdAt, payload.created_at, payload.datetime, payload.updatedAt, payload.updated_at,
            item.clientUpdatedAt, item.updatedAt, item.syncedAt, nowUtc()),
        page = firstNonEmpty(payload.page, payload.pageno, location.pageno),
        pageno = firstNumber(payload.pageno, location.pageno),
        chapter = firstNonEmpty(payload.chapter),
        color = firstNonEmpty(payload.color),
        drawer = firstNonEmpty(payload.drawer, payload.style),
        pos0 = pos0,
        pos1 = pos1,
        location = firstNonEmpty(payload.raw, payload.location, location.raw, location.cfi, pos0),
        grimmlink_remote_id = safeToString(item.id),
        grimmlink_dedupe_key = remoteItemDedupeKey(item),
        grimmlink_source = "remote",
        grimmlink_remote_type = "annotation",
    }, "annotation_applied"
end

function Grimmlink:appendPulledAnnotationLikeItem(doc_settings, item, payload)
    local annotations = type(tryReadSetting) == "function" and tryReadSetting(doc_settings, "annotations") or nil
    if type(annotations) ~= "table" then
        annotations = type(doc_settings.annotations) == "table" and cloneForMetadata(doc_settings.annotations) or {}
    else
        annotations = cloneForMetadata(annotations)
    end
    local dedupe_key = remoteItemDedupeKey(item)
    if annotationListHasRemoteDedupe(annotations, dedupe_key) then
        return true, "already_in_docsettings"
    end

    local entry, status
    local item_type = normalizeRemoteMetadataType(item.type)
    if item_type == "annotation" then
        entry, status = self:buildRemoteAnnotationEntry(item, payload)
    else
        entry, status = self:buildRemoteBookmarkEntry(item, payload, false), "bookmark_applied"
    end
    if type(entry) ~= "table" then
        return false, "invalid_annotation"
    end

    table.insert(annotations, entry)
    doc_settings.annotations = annotations
    if type(tryWriteSetting) == "function" then
        tryWriteSetting(doc_settings, "annotations", annotations)
    end
    return true, status
end

function Grimmlink:applyPulledMetadataItem(doc_settings, item)
    local item_type = normalizeRemoteMetadataType(item and item.type)
    local payload = remoteItemPayload(item)
    if not item_type or type(payload) ~= "table" then
        return false, "invalid_item"
    end
    if item_type == "rating" then
        if not self.rating_sync_enabled then
            return true, "rating_disabled"
        end
        return self:applyPulledRating(doc_settings, item, payload)
    end
    if item_type == "annotation" then
        if not self.annotations_sync_enabled then
            return true, "annotation_disabled"
        end
        return self:appendPulledAnnotationLikeItem(doc_settings, item, payload)
    end
    if item_type == "bookmark" then
        if not self.bookmarks_sync_enabled then
            return true, "bookmark_disabled"
        end
        return self:appendPulledAnnotationLikeItem(doc_settings, item, payload)
    end
    return false, "unsupported_item_type"
end

function Grimmlink:markRemoteMetadataItemApplied(context, item, status)
    local item_type = normalizeRemoteMetadataType(item and item.type)
    local dedupe_key = remoteItemDedupeKey(item)
    if not self.db or not context or not context.file_hash or not item_type or not dedupe_key then
        return false
    end
    return safeDbBoolCall(self.db, "markRemoteMetadataItemApplied", {
        file_hash = context.file_hash,
        book_id = item.bookId or context.book_id,
        book_file_id = item.bookFileId or context.book_file_id,
        item_type = item_type,
        dedupe_key = dedupe_key,
        remote_id = item.id,
        payload_json = item.payloadJson or item.payload_json,
        status = status,
    })
end

function Grimmlink:applyPulledMetadataItems(context, items)
    local result = {
        applied = 0,
        skipped = 0,
        failed = 0,
        changed = false,
    }
    if type(items) ~= "table" or #items == 0 then
        return result
    end
    if not context or not context.file_hash or context.file_hash == "" then
        result.failed = #items
        result.reason = "missing_file_hash"
        return result
    end

    context.file_path = context.file_path or self:getMetadataFilePathForIdentity(context.file_hash, context.book_id)
    if not context.file_path or context.file_path == "" then
        result.failed = #items
        result.reason = "missing_file_path"
        self:logWarn("GrimmLink metadata pull cannot apply: missing local file path")
        return result
    end

    local doc_settings, should_close = self:loadWritableDocSettings(context.file_path)
    if type(doc_settings) ~= "table" then
        result.failed = #items
        result.reason = "doc_settings_unavailable"
        self:logWarn("GrimmLink metadata pull cannot apply: doc settings unavailable")
        return result
    end

    for _, item in ipairs(items) do
        local item_type = normalizeRemoteMetadataType(item and item.type)
        local dedupe_key = remoteItemDedupeKey(item)
        if not item_type or not dedupe_key then
            result.skipped = result.skipped + 1
        elseif remoteItemDeviceId(item) and self.device_id and remoteItemDeviceId(item) == safeToString(self.device_id) then
            self:markRemoteMetadataItemApplied(context, item, "skipped_same_device")
            result.skipped = result.skipped + 1
        elseif safeDbBoolCall(self.db, "isRemoteMetadataItemApplied", context.file_hash, item_type, dedupe_key) then
            result.skipped = result.skipped + 1
        else
            local ok_apply, applied, status = pcall(self.applyPulledMetadataItem, self, doc_settings, item)
            if ok_apply and applied == true then
                self:markRemoteMetadataItemApplied(context, item, status or "applied")
                result.applied = result.applied + 1
                if status ~= "already_in_docsettings" and not tostring(status or ""):find("disabled", 1, true)
                    and status ~= "skipped_same_device" then
                    result.changed = true
                end
            else
                result.failed = result.failed + 1
                self:logWarn("GrimmLink metadata pull apply failed type=", item_type,
                    " dedupe=", shortPrefix(dedupe_key, 16), " reason=", safeToString(status or applied or ok_apply))
            end
        end
    end

    if result.changed and type(tryFlushDocSettings) == "function" then
        tryFlushDocSettings(doc_settings)
    end
    if should_close and type(tryCloseDocSettings) == "function" then
        tryCloseDocSettings(doc_settings)
    end
    return result
end

function Grimmlink:mergePulledMetadataItems(file_hash, book_id, items)
    local merged = 0
    if type(items) ~= "table" then
        return merged
    end

    for _, item in ipairs(items) do
        if type(item) == "table" and remoteItemDedupeKey(item) and item.type then
            if safeDbBoolCall(self.db, "markMetadataItemSynced", {
                file_hash = file_hash,
                book_id = item.bookId or book_id,
                item_type = normalizeRemoteMetadataType(item.type) or item.type,
                dedupe_key = remoteItemDedupeKey(item),
                server_id = item.id,
            }) then
                merged = merged + 1
            end
        end
    end

    return merged
end

function Grimmlink:pullRemoteMetadataForContext(context, silent, limit, item_type)
    local result = {
        pulled = 0,
        applied = 0,
        skipped = 0,
        failed = 0,
        cursor_saved = false,
    }

    if not self.db or not self.metadata_sync_enabled then
        return result
    end
    if not context or (not context.book_id and not context.file_hash and not context.book_file_id) then
        return result
    end
    if context.file_hash and not self:isTrackingEnabledForContext(context) then
        return result
    end
    if not self:requireReady({ require_api = true, silent = silent }) then
        return result
    end
    if not self:isOnline() then
        return result
    end
    if not self:isApiReady({ "submitMetadataBatch" }) then
        return result
    end
    if not self:refreshApiClient() then
        return result
    end

    local pull_since = self:getMetadataCursor(context.file_hash, context.book_id, context.book_file_id)
    local payload = nil
    if type(self.api.buildMetadataPullPayload) == "function" then
        payload = self.api:buildMetadataPullPayload(
            context.book_id,
            context.file_hash,
            context.book_file_id,
            context.file_format or context.book_type or "EPUB",
            self.device_name,
            self.device_id,
            pull_since,
            limit or 100,
            item_type
        )
    else
        payload = self.api:buildMetadataBatchPayload(
            context.book_id,
            context.file_hash,
            context.book_file_id,
            context.file_format or context.book_type or "EPUB",
            self.device_name,
            self.device_id,
            nil,
            {},
            {},
            pull_since,
            limit or 100
        )
        payload.type = item_type
    end

    local ok_submit, response, code = self.api:submitMetadataBatch(payload)
    if not ok_submit or type(response) ~= "table" then
        result.failed = 1
        self:logWarn("GrimmLink metadata pull request failed:", safeToString(response or code or "network_error"))
        if not silent then
            self:showMessage(T(_("Remote metadata pull failed: %1"), safeToString(response or code or "network_error")), 4)
        end
        return result
    end

    local pull = type(response.pull) == "table" and response.pull or response
    if pull.ok == false then
        result.failed = 1
        if not silent then
            self:showMessage(_("Remote metadata pull failed"), 4)
        end
        return result
    end

    local items = type(pull.items) == "table" and pull.items or {}
    result.pulled = #items
    local apply_result = self:applyPulledMetadataItems(context, items)
    result.applied = apply_result.applied or 0
    result.skipped = apply_result.skipped or 0
    result.failed = apply_result.failed or 0

    if result.failed == 0 and pull.nextCursor ~= nil and pull.nextCursor ~= "" then
        result.cursor_saved = self:saveMetadataCursor(context.file_hash, context.book_id, context.book_file_id, pull.nextCursor)
    end

    if not silent then
        self:showMessage(T(
            _("Remote metadata pull\nPulled: %1\nApplied: %2\nSkipped: %3\nFailed: %4"),
            result.pulled,
            result.applied,
            result.skipped,
            result.failed
        ), 4)
    end
    return result
end


local function fileExists(path)
    if not path or path == "" then
        return false
    end
    if lfs and type(lfs.attributes) == "function" then
        local ok_attr, attr = pcall(lfs.attributes, path)
        return ok_attr and type(attr) == "table" and attr.mode == "file"
    end
    return true
end

function Grimmlink:buildMetadataPullContextFromCandidate(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local file_path = candidate.file_path or candidate.local_path
    local file_hash = candidate.file_hash
    local book_id = candidate.book_id or candidate.bookId
    local book_file_id = candidate.book_file_id or candidate.bookFileId

    if file_path and file_path ~= "" and not fileExists(file_path) then
        return nil
    end

    if (not file_hash or file_hash == "") and file_path and file_path ~= "" and type(self.calculateBookHash) == "function" then
        local ok_hash, computed_hash = pcall(self.calculateBookHash, self, file_path)
        if ok_hash and computed_hash and computed_hash ~= "" then
            file_hash = computed_hash
            if self.db and type(self.db.saveBookCache) == "function" then
                pcall(self.db.saveBookCache, self.db, file_path, file_hash, book_id, candidate.title or candidate.remote_title, candidate.author or candidate.remote_author)
            end
        end
    end

    if (not book_id or not book_file_id) and file_path and file_path ~= "" and type(self.resolveBookByFilePath) == "function" then
        local ok_cached, cached = pcall(self.resolveBookByFilePath, self, file_path)
        if ok_cached and type(cached) == "table" then
            file_hash = file_hash or cached.file_hash
            book_id = book_id or cached.book_id
            book_file_id = book_file_id or cached.book_file_id
        end
    end

    if not file_hash or file_hash == "" then
        -- Local application/dedupe needs a file hash. Without it, pull by bookId may work
        -- on the server but the plugin cannot safely write or track applied items locally.
        return nil
    end

    if not book_id and not book_file_id then
        return nil
    end

    return {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
        file_format = candidate.file_format or candidate.remote_format,
    }
end

function Grimmlink:pullRemoteMetadataForKnownBooks(silent, limit, item_type)
    local result = {
        books = 0,
        pulled = 0,
        applied = 0,
        skipped = 0,
        failed = 0,
        candidates = 0,
    }

    if not self.metadata_sync_enabled then
        if not silent then
            self:showMessage(_("Metadata sync is disabled"), 3)
        end
        return result
    end
    if not self.db or type(self.db.getMetadataPullCandidates) ~= "function" then
        if not silent then
            self:showMessage(_("No local GrimmLink book cache available for metadata pull"), 4)
        end
        return result
    end

    local ok_candidates, candidates = pcall(self.db.getMetadataPullCandidates, self.db, limit or 100)
    if not ok_candidates or type(candidates) ~= "table" or #candidates == 0 then
        if not silent then
            self:showMessage(_("No local books are known to GrimmLink yet. Open or sync a shelf first."), 4)
        end
        return result
    end
    result.candidates = #candidates

    local seen = {}
    for _, candidate in ipairs(candidates) do
        local context = self:buildMetadataPullContextFromCandidate(candidate)
        local key = context and ((context.file_hash or "") .. ":" .. tostring(context.book_id or context.book_file_id or "")) or nil
        if context and key and not seen[key] then
            seen[key] = true
            local pull_result = self:pullRemoteMetadataForContext(context, true, limit or 100, item_type)
            result.books = result.books + 1
            result.pulled = result.pulled + (pull_result.pulled or 0)
            result.applied = result.applied + (pull_result.applied or 0)
            result.skipped = result.skipped + (pull_result.skipped or 0)
            result.failed = result.failed + (pull_result.failed or 0)
        else
            result.skipped = result.skipped + 1
        end
    end

    if not silent then
        if result.books == 0 then
            self:showMessage(_("No usable local book context for metadata pull. Open a matched book or sync a shelf first."), 4)
        else
            self:showMessage(T(
                _("Remote metadata pull\nBooks: %1\nPulled: %2\nApplied: %3\nSkipped: %4\nFailed: %5"),
                result.books,
                result.pulled,
                result.applied,
                result.skipped,
                result.failed
            ), 5)
        end
    end
    return result
end

function Grimmlink:pullRemoteMetadataNow(silent, limit, item_type)
    local context = self:getMetadataExtractionContext()
    if context and (context.file_hash or context.book_id or context.book_file_id) then
        return self:pullRemoteMetadataForCurrentBook(silent, limit, item_type)
    end
    return self:pullRemoteMetadataForKnownBooks(silent, limit, item_type)
end

function Grimmlink:pullRemoteMetadataForCurrentBook(silent, limit, item_type)
    if not self.metadata_sync_enabled then
        if not silent then
            self:showMessage(_("Metadata sync is disabled"), 3)
        end
        return nil
    end
    local context = self:getMetadataExtractionContext()
    if not context or (not context.file_hash and not context.book_id and not context.book_file_id) then
        if not silent then
            self:showMessage(_("No active document to pull remote metadata"), 3)
        end
        return nil
    end
    if not self:isTrackingEnabledForContext(context) then
        if not silent then
            self:showTrackingDisabledMessage()
        end
        return nil
    end
    return self:pullRemoteMetadataForContext(context, silent, limit, item_type)
end

function Grimmlink:handleMetadataRowRetry(row, reason)
    local max_retry = tonumber(self.metadata_retry_max) or DEFAULTS.metadata_retry_max
    local retry_count = tonumber(row.retry_count) or 0
    if retry_count >= max_retry then
        self:logWarn("GrimmLink metadata drop after max retry itemType=", row.item_type,
            " dedupe=", shortPrefix(row.dedupe_key, 16), " reason=", reason)
        safeDbBoolCall(self.db, "deletePendingMetadataItem", row.id)
        return false
    end
    safeDbBoolCall(self.db, "incrementPendingMetadataRetry", row.id)
    return true
end

function Grimmlink:syncPendingMetadata(silent, limit)
    local synced = 0
    local failed = 0

    if not self.db or not self.metadata_sync_enabled then
        return synced, failed
    end
    if not self:requireReady({ require_api = true, silent = silent }) then
        return synced, failed
    end
    if not self:isOnline() then
        return synced, failed
    end
    if not self:isApiReady({ "submitMetadataBatch" }) then
        return synced, failed
    end
    if not self:refreshApiClient() then
        return synced, failed
    end

    local pending = safeDbValueCall(self.db, "getPendingMetadataItems", {}, limit or 100)
    if #pending == 0 then
        local pull_result = self:pullRemoteMetadataForCurrentBook(true, limit or 100)
        if pull_result and pull_result.failed and pull_result.failed > 0 then
            failed = failed + pull_result.failed
        end
        return synced, failed
    end

    local groups = {}
    for _, row in ipairs(pending) do
        if self:isTrackingEnabled(row.file_hash, nil) then
            local should_consider = (row.item_type ~= "rating" or self.rating_sync_enabled)
                and (row.item_type ~= "annotation" or self.annotations_sync_enabled)
                and (row.item_type ~= "bookmark" or self.bookmarks_sync_enabled)
            if should_consider then
                local ok_payload, payload = pcall(json.decode, row.payload_json or "")
                if not ok_payload or type(payload) ~= "table" then
                    safeDbBoolCall(self.db, "deletePendingMetadataItem", row.id)
                    failed = failed + 1
                else
                    local key = table.concat({
                        safeToString(row.book_id or ""),
                        safeToString(row.file_hash or ""),
                        safeToString(row.book_file_id or ""),
                    }, "|")
                    if not groups[key] then
                        groups[key] = {
                            book_id = row.book_id,
                            book_hash = row.file_hash,
                            book_file_id = row.book_file_id,
                            file_format = payload.fileFormat or payload.bookType or "EPUB",
                            rows = {},
                            item_by_dedupe = {},
                            rating = nil,
                            annotations = {},
                            bookmarks = {},
                        }
                    end
                    local group = groups[key]
                    group.pull_since = group.pull_since or self:getMetadataCursor(row.file_hash, row.book_id, row.book_file_id)
                    group.rows[#group.rows + 1] = row
                    group.item_by_dedupe[row.dedupe_key] = row

                    if row.item_type == "rating" then
                        group.rating = self:buildMetadataRatingPayload(row, payload)
                    elseif row.item_type == "annotation" then
                        group.annotations[#group.annotations + 1] = self:buildMetadataAnnotationPayload(row, payload)
                    elseif row.item_type == "bookmark" then
                        group.bookmarks[#group.bookmarks + 1] = self:buildMetadataBookmarkPayload(row, payload)
                    end
                end
            end
        end
    end

    local function handleResult(group, item_result, fallback_item_type, processed_ids)
        if type(item_result) ~= "table" then
            return
        end
        local dedupe_key = item_result.dedupeKey
        local row = dedupe_key and group.item_by_dedupe[dedupe_key] or nil
        if not row then
            return
        end
        processed_ids[row.id] = true
        local status = tostring(item_result.status or "")
        if status == "synced" or status == "duplicate" or status == "updated" then
            self:markMetadataRowSynced(row, item_result.serverId)
            synced = synced + 1
            return
        end
        if status == "invalid" then
            self:logWarn("GrimmLink metadata invalid dropped itemType=", fallback_item_type,
                " dedupe=", shortPrefix(dedupe_key, 16), " error=", safeToString(item_result.error))
            safeDbBoolCall(self.db, "deletePendingMetadataItem", row.id)
            failed = failed + 1
            return
        end
        self:handleMetadataRowRetry(row, status ~= "" and status or "failed")
        failed = failed + 1
    end

    for _, group in pairs(groups) do
        local has_payload_items = not (group.rating == nil and #group.annotations == 0 and #group.bookmarks == 0)
        if has_payload_items then
            local payload = self.api:buildMetadataBatchPayload(
                group.book_id,
                group.book_hash,
                group.book_file_id,
                group.file_format,
                self.device_name,
                self.device_id,
                group.rating,
                group.annotations,
                group.bookmarks,
                group.pull_since,
                limit or 100
            )

            local ok_submit, response, code = self.api:submitMetadataBatch(payload)
            if not ok_submit or type(response) ~= "table" then
                for _, row in ipairs(group.rows) do
                    self:handleMetadataRowRetry(row, safeToString(response or code or "network_error"))
                    failed = failed + 1
                end
            else
                local processed_ids = {}
                local failed_before_group = failed
                local results = response.results or (type(response.push) == "table" and response.push.results) or {}
                if type(results.rating) == "table" then
                    handleResult(group, results.rating, "rating", processed_ids)
                end
                for _, item in ipairs(results.annotations or {}) do
                    handleResult(group, item, "annotation", processed_ids)
                end
                for _, item in ipairs(results.bookmarks or {}) do
                    handleResult(group, item, "bookmark", processed_ids)
                end

                -- Any item with no explicit result is treated as retryable failure.
                for _, row in ipairs(group.rows) do
                    if not processed_ids[row.id] then
                        self:handleMetadataRowRetry(row, "missing_result")
                        failed = failed + 1
                    end
                end

                local pull = type(response.pull) == "table" and response.pull or nil
                if failed == failed_before_group and pull and pull.ok ~= false then
                    local pull_items = pull.items or {}
                    local has_apply_payload = false
                    for _, item in ipairs(pull_items) do
                        if remoteItemPayload(item) ~= nil then
                            has_apply_payload = true
                            break
                        end
                    end
                    local context = {
                        file_hash = group.book_hash,
                        book_id = group.book_id,
                        book_file_id = group.book_file_id,
                        file_format = group.file_format,
                    }
                    if not has_apply_payload then
                        self:mergePulledMetadataItems(group.book_hash, group.book_id, pull_items)
                        self:saveMetadataCursor(group.book_hash, group.book_id, group.book_file_id, pull.nextCursor)
                    else
                        local apply_result = self:applyPulledMetadataItems(context, pull_items)
                        if (apply_result.failed or 0) == 0 then
                            self:saveMetadataCursor(group.book_hash, group.book_id, group.book_file_id, pull.nextCursor)
                        elseif apply_result.reason == "missing_file_path" or apply_result.reason == "doc_settings_unavailable" then
                            self:mergePulledMetadataItems(group.book_hash, group.book_id, pull_items)
                            self:saveMetadataCursor(group.book_hash, group.book_id, group.book_file_id, pull.nextCursor)
                        else
                            failed = failed + (apply_result.failed or 0)
                        end
                    end
                end
            end
        end
    end

    if not silent and (synced > 0 or failed > 0) then
        self:showMessage(T(_("Pending metadata sync\nSynced: %1\nFailed: %2"), synced, failed), 3)
    end
    return synced, failed
end

function Grimmlink:syncMetadataNow()
    local context = self:getCurrentDocumentContext()
    if context and not self:isTrackingEnabledForContext(context) then
        self:showTrackingDisabledMessage()
        return
    end

    if not self.metadata_sync_enabled then
        self:showMessage(_("Metadata sync is disabled"), 3)
        return
    end

    local pending_before = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    local queued_count = 0
    local queue_failed_count = 0
    local queued_result = self:extractAndQueueCurrentMetadata("manual-metadata-sync", context)
    if queued_result and type(queued_result.queued) == "table" then
        queued_count = tonumber(queued_result.queued.queued) or 0
        queue_failed_count = tonumber(queued_result.queued.failed) or 0
    end

    local pending_after_queue = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    if (tonumber(pending_after_queue) or 0) <= 0 then
        self:showMessage(T(_("No metadata to sync\nQueue failed: %1"), queue_failed_count), 3)
        return
    end

    self:showMessage(_("Syncing metadata..."), 2)
    local synced, failed = self:syncPendingMetadata(true)
    local pending_after_sync = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
    self:showMessage(T(
        _("Metadata sync result\nQueued: %1\nQueue failed: %2\nSynced: %3\nFailed: %4\nPending: %5"),
        queued_count,
        queue_failed_count,
        synced or 0,
        failed or 0,
        pending_after_sync or pending_before or 0
    ), 4)
end

function Grimmlink:rebuildMetadataQueueForCurrentBook()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local context = self:getMetadataExtractionContext()
    if not context or not context.file_hash then
        self:showMessage(_("No active document to rebuild metadata queue"), 3)
        return
    end
    if not self:isTrackingEnabledForContext(context) then
        self:showTrackingDisabledMessage()
        return
    end

    self:showConfirmAction(
        _("Rebuild metadata queue for current book?\nThis replaces local pending metadata rows for this file."),
        _("Rebuild Queue"),
        function()
            safeDbBoolCall(self.db, "deletePendingMetadataByFileHash", context.file_hash)
            local queued = self:extractAndQueueCurrentMetadata("rebuild-metadata-queue", context)
            if queued then
                local pending_count = safeDbValueCall(self.db, "getPendingMetadataCount", 0)
                self:showMessage(T(_("Metadata queue rebuilt for current book.\nPending metadata: %1"), pending_count), 4)
            else
                self:showMessage(_("Failed to rebuild metadata queue for current book"), 4)
            end
        end
    )
end

function Grimmlink:forceMetadataResyncForCurrentBook()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return
    end
    local context = self:getMetadataExtractionContext()
    if not context or not context.file_hash then
        self:showMessage(_("No active document to force metadata resync"), 3)
        return
    end
    if not self:isTrackingEnabledForContext(context) then
        self:showTrackingDisabledMessage()
        return
    end

    self:showConfirmAction(
        _("Force metadata re-upload for current book?\nThis clears local synced-history for this file only."),
        _("Force Resync"),
        function()
            local cleared_synced = safeDbBoolCall(self.db, "clearSyncedMetadataHistoryForFileHash", context.file_hash)
            local cleared_pending = safeDbBoolCall(self.db, "deletePendingMetadataByFileHash", context.file_hash)
            local queued = self:extractAndQueueCurrentMetadata("force-metadata-resync", context)
            if queued and (cleared_synced or cleared_pending) then
                self:syncPendingMetadata(false)
                self:showMessage(_("Forced metadata resync queued for current book"), 4)
            elseif queued then
                self:syncPendingMetadata(false)
                self:showMessage(_("Metadata resync queued (history clear partially unavailable)"), 4)
            else
                self:showMessage(_("Failed to queue forced metadata resync"), 4)
            end
        end
    )
end

function Grimmlink:resetMetadataPullCursorForCurrentBook()
    if not self.db then
        self:showMessage(_("Database not available"), 3)
        return false
    end
    local context = self:getMetadataExtractionContext()
    if not context or (not context.file_hash and not context.book_id and not context.book_file_id) then
        self:showMessage(_("No active document to reset metadata cursor"), 3)
        return false
    end
    local key = self:metadataCursorKey(context.file_hash, context.book_id, context.book_file_id)
    if not key then
        self:showMessage(_("Metadata cursor key unavailable"), 3)
        return false
    end
    local cleared = false
    if type(self.db.deletePluginSetting) == "function" then
        cleared = safeDbBoolCall(self.db, "deletePluginSetting", key)
    else
        cleared = safeDbBoolCall(self.db, "savePluginSetting", key, "")
    end
    if cleared and context.file_hash and type(self.db.clearRemoteMetadataAppliedForFileHash) == "function" then
        safeDbBoolCall(self.db, "clearRemoteMetadataAppliedForFileHash", context.file_hash)
    end
    self:showMessage(cleared and _("Metadata pull cursor reset for current book") or _("Failed to reset metadata pull cursor"), 3)
    return cleared
end

end

return M
