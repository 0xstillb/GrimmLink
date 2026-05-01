local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

local Grimmlink = require("main")
local UIManager = require("ui/uimanager")
restore_stubs()

describe("GrimmLink helper methods", function()
    local plugin

    before_each(function()
        if UIManager.reset then
            UIManager:reset()
        end
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

        local annotation_sync = menu_items.grimmlink.sub_item_table[8]
        local pending_sync = menu_items.grimmlink.sub_item_table[9]

        local ok_annotations, text_annotations = pcall(annotation_sync.sub_item_table[7].text_func)
        local ok_pending, text_pending = pcall(pending_sync.text_func)

        assert.is_true(ok_annotations)
        assert.is_true(ok_pending)
        assert.is_not_nil(text_annotations)
        assert.is_not_nil(text_pending)

        local ok_enable = pcall(menu_items.grimmlink.sub_item_table[1].callback)
        local ok_sync_pending = pcall(menu_items.grimmlink.sub_item_table[9].callback)

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

        local ok_open, err_open = pcall(function()
            menu_items.grimmlink.sub_item_table[5].sub_item_table[6].callback(touchmenu_instance)
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
end)
