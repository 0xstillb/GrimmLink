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
local renamed_paths = {}

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
            if path == "/storage/emulated/0/koreader" then
                return { mode = "directory" }
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

package.preload["json"] = function()
    return {
        encode = function(t) return "{}" end,
        decode = function(s) return {} end,
    }
end

package.preload["lua-ljsqlite3/init"] = function()
    return {
        OK = 0,
        DONE = 101,
        open = function() return nil end,
    }
end

package.loaded["datastorage"] = nil
package.loaded["logger"] = nil
package.loaded["lfs"] = nil
package.loaded["json"] = nil
package.loaded["lua-ljsqlite3/init"] = nil
package.loaded["grimmlink_shelf_sync"] = nil
local ShelfSync = require("grimmlink_shelf_sync")

describe("GrimmLink shelf sync download directory", function()
    local original_os_remove = os.remove
    local original_os_rename = os.rename
    local original_reader_settings = _G.G_reader_settings

    before_each(function()
        created_dirs = {}
        mock_attrs = {}
        mock_dir_entries = {}
        removed_paths = {}
        renamed_paths = {}
        os.remove = function(path)
            removed_paths[#removed_paths + 1] = path
            mock_attrs[path] = nil
            return true
        end
        os.rename = function(from_path, to_path)
            renamed_paths[#renamed_paths + 1] = { from_path, to_path }
            if mock_attrs[from_path] then
                mock_attrs[to_path] = mock_attrs[from_path]
                mock_attrs[from_path] = nil
                return true
            end
            return nil, "missing_source"
        end
    end)

    after_each(function()
        os.remove = original_os_remove
        os.rename = original_os_rename
        _G.G_reader_settings = original_reader_settings
    end)

    it("creates and uses a Book subfolder for auto-detected downloads", function()
        local sync = ShelfSync:new({}, {})
        local dir = sync:resolveDownloadDir("")

        assert.are.equal("/storage/emulated/0/koreader/Book", dir)
        assert.is_true(created_dirs["/storage/emulated/0/koreader/Book"])
    end)

    it("keeps DataStorage directory priority even when home_dir is set", function()
        _G.G_reader_settings = {
            readSetting = function(_, key)
                if key == "home_dir" then
                    return "/storage/emulated/0/ReaderHome"
                end
                return nil
            end,
        }
        mock_attrs["/storage/emulated/0/ReaderHome"] = { mode = "directory" }

        local sync = ShelfSync:new({}, {})
        local dir = sync:resolveDownloadDir("")

        assert.are.equal("/storage/emulated/0/koreader/Book", dir)
    end)

    it("keeps an explicit download directory unchanged", function()
        local sync = ShelfSync:new({}, {})
        created_dirs["/storage/emulated/0/BooksCustom"] = true

        local dir = sync:resolveDownloadDir("/storage/emulated/0/BooksCustom")

        assert.are.equal("/storage/emulated/0/BooksCustom", dir)
    end)

    it("builds safe filename from extension when fileFormat is missing", function()
        local sync = ShelfSync:new({}, {})
        local filename = sync:buildSafeFilename({
            bookId = 77,
            title = "Magic Format",
            fileName = "Magic Format.pdf",
            extension = "pdf",
        }, false)
        assert.are.equal("Magic Format_77.pdf", filename)
    end)

    it("builds safe filename from mime-type fileFormat values", function()
        local sync = ShelfSync:new({}, {})
        local filename = sync:buildSafeFilename({
            bookId = 78,
            title = "Mime Format",
            fileFormat = "application/pdf",
        }, false)
        assert.are.equal("Mime Format_78.pdf", filename)
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

    it("allows deleting auto-resolved regular shelf files when download_dir is blank", function()
        local deleted_entry = nil
        local sync = ShelfSync:new({
            deleteShelfSyncEntry = function(_, book_id)
                deleted_entry = book_id
                return true
            end,
        }, {})
        sync.deletion = require("grimmlink_deletion").new()

        mock_attrs["/storage/emulated/0/koreader/Book/auto.epub"] = { mode = "file" }

        local ok = sync:deleteLocalBook({
            book_id = 91,
            shelf_id = 1,
            shelf_type = "regular",
            downloaded_by_grimmlink = 1,
            local_path = "/storage/emulated/0/koreader/Book/auto.epub",
        }, false, "")

        assert.is_true(ok)
        assert.are.equal(91, deleted_entry)
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
            download_dir = "/storage/emulated/0/koreader/Book",
            use_original_filename = true,
            two_way_delete_sync = false,
            delete_sdr_on_book_delete = false,
        }, function() end)

        assert.are.equal(1, result.synced)
        assert.is_not_nil(saved_entry)
        assert.is_not_nil(cached_book)
        assert.are.equal("/storage/emulated/0/koreader/Book/Shelf Book.pdf", cached_book.file_path)
        assert.are.equal("", cached_book.file_hash)
        assert.are.equal(123, cached_book.book_id)
    end)

    it("resolves shelf download directory by shelf type and settings", function()
        local sync = ShelfSync:new({}, {})
        local regular_dir = sync:resolveDownloadDirForShelfType("regular", {
            download_dir = "/shared",
            use_separate_magic_download_dir = true,
            magic_download_dir = "/magic",
        })
        local magic_dir = sync:resolveDownloadDirForShelfType("magic", {
            download_dir = "/shared",
            use_separate_magic_download_dir = true,
            magic_download_dir = "/magic",
        })
        local magic_shared = sync:resolveDownloadDirForShelfType("magic", {
            download_dir = "/shared",
            use_separate_magic_download_dir = false,
            magic_download_dir = "/magic",
        })

        assert.are.equal("/shared", regular_dir)
        assert.are.equal("/magic", magic_dir)
        assert.are.equal("/shared", magic_shared)
    end)

    it("moves only magic-only files into the separate magic directory", function()
        local updated_paths = {}
        local deleted_cache_paths = {}
        local sync = ShelfSync:new({
            getMagicOnlyShelfMappings = function()
                return {
                    {
                        book_id = 101,
                        shelf_id = 7,
                        shelf_type = "magic",
                        local_path = "/shared/Alpha.epub",
                        downloaded_by_grimmlink = 1,
                        remote_title = "Alpha",
                        remote_author = "Author A",
                    },
                    {
                        book_id = 202,
                        shelf_id = 8,
                        shelf_type = "magic",
                        local_path = "/shared/Beta.epub",
                        downloaded_by_grimmlink = 1,
                    },
                }
            end,
            isBookTrackedByRegularShelf = function(_, book_id)
                return tonumber(book_id) == 202
            end,
            getShelfMappingsForBook = function(_, book_id)
                return {
                    {
                        book_id = book_id,
                        shelf_id = book_id == 101 and 7 or 8,
                        shelf_type = "magic",
                    },
                }
            end,
            updateShelfMappingLocalPath = function(_, book_id, _shelf_id, _shelf_type, local_path)
                updated_paths[book_id] = local_path
                return true
            end,
            getShelfSyncEntryByLocalPath = function()
                return nil
            end,
            saveBookCache = function()
                return true
            end,
        }, {})
        sync.deleteFromBookInfoCache = function(_, local_path)
            deleted_cache_paths[#deleted_cache_paths + 1] = local_path
            return true
        end

        mock_attrs["/shared"] = { mode = "directory" }
        mock_attrs["/magic"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader/settings"] = { mode = "directory" }
        mock_attrs["/shared/Alpha.epub"] = { mode = "file", size = 1234 }
        mock_attrs["/shared/Beta.epub"] = { mode = "file", size = 2345 }

        local summary = sync:moveMagicShelfFilesToDirectory("/magic", {
            shared_dir = "/shared",
            download_dir = "/shared",
        })

        assert.are.equal(1, summary.moved)
        assert.are.equal(1, summary.shared)
        assert.are.equal(0, summary.failed)
        assert.are.equal("/magic/Alpha.epub", updated_paths[101])
        assert.is_nil(updated_paths[202])
        assert.is_not_nil(mock_attrs["/magic/Alpha.epub"])
        assert.is_not_nil(mock_attrs["/shared/Beta.epub"])
        assert.are.equal(1, #deleted_cache_paths)
        assert.are.equal("/shared/Alpha.epub", deleted_cache_paths[1])
    end)

    it("moves magic-only files back to the shared directory", function()
        local updated_paths = {}
        local sync = ShelfSync:new({
            getMagicOnlyShelfMappings = function()
                return {
                    {
                        book_id = 303,
                        shelf_id = 9,
                        shelf_type = "magic",
                        local_path = "/magic/Gamma.epub",
                        downloaded_by_grimmlink = 1,
                        remote_title = "Gamma",
                        remote_author = "Author G",
                    },
                }
            end,
            isBookTrackedByRegularShelf = function()
                return false
            end,
            getShelfMappingsForBook = function(_, book_id)
                return {
                    {
                        book_id = book_id,
                        shelf_id = 9,
                        shelf_type = "magic",
                    },
                }
            end,
            updateShelfMappingLocalPath = function(_, book_id, _shelf_id, _shelf_type, local_path)
                updated_paths[book_id] = local_path
                return true
            end,
            getShelfSyncEntryByLocalPath = function()
                return nil
            end,
            saveBookCache = function()
                return true
            end,
        }, {})

        mock_attrs["/shared"] = { mode = "directory" }
        mock_attrs["/magic"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader/settings"] = { mode = "directory" }
        mock_attrs["/magic/Gamma.epub"] = { mode = "file", size = 3456 }

        local summary = sync:moveMagicShelfFilesBackToSharedDirectory("/shared", {
            magic_dir = "/magic",
            download_dir = "/shared",
        })

        assert.are.equal(1, summary.moved)
        assert.are.equal(0, summary.failed)
        assert.are.equal("/shared/Gamma.epub", updated_paths[303])
        assert.is_nil(mock_attrs["/magic/Gamma.epub"])
        assert.is_not_nil(mock_attrs["/shared/Gamma.epub"])
    end)

    it("prefers the source-folder mapping when moving duplicate magic mappings back", function()
        local updated_paths = {}
        local sync = ShelfSync:new({
            getMagicOnlyShelfMappings = function()
                return {
                    {
                        book_id = 404,
                        shelf_id = 11,
                        shelf_type = "magic",
                        local_path = "/shared/Delta.epub",
                        downloaded_by_grimmlink = 1,
                    },
                    {
                        book_id = 404,
                        shelf_id = 12,
                        shelf_type = "magic",
                        local_path = "/magic/Delta.epub",
                        downloaded_by_grimmlink = 1,
                        remote_title = "Delta",
                        remote_author = "Author D",
                    },
                }
            end,
            isBookTrackedByRegularShelf = function()
                return false
            end,
            getShelfMappingsForBook = function(_, book_id)
                return {
                    {
                        book_id = book_id,
                        shelf_id = 11,
                        shelf_type = "magic",
                    },
                    {
                        book_id = book_id,
                        shelf_id = 12,
                        shelf_type = "magic",
                    },
                }
            end,
            updateShelfMappingLocalPath = function(_, book_id, shelf_id, _shelf_type, local_path)
                updated_paths[shelf_id] = {
                    book_id = book_id,
                    local_path = local_path,
                }
                return true
            end,
            getShelfSyncEntryByLocalPath = function()
                return nil
            end,
            saveBookCache = function()
                return true
            end,
        }, {})

        mock_attrs["/shared"] = { mode = "directory" }
        mock_attrs["/magic"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader"] = { mode = "directory" }
        mock_attrs["/storage/emulated/0/koreader/settings"] = { mode = "directory" }
        mock_attrs["/magic/Delta.epub"] = { mode = "file", size = 4567 }

        local summary = sync:moveMagicShelfFilesBackToSharedDirectory("/shared", {
            magic_dir = "/magic",
            download_dir = "/shared",
        })

        assert.are.equal(1, summary.moved)
        assert.are.equal(0, summary.failed)
        assert.are.equal("/shared/Delta.epub", updated_paths[11].local_path)
        assert.are.equal("/shared/Delta.epub", updated_paths[12].local_path)
        assert.is_nil(mock_attrs["/magic/Delta.epub"])
        assert.is_not_nil(mock_attrs["/shared/Delta.epub"])
    end)

    it("uses snapshot fast-path for unchanged large shelves (100/500/1000)", function()
        mock_attrs["/storage/emulated/0/koreader/books/Book"] = { mode = "directory" }

        for _, size in ipairs({ 100, 500, 1000 }) do
            local remote_books = {}
            local shelf_entries = {}
            for i = 1, size do
                remote_books[#remote_books + 1] = {
                    bookId = i,
                    title = "Book " .. tostring(i),
                    author = "Author",
                    fileName = "Book_" .. tostring(i) .. ".epub",
                    fileFormat = "EPUB",
                    fileSizeKb = 256,
                }
                local path = "/storage/emulated/0/koreader/books/Book/Book_" .. tostring(i) .. ".epub"
                mock_attrs[path] = { mode = "file", size = 256 * 1024 }
                shelf_entries[#shelf_entries + 1] = {
                    book_id = i,
                    shelf_id = 12,
                    shelf_type = "regular",
                    local_path = path,
                    downloaded_by_grimmlink = 1,
                }
            end

            local sync = ShelfSync:new({
                getShelfMappingsByShelf = function()
                    return shelf_entries
                end,
                getAllShelfSyncEntries = function()
                    return shelf_entries
                end,
                upsertShelfSyncEntry = function()
                    return true
                end,
            }, {
                getShelfBooks = function()
                    return true, remote_books
                end,
            })

            local plan_first = sync:prepareSyncPlan({
                shelf_id = 12,
                shelf_type = "regular",
                download_dir = "/storage/emulated/0/koreader/books/Book",
                remote_delete_sync = true,
                delete_sdr = false,
            })
            assert.is_not_nil(plan_first.result.snapshot_token)

            local plan_second = sync:prepareSyncPlan({
                shelf_id = 12,
                shelf_type = "regular",
                download_dir = "/storage/emulated/0/koreader/books/Book",
                remote_delete_sync = true,
                delete_sdr = false,
                previous_snapshot_token = plan_first.result.snapshot_token,
                preloaded_remote_books = remote_books,
            })

            assert.is_true(plan_second.result.snapshot_unchanged == true)
            assert.are.equal(size, plan_second.result.skipped)
            assert.are.equal(0, #plan_second.download_queue)
            assert.is_true(plan_second.cleanup.remote_delete_sync == false)
        end
    end)

    it("does not skip cleanup on unchanged snapshot when stale shelf mappings still exist", function()
        local remote_books = {
            { bookId = 1, title = "Only Book", fileName = "Only Book.epub", fileFormat = "EPUB", fileSizeKb = 12 },
        }
        local sync = ShelfSync:new({
            getShelfMappingsByShelf = function()
                return {
                    {
                        book_id = 1,
                        shelf_id = 12,
                        shelf_type = "regular",
                        local_path = test_file,
                        downloaded_at = os.time(),
                        last_seen_in_shelf_at = os.time(),
                        downloaded_by_grimmlink = 1,
                    },
                    {
                        book_id = 99,
                        shelf_id = 12,
                        shelf_type = "regular",
                        local_path = "/tmp/Stale Book.epub",
                        downloaded_at = os.time(),
                        last_seen_in_shelf_at = os.time() - 100,
                        downloaded_by_grimmlink = 1,
                    },
                }
            end,
            getAllShelfSyncEntries = function()
                return {}
            end,
            upsertShelfSyncEntry = function()
                return true
            end,
        }, {
            getShelfBooks = function()
                return true, remote_books
            end,
        })

        local plan_first = sync:prepareSyncPlan({
            shelf_id = 12,
            shelf_type = "regular",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            remote_delete_sync = true,
            delete_sdr = false,
        })
        assert.is_not_nil(plan_first.result.snapshot_token)

        local plan_second = sync:prepareSyncPlan({
            shelf_id = 12,
            shelf_type = "regular",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            remote_delete_sync = true,
            delete_sdr = false,
            previous_snapshot_token = plan_first.result.snapshot_token,
            preloaded_remote_books = remote_books,
        })

        assert.is_nil(plan_second.result.snapshot_unchanged)
        assert.is_true(plan_second.cleanup.remote_delete_sync == true)
    end)

    it("does not skip cleanup on unchanged empty snapshot when orphan shelf mappings exist", function()
        local sync = ShelfSync:new({
            getShelfMappingsByShelf = function()
                return {}
            end,
            getAllShelfSyncEntries = function()
                return {
                    {
                        book_id = 1,
                        shelf_id = 2,
                        shelf_type = "magic",
                        local_path = "/storage/emulated/0/koreader/Book/orphan.epub",
                        downloaded_by_grimmlink = 1,
                        last_seen_in_shelf_at = 100,
                    },
                }
            end,
            upsertShelfSyncEntry = function()
                return true
            end,
        }, {
            getShelfBooks = function()
                return true, {}
            end,
        })

        local plan = sync:prepareSyncPlan({
            shelf_id = 1,
            shelf_type = "magic",
            download_dir = "/storage/emulated/0/koreader/Book/Magic_Shelf",
            remote_delete_sync = true,
            delete_sdr = false,
            previous_snapshot_token = "0:1:0",
            preloaded_remote_books = {},
            selected_shelf_ids_by_type = {
                magic = { ["1"] = true },
            },
        })

        assert.is_nil(plan.result.snapshot_unchanged)
        assert.is_true(plan.cleanup.remote_delete_sync == true)
    end)

    it("supports planning cancellation and returns cancelled result", function()
        local sync = ShelfSync:new({
            getShelfMappingsByShelf = function()
                return {}
            end,
            getAllShelfSyncEntries = function()
                return {}
            end,
        }, {
            getShelfBooks = function()
                return true, {
                    { bookId = 1, title = "A", fileName = "A.epub", fileFormat = "EPUB", fileSizeKb = 1 },
                }
            end,
        })

        local plan = sync:prepareSyncPlan({
            shelf_id = 1,
            shelf_type = "regular",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            is_cancelled = function()
                return true
            end,
        })

        assert.is_true(plan.result.cancelled == true)
        assert.is_true(#plan.result.errors > 0)
    end)

    it("supports batched planning continuation for large shelves", function()
        local sync = ShelfSync:new({
            getShelfMappingsByShelf = function()
                return {}
            end,
            getAllShelfSyncEntries = function()
                return {}
            end,
        }, {
            getShelfBooks = function()
                return true, {
                    { bookId = 1, title = "A", fileName = "A.epub", fileFormat = "EPUB", fileSizeKb = 1 },
                    { bookId = 2, title = "B", fileName = "B.epub", fileFormat = "EPUB", fileSizeKb = 1 },
                    { bookId = 3, title = "C", fileName = "C.epub", fileFormat = "EPUB", fileSizeKb = 1 },
                }
            end,
        })

        local plan1 = sync:prepareSyncPlan({
            shelf_id = 11,
            shelf_type = "regular",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            plan_batch_size = 1,
        })
        assert.is_truthy(plan1.plan_state)
        assert.is_true((plan1.result.planning_done or 0) >= 1)

        local plan2 = sync:prepareSyncPlan({
            plan_state = plan1.plan_state,
            plan_batch_size = 1,
        })
        assert.is_truthy(plan2.plan_state)
        assert.is_true((plan2.result.planning_done or 0) >= 2)

        local plan3 = sync:prepareSyncPlan({
            plan_state = plan2.plan_state,
            plan_batch_size = 1,
        })
        assert.is_nil(plan3.plan_state)
        assert.are.equal(3, #plan3.download_queue)
    end)

    it("processes pending removals before planning downloads", function()
        local called = false
        local sync = ShelfSync:new({
            getShelfMappingsByShelf = function()
                return {}
            end,
            getAllShelfSyncEntries = function()
                return {}
            end,
            getPendingShelfRemovals = function()
                return {}
            end,
        }, {
            getShelfBooks = function()
                return true, {}
            end,
        })

        sync.processPendingShelfRemovals = function(_, _shelf_id, _shelf_type, _download_dir, _delete_sdr, _skip_ids, result)
            called = true
            result.deleted = result.deleted + 1
        end

        local plan = sync:prepareSyncPlan({
            shelf_id = 2,
            shelf_type = "regular",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            remote_delete_sync = true,
        })

        assert.is_true(called)
        assert.are.equal(1, plan.result.deleted)
    end)

    it("uses pending-removal callback from options when provided", function()
        local callback_called = false
        local method_called = false
        local sync = ShelfSync:new({
            getShelfMappingsByShelf = function()
                return {}
            end,
            getAllShelfSyncEntries = function()
                return {}
            end,
            getPendingShelfRemovals = function()
                return {}
            end,
        }, {
            getShelfBooks = function()
                return true, {}
            end,
        })

        sync.processPendingShelfRemovals = function()
            method_called = true
        end

        local plan = sync:prepareSyncPlan({
            shelf_id = 2,
            shelf_type = "regular",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            remote_delete_sync = true,
            process_pending_shelf_removals = function(payload)
                callback_called = true
                payload.result.deleted = payload.result.deleted + 2
            end,
        })

        assert.is_true(callback_called)
        assert.is_false(method_called)
        assert.are.equal(2, plan.result.deleted)
    end)

    it("falls back to shelf method when pending-removal callback fails", function()
        local method_called = false
        local sync = ShelfSync:new({
            getShelfMappingsByShelf = function()
                return {}
            end,
            getAllShelfSyncEntries = function()
                return {}
            end,
            getPendingShelfRemovals = function()
                return {}
            end,
        }, {
            getShelfBooks = function()
                return true, {}
            end,
        })

        sync.processPendingShelfRemovals = function(_, _shelf_id, _shelf_type, _download_dir, _delete_sdr, _skip_ids, result)
            method_called = true
            result.deleted = result.deleted + 1
        end

        local plan = sync:prepareSyncPlan({
            shelf_id = 2,
            shelf_type = "regular",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            remote_delete_sync = true,
            process_pending_shelf_removals = function()
                error("callback failure")
            end,
        })

        assert.is_true(method_called)
        assert.are.equal(1, plan.result.deleted)
    end)

    it("deletes local file on cleanup only when still tracked by this shelf", function()
        local delete_called = false
        local sync = ShelfSync:new({
            getAllShelfSyncEntries = function()
                return {
                    {
                        book_id = 501,
                        shelf_id = 3,
                        shelf_type = "regular",
                        local_path = "/storage/emulated/0/koreader/books/Book/remove.epub",
                        downloaded_by_grimmlink = 1,
                        last_seen_in_shelf_at = 100,
                    },
                }
            end,
            isBookTrackedInOtherShelf = function()
                return false
            end,
        }, {})
        sync.deleteLocalBook = function()
            delete_called = true
            return true
        end
        sync.removeBookMetadata = function() end

        local result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
        sync:runCleanupPhase({
            shelf_id = 3,
            shelf_type = "regular",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            delete_sdr = false,
            remote_delete_sync = true,
            sync_start = 200,
        }, result, function() end)

        assert.is_true(delete_called)
        assert.are.equal(1, result.deleted)
    end)

    it("keeps local file when another shelf still tracks the book", function()
        local delete_called = false
        local mapping_removed = false
        local sync = ShelfSync:new({
            getAllShelfSyncEntries = function()
                return {
                    {
                        book_id = 777,
                        shelf_id = 4,
                        shelf_type = "magic",
                        local_path = "/storage/emulated/0/koreader/books/Book/shared.epub",
                        downloaded_by_grimmlink = 1,
                        last_seen_in_shelf_at = 100,
                    },
                }
            end,
            isBookTrackedInOtherShelf = function()
                return true
            end,
            removeShelfMappingOnly = function()
                mapping_removed = true
                return true
            end,
        }, {})
        sync.deleteLocalBook = function()
            delete_called = true
            return true
        end

        local result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
        sync:runCleanupPhase({
            shelf_id = 4,
            shelf_type = "magic",
            download_dir = "/storage/emulated/0/koreader/books/Book",
            delete_sdr = false,
            remote_delete_sync = true,
            sync_start = 200,
        }, result, function() end)

        assert.is_false(delete_called)
        assert.is_true(mapping_removed)
        assert.are.equal(0, result.deleted)
    end)

    it("cleans orphaned shelf mappings outside the active selected shelf ids", function()
        local deleted = {}
        local removed_mappings = {}
        local sync = ShelfSync:new({
            getAllShelfSyncEntries = function(_, shelf_id, shelf_type)
                if shelf_id ~= nil then
                    return {}
                end
                return {
                    {
                        book_id = 222,
                        shelf_id = 2,
                        shelf_type = "magic",
                        local_path = "/storage/emulated/0/koreader/Book/orphan-only.epub",
                        downloaded_by_grimmlink = 1,
                        last_seen_in_shelf_at = 100,
                    },
                    {
                        book_id = 333,
                        shelf_id = 2,
                        shelf_type = "magic",
                        local_path = "/storage/emulated/0/koreader/Book/still-regular.epub",
                        downloaded_by_grimmlink = 1,
                        last_seen_in_shelf_at = 100,
                    },
                    {
                        book_id = 333,
                        shelf_id = 7,
                        shelf_type = "regular",
                        local_path = "/storage/emulated/0/koreader/Book/still-regular.epub",
                        downloaded_by_grimmlink = 1,
                        last_seen_in_shelf_at = 900,
                    },
                }
            end,
            isBookTrackedInOtherShelf = function(_, book_id)
                return tonumber(book_id) == 333
            end,
            removeShelfMappingOnly = function(_, book_id, shelf_id, shelf_type)
                removed_mappings[#removed_mappings + 1] = {
                    book_id = book_id,
                    shelf_id = shelf_id,
                    shelf_type = shelf_type,
                }
                return true
            end,
        }, {})
        sync.deleteLocalBook = function(_, entry)
            deleted[#deleted + 1] = entry.book_id
            return true
        end
        sync.removeBookMetadata = function() end

        local result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
        sync:runCleanupPhase({
            shelf_id = 1,
            shelf_type = "magic",
            download_dir = "/storage/emulated/0/koreader/Book/Magic_Shelf",
            delete_sdr = false,
            remote_delete_sync = true,
            sync_start = 1000,
            selected_shelf_ids_by_type = {
                magic = { ["1"] = true },
                regular = { ["7"] = true },
            },
        }, result, function() end)

        assert.are.same({ 222 }, deleted)
        assert.are.equal(1, #removed_mappings)
        assert.are.equal(333, removed_mappings[1].book_id)
        assert.are.equal(2, removed_mappings[1].shelf_id)
        assert.are.equal("magic", removed_mappings[1].shelf_type)
        assert.are.equal(1, result.deleted)
        assert.are.equal(0, result.failed)
    end)

    it("retries pending removals when remote delete fails", function()
        local retried = false
        local sync = ShelfSync:new({
            getPendingShelfRemovals = function()
                return {
                    {
                        book_id = 88,
                        shelf_id = 9,
                        shelf_type = "regular",
                        local_path = "/storage/emulated/0/koreader/books/Book/fail.epub",
                    },
                }
            end,
            incrementPendingShelfRemovalRetryCount = function()
                retried = true
                return true
            end,
        }, {
            removeBookFromShelf = function()
                return false, "connection failed"
            end,
        })

        local result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }
        sync:processPendingShelfRemovals(9, "regular", "/storage/emulated/0/koreader/books/Book", false, {}, result, function() end)

        assert.is_true(retried)
        assert.are.equal(1, result.failed)
        assert.is_true(#result.errors > 0)
    end)

    it("delegates pending removals to pending_sync module when attached", function()
        local delegated = false
        local sync = ShelfSync:new({}, {})
        sync.pending_sync = {
            processPendingShelfRemovals = function(_, plugin_arg, payload)
                delegated = true
                assert.is_truthy(plugin_arg)
                payload.result.deleted = payload.result.deleted + 1
                return true
            end,
        }
        sync.plugin = { db = {}, api = {} }
        sync.pending_shelf_removal_retry_cooldown_seconds = 33

        local result = { deleted = 0, failed = 0, errors = {} }
        sync:processPendingShelfRemovals(1, "regular", "/storage/emulated/0/koreader/books/Book", false, {}, result, function() end)

        assert.is_true(delegated)
        assert.are.equal(1, result.deleted)
    end)

    it("uses deletion module policy when available", function()
        local db_deleted = false
        local sync = ShelfSync:new({
            deleteShelfSyncEntry = function()
                db_deleted = true
                return true
            end,
        }, {})
        sync.deletion = {
            evaluateLocalDeletePolicy = function()
                return false, "outside_managed_roots"
            end,
        }

        local ok, reason = sync:deleteLocalBook({
            book_id = 90,
            shelf_id = 1,
            shelf_type = "regular",
            downloaded_by_grimmlink = 1,
            local_path = "/etc/unsafe.epub",
        }, false, "/storage/emulated/0/koreader/books/Book")

        assert.is_false(ok)
        assert.are.equal("outside_managed_roots", reason)
        assert.is_false(db_deleted)
    end)

    it("processes cleanup in batches with runCleanupPhaseBatch", function()
        local removed = {}
        local sync = ShelfSync:new({
            getAllShelfSyncEntries = function()
                return {
                    {
                        book_id = 201,
                        shelf_id = 3,
                        shelf_type = "regular",
                        downloaded_by_grimmlink = 0,
                        last_seen_in_shelf_at = 1,
                    },
                    {
                        book_id = 202,
                        shelf_id = 3,
                        shelf_type = "regular",
                        downloaded_by_grimmlink = 0,
                        last_seen_in_shelf_at = 1,
                    },
                }
            end,
            removeShelfMappingOnly = function(_, book_id)
                removed[#removed + 1] = book_id
                return true
            end,
        }, {})

        local cleanup = {
            shelf_id = 3,
            shelf_type = "regular",
            remote_delete_sync = true,
            sync_start = 10,
            delete_sdr = false,
            download_dir = "/storage/emulated/0/koreader/books/Book",
        }
        local result = { deleted = 0, failed = 0, errors = {} }
        local state, done = sync:runCleanupPhaseBatch(cleanup, result, nil, 1, function() end)
        assert.is_false(done)
        assert.are.equal(1, #removed)

        state, done = sync:runCleanupPhaseBatch(cleanup, result, state, 1, function() end)
        assert.is_true(done)
        assert.are.equal(2, #removed)
    end)
end)

