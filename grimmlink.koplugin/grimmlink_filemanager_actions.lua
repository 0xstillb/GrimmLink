local M = {}

function M.install(Grimmlink, deps)
    deps = deps or {}
    local FileManager = deps.FileManager
    local UIManager = deps.UIManager
    local _ = deps._
    local T = deps.T
    local safeToString = deps.safeToString
    local sanitizeTitle = deps.sanitizeTitle
function Grimmlink:resolveBookContextByPath(file_path)
    if self.matching and type(self.matching.resolveBookContextByPath) == "function" then
        return self.matching:resolveBookContextByPath(self, file_path)
    end

    if not file_path or file_path == "" then
        return nil
    end
    local cached = self:resolveBookByFilePath(file_path)
    local file_hash = cached and cached.file_hash or nil
    if (not file_hash or file_hash == "") and type(self.calculateBookHash) == "function" then
        local ok_hash, hash = pcall(self.calculateBookHash, self, file_path)
        if ok_hash then
            file_hash = hash
        end
    end
    local book_id = cached and cached.book_id or nil
    local book_file_id = cached and cached.book_file_id or nil
    return {
        file_path = file_path,
        file_hash = file_hash,
        book_id = book_id,
        book_file_id = book_file_id,
    }
end

function Grimmlink:syncThisBookFromPath(file_path)
    if self.progress_sync and type(self.progress_sync.syncThisBookFromPath) == "function" then
        return self.progress_sync:syncThisBookFromPath(self, file_path)
    end

    local context = self:resolveBookContextByPath(file_path)
    if not context then
        self:showMessage(_("No file selected"), 3)
        return
    end
    if not self:isTrackingEnabled(context.file_hash, context.file_path) then
        self:showTrackingDisabledMessage()
        return
    end

    if self.current_session and self.current_session.file_path == context.file_path then
        local snapshot = self:getCurrentProgressSnapshot(
            self.current_session.file_hash,
            self.current_session.file_path,
            self.current_session.book_id,
            self.current_session.book_file_id
        )
        self:pushProgressSnapshot(snapshot, "manual", false)
        self:syncPendingNow(false, { progress_limit = 20, session_limit = 50 })
    else
        self:showMessage(_("Open the book to sync progress"), 3)
    end
end

function Grimmlink:pullRemoteProgressFromPath(file_path)
    if self.progress_sync and type(self.progress_sync.pullRemoteProgressFromPath) == "function" then
        return self.progress_sync:pullRemoteProgressFromPath(self, file_path)
    end

    if not self.current_session or self.current_session.file_path ~= file_path then
        self:showMessage(_("Open the book first to pull progress"), 3)
        return
    end
    if not self:isTrackingEnabled(self.current_session.file_hash, self.current_session.file_path) then
        self:showTrackingDisabledMessage()
        return
    end
    self:manualPullProgress()
end

function Grimmlink:toggleTrackingByPath(file_path)
    local context = self:resolveBookContextByPath(file_path)
    if not context then
        self:showMessage(_("No file selected"), 3)
        return
    end
    local toggled = self:toggleTracking(context.file_hash, context.file_path)
    if toggled == nil then
        self:showMessage(_("Failed to update tracking state"), 3)
        return
    end
    self:showMessage(toggled and _("Tracking enabled for this book") or _("Tracking disabled for this book"), 3)
end

function Grimmlink:matchBookByPath(file_path, options)
    if self.matching and type(self.matching.matchBookByPath) == "function" then
        return self.matching:matchBookByPath(self, file_path, options)
    end

    options = options or {}
    local force_rematch = options.force == true
    local context = self:resolveBookContextByPath(file_path)
    if not context or not context.file_hash then
        self:showMessage(_("Could not calculate book hash"), 3)
        return
    end

    local cached = self.db and self.db:getBookByHash(context.file_hash) or nil
    if cached and cached.book_id and not force_rematch then
        self:showMessage(T(_("Book already matched: %1"), cached.book_id), 3)
        return
    end

    local remote_matched = nil
    if self:isOnline() and self:isApiReady({ "getBookByHash" }) and self:refreshApiClient() then
        local ok_lookup, book = self.api:getBookByHash(context.file_hash)
        if ok_lookup and type(book) == "table" and book.id then
            remote_matched = tonumber(book.id) or book.id
        end
    end

    if remote_matched then
        self.db:saveBookCache(file_path, context.file_hash, remote_matched, sanitizeTitle(file_path), nil)
        self:showMessage(force_rematch and T(_("Re-matched by hash: %1"), remote_matched) or T(_("Matched by hash: %1"), remote_matched), 3)
        return
    end

    self:showTextInput(_("Manual Book ID"), "", _("Enter Grimmory book id"), false, function(value)
        local manual_id = tonumber(value)
        if not manual_id then
            self:showMessage(_("Invalid book id"), 3)
            return
        end
        self.db:saveBookCache(file_path, context.file_hash, manual_id, sanitizeTitle(file_path), nil)
        self:showMessage(T(_("Book mapping saved: %1"), manual_id), 3)
    end)
end

function Grimmlink:showBookDebugInfoByPath(file_path)
    local context = self:resolveBookContextByPath(file_path)
    if not context then
        self:showMessage(_("No file selected"), 3)
        return
    end
    self:showMessage(self:buildDebugInfo(context), 8)
end

