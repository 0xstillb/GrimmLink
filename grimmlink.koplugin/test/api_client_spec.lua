package.path = table.concat({
    "plugins/grimmlink.koplugin/?.lua",
    "plugins/grimmlink.koplugin/?/init.lua",
    package.path,
}, ";")

local captured_request

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end

package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(target)
                return function(chunk)
                    if chunk then
                        target[#target + 1] = chunk
                    end
                    return 1
                end
            end,
        },
        source = {
            string = function(value)
                local done = false
                return function()
                    if done then
                        return nil
                    end
                    done = true
                    return value
                end
            end,
        },
    }
end

package.preload["socket.http"] = function()
    return {
        request = function(arguments)
            captured_request = arguments
            if arguments.sink then
                arguments.sink('{"status":"ok"}')
            end
            return 1, 200, {}
        end,
    }
end

package.preload["ssl.https"] = function()
    return {
        request = function(arguments)
            captured_request = arguments
            if arguments.sink then
                arguments.sink('{"status":"ok"}')
            end
            return 1, 200, {}
        end,
    }
end

package.preload["json"] = function()
    return {
        encode = function(value)
            if type(value) == "table" and value.hello then
                return '{"hello":"world"}'
            end
            if type(value) == "table" and value.message then
                return '{"message":"' .. value.message .. '"}'
            end
            return "{}"
        end,
        decode = function(value)
            if value == '{"status":"ok"}' then
                return { status = "ok" }
            end
            if value == '{"message":"bad"}' then
                return { message = "bad" }
            end
            error("invalid json")
        end,
    }
end

local APIClient = require("grimmlink_api_client")

describe("GrimmLink API client", function()
    local client

    before_each(function()
        captured_request = nil
        client = APIClient:new()
        client:init("http://example.com", "reader", "secret-md5", false)
    end)

    it("encodes path values", function()
        assert.are.equal("The+Name+of+the+Rose", client:_urlEncode("The Name of the Rose"))
        assert.are.equal("a%26b", client:_urlEncode("a&b"))
    end)

    it("parses success JSON payloads", function()
        local success, code, payload = client:request("GET", "/api/koreader/users/auth")
        assert.is_true(success)
        assert.are.equal(200, code)
        assert.are.equal("ok", payload.status)
        assert.are.equal("reader", captured_request.headers["x-auth-user"])
        assert.are.equal("secret-md5", captured_request.headers["x-auth-key"])
    end)

    it("extracts fallback error messages", function()
        assert.are.equal("bad", client:extractErrorMessage('{"message":"bad"}', 400))
        assert.are.equal("HTTP 418", client:extractErrorMessage(string.rep("x", 500), 418))
    end)
end)
