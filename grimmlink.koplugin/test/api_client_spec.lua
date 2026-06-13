package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./test/?.lua",
    "./test/?/init.lua",
    package.path,
}, ";")

local captured_request
local next_http_response
local next_http_responses

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end

package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(target)
                return function(chunk)
                    if chunk then
                        target[#target + 1] = chunk
                    end
                    return 1
                end
            end,
        },
        source = {
            string = function(value)
                local done = false
                return function()
                    if done then
                        return nil
                    end
                    done = true
                    return value
                end
            end,
        },
    }
end

package.preload["socket.http"] = function()
    return {
        request = function(arguments)
            captured_request = arguments
            local response = nil
            if type(next_http_responses) == "table" and #next_http_responses > 0 then
                response = table.remove(next_http_responses, 1)
            else
                response = next_http_response or {
                    body = '{"status":"ok"}',
                    code = 200,
                    headers = {},
                    ok = 1,
                }
            end
            if arguments.sink and response.body then
                arguments.sink(response.body)
            end
            return response.ok or 1, response.code or 200, response.headers or {}
        end,
    }
end

package.preload["ssl.https"] = function()
    return {
        request = function(arguments)
            captured_request = arguments
            local response = nil
            if type(next_http_responses) == "table" and #next_http_responses > 0 then
                response = table.remove(next_http_responses, 1)
            else
                response = next_http_response or {
                body = '{"status":"ok"}',
                code = 200,
                headers = {},
                ok = 1,
            }
            end
            if arguments.sink and response.body then
                arguments.sink(response.body)
            end
            return response.ok or 1, response.code or 200, response.headers or {}
        end,
    }
end

package.preload["json"] = function()
    return {
        encode = function(value)
            if type(value) == "table" and value.message then
                return '{"message":"' .. value.message .. '"}'
            end
            if type(value) == "table" and value.status then
                return '{"status":"' .. tostring(value.status) .. '"}'
            end
            return "{}"
        end,
        decode = function(value)
            if value == '{"status":"ok"}' then
                return { status = "ok" }
            end
            if value == '{"message":"bad"}' then
                return { message = "bad" }
            end
            if value == '{"statuses":["UNREAD","READING","READ","PAUSED","ABANDONED","RE_READING"]}' then
                return { statuses = { "UNREAD", "READING", "READ", "PAUSED", "ABANDONED", "RE_READING" } }
            end
            if value == '{"status":"ok","readStatus":"READ"}' then
                return { status = "ok", readStatus = "READ" }
            end
            if value == '{"ok":true,"items":[]}' then
                return { ok = true, items = {} }
            end
            if value == '{"ok":true,"items":[],"nextCursor":"2026-06-05T00:01:00Z"}' then
                return {
                    ok = true,
                    items = {},
                    nextCursor = "2026-06-05T00:01:00Z",
                }
            end
            error("invalid json")
        end,
    }
end

package.preload["ffi/sha2"] = function()
    return {
        md5 = function(value)
            return "md5:" .. tostring(value)
        end,
    }
end

local APIClient = require("grimmlink_api_client")

