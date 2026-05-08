local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

package.loaded["main"] = nil
package.loaded["grimmlink_updater"] = nil
package.loaded["grimmlink_database"] = nil
package.loaded["grimmlink_shelf_sync"] = nil
package.loaded["grimmlink_api_client"] = nil
package.loaded["grimmlink_file_logger"] = nil
package.loaded["datastorage"] = nil
package.loaded["json"] = nil
package.loaded["logger"] = nil
local Grimmlink = require("main")
local UIManager = require("ui/uimanager")
restore_stubs()

local function getMenuItemText(item)
    if not item then
        return nil
    end
    if item.text ~= nil then
        return item.text
    end
    if type(item.text_func) == "function" then
        local ok, value = pcall(item.text_func)
        if ok then
            return value
        end
    end
    return nil
end

local function findMenuItem(items, expected_text)
    for _, item in ipairs(items or {}) do
        if getMenuItemText(item) == expected_text then
            return item
        end
    end
    return nil
end

local function newDb()
    local db = {
        settings = {},
        book_cache_by_hash = {},
        book_cache_by_path = {},
        progress_state = {},
        pending_progress = {},
        pending_sessions = {},
        book_cache_calls = {},
    }

    function db:getPluginSetting(key)
        return self.settings[key]
    end

    function db:savePluginSetting(key, value)
        self.settings[key] = value
        return true
    end

    function db:getBookByHash(file_hash)
        return self.book_cache_by_hash[file_hash]
    end

    function db:getBookByFilePath(file_path)
        return self.book_cache_by_path[file_path]
    end

    function db:saveBookCache(file_path, file_hash, book_id, title, author)
        local entry = {
            file_path = file_path,
            file_hash = file_hash,
            book_id = book_id,
            title = title,
            author = author,
        }
        self.book_cache_calls[#self.book_cache_calls + 1] = entry
        if file_path then
            self.book_cache_by_path[file_path] = entry
        end
        if file_hash then
            self.book_cache_by_hash[file_hash] = entry
        end
        return true
    end

    function db:updateBookId(file_hash, book_id)
        local entry = self.book_cache_by_hash[file_hash]
        if entry then
            entry.book_id = book_id
        end
        return true
    end

    function db:getProgressState(file_hash)
        return self.progress_state[file_hash]
    end

    function db:upsertLocalProgressState(file_hash, state)
        local entry = self.progress_state[file_hash] or { file_hash = file_hash }
        for key, value in pairs(state or {}) do
            entry["local_" .. key] = value
        end
        self.progress_state[file_hash] = entry
        return true
    end

    function db:upsertRemoteProgressState(file_hash, state)
        local entry = self.progress_state[file_hash] or { file_hash = file_hash }
        for key, value in pairs(state or {}) do
            entry["remote_" .. key] = value
        end
        self.progress_state[file_hash] = entry
        return true
    end

    function db:setProgressLastAction(file_hash, last_action)
        local entry = self.progress_state[file_hash] or { file_hash = file_hash }
        entry.last_action = last_action
        self.progress_state[file_hash] = entry
        return true
    end

    function db:upsertPendingProgress(file_hash, payload_json, kind)
        local existing
        for _, item in ipairs(self.pending_progress) do
            if item.file_hash == file_hash and item.kind == (kind or "native") then
                existing = item
                break
            end
        end
        if existing then
            existing.payload_json = payload_json
            existing.retry_count = 0
            existing.last_retry_at = nil
            return true
        end
        self.pending_progress[#self.pending_progress + 1] = {
            id = #self.pending_progress + 1,
            file_hash = file_hash,
            kind = kind or "native",
            payload_json = payload_json,
            retry_count = 0,
            last_retry_at = nil,
        }
        return true
    end

    function db:getPendingProgress(_limit)
        return self.pending_progress
    end

    function db:getPendingProgressCount()
        return #self.pending_progress
    end

    function db:deletePendingProgress(id)
        for index, item in ipairs(self.pending_progress) do
            if item.id == id then
                table.remove(self.pending_progress, index)
                return true
            end
        end
        return false
    end

    function db:incrementPendingProgressRetry(id)
        for _, item in ipairs(self.pending_progress) do
            if item.id == id then
                item.retry_count = (item.retry_count or 0) + 1
                item.last_retry_at = os.time()
                return true
            end
        end
        return false
    end

    function db:addPendingSession(session)
        local copy = {}
        for key, value in pairs(session or {}) do
            copy[key] = value
        end
        copy.id = #self.pending_sessions + 1
        copy.retry_count = 0
        self.pending_sessions[#self.pending_sessions + 1] = copy
        return true
    end

    function db:getPendingSessions(_limit)
        return self.pending_sessions
    end

    function db:getPendingSessionCount()
        return #self.pending_sessions
    end

    function db:deletePendingSession(id)
        for index, item in ipairs(self.pending_sessions) do
            if item.id == id then
                table.remove(self.pending_sessions, index)
                return true
            end
        end
        return false
    end

    function db:incrementSessionRetryCount(id)
        for _, item in ipairs(self.pending_sessions) do
            if item.id == id then
                item.retry_count = (item.retry_count or 0) + 1
                return true
            end
        end
        return false
    end

    function db:updatePendingSessionBookId(id, book_id)
        for _, item in ipairs(self.pending_sessions) do
            if item.id == id then
                item.bookId = book_id
                return true
            end
        end
        return false
    end

    function db:getShelfSyncEntryByLocalPath()
        return nil
    end

    function db:getShelfSyncEntry()
        return nil
    end

    function db:getBookCacheStats()
        return { total = 0, unmatched = 0, distinct_hashes = 0 }
    end

    function db:getUnmatchedCacheCount()
        return 0
    end

    function db:clearUnmatchedCache()
        return true
    end

    function db:getStaleCacheEntries()
        return {}
    end

    function db:getStaleCacheCount()
        return 0
    end

    function db:clearStaleCache()
        return true
    end

    function db:getPendingShelfRemovals()
        return {}
    end

    function db:upsertPendingShelfRemoval()
        return true
    end

    function db:deletePendingShelfRemoval()
        return true
    end

    function db:incrementPendingShelfRemovalRetryCount()
        return true
    end

    function db:getShelfSyncStats()
        return { total = 0, downloaded_by_grimmlink = 0 }
    end

    return db
end

local function newApi()
    local api = {
        calls = {},
        next_auth = { success = true, response = { status = "ok" }, code = 200 },
        next_book = { success = true, response = { id = 123, bookFileId = 456, title = "Demo", author = "Author" }, code = 200 },
        next_progress = { success = true, response = { currentPage = 20, totalPages = 100, percentage = 20, timestamp = 200, device = "other", deviceId = "device-b", source = "KOReader" }, code = 200 },
        next_pdf = { success = true, response = { currentPage = 40, totalPages = 100, percentage = 40, timestamp = 300, source = "WEB_READER" }, code = 200 },
        next_update_progress = { success = true, response = {}, code = 200 },
        next_update_pdf = { success = true, response = {}, code = 200 },
        next_session = { success = true, response = {}, code = 202 },
        next_session_batch = { success = true, response = { status = "ok" }, code = 200 },
    }

    function api:init(...)
        self.init_args = { ... }
    end

    function api:testAuth()
        self.calls[#self.calls + 1] = { name = "testAuth" }
        return self.next_auth.success, self.next_auth.response, self.next_auth.code
    end

    function api:getBookByHash(hash)
        self.calls[#self.calls + 1] = { name = "getBookByHash", hash = hash }
        return self.next_book.success, self.next_book.response, self.next_book.code
    end

    function api:getProgress(hash)
        self.calls[#self.calls + 1] = { name = "getProgress", hash = hash }
        return self.next_progress.success, self.next_progress.response, self.next_progress.code
    end

    function api:updateProgress(payload)
        self.calls[#self.calls + 1] = { name = "updateProgress", payload = payload }
        return self.next_update_progress.success, self.next_update_progress.response, self.next_update_progress.code
    end

    function api:getPdfProgress(book_id)
        self.calls[#self.calls + 1] = { name = "getPdfProgress", book_id = book_id }
        return self.next_pdf.success, self.next_pdf.response, self.next_pdf.code
    end

    function api:updatePdfProgress(book_id, payload)
        self.calls[#self.calls + 1] = { name = "updatePdfProgress", book_id = book_id, payload = payload }
        return self.next_update_pdf.success, self.next_update_pdf.response, self.next_update_pdf.code
    end

    function api:submitSession(payload)
        self.calls[#self.calls + 1] = { name = "submitSession", payload = payload }
        return self.next_session.success, self.next_session.response, self.next_session.code
    end

    function api:submitSessionBatch(book_id, book_hash, book_type, device, device_id, sessions)
        self.calls[#self.calls + 1] = {
            name = "submitSessionBatch",
            book_id = book_id,
            book_hash = book_hash,
            book_type = book_type,
            device = device,
            device_id = device_id,
            sessions = sessions,
        }
        return self.next_session_batch.success, self.next_session_batch.response, self.next_session_batch.code
    end

    return api
end

local function newPlugin(overrides)
    local plugin = {
        enabled = true,
        server_url = "http://example.com",
        username = "reader",
        password = "secret-password",
        device_name = "KOReader",
        device_id = "device-1",
        auto_pull_on_open = true,
        auto_push_on_close = true,
        offline_queue_enabled = true,
        threshold_percent = 1.0,
        threshold_minutes = 5,
        threshold_pages = 5,
        session_min_seconds = 30,
        pdf_web_reader_bridge_enabled = false,
        shelf_sync_enabled = false,
        shelf_id = 9,
        shelf_use_original_filename = true,
        two_way_shelf_delete_sync = false,
        delete_sdr_on_book_delete = false,
        auto_update_enabled = false,
        check_update_on_startup = false,
        update_channel = "stable",
        update_repo = "0xstillb/grimmlink",
        allow_prerelease_updates = false,
        db = newDb(),
        api = newApi(),
        isOnline = function()
            return true
        end,
        ui = {
            document = {
                file = "/books/demo.epub",
                info = { has_pages = true },
                getCurrentPos = function()
                    return "/4"
                end,
                getXPointer = function()
                    return "/4"
                end,
                getCurrentPage = function()
                    return 4
                end,
                getPageCount = function()
                    return 100
                end,
            },
            paging = {
                getCurrentPage = function()
                    return 4
                end,
            },
            link = {
                addCurrentLocationToStack = function() end,
            },
            doc_settings = {
                readSetting = function()
                    return nil
                end,
            },
        },
    }

    for key, value in pairs(overrides or {}) do
        plugin[key] = value
    end

    return setmetatable(plugin, { __index = Grimmlink })
end

describe("GrimmLink helper methods", function()
    before_each(function()
        if UIManager.reset then
            UIManager:reset()
        end
    end)

    it("keeps the PDF Web Reader Bridge disabled by default", function()
        local plugin = newPlugin()
        assert.is_false(plugin:isPdfWebReaderBridgeEnabled())
        plugin.pdf_web_reader_bridge_enabled = true
        assert.is_true(plugin:isPdfWebReaderBridgeEnabled())
    end)

    it("builds native progress payloads without bridge-specific fields", function()
        local plugin = newPlugin()
        local payload = plugin:prepareNativeProgressPayload({
            document = "hash-1",
            bookHash = "hash-1",
            bookId = 7,
            bookFileId = 9,
            fileFormat = "EPUB",
            progress = "/4",
            location = "/4",
            percentage = 12.5,
            currentPage = 4,
            totalPages = 100,
            device = "KOReader",
            deviceId = "device-1",
            timestamp = 123,
        })

        assert.are.equal("hash-1", payload.document)
        assert.are.equal("EPUB", payload.fileFormat)
        assert.are.equal(7, payload.bookId)
        assert.are.equal(9, payload.bookFileId)
        assert.are.equal("/4", payload.location)
        assert.is_nil(payload.rawKoreaderLocation)
    end)

    it("builds PDF bridge payloads with page metadata only", function()
        local plugin = newPlugin({ pdf_web_reader_bridge_enabled = true })
        local payload = plugin:preparePdfBridgePayload({
            bookHash = "hash-2",
            bookFileId = 11,
            currentPage = 40,
            totalPages = 120,
            percentage = 33.3,
            location = "/p/40",
            progress = "/p/40",
            device = "KOReader",
            deviceId = "device-1",
            timestamp = 555,
        }, {
            force = true,
        })

        assert.are.equal("hash-2", payload.bookHash)
        assert.are.equal("PDF", payload.fileFormat)
        assert.are.equal(40, payload.currentPage)
        assert.are.equal(120, payload.totalPages)
        assert.are.equal(33.3, payload.percentage)
        assert.are.equal("/p/40", payload.rawKoreaderLocation)
        assert.are.equal("/p/40", payload.rawKoreaderProgress)
        assert.are.equal("KOReader", payload.source)
        assert.is_true(payload.force)
    end)

    it("formats durations and detects book types", function()
        local plugin = newPlugin()
        assert.are.equal("0s", plugin:formatDuration(nil))
        assert.are.equal("1m 30s", plugin:formatDuration(90))
        assert.are.equal("PDF", plugin:getBookType("/books/manual.pdf"))
        assert.are.equal("CBX", plugin:getBookType("/books/comic.cbz"))
        assert.are.equal("EPUB", plugin:getBookType("/books/novel.epub"))
    end)

    it("calculates a deterministic book hash", function()
        local plugin = newPlugin()
        local original_sha2_preload = package.preload["ffi/sha2"]
        package.preload["ffi/sha2"] = function()
            return {
                md5 = function(value)
                    return "md5:" .. tostring(value or "")
                end,
            }
        end
        local path = "grimmlink-hash-test.txt"
        local file = assert(io.open(path, "wb"))
        file:write("hash me")
        file:close()

        local hash = plugin:calculateBookHash(path)
        os.remove(path)
        package.preload["ffi/sha2"] = original_sha2_preload

        assert.is_string(hash)
        assert.is_true(hash:find("md5:") == 1)
    end)

    it("classifies remote progress conservatively", function()
        local plugin = newPlugin()

        assert.are.equal("remote_newer", plugin:compareOpenProgress(
            { percentage = 10, currentPage = 10, location = "/10", timestamp = 100 },
            { percentage = 20, currentPage = 20, location = "/20", timestamp = 200 },
            nil
        ))

        assert.are.equal("same", plugin:compareOpenProgress(
            { percentage = 20, currentPage = 20, location = "/20", timestamp = 200 },
            { percentage = 20, currentPage = 20, location = "/20", timestamp = 200 },
            {}
        ))

        assert.are.equal("local_newer", plugin:compareOpenProgress(
            { percentage = 30, currentPage = 30, location = "/30", timestamp = 300 },
            { percentage = 20, currentPage = 20, location = "/20", timestamp = 200 },
            {
                local_progress = "/30",
                local_location = "/30",
                local_percentage = 30,
                local_current_page = 30,
                local_total_pages = 100,
                local_timestamp = 300,
                remote_progress = "/20",
                remote_location = "/20",
                remote_percentage = 20,
                remote_current_page = 20,
                remote_total_pages = 100,
                remote_timestamp = 200,
            }
        ))

        assert.are.equal("conflict", plugin:compareOpenProgress(
            { percentage = 25, currentPage = 25, location = "/25", timestamp = nil },
            { percentage = 28, currentPage = 28, location = "/28", timestamp = nil },
            {
                local_progress = "/15",
                local_location = "/15",
                local_percentage = 15,
                local_current_page = 15,
                local_total_pages = 100,
                remote_progress = "/12",
                remote_location = "/12",
                remote_percentage = 12,
                remote_current_page = 12,
                remote_total_pages = 100,
            }
        ))
    end)

    it("presents a native prompt before jumping to a newer remote position", function()
        local plugin = newPlugin()
        local jumped_location = nil
        plugin.jumpToLocation = function(_, location)
            jumped_location = location
            return true
        end
        plugin.api.next_progress = {
            success = true,
            response = {
                progress = "/remote",
                location = "/remote",
                percentage = 80,
                currentPage = 80,
                totalPages = 100,
                timestamp = 500,
                device = "other-device",
                deviceId = "device-b",
                source = "KOReader",
            },
            code = 200,
        }

        plugin:maybePullRemoteProgress("hash-3", "/books/demo.epub", 99, nil, true)
        assert.are.equal("getProgress", plugin.api.calls[1].name)
        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.is_true(tostring(dialog.title):find("Local:") ~= nil)
        dialog.buttons[1][2].callback()
        assert.are.equal("/remote", jumped_location)
    end)

    it("presents a PDF bridge prompt before jumping to a newer Web Reader page", function()
        local plugin = newPlugin({
            pdf_web_reader_bridge_enabled = true,
        })
        local jumped_page = nil
        plugin.jumpToPage = function(_, page)
            jumped_page = page
            return true
        end
        plugin.api.next_pdf = {
            success = true,
            response = {
                currentPage = 80,
                totalPages = 100,
                percentage = 80,
                timestamp = 600,
                source = "WEB_READER",
            },
            code = 200,
        }

        plugin:maybePullPdfWebProgress("hash-4", "/books/demo.pdf", 42, nil, true)
        assert.are.equal("getPdfProgress", plugin.api.calls[1].name)
        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.is_true(tostring(dialog.title):find("Web Reader") ~= nil)
        dialog.buttons[1][2].callback()
        assert.are.equal(80, jumped_page)
    end)

    it("queues native progress while offline and replays it later", function()
        local plugin = newPlugin()
        plugin.isOnline = function()
            return false
        end

        local snapshot = {
            document = "hash-5",
            bookHash = "hash-5",
            bookId = 21,
            fileFormat = "EPUB",
            progress = "/11",
            location = "/11",
            percentage = 11,
            currentPage = 11,
            totalPages = 100,
            device = "KOReader",
            deviceId = "device-1",
            timestamp = 700,
        }

        assert.is_false(plugin:pushProgressSnapshot(snapshot, "close", true))
        assert.are.equal(1, #plugin.db.pending_progress)
        assert.are.equal("native", plugin.db.pending_progress[1].kind)

        plugin.isOnline = function()
            return true
        end
        local update_calls = {}
        plugin.api.updateProgress = function(_, payload)
            update_calls[#update_calls + 1] = payload
            return true, {}, 200
        end

        local synced, failed = plugin:syncPendingProgress(true)
        assert.are.equal(1, synced)
        assert.are.equal(0, failed)
        assert.are.equal(1, #update_calls)
        assert.are.equal("hash-5", update_calls[1].bookHash)
        assert.are.equal(0, #plugin.db.pending_progress)
    end)

    it("queues PDF bridge progress while offline and replays it later", function()
        local plugin = newPlugin({
            pdf_web_reader_bridge_enabled = true,
        })
        plugin.isOnline = function()
            return false
        end

        local snapshot = {
            document = "hash-6",
            bookHash = "hash-6",
            bookId = 31,
            bookFileId = 41,
            fileFormat = "PDF",
            progress = "41",
            location = "41",
            percentage = 41,
            currentPage = 41,
            totalPages = 100,
            device = "KOReader",
            deviceId = "device-1",
            timestamp = 800,
        }

        assert.is_false(plugin:pushPdfWebProgress(snapshot, "close", true))
        assert.are.equal(1, #plugin.db.pending_progress)
        assert.are.equal("pdf_bridge", plugin.db.pending_progress[1].kind)

        plugin.isOnline = function()
            return true
        end
        local update_calls = {}
        plugin.api.updatePdfProgress = function(_, book_id, payload)
            update_calls[#update_calls + 1] = { book_id = book_id, payload = payload }
            return true, { currentPage = 41, totalPages = 100, percentage = 41, timestamp = 900 }, 200
        end

        local synced, failed = plugin:syncPendingProgress(true)
        assert.are.equal(1, synced)
        assert.are.equal(0, failed)
        assert.are.equal(1, #update_calls)
        assert.are.equal(31, update_calls[1].book_id)
        assert.are.equal("hash-6", update_calls[1].payload.bookHash)
        assert.are.equal(0, #plugin.db.pending_progress)
    end)

    it("uses bookType when batching reading sessions", function()
        local plugin = newPlugin()
        plugin.db.pending_sessions = {
            {
                id = 1,
                bookId = 99,
                bookHash = "hash-7",
                bookType = "PDF",
                device = "KOReader",
                deviceId = "device-1",
                startTime = "2026-05-07T00:00:00Z",
                endTime = "2026-05-07T00:05:00Z",
                durationSeconds = 300,
                duration_formatted = "5m 0s",
                startProgress = 10,
                endProgress = 20,
                progressDelta = 10,
                startLocation = "/10",
                endLocation = "/20",
                currentPage = 20,
                totalPages = 100,
            },
            {
                id = 2,
                bookId = 99,
                bookHash = "hash-7",
                bookType = "PDF",
                device = "KOReader",
                deviceId = "device-1",
                startTime = "2026-05-07T00:06:00Z",
                endTime = "2026-05-07T00:10:00Z",
                durationSeconds = 240,
                duration_formatted = "4m 0s",
                startProgress = 20,
                endProgress = 30,
                progressDelta = 10,
                startLocation = "/20",
                endLocation = "/30",
                currentPage = 30,
                totalPages = 100,
            },
        }

        local batch_calls = {}
        plugin.api.submitSessionBatch = function(_, book_id, book_hash, book_type, device, device_id, sessions)
            batch_calls[#batch_calls + 1] = {
                book_id = book_id,
                book_hash = book_hash,
                book_type = book_type,
                device = device,
                device_id = device_id,
                sessions = sessions,
            }
            return true, { status = "ok" }, 200
        end

        local synced, failed = plugin:syncPendingSessions(true)
        assert.are.equal(2, synced)
        assert.are.equal(0, failed)
        assert.are.equal(1, #batch_calls)
        assert.are.equal("PDF", batch_calls[1].book_type)
        assert.are.equal(2, #batch_calls[1].sessions)
    end)

    it("caches successful book matches by hash", function()
        local plugin = newPlugin()
        plugin.api.next_book = {
            success = true,
            response = {
                id = 123,
                bookFileId = 456,
                title = "Demo Book",
                author = "Author",
            },
            code = 200,
        }

        local matched = plugin:resolveBookByHash("/books/demo.epub", "hash-8", true)
        assert.is_not_nil(matched)
        assert.are.equal(123, matched.book_id)
        assert.are.equal(456, matched.bookFileId)
        assert.are.equal("/books/demo.epub", plugin.db.book_cache_calls[1].file_path)
        assert.are.equal("hash-8", plugin.db.book_cache_calls[1].file_hash)
    end)

    it("shows guided and advanced connection labels in the menu", function()
        local plugin = newPlugin()
        local menu = {}
        plugin:addToMainMenu(menu)

        local connection_menu = findMenuItem(menu.grimmlink.sub_item_table, "Connection")
        assert.is_not_nil(connection_menu)
        local setup_item = findMenuItem(connection_menu.sub_item_table, "Setup")
        assert.is_not_nil(setup_item)
        local advanced_item = findMenuItem(connection_menu.sub_item_table, "Advanced")
        assert.is_not_nil(advanced_item)
        local password_item = findMenuItem(advanced_item.sub_item_table, "Password")
        assert.is_not_nil(password_item)
    end)
end)
