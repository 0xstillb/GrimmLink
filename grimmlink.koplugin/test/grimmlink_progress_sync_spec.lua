package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./test/?.lua",
    package.path,
}, ";")

package.preload["gettext"] = function()
    return function(text)
        return text
    end
end

package.loaded["grimmlink_progress_sync"] = nil
local progress_sync = require("grimmlink_progress_sync").new()

describe("grimmlink_progress_sync", function()
    it("builds progress payload from snapshot", function()
        local payload = progress_sync:buildProgressPayload({
            bookHash = "h",
            bookId = 1,
            bookFileId = 2,
            progress = "cfi",
            percentage = 10.5,
            currentPage = 1,
            totalPages = 10,
            timestamp = "2026-01-01T00:00:00Z",
            fileFormat = "EPUB",
        }, "manual")

        assert.are.equal("h", payload.bookHash)
        assert.are.equal(1, payload.bookId)
        assert.are.equal(2, payload.bookFileId)
        assert.are.equal("manual", payload.reason)
    end)

    it("pushes current session progress for selected file", function()
        local calls = { push = 0, pending = 0 }
        local plugin = {
            resolveBookContextByPath = function()
                return { file_path = "/books/a.epub", file_hash = "h1" }
            end,
            isTrackingEnabled = function() return true end,
            current_session = {
                file_path = "/books/a.epub",
                file_hash = "h1",
                book_id = 11,
                book_file_id = 22,
            },
            getCurrentProgressSnapshot = function()
                return { fileFormat = "PDF" }
            end,
            pushProgressSnapshot = function()
                calls.push = calls.push + 1
            end,
            syncPendingNow = function()
                calls.pending = calls.pending + 1
            end,
            showTrackingDisabledMessage = function() end,
            showMessage = function() end,
        }

        progress_sync:syncThisBookFromPath(plugin, "/books/a.epub")
        assert.are.equal(1, calls.push)
        assert.are.equal(1, calls.pending)
    end)

    it("requires opened session when pulling remote progress", function()
        local called = { pull = 0, msg = 0 }
        local plugin = {
            current_session = nil,
            showMessage = function()
                called.msg = called.msg + 1
            end,
            manualPullProgress = function()
                called.pull = called.pull + 1
            end,
        }

        progress_sync:pullRemoteProgressFromPath(plugin, "/books/a.epub")
        assert.are.equal(1, called.msg)
        assert.are.equal(0, called.pull)
    end)
end)

