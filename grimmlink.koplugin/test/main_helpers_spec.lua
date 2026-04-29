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
end)
