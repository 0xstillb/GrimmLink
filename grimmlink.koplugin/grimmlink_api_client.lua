local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local _ok_lfs, lfs = pcall(require, "lfs")
if not _ok_lfs then lfs = nil end
local _ok_ffi, ffi = pcall(require, "ffi")
if not _ok_ffi then ffi = nil end
if ffi then pcall(ffi.cdef, "int system(const char *command);") end

local unpack_values = table.unpack or unpack

local APIClient = {
    timeout = 25,
    secure_logs = false,
    debug_logging = false,
    api_prefix = "/api/grimmlink/v1",
}

local function redact_urls(message)
    if type(message) ~= "string" then
        return tostring(message)
    end
    return message:gsub("https?://[^%s]+", "[URL REDACTED]")
end

local function is_md5(value)
    return type(value) == "string" and #value == 32 and value:match("^[a-fA-F0-9]+$") ~= nil
end

local function md5(value)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and type(sha2.md5) == "function" then
        return sha2.md5(value or "")
    end
    return tostring(value or "")
end

local function normalizeNumericId(value)
    local num = tonumber(value)
    if num then
        return tostring(math.floor(num))
    end
    local raw = tostring(value or "")
    local digits = raw:match("^%-?%d+")
    if digits then
        return digits
    end
    return raw
end

function APIClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function APIClient:init(server_url, username, password, debug_logging)
    self.server_url = tostring(server_url or "")
    self.fallback_url = nil
    self.username = tostring(username or "")
    self.password = tostring(password or "")
    self.debug_logging = debug_logging == true
    self.secure_logs = debug_logging == true

    if self.server_url:sub(-1) == "/" then
        self.server_url = self.server_url:sub(1, -2)
    end
end

function APIClient:setFallbackUrl(url)
    if url and url ~= "" then
        self.fallback_url = tostring(url):gsub("/$", "")
    else
        self.fallback_url = nil
    end
end

function APIClient:getLastPrimaryFailure()
    return self._last_primary_failure
end

function APIClient:_resolveAuthKey()
    if self.password == "" then
        return ""
    end
    if is_md5(self.password) then
        return self.password:lower()
    end
    return md5(self.password)
end

function APIClient:log(level, ...)
    local args = { ... }
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redact_urls(args[i])
        end
    end

    if level == "warn" then
        logger.warn(unpack_values(args))
    elseif level == "err" then
        logger.err(unpack_values(args))
    elseif level == "dbg" then
        if self.debug_logging then logger.dbg(unpack_values(args)) end
    else
        logger.info(unpack_values(args))
    end
end

