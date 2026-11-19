-- Boundary: one reusable HTTP/1.1 connection for same-origin page downloads.
--
-- Responsibility: send GET requests over a persistent TCP or TLS connection and
-- read complete responses (Content-Length, chunked, or read-to-close bodies).
-- Owned state: at most one open connection per process, keyed by scheme, host
-- and port.
-- Dependencies: LuaSocket (socket, socket.url) and LuaSec (ssl) for HTTPS.
-- External data: response status, headers and bodies are untrusted; callers
-- fall back to the one-shot LuaSocket request when this returns no response.
--
-- LuaSocket's http.request sends "Connection: close", so every page paid for a
-- new TCP connection and, over HTTPS, a full TLS handshake. Reusing one
-- connection removes that per-page cost on slow e-reader CPUs.

local KeepAlive = {}

local TLS_PARAMS = {
    -- Matches LuaSec's ssl.https defaults used by the existing request path.
    mode = "client",
    protocol = "any",
    options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
    verify = "none",
}
local MAX_HEADER_LINES = 100
local MAX_CHUNK_LINE = 1024

local current -- { key, sock, requests }

local function closeCurrent()
    if current and current.sock then pcall(current.sock.close, current.sock) end
    current = nil
end

function KeepAlive.close()
    closeCurrent()
end

local function target(parsed)
    local path = parsed.path
    if not path or path == "" then path = "/" end
    if parsed.params then path = path .. ";" .. parsed.params end
    if parsed.query then path = path .. "?" .. parsed.query end
    return path
end

local function connect(parsed, timeout)
    local socket = require("socket")
    local sock, err = socket.tcp()
    if not sock then return nil, err end
    sock:settimeout(timeout)
    local ok, connect_err = sock:connect(parsed.host, parsed.port)
    if not ok then
        pcall(sock.close, sock)
        return nil, connect_err
    end
    if parsed.scheme == "https" then
        local ssl = require("ssl")
        local wrapped, wrap_err = ssl.wrap(sock, TLS_PARAMS)
        if not wrapped then
            pcall(sock.close, sock)
            return nil, wrap_err
        end
        sock = wrapped
        if sock.sni then sock:sni(parsed.host) end
        sock:settimeout(timeout)
        local shaken, shake_err = sock:dohandshake()
        if not shaken then
            pcall(sock.close, sock)
            return nil, shake_err
        end
    end
    return sock
end

local function readHeaders(sock)
    local headers = {}
    for _ = 1, MAX_HEADER_LINES do
        local line, err = sock:receive("*l")
        if not line then return nil, err end
        if line == "" then return headers end
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if not name then return nil, "malformed header" end
        name = name:lower()
        headers[name] = headers[name] and (headers[name] .. ", " .. value) or value
    end
    return nil, "too many headers"
end

-- Returns body or nil, err. `sink(chunk)` enforces size and time limits.
local function readBody(sock, headers, sink)
    local encoding = (headers["transfer-encoding"] or ""):lower()
    if encoding ~= "" and encoding ~= "identity" then
        if not encoding:find("chunked", 1, true) then return nil, "unsupported transfer encoding" end
        while true do
            local line, err = sock:receive("*l")
            if not line then return nil, err end
            if #line > MAX_CHUNK_LINE then return nil, "malformed chunk" end
            local size = tonumber(line:match("^%s*(%x+)"), 16)
            if not size then return nil, "malformed chunk" end
            if size == 0 then
                -- Discard trailers up to the blank line ending the message.
                for _ = 1, MAX_HEADER_LINES do
                    local trailer, trailer_err = sock:receive("*l")
                    if not trailer then return nil, trailer_err end
                    if trailer == "" then return true end
                end
                return nil, "too many trailers"
            end
            local data, data_err = sock:receive(size)
            if not data then return nil, data_err end
            local accepted, sink_err = sink(data)
            if not accepted then return nil, sink_err end
            local crlf, crlf_err = sock:receive("*l")
            if crlf ~= "" then return nil, crlf_err or "malformed chunk" end
        end
    end
    local length = headers["content-length"]
    if length then
        length = tonumber(length)
        if not length or length < 0 then return nil, "malformed content length" end
        local remaining = length
        while remaining > 0 do
            local data, err = sock:receive(math.min(remaining, 65536))
            if not data then return nil, err end
            local accepted, sink_err = sink(data)
            if not accepted then return nil, sink_err end
            remaining = remaining - #data
        end
        return true
    end
    -- No framing: the body ends when the server closes the connection.
    while true do
        local data, err, partial = sock:receive(65536)
        local piece = data or partial
        if piece and #piece > 0 then
            local accepted, sink_err = sink(piece)
            if not accepted then return nil, sink_err end
        end
        if not data then
            if err == "closed" then return true, "closed" end
            return nil, err
        end
    end
end

local function exchange(sock, parsed, headers, sink)
    local host = parsed.host
    local default_port = parsed.scheme == "https" and 443 or 80
    if parsed.port and tonumber(parsed.port) ~= default_port then host = host .. ":" .. parsed.port end
    local lines = {
        "GET " .. target(parsed) .. " HTTP/1.1",
        "Host: " .. host,
        "Connection: keep-alive",
        "User-Agent: LuaSocket 3.0",
    }
    for name, value in pairs(headers or {}) do
        local lower = tostring(name):lower()
        if lower ~= "host" and lower ~= "connection" and lower ~= "user-agent" then
            table.insert(lines, tostring(name) .. ": " .. tostring(value))
        end
    end
    local sent, send_err = sock:send(table.concat(lines, "\r\n") .. "\r\n\r\n")
    if not sent then return nil, send_err, true end

    local status_line, status_err = sock:receive("*l")
    if not status_line then return nil, status_err, true end
    local version, code = status_line:match("^HTTP/(%d%.%d)%s+(%d%d%d)")
    code = tonumber(code)
    if not code then return nil, "malformed status line" end
    local response_headers, header_err = readHeaders(sock)
    if not response_headers then return nil, header_err end
    local body_ok, body_err = readBody(sock, response_headers, sink)
    if not body_ok then return nil, body_err end
    local connection = (response_headers.connection or ""):lower()
    local reusable = body_err ~= "closed" and not connection:find("close", 1, true)
        and (version ~= "1.0" or connection:find("keep-alive", 1, true) ~= nil)
    return { code = code, headers = response_headers, reusable = reusable }
end

-- GET `request_url` reusing the open connection when it matches.
-- Returns a response table { code, headers } or nil, err.
-- `make_sink()` must return a fresh sink: a stale connection is retried once.
function KeepAlive.request(request_url, headers, make_sink, timeout)
    local parsed = require("socket.url").parse(request_url)
    if not parsed or not parsed.host or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        return nil, "unsupported url"
    end
    parsed.port = tonumber(parsed.port) or (parsed.scheme == "https" and 443 or 80)
    local key = parsed.scheme .. "://" .. parsed.host:lower() .. ":" .. parsed.port
    if current and current.key ~= key then closeCurrent() end

    for attempt = 1, 2 do
        local reused = current ~= nil
        if not current then
            local sock, err = connect(parsed, timeout)
            if not sock then return nil, err end
            current = { key = key, sock = sock, requests = 0 }
        end
        current.sock:settimeout(timeout)
        local response, err, before_response = exchange(current.sock, parsed, headers, make_sink())
        if response then
            current.requests = current.requests + 1
            if not response.reusable then closeCurrent() end
            return response
        end
        closeCurrent()
        -- A reused connection may have been closed by the server while idle.
        if not (reused and before_response and attempt == 1) then return nil, err end
    end
end

return KeepAlive
