local DataStorage = require("datastorage")

local FileLogger = {
    path = nil,
}

function FileLogger:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function FileLogger:init()
    self.path = DataStorage:getDataDir() .. "/grimmlink.log"
    local file = io.open(self.path, "a")
    if not file then
        return false
    end
    file:write(string.format("[%s] GrimmLink log initialized\n", os.date("!%Y-%m-%dT%H:%M:%SZ")))
    file:close()
    return true
end

function FileLogger:write(level, ...)
    if not self.path then
        return false
    end

    local file = io.open(self.path, "a")
    if not file then
        return false
    end

    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end

    file:write(string.format("[%s] [%s] %s\n",
        os.date("!%Y-%m-%dT%H:%M:%SZ"),
        tostring(level or "INFO"),
        table.concat(parts, " ")
    ))
    file:close()
    return true
end

return FileLogger
