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

function Grimmlink:getMetadataCursor(file_hash, book_id, book_file_id)
    local key = self:metadataCursorKey(file_hash, book_id, book_file_id)
    if not key then
        return nil
    end
    local cursor = safeDbValueCall(self.db, "getPluginSetting", nil, key)
    if cursor == nil or cursor == "" then
        return nil
    end
    return safeToString(cursor)
end

function Grimmlink:saveMetadataCursor(file_hash, book_id, book_file_id, cursor)
    if cursor == nil or cursor == "" then
        return false
    end
    local key = self:metadataCursorKey(file_hash, book_id, book_file_id)
    if not key then
        return false
    end
    return safeDbBoolCall(self.db, "savePluginSetting", key, safeToString(cursor))
end

function Grimmlink:mergePulledMetadataItems(file_hash, book_id, items)
    local merged = 0
    if type(items) ~= "table" then
        return merged
    end

    for _, item in ipairs(items) do
        if type(item) == "table" and item.dedupeKey and item.type then
            if safeDbBoolCall(self.db, "markMetadataItemSynced", {
                file_hash = file_hash,
                book_id = item.bookId or book_id,
                item_type = item.type,
                dedupe_key = item.dedupeKey,
                server_id = item.id,
            }) then
                merged = merged + 1
            end
        end
    end

    return merged
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
                    self:mergePulledMetadataItems(group.book_hash, group.book_id, pull.items)
                    self:saveMetadataCursor(group.book_hash, group.book_id, group.book_file_id, pull.nextCursor)
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
end

return M
