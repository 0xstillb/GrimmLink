package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./test/?.lua",
    package.path,
}, ";")

package.loaded["grimmlink_util"] = nil
package.loaded["grimmlink_deletion"] = nil
local deletion = require("grimmlink_deletion").new()

describe("grimmlink_deletion safety", function()
    it("allows deletion only for GrimmLink-managed downloads inside managed roots", function()
        local ok1, reason1 = deletion:evaluateLocalDeletePolicy({
            downloaded_by_grimmlink = 1,
            local_path = "/mnt/onboard/books/Book/file.epub",
        }, {
            managed_roots = { "/mnt/onboard/books" },
        })
        assert.is_true(ok1)
        assert.are.equal("ok", reason1)

        local ok2, reason2 = deletion:evaluateLocalDeletePolicy({
            downloaded_by_grimmlink = 1,
            local_path = "/etc/passwd",
        }, {
            managed_roots = { "/mnt/onboard/books" },
        })
        assert.is_false(ok2)
        assert.are.equal("outside_managed_roots", reason2)
    end)

    it("blocks entries not downloaded by GrimmLink", function()
        local ok, reason = deletion:evaluateLocalDeletePolicy({
            downloaded_by_grimmlink = 0,
            local_path = "/mnt/onboard/books/Book/file.epub",
        }, {
            managed_roots = { "/mnt/onboard/books" },
        })
        assert.is_false(ok)
        assert.are.equal("not_downloaded_by_grimmlink", reason)
    end)

    it("queues offline shelf removals through database API", function()
        local queued = nil
        local plugin = {
            db = {
                queueShelfRemoval = function(_, book_id, shelf_id, shelf_type, local_path, delete_sdr)
                    queued = {
                        book_id = book_id,
                        shelf_id = shelf_id,
                        shelf_type = shelf_type,
                        local_path = local_path,
                        delete_sdr = delete_sdr,
                    }
                    return true
                end,
            },
        }

        local ok = deletion:queueOfflineShelfRemoval(plugin, 7, 9, "magic", "/mnt/onboard/books/Book/file.epub", true)
        assert.is_true(ok)
        assert.are.same({
            book_id = 7,
            shelf_id = 9,
            shelf_type = "magic",
            local_path = "/mnt/onboard/books/Book/file.epub",
            delete_sdr = true,
        }, queued)
    end)
end)

