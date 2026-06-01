local util = require("grimmlink_util")
local M = {}

function M.new()
    local o = {}
    setmetatable(o, { __index = M })
    return o
end

local function isPathUnderDirectory(path, root)
    local norm_path = util.normalizePath(path)
    local norm_root = util.normalizePath(root)
    if not norm_path or not norm_root then
        return false
    end
    return norm_path == norm_root or norm_path:sub(1, #norm_root + 1) == norm_root .. "/"
end

function M:evaluateLocalDeletePolicy(entry, opts)
    opts = opts or {}
    if not entry then
        return false, "invalid_entry"
    end
    if entry.downloaded_by_grimmlink ~= 1 then
        return false, "not_downloaded_by_grimmlink"
    end
    local local_path = entry.local_path
    if not local_path or local_path == "" then
        return true, "no_local_path"
    end

    local managed_roots = opts.managed_roots or {}
    for _, root in ipairs(managed_roots) do
        if root and root ~= "" and isPathUnderDirectory(local_path, root) then
            return true, "ok"
        end
    end
    return false, "outside_managed_roots"
end

function M:queueOfflineShelfRemoval(plugin, book_id, shelf_id, shelf_type, local_path, delete_sdr)
    if not plugin or not plugin.db or type(plugin.db.queueShelfRemoval) ~= "function" then
        return false
    end
    return plugin.db:queueShelfRemoval(book_id, shelf_id, shelf_type, local_path, delete_sdr == true)
end

return M