function Grimmlink:buildFileManagerActionItems(path_resolver)
    if self.menu_actions and type(self.menu_actions.buildFileManagerActionItems) == "function" then
        return self.menu_actions:buildFileManagerActionItems(self, path_resolver)
    end

    local resolve = path_resolver
    local function filePath()
        if type(resolve) == "function" then
            local ok, value = pcall(resolve)
            if ok and value and value ~= "" then
                return tostring(value)
            end
        end
        return nil
    end

    return {
        {
            text = _("GrimmLink: Sync This Book"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("Long-press on a book file first"), 3)
                    return
                end
                self:syncThisBookFromPath(file_path)
            end,
        },
        {
            text = _("GrimmLink: Toggle Tracking"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("Long-press on a book file first"), 3)
                    return
                end
                self:toggleTrackingByPath(file_path)
            end,
        },
        {
            text = _("GrimmLink: Match Book"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("Long-press on a book file first"), 3)
                    return
                end
                self:matchBookByPath(file_path)
            end,
        },
        {
            text = _("GrimmLink: Show Debug Info"),
            callback = function()
                local file_path = filePath()
                if not file_path then
                    self:showMessage(_("Long-press on a book file first"), 3)
                    return
                end
                self:showBookDebugInfoByPath(file_path)
            end,
        },
    }
end

function Grimmlink:registerFileManagerHoldActions()
    local function resolvePathFromValue(value)
        if type(value) == "string" and value ~= "" then
            return value
        end
        if type(value) == "table" then
            local candidates = {
                value.path,
                value.file,
                value.filepath,
                value.selected_file,
                value.selected_path,
            }
            for _, candidate in ipairs(candidates) do
                if candidate and candidate ~= "" then
                    return tostring(candidate)
                end
            end
        end
        return nil
    end

    local function registerViaFileDialogButtons()
        local fm = nil
        local fm_candidates = {
            self and self.ui,
            FileManager and FileManager.instance,
        }
        for _, candidate in ipairs(fm_candidates) do
            if type(candidate) == "table" and type(candidate.addFileDialogButtons) == "function" then
                fm = candidate
                break
            end
        end
        if not fm then
            return false
        end

        local function closeFileDialogSafe()
            local dialog = fm.file_dialog
            if dialog then
                pcall(function()
                    UIManager:close(dialog)
                end)
            end
        end

        local function wrapAction(action_item)
            if type(action_item) ~= "table" then
                return nil
            end
            return {
                text = action_item.text,
                callback = function()
                    closeFileDialogSafe()
                    if type(action_item.callback) == "function" then
                        action_item.callback()
                    end
                end,
            }
        end

        local function buildRows(file_path)
            local action_items = self:buildFileManagerActionItems(function()
                return file_path
            end)
            return {
                {}, -- separator between KOReader default actions and GrimmLink actions
                {
                    wrapAction(action_items[1]),
                    wrapAction(action_items[2]),
                    wrapAction(action_items[3]),
                },
                {
                    wrapAction(action_items[4]),
                    wrapAction(action_items[5]),
                },
            }
        end

        local function rowAt(index)
            return function(file, is_file, _book_props)
                if not is_file then
                    return nil
                end
                local file_path = resolvePathFromValue(file)
                if not file_path then
                    return nil
                end
                local rows = buildRows(file_path)
                return rows[index]
            end
        end

        local ok, err = pcall(function()
            fm:addFileDialogButtons("grimmlink_file_dialog_separator", rowAt(1))
            fm:addFileDialogButtons("grimmlink_file_dialog_primary", rowAt(2))
            fm:addFileDialogButtons("grimmlink_file_dialog_secondary", rowAt(3))
        end)
        if not ok then
            self:logWarn("GrimmLink: failed to register FileManager file-dialog actions:", tostring(err))
            return false
        end

        return true
    end

    if registerViaFileDialogButtons() then
        return true
    end

    local ok_fm_menu, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok_fm_menu or not FileManagerMenu then
        self:logDbg("GrimmLink: FileManager hold actions unavailable")
        return false
    end
    if FileManagerMenu.__grimmlink_hold_actions_patched then
        return true
    end

    local function resolvePathFromMenu(menu_self)
        local candidates = {
            menu_self and menu_self.selected_file,
            menu_self and menu_self.selected_path,
            menu_self and menu_self.file,
            menu_self and menu_self.filepath,
            menu_self and menu_self.path,
        }
        for _, value in ipairs(candidates) do
            local resolved = resolvePathFromValue(value)
            if resolved then
                return resolved
            end
        end
        return nil
    end

    local orig_set_update_item_table = FileManagerMenu.setUpdateItemTable
    FileManagerMenu.setUpdateItemTable = function(menu_self)
        if type(orig_set_update_item_table) == "function" then
            pcall(orig_set_update_item_table, menu_self)
        end
        if type(menu_self) ~= "table" then
            return
        end
        menu_self.pathhold_menu_table = menu_self.pathhold_menu_table or menu_self.hold_menu_table
        if type(menu_self.pathhold_menu_table) ~= "table" then
            return
        end
        local resolved_path = resolvePathFromMenu(menu_self)
        if not resolved_path then
            return
        end
        local grimmlink_items = self:buildFileManagerActionItems(function()
            return resolved_path
        end)
        for _, item in ipairs(grimmlink_items) do
            menu_self.pathhold_menu_table[#menu_self.pathhold_menu_table + 1] = item
        end
    end

    FileManagerMenu.__grimmlink_hold_actions_patched = true
    return true
end
end

return M
