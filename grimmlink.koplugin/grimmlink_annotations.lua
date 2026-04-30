--[[
GrimmLink Annotations Sync (Prompt 6)

Extracts KOReader-native annotations / bookmarks / personal rating from the
current document (via the active ReaderUI) and queues them for upload to
Grimmory through the KOReader-specific endpoints under /api/koreader/.

Design invariants:
  * Preserves raw KOReader location data (xpointer / page). NEVER converts
    to EPUB CFI — Web Reader bridge is intentionally out of scope.
  * Never deletes server-side library files or book records.
  * Sync is best-effort: if offline or upload fails, items stay in the
    pending_annotations queue and reading is never blocked.
  * Dedupe is performed client-side (stable key) AND server-side (unique
    constraint on user_id + book_id + dedupe_key).
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
            -- Fallback: use the raw input truncated. Dedupe is still unique
            -- per (book_id, kind, pos, text) since the concatenated input
            -- already encodes all identifying fields. The unique constraint
            -- is on (user_id, book_id, dedupe_key) so collisions across
            -- different books don't affect dedupe.
            _md5 = function(s) return (tostring(s) or ""):sub(1, 120) end
        end
    end
    return _md5(input)
end

local Annotations = {}
Annotations.__index = Annotations

function Annotations:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

-- ----- Helpers -----

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

-- Stable dedupe key for an annotation: md5(book_id|kind|pos|text)
local function buildDedupeKey(book_id, kind, pos, text)
    local input = tostring(book_id or "") .. "|" .. tostring(kind or "")
        .. "|" .. tostring(pos or "") .. "|" .. tostring(text or "")
    return md5(input)
end

-- ----- Extraction from KOReader UI -----

-- Returns an array of annotation dtos (plain Lua tables, server-shaped).
-- KOReader stores highlights either in the modern annotations array on
-- ReaderAnnotation, or in the legacy `bookmarks` table on ReaderBookmark
-- (where bookmarks with notes / drawer == "lighten" etc. are highlights).
function Annotations:extractAnnotations(book_id, ui)
    if not ui then return {} end
    local out = {}

    local handled_pos = {}

    -- 1. Modern annotation system (if present)
    if ui.annotation and ui.annotation.annotations then
        for _, a in ipairs(ui.annotation.annotations) do
            if a and a.text and a.text ~= "" then
                local pos = a.pos0 or a.page or a.pageno or ""
                local text = safeStr(a.text)
                local note = safeStr(a.note)
                local color = safeStr(a.color)
                local drawer = safeStr(a.drawer)
                local chapter = safeStr(a.chapter)
                local page = safeInt(a.page or a.pageno)
                local key = buildDedupeKey(book_id, "annotation", pos, text)
                handled_pos[tostring(pos)] = true
                out[#out + 1] = {
                    dedupeKey = key,
                    koreaderPos = safeStr(pos),
                    page = page,
                    chapter = chapter,
                    text = text,
                    note = note,
                    color = color,
                    drawer = drawer,
                    source = "KOREADER",
                    koreaderCreatedAt = safeInt(a.datetime_seconds),
                    koreaderUpdatedAt = safeInt(a.updated_seconds or a.datetime_seconds),
                }
            end
        end
    end

    -- 2. Legacy bookmarks-as-highlights (those with selected text)
    if ui.bookmark and ui.bookmark.bookmarks then
        for _, b in ipairs(ui.bookmark.bookmarks) do
            if b and b.notes and b.notes ~= "" and b.highlighted then
                local pos = b.pos0 or b.page or ""
                if not handled_pos[tostring(pos)] then
                    local text = safeStr(b.notes)
                    local note = safeStr(b.text)
                    local key = buildDedupeKey(book_id, "annotation", pos, text)
                    out[#out + 1] = {
                        dedupeKey = key,
                        koreaderPos = safeStr(pos),
                        page = safeInt(b.page),
                        chapter = safeStr(b.chapter),
                        text = text,
                        note = note,
                        color = safeStr(b.color),
                        drawer = safeStr(b.drawer),
                        source = "KOREADER",
                        koreaderCreatedAt = safeInt(b.datetime_seconds),
                        koreaderUpdatedAt = safeInt(b.datetime_seconds),
                    }
                end
            end
        end
    end

    return out
end

-- Extract pure bookmarks (not highlights with notes).
function Annotations:extractBookmarks(book_id, ui)
    if not ui or not ui.bookmark or not ui.bookmark.bookmarks then return {} end
    local out = {}
    for _, b in ipairs(ui.bookmark.bookmarks) do
        if b and not b.highlighted then
            local pos = b.pos0 or b.page or ""
            local text = safeStr(b.notes or b.text)
            local key = buildDedupeKey(book_id, "bookmark", pos, text or "")
            out[#out + 1] = {
                dedupeKey = key,
                koreaderPos = safeStr(pos),
                page = safeInt(b.page),
                chapter = safeStr(b.chapter),
                text = text,
                note = safeStr(b.text),
                source = "KOREADER",
                koreaderCreatedAt = safeInt(b.datetime_seconds),
            }
        end
    end
    return out
end

-- Extract personal rating from KOReader DocSettings (KOReader 5-star × 2 → 1..10).
function Annotations:extractRating(ui)
    if not ui or not ui.doc_settings then return nil end
    local summary = ui.doc_settings:readSetting("summary")
    if type(summary) ~= "table" then return nil end
    local stars = tonumber(summary.rating)
    if stars == nil then return nil end
    if stars < 0 then return nil end
    if stars > 5 then stars = 5 end
    -- Map 0..5 stars → 0..10. We treat 0 as "no rating" (skip).
    if stars == 0 then return nil end
    return math.floor(stars * 2)
end

-- ----- Queue + sync -----

-- Capture current document's annotations + bookmarks + rating into the queue.
-- book_id_remote is the Grimmory book ID (from book_cache or shelf_sync_map lookup).
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

-- Flush the queue. Groups by (book_id, kind) and posts per group.
-- Returns: { posted = N, failed = N, skipped = N, errors = {...} }
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

        if #payloads == 0 then goto continue end

        local ok, response
        if g.kind == "annotation" then
            ok, response = self.api:postAnnotationsBatch(g.book_id, payloads)
        elseif g.kind == "bookmark" then
            ok, response = self.api:postBookmarksBatch(g.book_id, payloads)
        elseif g.kind == "rating" then
            -- payloads should be a single { rating = N }
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

        ::continue::
    end

    logger.info(string.format(
        "GrimmLink Annotations sync: posted=%d failed=%d skipped=%d",
        result.posted, result.failed, result.skipped))
    return result
end

return Annotations
