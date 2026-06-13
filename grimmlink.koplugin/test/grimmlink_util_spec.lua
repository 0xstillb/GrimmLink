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

package.loaded["grimmlink_util"] = nil
local util = require("grimmlink_util")

describe("grimmlink_util helpers", function()
    it("normalizes shelf type values", function()
        assert.are.equal("regular", util.normalizeShelfType(nil))
        assert.are.equal("regular", util.normalizeShelfType("REGULAR"))
        assert.are.equal("magic", util.normalizeShelfType("magic"))
        assert.are.equal("regular", util.normalizeShelfType("other"))
    end)

    it("normalizes percentages from fractions, preserves two decimals, and clamps out-of-range", function()
        assert.are.equal(0.33, util.normalizePercent(55 / 16653))
        assert.are.equal(50.0, util.normalizePercent(0.5))
        assert.are.equal(50.0, util.normalizePercent(50))
        assert.are.equal(100.0, util.normalizePercent(500))
        assert.are.equal(0.0, util.normalizePercent(-1))
        assert.is_nil(util.normalizePercent("NaN"))
    end)

    it("normalizes path separators and trims trailing slashes", function()
        assert.are.equal("/mnt/books/Title.epub", util.normalizePath("\\mnt\\books\\Title.epub"))
        assert.are.equal("/mnt/books", util.normalizeDirectoryPath("/mnt/books/"))
        assert.are.equal("/", util.normalizeDirectoryPath("///"))
    end)

    it("redacts values and urls for logs", function()
        assert.are.equal("[REDACTED]", util.redactSimple("secret", 0))
        assert.are.equal("se...", util.redactSimple("secret", 2))
        assert.are.equal("https://exam...", util.redactUrl("https://example.com/library"))
    end)

    it("formats urls for compact display", function()
        assert.are.equal("https://example.com/.../book.epub", util.formatUrlForDisplay("https://example.com/path/to/book.epub", 80))
        assert.are.equal("https://example.com", util.formatUrlForDisplay("https://example.com/path/to/book.epub", 19))
    end)
end)

