local json = require("json")

local Extractor = {}

-- Adapted metadata parsing ideas from an upstream KOReader companion plugin.
-- Reworked for GrimmLink naming and local-only queue preparation.
local EXACT_RATING_STATE_KEY = "grimmlink_rating_state"

local function safeToString(value)
    if value == nil then
        return nil
    end
    return tostring(value)
end

local function trim(value)
    if value == nil then
        return nil
    end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil
    end
    return text
end

local function isNonEmpty(value)
    return trim(value) ~= nil
end

local function safeReadSetting(doc_settings, key)
    if not doc_settings or type(doc_settings.readSetting) ~= "function" then
        return nil
    end
    local ok, value = pcall(doc_settings.readSetting, doc_settings, key)
    if ok then
        return value
    end
    ok, value = pcall(doc_settings.readSetting, key)
    if ok then
        return value
    end
    return nil
end

local function loadDocSettingsByPath(file_path)
    if not file_path or file_path == "" then
        return nil
    end

    local ok_docsettings, docsettings = pcall(require, "docsettings")
    if not ok_docsettings or not docsettings then
        return nil
    end

    local loaders = {
        "open",
        "openDocSettings",
        "openDocSetting",
        "load",
        "new",
    }

    for _, loader in ipairs(loaders) do
        if type(docsettings[loader]) == "function" then
            local ok_loaded, loaded = pcall(docsettings[loader], file_path)
            if ok_loaded and type(loaded) == "table" then
                return loaded
            end
            ok_loaded, loaded = pcall(docsettings[loader], docsettings, file_path)
            if ok_loaded and type(loaded) == "table" then
                return loaded
            end
        end
    end

    return nil
end

local function normalizeExactRatingState(state, summary_rating)
    if type(state) ~= "table" then
        return nil
    end

    local value = math.floor(tonumber(state.value) or 0)
    local scale = math.floor(tonumber(state.scale) or 0)
    local stored_summary_rating = math.floor(tonumber(state.summary_rating or state.raw or state.koreader_rating) or 0)
    if scale ~= 10 or value < 1 or value > 10 or stored_summary_rating < 1 or stored_summary_rating > 5 then
        return nil
    end
    if summary_rating and stored_summary_rating ~= summary_rating then
        return nil
    end

    return {
        value = value,
        scale = 10,
        summary_rating = stored_summary_rating,
    }
end

local function extractRating(doc_settings)
    local summary = safeReadSetting(doc_settings, "summary")
    if type(summary) ~= "table" then
        summary = doc_settings and doc_settings.summary or nil
    end

    local raw_rating = summary and tonumber(summary.rating) or nil
    if raw_rating then
        raw_rating = math.floor(raw_rating)
        if raw_rating < 1 or raw_rating > 5 then
            raw_rating = nil
        end
    end

    local exact_state = normalizeExactRatingState(safeReadSetting(doc_settings, EXACT_RATING_STATE_KEY), raw_rating)
    if exact_state then
        return {
            raw = raw_rating or exact_state.summary_rating,
            value = exact_state.value,
            scale = exact_state.scale,
            normalized = exact_state.value,
        }
    end

    if not raw_rating then
        return nil
    end

    return {
        raw = raw_rating,
        value = raw_rating,
        scale = 5,
        normalized = raw_rating * 2,
    }
end

local function normalizeEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local normalized = {
        text = trim(entry.text or entry.highlight or entry.title),
        note = trim(entry.note or entry.notes),
        datetime = safeToString(entry.datetime or entry.time or entry.timestamp or entry.created_at),
        page = safeToString(entry.page or entry.location),
        pageno = safeToString(entry.pageno),
        chapter = trim(entry.chapter or entry.chapter_title),
        color = safeToString(entry.color),
        drawer = safeToString(entry.drawer),
        pos0 = safeToString(entry.pos0),
        pos1 = safeToString(entry.pos1),
        location = safeToString(entry.location),
    }
    return normalized
end

