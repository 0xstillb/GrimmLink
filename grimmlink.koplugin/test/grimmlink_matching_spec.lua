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

package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                local value = values[tonumber(index)]
                if value == nil then
                    return ""
                end
                return tostring(value)
            end))
        end,
    }
end

package.loaded["grimmlink_matching"] = nil
local matching = require("grimmlink_matching").new()

describe("grimmlink_matching", function()
    it("returns matched state from existing hash cache", function()
        local api_called = false
        local plugin = {
            db = {
                getBookByHash = function()
                    return { book_id = 21 }
                end,
            },
            resolveBookByFilePath = function()
                return { file_hash = "hash-1", file_path = "/books/a.epub" }
            end,
            isOnline = function() return true end,
            isApiReady = function() return true end,
            refreshApiClient = function() return true end,
            api = {
                getBookByHash = function()
                    api_called = true
                    return true, { id = 99 }
                end,
            },
            showMessage = function() end,
            showTextInput = function() end,
        }

        local result = matching:matchBookByPath(plugin, "/books/a.epub", {})
        assert.are.equal("matched", result.state)
        assert.are.equal("cache", result.data.source)
        assert.is_false(api_called)
    end)

    it("matches remotely by hash and stores local cache mapping", function()
        local saved = nil
        local plugin = {
            db = {
                getBookByHash = function()
                    return nil
                end,
                saveBookCache = function(_, file_path, file_hash, book_id, title, author)
                    saved = {
                        file_path = file_path,
                        file_hash = file_hash,
                        book_id = book_id,
                        title = title,
                        author = author,
                    }
                    return true
                end,
            },
            resolveBookByFilePath = function()
                return { file_hash = "hash-2" }
            end,
            isOnline = function() return true end,
            isApiReady = function() return true end,
            refreshApiClient = function() return true end,
            api = {
                getBookByHash = function()
                    return true, { id = 77 }
                end,
            },
            showMessage = function() end,
            showTextInput = function() end,
        }

        local result = matching:matchBookByPath(plugin, "/books/b-title.epub", {})
        assert.are.equal("matched", result.state)
        assert.are.equal("remote_hash", result.data.source)
        assert.are.equal(77, saved.book_id)
        assert.are.equal("b-title", saved.title)
    end)

    it("returns not_found and accepts manual id mapping", function()
        local prompt_callback = nil
        local saved = nil
        local plugin = {
            db = {
                getBookByHash = function()
                    return nil
                end,
                saveBookCache = function(_, file_path, file_hash, book_id, title)
                    saved = {
                        file_path = file_path,
                        file_hash = file_hash,
                        book_id = book_id,
                        title = title,
                    }
                    return true
                end,
            },
            resolveBookByFilePath = function()
                return { file_hash = "hash-3" }
            end,
            isOnline = function() return false end,
            isApiReady = function() return false end,
            refreshApiClient = function() return false end,
            api = {},
            showMessage = function() end,
            showTextInput = function(_, _, _, _, _, callback)
                prompt_callback = callback
            end,
        }

        local result = matching:matchBookByPath(plugin, "/books/c-title.epub", {})
        assert.are.equal("not_found", result.state)
        assert.is_truthy(prompt_callback)

        prompt_callback("123")
        assert.are.equal(123, saved.book_id)
        assert.are.equal("c-title", saved.title)
    end)

    it("returns error when file hash cannot be determined", function()
        local plugin = {
            db = {},
            resolveBookByFilePath = function()
                return nil
            end,
            calculateBookHash = function()
                error("hash fail")
            end,
            showMessage = function() end,
            showTextInput = function() end,
        }

        local result = matching:matchBookByPath(plugin, "/books/d.epub", {})
        assert.are.equal("error", result.state)
        assert.are.equal("hash_unavailable", result.data.reason)
    end)
end)

