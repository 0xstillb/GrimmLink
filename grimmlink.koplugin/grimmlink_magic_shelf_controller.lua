local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local _ = deps._
    local T = deps.T
    local joinDirectoryPath = deps.joinDirectoryPath
    local normalizeDirectoryPath = deps.normalizeDirectoryPath
    local safeToString = deps.safeToString
function Grimmlink:configureDownloadDir()
    self:showDownloadDirectoryInputChooser(function(selected_path)
        if not selected_path or selected_path == "" then
            return
        end
        local normalized = normalizeDirectoryPath(selected_path)
        if normalized == "" then
            return
        end
        self:saveSetting("download_dir", normalized)
        self:showMessage(T(_("Shelf sync download directory set to: %1"), normalized), 3)
    end)
end

function Grimmlink:isShelfDownloadDirectoryCustom()
    return normalizeDirectoryPath(self.download_dir) ~= ""
end

function Grimmlink:setShelfDownloadDirectoryAuto()
    self:saveSetting("download_dir", "")
    self:showMessage(_("Shelf sync download directory set to: Default (Auto)"), 3)
end

function Grimmlink:validateMagicDownloadDirectory(path_value)
    local normalized = normalizeDirectoryPath(path_value)
    if normalized == "" then
        return false, nil, "empty_path"
    end

    local created_ok = self:ensureDirectoryExists(normalized)
    if not created_ok then
        return false, nil, "create_failed"
    end
    if not self:isDirectoryWritable(normalized) then
        return false, nil, "not_writable"
    end
    return true, normalized
end

function Grimmlink:showMagicDirectoryValidationError(reason)
    if reason == "not_writable" then
        self:showMessage(_("Magic Shelf directory is not writable."), 4)
    else
        self:showMessage(_("Magic Shelf directory cannot be created."), 4)
    end
end

function Grimmlink:showMagicDirectoryInputChooser(on_select)
    local seed = self:getDirectoryPickerStart(
        self.magic_download_dir ~= "" and self.magic_download_dir or self.download_dir
    ) or self.magic_download_dir or self.download_dir or ""
    self:showTextInput(
        _("Magic Download Directory"),
        seed,
        _("Enter folder path"),
        false,
        function(value)
            if type(on_select) == "function" then
                on_select(value)
            end
        end
    )
end

function Grimmlink:showDownloadDirectoryInputChooser(on_select)
    local seed = self:getDirectoryPickerStart(self.download_dir ~= "" and self.download_dir or self.magic_download_dir)
        or self.download_dir or self.magic_download_dir or ""
    self:showTextInput(
        _("Shelf Download Directory"),
        seed,
        _("Enter folder path"),
        false,
        function(value)
        if type(on_select) == "function" then
                on_select(value)
        end
        end
    )
end

