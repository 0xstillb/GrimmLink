local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local lfs = require("lfs")
local _ok_ffi, ffi = pcall(require, "ffi")
if not _ok_ffi then ffi = nil end
if ffi then pcall(ffi.cdef, "int system(const char *command);") end

local unpack_values = table.unpack or unpack

local APIClient = {
    timeout = 25,
    secure_logs = false,
    debug_logging = false,
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
    self.username = tostring(username or "")
    self.password = tostring(password or "")
    self.debug_logging = debug_logging == true
    self.secure_logs = debug_logging == true

    if self.server_url:sub(-1) == "/" then
        self.server_url = self.server_url:sub(1, -2)
    end
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

function APIClient:request(method, path, body, extra_headers, timeout_sec)
    if not self.server_url or self.server_url == "" then
        return false, nil, "Server URL not configured"
    end

    local url = self.server_url .. path
    self:log("info", "GrimmLink API:", method, url)

    local protocol = url:match("^https://") and https or http
    protocol.TIMEOUT = timeout_sec or self.timeout

    local headers = extra_headers or {}
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
        return false, nil, error_message
    end

    local response_text = table.concat(response_buffer)
    local parsed = nil
    if response_text ~= "" then
        parsed = select(1, self:parseJSON(response_text))
    end

    if code >= 200 and code < 300 then
        return true, code, parsed or response_text, response_headers
    end

    local error_message = self:extractErrorMessage(response_text, code)
    self:log("warn", "GrimmLink API HTTP", code, error_message)
    return false, code, error_message, response_headers
end

function APIClient:testAuth()
    if self.username == "" then
        return false, "Username not configured"
    end
    if self.password == "" then
        return false, "Password not configured"
    end

    local success, code, response = self:request("GET", "/api/koreader/users/auth")
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getBookByHash(book_hash)
    local success, code, response = self:request(
        "GET",
        "/api/koreader/books/by-hash/" .. self:_urlEncode(book_hash)
    )
    if success and type(response) == "table" then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getProgress(book_hash, timeout_sec)
    local success, code, response = self:request(
        "GET",
        "/api/koreader/syncs/progress/" .. self:_urlEncode(book_hash),
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
    local success, code, response = self:request("PUT", "/api/koreader/syncs/progress", progress_payload)
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:submitSession(session_payload)
    local success, code, response = self:request("POST", "/api/v1/reading-sessions", session_payload)
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

    local success, code, response = self:request("POST", "/api/v1/reading-sessions/batch", payload)
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getShelves()
    local success, code, response = self:request("GET", "/api/koreader/shelves")
    if success and type(response) == "table" then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getShelfBooks(shelf_id)
    local success, code, response = self:request(
        "GET",
        "/api/koreader/shelves/" .. tostring(shelf_id) .. "/books"
    )
    if success and type(response) == "table" then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
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
    local file, err = io.open(tmp_path, "wb")
    if not file then
        return false, "Cannot open temp file: " .. tostring(err)
    end

    local url = self.server_url .. "/api/koreader/books/" .. tostring(book_id) .. "/download"
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
    local ok, code = protocol.request{
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

    -- Remove stale artifacts from a previous interrupted download.
    os.remove(tmp_path)
    os.remove(pid_path)
    os.remove(code_path)
    os.remove(script_path)

    local url = self.server_url .. "/api/koreader/books/" .. tostring(book_id) .. "/download"
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
    local attr = lfs.attributes(handle.tmp_path)
    local bytes_so_far = attr and attr.size or 0
    local total_bytes  = handle.expected_bytes

    -- Check if downloader has finished by looking for the exit code file.
    local code_attr = lfs.attributes(handle.code_path)
    if code_attr then
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

function APIClient:removeBookFromShelf(shelf_id, book_id)
    local success, code, response = self:request(
        "POST",
        "/api/koreader/shelves/" .. tostring(shelf_id) .. "/books/" .. tostring(book_id) .. "/remove"
    )
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:getPdfProgress(book_id, timeout_sec)
    local normalized_book_id = normalizeNumericId(book_id)
    local success, code, response = self:request(
        "GET",
        "/api/koreader/books/" .. normalized_book_id .. "/pdf-progress",
        nil,
        nil,
        timeout_sec
    )
    if success and type(response) == "table" then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

function APIClient:updatePdfProgress(book_id, progress_payload)
    local normalized_book_id = normalizeNumericId(book_id)
    local success, code, response = self:request(
        "PUT",
        "/api/koreader/books/" .. normalized_book_id .. "/pdf-progress",
        progress_payload
    )
    if success then
        return true, response, code
    end
    return false, response or ("HTTP " .. tostring(code or "?")), code
end

return APIClient
