package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./test/?.lua",
    "./test/?/init.lua",
    package.path,
}, ";")

package.preload["json"] = function()
    return {
        encode = function()
            return "{}"
        end,
    }
end

describe("GrimmLink metadata extractor", function()
    before_each(function()
        package.loaded["grimmlink_metadata_extractor"] = nil
        package.loaded["docsettings"] = nil
        package.preload["docsettings"] = nil
    end)

    it("extracts rating, highlights, notes, and bookmarks from live doc settings", function()
        local Extractor = require("grimmlink_metadata_extractor")
        local doc_settings = {
            readSetting = function(_, key)
                if key == "summary" then
                    return { rating = 4 }
                end
                if key == "annotations" then
                    return {
                        {
                            text = "Highlight text",
                            note = "Note text",
                            datetime = "2026-05-27T10:00:00Z",
                            pos0 = "x1",
                            pos1 = "x2",
                            color = "yellow",
                            chapter = "C1",
                        },
                        {
                            page = "12",
                            pageno = 12,
                            text = "Bookmark text",
                            datetime = "2026-05-27T10:05:00Z",
                        },
                        "malformed",
                    }
                end
                return nil
            end,
        }

        local extracted = Extractor.extract({
            file_path = "/books/demo.epub",
            doc_settings = doc_settings,
        })
        assert.is_not_nil(extracted.rating)
        assert.are.equal(4, extracted.rating.raw)
        assert.are.equal(4, extracted.rating.value)
        assert.are.equal(5, extracted.rating.scale)
        assert.are.equal(8, extracted.rating.normalized)
        assert.are.equal(1, #extracted.highlights)
        assert.are.equal(1, #extracted.bookmarks)
        assert.are.equal(1, extracted.counts.notes_count)
        assert.are.equal(1, extracted.counts.highlights_count)
        assert.are.equal(1, extracted.counts.bookmarks_count)
    end)

    it("falls back to loading doc settings by file path", function()
        package.preload["docsettings"] = function()
            return {
                open = function(_path)
                    return {
                        readSetting = function(_, key)
                            if key == "summary" then
                                return { rating = 5 }
                            end
                            if key == "annotations" then
                                return {}
                            end
                            return nil
                        end,
                    }
                end,
            }
        end

        local Extractor = require("grimmlink_metadata_extractor")
        local extracted = Extractor.extract({
            file_path = "/books/demo.epub",
        })
        assert.is_not_nil(extracted.rating)
        assert.are.equal(5, extracted.rating.raw)
        assert.are.equal(5, extracted.rating.value)
        assert.are.equal(5, extracted.rating.scale)
        assert.are.equal(10, extracted.rating.normalized)
        assert.are.equal(0, extracted.counts.highlights_count)
        assert.are.equal(0, extracted.counts.bookmarks_count)
    end)

    it("prefers an exact Grimmlink 1-10 rating when it matches KOReader stars", function()
        local Extractor = require("grimmlink_metadata_extractor")
        local doc_settings = {
            readSetting = function(_, key)
                if key == "summary" then
                    return { rating = 4 }
                end
                if key == "grimmlink_rating_state" then
                    return { value = 7, scale = 10, summary_rating = 4 }
                end
                if key == "annotations" then
                    return {}
                end
                return nil
            end,
        }

        local extracted = Extractor.extract({
            file_path = "/books/demo.epub",
            doc_settings = doc_settings,
        })

        assert.is_not_nil(extracted.rating)
        assert.are.equal(4, extracted.rating.raw)
        assert.are.equal(7, extracted.rating.value)
        assert.are.equal(10, extracted.rating.scale)
        assert.are.equal(7, extracted.rating.normalized)
    end)

    it("falls back to KOReader stars when the stored exact rating no longer matches", function()
        local Extractor = require("grimmlink_metadata_extractor")
        local doc_settings = {
            readSetting = function(_, key)
                if key == "summary" then
                    return { rating = 3 }
                end
                if key == "grimmlink_rating_state" then
                    return { value = 7, scale = 10, summary_rating = 4 }
                end
                if key == "annotations" then
                    return {}
                end
                return nil
            end,
        }

        local extracted = Extractor.extract({
            file_path = "/books/demo.epub",
            doc_settings = doc_settings,
        })

        assert.is_not_nil(extracted.rating)
        assert.are.equal(3, extracted.rating.raw)
        assert.are.equal(3, extracted.rating.value)
        assert.are.equal(5, extracted.rating.scale)
        assert.are.equal(6, extracted.rating.normalized)
    end)
end)
