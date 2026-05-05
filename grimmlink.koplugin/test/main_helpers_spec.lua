local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

package.loaded["main"] = nil
package.loaded["grimmlink_updater"] = nil
package.loaded["grimmlink_database"] = nil
package.loaded["grimmlink_shelf_sync"] = nil
package.loaded["datastorage"] = nil
package.loaded["json"] = nil
package.loaded["logger"] = nil
local Grimmlink = require("main")
local UIManager = require("ui/uimanager")
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

describe("GrimmLink helper methods", function()
    local plugin

    before_each(function()
        if UIManager.reset then
            UIManager:reset()
        end
        plugin = setmetatable({
            threshold_percent = 1.0,
            threshold_pages = 5,
            web_reader_bridge_enabled = false,
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

    it("keeps Web Reader sync disabled until the bridge is enabled", function()
        plugin.enabled = true
        plugin.web_reader_bridge_enabled = false
        assert.is_false(plugin:isWebReaderSyncEnabled())

        plugin.web_reader_bridge_enabled = true
        assert.is_true(plugin:isWebReaderSyncEnabled())
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

    it("prefers remote on first open when there is no prior sync state", function()
        local decision = plugin:compareOpenProgress(
            { percentage = 5.4, currentPage = 36, location = "36", timestamp = 500 },
            { percentage = 8.4, currentPage = 56, location = "56", timestamp = 490 },
            nil
        )

        assert.are.equal("remote_newer", decision)
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

    it("prefers page-based jumps for paged documents like PDFs", function()
        local jumped_page
        plugin.ui = {
            document = {
                info = {
                    has_pages = true,
                },
            },
        }
        plugin.jumpToPage = function(_, page)
            jumped_page = page
            return true
        end
        plugin.jumpToLocation = function()
            error("paged documents should not try xpointer-style jumps first")
        end

        local ok = plugin:applyRemoteProgress({
            currentPage = 40,
            progress = "40",
            location = "/body/DocFragment[7]",
        })

        assert.is_true(ok)
        assert.are.equal(40, jumped_page)
    end)

    it("keeps xpointer jumps for rolling documents", function()
        local jumped_location
        plugin.ui = {
            document = {
                info = {
                    has_pages = false,
                },
            },
        }
        plugin.jumpToPage = function()
            error("rolling documents should not prefer page jumps")
        end
        plugin.jumpToLocation = function(_, location)
            jumped_location = location
            return true
        end

        local ok = plugin:applyRemoteProgress({
            currentPage = 40,
            location = "/body/DocFragment[7]",
        })

        assert.is_true(ok)
        assert.are.equal("/body/DocFragment[7]", jumped_location)
    end)

    it("falls back to zero-based page navigation when direct page jumps fail", function()
        local current_page = 18
        plugin.ui = {
            paging = {
                gotoPage = function(_, page)
                    if page == 39 then
                        current_page = 40
                        return true
                    end
                    return false
                end,
            },
        }
        plugin.getCurrentPageInfo = function()
            return current_page, 663
        end
        plugin.logDbg = function() end
        plugin.logWarn = function() end

        local ok = plugin:jumpToPage(40)

        assert.is_true(ok)
    end)

    it("prefers KOReader GotoPage events when the reader UI exposes them", function()
        local current_page = 18
        plugin.ui = {
            document = {
                file = "/books/title.epub",
            },
            link = {
                addCurrentLocationToStack = function() end,
            },
            handleEvent = function(_, event)
                if event and event.handler == "onGotoPage" and event.args then
                    current_page = tonumber(event.args[1]) or 40
                    return true
                end
                return false
            end,
        }
        plugin.getCurrentPageInfo = function()
            return current_page, 663
        end
        plugin.logDbg = function() end
        plugin.logWarn = function() end

        local ok = plugin:jumpToPage(40)

        assert.is_true(ok)
    end)

    it("does not report success when a page jump method returns true without moving", function()
        local current_page = 18
        plugin.ui = {
            paging = {
                gotoPage = function()
                    return true
                end,
            },
        }
        plugin.getCurrentPageInfo = function()
            return current_page, 663
        end
        plugin.logDbg = function() end
        plugin.logWarn = function() end

        local ok = plugin:jumpToPage(40)

        assert.is_false(ok)
    end)

    it("verifies the page after a remote jump before reporting success", function()
        local current_page = 18
        local messages = {}
        plugin.ui = {
            document = {
                file = "/books/title.epub",
            },
        }
        plugin.getCurrentPageInfo = function()
            return current_page, 663
        end
        plugin.getCurrentProgressSnapshot = function(_, file_hash, file_path, book_id)
            return {
                bookHash = file_hash,
                bookId = book_id,
                file_path = file_path,
                currentPage = current_page,
                totalPages = 663,
                percentage = 100 * current_page / 663,
                progress = tostring(current_page),
                location = tostring(current_page),
            }
        end
        plugin.rememberLocalSnapshot = function(_, _, snapshot)
            assert.are.equal(40, snapshot.currentPage)
        end
        plugin.rememberRemoteSnapshot = function()
            error("should not mark the remote jump as unsafe when the page really changed")
        end
        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end
        plugin.requestReaderRefresh = function() end
        plugin.applyRemoteProgress = function()
            current_page = 40
            return true
        end

        plugin:resolveRemoteChoice("hash-1", {
            bookHash = "hash-1",
            bookId = 42,
            currentPage = 40,
            totalPages = 663,
            percentage = 6.0,
            progress = "40",
            location = "40",
        })

        assert.are.same({ "Jumped to remote progress" }, messages)
    end)

    it("waits for the UI to settle before reporting a remote jump success", function()
        local current_page = 18
        local messages = {}
        local scheduled = {}
        local original_schedule_in = UIManager.scheduleIn

        UIManager.scheduleIn = function(_, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end

        plugin.ui = {
            document = {
                file = "/books/title.epub",
            },
        }
        plugin.getCurrentPageInfo = function()
            return current_page, 663
        end
        plugin.getCurrentProgressSnapshot = function(_, file_hash, file_path, book_id)
            return {
                bookHash = file_hash,
                bookId = book_id,
                file_path = file_path,
                currentPage = current_page,
                totalPages = 663,
                percentage = 100 * current_page / 663,
                progress = tostring(current_page),
                location = tostring(current_page),
            }
        end
        plugin.rememberLocalSnapshot = function(_, _, snapshot)
            assert.are.equal(40, snapshot.currentPage)
        end
        plugin.rememberRemoteSnapshot = function()
            error("should not mark the remote jump as unsafe when the page really changed")
        end
        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end
        plugin.requestReaderRefresh = function() end
        plugin.applyRemoteProgress = function()
            current_page = 40
            return true
        end

        plugin:resolveRemoteChoice("hash-1", {
            bookHash = "hash-1",
            bookId = 42,
            currentPage = 40,
            totalPages = 663,
            percentage = 6.0,
            progress = "40",
            location = "40",
        })

        assert.are.equal(1, #scheduled)
        assert.are.same({}, messages)

        scheduled[1]()

        assert.are.equal(2, #scheduled)
        assert.are.same({}, messages)

        scheduled[2]()

        UIManager.scheduleIn = original_schedule_in
        assert.are.same({ "Jumped to remote progress" }, messages)
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

    it("registers the main menu after initialization is complete", function()
        local menu_items = {}
        plugin.ui = {
            menu = {
                registerToMainMenu = function(_, plugin_instance)
                    plugin_instance:addToMainMenu(menu_items)
                end,
            },
        }

        local ok, err = pcall(function()
            plugin:init()
        end)

        assert.is_true(ok, err)
        assert.is_true(plugin._initialized)
        assert.are.equal("GrimmLink", menu_items.grimmlink.text)
        assert.are.equal("Enable Sync", menu_items.grimmlink.sub_item_table[1].text)
    end)

    it("keeps the main menu available before init completes", function()
        local menu_items = {}

        plugin._initialized = false
        plugin.db = nil
        plugin:addToMainMenu(menu_items)

        assert.are.equal("GrimmLink", menu_items.grimmlink.text)
        assert.are.equal("Enable Sync", menu_items.grimmlink.sub_item_table[1].text)
        assert.is_false(plugin:saveSetting("enabled", false))

        local annotation_sync = findMenuItem(menu_items.grimmlink.sub_item_table, "Annotation Sync")
        local pending_sync = findMenuItem(menu_items.grimmlink.sub_item_table, "Sync Pending Now")

        local ok_annotations, text_annotations = pcall(annotation_sync.sub_item_table[7].text_func)
        local ok_pending, text_pending = pcall(pending_sync.text_func)

        assert.is_true(ok_annotations)
        assert.is_true(ok_pending)
        assert.is_not_nil(text_annotations)
        assert.is_not_nil(text_pending)

        local ok_enable = pcall(menu_items.grimmlink.sub_item_table[1].callback)
        local ok_sync_pending = pcall(pending_sync.callback)

        assert.is_true(ok_enable)
        assert.is_true(ok_sync_pending)
    end)

    it("guards menu callbacks from bubbling errors", function()
        local menu_items = {}
        plugin._initialized = true
        plugin.db = {
            savePluginSetting = function()
                error("boom")
            end,
        }
        plugin.api = {
            init = function() end,
        }
        plugin.enabled = true

        plugin:addToMainMenu(menu_items)

        local ok = pcall(menu_items.grimmlink.sub_item_table[1].callback)
        assert.is_true(ok)
    end)

    it("does not open a second conflict dialog while one is already visible", function()
        plugin._initialized = true
        plugin.logInfo = function() end

        plugin:showProgressConflictDialog(
            "hash-1",
            { percentage = 2.7, currentPage = 18, totalPages = 663, timestamp = 100 },
            { percentage = 6.0, currentPage = 40, totalPages = 663, timestamp = 200, device = "device-a" },
            "conflict"
        )

        local first_dialog = UIManager.getLastShown and UIManager:getLastShown() or nil
        assert.is_not_nil(first_dialog)

        plugin:showWebBridgeConflictDialog(
            "hash-1",
            { percentage = 2.7, currentPage = 18, totalPages = 663, timestamp = 100 },
            { percentage = 6.0, currentPage = 40, totalPages = 663, timestamp = 200, source = "WEB_READER" },
            "conflict"
        )

        local second_dialog = UIManager.getLastShown and UIManager:getLastShown() or nil
        assert.are.equal(first_dialog, second_dialog)
    end)

    it("updates the runtime password immediately when settings change", function()
        local init_calls = {}
        plugin._initialized = true
        plugin.db = {
            savePluginSetting = function()
                return true
            end,
        }
        plugin.api = {
            init = function(_, server_url, username, auth_key, debug_logging)
                init_calls[#init_calls + 1] = {
                    server_url = server_url,
                    username = username,
                    auth_key = auth_key,
                    debug_logging = debug_logging,
                }
            end,
        }
        plugin.server_url = "http://example.com"
        plugin.username = "reader"
        plugin.auth_key = "old-password"
        plugin.debug_logging = false

        local ok = plugin:saveSetting("password", "new-password")

        assert.is_true(ok)
        assert.are.equal("new-password", plugin.auth_key)
        assert.are.equal("new-password", init_calls[#init_calls].auth_key)
    end)

    it("collects URL, username, and password in one connection setup flow", function()
        local prompts = {}
        local saved = nil

        plugin.server_url = "http://old.example"
        plugin.username = "old-user"
        plugin.auth_key = "old-password"
        plugin.showTextInput = function(_, title, current_value, _hint, secret, on_save)
            prompts[#prompts + 1] = {
                title = title,
                current_value = current_value,
                secret = secret == true,
            }

            if title == "Grimmory Server URL" then
                on_save("http://new.example/")
            elseif title == "KOReader Username" then
                on_save("reader")
            elseif title == "Password" then
                on_save("secret-password")
            else
                error("unexpected prompt: " .. tostring(title))
            end
        end
        plugin.saveConnectionSettings = function(_, server_url, username, password)
            saved = {
                server_url = server_url,
                username = username,
                password = password,
            }
        end

        plugin:configureConnection()

        assert.are.same({
            { title = "Grimmory Server URL", current_value = "http://old.example", secret = false },
            { title = "KOReader Username", current_value = "old-user", secret = false },
            { title = "Password", current_value = "old-password", secret = true },
        }, prompts)
        assert.are.same({
            server_url = "http://new.example/",
            username = "reader",
            password = "secret-password",
        }, saved)
    end)

    it("prompts to test the connection after saving connection settings", function()
        local saved = {}
        local tested = 0

        plugin.db = {
            savePluginSetting = function(_, key, value)
                saved[key] = value
                return true
            end,
        }
        plugin._initialized = true
        plugin.api = {
            init = function() end,
            testAuth = function()
                tested = tested + 1
                return true, {}
            end,
        }
        plugin.server_url = ""
        plugin.username = ""
        plugin.auth_key = ""
        plugin.showMessage = function() end
        plugin.logInfo = function() end

        local ok_save, err_save = pcall(function()
            plugin:saveConnectionSettings("http://new.example/", "reader", "secret-password")
        end)
        assert.is_true(ok_save, err_save)

        assert.are.equal("http://new.example", saved.server_url)
        assert.are.equal("reader", saved.username)
        assert.are.equal("secret-password", saved.password)

        local dialog = UIManager.getLastShown and UIManager:getLastShown() or nil
        assert.is_not_nil(dialog)
        assert.is_true(dialog.text:find("Test connection now", 1, true) ~= nil)
        assert.is_not_nil(dialog.ok_callback)

        local ok_test, err_test = pcall(function()
            dialog.ok_callback()
        end)
        assert.is_true(ok_test, err_test)
        assert.are.equal(1, tested)
    end)

    it("enables file logging automatically when debug logging is turned on", function()
        local saved = {}
        local messages = {}

        plugin._initialized = true
        plugin.log_to_file = false
        plugin.file_logger = nil
        plugin.db = {
            savePluginSetting = function(_, key, value)
                saved[key] = value
                return true
            end,
        }
        plugin.api = {
            init = function() end,
        }
        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end

        local ok = plugin:saveSetting("debug_logging", true)

        assert.is_true(ok)
        assert.is_true(plugin.debug_logging)
        assert.is_true(plugin.log_to_file)
        assert.are.equal(true, saved.debug_logging)
        assert.are.equal(true, saved.log_to_file)
        assert.is_true(type(messages[#messages]) == "string" and messages[#messages]:find("grimmlink.log", 1, true) ~= nil)
    end)

    it("shows recent log lines from the GrimmLink log file", function()
        local original_io_open = io.open
        local messages = {}

        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end

        io.open = function(path, mode)
            if path == "/tmp/grimmlink.log" and mode == "r" then
                return {
                    read = function()
                        return table.concat({
                            "[2026-05-02T10:00:00Z] [INFO] start",
                            "[2026-05-02T10:00:01Z] [WARN] warn",
                            "[2026-05-02T10:00:02Z] [ERR] boom",
                        }, "\n")
                    end,
                    close = function()
                        return true
                    end,
                }
            end
            return original_io_open(path, mode)
        end

        local ok, err = pcall(function()
            plugin:showRecentLogLines()
        end)
        io.open = original_io_open

      assert.is_true(ok, err)
      assert.is_true(type(messages[#messages]) == "string" and messages[#messages]:find("Recent GrimmLink log lines", 1, true) ~= nil)
      assert.is_true(messages[#messages]:find("%[ERR%] boom") ~= nil)
  end)

  it("shows detailed cache stats with stale and not found entries", function()
      local messages = {}

      plugin._initialized = true
      plugin.db = {
          getBookCacheStats = function()
              return { total = 10, matched = 6, unmatched = 4 }
          end,
          getShelfSyncStats = function()
              return { total = 3 }
          end,
          getPendingProgressCount = function()
              return 2
          end,
          getPendingSessionCount = function()
              return 1
          end,
          getPendingAnnotationCount = function()
              return 4
          end,
          getNotFoundHashCount = function()
              return 5
          end,
          getStaleCacheCount = function()
              return 2
          end,
          getNotFoundHashes = function()
              return {
                  { file_hash = "hash-a", book_id = 7, file_format = "EPUB", source = "koreader", reason = "404" },
              }
          end,
          getStaleCacheEntries = function()
              return {
                  { table_name = "book_cache", id = 1, file_hash = "hash-b", file_path = "/missing/book.epub" },
              }
          end,
      }
      plugin.showMessage = function(_, text)
          messages[#messages + 1] = text
      end

      plugin:showDetailedCacheStats()

      assert.is_true(type(messages[#messages]) == "string")
      assert.is_true(messages[#messages]:find("Stale cache entries", 1, true) ~= nil)
      assert.is_true(messages[#messages]:find("Not found hashes", 1, true) ~= nil)
      assert.is_true(messages[#messages]:find("hash-a", 1, true) ~= nil)
  end)

  it("adds the status/debug menu group", function()
      local menu_items = {}

      plugin._initialized = true
      plugin.db = {
          getPendingProgressCount = function()
              return 0
          end,
          getPendingSessionCount = function()
              return 0
          end,
          getPendingAnnotationCount = function()
              return 0
          end,
      }

      plugin:addToMainMenu(menu_items)

      local status_debug_menu = findMenuItem(menu_items.grimmlink.sub_item_table, "Status / Debug")
      assert.is_not_nil(status_debug_menu)
      assert.is_not_nil(findMenuItem(status_debug_menu.sub_item_table, "Show Detailed Cache Stats"))
      assert.is_not_nil(findMenuItem(status_debug_menu.sub_item_table, "Clear Pending Progress"))
      assert.is_not_nil(findMenuItem(status_debug_menu.sub_item_table, "Export Debug Log"))
  end)

  it("records a not-found hash and clears queued progress for that hash", function()
      local deleted_hashes = {}
      local upsert_calls = 0

      plugin._initialized = true
      plugin.db = {
          upsertNotFoundHash = function(_, entry)
              upsert_calls = upsert_calls + 1
              assert.are.equal("hash-404", entry.file_hash)
              return true
          end,
          deletePendingProgressByHash = function(_, file_hash)
              deleted_hashes[#deleted_hashes + 1] = file_hash
              return true
          end,
      }

      assert.is_true(plugin:recordNotFoundHash({
          file_hash = "hash-404",
          file_path = "/books/missing.epub",
          source = "koreader",
          reason = "HTTP 404",
      }))
      assert.are.equal(1, upsert_calls)
      assert.are.same({ "hash-404" }, deleted_hashes)
      assert.is_true(plugin._not_found_hashes["hash-404"])
      assert.is_true(plugin._not_found_logged["hash-404"])
  end)

  it("skips queueing, pushing, and retrying hashes that are not found or still backing off", function()
      local deleted_ids = {}
      local update_calls = 0

      plugin._initialized = true
      plugin.offline_queue_enabled = true
      plugin.server_url = "http://example.com"
      plugin.username = "reader"
      plugin.auth_key = "secret"
      plugin.debug_logging = false
      plugin.isOnline = function()
          return true
      end
      plugin.db = {
          hasNotFoundHash = function(_, file_hash)
              return file_hash == "hash-404"
          end,
          upsertPendingProgress = function()
              error("not-found hashes should not be queued")
          end,
          getPendingProgress = function()
              return {
                  {
                      id = 1,
                      file_hash = "hash-404",
                      payload_json = '{"bookHash":"hash-404"}',
                      retry_count = 1,
                  },
                  {
                      id = 2,
                      file_hash = "hash-backoff",
                      payload_json = '{"bookHash":"hash-backoff"}',
                      retry_count = 2,
                      last_retry_at = os.time(),
                  },
                  {
                      id = 3,
                      file_hash = "hash-cap",
                      payload_json = '{"bookHash":"hash-cap"}',
                      retry_count = 20,
                  },
              }
          end,
          deletePendingProgress = function(_, id)
              deleted_ids[#deleted_ids + 1] = id
              return true
          end,
          incrementPendingProgressRetry = function()
              error("retry backoff / cap should avoid touching skipped rows")
          end,
      }
      plugin.api = {
          init = function() end,
          updateProgress = function()
              update_calls = update_calls + 1
              error("skipped rows should not be sent to the API")
          end,
      }

      assert.is_false(plugin:queueProgressSnapshot({
          bookHash = "hash-404",
          bookId = 7,
          fileFormat = "EPUB",
          progress = "12",
          location = "12",
          percentage = 12,
          currentPage = 12,
          totalPages = 100,
      }))
      assert.is_false(plugin:pushProgressSnapshot({
          bookHash = "hash-404",
          bookId = 7,
          fileFormat = "EPUB",
          progress = "12",
          location = "12",
          percentage = 12,
          currentPage = 12,
          totalPages = 100,
      }, "manual", true))

      local synced, failed = plugin:syncPendingProgress(true)

      assert.are.equal(0, synced)
      assert.are.equal(1, failed)
      assert.are.same({ 1 }, deleted_ids)
      assert.are.equal(0, update_calls)
  end)

  it("disables current-document sync actions when no matched local file exists", function()
      local menu_items = {}

      plugin._initialized = true
      plugin.db = {
          getPendingProgressCount = function()
              return 0
          end,
          getPendingSessionCount = function()
              return 0
          end,
          getPendingAnnotationCount = function()
              return 0
          end,
          getBookByFilePath = function()
              return nil
          end,
          getShelfSyncEntryByLocalPath = function()
              return nil
          end,
      }
      plugin.ui = {
          document = {
              file = "/books/missing.epub",
          },
      }

      plugin:addToMainMenu(menu_items)

      local progress_item = findMenuItem(menu_items.grimmlink.sub_item_table, "Sync Shared Reading Progress Now")
      local annotation_menu = findMenuItem(menu_items.grimmlink.sub_item_table, "Annotation Sync")
      local pull_item = findMenuItem(annotation_menu and annotation_menu.sub_item_table or {}, "Pull Remote Annotations Now")

      assert.is_not_nil(progress_item)
      assert.is_not_nil(pull_item)
      assert.is_false(progress_item.enabled_func())
      assert.is_false(pull_item.enabled_func())
  end)

      it("falls back to individual session uploads when batch sync fails", function()
          local deleted_ids = {}
          local init_calls = 0
          local batch_calls = 0
        local single_calls = 0

        plugin._initialized = true
        plugin.server_url = "http://example.com"
        plugin.username = "reader"
        plugin.auth_key = "secret"
        plugin.debug_logging = false
        plugin.requireReady = function()
            return true
        end
        plugin.isOnline = function()
            return true
        end
        plugin.logWarn = function() end
        plugin.db = {
            getPendingSessions = function()
                return {
                    {
                        id = 1,
                        bookId = 42,
                        bookHash = "hash-1",
                        bookType = "PDF",
                        device = "KOReader",
                        deviceId = "device-1",
                        startTime = "2026-05-01T10:00:00Z",
                        endTime = "2026-05-01T10:30:00Z",
                        durationSeconds = 1800,
                        startProgress = 10.0,
                        endProgress = 20.0,
                        progressDelta = 10.0,
                        startLocation = "10",
                        endLocation = "20",
                    },
                    {
                        id = 2,
                        bookId = 42,
                        bookHash = "hash-1",
                        bookType = "PDF",
                        device = "KOReader",
                        deviceId = "device-1",
                        startTime = "2026-05-01T11:00:00Z",
                        endTime = "2026-05-01T11:15:00Z",
                        durationSeconds = 900,
                        startProgress = 20.0,
                        endProgress = 28.0,
                        progressDelta = 8.0,
                        startLocation = "20",
                        endLocation = "28",
                    },
                }
            end,
            deletePendingSession = function(_, id)
                deleted_ids[#deleted_ids + 1] = id
                return true
            end,
            incrementSessionRetryCount = function()
                error("should not retry when single-session fallback succeeds")
            end,
        }
        plugin.api = {
            init = function()
                init_calls = init_calls + 1
            end,
            submitSessionBatch = function(_, ...)
                batch_calls = batch_calls + 1
                return false, "HTTP 404", 404
            end,
            submitSession = function(_, payload)
                single_calls = single_calls + 1
                return payload.bookId == 42
            end,
        }

        local synced, failed = plugin:syncPendingSessions(true)

        assert.are.equal(1, init_calls)
        assert.are.equal(1, batch_calls)
        assert.are.equal(2, single_calls)
        assert.are.equal(2, synced)
        assert.are.equal(0, failed)
        assert.are.same({ 1, 2 }, deleted_ids)
    end)

    it("resolves pending session book ids from progress state file paths", function()
        local deleted_ids = {}
        plugin._initialized = true
        plugin.server_url = "http://example.com"
        plugin.username = "reader"
        plugin.auth_key = "secret"
        plugin.debug_logging = false
        plugin.requireReady = function()
            return true
        end
        plugin.isOnline = function()
            return true
        end
        plugin.resolveBookByFilePath = function(_, file_path)
            if file_path == "/books/Book/title.pdf" then
                return { book_id = 66, file_path = file_path, file_hash = "hash-66" }
            end
            return nil
        end
        plugin.db = {
            getPendingSessions = function()
                return {
                    {
                        id = 10,
                        bookId = nil,
                        bookHash = "hash-66",
                        bookType = "PDF",
                        device = "KOReader",
                        deviceId = "device-1",
                        startTime = "2026-05-01T10:00:00Z",
                        endTime = "2026-05-01T10:15:00Z",
                        durationSeconds = 900,
                        startProgress = 10.0,
                        endProgress = 18.0,
                        progressDelta = 8.0,
                        startLocation = "10",
                        endLocation = "18",
                    },
                }
            end,
            getBookByHash = function()
                return nil
            end,
            getProgressState = function(_, file_hash)
                if file_hash == "hash-66" then
                    return { file_path = "/books/Book/title.pdf" }
                end
                return nil
            end,
            updateBookId = function() return true end,
            updatePendingSessionBookId = function(_, id, book_id)
                assert.are.equal(10, id)
                assert.are.equal(66, book_id)
                return true
            end,
            deletePendingSession = function(_, id)
                deleted_ids[#deleted_ids + 1] = id
                return true
            end,
            incrementSessionRetryCount = function()
                error("should not retry when progress-state path resolution succeeds")
            end,
        }
        plugin.api = {
            init = function() end,
            submitSession = function(_, payload)
                return payload.bookId == 66
            end,
        }

        local synced, failed = plugin:syncPendingSessions(true)

        assert.are.equal(1, synced)
        assert.are.equal(0, failed)
        assert.are.same({ 10 }, deleted_ids)
    end)

    it("resolves current document book id from shelf sync local path", function()
        plugin.db = {
            getBookByFilePath = function()
                return nil
            end,
            getShelfSyncEntryByLocalPath = function(_, path)
                if path == "/books/Book/title.pdf" then
                    return {
                        book_id = 55,
                        remote_title = "Synced Title",
                        remote_author = "Author",
                    }
                end
                return nil
            end,
            saveBookCache = function() end,
        }
        plugin.ui = {
            document = {
                file = "/books/Book/title.pdf",
            },
        }

        local book_id = plugin:resolveCurrentDocumentBookId()

        assert.are.equal(55, book_id)
    end)

    it("syncs the web reader bridge using a shelf-synced local path book id", function()
        local calls = {}
        plugin._initialized = true
        plugin.enabled = true
        plugin.web_reader_bridge_enabled = true
        plugin.requireReady = function()
            return true
        end
        plugin.resolveBookByFilePath = function(_, file_path)
            calls[#calls + 1] = "resolve:" .. file_path
            return {
                file_path = file_path,
                file_hash = "",
                book_id = 77,
            }
        end
        plugin.calculateBookHash = function(_, file_path)
            calls[#calls + 1] = "hash:" .. file_path
            return "hash-77"
        end
        plugin.getCurrentProgressSnapshot = function(_, file_hash, file_path, book_id)
            calls[#calls + 1] = "snapshot:" .. tostring(file_hash) .. ":" .. tostring(book_id)
            return {
                bookHash = file_hash,
                bookId = book_id,
                file_path = file_path,
                percentage = 50,
                progress = "50",
                location = "50",
                currentPage = 50,
                totalPages = 100,
                timestamp = 123,
                device = "KOReader",
                deviceId = "device-1",
                fileFormat = "PDF",
            }
        end
        plugin.pushProgressSnapshot = function(_, snapshot, reason, silent)
            calls[#calls + 1] = "push-progress:" .. tostring(snapshot.bookHash) .. ":" .. tostring(reason) .. ":" .. tostring(silent)
            return true
        end
        plugin.resolveBookByHash = function(_, file_path, file_hash)
            calls[#calls + 1] = "resolve-hash:" .. file_hash
            return nil
        end
        plugin.maybePullWebReaderProgress = function(_, file_hash, file_path, book_id, silent)
            calls[#calls + 1] = table.concat({
                "pull",
                tostring(file_hash),
                tostring(file_path),
                tostring(book_id),
                tostring(silent),
            }, ":")
            return true
        end
        plugin.ui = {
            document = {
                file = "/books/Book/title.pdf",
            },
        }

        local ok = plugin:syncWebReaderBridgeNow(true)

        assert.is_true(ok)
        assert.are.same({
            "resolve:/books/Book/title.pdf",
            "hash:/books/Book/title.pdf",
            "resolve-hash:hash-77",
            "snapshot:hash-77:77",
            "push-progress:hash-77:manual:true",
            "pull:hash-77:/books/Book/title.pdf:77:true",
        }, calls)
    end)

    it("does not sync the web reader bridge when the bridge is disabled", function()
        local calls = {}
        plugin._initialized = true
        plugin.enabled = true
        plugin.web_reader_bridge_enabled = false
        plugin.resolveBookByFilePath = function(_, file_path)
            calls[#calls + 1] = "resolve:" .. file_path
            return {
                file_path = file_path,
                file_hash = "",
                book_id = 77,
            }
        end
        plugin.ui = {
            document = {
                file = "/books/Book/title.pdf",
            },
        }

        local ok = plugin:syncWebReaderBridgeNow(true)

        assert.is_nil(ok)
        assert.are.same({}, calls)
    end)

    it("builds an EPUB bridge payload with exact identity and raw locator data", function()
        local conversion_request = nil
        plugin.cfi_conversion_enabled = true
        plugin.resolveBridgeConversion = function(_, book_id, payload)
            conversion_request = {
                book_id = book_id,
                payload = payload,
            }
            return {
                converted = true,
                epubCfi = "epubcfi(/6/2!/4/2)",
                positionHref = "chapter1.xhtml#p1",
                contentSourceProgressPercent = 44.4,
                conversionStatus = "cfi_to_xpointer",
                conversionConfidence = 0.95,
            }
        end

        local payload, conversion = plugin:buildWebBridgePayload({
            bookId = 77,
            bookFileId = 420,
            bookHash = "hash-epub",
            fileFormat = "EPUB",
            progress = "/body/DocFragment[1]/body/div[1]/p[2]",
            location = "/body/DocFragment[1]/body/div[1]/p[2]",
            currentPage = 12,
            totalPages = 200,
            percentage = 6.0,
            timestamp = 123,
        }, { remote_updated_at = 222 }, false)

        assert.is_not_nil(conversion_request)
        assert.are.equal(77, conversion_request.book_id)
        assert.are.equal("hash-epub", conversion_request.payload.bookHash)
        assert.are.equal(420, conversion_request.payload.bookFileId)
        assert.are.equal("EPUB", conversion_request.payload.fileFormat)
        assert.are.equal("/body/DocFragment[1]/body/div[1]/p[2]", conversion_request.payload.rawKoreaderXPointer)
        assert.are.equal("/body/DocFragment[1]/body/div[1]/p[2]", conversion_request.payload.rawKoreaderLocation)
        assert.are.equal("hash-epub", payload.bookHash)
        assert.are.equal(420, payload.bookFileId)
        assert.are.equal("EPUB", payload.fileFormat)
        assert.are.equal("epubcfi(/6/2!/4/2)", payload.epubCfi)
        assert.are.equal("epubcfi(/6/2!/4/2)", conversion.epubCfi)
    end)

    it("does not send a raw href when EPUB conversion fails", function()
        plugin.cfi_conversion_enabled = true
        plugin.resolveBridgeConversion = function()
            return {
                converted = false,
                epubCfi = nil,
                positionHref = "chapter1.xhtml#p1",
                contentSourceProgressPercent = 44.4,
                conversionStatus = "conversion_failed",
                conversionConfidence = 0.0,
            }
        end

        local payload, conversion = plugin:buildWebBridgePayload({
            bookId = 77,
            bookFileId = 420,
            bookHash = "hash-epub",
            fileFormat = "EPUB",
            progress = "/body/DocFragment[1]/body/div[1]/p[2]",
            location = "/body/DocFragment[1]/body/div[1]/p[2]",
            currentPage = 12,
            totalPages = 200,
            percentage = 6.0,
            timestamp = 123,
        }, nil, false)

        assert.is_not_nil(conversion)
        assert.is_nil(payload.epubCfi)
        assert.is_nil(payload.positionHref)
        assert.are.equal("/body/DocFragment[1]/body/div[1]/p[2]", payload.rawKoreaderXPointer)
    end)

    it("skips EPUB conversion for PDF bridge payloads", function()
        local conversion_called = false
        plugin.cfi_conversion_enabled = true
        plugin.resolveBridgeConversion = function()
            conversion_called = true
            return nil
        end

        local payload, conversion = plugin:buildWebBridgePayload({
            bookId = 78,
            bookFileId = 421,
            bookHash = "hash-pdf",
            fileFormat = "PDF",
            progress = "17",
            location = "17",
            currentPage = 17,
            totalPages = 200,
            percentage = 8.5,
            timestamp = 123,
        }, nil, false)

        assert.is_false(conversion_called)
        assert.is_nil(conversion)
        assert.are.equal("hash-pdf", payload.bookHash)
        assert.are.equal(421, payload.bookFileId)
        assert.are.equal("PDF", payload.fileFormat)
        assert.is_nil(payload.epubCfi)
        assert.are.equal(17, payload.currentPage)
        assert.are.equal(200, payload.totalPages)
    end)

    it("auto-applies remote progress when the remote side is newer on open", function()
        local calls = {}
        plugin.auto_pull_on_open = true
        plugin.server_url = "http://example.com"
        plugin.username = "reader"
        plugin.auth_key = "secret"
        plugin.debug_logging = false
        plugin.isOnline = function()
            return true
        end
        plugin.api = {
            init = function() end,
            getProgress = function()
                return true, {
                    percentage = 8.4,
                    currentPage = 56,
                    totalPages = 663,
                    progress = "56",
                    location = "56",
                    timestamp = 490,
                }
            end,
        }
        plugin.db = {
            getProgressState = function()
                return nil
            end,
            upsertLocalProgressState = function() end,
            upsertRemoteProgressState = function() end,
        }
        plugin.getCurrentProgressSnapshot = function()
            return {
                percentage = 5.4,
                currentPage = 36,
                totalPages = 663,
                progress = "36",
                location = "36",
                timestamp = 500,
            }
        end
        plugin.resolveRemoteChoice = function(_, file_hash, remote_snapshot)
            calls[#calls + 1] = {
                file_hash = file_hash,
                currentPage = remote_snapshot.currentPage,
                percentage = remote_snapshot.percentage,
            }
        end
        plugin.showProgressConflictDialog = function()
            error("should not show a conflict dialog when remote is clearly newer")
        end
        plugin.logInfo = function() end
        plugin.rememberLocalSnapshot = function() end
        plugin.rememberRemoteSnapshot = function() end

        plugin:maybePullRemoteProgress("hash-remote", "/books/title.epub", 42)

        assert.are.equal(1, #calls)
        assert.are.equal("hash-remote", calls[1].file_hash)
        assert.are.equal(56, calls[1].currentPage)
        assert.are.equal(8.4, calls[1].percentage)
    end)

    it("selects a shelf without shadowing the gettext helper", function()
        local saved = {}
        plugin._initialized = true
        plugin.enabled = true
        plugin.server_url = "http://example.com"
        plugin.username = "reader"
        plugin.db = {}
        plugin.api = {
            getShelves = function()
                return true, {
                    { id = 7, name = "Favorites", bookCount = 12 },
                }
            end,
        }
        plugin.saveSetting = function(_, key, value)
            saved[key] = value
            return true
        end
        plugin.showMessage = function() end

        local ok_open, err_open = pcall(function()
            plugin:showShelfPicker()
        end)
        assert.is_true(ok_open, err_open)

        local ok_select, err_select = pcall(function()
            plugin._shelf_picker_dialog.buttons[1][1].callback()
        end)
        assert.is_true(ok_select, err_select)
        assert.are.equal(7, saved.shelf_id)
        assert.are.equal("Favorites", saved.shelf_name)
    end)

    it("enables two-way shelf delete sync through its confirmation dialog", function()
        local menu_items = {}
        local saved = {}
        local refreshed = 0
        local touchmenu_instance = {
            updateItems = function()
                refreshed = refreshed + 1
            end,
        }
        plugin._initialized = true
        plugin.enabled = true
        plugin.two_way_shelf_delete_sync = false
        plugin.db = {
            savePluginSetting = function()
                return true
            end,
        }
        plugin.api = {
            init = function() end,
        }
        plugin.saveSetting = function(_, key, value)
            saved[key] = value
            plugin[key] = value
            return true
        end

        plugin:addToMainMenu(menu_items)

        local shelf_sync_menu = findMenuItem(menu_items.grimmlink.sub_item_table, "Shelf Sync")
        assert.is_not_nil(shelf_sync_menu)
        local two_way_item = findMenuItem(shelf_sync_menu.sub_item_table, "Two-way Shelf Delete Sync")
        assert.is_not_nil(two_way_item)

        local ok_open, err_open = pcall(function()
            two_way_item.callback(touchmenu_instance)
        end)
        assert.is_true(ok_open, err_open)

        local dialog = UIManager.getLastShown and UIManager:getLastShown() or nil
        assert.is_not_nil(dialog)
        assert.is_not_nil(dialog.ok_callback)

        local ok_confirm, err_confirm = pcall(function()
            dialog.ok_callback()
        end)
        assert.is_true(ok_confirm, err_confirm)
        assert.is_true(saved.two_way_shelf_delete_sync)
        assert.is_true(plugin.two_way_shelf_delete_sync)
        assert.is_true(refreshed > 0)
    end)

    it("routes the Check for Updates menu action through the update confirmation flow", function()
        local menu_items = {}
        local messages = {}
        local install_target = nil

        plugin._initialized = true
        plugin.enabled = true
        plugin.auto_update_enabled = true
        plugin.check_update_on_startup = true
        plugin.allow_prerelease_updates = false
        plugin.update_repo = "0xstillb/grimmlink"
        plugin.updater = {
            checkForUpdates = function(_, use_cache)
                assert.is_false(use_cache)
                return {
                    available = true,
                    current_version = "v1.2.2",
                    latest_version = "v1.2.3",
                    release_info = {
                        version = "v1.2.3",
                        asset_name = "grimmlink.koplugin.zip",
                        size = 16384,
                        prerelease = false,
                        download_url = "https://example.invalid/grimmlink.koplugin.zip",
                    },
                }, nil
            end,
            formatBytes = function(_, bytes)
                assert.are.equal(16384, bytes)
                return "16.0 KB"
            end,
        }
        plugin.requireReady = function()
            return true
        end
        plugin.isOnline = function()
            return true
        end
        plugin.saveSetting = function(_, key, value)
            plugin[key] = value
            return true
        end
        plugin.showMessage = function(_, text)
            messages[#messages + 1] = text
        end
        plugin.installUpdate = function(_, release_info)
            install_target = release_info
        end
        plugin.logWarn = function() end

        plugin:addToMainMenu(menu_items)

        local settings_menu = findMenuItem(menu_items.grimmlink.sub_item_table, "Settings")
        assert.is_not_nil(settings_menu)
        local updates_menu = findMenuItem(settings_menu.sub_item_table, "About & Updates")

        assert.is_not_nil(updates_menu)
        local ok_open, err_open = pcall(function()
            updates_menu.sub_item_table[1].callback()
        end)
        assert.is_true(ok_open, err_open)

        assert.are.equal("Checking GrimmLink updates...", messages[1])
        assert.is_true(plugin.update_available)
        assert.is_true(type(plugin.last_update_check) == "number" and plugin.last_update_check > 0)

        local dialog = UIManager.getLastShown and UIManager:getLastShown() or nil
        assert.is_not_nil(dialog)
        assert.is_true(dialog.text:find("GrimmLink update available", 1, true) ~= nil)
        assert.is_true(dialog.text:find("Current version: v1.2.2", 1, true) ~= nil)
        assert.is_true(dialog.text:find("Latest version: v1.2.3", 1, true) ~= nil)
        assert.is_true(dialog.text:find("Size: 16.0 KB", 1, true) ~= nil)
        assert.is_not_nil(dialog.ok_callback)

        local ok_install, err_install = pcall(function()
            dialog.ok_callback()
        end)
        assert.is_true(ok_install, err_install)
        assert.are.same({
            version = "v1.2.3",
            asset_name = "grimmlink.koplugin.zip",
            size = 16384,
            prerelease = false,
            download_url = "https://example.invalid/grimmlink.koplugin.zip",
        }, install_target)
    end)
end)
