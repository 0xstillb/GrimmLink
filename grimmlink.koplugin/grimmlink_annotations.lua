--[[
GrimmLink Annotations Sync (Prompts 6 + 7A)

Extracts KOReader-native annotations / bookmarks / personal rating from the
current document (via the active ReaderUI), queues them for upload to
Grimmory, and safely merges remote-newer annotation items back into KOReader.

Design invariants:
  * Preserves raw KOReader location data (xpointer / page). NEVER converts
    to EPUB CFI - Web Reader bridge is intentionally out of scope.
  * Never deletes server-side library files or book records.
  * Never deletes local user annotations during pull.
  * Never silently overwrites a local note/highlight when the merge is
    uncertain. Conflicts are cached instead of forcing an overwrite.
  * Sync is best-effort: if offline or import fails, items stay cached for
    retry and reading is never blocked.
]]

local json = require("json")
local logger = require("logger")

local _md5
local function md5(input)
    if not _md5 then
        local ok, sha2 = pcall(require, "ffi/sha2")
        if ok and sha2 and sha2.md5 then
            _md5 = sha2.md5
        else
            _md5 = function(s) return (tostring(s) or ""):sub(1, 120) end
        end
    end
    return _md5(input)
end

local function safeMethodCall(target, method, ...)
    if not target or type(target[method]) ~= "function" then
        return nil, false
    end

    local ok, result = pcall(target[method], target, ...)
    if ok then
        return result, true
    end
    return nil, false
end

local function safeStr(v)
    if v == nil then return nil end
    return tostring(v)
end

local function safeInt(v)
    if v == nil then return nil end
    local n = tonumber(v)
    if n == nil then return nil end
    return math.floor(n)
end

local function normalizeStr(v)
    local s = safeStr(v)
    if not s then return "" end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function nowEpoch()
    return os.time()
end

local Annotations = {}
Annotations.__index = Annotations

function Annotations:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

local function buildDedupeKey(book_id, kind, pos, text)
    local input = tostring(book_id or "") .. "|" .. tostring(kind or "")
        .. "|" .. tostring(pos or "") .. "|" .. tostring(text or "")
    return md5(input)
end

local function itemTimestamp(item)
    return safeInt(item and (item.koreaderUpdatedAt or item.updatedAt or item.koreaderCreatedAt or item.createdAt)) or 0
end

local function buildCandidateKey(item)
    return md5(table.concat({
        tostring(item and item.kind or ""),
        tostring(item and item.koreaderPos or ""),
        tostring(item and item.page or ""),
        normalizeStr(item and item.text),
        normalizeStr(item and item.source),
    }, "|"))
end

local function buildExactKey(item)
    return md5(table.concat({
        tostring(item and item.kind or ""),
        tostring(item and item.koreaderPos or ""),
        tostring(item and item.page or ""),
        normalizeStr(item and item.text),
        normalizeStr(item and item.note),
        normalizeStr(item and item.source),
    }, "|"))
end

local function copyForSync(model)
    return {
        id = model.id,
        bookId = model.bookId,
        type = model.type,
        dedupeKey = model.dedupeKey,
        koreaderPos = model.koreaderPos,
        page = model.page,
        chapter = model.chapter,
        text = model.text,
        note = model.note,
        color = model.color,
        drawer = model.drawer,
        source = model.source,
        koreaderCreatedAt = model.koreaderCreatedAt,
        koreaderUpdatedAt = model.koreaderUpdatedAt,
        createdAt = model.createdAt,
        updatedAt = model.updatedAt,
    }
end

function Annotations:normalizeModel(book_id, kind, source_item, raw_ref, storage)
    if type(source_item) ~= "table" then
        return nil
    end

    local model = {
        id = safeInt(source_item.id),
        bookId = safeInt(source_item.bookId) or safeInt(book_id),
        kind = kind,
        type = safeStr(source_item.type) or kind,
        dedupeKey = safeStr(source_item.dedupeKey),
        koreaderPos = safeStr(source_item.koreaderPos or source_item.pos0 or source_item.location or source_item.xpointer),
        page = safeInt(source_item.page or source_item.pageno),
        chapter = safeStr(source_item.chapter),
        text = safeStr(source_item.text),
        note = safeStr(source_item.note),
        color = safeStr(source_item.color),
        drawer = safeStr(source_item.drawer),
        source = safeStr(source_item.source) or "KOREADER",
        koreaderCreatedAt = safeInt(source_item.koreaderCreatedAt or source_item.datetime_seconds),
        koreaderUpdatedAt = safeInt(source_item.koreaderUpdatedAt or source_item.updated_seconds),
        createdAt = safeInt(source_item.createdAt),
        updatedAt = safeInt(source_item.updatedAt),
        raw = raw_ref,
        storage = storage,
    }

    if not model.dedupeKey then
        model.dedupeKey = buildDedupeKey(model.bookId, kind, model.koreaderPos, model.text or "")
    end

    return model