function Grimmlink:showMagicMoveSummary(prefix_text, summary)
    local moved = summary and tonumber(summary.moved) or 0
    local shared = summary and tonumber(summary.shared) or 0
    local skipped = summary and tonumber(summary.skipped) or 0
    local failed = summary and tonumber(summary.failed) or 0
    local sidecar_warnings = summary and tonumber(summary.sidecar_warnings) or 0
    local lines = {
        prefix_text,
        T(_("Moved %1 files."), moved),
        T(_("Skipped %1 shared books."), shared),
    }
    if skipped > 0 then
        lines[#lines + 1] = T(_("Skipped %1 other files."), skipped)
    end
    if failed > 0 then
        lines[#lines + 1] = T(_("Failed %1 files."), failed)
    end
    if sidecar_warnings > 0 then
        lines[#lines + 1] = T(_("Sidecar warnings: %1"), sidecar_warnings)
    end
    local first_error = summary and type(summary.errors) == "table" and summary.errors[1] or nil
    if first_error and first_error ~= "" then
        lines[#lines + 1] = safeToString(first_error)
    end
    self:showMessage(table.concat(lines, "\n"), 8)
end

function Grimmlink:getResolvedShelfDownloadDirectory()
    local configured = normalizeDirectoryPath(self.download_dir)
    if self.shelf_sync and type(self.shelf_sync.resolveDownloadDir) == "function" then
        local ok, resolved = pcall(self.shelf_sync.resolveDownloadDir, self.shelf_sync, configured)
        if ok and resolved and resolved ~= "" then
            return normalizeDirectoryPath(resolved)
        end
    end
    return configured
end

function Grimmlink:moveMagicShelfFilesToMagicDirectory()
    if not self.shelf_sync or type(self.shelf_sync.moveMagicShelfFilesToDirectory) ~= "function" then
        return
    end
    local shared_dir = self:getResolvedShelfDownloadDirectory()
    if shared_dir == "" then
        self:showMessage(_("Shared shelf directory is not available."), 4)
        return
    end
    self:showMessage(_("Moving Magic Shelf files…"), 2)
    local summary = self.shelf_sync:moveMagicShelfFilesToDirectory(self.magic_download_dir, {
        shared_dir = shared_dir,
        download_dir = shared_dir,
    })
    self:showMagicMoveSummary(_("Moving Magic Shelf files…"), summary)
end

function Grimmlink:moveMagicShelfFilesBackToSharedDirectory()
    if not self.shelf_sync or type(self.shelf_sync.moveMagicShelfFilesBackToSharedDirectory) ~= "function" then
        return
    end
    local shared_dir = self:getResolvedShelfDownloadDirectory()
    if shared_dir == "" then
        self:showMessage(_("Shared shelf directory is not available."), 4)
        return
    end
    self:showMessage(_("Moving Magic Shelf files…"), 2)
    local summary = self.shelf_sync:moveMagicShelfFilesBackToSharedDirectory(shared_dir, {
        magic_dir = self.magic_download_dir,
        download_dir = shared_dir,
    })
    self:showMagicMoveSummary(_("Moving Magic Shelf files…"), summary)
end

local function collapseTrailingMagicShelfSegments(path_value)
    local normalized = normalizeDirectoryPath(path_value)
    if normalized == "" then
        return normalized
    end

    local parts = {}
    for part in normalized:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    if #parts == 0 then
        return normalized
    end

    local trailing_magic = 0
    for idx = #parts, 1, -1 do
        if parts[idx]:lower() == "magic_shelf" then
            trailing_magic = trailing_magic + 1
        else
            break
        end
    end

    if trailing_magic <= 1 then
        return normalized
    end

    for _ = 1, trailing_magic - 1 do
        table.remove(parts)
    end

    local prefix = normalized:sub(1, 1) == "/" and "/" or ""
    return prefix .. table.concat(parts, "/")
end

function Grimmlink:getDefaultMagicDownloadDirectory()
    local base_dir = ""
    if self.shelf_sync and type(self.shelf_sync.resolveDownloadDir) == "function" then
        local ok_resolve, resolved = pcall(self.shelf_sync.resolveDownloadDir, self.shelf_sync, "")
        if ok_resolve and type(resolved) == "string" and resolved ~= "" then
            base_dir = collapseTrailingMagicShelfSegments(resolved)
        end
    end
    if base_dir == "" then
        base_dir = collapseTrailingMagicShelfSegments(self.download_dir)
    end
    if base_dir == "" then
        base_dir = self:getDirectoryPickerStart(self.magic_download_dir ~= "" and self.magic_download_dir or nil) or ""
        base_dir = collapseTrailingMagicShelfSegments(base_dir)
    end
    if base_dir == "" then
        return ""
    end
    -- Avoid creating nested ".../Magic_Shelf/Magic_Shelf" when the base path
    -- is already a Magic Shelf directory (case-insensitive).
    if base_dir:lower():match("/magic_shelf$") or base_dir:lower() == "magic_shelf" then
        return base_dir
    end
    return joinDirectoryPath(base_dir, "Magic_Shelf")
end

function Grimmlink:applySeparateMagicDownloadDirectory(path_value, prompt_move_on_enable)
    local candidate_path = collapseTrailingMagicShelfSegments(path_value)
    local ok_dir, normalized, reason = self:validateMagicDownloadDirectory(candidate_path)
    if not ok_dir then
        self:showMagicDirectoryValidationError(reason)
        return false
    end

    local was_enabled = self.use_separate_magic_download_dir == true
    self:saveSetting("magic_download_dir", normalized)
    self:saveSetting("use_separate_magic_download_dir", true)
    self:showMessage(T(_("Separate magic shelf folder enabled.\nMagic Shelf directory set to: %1"), normalized), 4)

    if (not was_enabled) and prompt_move_on_enable == true then
        self:showConfirmAction(
            _("Move existing Magic Shelf files to the Magic folder?\nShared books that are also in Regular Shelves will stay in the main folder."),
            _("Move Files"),
            function()
                self:moveMagicShelfFilesToMagicDirectory()
            end
        )
    end
    return true
end

function Grimmlink:enableSeparateMagicDownloadDirectory()
    local preferred_path = normalizeDirectoryPath(self.magic_download_dir)
    if preferred_path == "" then
        preferred_path = self:getDefaultMagicDownloadDirectory()
    end
    if preferred_path ~= "" and self:applySeparateMagicDownloadDirectory(preferred_path, true) then
        return
    end
    self:selectSeparateMagicDownloadDirectory()
end

function Grimmlink:disableSeparateMagicDownloadDirectory()
    self:saveSetting("use_separate_magic_download_dir", false)
    self:showMessage(_("Separate magic shelf folder disabled."), 3)
    self:showConfirmAction(
        _("Move Magic Shelf files back to the shared folder?"),
        _("Move Files"),
        function()
            self:moveMagicShelfFilesBackToSharedDirectory()
        end
    )
end

function Grimmlink:toggleSeparateMagicDownloadDirectory()
    if self.use_separate_magic_download_dir == true then
        self:disableSeparateMagicDownloadDirectory()
    else
        self:enableSeparateMagicDownloadDirectory()
    end
end

function Grimmlink:setSeparateMagicDownloadDirectoryDefault()
    local default_magic_dir = self:getDefaultMagicDownloadDirectory()
    if default_magic_dir == "" then
        self:showMessage(_("Cannot determine default Magic Shelf directory."), 4)
        return
    end
    local should_prompt_move = self.use_separate_magic_download_dir ~= true
    self:applySeparateMagicDownloadDirectory(default_magic_dir, should_prompt_move)
end

function Grimmlink:selectSeparateMagicDownloadDirectory()
    local should_prompt_move = self.use_separate_magic_download_dir ~= true
    self:showMagicDirectoryInputChooser(function(selected_path)
        if not selected_path or selected_path == "" then
            return
        end
        self:applySeparateMagicDownloadDirectory(selected_path, should_prompt_move)
    end)
end

function Grimmlink:configureMagicDownloadDir()
    self:selectSeparateMagicDownloadDirectory()
end
end

return M