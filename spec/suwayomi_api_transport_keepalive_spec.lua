package.path = "?.lua;" .. package.path

-- Page downloads opt into the reusable connection; anything it cannot answer
-- falls back to the one-shot LuaSocket request with the existing policies.
describe("suwayomi/api/transport keep-alive page downloads", function()
    local transport, keep_alive_calls, keep_alive_result, one_shot_calls

    local credentials = {
        server_url = "https://suwayomi.example",
        username = "alice",
        password = "secret",
        auth_method = "basic_auth",
    }

    before_each(function()
        keep_alive_calls, one_shot_calls = {}, 0
        keep_alive_result = nil
        package.loaded["suwayomi/api/transport"] = nil
        package.loaded["suwayomi/api/keepalive"] = {
            request = function(url, headers, make_sink, timeout)
                table.insert(keep_alive_calls, { url = url, headers = headers, timeout = timeout })
                return keep_alive_result(make_sink)
            end,
            close = function() end,
        }
        package.loaded["ssl.https"] = {
            request = function(options)
                one_shot_calls = one_shot_calls + 1
                options.sink("ONE-SHOT")
                return 1, 200, { ["content-type"] = "image/png" }
            end,
        }
        transport = require("suwayomi/api/transport")
    end)

    after_each(function()
        package.loaded["suwayomi/api/transport"] = nil
        package.loaded["suwayomi/api/keepalive"] = nil
        package.loaded["ssl.https"] = nil
    end)

    it("downloads same-origin pages over the reusable connection with credentials", function()
        keep_alive_result = function(make_sink)
            assert(make_sink()("KEPT"))
            return { code = 200, headers = { ["content-type"] = "image/webp" } }
        end
        local result = transport.downloadBinary(credentials, "/api/v1/page/1", { keep_alive = true })
        assert.is_true(result.ok)
        assert.are.equal("KEPT", result.body)
        assert.are.equal("image/webp", result.content_type)
        assert.are.equal(0, one_shot_calls)
        assert.are.equal("https://suwayomi.example/api/v1/page/1", keep_alive_calls[1].url)
        assert.matches("^Basic ", keep_alive_calls[1].headers.Authorization)
    end)

    it("uses only the body from the final attempt", function()
        keep_alive_result = function(make_sink)
            make_sink()("STALE")
            assert(make_sink()("FRESH"))
            return { code = 200, headers = {} }
        end
        assert.are.equal("FRESH", transport.downloadBinary(credentials, "/p", { keep_alive = true }).body)
    end)

    it("does not use the reusable connection unless asked", function()
        keep_alive_result = function() error("unexpected keep-alive request") end
        assert.are.equal("ONE-SHOT", transport.downloadBinary(credentials, "/p").body)
        assert.are.equal(1, one_shot_calls)
    end)

    it("does not send other-origin images over the reusable connection", function()
        keep_alive_result = function() error("unexpected keep-alive request") end
        assert.are.equal("ONE-SHOT", transport.downloadBinary(credentials, "https://cdn.example/p.jpg", { keep_alive = true }).body)
        assert.are.equal(0, #keep_alive_calls)
    end)

    it("falls back to the one-shot request for redirects", function()
        keep_alive_result = function(make_sink)
            make_sink()("moved")
            return { code = 302, headers = { location = "/elsewhere" } }
        end
        local result = transport.downloadBinary(credentials, "/p", { keep_alive = true })
        assert.are.equal("ONE-SHOT", result.body)
        assert.are.equal(1, one_shot_calls)
    end)

    it("falls back to the one-shot request when the connection fails", function()
        keep_alive_result = function() return nil, "connection refused" end
        assert.are.equal("ONE-SHOT", transport.downloadBinary(credentials, "/p", { keep_alive = true }).body)
        assert.are.equal(1, one_shot_calls)
    end)

    it("reports oversized pages without refetching them", function()
        keep_alive_result = function() return nil, "response too large" end
        local result = transport.downloadBinary(credentials, "/p", { keep_alive = true })
        assert.is_false(result.ok)
        assert.are.equal("Downloaded response was too large.", result.error)
        assert.are.equal(0, one_shot_calls)
    end)

    it("maps HTTP errors from the reusable connection like the one-shot request", function()
        keep_alive_result = function() return { code = 404, headers = {} } end
        local result = transport.downloadBinary(credentials, "/p", { keep_alive = true })
        assert.is_false(result.ok)
        assert.are.equal("Chapter page not found.", result.error)
        assert.are.equal(404, result.status_code)
        assert.are.equal(0, one_shot_calls)
    end)

    it("enforces the page size limit through the sink", function()
        keep_alive_result = function(make_sink)
            local accepted, err = make_sink()(string.rep("x", 11))
            assert.is_nil(accepted)
            return nil, err
        end
        local result = transport.downloadBinary(credentials, "/p", { keep_alive = true, max_bytes = 10 })
        assert.are.equal("Downloaded response was too large.", result.error)
    end)
end)
