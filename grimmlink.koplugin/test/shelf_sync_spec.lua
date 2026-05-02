package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./test/?.lua",
    "./test/?/init.lua",
    package.path,
}, ";")

local created_dirs = {}
local mock_attrs = {}
local mock_dir_entries = {}
local removed_paths = {}

package.preload["datastorage"] = function()
    return {
        getDataDir = function()
            return "/storage/emulated/0/koreader"
        end,
        getSettingsDir = function()
            return "/storage/emulated/0/koreader/settings"
        end,
    }
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end

package.preload["lfs"] = function()
    return {
        attributes = function(path)
            if mock_attrs[path] then
                return mock_attrs[path]
            end
            if path == "/storage/emulated/0/koreader/books" then
                return { mode = "directory" }
            end
            if created_dirs[path] then
                return { mode = "directory" }
            end
            return nil
        end,
        dir = function(path)
            local entries = mock_dir_entries[path] or {}
            local index = 0
            return function()
                index = index + 1
                return entries[index]
            end
        end,
        mkdir = function(path)
            created_dirs[path] = true
            return true
        end,
        rmdir = function(path)
            removed_paths[#removed_paths + 1] = path
            mock_attrs[path] = nil
            mock_dir_entries[path] = nil
            return true
        end,
    }
end

package.loaded["datastorage"] = nil
package.loaded["logger"] = nil
package.loaded["lfs"] = nil
package.loaded["grimmlink_shelf_sync"] = nil
local ShelfSync = require("grimmlink_shelf_sync")

describe("GrimmLink shelf sync download directory", function()
    local original_os_remove = os.remove

    before_each(function()
        created_dirs = {}
        mock_attrs = {}
        mock_dir_entries = {}
        removed_paths = {}
        os.remove = function(path)
            removed_paths[#removed_paths + 1] = path
            mock_attrs[path] = nil
            return true
        end
    end)

    after_each(function()
        os.remove = original_os_remove
    end)

    it("creates and uses a Book subfolder for auto-detected downloads", function()
        local sync = ShelfSync:new({}, {})
        local dir = sync:resolveDownloadDir("")

        assert.are.equal("/storage/emulated/0/koreader/books/Book", dir)
        assert.is_true(created_dirs["/storage/emulated/0/koreader/books/Book"])
    end)

    it("keeps an explicit download directory unchanged", function()
        local sync = ShelfSync:new({}, {})
        created_dirs["/storage/emulated/0/BooksCustom"] = true

        local dir = sync:resolveDownloadDir("/storage/emulated/0/BooksCustom")

        assert.are.equal("/storage/emulated/0/BooksCustom", dir)
    end)

    it("removes nested .sdr directories when delete_sdr is enabled", function()
        local deleted_entry = nil
        local sync = ShelfSync:new({
            deleteShelfSyncEntry = function(_, book_id)
                deleted_entry = book_id
            end,
        }, {})

        mock_attrs["/storage/emulated/0/koreader/books/Book/title.epub"] = { mode = "file" }
        mock_attrs["/storage/emulated/0/koreader/books/Book/title.epub.sdr"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader/books/Book/title.epub.sdr/metadata.lua"] = { mode = "file" }
        mock_attrs["/storage/emulated/0/koreader/books/Book/title.epub.sdr/cache"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader/books/Book/title.epub.sdr/cache/page1.dat"] = { mode = "file" }
        mock_dir_entries["/storage/emulated/0/koreader/books/Book/title.epub.sdr"] = { ".", "..", "metadata.lua", "cache" }
        mock_dir_entries["/storage/emulated/0/koreader/books/Book/title.epub.sdr/cache"] = { ".", "..", "page1.dat" }

        local ok = sync:deleteLocalBook({
            book_id = 42,
            downloaded_by_grimmlink = 1,
            local_path = "/storage/emulated/0/koreader/books/Book/title.epub",
        }, true, "/storage/emulated/0/koreader/books/Book")

        assert.is_true(ok)
        assert.are.equal(42, deleted_entry)
        assert.is_nil(mock_attrs["/storage/emulated/0/koreader/books/Book/title.epub.sdr"])
        assert.is_nil(mock_attrs["/storage/emulated/0/koreader/books/Book/title.epub.sdr/cache"])
    end)

    it("removes basename .sdr directories used by KOReader sidecars", function()
        local deleted_entry = nil
        local cached_book = nil
        local sync = ShelfSync:new({
            deleteShelfSyncEntry = function(_, book_id)
                deleted_entry = book_id
            end,
            saveBookCache = function(_, file_path, file_hash, book_id, title, author)
                cached_book = {
                    file_path = file_path,
                    file_hash = file_hash,
                    book_id = book_id,
                    title = title,
                    author = author,
                }
                return true
            end,
        }, {})

        mock_attrs["/storage/emulated/0/koreader/books/Book/title.pdf"] = { mode = "file" }
        mock_attrs["/storage/emulated/0/koreader/books/Book/title.sdr"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader/books/Book/title.sdr/metadata.pdf.lua"] = { mode = "file" }
        mock_dir_entries["/storage/emulated/0/koreader/books/Book/title.sdr"] = { ".", "..", "metadata.pdf.lua" }

        local ok = sync:deleteLocalBook({
            book_id = 84,
            downloaded_by_grimmlink = 1,
            local_path = "/storage/emulated/0/koreader/books/Book/title.pdf",
        }, true, "/storage/emulated/0/koreader/books/Book")

        assert.is_true(ok)
        assert.are.equal(84, deleted_entry)
        assert.is_nil(mock_attrs["/storage/emulated/0/koreader/books/Book/title.sdr"])
        assert.is_nil(cached_book)
    end)

    it("stores a file-path book cache entry for downloaded shelf books", function()
        local cached_book = nil
        local saved_entry = nil
        local sync = ShelfSync:new({
            upsertShelfSyncEntry = function(_, entry)
                saved_entry = entry
                return true
            end,
            saveBookCache = function(_, file_path, file_hash, book_id, title, author)
                cached_book = {
                    file_path = file_path,
                    file_hash = file_hash,
                    book_id = book_id,
                    title = title,
                    author = author,
                }
                return true
            end,
            getShelfSyncEntry = function()
                return nil
            end,
            getAllShelfSyncEntries = function()
                return {}
            end,
        }, {
            getShelfBooks = function()
                return true, {
                    {
                        bookId = 123,
                        title = "Shelf Book",
                        author = "Sync Author",
                        fileName = "Shelf Book.pdf",
                        fileFormat = "PDF",
                        fileSizeKb = 256,
                    },
                }
            end,
            downloadBookToFile = function(_, _, dest_path)
                mock_attrs[dest_path] = { mode = "file", size = 256 * 1024 }
                return true
            end,
        })

        local result = sync:syncShelf({
            shelf_id = 9,
            download_dir = "/storage/emulated/0/koreader/books/Book",
            use_original_filename = true,
            two_way_delete_sync = false,
            delete_sdr_on_book_delete = false,
        }, function() end)

        assert.are.equal(1, result.synced)
        assert.is_not_nil(saved_entry)
        assert.is_not_nil(cached_book)
        assert.are.equal("/storage/emulated/0/koreader/books/Book/Shelf Book.pdf", cached_book.file_path)
        assert.are.equal("", cached_book.file_hash)
        assert.are.equal(123, cached_book.book_id)
    end)
end)