describe("GrimmLink API client", function()
    local client

    before_each(function()
        captured_request = nil
        next_http_response = nil
        next_http_responses = nil
        client = APIClient:new()
        client:init("http://example.com", "reader", "secret-password", false)
    end)

    it("hashes plain-text passwords into x-auth-key headers", function()
        local success, code, payload = client:request("GET", client:_apiPath("/auth"))
        assert.is_true(success)
        assert.are.equal(200, code)
        assert.are.equal("ok", payload.status)
        assert.are.equal("reader", captured_request.headers["x-auth-user"])
        assert.are.equal("md5:secret-password", captured_request.headers["x-auth-key"])
    end)

    it("keeps legacy md5 values unchanged", function()
        client:init("http://example.com", "reader", "5f4dcc3b5aa765d61d8327deb882cf99", false)

        local success, code, payload = client:request("GET", client:_apiPath("/auth"))
        assert.is_true(success)
        assert.are.equal(200, code)
        assert.are.equal("ok", payload.status)
        assert.are.equal("5f4dcc3b5aa765d61d8327deb882cf99", captured_request.headers["x-auth-key"])
    end)

    it("uses the canonical PDF bridge endpoint", function()
        client:getPdfProgress(123)
        assert.are.equal("/api/grimmlink/v1/books/123/pdf-progress", captured_request.url:match("/api/grimmlink/v1/books/123/pdf%-progress$") and "/api/grimmlink/v1/books/123/pdf-progress" or nil)

        client:updatePdfProgress(123, { currentPage = 9 })
        assert.are.equal("/api/grimmlink/v1/books/123/pdf-progress", captured_request.url:match("/api/grimmlink/v1/books/123/pdf%-progress$") and "/api/grimmlink/v1/books/123/pdf-progress" or nil)
    end)

    it("returns useful auth errors", function()
        client:init("http://example.com", "", "", false)
        local success, message = client:testAuth()
        assert.is_false(success)
        assert.are.equal("Username not configured", message)

        client:init("http://example.com", "reader", "secret-password", false)
        next_http_response = {
            body = '{"message":"Unauthorized - Invalid credentials"}',
            code = 401,
            headers = {},
            ok = 1,
        }
        success, message = client:testAuth()
        assert.is_false(success)
        assert.is_true(tostring(message):find("Unauthorized") ~= nil)
    end)

    it("uses the reading session endpoints with bookType payloads", function()
        client:submitSession({
            bookId = 99,
            bookType = "PDF",
            startTime = "2026-05-07T00:00:00Z",
            endTime = "2026-05-07T00:01:00Z",
            durationSeconds = 60,
        })
        assert.are.equal("/api/grimmlink/v1/reading-sessions", captured_request.url:match("/api/grimmlink/v1/reading%-sessions$") and "/api/grimmlink/v1/reading-sessions" or nil)

        client:submitSessionBatch(99, "hash-1", "PDF", "KOReader", "device-1", {})
        assert.are.equal("/api/grimmlink/v1/reading-sessions/batch", captured_request.url:match("/api/grimmlink/v1/reading%-sessions/batch$") and "/api/grimmlink/v1/reading-sessions/batch" or nil)
    end)

    it("builds metadata batch payloads", function()
        local payload = client:buildMetadataBatchPayload(
            88,
            "hash-meta",
            900,
            "EPUB",
            "KOReader",
            "device-1",
            { dedupeKey = "r-1", value = 4, scale = 5 },
            { { dedupeKey = "a-1", text = "Highlight" } },
            { { dedupeKey = "b-1", title = "Bookmark" } },
            "2026-06-05T00:00:00Z",
            50
        )
        assert.are.equal(88, payload.bookId)
        assert.are.equal("hash-meta", payload.bookHash)
        assert.are.equal(900, payload.bookFileId)
        assert.are.equal("EPUB", payload.fileFormat)
        assert.are.equal("incremental", payload.syncMode)
        assert.are.equal("2026-06-05T00:00:00Z", payload.since)
        assert.are.equal("2026-06-05T00:00:00Z", payload.cursor)
        assert.are.equal(50, payload.limit)
        assert.are.equal(1, #payload.annotations)
        assert.are.equal(1, #payload.bookmarks)
    end)

    it("omits invalid metadata cursors from payloads", function()
        local payload = client:buildMetadataBatchPayload(
            88,
            "hash-meta",
            900,
            "EPUB",
            "KOReader",
            "device-1",
            nil,
            {},
            {},
            nil,
            50
        )

        assert.is_nil(payload.since)
        assert.is_nil(payload.cursor)

        payload = client:buildMetadataBatchPayload(
            88,
            "hash-meta",
            900,
            "EPUB",
            "KOReader",
            "device-1",
            nil,
            {},
            {},
            "function: 0x79a56e3318",
            50
        )

        assert.is_nil(payload.since)
        assert.is_nil(payload.cursor)
    end)

    it("submits metadata batch to the GrimmLink metadata batch endpoint", function()
        next_http_response = {
            body = '{"ok":true,"push":{"ok":true,"results":{"annotations":[],"bookmarks":[]}},"pull":{"ok":true,"items":[]}}',
            code = 200,
            headers = {},
            ok = 1,
        }
        local success, _, _ = client:submitMetadataBatch({
            schemaVersion = 1,
            syncMode = "incremental",
            bookId = 88,
            bookHash = "hash-meta",
            annotations = {},
            bookmarks = {},
        })
        assert.is_true(success)
        assert.are.equal("/api/grimmlink/v1/syncs/metadata/batch", captured_request.url:match("/api/grimmlink/v1/syncs/metadata/batch$") and "/api/grimmlink/v1/syncs/metadata/batch" or nil)
    end)

    it("pulls metadata from the existing GET endpoint with hash priority", function()
        next_http_response = {
            body = '{"ok":true,"items":[],"nextCursor":"2026-06-05T00:01:00Z"}',
            code = 200,
            headers = {},
            ok = 1,
        }

        local success = client:pullMetadata(
            88,
            "hash meta",
            900,
            "2026-06-05T00:00:00Z",
            50,
            "annotation"
        )

        assert.is_true(success)
        assert.are.equal("GET", captured_request.method)
        assert.is_true(captured_request.url:find("/api/grimmlink/v1/syncs/metadata?", 1, true) ~= nil)
        assert.is_true(captured_request.url:find("bookHash=hash+meta", 1, true) ~= nil)
        assert.is_true(captured_request.url:find("bookId=", 1, true) == nil)
        assert.is_true(captured_request.url:find("bookFileId=", 1, true) == nil)
        assert.is_true(captured_request.url:find("cursor=2026%-06%-05T00%%3A00%%3A00Z") ~= nil)
        assert.is_true(captured_request.url:find("limit=50", 1, true) ~= nil)
        assert.is_true(captured_request.url:find("type=annotation", 1, true) ~= nil)
    end)

    it("falls back from bookId to bookFileId for metadata pulls", function()
        next_http_response = {
            body = '{"ok":true,"items":[]}',
            code = 200,
            headers = {},
            ok = 1,
        }

        assert.is_true(client:pullMetadata(88, nil, 900, nil, 50))
        assert.is_true(captured_request.url:find("bookId=88", 1, true) ~= nil)
        assert.is_true(captured_request.url:find("bookFileId=", 1, true) == nil)

        assert.is_true(client:pullMetadata(nil, nil, 900, nil, 50))
        assert.is_true(captured_request.url:find("bookFileId=900", 1, true) ~= nil)
    end)

    it("rejects malformed successful metadata pull responses", function()
        next_http_response = {
            body = "not-json",
            code = 200,
            headers = {},
            ok = 1,
        }

        local success, message, code = client:pullMetadata(88, nil, nil, nil, 50)
        assert.is_false(success)
        assert.are.equal("Malformed response", message)
        assert.are.equal(200, code)
    end)

    it("fetches supported read statuses from GrimmLink endpoint", function()
        next_http_response = {
            body = '{"statuses":["UNREAD","READING","READ","PAUSED","ABANDONED","RE_READING"]}',
            code = 200,
            headers = {},
            ok = 1,
        }

        local success, statuses = client:getSupportedReadStatuses()
        assert.is_true(success)
        assert.are.same({ "UNREAD", "READING", "READ", "PAUSED", "ABANDONED", "RE_READING" }, statuses)
        assert.are.equal("/api/grimmlink/v1/books/read-statuses", captured_request.url:match("/api/grimmlink/v1/books/read%-statuses$") and "/api/grimmlink/v1/books/read-statuses" or nil)
    end)

    it("updates read status through GrimmLink endpoint", function()
        next_http_response = {
            body = '{"status":"ok","readStatus":"READ"}',
            code = 200,
            headers = {},
            ok = 1,
        }

        local success, response = client:updateBookReadStatus(123, "read")
        assert.is_true(success)
        assert.are.equal("READ", response.readStatus)
        assert.are.equal("/api/grimmlink/v1/books/123/status", captured_request.url:match("/api/grimmlink/v1/books/123/status$") and "/api/grimmlink/v1/books/123/status" or nil)
        local request_payload = type(captured_request.source) == "function" and captured_request.source() or nil
        assert.is_true(type(request_payload) == "string")
        assert.is_true(request_payload:find('"status":"READ"', 1, true) ~= nil)
    end)

    it("normalizes shelf book file format from extension when format is missing", function()
        local normalized = client:normalizeShelfBookObject({
            bookId = 321,
            title = "Demo",
            fileName = "demo_book.pdf",
            extension = "pdf",
        })
        assert.is_not_nil(normalized)
        assert.are.equal("pdf", normalized.extension)
        assert.are.equal("PDF", normalized.fileFormat)
    end)

    it("normalizes shelf book file format from filename extension when only fileName exists", function()
        local normalized = client:normalizeShelfBookObject({
            id = 654,
            title = "Demo EPUB",
            fileName = "demo_epub.epub",
        })
        assert.is_not_nil(normalized)
        assert.are.equal("epub", normalized.extension)
        assert.are.equal("EPUB", normalized.fileFormat)
    end)

    it("normalizes shelf book file format from mime type values", function()
        local normalized = client:normalizeShelfBookObject({
            id = 987,
            title = "Demo PDF Mime",
            fileFormat = "application/pdf",
            fileName = "demo_pdf.pdf",
        })
        assert.is_not_nil(normalized)
        assert.are.equal("pdf", normalized.extension)
        assert.are.equal("PDF", normalized.fileFormat)
    end)

    it("uses fallback URL temporarily without overwriting primary server_url", function()
        client:setFallbackUrl("https://backup.example.com")
        next_http_responses = {
            {
                body = nil,
                code = "timeout",
                headers = {},
                ok = nil,
            },
            {
                body = '{"status":"ok"}',
                code = 200,
                headers = {},
                ok = 1,
            },
        }

        local success, code, payload, _headers, details = client:request("GET", client:_apiPath("/auth"))
        assert.is_true(success)
        assert.are.equal(200, code)
        assert.are.equal("ok", payload.status)
        assert.are.equal("http://example.com", client.server_url)
        assert.is_true(details.used_fallback)
        assert.are.equal("https://backup.example.com/api/grimmlink/v1/auth", details.used_url)
        local last_failure = client:getLastPrimaryFailure()
        assert.is_true(type(last_failure) == "table")
        assert.are.equal("http://example.com", last_failure.url)
    end)

    it("clears last primary failure after primary recovers", function()
        client:setFallbackUrl("https://backup.example.com")
        next_http_responses = {
            {
                body = nil,
                code = "timeout",
                headers = {},
                ok = nil,
            },
            {
                body = '{"status":"ok"}',
                code = 200,
                headers = {},
                ok = 1,
            },
        }
        local ok_first = select(1, client:request("GET", client:_apiPath("/auth")))
        assert.is_true(ok_first)
        assert.is_not_nil(client:getLastPrimaryFailure())

        next_http_response = {
            body = '{"status":"ok"}',
            code = 200,
            headers = {},
            ok = 1,
        }
        local ok_second = select(1, client:request("GET", client:_apiPath("/auth")))
        assert.is_true(ok_second)
        assert.is_nil(client:getLastPrimaryFailure())
    end)

    it("uses dedicated fallback timeout when primary transport fails", function()
        client.timeout = 15
        client.fallback_timeout = 7
        client:setFallbackUrl("https://backup.example.com")
        next_http_responses = {
            {
                body = nil,
                code = "timeout",
                headers = {},
                ok = nil,
            },
            {
                body = nil,
                code = "timeout",
                headers = {},
                ok = nil,
            },
        }

        local ok, code, message, _headers, details = client:request("GET", client:_apiPath("/auth"))
        assert.is_false(ok)
        assert.is_nil(code)
        assert.is_true(type(message) == "string")
        assert.is_true(details.used_fallback)
        assert.are.equal(15, require("socket.http").TIMEOUT)
        assert.are.equal(7, require("ssl.https").TIMEOUT)
    end)

    it("centralizes the API prefix", function()
        assert.are.equal("/api/grimmlink/v1", client.api_prefix)
        assert.are.equal("/api/grimmlink/v1/syncs/progress", client:_apiPath("/syncs/progress"))
    end)
end)
