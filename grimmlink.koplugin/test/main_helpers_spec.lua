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
local json = require("json")
local NetworkMgr = require("ui/network/manager")
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

local function findMenuItemByContains(items, expected_part)
    for _, item in ipairs(items or {}) do
        local text = getMenuItemText(item)
        if type(text) == "string" and text:find(expected_part, 1, true) ~= nil then
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
        pending_metadata_items = {},
        synced_metadata_items = {},
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

    function db:upsertPendingMetadataItem(item)
        local existing = nil
        for _, row in ipairs(self.pending_metadata_items) do
            if row.file_hash == item.file_hash
                and row.item_type == item.item_type
                and row.dedupe_key == item.dedupe_key then
                existing = row
                break
            end
        end
        if existing then
            existing.book_id = item.book_id
            existing.book_file_id = item.book_file_id
            existing.payload_json = item.payload_json
            existing.retry_count = 0
            existing.last_retry_at = nil
            existing.updated_at = os.time()
            return true
        end

        self.pending_metadata_items[#self.pending_metadata_items + 1] = {
            id = #self.pending_metadata_items + 1,
            file_hash = item.file_hash,
            book_id = item.book_id,
            book_file_id = item.book_file_id,
            item_type = item.item_type,
            dedupe_key = item.dedupe_key,
            payload_json = item.payload_json,
            retry_count = 0,
            last_retry_at = nil,
            created_at = os.time(),
            updated_at = os.time(),
        }
        return true
    end

    function db:getPendingMetadataItems(_limit)
        return self.pending_metadata_items
    end

    function db:deletePendingMetadataItem(id)
        for index, row in ipairs(self.pending_metadata_items) do
            if row.id == id then
                table.remove(self.pending_metadata_items, index)
                return true
            end
        end
        return false
    end

    function db:incrementPendingMetadataRetry(id)
        for _, row in ipairs(self.pending_metadata_items) do
            if row.id == id then
                row.retry_count = (row.retry_count or 0) + 1
                row.last_retry_at = os.time()
                row.updated_at = os.time()
                return true
            end
        end
        return false
    end

    function db:markMetadataItemSynced(item)
        local existing = nil
        for _, row in ipairs(self.synced_metadata_items) do
            if row.file_hash == item.file_hash
                and row.item_type == item.item_type
                and row.dedupe_key == item.dedupe_key then
                existing = row
                break
            end
        end
        if existing then
            existing.book_id = item.book_id
            existing.server_id = item.server_id
            existing.synced_at = os.time()
            return true
        end

        self.synced_metadata_items[#self.synced_metadata_items + 1] = {
            file_hash = item.file_hash,
            book_id = item.book_id,
            item_type = item.item_type,
            dedupe_key = item.dedupe_key,
            server_id = item.server_id,
            synced_at = os.time(),
        }
        return true
    end

    function db:isMetadataItemSynced(file_hash, item_type, dedupe_key)
        for _, row in ipairs(self.synced_metadata_items) do
            if row.file_hash == file_hash and row.item_type == item_type and row.dedupe_key == dedupe_key then
                return true
            end
        end
        return false
    end

    function db:getPendingMetadataCount()
        return #self.pending_metadata_items
    end

    function db:deleteAllPendingMetadata()
        self.pending_metadata_items = {}
        return true
    end

    function db:clearSyncedMetadataHistory()
        self.synced_metadata_items = {}
        return true
    end

    function db:isTrackingEnabled(file_hash, file_path)
        self.book_tracking_state = self.book_tracking_state or {}
        local key = tostring(file_hash or "") .. "|" .. tostring(file_path or "")
        if self.book_tracking_state[key] == nil then
            return true
        end
        return self.book_tracking_state[key] == true
    end

    function db:setTrackingEnabled(file_hash, file_path, enabled)
        self.book_tracking_state = self.book_tracking_state or {}
        local key = tostring(file_hash or "") .. "|" .. tostring(file_path or "")
        self.book_tracking_state[key] = enabled == true
        return true
    end

    function db:toggleTracking(file_hash, file_path)
        local current = self:isTrackingEnabled(file_hash, file_path)
        local next_value = not current
        self:setTrackingEnabled(file_hash, file_path, next_value)
        return next_value
    end

    function db:getPendingCountsForFileHash(file_hash)
        local progress = 0
        local sessions = 0
        local metadata = 0
        for _, row in ipairs(self.pending_progress or {}) do
            if row.file_hash == file_hash then
                progress = progress + 1
            end
        end
        for _, row in ipairs(self.pending_sessions or {}) do
            if row.bookHash == file_hash or row.book_hash == file_hash then
                sessions = sessions + 1
            end
        end
        for _, row in ipairs(self.pending_metadata_items or {}) do
            if row.file_hash == file_hash then
                metadata = metadata + 1
            end
        end
        return { progress = progress, sessions = sessions, metadata = metadata }
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
        next_metadata_batch = { success = true, response = { ok = true, results = { annotations = {}, bookmarks = {} } }, code = 200 },
    }

    function api:init(...)
        self.init_args = { ... }
    end

    function api:setFallbackUrl(url)
        self.fallback_url = url
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

    function api:buildMetadataBatchPayload(book_id, book_hash, book_file_id, file_format, device, device_id, rating, annotations, bookmarks)
        return {
            schemaVersion = 1,
            syncMode = "incremental",
            bookId = book_id,
            bookHash = book_hash,
            bookFileId = book_file_id,
            fileFormat = file_format,
            device = device,
            deviceId = device_id,
            rating = rating,
            annotations = annotations or {},
            bookmarks = bookmarks or {},
        }
    end

    function api:submitMetadataBatch(payload)
        self.calls[#self.calls + 1] = { name = "submitMetadataBatch", payload = payload }
        return self.next_metadata_batch.success, self.next_metadata_batch.response, self.next_metadata_batch.code
    end

    return api
end

local function newPlugin(overrides)
    local plugin = {
        enabled = true,
        server_url = "http://example.com",
        remote_url = "",
        local_url_nickname = "",
        remote_url_nickname = "",
        home_ssid = "",
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
        metadata_sync_enabled = false,
        rating_sync_enabled = true,
        annotations_sync_enabled = true,
        bookmarks_sync_enabled = true,
        metadata_retry_max = 5,
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
        NetworkMgr.getCurrentNetwork = nil
        NetworkMgr.getCurrentSSID = nil
        NetworkMgr.getSSID = nil
    end)

    it("keeps the PDF Web Reader Bridge disabled by default", function()
        local plugin = newPlugin()
        assert.is_false(plugin:isPdfWebReaderBridgeEnabled())
        plugin.pdf_web_reader_bridge_enabled = true
        assert.is_true(plugin:isPdfWebReaderBridgeEnabled())
    end)

    it("builds native EPUB progress payloads without bridge-specific fields or percentage", function()
        local plugin = newPlugin()
        plugin.send_reflowable_percentage = false
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
        assert.is_nil(payload.percentage)
        assert.is_nil(payload.cfi)
        assert.is_nil(payload.rawKoreaderLocation)
    end)

    it("builds native EPUB progress payloads with percentage when reflowable percentage is enabled", function()
        local plugin = newPlugin()
        plugin.send_reflowable_percentage = true
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

        assert.are.equal(12.5, payload.percentage)
        assert.is_nil(payload.cfi)
    end)

    it("builds native fixed-page payloads with percentage intact", function()
        local plugin = newPlugin()
        local payload = plugin:prepareNativeProgressPayload({
            document = "hash-pdf",
            bookHash = "hash-pdf",
            bookId = 17,
            bookFileId = 19,
            fileFormat = "PDF",
            progress = "40",
            location = "40",
            percentage = 40.0,
            currentPage = 40,
            totalPages = 100,
            device = "KOReader",
            deviceId = "device-1",
            timestamp = 123,
        })

        assert.are.equal("PDF", payload.fileFormat)
        assert.are.equal(40.0, payload.percentage)
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
        assert.is_true(plugin:isReflowableFormat("/books/novel.epub", "EPUB", "EPUB"))
        assert.is_false(plugin:isReflowableFormat("/books/manual.pdf", "PDF", "PDF"))
        assert.is_true(plugin:isFixedPageFormat("/books/comic.cbz", "CBX", "CBX"))
        assert.is_false(plugin:isFixedPageFormat("/books/novel.epub", "EPUB", "EPUB"))
    end)

    it("prefers xpointer over numeric current position for reflowable snapshot", function()
        local plugin = newPlugin()
        plugin.ui.document.getCurrentPos = function()
            return 1
        end
        plugin.ui.document.getXPointer = function()
            return "/body/4/10"
        end

        local snapshot = plugin:getCurrentProgressSnapshot("hash-xp", "/books/demo.epub", 11, 12)
        assert.are.equal("/body/4/10", snapshot.location)
        assert.are.equal("/body/4/10", snapshot.progress)
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

    it("applies remote EPUB progress using native location only", function()
        local plugin = newPlugin()
        local location_jump = nil
        local page_jump = nil
        plugin.jumpToLocation = function(_, location, opts)
            location_jump = { location = location, opts = opts }
            return true
        end
        plugin.jumpToPage = function(_, page)
            page_jump = page
            return true
        end

        local applied = plugin:applyRemoteProgress({
            fileFormat = "EPUB",
            progress = "/remote",
            location = "/remote",
            percentage = 80,
            currentPage = 80,
            totalPages = 100,
        })

        assert.is_true(applied)
        assert.are.equal("/remote", location_jump.location)
        assert.is_false(location_jump.opts.allow_numeric_page)
        assert.is_nil(page_jump)
    end)

    it("rejects remote EPUB percentage fallback without native location", function()
        local plugin = newPlugin()
        plugin.jumpToPage = function()
            return true
        end

        local applied = plugin:applyRemoteProgress({
            fileFormat = "EPUB",
            percentage = 80,
            currentPage = 80,
            totalPages = 100,
        })

        assert.is_false(applied)
        assert.are.equal("No KOReader-native location available for this book.", plugin._last_progress_apply_error)
    end)

    it("rejects numeric-only remote EPUB location to avoid jumping to first page", function()
        local plugin = newPlugin()
        plugin.jumpToLocation = function()
            return true
        end

        local applied = plugin:applyRemoteProgress({
            fileFormat = "EPUB",
            location = "1",
            progress = "1",
            percentage = 80,
            currentPage = 80,
            totalPages = 100,
        })

        assert.is_false(applied)
        assert.are.equal("No KOReader-native location available for this book.", plugin._last_progress_apply_error)
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

    it("queues close progress before scheduled sync so document close is not blocked by an immediate push", function()
        local plugin = newPlugin()
        local update_calls = 0
        local schedule_calls = 0
        local scheduled_opts = nil

        plugin.api.updateProgress = function()
            update_calls = update_calls + 1
            return true, {}, 200
        end
        plugin.schedulePendingSync = function(_, _label, _delay, opts)
            schedule_calls = schedule_calls + 1
            scheduled_opts = opts
        end
        plugin.ui.document.getCurrentPos = function()
            return "/100"
        end
        plugin.ui.document.getXPointer = function()
            return "/100"
        end
        plugin.ui.document.getCurrentPage = function()
            return 100
        end
        plugin.ui.paging.getCurrentPage = function()
            return 100
        end
        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-close-100",
            book_id = 21,
            book_file_id = 22,
            start_time = os.time() - 120,
            start_snapshot = {
                percentage = 90,
                currentPage = 90,
                totalPages = 100,
                location = "/90",
            },
            book_type = "EPUB",
        }

        assert.is_true(plugin:endSession({ reason = "close" }))
        assert.are.equal(0, update_calls)
        assert.are.equal(1, #plugin.db.pending_progress)
        assert.are.equal("native", plugin.db.pending_progress[1].kind)
        assert.are.equal(1, schedule_calls)
        assert.are.equal(10, scheduled_opts.progress_limit)
        assert.are.equal(25, scheduled_opts.session_limit)
    end)

    it("captures sessions and queues progress without an API client while offline", function()
        local plugin = newPlugin({
            api = nil,
            isOnline = function()
                return false
            end,
        })
        plugin.calculateBookHash = function()
            return "offline-hash"
        end

        plugin:startSession()
        assert.is_not_nil(plugin.current_session)
        assert.are.equal(nil, plugin.current_session.book_id)

        plugin.ui.document.getCurrentPos = function()
            return "/12"
        end
        plugin.ui.document.getXPointer = function()
            return "/12"
        end
        plugin.ui.document.getCurrentPage = function()
            return 12
        end
        plugin.ui.paging.getCurrentPage = function()
            return 12
        end
        plugin.current_session.start_time = os.time() - 120
        plugin.current_session.start_snapshot = {
            percentage = 4,
            currentPage = 4,
            totalPages = 100,
            location = "/4",
        }

        assert.is_true(plugin:endSession({ reason = "close" }))
        assert.are.equal(1, #plugin.db.pending_sessions)
        assert.are.equal(1, #plugin.db.pending_progress)
        assert.are.equal("native", plugin.db.pending_progress[1].kind)
    end)

    it("leaves pending queues untouched when the API client is not ready", function()
        local plugin = newPlugin({
            api = {},
        })
        plugin.db.pending_progress = {
            {
                id = 1,
                file_hash = "hash-api-not-ready",
                kind = "native",
                payload_json = {
                    bookHash = "hash-api-not-ready",
                    percentage = 42,
                },
                retry_count = 0,
            },
        }
        plugin.db.pending_sessions = {
            {
                id = 1,
                bookId = 21,
                bookHash = "hash-api-not-ready",
                bookType = "EPUB",
                device = "KOReader",
                deviceId = "device-1",
                startTime = "2026-05-26T00:00:00Z",
                endTime = "2026-05-26T00:02:00Z",
                durationSeconds = 120,
                startProgress = 40,
                endProgress = 42,
                progressDelta = 2,
                startLocation = "/40",
                endLocation = "/42",
                currentPage = 42,
                totalPages = 100,
            },
        }

        local progress_synced, progress_failed = plugin:syncPendingProgress(true)
        local sessions_synced, sessions_failed = plugin:syncPendingSessions(true)

        assert.is_false(plugin:isApiReady())
        assert.are.equal(0, progress_synced)
        assert.are.equal(0, progress_failed)
        assert.are.equal(0, sessions_synced)
        assert.are.equal(0, sessions_failed)
        assert.are.equal(1, #plugin.db.pending_progress)
        assert.are.equal(1, #plugin.db.pending_sessions)
    end)

    it("throttles automatic pending sync scheduling during the cooldown window", function()
        local plugin = newPlugin()
        local sync_calls = 0
        plugin.syncPendingNow = function()
            sync_calls = sync_calls + 1
        end

        plugin:schedulePendingSync("first auto sync", 0, {
            respect_cooldown = true,
            cooldown_seconds = 300,
        })
        plugin:schedulePendingSync("second auto sync", 0, {
            respect_cooldown = true,
            cooldown_seconds = 300,
        })

        assert.are.equal(1, sync_calls)
    end)

    it("queues exit progress without running a full pending sync on exit", function()
        local plugin = newPlugin()
        local full_sync_calls = 0
        local scheduled_sync_calls = 0
        plugin.syncPendingNow = function()
            full_sync_calls = full_sync_calls + 1
        end
        plugin.schedulePendingSync = function()
            scheduled_sync_calls = scheduled_sync_calls + 1
        end
        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-exit",
            book_id = 21,
            book_file_id = 22,
            start_time = os.time() - 120,
            start_snapshot = {
                percentage = 50,
                currentPage = 50,
                totalPages = 100,
                location = "/50",
            },
            book_type = "EPUB",
        }

        plugin:onExit()
        assert.are.equal(0, full_sync_calls)
        assert.are.equal(1, scheduled_sync_calls)
        assert.are.equal(1, #plugin.db.pending_progress)
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

    it("queues metadata items on close and dedupes on repeated close", function()
        local plugin = newPlugin()
        plugin.extractMetadataForContext = function()
            return {
                rating = { raw = 4, normalized = 8 },
                highlights = {
                    {
                        text = "Quote A",
                        note = "Note A",
                        datetime = "2026-05-27T10:00:00Z",
                        pos0 = "xp-1",
                        pos1 = "xp-2",
                    },
                },
                bookmarks = {
                    {
                        page = "12",
                        datetime = "2026-05-27T10:05:00Z",
                    },
                },
                counts = {
                    rating_present = true,
                    highlights_count = 1,
                    notes_count = 1,
                    bookmarks_count = 1,
                },
            }
        end
        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-meta-close",
            book_id = 50,
            book_file_id = 60,
            start_time = os.time() - 100,
            start_snapshot = {
                percentage = 20,
                currentPage = 20,
                totalPages = 100,
                location = "/20",
            },
            book_type = "EPUB",
        }

        assert.is_true(plugin:endSession({ reason = "close" }))
        assert.are.equal(3, #plugin.db.pending_metadata_items)

        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-meta-close",
            book_id = 50,
            book_file_id = 60,
            start_time = os.time() - 100,
            start_snapshot = {
                percentage = 25,
                currentPage = 25,
                totalPages = 100,
                location = "/25",
            },
            book_type = "EPUB",
        }
        assert.is_true(plugin:endSession({ reason = "close" }))
        assert.are.equal(3, #plugin.db.pending_metadata_items)
    end)

    it("queues metadata during manual sync when a current session exists", function()
        local plugin = newPlugin()
        plugin.extractMetadataForContext = function()
            return {
                rating = { raw = 5, normalized = 10 },
                highlights = {},
                bookmarks = {},
                counts = {
                    rating_present = true,
                    highlights_count = 0,
                    notes_count = 0,
                    bookmarks_count = 0,
                },
            }
        end
        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-meta-manual",
            book_id = 70,
            book_file_id = 71,
        }
        plugin.isOnline = function()
            return false
        end

        plugin:syncPendingNow(false)
        assert.are.equal(1, #plugin.db.pending_metadata_items)
        assert.are.equal("rating", plugin.db.pending_metadata_items[1].item_type)
    end)

    it("syncs pending metadata rows using per-item statuses", function()
        local plugin = newPlugin({
            metadata_sync_enabled = true,
        })
        plugin.db.pending_metadata_items = {
            {
                id = 1,
                file_hash = "hash-meta-sync",
                book_id = 70,
                book_file_id = 71,
                item_type = "rating",
                dedupe_key = "r-1",
                payload_json = json.encode({ rating = 4, datetime = "2026-05-27T00:00:00Z" }),
                retry_count = 0,
            },
            {
                id = 2,
                file_hash = "hash-meta-sync",
                book_id = 70,
                book_file_id = 71,
                item_type = "annotation",
                dedupe_key = "a-1",
                payload_json = json.encode({ text = "Highlight", pos0 = "xp-1", pos1 = "xp-2" }),
                retry_count = 0,
            },
            {
                id = 3,
                file_hash = "hash-meta-sync",
                book_id = 70,
                book_file_id = 71,
                item_type = "bookmark",
                dedupe_key = "b-1",
                payload_json = json.encode({ title = "Bookmark", page = "12" }),
                retry_count = 0,
            },
        }
        plugin.api.next_metadata_batch = {
            success = true,
            response = {
                ok = true,
                results = {
                    rating = { dedupeKey = "r-1", itemType = "rating", status = "synced", serverId = "11" },
                    annotations = { { dedupeKey = "a-1", itemType = "annotation", status = "duplicate", serverId = "12" } },
                    bookmarks = { { dedupeKey = "b-1", itemType = "bookmark", status = "updated", serverId = "13" } },
                },
            },
            code = 200,
        }

        local synced, failed = plugin:syncPendingMetadata(true)
        assert.are.equal(3, synced)
        assert.are.equal(0, failed)
        assert.are.equal(0, #plugin.db.pending_metadata_items)
        assert.are.equal(3, #plugin.db.synced_metadata_items)
    end)

    it("keeps failed metadata rows pending with retry increment", function()
        local plugin = newPlugin({
            metadata_sync_enabled = true,
        })
        plugin.db.pending_metadata_items = {
            {
                id = 1,
                file_hash = "hash-meta-retry",
                book_id = 70,
                book_file_id = 71,
                item_type = "annotation",
                dedupe_key = "a-retry",
                payload_json = json.encode({ text = "Highlight", pos0 = "xp-1" }),
                retry_count = 0,
            },
        }
        plugin.api.next_metadata_batch = {
            success = false,
            response = "HTTP 500",
            code = 500,
        }

        local synced, failed = plugin:syncPendingMetadata(true)
        assert.are.equal(0, synced)
        assert.are.equal(1, failed)
        assert.are.equal(1, #plugin.db.pending_metadata_items)
        assert.are.equal(1, plugin.db.pending_metadata_items[1].retry_count)
    end)

    it("drops invalid metadata rows and stops retrying after max retry", function()
        local plugin = newPlugin({
            metadata_sync_enabled = true,
            metadata_retry_max = 1,
        })
        plugin.db.pending_metadata_items = {
            {
                id = 1,
                file_hash = "hash-meta-invalid",
                book_id = 70,
                book_file_id = 71,
                item_type = "annotation",
                dedupe_key = "a-invalid",
                payload_json = json.encode({ text = "Highlight", pos0 = "xp-1" }),
                retry_count = 0,
            },
            {
                id = 2,
                file_hash = "hash-meta-drop",
                book_id = 70,
                book_file_id = 71,
                item_type = "bookmark",
                dedupe_key = "b-drop",
                payload_json = json.encode({ title = "Bookmark", page = "1" }),
                retry_count = 1,
            },
        }
        plugin.api.next_metadata_batch = {
            success = true,
            response = {
                ok = false,
                results = {
                    annotations = { { dedupeKey = "a-invalid", itemType = "annotation", status = "invalid", error = "invalid_payload" } },
                    bookmarks = { { dedupeKey = "b-drop", itemType = "bookmark", status = "failed", error = "server_error" } },
                },
            },
            code = 200,
        }

        local synced, failed = plugin:syncPendingMetadata(true)
        assert.are.equal(0, synced)
        assert.are.equal(2, failed)
        assert.are.equal(0, #plugin.db.pending_metadata_items)
    end)

    it("skips close auto sync/session/metadata when tracking is disabled for the book", function()
        local plugin = newPlugin()
        plugin.db:setTrackingEnabled("hash-track-off", "/books/demo.epub", false)
        plugin.extractMetadataForContext = function()
            return {
                rating = { raw = 5, normalized = 10 },
                highlights = { { text = "h1", pos0 = "p1" } },
                bookmarks = { { page = "1" } },
                counts = {
                    rating_present = true,
                    highlights_count = 1,
                    notes_count = 0,
                    bookmarks_count = 1,
                },
            }
        end
        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-track-off",
            book_id = 70,
            book_file_id = 71,
            start_time = os.time() - 120,
            start_snapshot = {
                percentage = 4,
                currentPage = 4,
                totalPages = 100,
                location = "/4",
            },
            book_type = "EPUB",
            tracking_enabled = false,
        }

        plugin:endSession({ reason = "close" })
        assert.are.equal(0, #plugin.db.pending_progress)
        assert.are.equal(0, #plugin.db.pending_sessions)
        assert.are.equal(0, #plugin.db.pending_metadata_items)
    end)

    it("exports debug info with redacted secrets", function()
        local plugin = newPlugin()
        plugin.password = "super-secret-password"
        plugin.server_url = "http://192.168.1.100:6060"
        plugin.remote_url = "https://example.com"
        plugin.home_ssid = "MyHomeWiFi"
        NetworkMgr.getCurrentNetwork = function()
            return { ssid = "CoffeeShop" }
        end
        plugin.file_logger = {
            getLogPath = function()
                return "/tmp/grimmlink.log"
            end,
        }

        plugin:exportDebugInfo()
        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.is_true(type(dialog.text) == "string")
        assert.is_true(dialog.text:find("GrimmLink Debug Info", 1, true) ~= nil)
        assert.is_true(dialog.text:find("super-secret-password", 1, true) == nil)
        assert.is_true(dialog.text:find("username: re...", 1, true) ~= nil)
        assert.is_true(dialog.text:find("active_url_source:", 1, true) ~= nil)
        assert.is_true(dialog.text:find("last_connection_error_category:", 1, true) ~= nil)
    end)

    it("keeps local URL regardless of SSID when local is configured", function()
        local plugin = newPlugin()
        plugin.server_url = "http://192.168.1.100:6060"
        plugin.remote_url = "https://example.com"

        local current_ssid = "HomeWiFi"
        NetworkMgr.getCurrentNetwork = function()
            return { ssid = current_ssid }
        end

        local first = plugin:resolveServerUrl(true)
        assert.are.equal("http://192.168.1.100:6060", first)
        assert.are.equal("local", plugin.active_url_source)
        assert.are.equal("local_first_policy", plugin.last_url_switch_reason)

        current_ssid = "CoffeeShop"
        local second = plugin:resolveServerUrl(true)
        assert.are.equal("http://192.168.1.100:6060", second)
        assert.are.equal("local", plugin.active_url_source)
        assert.are.equal("local_first_policy", plugin.last_url_switch_reason)
    end)

    it("uses remote when local recently failed", function()
        local plugin = newPlugin()
        plugin.server_url = "http://192.168.1.100:6060"
        plugin.remote_url = "https://example.com"
        plugin.local_fail_cooldown_seconds = 60

        plugin.api = {
            getLastPrimaryFailure = function()
                return {
                    url = "http://192.168.1.100:6060",
                    at = os.time(),
                    error = "timeout",
                }
            end,
        }
        NetworkMgr.getCurrentNetwork = function()
            return nil
        end

        local selected = plugin:resolveServerUrl(true)
        assert.are.equal("https://example.com", selected)
        assert.are.equal("fallback", plugin.active_url_source)
        assert.are.equal("local_recently_failed", plugin.last_url_switch_reason)
    end)

    it("sets fallback only when active source is local", function()
        local plugin = newPlugin()
        plugin.server_url = "http://192.168.1.100:6060"
        plugin.remote_url = "https://example.com"
        plugin.local_request_timeout_seconds = 2
        plugin.remote_request_timeout_seconds = 1

        NetworkMgr.getCurrentNetwork = function() return { ssid = "AnyWiFi" } end

        plugin:refreshApiClient(true)
        assert.are.equal("https://example.com", plugin.api.fallback_url)
        assert.are.equal(2, plugin.api.timeout)
        assert.are.equal(1, plugin.api.fallback_timeout)

        plugin._local_fail_cooldown_until = os.time() + 30
        plugin:refreshApiClient(true)
        assert.is_nil(plugin.api.fallback_url)
        assert.are.equal(1, plugin.api.timeout)
        assert.are.equal(1, plugin.api.fallback_timeout)
    end)

    it("uses URL nickname for target display when configured", function()
        local plugin = newPlugin()
        plugin.local_url_nickname = "My Home API"
        plugin.remote_url_nickname = "My Remote API"

        local local_target = plugin:getTargetDisplayLabel("local")
        assert.are.equal("My Home API", local_target)

        local remote_target = plugin:getTargetDisplayLabel("remote")
        assert.are.equal("My Remote API", remote_target)
    end)

    it("allows setup flow to skip immediate test prompt via saveConnectionSettings options", function()
        local plugin = newPlugin()
        local prompted = false
        local saved_callback = false
        plugin.promptTestConnectionAfterSetup = function()
            prompted = true
        end

        plugin:saveConnectionSettings("http://192.168.1.10:6060", "reader", "secret", "https://grimmory.example.com", {
            prompt_test = false,
            on_saved = function()
                saved_callback = true
            end,
        })

        assert.are.equal("http://192.168.1.10:6060", plugin.server_url)
        assert.are.equal("https://grimmory.example.com", plugin.remote_url)
        assert.are.equal("reader", plugin.username)
        assert.are.equal("secret", plugin.password)
        assert.is_true(saved_callback)
        assert.is_false(prompted)
    end)

    it("skips immediate onNetworkConnected sync during resume grace window", function()
        local plugin = newPlugin()
        local refresh_calls = 0
        local scheduled_calls = 0
        plugin.ensureMainMenuRegistered = function() end
        plugin.refreshApiClient = function()
            refresh_calls = refresh_calls + 1
            return true
        end
        plugin.schedulePendingSync = function()
            scheduled_calls = scheduled_calls + 1
        end
        plugin.sync_on_network_connected = true
        plugin.resume_network_grace_seconds = 8
        plugin.isOnline = function() return true end

        plugin:onResume()
        assert.is_true(refresh_calls >= 1)
        assert.are.equal(1, scheduled_calls)

        plugin:onNetworkConnected()
        assert.are.equal(1, scheduled_calls)

        plugin._last_resume_at = os.time() - 20
        plugin:onNetworkConnected()
        assert.are.equal(2, scheduled_calls)
    end)

    it("shows metadata preview with counts and pending metadata total", function()
        local plugin = newPlugin()
        plugin.db.pending_metadata_items = {
            { id = 1, file_hash = "a", item_type = "rating", dedupe_key = "a:rating" },
            { id = 2, file_hash = "a", item_type = "annotation", dedupe_key = "a:annotation:x" },
        }
        plugin.extractMetadataForContext = function()
            return {
                rating = { raw = 3, normalized = 6 },
                highlights = { { text = "h1" }, { text = "h2" } },
                bookmarks = { { page = 1 } },
                counts = {
                    rating_present = true,
                    highlights_count = 2,
                    notes_count = 1,
                    bookmarks_count = 1,
                },
            }
        end

        plugin:showMetadataPreview()
        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.is_true(type(dialog.text) == "string")
        assert.is_true(dialog.text:find("Metadata Preview", 1, true) ~= nil)
        assert.is_true(dialog.text:find("Pending metadata: 2", 1, true) ~= nil)
    end)

    it("shows a message when manual metadata sync is disabled", function()
        local plugin = newPlugin({
            metadata_sync_enabled = false,
        })
        local last_message = nil
        local sync_called = false
        plugin.showMessage = function(_, text)
            last_message = text
        end
        plugin.syncPendingMetadata = function()
            sync_called = true
            return 0, 0
        end

        plugin:syncMetadataNow()

        assert.are.equal("Metadata sync is disabled", last_message)
        assert.is_false(sync_called)
    end)

    it("shows progress/result messages for manual metadata sync", function()
        local plugin = newPlugin({
            metadata_sync_enabled = true,
        })
        plugin.db.pending_metadata_items = {
            { id = 1, file_hash = "a", item_type = "rating", dedupe_key = "a:rating" },
        }
        local messages = {}
        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end
        plugin.extractAndQueueCurrentMetadata = function()
            return {
                queued = {
                    queued = 2,
                    failed = 1,
                },
            }
        end
        plugin.syncPendingMetadata = function(_, silent)
            assert.is_true(silent)
            return 1, 0
        end

        plugin:syncMetadataNow()

        assert.is_true(#messages >= 2)
        assert.are.equal("Syncing metadata...", messages[1])
        assert.is_true(messages[#messages]:find("Metadata sync result", 1, true) ~= nil)
    end)

    it("opens manual path input directly for magic folder selection", function()
        local plugin = newPlugin({
            download_dir = "/sdcard/koreader",
        })

        plugin:showMagicDirectoryInputChooser(function() end)
        local input_dialog = UIManager.getLastShown()
        assert.is_not_nil(input_dialog)
        assert.are.equal("Magic Download Directory", input_dialog.title)
        assert.is_true(type(input_dialog.input) == "string" and input_dialog.input ~= "")
    end)

    it("auto-creates default magic directory when enabling separate mode without manual selection", function()
        local plugin = newPlugin({
            download_dir = "/sdcard/koreader/Book",
            magic_download_dir = "",
            use_separate_magic_download_dir = false,
        })
        local chooser_called = false
        local confirm_called = 0
        local saved_magic = nil
        local saved_enabled = nil

        plugin.validateMagicDownloadDirectory = function(_, path_value)
            return true, path_value
        end
        plugin.showMagicDirectoryInputChooser = function()
            chooser_called = true
        end
        plugin.showConfirmAction = function(_, _, _, _)
            confirm_called = confirm_called + 1
        end
        plugin.saveSetting = function(self, key, value)
            if key == "magic_download_dir" then
                saved_magic = value
                self.magic_download_dir = value
            elseif key == "use_separate_magic_download_dir" then
                saved_enabled = value
                self.use_separate_magic_download_dir = value
            end
            return true
        end

        plugin:enableSeparateMagicDownloadDirectory()

        assert.is_false(chooser_called)
        assert.are.equal("/sdcard/koreader/Book/Magic_Shelf", saved_magic)
        assert.is_true(saved_enabled)
        assert.are.equal(1, confirm_called)
    end)

    it("auto default magic directory follows resolved shared Book directory", function()
        local plugin = newPlugin({
            download_dir = "",
            magic_download_dir = "",
            use_separate_magic_download_dir = false,
        })
        local saved_magic = nil

        plugin.shelf_sync = {
            resolveDownloadDir = function(_, configured)
                assert.are.equal("", configured)
                return "/storage/emulated/0/koreader/Book"
            end,
        }
        plugin.validateMagicDownloadDirectory = function(_, path_value)
            return true, path_value
        end
        plugin.saveSetting = function(self, key, value)
            if key == "magic_download_dir" then
                saved_magic = value
                self.magic_download_dir = value
            elseif key == "use_separate_magic_download_dir" then
                self.use_separate_magic_download_dir = value
            end
            return true
        end
        plugin.showConfirmAction = function() end

        plugin:setSeparateMagicDownloadDirectoryDefault()

        assert.are.equal("/storage/emulated/0/koreader/Book/Magic_Shelf", saved_magic)
    end)

    it("does not append Magic_Shelf twice when download dir already points to magic shelf", function()
        local plugin = newPlugin({
            download_dir = "/sdcard/koreader/Book/Magic_shelf",
            magic_download_dir = "",
            use_separate_magic_download_dir = false,
        })
        local saved_magic = nil
        plugin.validateMagicDownloadDirectory = function(_, path_value)
            return true, path_value
        end
        plugin.saveSetting = function(self, key, value)
            if key == "magic_download_dir" then
                saved_magic = value
                self.magic_download_dir = value
            elseif key == "use_separate_magic_download_dir" then
                self.use_separate_magic_download_dir = value
            end
            return true
        end
        plugin.showConfirmAction = function() end

        plugin:setSeparateMagicDownloadDirectoryDefault()

        assert.are.equal("/sdcard/koreader/Book/Magic_shelf", saved_magic)
    end)

    it("collapses repeated trailing Magic_Shelf segments in auto default path", function()
        local plugin = newPlugin({
            download_dir = "/sdcard/koreader/Book/Magic_shelf/Magic_Shelf/Magic_shelf",
            magic_download_dir = "",
            use_separate_magic_download_dir = false,
        })
        local saved_magic = nil
        plugin.validateMagicDownloadDirectory = function(_, path_value)
            return true, path_value
        end
        plugin.saveSetting = function(self, key, value)
            if key == "magic_download_dir" then
                saved_magic = value
                self.magic_download_dir = value
            elseif key == "use_separate_magic_download_dir" then
                self.use_separate_magic_download_dir = value
            end
            return true
        end
        plugin.showConfirmAction = function() end

        plugin:setSeparateMagicDownloadDirectoryDefault()

        assert.are.equal("/sdcard/koreader/Book/Magic_shelf", saved_magic)
    end)

    it("uses resolved shared dir when moving Magic Shelf files back in auto mode", function()
        local plugin = newPlugin({
            download_dir = "",
            magic_download_dir = "/sdcard/koreader/Book/Magic_Shelf",
        })
        local captured_shared_dir = nil
        local captured_opts = nil
        plugin.shelf_sync = {
            resolveDownloadDir = function(_, configured)
                assert.are.equal("", configured)
                return "/sdcard/koreader/Book"
            end,
            moveMagicShelfFilesBackToSharedDirectory = function(_, shared_dir, opts)
                captured_shared_dir = shared_dir
                captured_opts = opts
                return { moved = 0, skipped = 0, failed = 0, shared = 0, sidecar_warnings = 0, errors = {} }
            end,
        }
        plugin.showMagicMoveSummary = function() end

        plugin:moveMagicShelfFilesBackToSharedDirectory()

        assert.are.equal("/sdcard/koreader/Book", captured_shared_dir)
        assert.are.equal("/sdcard/koreader/Book", captured_opts.download_dir)
        assert.are.equal("/sdcard/koreader/Book/Magic_Shelf", captured_opts.magic_dir)
    end)

    it("uses resolved shared dir when moving Magic Shelf files to magic folder in auto mode", function()
        local plugin = newPlugin({
            download_dir = "",
            magic_download_dir = "/sdcard/koreader/Book/Magic_Shelf",
        })
        local captured_target_dir = nil
        local captured_opts = nil
        plugin.shelf_sync = {
            resolveDownloadDir = function(_, configured)
                assert.are.equal("", configured)
                return "/sdcard/koreader/Book"
            end,
            moveMagicShelfFilesToDirectory = function(_, target_dir, opts)
                captured_target_dir = target_dir
                captured_opts = opts
                return { moved = 0, skipped = 0, failed = 0, shared = 0, sidecar_warnings = 0, errors = {} }
            end,
        }
        plugin.showMagicMoveSummary = function() end

        plugin:moveMagicShelfFilesToMagicDirectory()

        assert.are.equal("/sdcard/koreader/Book/Magic_Shelf", captured_target_dir)
        assert.are.equal("/sdcard/koreader/Book", captured_opts.shared_dir)
        assert.are.equal("/sdcard/koreader/Book", captured_opts.download_dir)
    end)

    it("shows connection and settings items in the restructured menu", function()
        local plugin = newPlugin()
        local menu = {}
        plugin:addToMainMenu(menu)

        local top = menu.grimmlink.sub_item_table
        local status_menu = findMenuItem(top, "Status / About")
        assert.is_not_nil(status_menu)
        local connection_menu = findMenuItem(top, "Connection")
        assert.is_not_nil(connection_menu)
        local setup_item = findMenuItem(connection_menu.sub_item_table, "Setup Connection")
        assert.is_not_nil(setup_item)
        local local_nickname_item = findMenuItem(connection_menu.sub_item_table, "Home URL Nickname")
        assert.is_nil(local_nickname_item)
        local remote_nickname_item = findMenuItem(connection_menu.sub_item_table, "Remote URL Nickname")
        assert.is_nil(remote_nickname_item)
        local test_item = findMenuItem(connection_menu.sub_item_table, "Test Connection")
        assert.is_not_nil(test_item)
        local test_diag_item = findMenuItem(connection_menu.sub_item_table, "Test Connection with Diagnostics")
        assert.is_not_nil(test_diag_item)
        local password_item = findMenuItem(connection_menu.sub_item_table, "Password")
        assert.is_not_nil(password_item)
        local advanced_menu = findMenuItem(top, "Advanced Setting")
        assert.is_not_nil(advanced_menu)
        local metadata_menu = findMenuItem(advanced_menu.sub_item_table, "Metadata Sync")
        assert.is_not_nil(metadata_menu)
        local preview_item = findMenuItem(metadata_menu.sub_item_table, "Preview Metadata")
        assert.is_not_nil(preview_item)
        local device_menu = findMenuItem(advanced_menu.sub_item_table, "Device Identity")
        assert.is_not_nil(device_menu)
        assert.is_not_nil(findMenuItemByContains(device_menu.sub_item_table, "Device Name:"))
        assert.is_not_nil(findMenuItemByContains(device_menu.sub_item_table, "Device ID:"))

        local shelf_menu = findMenuItem(advanced_menu.sub_item_table, "Shelf Sync Settings")
        assert.is_not_nil(shelf_menu)
        local download_settings = findMenuItem(shelf_menu.sub_item_table, "Download Settings")
        assert.is_not_nil(download_settings)

        local shelf_dir_item = findMenuItem(download_settings.sub_item_table, "Shelf Sync Download Directory")
        assert.is_not_nil(shelf_dir_item)
        assert.is_nil(shelf_dir_item.checked_func)
        local current_mode_item = findMenuItemByContains(shelf_dir_item.sub_item_table, "Current:")
        assert.is_not_nil(current_mode_item)
        assert.is_not_nil(findMenuItem(shelf_dir_item.sub_item_table, "Default (Auto)"))
        assert.is_not_nil(findMenuItem(shelf_dir_item.sub_item_table, "Select folder"))

        local separate_magic_item = findMenuItemByContains(download_settings.sub_item_table, "Separate magic shelf folder:")
        assert.is_not_nil(separate_magic_item)
        assert.is_not_nil(findMenuItem(separate_magic_item.sub_item_table, "Turn ON"))
        assert.is_not_nil(findMenuItem(separate_magic_item.sub_item_table, "Default (Auto)"))
        assert.is_not_nil(findMenuItem(separate_magic_item.sub_item_table, "Select folder"))
    end)

    it("saves configured device identity with normalized display text", function()
        local plugin = newPlugin()
        local message_count = 0

        plugin.showTextInput = function(_, title, current_value, _, _, on_save)
            if title == "Device Name" then
                assert.are.equal("KOReader", current_value)
                on_save("  Kindle   PW5  ")
            elseif title == "Device ID" then
                assert.are.equal("device-1", current_value)
                on_save("  kindle-pw5-main  ")
            else
                error("unexpected input title: " .. tostring(title))
            end
        end
        plugin.showMessage = function()
            message_count = message_count + 1
        end

        plugin:configureDeviceName()
        plugin:configureDeviceId()

        assert.are.equal("Kindle PW5", plugin.device_name)
        assert.are.equal("kindle-pw5-main", plugin.device_id)
        assert.are.equal("Kindle PW5", plugin.db.settings.device_name)
        assert.are.equal("kindle-pw5-main", plugin.db.settings.device_id)
        assert.are.equal(2, message_count)
    end)

    it("asks to move files back when disabling separate magic folder", function()
        local plugin = newPlugin({
            use_separate_magic_download_dir = true,
        })
        local confirm_calls = 0
        plugin.showConfirmAction = function()
            confirm_calls = confirm_calls + 1
        end

        plugin:disableSeparateMagicDownloadDirectory()

        assert.is_false(plugin.use_separate_magic_download_dir)
        assert.are.equal(1, confirm_calls)
    end)

    it("shows Turn OFF action in separate magic submenu when already enabled", function()
        local plugin = newPlugin({
            use_separate_magic_download_dir = true,
        })
        local menu = {}
        plugin:addToMainMenu(menu)
        local top = menu.grimmlink.sub_item_table
        local advanced_menu = findMenuItem(top, "Advanced Setting")
        assert.is_not_nil(advanced_menu)
        local shelf_menu = findMenuItem(advanced_menu.sub_item_table, "Shelf Sync Settings")
        assert.is_not_nil(shelf_menu)
        local download_settings = findMenuItem(shelf_menu.sub_item_table, "Download Settings")
        assert.is_not_nil(download_settings)
        local separate_magic_item = findMenuItemByContains(download_settings.sub_item_table, "Separate magic shelf folder:")
        assert.is_not_nil(separate_magic_item)
        assert.is_not_nil(findMenuItem(separate_magic_item.sub_item_table, "Turn OFF"))
    end)

    it("shows planning batch size control in shelf sync behavior settings", function()
        local plugin = newPlugin()
        local menu = {}
        plugin:addToMainMenu(menu)

        local top = menu.grimmlink.sub_item_table
        local advanced_menu = findMenuItem(top, "Advanced Setting")
        assert.is_not_nil(advanced_menu)
        local shelf_menu = findMenuItem(advanced_menu.sub_item_table, "Shelf Sync Settings")
        assert.is_not_nil(shelf_menu)
        local behavior_menu = findMenuItem(shelf_menu.sub_item_table, "Sync Behavior")
        assert.is_not_nil(behavior_menu)

        local found = false
        for _, item in ipairs(behavior_menu.sub_item_table or {}) do
            local text = getMenuItemText(item)
            if type(text) == "string" and text:find("Planning Batch Size", 1, true) then
                found = true
                break
            end
        end
        assert.is_true(found)
    end)

    it("hides Pull Remote Progress in top menu when no active reading session", function()
        local plugin = newPlugin()
        local menu = {}
        plugin:addToMainMenu(menu)
        local top = menu.grimmlink.sub_item_table
        local pull_item = findMenuItem(top, "Pull Remote Progress")
        local manual_status_item = findMenuItem(top, "Manual Reading Status")
        local toggle_item = findMenuItem(top, "Toggle Tracking (Current Book)")
        assert.is_nil(pull_item)
        assert.is_nil(manual_status_item)
        assert.is_nil(toggle_item)
    end)

    it("shows Pull Remote Progress in top menu during active reading session", function()
        local plugin = newPlugin()
        plugin.current_session = {
            file_path = "/books/demo.epub",
            book_id = 123,
        }
        local menu = {}
        plugin:addToMainMenu(menu)
        local top = menu.grimmlink.sub_item_table
        local pull_item = findMenuItem(top, "Pull Remote Progress")
        local manual_status_item = findMenuItem(top, "Manual Reading Status")
        assert.is_not_nil(pull_item)
        assert.is_not_nil(manual_status_item)
    end)

    it("registers long-press file actions via FileManager file dialog buttons API", function()
        local rows = {}
        local plugin = newPlugin({
            ui = {
                file_dialog = { id = "dialog" },
                addFileDialogButtons = function(_, row_id, row_func)
                    rows[row_id] = row_func
                end,
            },
        })
        local calls = {}
        plugin.syncThisBookFromPath = function(_, file_path)
            calls[#calls + 1] = { name = "sync", file_path = file_path }
        end
        plugin.toggleTrackingByPath = function(_, file_path)
            calls[#calls + 1] = { name = "toggle", file_path = file_path }
        end
        plugin.matchBookByPath = function(_, file_path)
            calls[#calls + 1] = { name = "match", file_path = file_path }
        end
        plugin.showBookDebugInfoByPath = function(_, file_path)
            calls[#calls + 1] = { name = "debug", file_path = file_path }
        end

        assert.is_true(plugin:registerFileManagerHoldActions())
        assert.is_not_nil(rows.grimmlink_file_dialog_separator)
        assert.is_not_nil(rows.grimmlink_file_dialog_primary)
        assert.is_not_nil(rows.grimmlink_file_dialog_secondary)

        local separator = rows.grimmlink_file_dialog_separator("/books/demo.epub", true, nil)
        assert.are.same({}, separator)

        local primary = rows.grimmlink_file_dialog_primary("/books/demo.epub", true, nil)
        assert.are.equal(3, #primary)
        primary[1].callback()
        primary[2].callback()
        primary[3].callback()

        local secondary = rows.grimmlink_file_dialog_secondary("/books/demo.epub", true, nil)
        assert.are.equal(1, #secondary)
        secondary[1].callback()

        assert.are.equal(4, #calls)
        assert.are.equal("sync", calls[1].name)
        assert.are.equal("toggle", calls[2].name)
        assert.are.equal("match", calls[3].name)
        assert.are.equal("debug", calls[4].name)
        for _, call in ipairs(calls) do
            assert.are.equal("/books/demo.epub", call.file_path)
        end

        assert.is_nil(rows.grimmlink_file_dialog_primary("/books", false, nil))
    end)

    it("does not reuse legacy shelf-books cache key across explicit shelf types", function()
        local plugin = newPlugin()
        plugin._shelf_books_cache = {
            ["2"] = {
                ts = os.time(),
                books = {
                    { bookId = 999 },
                },
            },
        }

        local magic_books = plugin:getCachedShelfBooks(2, "magic", 120)
        assert.is_nil(magic_books)

        local legacy_books = plugin:getCachedShelfBooks(2, nil, 120)
        assert.is_not_nil(legacy_books)
        assert.are.equal(1, #legacy_books)
        assert.are.equal(999, legacy_books[1].bookId)
    end)

    it("uses configured shelf_plan_batch_size when preparing shelf sync plan", function()
        local captured_plan_batch_size = nil
        local plugin = newPlugin({
            shelf_sync_enabled = true,
            sync_regular_shelf_enabled = true,
            selected_regular_shelf_id = 7,
            selected_regular_shelf_name = "Regular Shelf",
            sync_magic_shelf_enabled = false,
            shelf_plan_batch_size = 123,
            requireReady = function() return true end,
            refreshApiClient = function() return true end,
            isOnline = function() return true end,
            readShelfSnapshotToken = function() return nil end,
        })
        plugin.shelf_sync = {
            prepareSyncPlan = function(_, opts)
                captured_plan_batch_size = opts.plan_batch_size
                return {
                    result = {
                        synced = 0,
                        skipped = 0,
                        failed = 0,
                        deleted = 0,
                        errors = {},
                        snapshot_unchanged = true,
                        snapshot_token = "token",
                    },
                    download_queue = {},
                    cleanup = {
                        remote_delete_sync = false,
                        downloaded_files_to_refresh = {},
                        downloaded_files_to_refresh_set = {},
                    },
                }
            end,
        }

        plugin:syncShelfNow(true)
        assert.are.equal(123, captured_plan_batch_size)
    end)

    it("uses live release checks for manual update checks", function()
        local plugin = newPlugin()
        local captured_use_cache = nil
        plugin.updater = {
            setAllowPrerelease = function() end,
            checkForUpdates = function(_, use_cache)
                captured_use_cache = use_cache
                return {
                    available = false,
                    current_version = "v1.0.1",
                    latest_version = "v1.0.1",
                }, nil
            end,
        }

        local result, err = plugin:checkForUpdates(false)
        assert.is_nil(err)
        assert.is_not_nil(result)
        assert.is_false(captured_use_cache)
    end)

    it("asks before installing on startup when auto update and startup checks are enabled", function()
        local plugin = newPlugin({
            auto_update_enabled = true,
            check_update_on_startup = true,
        })
        local seen_use_cache = nil
        local install_calls = 0
        plugin.updater = {
            setAllowPrerelease = function() end,
            checkForUpdates = function(_, use_cache)
                seen_use_cache = use_cache
                return {
                    available = true,
                    current_version = "v1.0.1",
                    latest_version = "v1.0.2",
                    release_info = {
                        download_url = "https://example.invalid/grimmlink.koplugin.zip",
                    },
                }, nil
            end,
            installUpdate = function(_, release_info)
                install_calls = install_calls + 1
                return release_info ~= nil, release_info and nil or "missing release"
            end,
        }

        plugin:maybeCheckForUpdatesOnStartup()
        assert.is_false(seen_use_cache)
        assert.are.equal(0, install_calls)

        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.is_true(type(dialog.ok_callback) == "function")

        dialog.ok_callback()
        assert.are.equal(1, install_calls)
    end)

    it("skips metadata index/cache writes for unchanged snapshot with no downloads", function()
        local write_index_called = 0
        local upsert_cache_called = 0
        local plugin = newPlugin({
            shelf_sync_enabled = true,
            sync_regular_shelf_enabled = true,
            selected_regular_shelf_id = 1,
            selected_regular_shelf_name = "Regular Shelf",
            sync_magic_shelf_enabled = false,
            two_way_shelf_delete_sync = false,
            shelf_fast_sync_enabled = false,
            download_dir = "/storage/emulated/0/koreader/books/Book",
            refreshApiClient = function() return true end,
            requireReady = function() return true end,
        })
        plugin.shelf_sync = {
            prepareSyncPlan = function()
                return {
                    result = {
                        synced = 0,
                        skipped = 5,
                        failed = 0,
                        deleted = 0,
                        errors = {},
                        snapshot_token = "snapshot-token",
                        snapshot_unchanged = true,
                    },
                    download_queue = {},
                    cleanup = {
                        shelf_id = 1,
                        shelf_type = "regular",
                        download_dir = "/storage/emulated/0/koreader/books/Book",
                        delete_sdr = false,
                        remote_delete_sync = false,
                        sync_start = os.time(),
                        downloaded_files_to_refresh = {},
                        downloaded_files_to_refresh_set = {},
                    },
                }
            end,
            resolveDownloadDir = function(_, dir) return dir end,
            writeMetadataIndex = function()
                write_index_called = write_index_called + 1
                return "/tmp/index.json"
            end,
            upsertBookInfoCache = function()
                upsert_cache_called = upsert_cache_called + 1
                return { inserted = 0, updated = 0, skipped = 0 }
            end,
        }

        local result = plugin:syncShelfNow(true)
        assert.is_nil(result)
        assert.are.equal(0, write_index_called)
        assert.are.equal(0, upsert_cache_called)
    end)
end)
