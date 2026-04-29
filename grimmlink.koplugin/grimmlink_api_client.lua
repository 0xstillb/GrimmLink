local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")

local APIClient = {
    timeout = 10,
    secure_logs = false,
}

local function redactUrls(message)
    if type(message) ~= "string" then
        return tostring(message)
    end
    return message:gsub("https?://[^%s]+", "[URL REDACTED]")
end

function APIClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function APIClient:init(server_url, username, auth_key, secure_logs)
    self.server_url = server_url or ""
    self.username = username or ""
    self.auth_key = auth_key or ""
    self.secure_logs = secure_logs or false

    if self.server_url:sub(-1) == "/" then
        self.server_url = self.server_url:sub(1, -2)
    end
end

function APIClient:log(level, ...)
    local args = { ... }
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end

    if level == "warn" then
        logger.warn(table.unpack(args))
    elseif level == "err" then
        logger.err(table.unpack(args))
    elseif level == "dbg" then
        logger.dbg(table.unpack(args))
    else
        logger.info(table.unpack(args))
    end
end

function APIClient:_urlEncode(value)
    if not value then
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
        [500] = "Internal Server Error",
        [503] = "Service Unavailable",
    }
    return fallback[code] or ("HTTP " .. tostring(code))
end

function APIClient:request(method, path, body, extra_headers)
    if not self.server_url or self.server_url == "" then
        return false, nil, "Server URL not configured"
    end

    local url = self.server_url .. path
    self:log("info", "GrimmLink API:", method, url)

    local protocol = url:match("^https://") and https or http
    protocol.TIMEOUT = self.timeout

    local headers = extra_headers or {}
    headers["Accept"] = headers["Accept"] or "application/json"

    if self.username ~= "" and self.auth_key ~= "" then
        headers["x-auth-user"] = self.username
        headers["x-auth-key"] = self.auth_key
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
        self:log("dbg", "GrimmLink API:", method, path, "payload bytes:", #request_body)
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
    if self.auth_key == "" then
        return false, "Auth key not configured"
    end

    local success, code, response = self:request("GET", "/api/koreader/users/auth")
    if success then
        return true, response
    end
    return false, response or ("HTTP " .. tostring(code or "?"))
end

function APIClient:getBookByHash(book_hash)
    local success, code, response = self:request(
        "GET",
        "/api/koreader/books/by-hash/" .. self:_urlEncode(book_hash)
    )
    if success and type(response) == "table" then
        return true, response
    end
    return false, response or ("HTTP " .. tostring(code or "?"))
end

function APIClient:getProgress(book_hash)
    local success, code, response = self:request(
        "GET",
        "/api/koreader/syncs/progress/" .. self:_urlEncode(book_hash)
    )
    if success and type(response) == "table" then
        return true, response
    end
    return false, response or ("HTTP " .. tostring(code or "?"))
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
        bookId = book_id,
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

return APIClient
