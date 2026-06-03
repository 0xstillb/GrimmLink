local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local _ = deps._
    local T = deps.T
    local DEFAULTS = deps.DEFAULTS

function Grimmlink:isTrackingEnabled(file_hash, file_path)
    if not self.db or type(self.db.isTrackingEnabled) ~= "function" then
        return true
    end
    local ok, enabled = pcall(self.db.isTrackingEnabled, self.db, file_hash, file_path)
    if not ok then
        return true
    end
    return enabled ~= false
end

function Grimmlink:setTrackingEnabled(file_hash, file_path, enabled)
    if not self.db or type(self.db.setTrackingEnabled) ~= "function" then
        return false
    end
    local ok, result = pcall(self.db.setTrackingEnabled, self.db, file_hash, file_path, enabled)
    return ok and result == true or false
end

function Grimmlink:toggleTracking(file_hash, file_path)
    if not self.db or type(self.db.toggleTracking) ~= "function" then
        return nil
    end
    local ok, toggled = pcall(self.db.toggleTracking, self.db, file_hash, file_path)
    if not ok then
        return nil
    end
    return toggled
end

function Grimmlink:isTrackingEnabledForContext(context)
    if type(context) ~= "table" then
        return true
    end
    if not self.db then
        return true
    end
    local ok, enabled = pcall(self.db.isTrackingEnabled, self.db, context.file_hash, context.file_path)
    if not ok then
        return true
    end
    return enabled ~= false
end

function Grimmlink:getCurrentDocumentContext()
    local file_path = nil
    local file_hash = nil
    local book_id = nil
    local book_file_id = nil

    if self.current_session then
        file_path = self.current_session.file_path
        file_hash = self.current_session.file_hash
        book_id = self.current_session.book_id
        book_file_id = self.current_session.book_file_id
    elseif self.ui and self.ui.document and self.ui.document.file then
        file_path = tostring(self.ui.document.file)
    end

    if not file_path or file_path == "" then
        return nil
    end
    if (not file_hash or file_hash == "") and type(self.calculateBookHash) == "function" then
        local ok_hash, value = pcall(self.calculateBookHash, self, file_path)
        if ok_hash then
            file_hash = value
        end
    end
    if (not book_id or not book_file_id) and type(self.resolveBookByFilePath) == "function" then
        local ok_cached, cached = pcall(self.resolveBookByFilePath, self, file_path)
        if ok_cached and type(cached) == "table" then
            file_hash = file_hash or cached.file_hash
            book_id = book_id or cached.book_id
            book_file_id = book_file_id or cached.book_file_id
        end
    end

    return {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
    }
end

function Grimmlink:showTrackingDisabledMessage()
    self:showMessage(_("Tracking disabled for this book"), 3)
end

function Grimmlink:formatDuration(duration_seconds)
    local total = math.max(0, math.floor(tonumber(duration_seconds) or 0))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local seconds = total % 60
    local parts = {}
    if hours > 0 then
        parts[#parts + 1] = T(_("%1h"), hours)
    end
    if hours > 0 or minutes > 0 then
        parts[#parts + 1] = T(_("%1m"), minutes)
    end
    if seconds > 0 or #parts == 0 then
        parts[#parts + 1] = T(_("%1s"), seconds)
    end
    return table.concat(parts, " ")
end

function Grimmlink:loadWritableDocSettings(file_path)
    local active_file = self.ui and self.ui.document and self.ui.document.file or nil
    if self.ui and type(self.ui.doc_settings) == "table" and ((not file_path or file_path == "") or active_file == file_path) then
        return self.ui.doc_settings, false
    end
    if not file_path or file_path == "" then
        return nil, false
    end

    local ok_docsettings, docsettings = pcall(require, "docsettings")
    if not ok_docsettings or not docsettings then
        return nil, false
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
                return loaded, true
            end
            ok_loaded, loaded = pcall(docsettings[loader], docsettings, file_path)
            if ok_loaded and type(loaded) == "table" then
                return loaded, true
            end
        end
    end
    return nil, false
end

function Grimmlink:getPluginVersionLabel()
    if not self.plugin_dir or self.plugin_dir == "" then
        return _("unknown")
    end
    local ok, info = pcall(dofile, self.plugin_dir .. "/plugin_version.lua")
    if ok and type(info) == "table" and info.version and info.version ~= "" then
        return tostring(info.version)
    end
    return _("unknown")
end

function Grimmlink:rematchCurrentBook()
    local context = self:getCurrentDocumentContext()
    if not context or not context.file_path then
        self:showMessage(_("No file selected"), 3)
        return
    end
    self:matchBookByPath(context.file_path, { force = true })
end

end

return M
