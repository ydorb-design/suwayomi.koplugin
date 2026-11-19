package.path = "?.lua;" .. package.path

-- Scripted sockets stand in for the network: each connection replays the
-- responses queued for it and records what the client sent.
describe("suwayomi/api/keepalive", function()
    local KeepAlive, connections, scripts, saved

    local function fakeConnection(script)
        local buffer = table.concat(script.responses or {})
        local conn = { sent = {}, closed = false, host = nil, port = nil }
        function conn:settimeout() end
        function conn:connect(host, port)
            self.host, self.port = host, port
            if script.refuse then return nil, "connection refused" end
            return 1
        end
        function conn:send(data)
            if self.closed or script.dead then return nil, "closed" end
            table.insert(self.sent, data)
            return #data
        end
        function conn:receive(pattern)
            if self.closed then return nil, "closed" end
            if pattern == "*l" then
                local stop = buffer:find("\n", 1, true)
                if not stop then
                    local partial = buffer
                    buffer = ""
                    return nil, "closed", partial
                end
                local line = buffer:sub(1, stop - 1):gsub("\r$", "")
                buffer = buffer:sub(stop + 1)
                return line
            end
            if #buffer == 0 then return nil, "closed", "" end
            local piece = buffer:sub(1, pattern)
            buffer = buffer:sub(pattern + 1)
            if #piece < pattern then return nil, "closed", piece end
            return piece
        end
        function conn:close() self.closed = true end
        return conn
    end

    local function response(body, extra)
        return "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: " .. #body .. "\r\n"
            .. (extra or "") .. "\r\n" .. body
    end

    local function collecting()
        local bodies = {}
        local function make()
            local chunks = {}
            table.insert(bodies, chunks)
            return function(chunk) table.insert(chunks, chunk) return 1 end
        end
        local function last() return table.concat(bodies[#bodies]) end
        return make, last
    end

    before_each(function()
        saved = { package.loaded.socket, package.loaded["socket.url"], package.loaded.ssl,
            package.loaded["suwayomi/api/keepalive"] }
        connections, scripts = {}, {}
        package.loaded["socket.url"] = nil
        local url = require("socket.url")
        package.loaded.socket = {
            tcp = function()
                local conn = fakeConnection(table.remove(scripts, 1) or { responses = {} })
                table.insert(connections, conn)
                return conn
            end,
            url = url,
        }
        package.loaded.ssl = {
            wrap = function(conn)
                conn.tls = true
                function conn:sni(host) self.sni_host = host end
                function conn:dohandshake() return true end
                return conn
            end,
        }
        package.loaded["suwayomi/api/keepalive"] = nil
        KeepAlive = require("suwayomi/api/keepalive")
    end)

    after_each(function()
        KeepAlive.close()
        package.loaded.socket, package.loaded["socket.url"], package.loaded.ssl,
            package.loaded["suwayomi/api/keepalive"] = saved[1], saved[2], saved[3], saved[4]
    end)

    it("reuses one HTTPS connection for consecutive pages", function()
        table.insert(scripts, { responses = { response("page-one"), response("page-two") } })
        local make, last = collecting()
        local first = assert(KeepAlive.request("https://suwa.example/api/v1/manga/1/chapter/2/page/0",
            { Authorization = "Basic abc" }, make, 15))
        assert.are.equal(200, first.code)
        assert.are.equal("page-one", last())
        assert(KeepAlive.request("https://suwa.example/api/v1/manga/1/chapter/2/page/1", {}, make, 15))
        assert.are.equal("page-two", last())
        assert.are.equal(1, #connections)
        local conn = connections[1]
        assert.is_true(conn.tls)
        assert.are.equal("suwa.example", conn.sni_host)
        assert.are.equal(443, conn.port)
        assert.matches("^GET /api/v1/manga/1/chapter/2/page/0 HTTP/1.1\r\n", conn.sent[1])
        assert.matches("\r\nHost: suwa.example\r\n", conn.sent[1], 1, true)
        assert.matches("\r\nConnection: keep-alive\r\n", conn.sent[1], 1, true)
        assert.matches("\r\nAuthorization: Basic abc\r\n", conn.sent[1], 1, true)
        assert.are.equal("image/jpeg", first.headers["content-type"])
    end)

    it("reads chunked bodies and keeps the connection", function()
        table.insert(scripts, { responses = {
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nabcd\r\n3\r\nefg\r\n0\r\nX-Trailer: 1\r\n\r\n",
            response("next"),
        } })
        local make, last = collecting()
        assert(KeepAlive.request("http://suwa.example:4567/page", {}, make, 15))
        assert.are.equal("abcdefg", last())
        assert(KeepAlive.request("http://suwa.example:4567/page2", {}, make, 15))
        assert.are.equal("next", last())
        assert.are.equal(1, #connections)
        assert.matches("\r\nHost: suwa.example:4567\r\n", connections[1].sent[1], 1, true)
        assert.is_nil(connections[1].tls)
    end)

    it("opens a new connection after the server asks to close", function()
        table.insert(scripts, { responses = { response("one", "Connection: close\r\n") } })
        table.insert(scripts, { responses = { response("two") } })
        local make, last = collecting()
        assert(KeepAlive.request("https://suwa.example/a", {}, make, 15))
        assert.is_true(connections[1].closed)
        assert(KeepAlive.request("https://suwa.example/b", {}, make, 15))
        assert.are.equal("two", last())
        assert.are.equal(2, #connections)
    end)

    it("reads unframed bodies to close and does not reuse that connection", function()
        table.insert(scripts, { responses = { "HTTP/1.1 200 OK\r\n\r\nuntil-close" } })
        table.insert(scripts, { responses = { response("again") } })
        local make, last = collecting()
        assert(KeepAlive.request("https://suwa.example/a", {}, make, 15))
        assert.are.equal("until-close", last())
        assert(KeepAlive.request("https://suwa.example/b", {}, make, 15))
        assert.are.equal(2, #connections)
    end)

    it("retries once on a fresh connection when an idle connection went stale", function()
        table.insert(scripts, { responses = { response("one") } })
        table.insert(scripts, { responses = { response("two") } })
        local make, last = collecting()
        assert(KeepAlive.request("https://suwa.example/a", {}, make, 15))
        -- The server dropped the idle connection: nothing more to read.
        local response_two = assert(KeepAlive.request("https://suwa.example/b", {}, make, 15))
        assert.are.equal(200, response_two.code)
        assert.are.equal("two", last())
        assert.are.equal(2, #connections)
    end)

    it("does not retry a failure on a fresh connection", function()
        table.insert(scripts, { refuse = true })
        local make = collecting()
        local result, err = KeepAlive.request("https://suwa.example/a", {}, make, 15)
        assert.is_nil(result)
        assert.are.equal("connection refused", err)
        assert.are.equal(1, #connections)
    end)

    it("does not retry after the response has started", function()
        table.insert(scripts, { responses = { response("one"), "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort" } })
        local make = collecting()
        assert(KeepAlive.request("https://suwa.example/a", {}, make, 15))
        local result, err = KeepAlive.request("https://suwa.example/b", {}, make, 15)
        assert.is_nil(result)
        assert.are.equal("closed", err)
        assert.are.equal(1, #connections)
    end)

    it("stops when the sink rejects the body", function()
        table.insert(scripts, { responses = { response(string.rep("x", 20)) } })
        local result, err = KeepAlive.request("https://suwa.example/a", {}, function()
            return function() return nil, "response too large" end
        end, 15)
        assert.is_nil(result)
        assert.are.equal("response too large", err)
        assert.is_true(connections[1].closed)
    end)

    it("switches connections when the origin changes", function()
        table.insert(scripts, { responses = { response("a") } })
        table.insert(scripts, { responses = { response("b") } })
        local make = collecting()
        assert(KeepAlive.request("https://one.example/a", {}, make, 15))
        assert(KeepAlive.request("https://two.example/a", {}, make, 15))
        assert.are.equal(2, #connections)
        assert.is_true(connections[1].closed)
        assert.are.equal("two.example", connections[2].host)
    end)

    it("rejects malformed responses", function()
        table.insert(scripts, { responses = { "garbage\r\n\r\n" } })
        local make = collecting()
        local result, err = KeepAlive.request("https://suwa.example/a", {}, make, 15)
        assert.is_nil(result)
        assert.are.equal("malformed status line", err)
    end)
end)
