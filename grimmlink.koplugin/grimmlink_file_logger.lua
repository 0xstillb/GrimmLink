local DataStorage = require("datastorage")
local _ok_lfs, lfs = pcall(require, "lfs")
if not _ok_lfs then lfs = nil end

local FileLogger = {
    path = nil,
    log_dir = nil,
    max_bytes = 512 * 1024,
    max_files = 5,
    _current_day = nil,
}

local function toString(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function fileSize(path)
    if not path or path == "" then
        return 0
    end
    if lfs and type(lfs.attributes) == "function" then
        local attrs = lfs.attributes(path)
        if attrs and attrs.size then
            return tonumber(attrs.size) or 0
        end
    end
    local handle = io.open(path, "rb")
    if not handle then
        return 0
    end
    local size = handle:seek("end") or 0
    handle:close()
    return tonumber(size) or 0
end

local function safeClose(handle)
    if handle then
        pcall(function() handle:close() end)
    end
end

function FileLogger:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function FileLogger:getLogDir()
    if self.log_dir and self.log_dir ~= "" then
        return self.log_dir
    end
    self.log_dir = DataStorage:getDataDir()
    return self.log_dir
end

function FileLogger:getLogPath()
    if self.path and self.path ~= "" then
        return self.path
    end
    self.path = self:getLogDir() .. "/grimmlink.log"
    return self.path
end

function FileLogger:_sanitizeMessage(message)
    local text = toString(message)
    if text == "" then
        return text
    end

    -- Sensitive key/value redaction.
    local patterns = {
        "([Pp]assword%s*[:=]%s*)([^%s,;]+)",
        "([Xx]%-%s*[Aa]uth%s*%-?%s*[Kk]ey%s*[:=]%s*)([^%s,;]+)",
        "([Aa]uth%s*[Kk]ey%s*[:=]%s*)([^%s,;]+)",
        "([Aa]uthorization%s*[:=]%s*)([^%s,;]+)",
        "([Tt]oken%s*[:=]%s*)([^%s,;]+)",
        "([Xx]%-%s*[Aa]uth%s*%-?%s*[Uu]ser%s*[:=]%s*)([^%s,;]+)",
    }
    for _, pattern in ipairs(patterns) do
        text = text:gsub(pattern, "%1[REDACTED]")
    end

    -- Hide possible metadata payload dumps.
    if text:find("payload_json", 1, true)
        or text:find("\"highlights\"", 1, true)
        or text:find("\"bookmarks\"", 1, true)
        or text:find("\"annotations\"", 1, true)
        or text:find("raw metadata payload", 1, true) then
        return "[REDACTED_METADATA_PAYLOAD]"
    end

    -- Avoid logging full highlight/note/bookmark text bodies.
    if text:find("highlight", 1, true) and text:find("text", 1, true) then
        return "[REDACTED_HIGHLIGHT_TEXT]"
    end
    if text:find("bookmark", 1, true) and text:find("text", 1, true) then
        return "[REDACTED_BOOKMARK_TEXT]"
    end
    if text:find("note", 1, true) and #text > 240 then
        return "[REDACTED_NOTE_TEXT]"
    end

    return text
end

function FileLogger:_listRotatedLogs()
    local files = {}
    local dir = self:getLogDir()
    if lfs and type(lfs.dir) == "function" then
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." and name:match("^grimmlink%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.log$") then
                files[#files + 1] = dir .. "/" .. name
            end
        end
    end
    table.sort(files, function(a, b) return a > b end)
    return files
end

function FileLogger:_cleanupOldLogs()
    local files = self:_listRotatedLogs()
    local keep = tonumber(self.max_files) or 5
    for index, file in ipairs(files) do
        if index > keep then
            pcall(os.remove, file)
        end
    end
end

function FileLogger:_rotateIfNeeded()
    local path = self:getLogPath()
    local today = os.date("!%Y%m%d")
    local need_rotate = false

    if self._current_day and self._current_day ~= today and fileSize(path) > 0 then
        need_rotate = true
    end

    if not need_rotate and fileSize(path) >= (tonumber(self.max_bytes) or (512 * 1024)) then
        need_rotate = true
    end

    if need_rotate then
        local stamp = os.date("!%Y%m%d-%H%M%S")
        local rotated = self:getLogDir() .. "/grimmlink-" .. stamp .. ".log"
        pcall(os.rename, path, rotated)
    end

    self._current_day = today
    self:_cleanupOldLogs()
end

function FileLogger:getLogFiles()
    local files = {}
    files[#files + 1] = self:getLogPath()
    local rotated = self:_listRotatedLogs()
    for _, file in ipairs(rotated) do
        files[#files + 1] = file
    end
    return files
end

function FileLogger:clearLogs()
    local ok = true
    for _, file in ipairs(self:getLogFiles()) do
        if file and file ~= "" then
            local removed, err = pcall(os.remove, file)
            if not removed or err == nil then
                -- os.remove may return nil,error on missing file; keep going.
            end
        end
    end
    local initialized = self:init()
    return initialized and ok
end

function FileLogger:init()
    self.path = self:getLogPath()
    self._current_day = os.date("!%Y%m%d")
    self:_rotateIfNeeded()

    local file = io.open(self.path, "a")
    if not file then
        return false
    end
    file:write(string.format("[%s] GrimmLink log initialized\n", os.date("!%Y-%m-%dT%H:%M:%SZ")))
    safeClose(file)
    return true
end

function FileLogger:write(level, ...)
    local path = self:getLogPath()
    if not path or path == "" then
        return false
    end

    pcall(function()
        self:_rotateIfNeeded()
    end)

    local file = io.open(path, "a")
    if not file then
        return false
    end

    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = self:_sanitizeMessage(select(i, ...))
    end

    local ok = pcall(function()
        file:write(string.format("[%s] [%s] %s\n",
            os.date("!%Y-%m-%dT%H:%M:%SZ"),
            tostring(level or "INFO"),
            table.concat(parts, " ")
        ))
    end)
    safeClose(file)
    return ok
end

return FileLogger
