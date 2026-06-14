local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

package.loaded["main"] = nil
package.loaded["grimmlink_updater"] = nil
package.loaded["grimmlink_database"] = nil
package.loaded["grimmlink_shelf_sync"] = nil
package.loaded["grimmlink_api_client"] = nil
package.loaded["grimmlink_file_logger"] = nil
package.loaded["grimmlink_lifecycle_controller"] = nil
package.loaded["grimmlink_shelf_controller"] = nil
package.loaded["grimmlink_progress_controller"] = nil
package.loaded["grimmlink_session_controller"] = nil
package.loaded["grimmlink_maintenance_controller"] = nil
package.loaded["grimmlink_pending_sync_controller"] = nil
package.loaded["grimmlink_runtime_controller"] = nil
package.loaded["grimmlink_tracking_controller"] = nil
package.loaded["datastorage"] = nil
package.loaded["json"] = nil
package.loaded["logger"] = nil
local Grimmlink = require("main")
local UIManager = require("ui/uimanager")
local json = require("json")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")
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
        applied_remote_metadata_items = {},
        historical_import_sessions = {},
        book_cache_calls = {},
    }

    function db:getPluginSetting(key)
        return self.settings[key]
    end

    function db:savePluginSetting(key, value)
        self.settings[key] = value
        return true
    end

    function db:deletePluginSetting(key)
        self.settings[key] = nil
        return true
    end

    function db:isRemoteMetadataItemApplied(file_hash, item_type, dedupe_key)
        local key = table.concat({ file_hash or "", item_type or "", dedupe_key or "" }, "|")
        return self.applied_remote_metadata_items[key] ~= nil
    end

    function db:markRemoteMetadataItemApplied(item)
        local key = table.concat({
            item.file_hash or "",
            item.item_type or "",
            item.dedupe_key or "",
        }, "|")
        self.applied_remote_metadata_items[key] = item
        return true
    end

    function db:clearRemoteMetadataAppliedForFileHash(file_hash)
        for key, item in pairs(self.applied_remote_metadata_items) do
            if item.file_hash == file_hash then
                self.applied_remote_metadata_items[key] = nil
            end
        end
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

    function db:markHistoricalSessionImported(book_hash, start_time, end_time, device_id)
        local key = table.concat({
            tostring(book_hash or ""),
            tostring(start_time or ""),
            tostring(end_time or ""),
            tostring(device_id or ""),
        }, "|")
        self.historical_import_sessions[key] = true
        return true
    end

    function db:isHistoricalSessionImported(book_hash, start_time, end_time, device_id)
        local key = table.concat({
            tostring(book_hash or ""),
            tostring(start_time or ""),
            tostring(end_time or ""),
            tostring(device_id or ""),
        }, "|")
        return self.historical_import_sessions[key] == true
    end

    function db:getHistoricalImportCount()
        local count = 0
        for _ in pairs(self.historical_import_sessions) do
            count = count + 1
        end
        return count
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
        next_metadata_pull = { success = true, response = { ok = true, items = {} }, code = 200 },
        next_async_metadata_polls = {
            { status = "done", response = { ok = true, items = {} }, code = 200 },
        },
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

    function api:buildMetadataBatchPayload(book_id, book_hash, book_file_id, file_format, device, device_id, rating, annotations, bookmarks, pull_since, pull_limit)
        return {
            schemaVersion = 1,
            syncMode = "incremental",
            bookId = book_id,
            bookHash = book_hash,
            bookFileId = book_file_id,
            fileFormat = file_format,
            device = device,
            deviceId = device_id,
            since = pull_since,
            cursor = pull_since,
            limit = pull_limit,
            rating = rating,
            annotations = annotations or {},
            bookmarks = bookmarks or {},
        }
    end

    function api:submitMetadataBatch(payload)
        self.calls[#self.calls + 1] = { name = "submitMetadataBatch", payload = payload }
        return self.next_metadata_batch.success, self.next_metadata_batch.response, self.next_metadata_batch.code
    end

    function api:pullMetadata(book_id, book_hash, book_file_id, cursor, limit, item_type)
        self.calls[#self.calls + 1] = {
            name = "pullMetadata",
            book_id = book_id,
            book_hash = book_hash,
            book_file_id = book_file_id,
            cursor = cursor,
            limit = limit,
            item_type = item_type,
        }
        return self.next_metadata_pull.success, self.next_metadata_pull.response, self.next_metadata_pull.code
    end

    function api:startAsyncMetadataPull(book_id, book_hash, book_file_id, cursor, limit, item_type, opts)
        self.calls[#self.calls + 1] = {
            name = "startAsyncMetadataPull",
            book_id = book_id,
            book_hash = book_hash,
            book_file_id = book_file_id,
            cursor = cursor,
            limit = limit,
            item_type = item_type,
            opts = opts,
        }
        return { id = "async-metadata-pull" }
    end

    function api:pollAsyncMetadataPull(handle)
        self.calls[#self.calls + 1] = { name = "pollAsyncMetadataPull", handle = handle }
        local next_poll = table.remove(self.next_async_metadata_polls, 1)
        if not next_poll then
            return "failed", "Missing async metadata poll result", nil, { transport_error = true }
        end
        return next_poll.status, next_poll.response, next_poll.code, next_poll.details
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
        e_reader_friendly_mode = false,
        threshold_percent = 1.0,
        threshold_minutes = 5,
        threshold_pages = 5,
        session_min_seconds = 30,
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

local function newDocSettings(initial)
    local store = initial or {}
    return {
        readSetting = function(self, key)
            return self._store[key]
        end,
        saveSetting = function(self, key, value)
            self._store[key] = value
            return true
        end,
        flush = function(self)
            self.flushed = true
        end,
        _store = store,
    }
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

    it("does not double-scale reflowable page-derived percentage", function()
        local plugin = newPlugin()
        plugin.send_reflowable_percentage = true
        plugin.ui.paging.getCurrentPage = function()
            return 55
        end
        plugin.ui.document.getCurrentPage = function()
            return 55
        end
        plugin.ui.document.getPageCount = function()
            return 16653
        end
        plugin.ui.document.getCurrentPos = function()
            return 55
        end
        plugin.ui.document.getXPointer = function()
            return "/body/55"
        end

        local snapshot = plugin:getCurrentProgressSnapshot("hash-epub", "/books/demo.epub", 11, 12)

        assert.are.equal(0.33, snapshot.percentage)
        assert.is_true(snapshot.percentage ~= 33.0)
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

    it("replaces an existing remote progress prompt instead of stacking dialogs", function()
        local plugin = newPlugin()
        local local_snapshot = {
            percentage = 10,
            currentPage = 10,
            totalPages = 100,
            timestamp = 100,
        }
        local first = plugin:showProgressConflictDialog("hash-dialog", local_snapshot, {
            percentage = 20,
            currentPage = 20,
            totalPages = 100,
            timestamp = 200,
        }, "native")
        local second = plugin:showProgressConflictDialog("hash-dialog", local_snapshot, {
            percentage = 30,
            currentPage = 30,
            totalPages = 100,
            timestamp = 300,
        }, "pdf")

        assert.are.equal(first, UIManager.getLastClosed())
        assert.are.equal(second, plugin._progress_conflict_dialog)
        assert.are.equal(second, UIManager.getLastShown())

        second.buttons[1][3].callback()
        assert.is_nil(plugin._progress_conflict_dialog)
        assert.are.equal(second, UIManager.getLastClosed())
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

    it("uses native progress when opening a PDF", function()
        local plugin = newPlugin()
        plugin.ui.document.file = "/books/demo.pdf"
        plugin.resolveBookByFilePath = function()
            return {
                file_hash = "hash-pdf-native",
                book_id = 52,
                book_file_id = 53,
                title = "Native PDF",
            }
        end
        plugin.resolveBookByHash = function()
            return {
                book_id = 52,
                bookFileId = 53,
                title = "Native PDF",
            }
        end
        plugin.getCurrentProgressSnapshot = function()
            return {
                percentage = 10,
                currentPage = 10,
                totalPages = 100,
                timestamp = 100,
            }
        end
        plugin.isTrackingEnabled = function()
            return true
        end
        local native_pulls = 0
        plugin.maybePullRemoteProgress = function()
            native_pulls = native_pulls + 1
        end
        plugin.schedulePendingSync = function() end

        plugin:startSession()

        assert.are.equal(1, native_pulls)
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

    it("schedules short follow-up pending sync rounds while backlog remains", function()
        local plugin = newPlugin()
        local seen_followup_rounds = {}
        local seen_respect_cooldown = {}
        local sync_calls = 0
        plugin.syncPendingNow = function(_, _, opts)
            sync_calls = sync_calls + 1
            seen_followup_rounds[sync_calls] = opts and opts._followup_rounds_left
            if seen_followup_rounds[sync_calls] == nil then
                seen_followup_rounds[sync_calls] = "initial"
            end
            if opts ~= nil then
                seen_respect_cooldown[sync_calls] = opts.respect_cooldown
            else
                seen_respect_cooldown[sync_calls] = nil
            end
            if sync_calls == 1 then
                return {
                    processed_total = 5,
                    queue_remaining = {
                        pending_progress = 2,
                        pending_sessions = 0,
                        pending_metadata = 0,
                    },
                }
            elseif sync_calls == 2 then
                return {
                    processed_total = 4,
                    queue_remaining = {
                        pending_progress = 0,
                        pending_sessions = 1,
                        pending_metadata = 0,
                    },
                }
            end
            return {
                processed_total = 1,
                queue_remaining = {
                    pending_progress = 0,
                    pending_sessions = 0,
                    pending_metadata = 0,
                },
            }
        end

        plugin:schedulePendingSync("batched pending sync", 0, {
            followup_rounds = 2,
            followup_delay_seconds = 0,
            respect_cooldown = true,
            cooldown_seconds = 300,
        })

        assert.are.equal(3, sync_calls)
        assert.are.same({ "initial", 1, 0 }, seen_followup_rounds)
        assert.are.same({ true, false, false }, seen_respect_cooldown)
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

    it("discards legacy PDF bridge queue entries without sending them", function()
        local plugin = newPlugin()
        plugin.db.pending_progress = {
            {
                id = 1,
                file_hash = "hash-6",
                kind = "pdf_bridge",
                payload_json = '{"bookHash":"hash-6","bookId":31}',
                retry_count = 0,
            },
        }
        local update_calls = 0
        plugin.api.updateProgress = function()
            update_calls = update_calls + 1
            return true, {}, 200
        end
        local synced, failed = plugin:syncPendingProgress(true)
        assert.are.equal(0, synced)
        assert.are.equal(0, failed)
        assert.are.equal(0, update_calls)
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
        local cursor_key = plugin:metadataCursorKey("hash-meta-sync", 70, 71)
        plugin.db.settings[cursor_key] = "2026-06-05T00:00:00Z"
        plugin.api.next_metadata_batch = {
            success = true,
            response = {
                ok = true,
                push = {
                    ok = true,
                    results = {
                        rating = { dedupeKey = "r-1", itemType = "rating", status = "synced", serverId = "11" },
                        annotations = { { dedupeKey = "a-1", itemType = "annotation", status = "duplicate", serverId = "12" } },
                        bookmarks = { { dedupeKey = "b-1", itemType = "bookmark", status = "updated", serverId = "13" } },
                    },
                },
                pull = {
                    ok = true,
                    nextCursor = "2026-06-05T00:01:00Z",
                    items = {
                        { id = "remote-1", type = "annotation", bookId = 70, dedupeKey = "remote-a-1" },
                    },
                },
            },
            code = 200,
        }

        local synced, failed = plugin:syncPendingMetadata(true)
        assert.are.equal(3, synced)
        assert.are.equal(0, failed)
        assert.are.equal(0, #plugin.db.pending_metadata_items)
        assert.are.equal(4, #plugin.db.synced_metadata_items)
        assert.are.equal("2026-06-05T00:00:00Z", plugin.api.calls[1].payload.since)
        assert.are.equal("2026-06-05T00:00:00Z", plugin.api.calls[1].payload.cursor)
        assert.are.equal(100, plugin.api.calls[1].payload.limit)
        assert.are.equal("2026-06-05T00:01:00Z", plugin.db.settings[cursor_key])
    end)

    it("stores and returns valid ISO metadata cursors", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        local cursor = "2026-06-05T00:00:00Z"
        local cursor_key = plugin:metadataCursorKey("hash-valid-cursor", 70, 71)

        assert.is_true(plugin:saveMetadataCursor("hash-valid-cursor", 70, 71, cursor))
        assert.are.equal(cursor, plugin.db.settings[cursor_key])
        assert.are.equal(cursor, plugin:getMetadataCursor("hash-valid-cursor", 70, 71))
    end)

    it("scopes metadata cursors by server, user, book, and type", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        local all_key = plugin:metadataCursorKey("hash-scope", 70, 71)
        local rating_key = plugin:metadataCursorKey("hash-scope", 70, 71, "rating")
        local other_book_key = plugin:metadataCursorKey("hash-other", 70, 71)

        plugin.username = "other-reader"
        local other_user_key = plugin:metadataCursorKey("hash-scope", 70, 71)
        plugin.username = "reader"
        plugin.server_url = "http://other.example.com"
        local other_server_key = plugin:metadataCursorKey("hash-scope", 70, 71)

        assert.are_not.equal(all_key, rating_key)
        assert.are_not.equal(all_key, other_book_key)
        assert.are_not.equal(all_key, other_user_key)
        assert.are_not.equal(all_key, other_server_key)
    end)

    it("refuses nil metadata cursors", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        local cursor_key = plugin:metadataCursorKey("hash-nil-cursor", 70, 71)

        assert.is_false(plugin:saveMetadataCursor("hash-nil-cursor", 70, 71, nil))
        assert.is_nil(plugin.db.settings[cursor_key])
        assert.is_nil(plugin:getMetadataCursor("hash-nil-cursor", 70, 71))
    end)

    it("refuses JSON-null function sentinels as metadata cursors", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        local null_sentinel = function() end
        local cursor_key = plugin:metadataCursorKey("hash-function-cursor", 70, 71)

        assert.is_false(plugin:saveMetadataCursor("hash-function-cursor", 70, 71, null_sentinel))
        assert.is_nil(plugin.db.settings[cursor_key])
    end)

    it("ignores and deletes stored legacy function metadata cursors", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        local cursor_key = plugin:metadataCursorKey("hash-legacy-function", 70, 71)
        plugin.db.settings[cursor_key] = "function: 0x79a56e3318"

        assert.is_nil(plugin:getMetadataCursor("hash-legacy-function", 70, 71))
        assert.is_nil(plugin.db.settings[cursor_key])
    end)

    it("refuses invalid arbitrary metadata cursor strings", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        local cursor_key = plugin:metadataCursorKey("hash-invalid-cursor", 70, 71)
        plugin.db.settings[cursor_key] = "not-a-timestamp"

        assert.is_false(plugin:saveMetadataCursor("hash-invalid-cursor", 70, 71, "not-a-timestamp"))
        assert.is_nil(plugin:getMetadataCursor("hash-invalid-cursor", 70, 71))
        assert.is_nil(plugin.db.settings[cursor_key])
    end)

    it("omits null metadata cursors from pull requests and does not store them", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.api.next_metadata_pull = {
            success = true,
            response = {
                ok = true,
                nextCursor = nil,
                items = {},
            },
            code = 200,
        }

        local result = plugin:pullRemoteMetadataForContext({
            file_hash = "hash-null-cursor",
            book_id = 70,
            book_file_id = 71,
            file_format = "EPUB",
        }, true)

        assert.are.equal(0, result.failed)
        assert.is_nil(plugin.api.calls[1].cursor)
        assert.is_nil(plugin.db.settings[plugin:metadataCursorKey("hash-null-cursor", 70, 71)])
    end)

    it("resolves the open document before a stale session and uses currentHash before initialHash", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.ui.document.file = "/books/open.epub"
        plugin.ui.document.currentHash = "current-open-hash"
        plugin.ui.document.initialHash = "initial-open-hash"
        plugin.current_session = {
            file_path = "/books/stale.epub",
            file_hash = "stale-hash",
            book_id = 1,
            book_file_id = 2,
        }
        plugin.db.book_cache_by_path["/books/open.epub"] = {
            file_path = "/books/open.epub",
            file_hash = "cached-open-hash",
            book_id = 70,
            book_file_id = 71,
        }

        local context = plugin:resolveMetadataPullContext()
        assert.are.equal("/books/open.epub", context.file_path)
        assert.are.equal("current-open-hash", context.file_hash)
        assert.are.equal("initial-open-hash", context.initial_hash)
        assert.are.equal(70, context.book_id)
        assert.are.equal(71, context.book_file_id)
    end)

    it("falls back to initialHash, cached IDs, and file-browser context", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.ui = {
            selected_file = "/books/browser.epub",
            doc_settings = newDocSettings(),
        }
        plugin.current_session = nil
        plugin.calculateBookHash = function()
            return nil
        end
        plugin.db.book_cache_by_path["/books/browser.epub"] = {
            file_path = "/books/browser.epub",
            initialHash = "initial-browser-hash",
            book_id = 80,
            book_file_id = 81,
        }
        plugin.resolveBookByFilePath = function()
            return {
                initialHash = "initial-browser-hash",
                book_id = 80,
                book_file_id = 81,
            }
        end

        local context = plugin:resolveMetadataPullContext()
        assert.are.equal("/books/browser.epub", context.file_path)
        assert.are.equal("initial-browser-hash", context.file_hash)
        assert.are.equal(80, context.book_id)
        assert.are.equal(81, context.book_file_id)
    end)

    it("does not call the backend when no book context exists", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.ui = {}
        plugin.current_session = nil

        local result = plugin:pullRemoteMetadataNow(false, 100)
        assert.are.equal("no_book_context", result.reason)
        assert.are.equal(0, #plugin.api.calls)
        local dialog = UIManager.getLastShown()
        assert.is_true(dialog.text:find("Please open a book first", 1, true) ~= nil)
    end)

    it("runs manual metadata pull in the background with staged progress", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.ui.document.currentHash = "hash-async-progress"
        plugin.api.next_async_metadata_polls = {
            {
                status = "running",
                details = { response_bytes = 128 },
            },
            {
                status = "done",
                response = { ok = true, items = {} },
                code = 200,
            },
        }

        local result = plugin:pullRemoteMetadataNow(false, 100)

        assert.is_true(result.pending, result.reason)
        assert.is_false(plugin._metadata_pull_running == true)
        local shown_texts = UIManager.getShownTexts()
        local joined = table.concat(shown_texts, "\n")
        assert.is_true(joined:find("Step 1 of 3", 1, true) ~= nil)
        assert.is_true(joined:find("Step 2 of 3", 1, true) ~= nil)
        assert.is_true(joined:find("Step 3 of 3", 1, true) ~= nil)
        assert.is_true(joined:find("KOReader will remain responsive", 1, true) ~= nil)
        assert.is_true(joined:find("No remote metadata for this book", 1, true) ~= nil)
    end)

    it("prevents a second manual metadata pull while one is running", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.ui.document.currentHash = "hash-async-duplicate"
        local scheduled = {}
        local original_schedule = UIManager.scheduleIn
        UIManager.scheduleIn = function(_, _, callback)
            scheduled[#scheduled + 1] = callback
        end

        local first = plugin:pullRemoteMetadataNow(false, 100)
        local second = plugin:pullRemoteMetadataNow(false, 100)

        UIManager.scheduleIn = original_schedule
        plugin._metadata_pull_running = false
        plugin._metadata_pull_handle = nil
        plugin:closeMetadataPullProgress()

        assert.is_true(first.pending, first.reason)
        assert.are.equal("already_running", second.reason)
        assert.are.equal(1, #scheduled)
        local starts = 0
        for _, call in ipairs(plugin.api.calls) do
            if call.name == "startAsyncMetadataPull" then
                starts = starts + 1
            end
        end
        assert.are.equal(1, starts)
    end)

    it("contains background metadata poll exceptions without crashing the UI", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.ui.document.currentHash = "hash-async-exception"
        plugin.api.pollAsyncMetadataPull = function()
            error("simulated poll failure")
        end

        local result = plugin:pullRemoteMetadataNow(false, 100)

        assert.is_true(result.pending, result.reason)
        assert.is_false(plugin._metadata_pull_running == true)
        local dialog = UIManager.getLastShown()
        assert.is_true(dialog.text:find("Server unreachable", 1, true) ~= nil)
    end)

    it("uses a silent background pull when pending metadata is empty", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.ui.document.currentHash = "hash-auto-background"

        local synced, failed = plugin:syncPendingMetadata(true)

        assert.are.equal(0, synced)
        assert.are.equal(0, failed)
        local async_starts = 0
        local blocking_pulls = 0
        for _, call in ipairs(plugin.api.calls) do
            if call.name == "startAsyncMetadataPull" then
                async_starts = async_starts + 1
            elseif call.name == "pullMetadata" then
                blocking_pulls = blocking_pulls + 1
            end
        end
        assert.are.equal(1, async_starts)
        assert.are.equal(0, blocking_pulls)
        assert.are.equal(0, #UIManager.getShownTexts())
    end)

    it("contains synchronous metadata request exceptions", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.api.pullMetadata = function()
            error("simulated socket failure")
        end

        local result = plugin:pullRemoteMetadataForContext({
            file_path = "/books/demo.epub",
            file_hash = "hash-sync-exception",
            book_id = 70,
        }, true, 100)

        assert.are.equal(1, result.failed)
        assert.are.equal("request_failed", result.reason)
    end)

    it("pulls and deduplicates rating, annotation, and bookmark metadata", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        local doc_settings = newDocSettings({
            summary = {},
            annotations = {},
        })
        plugin.ui.document.file = "/books/demo.epub"
        plugin.ui.doc_settings = doc_settings
        local items = {
            {
                id = "rating-1",
                type = "rating",
                dedupeKey = "rating-dedupe",
                deviceId = "other-device",
                payload = { value = 8, scale = 10 },
            },
            {
                id = "annotation-1",
                type = "annotation",
                dedupeKey = "annotation-dedupe",
                deviceId = "other-device",
                payload = { text = "Remote highlight", pos0 = "xp-1", pos1 = "xp-2" },
            },
            {
                id = "bookmark-1",
                type = "bookmark",
                dedupeKey = "bookmark-dedupe",
                deviceId = "other-device",
                payload = { title = "Remote bookmark", page = 12 },
            },
            {
                id = "read-status-1",
                type = "read_status",
                dedupeKey = "status-dedupe",
                payload = { status = "READ" },
            },
        }
        plugin.api.next_metadata_pull = {
            success = true,
            response = {
                ok = true,
                nextCursor = "2026-06-05T00:01:00Z",
                items = items,
            },
            code = 200,
        }
        local context = {
            file_path = "/books/demo.epub",
            file_hash = "hash-pull-e2e",
            book_id = 70,
            book_file_id = 71,
        }

        local first = plugin:pullRemoteMetadataForContext(context, false, 100)
        assert.are.equal(3, first.applied)
        assert.are.equal(1, first.skipped)
        assert.are.equal(0, first.failed)
        assert.is_true(first.cursor_saved)
        assert.are.equal(4, doc_settings._store.summary.rating)
        assert.are.equal(2, #doc_settings._store.annotations)
        assert.are.equal(
            "2026-06-05T00:01:00Z",
            plugin.db.settings[plugin:metadataCursorKey("hash-pull-e2e", 70, 71)]
        )

        plugin.api.next_metadata_pull.response.nextCursor = "2026-06-05T00:02:00Z"
        local second = plugin:pullRemoteMetadataForContext(context, true, 100)
        assert.are.equal(0, second.applied)
        assert.are.equal(4, second.skipped)
        assert.are.equal(0, second.failed)
        assert.are.equal(2, #doc_settings._store.annotations)
    end)

    it("applies good metadata items without advancing the cursor past a failed item", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.ui.doc_settings = newDocSettings({ annotations = {} })
        plugin.api.next_metadata_pull = {
            success = true,
            response = {
                ok = true,
                nextCursor = "2026-06-05T00:03:00Z",
                items = {
                    {
                        id = "bad-rating",
                        type = "rating",
                        dedupeKey = "bad-rating",
                        payload = { value = 99, scale = 10 },
                    },
                    {
                        id = "good-bookmark",
                        type = "bookmark",
                        dedupeKey = "good-bookmark",
                        payload = { title = "Good bookmark", page = 2 },
                    },
                },
            },
            code = 200,
        }
        local context = {
            file_path = "/books/demo.epub",
            file_hash = "hash-partial-failure",
            book_id = 70,
            book_file_id = 71,
        }

        local result = plugin:pullRemoteMetadataForContext(context, true, 100)
        assert.are.equal(1, result.applied)
        assert.are.equal(1, result.failed)
        assert.is_false(result.cursor_saved)
        assert.is_nil(plugin.db.settings[plugin:metadataCursorKey("hash-partial-failure", 70, 71)])
        assert.are.equal(1, #plugin.ui.doc_settings._store.annotations)
    end)

    it("counts disabled metadata types as safely skipped", function()
        local plugin = newPlugin({
            metadata_sync_enabled = true,
            annotations_sync_enabled = false,
        })
        plugin.ui.doc_settings = newDocSettings({ annotations = {} })
        plugin.api.next_metadata_pull = {
            success = true,
            response = {
                ok = true,
                nextCursor = "2026-06-05T00:04:00Z",
                items = {
                    {
                        id = "annotation-disabled",
                        type = "annotation",
                        dedupeKey = "annotation-disabled",
                        payload = { text = "Skipped", pos0 = "xp-1", pos1 = "xp-2" },
                    },
                },
            },
            code = 200,
        }

        local result = plugin:pullRemoteMetadataForContext({
            file_path = "/books/demo.epub",
            file_hash = "hash-disabled",
            book_id = 70,
        }, true, 100, "annotation")
        assert.are.equal(0, result.applied)
        assert.are.equal(1, result.skipped)
        assert.are.equal(0, result.failed)
        assert.are.equal(1, result.skipped_reasons.annotation_disabled)
        assert.is_true(result.cursor_saved)
    end)

    local metadata_pull_error_cases = {
        {
            name = "authentication failures",
            response = { success = false, response = "Unauthorized", code = 401 },
            expected = "Authentication failed",
        },
        {
            name = "wrong server URLs",
            response = { success = false, response = "Not Found", code = 404 },
            expected = "Server URL or metadata endpoint not found",
        },
        {
            name = "unreachable servers",
            response = { success = false, response = "connection refused", code = nil },
            expected = "Server unreachable",
        },
        {
            name = "forbidden books",
            response = { success = false, response = "Forbidden", code = 403 },
            expected = "Book not found or forbidden",
        },
        {
            name = "malformed responses",
            response = { success = false, response = "Malformed response", code = 200 },
            expected = "Malformed response from Grimmory",
        },
    }
    for _, case in ipairs(metadata_pull_error_cases) do
        it("shows a clear message for " .. case.name, function()
            local plugin = newPlugin({ metadata_sync_enabled = true })
            plugin.api.next_metadata_pull = case.response

            local result = plugin:pullRemoteMetadataForContext({
                file_path = "/books/demo.epub",
                file_hash = "hash-error",
                book_id = 70,
            }, false, 100)

            assert.are.equal(1, result.failed)
            local dialog = UIManager.getLastShown()
            assert.is_true(dialog.text:find(case.expected, 1, true) ~= nil)
        end)
    end

    it("reports an empty metadata pull clearly", function()
        local plugin = newPlugin({ metadata_sync_enabled = true })
        plugin.api.next_metadata_pull = {
            success = true,
            response = { ok = true, items = {} },
            code = 200,
        }

        local result = plugin:pullRemoteMetadataForContext({
            file_path = "/books/demo.epub",
            file_hash = "hash-empty",
            book_id = 70,
        }, false, 100)
        assert.are.equal(0, result.pulled)
        local dialog = UIManager.getLastShown()
        assert.is_true(dialog.text:find("No remote metadata for this book", 1, true) ~= nil)
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
        local cursor_key = plugin:metadataCursorKey("hash-meta-retry", 70, 71)
        plugin.db.settings[cursor_key] = "2026-06-05T00:00:00Z"
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
        assert.are.equal("2026-06-05T00:00:00Z", plugin.db.settings[cursor_key])
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

    it("executes whitelisted device debug commands and returns structured results", function()
        local plugin = newPlugin()
        plugin.active_url_source = "local"
        plugin.getQueueSummaryCounters = function()
            return {
                pending_progress = 1,
                pending_sessions = 2,
                pending_metadata = 3,
                pending_shelf_removals = 4,
            }
        end

        local ping_result = plugin:executeDeviceDebugCommand({
            command = "ping",
            request_id = "req-1",
        })
        assert.is_true(ping_result.success)
        assert.are.equal("req-1", ping_result.request_id)
        assert.are.equal("local", ping_result.active_url_source)
        assert.are.equal(1, ping_result.queue.pending_progress)

        local context_result = plugin:executeDeviceDebugCommand({
            command = "current_context",
        })
        assert.is_true(context_result.success)
        assert.are.equal("/books/demo.epub", context_result.context.file_path)

        local unknown_result = plugin:executeDeviceDebugCommand({
            command = "not_real",
        })
        assert.is_false(unknown_result.success)
        assert.are.equal("unknown command", unknown_result.error)
    end)

    it("processes a device debug command file and writes a result file", function()
        local plugin = newPlugin()
        local written_path = nil
        local written_payload = nil
        local deleted_path = nil
        plugin.readJsonFile = function(_, path)
            assert.are.equal("/tmp/grimmlink-device-command.json", path)
            return {
                command = "queue_summary",
                request_id = "dev-1",
            }
        end
        plugin.writeJsonFile = function(_, path, payload)
            written_path = path
            written_payload = payload
            return true
        end
        plugin.deleteFile = function(_, path)
            deleted_path = path
            return true
        end

        local result, err = plugin:processDeviceDebugCommandFile("init")
        assert.is_nil(err)
        assert.is_true(result.success)
        assert.are.equal("/tmp/grimmlink-device-result.json", written_path)
        assert.are.equal("queue_summary", written_payload.command)
        assert.are.equal("init", written_payload.trigger)
        assert.are.equal("/tmp/grimmlink-device-command.json", deleted_path)
    end)

    it("builds a settings backup payload from current plugin settings", function()
        local plugin = newPlugin({
            remote_url = "https://example.com",
            local_url_nickname = "Home API",
            metadata_sync_enabled = true,
            first_run_setup_completed = true,
        })

        local payload = plugin:buildSettingsBackupPayload()

        assert.are.equal(1, payload.schemaVersion)
        assert.are.equal("GrimmLink", payload.plugin)
        assert.are.equal("http://example.com", payload.settings.server_url)
        assert.are.equal("https://example.com", payload.settings.remote_url)
        assert.are.equal("Home API", payload.settings.local_url_nickname)
        assert.are.equal(true, payload.settings.metadata_sync_enabled)
        assert.are.equal(true, payload.settings.first_run_setup_completed)
    end)

    it("uses the KOReader settings backup folder as the default export and restore path", function()
        local plugin = newPlugin()

        assert.are.equal(
            "/tmp/Grimmlink-setting-backup",
            plugin:getSettingsBackupDirectory()
        )
        assert.are.equal(
            "/tmp/Grimmlink-setting-backup/grimmlink-settings-backup.json",
            plugin:getSettingsBackupPath()
        )
    end)

    it("uses a dedicated KOReader diagnostics folder and redacts sensitive values in the bundle", function()
        local plugin = newPlugin({
            remote_url = "https://grimmory.example.com",
            home_ssid = "HomeWifi",
            current_session = {
                file_path = "/books/demo.epub",
                file_hash = "hash-1234567890",
                book_id = 44,
                book_file_id = 55,
            },
        })
        plugin.file_logger = {
            getLogPath = function()
                return "/tmp/grimmlink.log"
            end,
        }
        NetworkMgr.getCurrentNetwork = function()
            return { ssid = "CafeWifi" }
        end
        plugin.db.pending_progress = {
            { id = 1, file_hash = "hash-1234567890", kind = "native" },
        }
        plugin.db.pending_sessions = {
            { id = 1, bookHash = "hash-1234567890" },
        }
        plugin.db.pending_metadata_items = {
            { id = 1, file_hash = "hash-1234567890", item_type = "rating", dedupe_key = "r1" },
        }

        assert.are.equal("/tmp/Grimmlink-diagnostics", plugin:getLocalDiagnosticsBundleDirectory())
        assert.are.equal(
            "/tmp/Grimmlink-diagnostics/grimmlink-diagnostics-bundle.json",
            plugin:getLocalDiagnosticsBundlePath()
        )

        local bundle = plugin:buildLocalDiagnosticsBundle()

        assert.are.equal(1, bundle.schemaVersion)
        assert.are.equal("GrimmLink", bundle.plugin)
        assert.are.equal("(redacted)", bundle.settings.password)
        assert.are.equal("re...", bundle.settings.username)
        assert.is_true(type(bundle.connection.home_ssid) == "string" and bundle.connection.home_ssid ~= "HomeWifi")
        assert.is_true(type(bundle.connection.current_ssid) == "string" and bundle.connection.current_ssid ~= "CafeWifi")
        assert.are.equal(1, bundle.database.pending_progress)
        assert.are.equal(1, bundle.database.pending_sessions)
        assert.are.equal(1, bundle.database.pending_metadata)
        assert.are.equal("/tmp/grimmlink.log", bundle.files.log_path)
    end)

    it("applies a settings backup payload and marks setup complete", function()
        local plugin = newPlugin({
            server_url = "",
            username = "",
            password = "",
            first_run_setup_completed = false,
        })

        local ok, restored = plugin:applySettingsBackupPayload({
            settings = {
                server_url = "http://192.168.1.55:6060",
                username = "new-reader",
                password = "new-secret",
                device_name = "Kindle PW5",
                e_reader_friendly_mode = true,
            },
        })

        assert.is_true(ok)
        assert.are.equal(5, restored)
        assert.are.equal("http://192.168.1.55:6060", plugin.server_url)
        assert.are.equal("new-reader", plugin.username)
        assert.are.equal("new-secret", plugin.password)
        assert.are.equal("Kindle PW5", plugin.device_name)
        assert.are.equal(true, plugin.db.settings.first_run_setup_completed)
        assert.are.equal(false, plugin.db.settings.first_run_setup_dismissed)
    end)

    it("shows the first-run setup prompt when connection is not configured", function()
        local plugin = newPlugin({
            server_url = "",
            username = "",
            password = "",
            first_run_setup_completed = false,
            first_run_setup_dismissed = false,
        })

        local shown = plugin:maybePromptFirstRunSetup()

        assert.is_true(shown)
        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.is_true(dialog.text:find("first%-time setup wizard", 1) ~= nil)
    end)

    it("runs the first-run setup wizard and saves core settings", function()
        local plugin = newPlugin({
            server_url = "",
            username = "",
            password = "",
            first_run_setup_completed = false,
        })
        local prompts = {
            ["Local URL (home network)"] = "http://192.168.1.20:6060",
            ["KOReader Username"] = "reader-one",
            ["Password"] = "secret-one",
            ["Device Name"] = "Bedroom Kindle",
        }
        local tested_connection = false
        plugin.showTextInput = function(_, title, current_value, _, _, on_save)
            assert.is_not_nil(prompts[title], "unexpected prompt: " .. tostring(title))
            on_save(prompts[title])
        end
        plugin.showChoiceAction = function(_, _, ok_text, cancel_text, on_confirm, _)
            assert.are.equal("Enable", ok_text)
            assert.are.equal("Skip", cancel_text)
            on_confirm()
        end
        plugin.promptTestConnectionAfterSetup = function()
            tested_connection = true
        end

        plugin:runFirstRunSetupWizard()

        assert.are.equal("http://192.168.1.20:6060", plugin.server_url)
        assert.are.equal("reader-one", plugin.username)
        assert.are.equal("secret-one", plugin.password)
        assert.are.equal("Bedroom Kindle", plugin.device_name)
        assert.is_true(plugin.e_reader_friendly_mode)
        assert.is_true(plugin.first_run_setup_completed)
        assert.is_true(tested_connection)
    end)

    it("groups KOReader page_stat rows into historical reading sessions using the idle gap threshold", function()
        local plugin = newPlugin()

        local groups = plugin:groupHistoricalPageStats({
            { file_hash = "hash-1", title = "Book A", page = 10, start_time = 1000, duration = 120, total_pages = 100 },
            { file_hash = "hash-1", title = "Book A", page = 12, start_time = 1120, duration = 180, total_pages = 100 },
            { file_hash = "hash-1", title = "Book A", page = 20, start_time = 1800, duration = 60, total_pages = 100 },
            { file_hash = "hash-2", title = "Book B", page = 5, start_time = 2000, duration = 90, total_pages = 50 },
        }, 300)

        assert.are.equal(3, #groups)
        assert.are.equal("hash-1", groups[1].file_hash)
        assert.are.equal(10, groups[1].start_page)
        assert.are.equal(12, groups[1].end_page)
        assert.are.equal(300, groups[1].duration_seconds)
        assert.are.equal(20, groups[2].start_page)
        assert.are.equal("hash-2", groups[3].file_hash)
    end)

    it("imports historical sessions into the existing pending queue and skips duplicates on rerun", function()
        local plugin = newPlugin()
        plugin.resolveBookByHash = function(_, _, file_hash)
            if file_hash == "hash-1" then
                return { book_id = 123 }
            end
            return nil
        end
        plugin.loadHistoricalPageStatsFromPath = function()
            return {
                { file_hash = "hash-1", title = "Book A", page = 10, start_time = 1000, duration = 120, total_pages = 100 },
                { file_hash = "hash-1", title = "Book A", page = 12, start_time = 1120, duration = 180, total_pages = 100 },
                { file_hash = "hash-2", title = "Book B", page = 20, start_time = 2000, duration = 240, total_pages = 200 },
            }
        end
        local messages = {}
        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end

        local ok_first = plugin:importHistoricalSessionsFromPath("/tmp/statistics.sqlite3")
        local first_count = #plugin.db.pending_sessions
        local first_markers = plugin.db:getHistoricalImportCount()
        local ok_second = plugin:importHistoricalSessionsFromPath("/tmp/statistics.sqlite3")

        assert.is_true(ok_first)
        assert.is_true(ok_second)
        assert.are.equal(2, first_count)
        assert.are.equal(2, first_markers)
        assert.are.equal(2, #plugin.db.pending_sessions)
        assert.is_true(plugin.db.pending_sessions[1].bookId == 123)
        assert.is_true(plugin.db.pending_sessions[2].bookId == nil)
        assert.is_true(messages[#messages]:find("Skipped duplicates: 2", 1, true) ~= nil)
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

    it("routes dispatcher action callbacks to pending sync, connection test, and shelf sync", function()
        local plugin = newPlugin()
        local pending_silent = nil
        local test_connection_calls = 0
        local shelf_silent = nil
        local settled_calls = 0

        plugin.syncPendingNow = function(_, silent)
            pending_silent = silent
        end
        plugin.testConnection = function()
            test_connection_calls = test_connection_calls + 1
        end
        plugin.syncShelfNow = function(_, silent)
            shelf_silent = silent
        end
        plugin.runAfterUiSettles = function(_, callback)
            settled_calls = settled_calls + 1
            callback()
        end

        plugin:onGrimmLinkSyncPending()
        plugin:onGrimmLinkTestConnection()
        plugin:onGrimmLinkSyncShelf()

        assert.is_false(pending_silent)
        assert.are.equal(1, test_connection_calls)
        assert.are.equal(1, settled_calls)
        assert.is_false(shelf_silent)
    end)

    it("registers dispatcher actions when the dispatcher is available", function()
        Dispatcher.registered_actions = {}
        local plugin = newPlugin()

        plugin:registerDispatcherActions()

        assert.are.equal("GrimmLink Sync Pending", Dispatcher.registered_actions.GrimmLinkSyncPending.title)
        assert.are.equal("GrimmLink Test Connection", Dispatcher.registered_actions.GrimmLinkTestConnection.title)
        assert.are.equal("GrimmLink Sync Shelf", Dispatcher.registered_actions.GrimmLinkSyncShelf.title)
    end)

    it("starts a session after reader UI settles when a document is ready", function()
        local plugin = newPlugin()
        local menu_registered = 0
        local settled_calls = 0
        local start_calls = 0
        local debug_triggers = {}

        plugin.ensureMainMenuRegistered = function()
            menu_registered = menu_registered + 1
            return true
        end
        plugin.runAfterUiSettles = function(_, callback)
            settled_calls = settled_calls + 1
            callback()
        end
        plugin.startSession = function()
            start_calls = start_calls + 1
        end
        plugin.processDeviceDebugCommandFile = function(_, trigger)
            debug_triggers[#debug_triggers + 1] = trigger
        end

        plugin:onReaderReady()

        assert.are.equal(1, menu_registered)
        assert.are.equal(1, settled_calls)
        assert.are.equal(1, start_calls)
        assert.are.same({ "reader_ready" }, debug_triggers)
    end)

    it("ends sessions with close and suspend lifecycle reasons", function()
        local plugin = newPlugin()
        local reasons = {}
        plugin.endSession = function(_, opts)
            reasons[#reasons + 1] = opts and opts.reason or nil
        end

        plugin:onCloseDocument()
        plugin:onSuspend()

        assert.are.same({ "close", "suspend" }, reasons)
    end)

    it("schedules the end-of-book Reading Completion prompt from the current session context", function()
        local plugin = newPlugin()
        local context = {
            file_hash = "hash-end",
            file_path = "/books/end.epub",
            book_id = 11,
            book_file_id = 12,
        }
        local snapshot = { percentage = 100, currentPage = 100, totalPages = 100 }
        local captured = nil
        plugin.current_session = { file_hash = context.file_hash }
        plugin.getReadingCompletionContext = function()
            return context
        end
        plugin.getCurrentProgressSnapshot = function(_, file_hash, file_path, book_id, book_file_id)
            assert.are.equal(context.file_hash, file_hash)
            assert.are.equal(context.file_path, file_path)
            assert.are.equal(context.book_id, book_id)
            assert.are.equal(context.book_file_id, book_file_id)
            return snapshot
        end
        plugin.scheduleReadingCompletionPrompt = function(_, prompt_context, prompt_snapshot, opts)
            captured = {
                context = prompt_context,
                snapshot = prompt_snapshot,
                opts = opts,
            }
        end

        plugin:onEndOfBook()

        assert.are.same(context, captured.context)
        assert.are.same(snapshot, captured.snapshot)
        assert.are.equal("end_of_book", captured.opts.prompt_source)
        assert.is_true(captured.opts.wait_for_koreader_end_dialog)
    end)

    it("runs resume network work and optional shelf sync after configured delays", function()
        local plugin = newPlugin({
            auto_sync_shelf_on_resume = true,
            sync_on_network_connected = false,
        })
        local delays = {}
        local refresh_calls = 0
        local shelf_silent = nil
        local debug_triggers = {}
        plugin.ensureMainMenuRegistered = function() return true end
        plugin.refreshApiClient = function()
            refresh_calls = refresh_calls + 1
            return true
        end
        plugin.syncShelfNow = function(_, silent)
            shelf_silent = silent
        end
        plugin.processDeviceDebugCommandFile = function(_, trigger)
            debug_triggers[#debug_triggers + 1] = trigger
        end

        local original_schedule = UIManager.scheduleIn
        UIManager.scheduleIn = function(_, delay, callback)
            delays[#delays + 1] = delay
            callback()
        end
        plugin:onResume()
        UIManager.scheduleIn = original_schedule

        assert.are.same({ 1.0, 4.0 }, delays)
        assert.are.equal(1, refresh_calls)
        assert.is_true(shelf_silent)
        assert.are.same({ "resume" }, debug_triggers)
    end)

    it("processes device debug commands at the end of init", function()
        local plugin = newPlugin()
        local debug_triggers = {}
        plugin.ensureMainMenuRegistered = function() return true end
        plugin.installSettingsTab = function() end
        plugin.registerFileManagerHoldActions = function() end
        plugin.refreshApiClient = function() return true end
        plugin.syncFirstRunSetupState = function() end
        plugin.maybeCheckForUpdatesOnStartup = function() end
        plugin.maybePromptFirstRunSetup = function() end
        plugin.processDeviceDebugCommandFile = function(_, trigger)
            debug_triggers[#debug_triggers + 1] = trigger
        end

        plugin:init()
        assert.are.same({ "init" }, debug_triggers)
    end)

    it("clears cached tab items on teardown", function()
        local plugin = newPlugin()
        local clear_calls = 0
        plugin.clearTabItemsCache = function()
            clear_calls = clear_calls + 1
        end

        plugin:onTeardown()

        assert.are.equal(1, clear_calls)
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
        local wizard_item = findMenuItem(connection_menu.sub_item_table, "First Run Setup Wizard")
        assert.is_not_nil(wizard_item)
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
        local setup_backup_menu = findMenuItem(advanced_menu.sub_item_table, "Setup & Backup")
        assert.is_not_nil(setup_backup_menu)
        assert.is_not_nil(findMenuItem(setup_backup_menu.sub_item_table, "Run First Setup Wizard"))
        assert.is_not_nil(findMenuItem(setup_backup_menu.sub_item_table, "Export Settings Backup"))
        assert.is_not_nil(findMenuItem(setup_backup_menu.sub_item_table, "Restore Settings Backup"))
        local metadata_menu = findMenuItem(advanced_menu.sub_item_table, "Metadata Sync")
        assert.is_not_nil(metadata_menu)
        local preview_item = findMenuItem(metadata_menu.sub_item_table, "Preview Metadata")
        assert.is_not_nil(preview_item)
        local device_menu = findMenuItem(advanced_menu.sub_item_table, "Device Identity")
        assert.is_not_nil(device_menu)
        assert.is_not_nil(findMenuItemByContains(device_menu.sub_item_table, "Device Name:"))
        assert.is_not_nil(findMenuItemByContains(device_menu.sub_item_table, "Device ID:"))
        local network_menu = findMenuItem(advanced_menu.sub_item_table, "Tracking & Network")
        assert.is_not_nil(network_menu)
        assert.is_not_nil(findMenuItemByContains(network_menu.sub_item_table, "Network Mode:"))
        assert.is_not_nil(findMenuItem(network_menu.sub_item_table, "E-reader Friendly Mode"))

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

    it("applies E-reader Friendly Mode as a conservative network preset", function()
        local plugin = newPlugin({
            offline_queue_enabled = false,
            ask_wifi_before_sync = false,
            sync_on_network_connected = false,
            network_sync_cooldown_seconds = 10,
            auto_sync_shelf_on_resume = true,
            auto_pull_on_open = false,
            auto_push_on_close = false,
        })
        local messages = {}
        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end

        assert.are.equal("Custom", plugin:getNetworkModeLabel())
        plugin:applyEreaderFriendlyMode()

        assert.is_true(plugin.offline_queue_enabled)
        assert.is_true(plugin.ask_wifi_before_sync)
        assert.is_true(plugin.sync_on_network_connected)
        assert.are.equal(300, plugin.network_sync_cooldown_seconds)
        assert.is_false(plugin.auto_sync_shelf_on_resume)
        assert.is_true(plugin.auto_pull_on_open)
        assert.is_true(plugin.auto_push_on_close)
        assert.is_true(plugin:isEreaderFriendlyModeActive())
        assert.are.equal("E-reader Friendly", plugin:getNetworkModeLabel())
        assert.are.equal(true, plugin.db.settings.e_reader_friendly_mode)
        assert.are.equal("E-reader Friendly Mode enabled", messages[1])

        plugin:disableEreaderFriendlyMode()

        assert.is_false(plugin.e_reader_friendly_mode)
        assert.is_false(plugin:isEreaderFriendlyModeActive())
        assert.are.equal("Custom", plugin:getNetworkModeLabel())
        assert.is_true(plugin.sync_on_network_connected)
        assert.are.equal(false, plugin.db.settings.e_reader_friendly_mode)
    end)

    it("asks to move files back and disables separate magic folder after confirmation", function()
        local plugin = newPlugin({
            use_separate_magic_download_dir = true,
        })
        local confirm_calls = 0
        plugin.showConfirmAction = function(_, _message, _ok_text, on_confirm)
            confirm_calls = confirm_calls + 1
            assert.is_true(plugin.use_separate_magic_download_dir)
            on_confirm()
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
        local completion_item = findMenuItem(top, "Reading Completion")
        local pull_item = findMenuItem(top, "Pull Remote Progress")
        local manual_status_item = findMenuItem(top, "Manual Reading Status")
        local toggle_item = findMenuItem(top, "Toggle Tracking (Current Book)")
        assert.is_nil(completion_item)
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
        local completion_item = findMenuItem(top, "Reading Completion")
        local pull_item = findMenuItem(top, "Pull Remote Progress")
        local manual_status_item = findMenuItem(top, "Manual Reading Status")
        assert.is_not_nil(completion_item)
        assert.is_not_nil(pull_item)
        assert.is_not_nil(manual_status_item)
    end)

    it("saves an exact 1-10 rating into doc settings and queues metadata for the current book", function()
        local plugin = newPlugin()
        plugin.ui.doc_settings = newDocSettings({
            summary = { rating = 2 },
        })
        local messages = {}
        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end
        plugin.extractAndQueueCurrentMetadata = function(_, reason, context)
            assert.are.equal("reading-completion-rating", reason)
            assert.are.equal("/books/demo.epub", context.file_path)
            return {
                queued = { queued = 1, failed = 0 },
            }
        end

        local ok = plugin:setCurrentBookRating(7)

        assert.is_true(ok)
        assert.are.equal(4, plugin.ui.doc_settings._store.summary.rating)
        assert.are.same({
            value = 7,
            scale = 10,
            summary_rating = 4,
        }, plugin.ui.doc_settings._store.grimmlink_rating_state)
        assert.is_true(plugin.ui.doc_settings.flushed == true)
        assert.is_true(messages[1]:find("Rating saved", 1, true) ~= nil)
        assert.is_true(messages[1]:find("7/10", 1, true) ~= nil)
    end)

    it("builds a 10-scale metadata payload for exact Reading Completion ratings", function()
        local plugin = newPlugin()
        local payload = plugin:buildMetadataRatingPayload({
            dedupe_key = "hash-1:rating:7",
        }, {
            rating = 7,
            ratingScale = 10,
            datetime = "2026-06-02T10:00:00Z",
        })

        assert.are.same({
            dedupeKey = "hash-1:rating:7",
            value = 7,
            scale = 10,
            source = "koreader",
            updatedAt = "2026-06-02T10:00:00Z",
        }, payload)
    end)

    it("changes the rating dedupe key when the exact 1-10 score changes", function()
        local plugin = newPlugin()
        local dedupe_a = plugin:buildMetadataDedupeKey("hash-1", "rating", {
            rating = 7,
            ratingScale = 10,
        })
        local dedupe_b = plugin:buildMetadataDedupeKey("hash-1", "rating", {
            rating = 8,
            ratingScale = 10,
        })

        assert.are.equal("hash-1:rating:7", dedupe_a)
        assert.are.equal("hash-1:rating:8", dedupe_b)
        assert.are_not.equal(dedupe_a, dedupe_b)
    end)

    it("shows Reading Completion menu with finish, mark as read, rating, and cancel actions", function()
        local plugin = newPlugin()
        plugin.current_session = {
            file_path = "/books/demo.epub",
            book_id = 123,
        }
        plugin.buildManualReadStatusActions = function()
            return {
                { backend = "READ", label = "Mark as Read" },
                { backend = "READING", label = "Mark as Reading" },
            }
        end

        plugin:showReadingCompletionMenu()

        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.are.equal("Reading Completion", dialog.title)
        assert.are.equal("Finish & Sync Now", dialog.buttons[1][1].text)
        assert.are.equal("Mark as Read", dialog.buttons[2][1].text)
        assert.are.equal("Set Rating", dialog.buttons[3][1].text)
        assert.are.equal("Cancel", dialog.buttons[4][1].text)
    end)

    it("shows Reading Completion from a close-book context even after the session is cleared", function()
        local plugin = newPlugin()
        plugin.current_session = nil
        plugin.buildManualReadStatusActions = function()
            return {
                { backend = "READ", label = "Mark as Read" },
            }
        end

        plugin:showReadingCompletionMenu({
            context = {
                file_path = "/books/demo.epub",
                file_hash = "hash-1",
                book_id = 123,
            },
        })

        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.are.equal("Reading Completion", dialog.title)
        assert.are.equal("Finish & Sync Now", dialog.buttons[1][1].text)
    end)

    it("prompts for Reading Completion once per completion cycle after closing a near-finished book", function()
        local plugin = newPlugin()
        plugin.ui.doc_settings = newDocSettings({})
        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-1",
            book_id = 123,
            book_file_id = 456,
            start_time = os.time() - 60,
            start_snapshot = { percentage = 94.0, currentPage = 94 },
            book_type = "EPUB",
            tracking_enabled = true,
        }
        plugin.buildManualReadStatusActions = function()
            return {
                { backend = "READ", label = "Mark as Read" },
            }
        end
        plugin.validateSession = function()
            return true
        end
        plugin.getCurrentProgressSnapshot = function()
            return {
                file_path = "/books/demo.epub",
                bookHash = "hash-1",
                bookId = 123,
                bookFileId = 456,
                fileFormat = "EPUB",
                percentage = 99.2,
                currentPage = 99,
                totalPages = 100,
                progress = "/99",
                location = "/99",
                timestamp = os.time(),
            }
        end
        plugin.shouldPushProgress = function()
            return false
        end
        plugin.isOnline = function()
            return false
        end
        plugin.extractAndQueueCurrentMetadata = function()
            return { queued = { queued = 0, failed = 0 } }
        end

        plugin:endSession({ reason = "close" })

        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.are.equal("Reading Completion", dialog.title)
        assert.is_true(plugin.ui.doc_settings._store.grimmlink_reading_completion_prompt.prompted)

        UIManager:reset()
        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-1",
            book_id = 123,
            book_file_id = 456,
            start_time = os.time() - 60,
            start_snapshot = { percentage = 98.0, currentPage = 98 },
            book_type = "EPUB",
            tracking_enabled = true,
        }

        plugin:endSession({ reason = "close" })

        assert.is_nil(UIManager.getLastShown())
    end)

    it("prompts for Reading Completion after KOReader end-of-book dialog is dismissed", function()
        local plugin = newPlugin()
        plugin.ui.doc_settings = newDocSettings({})
        plugin.current_session = {
            file_path = "/books/demo.epub",
            file_hash = "hash-1",
            book_id = 123,
            book_file_id = 456,
            start_time = os.time() - 60,
            start_snapshot = { percentage = 94.0, currentPage = 94 },
            book_type = "EPUB",
            tracking_enabled = true,
        }
        plugin.buildManualReadStatusActions = function()
            return {
                { backend = "READ", label = "Mark as Read" },
            }
        end
        local top_widget_checks = 0
        plugin.getCurrentProgressSnapshot = function()
            return {
                file_path = "/books/demo.epub",
                bookHash = "hash-1",
                bookId = 123,
                bookFileId = 456,
                fileFormat = "EPUB",
                percentage = 100,
                currentPage = 100,
                totalPages = 100,
                progress = "/100",
                location = "/100",
                timestamp = os.time(),
            }
        end
        local original_get_topmost = UIManager.getTopmostVisibleWidget
        UIManager.getTopmostVisibleWidget = function()
            top_widget_checks = top_widget_checks + 1
            if top_widget_checks == 1 then
                return { name = "end_document" }
            end
            return nil
        end

        plugin:onEndOfBook()

        UIManager.getTopmostVisibleWidget = original_get_topmost

        local dialog = UIManager.getLastShown()
        assert.is_not_nil(dialog)
        assert.are.equal("Reading Completion", dialog.title)
        assert.is_true(plugin.ui.doc_settings._store.grimmlink_reading_completion_prompt.prompted)
        assert.is_true(top_widget_checks >= 2)
    end)

    it("waits for KOReader end-of-book dialog to disappear before showing Reading Completion", function()
        local plugin = newPlugin()
        local original_get_topmost = UIManager.getTopmostVisibleWidget
        local seen = 0
        UIManager.getTopmostVisibleWidget = function()
            seen = seen + 1
            if seen <= 3 then
                return { name = "end_document" }
            end
            return nil
        end
        local called = 0

        plugin:waitForKoreaderEndOfBookUi(function()
            called = called + 1
        end, 0)

        UIManager.getTopmostVisibleWidget = original_get_topmost

        assert.are.equal(1, called)
        assert.are.equal(4, seen)
    end)

    it("resets the completion prompt state after progress drops below the reread threshold", function()
        local plugin = newPlugin()
        plugin.ui.doc_settings = newDocSettings({
            grimmlink_reading_completion_prompt = {
                prompted = true,
                progress_percentage = 99.2,
            },
        })

        local should_prompt = plugin:shouldShowReadingCompletionPrompt({
            file_path = "/books/demo.epub",
            file_hash = "hash-1",
            book_id = 123,
        }, 80)

        assert.is_false(should_prompt)
        assert.is_false(plugin.ui.doc_settings._store.grimmlink_reading_completion_prompt.prompted)
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
        local captured_selected_shelf_ids = nil
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
                captured_selected_shelf_ids = opts.selected_shelf_ids_by_type
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
        assert.is_true(captured_selected_shelf_ids.regular["7"])
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

    it("falls back to blocking downloads when async start becomes unavailable", function()
        local execute_download_calls = 0
        local write_index_called = 0
        local upsert_cache_called = 0
        local completion_result = nil
        local plugin = newPlugin({
            shelf_sync_enabled = true,
            sync_regular_shelf_enabled = true,
            selected_regular_shelf_id = 1,
            selected_regular_shelf_name = "Regular Shelf",
            sync_magic_shelf_enabled = false,
            two_way_shelf_delete_sync = false,
            shelf_fast_sync_enabled = false,
            refresh_bookinfo_after_shelf_sync = false,
            download_dir = "/storage/emulated/0/koreader/books/Book",
            refreshApiClient = function() return true end,
            requireReady = function() return true end,
            isOnline = function() return true end,
        })
        plugin.api.isAsyncDownloadAvailable = function()
            return true
        end
        plugin.api.cancelAsyncDownload = function() end
        plugin.shelf_sync = {
            prepareSyncPlan = function()
                return {
                    result = {
                        synced = 0,
                        skipped = 0,
                        failed = 0,
                        deleted = 0,
                        errors = {},
                        snapshot_token = "snapshot-token",
                    },
                    download_queue = {
                        {
                            book_id = 11,
                            title = "Fallback Book",
                            book = {
                                fileSizeKb = 128,
                            },
                        },
                    },
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
            startAsyncDownload = function()
                return nil, "tool missing"
            end,
            executeDownload = function()
                execute_download_calls = execute_download_calls + 1
                return true
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

        local result = plugin:syncShelfNow(true, {
            on_complete = function(sync_result)
                completion_result = sync_result
            end,
        })

        assert.is_nil(result)
        assert.are.equal(1, execute_download_calls)
        assert.are.equal(1, write_index_called)
        assert.are.equal(1, upsert_cache_called)
        assert.is_not_nil(completion_result)
        assert.are.equal(1, completion_result.synced)
        assert.are.equal(0, completion_result.failed)
        assert.are.same({
            used = true,
            reason = "async_start_failed bookId=11: tool missing",
        }, completion_result.async_fallback)
        assert.is_false(plugin._shelf_sync_running)
        assert.are.equal(false, plugin.api._async_available)
    end)
end)