end

function Annotations:collectLocalAnnotations(book_id, ui)
    if not ui then return {} end
    local out = {}
    local handled_pos = {}

    if ui.annotation and ui.annotation.annotations then
        for _, a in ipairs(ui.annotation.annotations) do
            if a and a.text and a.text ~= "" then
                local model = self:normalizeModel(book_id, "annotation", {
                    dedupeKey = buildDedupeKey(book_id, "annotation", a.pos0 or a.page or a.pageno or "", a.text),
                    koreaderPos = a.pos0 or a.page or a.pageno or "",
                    page = a.page or a.pageno,
                    chapter = a.chapter,
                    text = a.text,
                    note = a.note,
                    color = a.color,
                    drawer = a.drawer,
                    source = "KOREADER",
                    koreaderCreatedAt = a.datetime_seconds,
                    koreaderUpdatedAt = a.updated_seconds or a.datetime_seconds,
                }, a, "annotation")
                handled_pos[tostring(model.koreaderPos or "")] = true
                out[#out + 1] = model
            end
        end
    end

    if ui.bookmark and ui.bookmark.bookmarks then
        for _, b in ipairs(ui.bookmark.bookmarks) do
            if b and b.notes and b.notes ~= "" and b.highlighted then
                local pos = b.pos0 or b.page or ""
                if not handled_pos[tostring(pos)] then
                    local model = self:normalizeModel(book_id, "annotation", {
                        dedupeKey = buildDedupeKey(book_id, "annotation", pos, b.notes),
                        koreaderPos = pos,
                        page = b.page,
                        chapter = b.chapter,
                        text = b.notes,
                        note = b.text,
                        color = b.color,
                        drawer = b.drawer,
                        source = "KOREADER",
                        koreaderCreatedAt = b.datetime_seconds,
                        koreaderUpdatedAt = b.datetime_seconds,
                    }, b, "legacy-highlight")
                    out[#out + 1] = model
                end
            end
        end
    end

    return out
end

function Annotations:extractAnnotations(book_id, ui)
    local out = {}
    for _, model in ipairs(self:collectLocalAnnotations(book_id, ui)) do
        out[#out + 1] = copyForSync(model)
    end
    return out
end

function Annotations:collectLocalBookmarks(book_id, ui)
    if not ui or not ui.bookmark or not ui.bookmark.bookmarks then return {} end
    local out = {}
    for _, b in ipairs(ui.bookmark.bookmarks) do
        if b and not b.highlighted then
            local pos = b.pos0 or b.page or ""
            local text = b.notes or b.text
            local model = self:normalizeModel(book_id, "bookmark", {
                dedupeKey = buildDedupeKey(book_id, "bookmark", pos, text or ""),
                koreaderPos = pos,
                page = b.page,
                chapter = b.chapter,
                text = text,
                note = b.text,
                source = "KOREADER",
                koreaderCreatedAt = b.datetime_seconds,
            }, b, "bookmark")
            out[#out + 1] = model
        end
    end
    return out
end

function Annotations:extractBookmarks(book_id, ui)
    local out = {}
    for _, model in ipairs(self:collectLocalBookmarks(book_id, ui)) do
        out[#out + 1] = copyForSync(model)
    end
    return out
end

function Annotations:extractRating(ui)
    if not ui or not ui.doc_settings then return nil end
    local summary = ui.doc_settings:readSetting("summary")
    if type(summary) ~= "table" then return nil end
    local stars = tonumber(summary.rating)
    if stars == nil or stars < 0 then return nil end
    if stars > 5 then stars = 5 end
    if stars == 0 then return nil end
    return math.floor(stars * 2)
end

function Annotations:captureCurrentDocument(book_id_remote, ui)
    if not book_id_remote or not self.db then return 0 end
    local total = 0

    local annotations = self:extractAnnotations(book_id_remote, ui)
    for _, a in ipairs(annotations) do
        local payload = json.encode(a)
        if self.db:enqueueAnnotation(book_id_remote, "annotation", a.dedupeKey, payload) then
            total = total + 1
        end
    end

    local bookmarks = self:extractBookmarks(book_id_remote, ui)
    for _, b in ipairs(bookmarks) do
        local payload = json.encode(b)
        if self.db:enqueueAnnotation(book_id_remote, "bookmark", b.dedupeKey, payload) then
            total = total + 1
        end
    end

    if self.rating_sync_enabled then
        local rating = self:extractRating(ui)
        if rating then
            local payload = json.encode({ rating = rating })
            if self.db:enqueueAnnotation(book_id_remote, "rating", nil, payload) then
                total = total + 1
            end
        end
    end

    logger.info("GrimmLink Annotations: captured", total, "items for bookId=", book_id_remote)
    return total
end

function Annotations:syncPending(opts)
    opts = opts or {}
    local result = { posted = 0, failed = 0, skipped = 0, errors = {} }
    if not self.db or not self.api then return result end

    local groups = self.db:getPendingAnnotationGroups(opts.batch_size or 100)
    if not groups or #groups == 0 then return result end

    for _, g in ipairs(groups) do
        local payloads = {}
        local ids = {}
        for _, item in ipairs(g.items) do
            local ok, decoded = pcall(json.decode, item.payload_json)
            if ok then
                payloads[#payloads + 1] = decoded
                ids[#ids + 1] = item.id
            else
                result.skipped = result.skipped + 1
                self.db:deletePendingAnnotations({ item.id })
            end
        end

        if #payloads > 0 then
            local ok, response
            if g.kind == "annotation" then
                ok, response = self.api:postAnnotationsBatch(g.book_id, payloads)
            elseif g.kind == "bookmark" then
                ok, response = self.api:postBookmarksBatch(g.book_id, payloads)
            elseif g.kind == "rating" then
                local last = payloads[#payloads]
                ok, response = self.api:putRating(g.book_id, last and last.rating or nil)
            else
                ok = false
                response = "unknown kind: " .. tostring(g.kind)
            end

            if ok then
                self.db:deletePendingAnnotations(ids)
                self.db:setAnnotationSyncState(g.book_id, g.kind, os.time(), nil)
                result.posted = result.posted + #ids
            else
                self.db:incrementPendingAnnotationRetry(ids, tostring(response))
                result.failed = result.failed + #ids
                result.errors[#result.errors + 1] = "bookId=" .. tostring(g.book_id)
                    .. " kind=" .. tostring(g.kind) .. ": " .. tostring(response)
            end
        end
    end

    logger.info(string.format(
        "GrimmLink Annotations sync: posted=%d failed=%d skipped=%d",
        result.posted, result.failed, result.skipped))
    return result
end

function Annotations:buildLocalIndex(items)
    local index = {
        by_dedupe = {},
        by_candidate = {},
        by_exact = {},
    }
    for _, item in ipairs(items or {}) do
        if item.dedupeKey then
            index.by_dedupe[item.dedupeKey] = item
        end
        index.by_candidate[buildCandidateKey(item)] = item
        index.by_exact[buildExactKey(item)] = item
    end
    return index
end

function Annotations:addToLocalIndex(index, item)
    if not item then return end
    if item.dedupeKey then
        index.by_dedupe[item.dedupeKey] = item
    end
    index.by_candidate[buildCandidateKey(item)] = item
    index.by_exact[buildExactKey(item)] = item
end

function Annotations:isSafeRemoteOverwrite(local_item, remote_item)
    local local_text = normalizeStr(local_item and local_item.text)
    local remote_text = normalizeStr(remote_item and remote_item.text)
    local local_note = normalizeStr(local_item and local_item.note)
    local remote_note = normalizeStr(remote_item and remote_item.note)

    local text_compatible = (local_text == remote_text) or (local_text == "") or (remote_text == "")
    local note_compatible = (local_note == remote_note) or (local_note == "")
    return text_compatible and note_compatible
end

function Annotations:compareLocalAndRemote(local_item, remote_item)
    if buildExactKey(local_item) == buildExactKey(remote_item) then
        return "exact_duplicate"
    end

    local remote_ts = itemTimestamp(remote_item)
    local local_ts = itemTimestamp(local_item)
    if remote_ts <= local_ts then
        return "local_newer"
    end

    if self:isSafeRemoteOverwrite(local_item, remote_item) then
        return "remote_newer_safe"
    end

    return "conflict"
end

function Annotations:persistLocalChanges(ui, kind)
    if not ui then return false end

    if kind == "annotation" and ui.annotation then
        ui.annotation.modified = true
        ui.annotation.updated = true
        safeMethodCall(ui.annotation, "save")
        safeMethodCall(ui.annotation, "saveAnnotations")
        safeMethodCall(ui.annotation, "writeAnnotations")
        safeMethodCall(ui.annotation, "saveHighlights")
        safeMethodCall(ui.annotation, "updatePage")
    elseif kind == "bookmark" and ui.bookmark then
        ui.bookmark.modified = true
        ui.bookmark.updated = true
        safeMethodCall(ui.bookmark, "save")
        safeMethodCall(ui.bookmark, "saveBookmarks")
        safeMethodCall(ui.bookmark, "writeBookmarks")
        safeMethodCall(ui.bookmark, "updateBookmarks")
    end

    if ui.doc_settings then
        safeMethodCall(ui.doc_settings, "flush")
        safeMethodCall(ui.doc_settings, "save")
    end
    safeMethodCall(ui, "refresh")
    safeMethodCall(ui, "onRefresh")
    return true
end

function Annotations:buildImportedAnnotationRaw(remote_item)
    local now = nowEpoch()
    return {
        pos0 = remote_item.koreaderPos,
        page = remote_item.page,
        pageno = remote_item.page,
        chapter = remote_item.chapter,
        text = remote_item.text,
        note = remote_item.note,
        color = remote_item.color,
        drawer = remote_item.drawer or "lighten",
        datetime_seconds = remote_item.koreaderCreatedAt or remote_item.createdAt or now,
        updated_seconds = remote_item.koreaderUpdatedAt or remote_item.updatedAt or now,
        source = remote_item.source or "KOREADER",
        highlighted = true,
        grimmory_remote_id = remote_item.id,
        grimmory_remote_key = remote_item.dedupeKey,
    }
end

function Annotations:buildImportedLegacyHighlight(remote_item)
    local now = nowEpoch()
    return {
        pos0 = remote_item.koreaderPos,
        page = remote_item.page,
        chapter = remote_item.chapter,
        notes = remote_item.text,
        text = remote_item.note,
        color = remote_item.color,
        drawer = remote_item.drawer or "lighten",
        highlighted = true,
        datetime_seconds = remote_item.koreaderCreatedAt or remote_item.createdAt or now,
        updated_seconds = remote_item.koreaderUpdatedAt or remote_item.updatedAt or now,
        source = remote_item.source or "KOREADER",
        grimmory_remote_id = remote_item.id,
        grimmory_remote_key = remote_item.dedupeKey,
    }
end

function Annotations:buildImportedBookmarkRaw(remote_item)
    local now = nowEpoch()
    return {
        pos0 = remote_item.koreaderPos,
        page = remote_item.page,
        chapter = remote_item.chapter,
        notes = remote_item.text,
        text = remote_item.note,
        highlighted = false,
        datetime_seconds = remote_item.koreaderCreatedAt or remote_item.createdAt or now,
        updated_seconds = remote_item.koreaderUpdatedAt or remote_item.updatedAt or now,
        source = remote_item.source or "KOREADER",
        grimmory_remote_id = remote_item.id,
        grimmory_remote_key = remote_item.dedupeKey,
    }
end

function Annotations:appendRemoteItem(book_id, kind, remote_item, ui)
    if kind == "annotation" then
        if ui and ui.annotation and ui.annotation.annotations then
            local raw = self:buildImportedAnnotationRaw(remote_item)
            ui.annotation.annotations[#ui.annotation.annotations + 1] = raw
            return true, self:normalizeModel(book_id, "annotation", copyForSync(remote_item), raw, "annotation")
        end
        if ui and ui.bookmark and ui.bookmark.bookmarks then
            local raw = self:buildImportedLegacyHighlight(remote_item)
            ui.bookmark.bookmarks[#ui.bookmark.bookmarks + 1] = raw
            return true, self:normalizeModel(book_id, "annotation", copyForSync(remote_item), raw, "legacy-highlight")
        end
        return false, "KOReader annotation store unavailable"
    end

    if ui and ui.bookmark and ui.bookmark.bookmarks then
        local raw = self:buildImportedBookmarkRaw(remote_item)
        ui.bookmark.bookmarks[#ui.bookmark.bookmarks + 1] = raw
        return true, self:normalizeModel(book_id, "bookmark", copyForSync(remote_item), raw, "bookmark")
    end

    return false, "KOReader bookmark store unavailable"
end

function Annotations:updateLocalItemFromRemote(local_item, remote_item)
    if not local_item or not local_item.raw then
        return false, "Missing local annotation reference"
    end

    local raw = local_item.raw
    if local_item.storage == "annotation" then
        raw.pos0 = remote_item.koreaderPos or raw.pos0
        raw.page = remote_item.page or raw.page
        raw.pageno = remote_item.page or raw.pageno
        raw.chapter = remote_item.chapter or raw.chapter
        raw.text = remote_item.text or raw.text
        raw.note = remote_item.note or raw.note
        raw.color = remote_item.color or raw.color
        raw.drawer = remote_item.drawer or raw.drawer
        raw.datetime_seconds = remote_item.koreaderCreatedAt or raw.datetime_seconds
        raw.updated_seconds = remote_item.koreaderUpdatedAt or remote_item.updatedAt or raw.updated_seconds
    elseif local_item.storage == "legacy-highlight" then
        raw.pos0 = remote_item.koreaderPos or raw.pos0
        raw.page = remote_item.page or raw.page
        raw.chapter = remote_item.chapter or raw.chapter
        raw.notes = remote_item.text or raw.notes
        raw.text = remote_item.note or raw.text
        raw.color = remote_item.color or raw.color
        raw.drawer = remote_item.drawer or raw.drawer
        raw.datetime_seconds = remote_item.koreaderUpdatedAt or remote_item.updatedAt or raw.datetime_seconds
    elseif local_item.storage == "bookmark" then
        raw.pos0 = remote_item.koreaderPos or raw.pos0
        raw.page = remote_item.page or raw.page
        raw.chapter = remote_item.chapter or raw.chapter
        raw.notes = remote_item.text or raw.notes
        raw.text = remote_item.note or raw.text
        raw.datetime_seconds = remote_item.koreaderUpdatedAt or remote_item.updatedAt or raw.datetime_seconds
    else
        return false, "Unsupported local storage: " .. tostring(local_item.storage)
    end

    raw.source = remote_item.source or raw.source
    raw.grimmory_remote_id = remote_item.id
    raw.grimmory_remote_key = remote_item.dedupeKey

    local_item.koreaderPos = remote_item.koreaderPos
    local_item.page = remote_item.page
    local_item.chapter = remote_item.chapter
    local_item.text = remote_item.text
    local_item.note = remote_item.note
    local_item.color = remote_item.color
    local_item.drawer = remote_item.drawer
    local_item.source = remote_item.source or local_item.source
    local_item.koreaderCreatedAt = remote_item.koreaderCreatedAt or local_item.koreaderCreatedAt
    local_item.koreaderUpdatedAt = remote_item.koreaderUpdatedAt or remote_item.updatedAt or local_item.koreaderUpdatedAt
    local_item.updatedAt = remote_item.updatedAt or local_item.updatedAt

    return true, local_item
end

function Annotations:normalizeRemoteItem(book_id, kind, source_item)
    local model = self:normalizeModel(book_id, kind, {
        id = source_item.id,
        bookId = source_item.bookId or book_id,
        type = source_item.type or kind,
        dedupeKey = source_item.dedupeKey,
        koreaderPos = source_item.koreaderPos or source_item.location or source_item.xpointer,
        page = source_item.page,
        chapter = source_item.chapter,
        text = source_item.text,
        note = source_item.note or source_item.comment,
        color = source_item.color,
        drawer = source_item.drawer,
        source = source_item.source or "KOREADER",
        koreaderCreatedAt = source_item.koreaderCreatedAt or source_item.createdAt,
        koreaderUpdatedAt = source_item.koreaderUpdatedAt or source_item.updatedAt,
        createdAt = source_item.createdAt,
        updatedAt = source_item.updatedAt,
    }, nil, nil)
    if not model then
        return nil
    end
    model.remoteKey = model.dedupeKey
    return model
end

function Annotations:saveMergeState(book_id, kind, remote_item, status, extra)
    extra = extra or {}
    local payload_json = json.encode(copyForSync(remote_item))
    self.db:saveRemoteAnnotationMergeState({
        book_id = book_id,
        kind = kind,
        remote_key = remote_item.remoteKey or remote_item.dedupeKey,
        remote_id = remote_item.id,
        remote_updated_at = itemTimestamp(remote_item),
        local_key = extra.local_key,
        status = status,
        payload_json = payload_json,
        retry_count = extra.retry_count or 0,
        last_error = extra.last_error,
        conflict_reason = extra.conflict_reason,
    })
end

function Annotations:loadRemoteItemsForKind(book_id, kind)
    local combined = {}
    local fetched = 0
    local max_remote_updated_at = nil

    local pending = self.db:getPendingRemoteAnnotationMergeStates(book_id, kind)
    for _, row in ipairs(pending or {}) do
        local ok, decoded = pcall(json.decode, row.payload_json or "{}")
        if ok and type(decoded) == "table" then
            local item = self:normalizeRemoteItem(book_id, kind, decoded)
            if item then
                item.remoteKey = row.remote_key or item.remoteKey
                combined[item.remoteKey] = item
            end
        end
    end

    local sync_state = self.db:getAnnotationSyncState(book_id, kind) or {}
    local since = sync_state.last_pulled_at

    local ok, response
    if kind == "annotation" then
        ok, response = self.api:getAnnotations(book_id, since)
    else
        ok, response = self.api:getBookmarks(book_id, since)
    end

    if ok and type(response) == "table" then
        for _, row in ipairs(response) do
            local item = self:normalizeRemoteItem(book_id, kind, row)
            if item then
                item.remoteKey = item.remoteKey or item.dedupeKey
                local current = combined[item.remoteKey]
                if not current or itemTimestamp(item) >= itemTimestamp(current) then
                    combined[item.remoteKey] = item
                end
                fetched = fetched + 1
                local ts = item.updatedAt or itemTimestamp(item)
                if ts and (not max_remote_updated_at or ts > max_remote_updated_at) then
                    max_remote_updated_at = ts
                end
            end
        end
        return combined, fetched, max_remote_updated_at or nowEpoch(), nil
    end

    return combined, fetched, nil, response
end

function Annotations:mergeRemoteKind(book_id, kind, ui, local_items)
    local result = {
        kind = kind,
        fetched = 0,
        imported = 0,
        updated = 0,
        duplicates = 0,
        conflicts = 0,
        pending = 0,
        skipped = 0,
        errors = {},
    }

    local index = self:buildLocalIndex(local_items or {})
    local combined, fetched, pull_watermark, fetch_error = self:loadRemoteItemsForKind(book_id, kind)
    result.fetched = fetched or 0

    if fetch_error and next(combined) == nil then
        result.errors[#result.errors + 1] = tostring(fetch_error)
        return result
    end

    local changed = false
    for _, remote_item in pairs(combined) do
        local existing_state = self.db:getRemoteAnnotationMergeState(book_id, kind, remote_item.remoteKey)
        local local_item = index.by_exact[buildExactKey(remote_item)]
            or index.by_dedupe[remote_item.dedupeKey]
            or index.by_candidate[buildCandidateKey(remote_item)]

        if local_item then
            local decision = self:compareLocalAndRemote(local_item, remote_item)
            if decision == "exact_duplicate" then
                result.duplicates = result.duplicates + 1
                self:saveMergeState(book_id, kind, remote_item, "duplicate", {
                    local_key = local_item.dedupeKey,
                })
            elseif decision == "local_newer" then
                result.skipped = result.skipped + 1
                self:saveMergeState(book_id, kind, remote_item, "local_newer", {
                    local_key = local_item.dedupeKey,
                })
            elseif decision == "remote_newer_safe" then
                local ok, updated_or_err = self:updateLocalItemFromRemote(local_item, remote_item)
                if ok then
                    changed = true
                    self:addToLocalIndex(index, updated_or_err)
                    result.updated = result.updated + 1
                    self:saveMergeState(book_id, kind, remote_item, "updated", {
                        local_key = updated_or_err.dedupeKey,
                    })
                else
                    result.pending = result.pending + 1
                    self:saveMergeState(book_id, kind, remote_item, "pending", {
                        local_key = local_item.dedupeKey,
                        retry_count = (existing_state and existing_state.retry_count or 0) + 1,
                        last_error = updated_or_err,
                    })
                end
            else
                result.conflicts = result.conflicts + 1
                self:saveMergeState(book_id, kind, remote_item, "conflict", {
                    local_key = local_item.dedupeKey,
                    conflict_reason = "Remote item differs from a local user annotation; keeping both untouched.",
                })
            end
        else
            local ok, imported_or_err = self:appendRemoteItem(book_id, kind, remote_item, ui)
            if ok then
                changed = true
                self:addToLocalIndex(index, imported_or_err)
                result.imported = result.imported + 1
                self:saveMergeState(book_id, kind, remote_item, "imported", {
                    local_key = imported_or_err.dedupeKey,
                })
            else
                result.pending = result.pending + 1
                self:saveMergeState(book_id, kind, remote_item, "pending", {
                    retry_count = (existing_state and existing_state.retry_count or 0) + 1,
                    last_error = imported_or_err,
                })
            end
        end
    end

    if changed then
        self:persistLocalChanges(ui, kind)
    end
    if pull_watermark then
        self.db:setAnnotationSyncState(book_id, kind, nil, pull_watermark)
    end
    if fetch_error then
        result.errors[#result.errors + 1] = tostring(fetch_error)
    end

    return result
end

function Annotations:pullRemoteForCurrentDocument(book_id, ui)
    local summary = {
        fetched = 0,
        imported = 0,
        updated = 0,
        duplicates = 0,
        conflicts = 0,
        pending = 0,
        skipped = 0,
        errors = {},
    }

    if not self.db or not self.api or not book_id or not ui then
        return summary
    end

    if self.annotations_sync_enabled then
        local local_annotations = self:collectLocalAnnotations(book_id, ui)
        local result = self:mergeRemoteKind(book_id, "annotation", ui, local_annotations)
        summary.fetched = summary.fetched + (result.fetched or 0)
        summary.imported = summary.imported + (result.imported or 0)
        summary.updated = summary.updated + (result.updated or 0)
        summary.duplicates = summary.duplicates + (result.duplicates or 0)
        summary.conflicts = summary.conflicts + (result.conflicts or 0)
        summary.pending = summary.pending + (result.pending or 0)
        summary.skipped = summary.skipped + (result.skipped or 0)
        for _, err in ipairs(result.errors or {}) do
            summary.errors[#summary.errors + 1] = "annotation: " .. tostring(err)
        end
    end

    if self.bookmarks_sync_enabled then
        local local_bookmarks = self:collectLocalBookmarks(book_id, ui)
        local result = self:mergeRemoteKind(book_id, "bookmark", ui, local_bookmarks)
        summary.fetched = summary.fetched + (result.fetched or 0)
        summary.imported = summary.imported + (result.imported or 0)
        summary.updated = summary.updated + (result.updated or 0)
        summary.duplicates = summary.duplicates + (result.duplicates or 0)
        summary.conflicts = summary.conflicts + (result.conflicts or 0)
        summary.pending = summary.pending + (result.pending or 0)
        summary.skipped = summary.skipped + (result.skipped or 0)
        for _, err in ipairs(result.errors or {}) do
            summary.errors[#summary.errors + 1] = "bookmark: " .. tostring(err)
        end
    end

    logger.info(string.format(
        "GrimmLink annotation pull: fetched=%d imported=%d updated=%d duplicates=%d conflicts=%d pending=%d skipped=%d",
        summary.fetched, summary.imported, summary.updated, summary.duplicates,
        summary.conflicts, summary.pending, summary.skipped
    ))
    return summary
end

return Annotations