local function classifyEntry(entry)
    local has_pos = isNonEmpty(entry.pos0) or isNonEmpty(entry.pos1)
    local has_color = isNonEmpty(entry.color) or isNonEmpty(entry.drawer)
    local has_text = isNonEmpty(entry.text)
    local has_note = isNonEmpty(entry.note)
    local has_mark_anchor = isNonEmpty(entry.page) or isNonEmpty(entry.pageno) or isNonEmpty(entry.location)

    local is_annotation = has_pos or has_color or has_text or has_note
    local is_bookmark = (not has_pos and not has_color) and has_mark_anchor

    if is_bookmark and not has_text and not has_note and not has_mark_anchor then
        is_bookmark = false
    end

    if is_annotation and not is_bookmark then
        return "annotation"
    end
    if is_bookmark then
        return "bookmark"
    end

    if (not has_pos and not has_color) and (has_text or has_note) then
        return "bookmark"
    end
    return nil
end

local function extractAnnotations(doc_settings)
    local raw_annotations = safeReadSetting(doc_settings, "annotations")
    if type(raw_annotations) ~= "table" then
        raw_annotations = doc_settings and doc_settings.annotations or nil
    end
    if type(raw_annotations) ~= "table" then
        return {}, {}, 0
    end

    local highlights = {}
    local bookmarks = {}
    local notes_count = 0

    for _, entry in pairs(raw_annotations) do
        local normalized = normalizeEntry(entry)
        if normalized then
            local kind = classifyEntry(normalized)
            if kind == "annotation" then
                if isNonEmpty(normalized.note) then
                    notes_count = notes_count + 1
                end
                highlights[#highlights + 1] = {
                    text = normalized.text,
                    note = normalized.note,
                    datetime = normalized.datetime,
                    page = normalized.page,
                    chapter = normalized.chapter,
                    color = normalized.color,
                    drawer = normalized.drawer,
                    pos0 = normalized.pos0,
                    pos1 = normalized.pos1,
                }
            elseif kind == "bookmark" then
                bookmarks[#bookmarks + 1] = {
                    pos0 = normalized.pos0,
                    page = normalized.page,
                    location = normalized.location,
                    pageno = normalized.pageno,
                    text = normalized.text,
                    title = normalized.text,
                    notes = normalized.note,
                    datetime = normalized.datetime,
                    chapter = normalized.chapter,
                }
            end
        end
    end

    return highlights, bookmarks, notes_count
end

local function maybeCloseDocSettings(doc_settings, live_doc_settings)
    if not doc_settings or doc_settings == live_doc_settings then
        return
    end
    if type(doc_settings.close) == "function" then
        local ok = pcall(doc_settings.close, doc_settings)
        if not ok then
            pcall(doc_settings.close)
        end
    elseif type(doc_settings.flush) == "function" then
        local ok = pcall(doc_settings.flush, doc_settings)
        if not ok then
            pcall(doc_settings.flush)
        end
    end
end

function Extractor.extract(opts)
    opts = opts or {}
    local live_doc_settings = opts.doc_settings
    local file_path = opts.file_path

    local rating = nil
    local highlights = {}
    local bookmarks = {}
    local notes_count = 0
    local loaded_doc_settings = nil

    local function readFrom(doc_settings)
        if type(doc_settings) ~= "table" then
            return false
        end
        rating = extractRating(doc_settings)
        highlights, bookmarks, notes_count = extractAnnotations(doc_settings)
        return true
    end

    local has_read = readFrom(live_doc_settings)
    local has_signal = rating ~= nil or #highlights > 0 or #bookmarks > 0
    if not has_read or not has_signal then
        loaded_doc_settings = loadDocSettingsByPath(file_path)
        readFrom(loaded_doc_settings)
    end

    maybeCloseDocSettings(loaded_doc_settings, live_doc_settings)

    local payload = {
        rating = rating,
        highlights = highlights,
        bookmarks = bookmarks,
        counts = {
            rating_present = rating ~= nil,
            highlights_count = #highlights,
            notes_count = notes_count,
            bookmarks_count = #bookmarks,
        },
    }

    local ok, encoded = pcall(json.encode, payload)
    if ok and encoded ~= nil then
        payload.debug_json = encoded
    end
    return payload
end

return Extractor
