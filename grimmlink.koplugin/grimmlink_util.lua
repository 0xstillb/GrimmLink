local M = {}

local function safeToString(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

function M.safeToString(value)
    return safeToString(value)
end

function M.toIso8601(epoch_seconds)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch_seconds)
end

function M.formatTimestamp(epoch_seconds)
    if not epoch_seconds then
        return "unknown"
    end
    return os.date("%Y-%m-%d %H:%M:%S", epoch_seconds)
end

function M.normalizeShelfType(value)
    local shelf_type = tostring(value or "regular"):lower()
    if shelf_type ~= "magic" then
        return "regular"
    end
    return shelf_type
end

function M.normalizePercent(value)
    if value == nil then
        return nil
    end
    value = tonumber(value)
    if not value or value ~= value then
        return nil
    end
    if value >= 0 and value <= 1 then
        value = value * 100
    end
    if value < 0 then
        value = 0
    end
    if value > 100 then
        value = 100
    end
    return math.floor(value * 100 + 0.5) / 100
end

function M.normalizeDirectoryPath(path)
    local value = safeToString(path):gsub("\\", "/")
    if value == "" then
        return ""
    end
    value = value:gsub("/+$", "")
    if value == "" then
        return "/"
    end
    return value
end

function M.normalizePath(path)
    local value = M.normalizeDirectoryPath(path)
    if value == "" then
        return nil
    end
    value = value:gsub("/+", "/")
    if #value > 1 then
        value = value:gsub("/$", "")
    end
    return value
end

function M.redactSimple(value, keep_prefix)
    local text = safeToString(value)
    if text == "" then
        return ""
    end
    local keep = tonumber(keep_prefix) or 0
    if keep <= 0 then
        return "[REDACTED]"
    end
    if #text <= keep then
        return text
    end
    return text:sub(1, keep) .. "..."
end

function M.redactUrl(url)
    local text = safeToString(url)
    if text == "" then
        return ""
    end
    local protocol, host = text:match("^(https?://)([^/%?]+)")
    if protocol and host then
        local host_prefix = host:sub(1, math.min(#host, 4))
        return protocol .. host_prefix .. "..."
    end
    return M.redactSimple(text, 8)
end

function M.formatUrlForDisplay(url, max_len)
    local text = safeToString(url)
    if text == "" then
        return ""
    end

    local limit = tonumber(max_len) or 60
    local cleaned = text:gsub("%?.*$", ""):gsub("#.*$", "")
    local protocol, host, path = cleaned:match("^(https?://)([^/%?]+)(/?.*)$")
    if not protocol or not host then
        if #cleaned <= limit then
            return cleaned
        end
        return cleaned:sub(1, limit - 3) .. "..."
    end

    local normalized_path = safeToString(path):gsub("^/*", "")
    if normalized_path == "" then
        local base = protocol .. host
        if #base <= limit then
            return base
        end
        return base:sub(1, limit - 3) .. "..."
    end

    local last_segment = normalized_path:match("([^/\\]+)$") or normalized_path
    local compact = protocol .. host .. "/.../" .. last_segment
    if #compact <= limit then
        return compact
    end

    local host_only = protocol .. host
    if #host_only <= limit then
        return host_only
    end
    return host_only:sub(1, limit - 3) .. "..."
end

function M.buildUrlDisplayLabel(nickname, fallback)
    local nick = safeToString(nickname):gsub("^%s+", ""):gsub("%s+$", "")
    if nick ~= "" then
        return nick
    end
    return safeToString(fallback)
end

return M
