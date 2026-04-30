local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

local Grimmlink = require("main")
restore_stubs()

describe("GrimmLink helper methods", function()
    local plugin

    before_each(function()
        plugin = setmetatable({
            threshold_percent = 1.0,
            threshold_pages = 5,
            cfi_conversion_enabled = false,
            device_name = "KOReader",
            device_id = "device-1",
        }, { __index = Grimmlink })
    end)

    it("formats duration values", function()
        assert.are.equal("0s", plugin:formatDuration(nil))
        assert.are.equal("59s", plugin:formatDuration(59))
        assert.are.equal("1m 30s", plugin:formatDuration(90))
        assert.are.equal("1h 1m 1s", plugin:formatDuration(3661))
    end)

    it("detects book types from file extension", function()
        assert.are.equal("EPUB", plugin:getBookType("/books/novel.epub"))
        assert.are.equal("PDF", plugin:getBookType("/books/manual.PDF"))
        assert.are.equal("CBX", plugin:getBookType("/books/comic.cbz"))
    end)

    it("normalizes remote percentage scale and aliases device id", function()
        local normalized = plugin:normalizeRemoteProgress({
            document = "hash",
            percentage = 0.458,
            device_id = "dev-1",
        })

        assert.are.equal(45.8, normalized.percentage)
        assert.are.equal("dev-1", normalized.deviceId)
        assert.are.equal("hash", normalized.bookHash)
    end)

    it("detects significant progress differences", function()
        local changed = plugin:progressDifferenceExceeded(
            { percentage = 42.3, currentPage = 100, location = "100" },
            { percentage = 45.0, currentPage = 107, location = "107" }
        )
        assert.is_true(changed)
    end)

    it("prefers remote when only remote changed", function()
        local decision = plugin:compareOpenProgress(
            { percentage = 12.0, currentPage = 12, location = "12", timestamp = 100 },
            { percentage = 45.0, currentPage = 45, location = "45", timestamp = 200 },
            {
                local_percentage = 12.0,
                local_current_page = 12,
                local_location = "12",
                local_timestamp = 100,
                remote_percentage = 10.0,
                remote_current_page = 10,
                remote_location = "10",
                remote_timestamp = 90,
            }
        )

        assert.are.equal("remote_newer", decision)
    end)

    it("flags conflict when both local and remote changed", function()
        local decision = plugin:compareOpenProgress(
            { percentage = 42.3, currentPage = 134, location = "134", timestamp = 220 },
            { percentage = 45.8, currentPage = 145, location = "145", timestamp = 210 },
            {
                local_percentage = 40.0,
                local_current_page = 120,
                local_location = "120",
                local_timestamp = 100,
                remote_percentage = 39.0,
                remote_current_page = 118,
                remote_location = "118",
                remote_timestamp = 95,
            }
        )

        assert.are.equal("conflict", decision)
    end)

    it("does not treat backend raw native fields as a web jump target", function()
        local normalized = plugin:normalizeWebBridgeProgress({
            percentage = 61.2,
            timestamp = 500,
            rawKoreaderXPointer = "/body/DocFragment[9]/body/div[1]",
            source = "WEB_READER",
        })

        assert.are.equal(61.2, normalized.percentage)
        assert.is_nil(normalized.location)
        assert.are.equal("WEB_READER", normalized.source)
    end)

    it("builds a percentage-first web bridge payload when CFI conversion is disabled", function()
        local payload = plugin:buildWebBridgePayload({
            bookId = 42,
            bookHash = "hash-1",
            percentage = 44.5,
            currentPage = 120,
            totalPages = 300,
            location = "/body/DocFragment[1]/body/div[3]",
            progress = "/body/DocFragment[1]/body/div[3]",
            timestamp = 900,
        }, {
            remote_updated_at = 850,
        }, false)

        assert.are.equal(44.5, payload.percentage)
        assert.are.equal(850, payload.expectedUpdatedAt)
        assert.is_nil(payload.epubCfi)
        assert.are.equal("/body/DocFragment[1]/body/div[3]", payload.rawKoreaderXPointer)
        assert.is_false(payload.force)
    end)

    it("captures annotations before syncing pending work on suspend", function()
        local calls = {}
        plugin.enabled = true
        plugin.endSession = function(_, options)
            calls[#calls + 1] = "endSession:" .. tostring(options.reason)
            return true
        end
        plugin.captureCurrentDocumentAnnotations = function()
            calls[#calls + 1] = "capture"
        end
        plugin.isOnline = function()
            return true
        end
        plugin.syncPendingNow = function(_, silent)
            calls[#calls + 1] = "syncPendingNow:" .. tostring(silent)
        end
        plugin.logInfo = function() end
        plugin.logWarn = function() end

        local result = plugin:onSuspend()

        assert.is_false(result)
        assert.are.same({
            "endSession:suspend",
            "capture",
            "syncPendingNow:true",
        }, calls)
    end)
end)