function APIClient:_urlEncode(value)
    if value == nil then
        return ""
    end
    local encoded = tostring(value)
    encoded = encoded:gsub("\n", "\r\n")
    encoded = encoded:gsub("([^%w %-%_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
    encoded = encoded:gsub(" ", "+")
    return encoded
end

function APIClient:_apiPath(path)
    return self.api_prefix .. tostring(path or "")
end

function APIClient:parseJSON(response_text)
    if not response_text or response_text == "" then
        return nil, "Empty response"
    end

    local ok, decoded = pcall(json.decode, response_text)
    if not ok then
        return nil, "Invalid JSON response"
    end

    return decoded, nil
end

function APIClient:extractErrorMessage(response_text, code)
    local decoded = nil
    if response_text and response_text ~= "" then
        decoded = select(1, self:parseJSON(response_text))
    end

    if decoded then
        if decoded.message then
            return decoded.message
        end
        if decoded.error then
            if type(decoded.error) == "string" then
                return decoded.error
            end
            if type(decoded.error) == "table" and decoded.error.message then
                return decoded.error.message
            end
        end
        if decoded.detail then
            return decoded.detail
        end
    end

    if response_text and response_text ~= "" and #response_text < 300 then
        return response_text
    end

    local fallback = {
        [400] = "Bad Request",
        [401] = "Unauthorized - Invalid credentials",
        [403] = "Forbidden - Access denied",
        [404] = "Not Found",
        [409] = "Conflict",
        [415] = "Unsupported Media Type",
        [422] = "Unprocessable Entity",
        [500] = "Internal Server Error",
        [503] = "Service Unavailable",
    }
    return fallback[code] or ("HTTP " .. tostring(code))
end

local function cloneHeaders(headers)
    local copied = {}
    for key, value in pairs(headers or {}) do
        copied[key] = value
    end
    return copied
end

local function summarizeUrlForLogs(url)
    local text = tostring(url or "")
    local protocol, host = text:match("^(https?://)([^/%?]+)")
    if protocol and host then
        return protocol .. host
    end
    return text:gsub("%?.*$", "")
end

function APIClient:_performRequest(base_url, method, path, body, extra_headers, timeout_sec)
    local url = tostring(base_url or "") .. tostring(path or "")
    self:log("info", "GrimmLink API:", method, summarizeUrlForLogs(url))

    local protocol = url:match("^https://") and https or http
    protocol.TIMEOUT = timeout_sec or self.timeout

    local headers = cloneHeaders(extra_headers)
    headers["Accept"] = headers["Accept"] or "application/json"

    if self.username ~= "" and self.password ~= "" then
        headers["x-auth-user"] = self.username
        headers["x-auth-key"] = self:_resolveAuthKey()
    end

    local request_body = nil
    local source = nil
    if body ~= nil then
        if type(body) == "table" then
            request_body = json.encode(body)
            headers["Content-Type"] = "application/json"
        else
            request_body = tostring(body)
        end
        headers["Content-Length"] = tostring(#request_body)
        source = ltn12.source.string(request_body)
    end

    local response_buffer = {}
    local ok, code, response_headers = protocol.request{
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(response_buffer),
    }

    if type(code) ~= "number" then
        local error_message = tostring(code or ok or "connection failed")
        self:log("warn", "GrimmLink API request failed:", error_message)
        return {
            success = false,
            code = nil,
            response = error_message,
            headers = response_headers,
            transport_error = true,
            url = url,
        }
    end

    local response_text = table.concat(response_buffer)
    local parsed = nil
    if response_text ~= "" then
        parsed = select(1, self:parseJSON(response_text))
    end

    if code >= 200 and code < 300 then
        return {
            success = true,
            code = code,
            response = parsed or response_text,
            headers = response_headers,
            transport_error = false,
            url = url,
        }
    end

    local error_message = self:extractErrorMessage(response_text, code)
    self:log("warn", "GrimmLink API HTTP", code, error_message)
    return {
        success = false,
        code = code,
        response = error_message,
        headers = response_headers,
        transport_error = false,
        url = url,
    }
end

function APIClient:request(method, path, body, extra_headers, timeout_sec)
    if not self.server_url or self.server_url == "" then
        return false, nil, "Server URL not configured", nil, {
            category = "url_missing",
            used_url = "",
            used_fallback = false,
            fallback_attempted = false,
            fallback_success = false,
        }
    end

    local primary = self:_performRequest(self.server_url, method, path, body, extra_headers, timeout_sec)
    local now_ts = os.time()
    local details = {
        primary_url = self.server_url .. path,
        used_url = primary.url,
        used_fallback = false,
        fallback_attempted = false,
        fallback_success = false,
    }

    if primary.transport_error and self.fallback_url and self.fallback_url ~= "" and self.fallback_url ~= self.server_url then
        self._last_primary_failure = {
            url = self.server_url,
            at = now_ts,
            error = primary.response,
        }
        details.fallback_attempted = true
        self:log("info", "GrimmLink API: primary failed, trying fallback:", summarizeUrlForLogs(self.fallback_url))
        local fallback_timeout = self.fallback_timeout
        if fallback_timeout == nil then
            fallback_timeout = timeout_sec or self.timeout
        end
        local fallback = self:_performRequest(self.fallback_url, method, path, body, extra_headers, fallback_timeout)
        details.used_url = fallback.url
        details.used_fallback = true
        details.fallback_success = not fallback.transport_error
        details.fallback_http_code = fallback.code
        details.fallback_error = fallback.response
        if fallback.success then
            self:log("info", "GrimmLink API: remote fallback succeeded")
        elseif fallback.transport_error then
            self:log("warn", "GrimmLink API: remote fallback failed")
        end
        return fallback.success, fallback.code, fallback.response, fallback.headers, details
    end

    if primary.success and type(self._last_primary_failure) == "table"
        and tostring(self._last_primary_failure.url or "") == tostring(self.server_url) then
        self._last_primary_failure = nil
    end

    return primary.success, primary.code, primary.response, primary.headers, details
end

function APIClient:testAuth(timeout_sec)
    if self.username == "" then
        return false, "Username not configured"
    end
    if self.password == "" then
        return false, "Password not configured"
    end

    local success, code, response, _headers, details = self:request(
        "GET",
        self:_apiPath("/auth"),
        nil,
        nil,
        timeout_sec
    )
    if success then
        return true, response, code, details
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code, details
end

function APIClient:getBookByHash(book_hash)
    local success, code, response = self:request(
        "GET",
        self:_apiPath("/books/by-hash/" .. self:_urlEncode(book_hash))
    )
    if success and type(response) == "table" then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getProgress(book_hash, timeout_sec)
    local success, code, response = self:request(
        "GET",
        self:_apiPath("/syncs/progress/" .. self:_urlEncode(book_hash)),
        nil,
        nil,
        timeout_sec
    )
    if success and type(response) == "table" then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:updateProgress(progress_payload)
    local success, code, response = self:request("PUT", self:_apiPath("/syncs/progress"), progress_payload)
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:submitSession(session_payload)
    local success, code, response = self:request("POST", self:_apiPath("/reading-sessions"), session_payload)
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:submitSessionBatch(book_id, book_hash, book_type, device, device_id, sessions)
    local payload = {
        bookId = tonumber(book_id) or book_id,
        bookHash = book_hash,
        bookType = book_type or "EPUB",
        device = device,
        deviceId = device_id,
        sessions = sessions,
    }

    local success, code, response = self:request("POST", self:_apiPath("/reading-sessions/batch"), payload)
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

local function readPrefix(path, max_bytes)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local data = fh:read(max_bytes or 512)
    fh:close()
    return data
end

local function readTail(path, max_bytes)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local size = fh:seek("end")
    if not size then
        fh:close()
        return nil
    end
    local window = tonumber(max_bytes) or 4096
    if window < 256 then
        window = 256
    end
    local start = size - window
    if start < 0 then
        start = 0
    end
    fh:seek("set", start)
    local data = fh:read("*a")
    fh:close()
    return data
end

local function looksLikeTextErrorPayload(prefix)
    local sample = tostring(prefix or ""):lower()
    if sample == "" then
        return false
    end
    if sample:find("<!doctype html", 1, true) then return true end
    if sample:find("<html", 1, true) then return true end
    if sample:find("{\"timestamp\":", 1, true) then return true end
    if sample:find("\"status\":", 1, true) and sample:find("\"error\":", 1, true) then return true end
    return false
end

local function canonicalFormatToken(value)
    local raw = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then
        return nil
    end

    raw = raw:lower():gsub("^%.", ""):gsub("[?#].*$", "")
    local slash_value = raw:match("/([%w%+%-%.]+)$")
    if slash_value and slash_value ~= "" then
        raw = slash_value
    end

    if raw == "epub+zip" or raw == "x-epub+zip" then return "epub" end
    if raw == "x-pdf" then return "pdf" end
    if raw == "octet-stream" or raw == "binary" then return nil end
    return raw ~= "" and raw or nil
end

local function isZipLikeExpectedFormat(fmt)
    local value = canonicalFormatToken(fmt)
    return value == "epub" or value == "cbz" or value == "zip"
end

local function isPdfExpectedFormat(fmt)
    local value = canonicalFormatToken(fmt)
    return value == "pdf"
end

local function hasPrefix(data, signature)
    if type(data) ~= "string" or type(signature) ~= "string" then
        return false
    end
    return data:sub(1, #signature) == signature
end

local function normalizeBookFormat(value)
    local token = canonicalFormatToken(value)
    if not token then
        return nil
    end
    return token:upper()
end

local function extractExtension(value)
    local raw = tostring(value or ""):gsub("[?#].*$", "")
    if raw == "" then
        return nil
    end
    local ext = raw:match("%.([%w%+%-]+)$") or raw:match("^([%w%+%-]+)$")
    if not ext or ext == "" then
        return nil
    end
    return canonicalFormatToken(ext)
end

local function inferExpectedFormat(expected_format, dest_path)
    local normalized = canonicalFormatToken(expected_format)
    if normalized then
        return normalized
    end
    local inferred = extractExtension(dest_path)
    if inferred then
        return inferred
    end
    return nil
end

local function hasPdfEofMarker(path)
    local tail = readTail(path, 8192)
    if type(tail) ~= "string" or tail == "" then
        return false
    end
    return tail:find("%%EOF", 1, true) ~= nil
end

local function normalizeShelfType(value)
    local shelf_type = tostring(value or "regular"):lower()
    if shelf_type ~= "magic" then
        return "regular"
    end
    return shelf_type
end

local function normalizeMetadataCursor(value)
    if type(value) ~= "string" then
        return nil
    end
    local text = value:match("^%s*(.-)%s*$")
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

function APIClient:buildMetadataBatchPayload(book_id, book_hash, book_file_id, file_format, device, device_id, rating, annotations, bookmarks, pull_since, pull_limit)
    local normalized_annotations = nil
    if type(annotations) == "table" and #annotations > 0 then
        normalized_annotations = annotations
    end

    local normalized_bookmarks = nil
    if type(bookmarks) == "table" and #bookmarks > 0 then
        normalized_bookmarks = bookmarks
    end

    local normalized_cursor = normalizeMetadataCursor(pull_since)

    return {
        schemaVersion = 1,
        syncMode = "incremental",
        bookId = tonumber(book_id) or book_id,
        bookHash = book_hash,
        bookFileId = tonumber(book_file_id) or book_file_id,
        fileFormat = file_format or "EPUB",
        device = device,
        deviceId = device_id,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        -- Keep legacy `since` for the current Instant-based backend contract,
        -- and send `cursor` for the next stable cursor contract. Only valid
        -- ISO-8601 timestamp cursors are sent; JSON-null sentinels and legacy
        -- `function: 0x...` values are omitted entirely.
        since = normalized_cursor,
        cursor = normalized_cursor,
        limit = pull_limit,
        rating = rating,
        annotations = normalized_annotations,
        bookmarks = normalized_bookmarks,
    }
end

function APIClient:buildMetadataPullPayload(book_id, book_hash, book_file_id, file_format, device, device_id, pull_since, pull_limit, item_type)
    local payload = self:buildMetadataBatchPayload(
        book_id,
        book_hash,
        book_file_id,
        file_format,
        device,
        device_id,
        nil,
        {},
        {},
        pull_since,
        pull_limit
    )
    payload.syncMode = "pull"
    payload.type = item_type
    return payload
end

function APIClient:buildMetadataPullPath(book_id, book_hash, book_file_id, cursor, limit, item_type)
    local query = {}
    local normalized_hash = tostring(book_hash or ""):match("^%s*(.-)%s*$")
    if normalized_hash ~= "" then
        query[#query + 1] = "bookHash=" .. self:_urlEncode(normalized_hash)
    elseif book_id ~= nil and tostring(book_id) ~= "" then
        query[#query + 1] = "bookId=" .. self:_urlEncode(normalizeNumericId(book_id))
    elseif book_file_id ~= nil and tostring(book_file_id) ~= "" then
        query[#query + 1] = "bookFileId=" .. self:_urlEncode(normalizeNumericId(book_file_id))
    else
        return nil, "Book context is required"
    end

    local normalized_cursor = normalizeMetadataCursor(cursor)
    if normalized_cursor then
        query[#query + 1] = "cursor=" .. self:_urlEncode(normalized_cursor)
    end

    local normalized_limit = tonumber(limit)
    if normalized_limit then
        normalized_limit = math.max(1, math.min(math.floor(normalized_limit), 500))
        query[#query + 1] = "limit=" .. tostring(normalized_limit)
    end

    local normalized_type = tostring(item_type or ""):match("^%s*(.-)%s*$"):lower()
    if normalized_type ~= "" then
        query[#query + 1] = "type=" .. self:_urlEncode(normalized_type)
    end

    return self:_apiPath("/syncs/metadata") .. "?" .. table.concat(query, "&")
end

function APIClient:pullMetadata(book_id, book_hash, book_file_id, cursor, limit, item_type)
    local path, path_error = self:buildMetadataPullPath(
        book_id,
        book_hash,
        book_file_id,
        cursor,
        limit,
        item_type
    )
    if not path then
        return false, path_error or "Book context is required", nil
    end
    local success, code, response = self:request("GET", path)
    if success and type(response) == "table" then
        return true, response, code
    end
    if success then
        return false, "Malformed response", code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:submitMetadataBatch(payload)
    local success, code, response = self:request("POST", self:_apiPath("/syncs/metadata/batch"), payload)
    if success then
        if type(response) == "table" and type(response.push) == "table" and response.results == nil then
            response.results = response.push.results
        end
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:pullMetadataBatch(payload)
    return self:submitMetadataBatch(payload)
end

function APIClient:normalizeShelfObject(shelf)
    if type(shelf) ~= "table" then
        return nil
    end
    local shelf_id = tonumber(shelf.id or shelf.shelfId or shelf.shelf_id)
    local shelf_type = normalizeShelfType(shelf.type or shelf.shelf_type)
    local normalized = {
        id = shelf_id,
        shelfId = shelf_id,
        name = shelf.name or shelf.title,
        type = shelf_type,
        shelfType = shelf_type,
        bookCount = shelf.bookCount or shelf.book_count,
        description = shelf.description,
        visibility = shelf.visibility,
    }
    return normalized
end

function APIClient:normalizeShelfBookObject(book)
    if type(book) ~= "table" then
        return nil
    end
    local resolved_file_name = book.fileName or book.originalFileName or book.original_file_name
    local extension = extractExtension(book.extension) or extractExtension(resolved_file_name)
    local format = normalizeBookFormat(
        book.fileFormat or book.file_format or book.bookType or book.book_type or extension
    )
    local normalized = {
        bookId = tonumber(book.bookId or book.id or book.book_id),
        bookFileId = tonumber(book.bookFileId or book.book_file_id),
        title = book.title,
        author = book.author,
        fileName = resolved_file_name,
        originalFileName = book.originalFileName or book.fileName or book.original_file_name,
        extension = extension,
        fileFormat = format,
        fileSizeKb = tonumber(book.fileSizeKb or book.file_size_kb),
        fileSize = tonumber(book.fileSize or book.file_size),
        seriesName = book.seriesName or book.series_name,
        seriesNumber = tonumber(book.seriesNumber or book.series_number),
        bookHash = book.bookHash or book.hash,
        hash = book.hash or book.bookHash,
    }
    return normalized
end

function APIClient:getShelves(shelf_type)
    local path = self:_apiPath("/shelves")
    local normalized_type = normalizeShelfType(shelf_type)
    if shelf_type ~= nil and shelf_type ~= "" then
        path = path .. "?type=" .. self:_urlEncode(normalized_type)
    end

    local success, code, response = self:request("GET", path)
    if success and type(response) == "table" then
        local raw_list = response
        if type(response.content) == "table" then
            raw_list = response.content
        elseif type(response.items) == "table" then
            raw_list = response.items
        end

        local normalized = {}
        if type(raw_list) == "table" then
            for _, shelf in ipairs(raw_list) do
                local normalized_shelf = self:normalizeShelfObject(shelf)
                if normalized_shelf then
                    normalized[#normalized + 1] = normalized_shelf
                end
            end
        end
        return true, normalized, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getShelfBooks(shelf_id, shelf_type)
    local normalized_type = normalizeShelfType(shelf_type)
    local primary_path = self:_apiPath("/shelves/" .. normalized_type .. "/" .. tostring(shelf_id) .. "/books")
    local success, code, response = self:request(
        "GET",
        primary_path
    )

    -- Backward compatibility for older backends without typed shelf route.
    if not success and normalized_type == "regular" and tonumber(code) == 404 then
        success, code, response = self:request(
            "GET",
            self:_apiPath("/shelves/" .. tostring(shelf_id) .. "/books")
        )
    end

    if success and type(response) == "table" then
        local raw_list = response
        if type(response.content) == "table" then
            raw_list = response.content
        elseif type(response.items) == "table" then
            raw_list = response.items
        end

        local normalized_books = {}
        if type(raw_list) == "table" then
            for _, book in ipairs(raw_list) do
                local normalized_book = self:normalizeShelfBookObject(book)
                if normalized_book then
                    normalized_books[#normalized_books + 1] = normalized_book
                end
            end
        end
        return true, normalized_books, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getBooksInShelf(shelf_id, shelf_type)
    return self:getShelfBooks(shelf_id, shelf_type)
end

--- Download a book file with progress reporting.
-- opts (optional table):
--   timeout         number   total HTTP timeout in seconds (default: auto-scaled)
--   on_progress     function(bytes_so_far, total_bytes)  called periodically
--   is_cancelled    function() → bool  checked between chunks; aborts if true
--   expected_size_kb number   hint for timeout scaling when Content-Length absent
function APIClient:downloadBookToFile(book_id, dest_path, timeout_sec_or_opts)
    -- Accept both old-style (timeout_sec) and new-style (opts table) signatures.
    local opts = {}
    if type(timeout_sec_or_opts) == "table" then
        opts = timeout_sec_or_opts
    elseif type(timeout_sec_or_opts) == "number" then
        opts.timeout = timeout_sec_or_opts
    end

    if not self.server_url or self.server_url == "" then
        return false, "Server URL not configured"
    end

    local tmp_path = dest_path .. ".tmp"
    local expected_format = inferExpectedFormat(opts.expected_format, dest_path)
    local file, err = io.open(tmp_path, "wb")
    if not file then
        return false, "Cannot open temp file: " .. tostring(err)
    end

    local url = self.server_url .. self:_apiPath("/books/" .. tostring(book_id) .. "/download")
    self:log("info", "GrimmLink API: GET (binary)", url)

    -- Auto-scale timeout based on expected file size.
    -- 120s base + 1s per MB, minimum 120s.
    local timeout = opts.timeout
    if not timeout then
        local est_kb = tonumber(opts.expected_size_kb) or 0
        timeout = math.max(120, 120 + math.ceil(est_kb / 1024))
        -- Cap at 30 minutes for very large files.
        if timeout > 1800 then timeout = 1800 end
    end

    local protocol = url:match("^https://") and https or http
    protocol.TIMEOUT = timeout

    -- Progress-tracking sink: wraps file writing with byte counting.
    local bytes_written = 0
    -- Use expected_size_kb from the book metadata as total size hint
    -- (Content-Length isn't available until after the request completes in LuaSocket).
    local total_bytes   = opts.expected_size_kb and (tonumber(opts.expected_size_kb) or 0) * 1024 or nil
    if total_bytes and total_bytes <= 0 then total_bytes = nil end
    local on_progress   = opts.on_progress
    local is_cancelled  = opts.is_cancelled
    local last_progress_time = 0

    local file_closed = false
    local function close_file()
        if not file_closed then
            file_closed = true
            file:close()
        end
    end

    local function progress_sink(chunk, sink_err)
        if chunk == nil then
            -- EOF: close file
            close_file()
            return nil
        end
        if chunk == "" then
            return 1
        end
        -- Check cancellation periodically (every chunk).
        if is_cancelled and is_cancelled() then
            close_file()
            os.remove(tmp_path)
            return nil, "cancelled"
        end
        local write_ok, write_err = file:write(chunk)
        if not write_ok then
            close_file()
            return nil, write_err
        end
        bytes_written = bytes_written + #chunk
        -- Report progress at most once per second to avoid overhead.
        local now = os.time()
        if on_progress and now ~= last_progress_time then
            last_progress_time = now
            on_progress(bytes_written, total_bytes)
        end
        return 1
    end

    -- Use a custom sink instead of ltn12.sink.file so we can track progress.
    local ok, code, response_headers = protocol.request{
        url = url,
        method = "GET",
        headers = {
            ["x-auth-user"] = self.username,
            ["x-auth-key"] = self:_resolveAuthKey(),
            ["Accept"] = "application/octet-stream",
        },
        sink = progress_sink,
    }

    -- Fire one final progress update so the UI shows 100%.
    if on_progress and bytes_written > 0 then
        on_progress(bytes_written, total_bytes or bytes_written)
    end

    -- Ensure file is closed regardless of how the request ended.
    close_file()

    if type(code) ~= "number" or code < 200 or code >= 300 then
        os.remove(tmp_path)
        -- Distinguish cancellation from real errors.
        if is_cancelled and is_cancelled() then
            return false, "Download cancelled"
        end
        local msg = "Download failed: HTTP " .. tostring(code or ok or "connection failed")
        self:log("warn", "GrimmLink download error:", msg)
        return false, msg
    end

    if bytes_written <= 0 then
        os.remove(tmp_path)
        return false, "Downloaded file is empty"
    end

    local content_type = ""
    if type(response_headers) == "table" then
        content_type = tostring(response_headers["content-type"] or response_headers["Content-Type"] or ""):lower()
    end
    if content_type:find("text/html", 1, true) or content_type:find("application/json", 1, true) then
        os.remove(tmp_path)
        return false, "Downloaded payload is not a book file (content-type=" .. content_type .. ")"
    end

    local prefix = readPrefix(tmp_path, 512)
    if looksLikeTextErrorPayload(prefix) then
        os.remove(tmp_path)
        return false, "Downloaded payload looks like an error page"
    end
    if isZipLikeExpectedFormat(expected_format) and not hasPrefix(prefix, "PK\003\004") then
        os.remove(tmp_path)
        return false, "Downloaded file signature is invalid for EPUB/CBZ"
    end
    if isPdfExpectedFormat(expected_format) and not hasPrefix(prefix, "%PDF-") then
        os.remove(tmp_path)
        return false, "Downloaded file signature is invalid for PDF"
    end
    if isPdfExpectedFormat(expected_format) and not hasPdfEofMarker(tmp_path) then
        os.remove(tmp_path)
        return false, "Downloaded PDF appears incomplete (missing EOF marker)"
    end

    local expected_size_kb = tonumber(opts.expected_size_kb) or 0
    if expected_size_kb > 0 then
        local expected_bytes = expected_size_kb * 1024
        local min_reasonable = math.max(4096, math.floor(expected_bytes * 0.10))
        if bytes_written < min_reasonable then
            os.remove(tmp_path)
            return false, "Downloaded file is unexpectedly small (" .. tostring(bytes_written) .. " bytes)"
        end
    end

    local rename_ok, rename_err = os.rename(tmp_path, dest_path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, "Failed to save file: " .. tostring(rename_err)
    end

    return true, nil
end

-- ---------------------------------------------------------------------------
-- Async (non-blocking) download via background curl subprocess.
-- The main Lua thread is never blocked, so UIManager keeps processing events.
-- ---------------------------------------------------------------------------

--- Shell-escape a string for single-quoted sh arguments.
local function shquote(s)
    if not s then return "''" end
    return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end

local function readTextFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local value = file:read("*a")
    file:close()
    return value
end

local function removeAsyncRequestArtifacts(handle)
    if not handle then
        return
    end
    os.remove(handle.response_path)
    os.remove(handle.http_code_path)
    os.remove(handle.exit_code_path)
    os.remove(handle.pid_path)
    os.remove(handle.script_path)
end

--- Start a metadata GET in a background curl/wget process.
--- Returns a pollable handle, or nil + an error string.
function APIClient:startAsyncMetadataPull(book_id, book_hash, book_file_id, cursor, limit, item_type, opts)
    opts = opts or {}
    if not self.server_url or self.server_url == "" then
        return nil, "Server URL not configured"
    end
    if not self:isAsyncDownloadAvailable() then
        return nil, "Background HTTP tools are unavailable"
    end

    local path, path_error = self:buildMetadataPullPath(
        book_id,
        book_hash,
        book_file_id,
        cursor,
        limit,
        item_type
    )
    if not path then
        return nil, path_error or "Book context is required"
    end

    local prefix = opts.temp_prefix or os.tmpname()
    if not prefix or prefix == "" then
        return nil, "Cannot allocate metadata pull temporary files"
    end
    os.remove(prefix)

    local response_path = prefix .. ".json"
    local http_code_path = prefix .. ".http"
    local exit_code_path = prefix .. ".exit"
    local pid_path = prefix .. ".pid"
    local script_path = prefix .. ".sh"
    local timeout = math.max(5, math.min(math.floor(tonumber(opts.timeout) or self.timeout or 25), 60))
    local primary_url = self.server_url .. path
    local fallback_url = ""
    if self.fallback_url and self.fallback_url ~= "" and self.fallback_url ~= self.server_url then
        fallback_url = self.fallback_url .. path
    end
    local auth_user = self.username or ""
    local auth_key = self:_resolveAuthKey() or ""

    local script = string.format([[#!/bin/sh
export GL_USER=%s
export GL_KEY=%s
REQ_TIMEOUT=%d
REQ_PRIMARY=%s
REQ_FALLBACK=%s
REQ_BODY=%s
REQ_HTTP=%s
REQ_EXIT=%s
REQ_PID=%s

run_curl() {
  REQ_URL="$1"
  curl -s -S --max-time "$REQ_TIMEOUT" \
    -H "x-auth-user: $GL_USER" \
    -H "x-auth-key: $GL_KEY" \
    -H "Accept: application/json" \
    -o "$REQ_BODY" \
    -w "%%{http_code}" \
    "$REQ_URL" > "$REQ_HTTP" &
  echo $! > "$REQ_PID"
  wait $!
  return $?
}

run_wget() {
  REQ_URL="$1"
  REQ_HEADERS="${REQ_HTTP}.headers"
  wget -q --timeout="$REQ_TIMEOUT" --server-response \
    --header="x-auth-user: $GL_USER" \
    --header="x-auth-key: $GL_KEY" \
    --header="Accept: application/json" \
    -O "$REQ_BODY" \
    "$REQ_URL" 2> "$REQ_HEADERS" &
  echo $! > "$REQ_PID"
  wait $!
  REQ_STATUS=$?
  awk '/^  HTTP\// { code=$2 } END { if (code != "") print code; else print 0 }' "$REQ_HEADERS" > "$REQ_HTTP"
  rm -f "$REQ_HEADERS"
  return $REQ_STATUS
}

run_request() {
  if command -v curl >/dev/null 2>&1; then
    run_curl "$1"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    run_wget "$1"
    return $?
  fi
  echo 127 > "$REQ_EXIT"
  return 127
}

run_request "$REQ_PRIMARY"
REQ_STATUS=$?
REQ_HTTP_CODE=$(cat "$REQ_HTTP" 2>/dev/null)
if [ "$REQ_STATUS" -ne 0 ] && { [ -z "$REQ_HTTP_CODE" ] || [ "$REQ_HTTP_CODE" = "0" ] || [ "$REQ_HTTP_CODE" = "000" ]; } && [ -n "$REQ_FALLBACK" ]; then
  rm -f "$REQ_BODY" "$REQ_HTTP"
  run_request "$REQ_FALLBACK"
  REQ_STATUS=$?
fi
echo "$REQ_STATUS" > "$REQ_EXIT"
]],
        shquote(auth_user),
        shquote(auth_key),
        timeout,
        shquote(primary_url),
        shquote(fallback_url),
        shquote(response_path),
        shquote(http_code_path),
        shquote(exit_code_path),
        shquote(pid_path)
    )

    local prepare_status = ffi.C.system("umask 077; : > " .. shquote(script_path) .. " && chmod 700 " .. shquote(script_path))
    if prepare_status ~= 0 then
        return nil, "Cannot prepare metadata pull script"
    end
    local script_file = io.open(script_path, "w")
    if not script_file then
        os.remove(script_path)
        return nil, "Cannot create metadata pull script"
    end
    script_file:write(script)
    script_file:close()

    local handle = {
        response_path = response_path,
        http_code_path = http_code_path,
        exit_code_path = exit_code_path,
        pid_path = pid_path,
        script_path = script_path,
        started_at = os.time(),
        timeout = timeout,
    }
    ffi.C.system("sh " .. shquote(script_path) .. " </dev/null >/dev/null 2>&1 &")
    return handle
end

--- Poll a background metadata pull.
--- Returns status, response, HTTP code, details.
function APIClient:pollAsyncMetadataPull(handle)
    if not handle then
        return "failed", "Missing metadata pull handle", nil, { transport_error = true }
    end

    local exit_text = readTextFile(handle.exit_code_path)
    if exit_text == nil then
        if os.time() - handle.started_at > handle.timeout + 10 then
            self:cancelAsyncMetadataPull(handle)
            return "timeout", "Metadata pull timed out", nil, { transport_error = true }
        end
        local response_size = 0
        if lfs then
            local attr = lfs.attributes(handle.response_path)
            response_size = attr and attr.size or 0
        end
        return "running", nil, nil, { response_bytes = response_size }
    end

    local exit_code = tonumber(exit_text:match("%-?%d+")) or -1
    local http_text = readTextFile(handle.http_code_path) or ""
    local http_code = tonumber(http_text:match("%d%d%d"))
    local response_text = readTextFile(handle.response_path) or ""
    local parsed = nil
    if response_text ~= "" then
        parsed = select(1, self:parseJSON(response_text))
    end
    removeAsyncRequestArtifacts(handle)

    if exit_code == 0 and http_code and http_code >= 200 and http_code < 300 then
        if type(parsed) ~= "table" then
            return "failed", "Malformed response", http_code, {
                transport_error = false,
                malformed_response = true,
                exit_code = exit_code,
            }
        end
        return "done", parsed, http_code, {
            transport_error = false,
            exit_code = exit_code,
        }
    end
    if http_code and http_code > 0 then
        return "failed", self:extractErrorMessage(response_text, http_code), http_code, {
            transport_error = false,
            exit_code = exit_code,
        }
    end
    return "failed",
        response_text ~= "" and response_text or ("Background request failed (exit " .. tostring(exit_code) .. ")"),
        nil,
        { transport_error = true, exit_code = exit_code }
end

function APIClient:cancelAsyncMetadataPull(handle)
    if not handle then
        return
    end
    local pid = tonumber((readTextFile(handle.pid_path) or ""):match("%d+"))
    if pid and ffi then
        ffi.C.system("kill " .. tostring(pid) .. " 2>/dev/null")
        ffi.C.system("kill -9 " .. tostring(pid) .. " 2>/dev/null")
    end
    removeAsyncRequestArtifacts(handle)
end

--- Check if async download is available (curl or wget + ffi.C.system).
-- Caches the result so the check runs only once per session.
function APIClient:isAsyncDownloadAvailable()
    if self._async_available ~= nil then
        return self._async_available
    end
    if not ffi then
        self:log("warn", "GrimmLink: FFI not available, async download disabled")
        self._async_available = false
        return false
    end
    -- Check if curl or wget exists.
    local has_tool = ffi.C.system("command -v curl >/dev/null 2>&1") == 0
                  or ffi.C.system("command -v wget >/dev/null 2>&1") == 0
    if not has_tool then
        -- Try busybox-style check
        has_tool = ffi.C.system("which curl >/dev/null 2>&1") == 0
                or ffi.C.system("which wget >/dev/null 2>&1") == 0
    end
    self._async_available = has_tool
    if not has_tool then
        self:log("warn", "GrimmLink: no curl/wget found, async download disabled")
    else
        self:log("info", "GrimmLink: async download available (curl/wget found)")
    end
    return has_tool
end

--- Start a background download and return a handle for polling.
-- Returns: handle table, or nil + error string.
function APIClient:startAsyncDownload(book_id, dest_path, opts)
    opts = opts or {}
    if not self.server_url or self.server_url == "" then
        return nil, "Server URL not configured"
    end

    local tmp_path    = dest_path .. ".tmp"
    local pid_path    = dest_path .. ".pid"
    local code_path   = dest_path .. ".exitcode"
    local script_path = dest_path .. ".dl.sh"
    local expected_format = inferExpectedFormat(opts.expected_format, dest_path)

    -- Remove stale artifacts from a previous interrupted download.
    os.remove(tmp_path)
    os.remove(pid_path)
    os.remove(code_path)
    os.remove(script_path)

    local url = self.server_url .. self:_apiPath("/books/" .. tostring(book_id) .. "/download")
    self:log("info", "GrimmLink API: async GET (curl)", url)

    -- Auto-scale timeout: 180s base + 1s per MB, cap at 45 minutes.
    local timeout = opts.timeout
    if not timeout then
        local est_kb = tonumber(opts.expected_size_kb) or 0
        timeout = math.max(180, 180 + math.ceil(est_kb / 1024))
        if timeout > 2700 then timeout = 2700 end
    end

    -- Write a small shell script to avoid nested quoting issues.
    -- The script backgrounds curl and captures its PID with $! so that
    -- cancellation kills curl directly (killing the shell PID wouldn't
    -- propagate to the curl child process).
    -- Auth credentials are passed via environment variables to avoid
    -- shell interpretation of special characters ($, `, \) in passwords.
    local auth_user = self.username or ""
    local auth_key  = self:_resolveAuthKey() or ""

    -- Build a shell script that tries curl first, then wget as fallback.
    -- Both are backgrounded and their PID is captured via $! for cancel support.
    local script = string.format([[#!/bin/sh
export GL_USER=%s
export GL_KEY=%s
DL_TIMEOUT=%d
DL_OUT=%s
DL_URL=%s
DL_PID=%s
DL_CODE=%s

if command -v curl >/dev/null 2>&1; then
  curl -s -S --fail --max-time "$DL_TIMEOUT" \
    -H "x-auth-user: $GL_USER" \
    -H "x-auth-key: $GL_KEY" \
    -H "Accept: application/octet-stream" \
    -o "$DL_OUT" \
    "$DL_URL" &
  echo $! > "$DL_PID"
  wait $!
  echo $? > "$DL_CODE"
elif command -v wget >/dev/null 2>&1; then
  wget -q --timeout="$DL_TIMEOUT" \
    --header="x-auth-user: $GL_USER" \
    --header="x-auth-key: $GL_KEY" \
    --header="Accept: application/octet-stream" \
    -O "$DL_OUT" \
    "$DL_URL" &
  echo $! > "$DL_PID"
  wait $!
  echo $? > "$DL_CODE"
else
  echo 127 > "$DL_CODE"
fi
]],
        shquote(auth_user),
        shquote(auth_key),
        timeout,
        shquote(tmp_path),
        shquote(url),
        shquote(pid_path),
        shquote(code_path)
    )

    local sf = io.open(script_path, "w")
    if not sf then
        return nil, "Cannot create download script"
    end
    sf:write(script)
    sf:close()

    -- Make executable and run in background.
    -- IMPORTANT: KOReader wraps os.execute with a command runner that
    -- captures stdout/stderr and waits for the process to finish — the
    -- shell & operator has no effect.  We bypass that by calling the C
    -- system() function directly via FFI.  system("cmd &") forks a
    -- background shell and returns immediately.
    ffi.C.system("chmod +x " .. shquote(script_path))
    ffi.C.system("sh " .. shquote(script_path) .. " </dev/null >/dev/null 2>&1 &")
    self:log("info", "GrimmLink: async download launched via ffi.C.system, script=" .. script_path)

    return {
        dest_path       = dest_path,
        tmp_path        = tmp_path,
        pid_path        = pid_path,
        code_path       = code_path,
        script_path     = script_path,
        expected_bytes  = opts.expected_size_kb and (tonumber(opts.expected_size_kb) or 0) * 1024 or nil,
        expected_format = expected_format,
        started_at      = os.time(),
        timeout         = timeout,
    }
end

--- Poll an async download handle.
-- Returns: status, bytes_so_far, total_bytes, exit_code
-- status: "running", "done", "failed", "timeout"
-- exit_code: nil while running, number on completion (0=ok, 127=no curl/wget)
function APIClient:pollAsyncDownload(handle)
    if not handle then return "failed", 0, 0, nil end

    -- Check how many bytes have been written so far.
    local bytes_so_far = 0
    if lfs then
        local attr = lfs.attributes(handle.tmp_path)
        bytes_so_far = attr and attr.size or 0
    else
        local f = io.open(handle.tmp_path, "r")
        if f then bytes_so_far = f:seek("end") or 0; f:close() end
    end
    local total_bytes  = handle.expected_bytes

    -- Check if downloader has finished by looking for the exit code file.
    local code_exists = lfs and lfs.attributes(handle.code_path)
    if not code_exists then
        local f = io.open(handle.code_path, "r")
        if f then code_exists = true; f:close() end
    end
    if code_exists then
        local f = io.open(handle.code_path, "r")
        if f then
            local code_str = f:read("*l")
            f:close()
            local exit_code = tonumber(code_str)
            -- Clean up control files.
            os.remove(handle.pid_path)
            os.remove(handle.code_path)
            if handle.script_path then os.remove(handle.script_path) end

            if exit_code == 0 then
                local prefix = readPrefix(handle.tmp_path, 512)
                if looksLikeTextErrorPayload(prefix) then
                    self:log("warn", "GrimmLink: async payload looks like an error page")
                    os.remove(handle.tmp_path)
                    return "failed", bytes_so_far, total_bytes, exit_code
                end
                if isZipLikeExpectedFormat(handle.expected_format) and not hasPrefix(prefix, "PK\003\004") then
                    self:log("warn", "GrimmLink: async payload signature invalid for EPUB/CBZ")
                    os.remove(handle.tmp_path)
                    return "failed", bytes_so_far, total_bytes, exit_code
                end
                if isPdfExpectedFormat(handle.expected_format) and not hasPrefix(prefix, "%PDF-") then
                    self:log("warn", "GrimmLink: async payload signature invalid for PDF")
                    os.remove(handle.tmp_path)
                    return "failed", bytes_so_far, total_bytes, exit_code
                end
                if isPdfExpectedFormat(handle.expected_format) and not hasPdfEofMarker(handle.tmp_path) then
                    self:log("warn", "GrimmLink: async payload appears incomplete for PDF (missing EOF marker)")
                    os.remove(handle.tmp_path)
                    return "failed", bytes_so_far, total_bytes, exit_code
                end
                if bytes_so_far <= 0 then
                    self:log("warn", "GrimmLink: async payload is empty")
                    os.remove(handle.tmp_path)
                    return "failed", bytes_so_far, total_bytes, exit_code
                end
                if handle.expected_bytes and handle.expected_bytes > 0 then
                    local min_reasonable = math.max(4096, math.floor(handle.expected_bytes * 0.10))
                    if bytes_so_far < min_reasonable then
                        self:log("warn", "GrimmLink: async payload unexpectedly small")
                        os.remove(handle.tmp_path)
                        return "failed", bytes_so_far, total_bytes, exit_code
                    end
                end
                -- Download succeeded. Rename tmp → final.
                local rename_ok, rename_err = os.rename(handle.tmp_path, handle.dest_path)
                if rename_ok then
                    return "done", bytes_so_far, total_bytes, exit_code
                else
                    self:log("warn", "GrimmLink: rename failed:", rename_err)
                    os.remove(handle.tmp_path)
                    return "failed", bytes_so_far, total_bytes, exit_code
                end
            else
                -- Download tool failed.
                local reason = "exit code " .. tostring(exit_code)
                if exit_code == 127 then
                    reason = "curl/wget not found on device"
                elseif exit_code == 22 then
                    reason = "HTTP error (curl 22)"
                elseif exit_code == 28 then
                    reason = "timeout (curl 28)"
                elseif exit_code == 7 then
                    reason = "connection refused (curl 7)"
                elseif exit_code == 6 then
                    reason = "DNS lookup failed (curl 6)"
                end
                self:log("warn", "GrimmLink: download failed:", reason)
                os.remove(handle.tmp_path)
                return "failed", bytes_so_far, total_bytes, exit_code
            end
        end
    end

    -- Check for timeout (safety net in case curl's --max-time doesn't fire).
    local elapsed = os.time() - handle.started_at
    if elapsed > handle.timeout + 30 then
        -- Force-kill any lingering curl process.
        self:cancelAsyncDownload(handle)
        return "timeout", bytes_so_far, total_bytes
    end

    return "running", bytes_so_far, total_bytes
end

--- Cancel an async download by killing the curl process.
-- The PID file now contains curl's actual PID (not the shell wrapper),
-- so SIGTERM goes directly to curl.
function APIClient:cancelAsyncDownload(handle)
    if not handle then return end

    -- Try to read the PID and kill the curl process.
    -- Use ffi.C.system to bypass KOReader's blocking os.execute wrapper.
    local f = io.open(handle.pid_path, "r")
    if f then
        local pid_str = f:read("*l")
        f:close()
        local pid = tonumber(pid_str)
        if pid then
            ffi.C.system("kill " .. tostring(pid) .. " 2>/dev/null")
            -- If SIGTERM didn't work, force kill after a brief pause.
            ffi.C.system("kill -9 " .. tostring(pid) .. " 2>/dev/null")
        end
    end

    -- Clean up all artifacts.
    os.remove(handle.tmp_path)
    os.remove(handle.pid_path)
    os.remove(handle.code_path)
    if handle.script_path then
        os.remove(handle.script_path)
    end
end

function APIClient:removeBookFromShelf(shelf_id, book_id, shelf_type)
    local normalized_type = normalizeShelfType(shelf_type)
    local typed_path = self:_apiPath("/shelves/" .. normalized_type .. "/" .. tostring(shelf_id) .. "/books/" .. tostring(book_id) .. "/remove")

    local success, code, response = self:request("POST", typed_path)

    if not success and normalized_type == "regular" and tonumber(code) == 404 then
        success, code, response = self:request(
            "POST",
            self:_apiPath("/shelves/" .. tostring(shelf_id) .. "/books/" .. tostring(book_id) .. "/remove")
        )
    end

    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getSupportedReadStatuses()
    local success, code, response = self:request("GET", self:_apiPath("/books/read-statuses"))
    if success and type(response) == "table" then
        local raw = response
        if type(response.statuses) == "table" then
            raw = response.statuses
        end
        if type(raw) ~= "table" then
            return false, "invalid_status_payload", code
        end
        local statuses = {}
        for _, value in ipairs(raw) do
            if value ~= nil and tostring(value) ~= "" then
                statuses[#statuses + 1] = tostring(value):upper()
            end
        end
        return true, statuses, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:updateBookReadStatus(book_id, status)
    local normalized_book_id = normalizeNumericId(book_id)
    local payload = {
        status = status and tostring(status):upper() or nil,
    }
    local success, code, response = self:request(
        "PUT",
        self:_apiPath("/books/" .. normalized_book_id .. "/status"),
        payload
    )
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

return APIClient
