package.path = "?.lua;" .. package.path

describe("suwayomi/downloads/page_resize", function()
    local PageResize, saved_render, saved_device

    local function be16(n) return string.char(math.floor(n / 256), n % 256) end
    local function be32(n) return be16(math.floor(n / 65536)) .. be16(n % 65536) end
    local function le16(n) return string.char(n % 256, math.floor(n / 256)) end
    local function le24(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536)) end
    local function pad(s) return s .. string.rep("\0", 64) end

    local function jpeg(width, height, extra_segments)
        return pad("\255\216" .. (extra_segments or "")
            .. "\255\192" .. be16(17) .. "\8" .. be16(height) .. be16(width) .. "\3")
    end
    local function png(width, height)
        return pad("\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(width) .. be32(height) .. "\8\2\0\0\0")
    end
    local function webpLossy(width, height)
        return pad("RIFF" .. "\0\0\0\0" .. "WEBP" .. "VP8 " .. "\0\0\0\0" .. "\0\0\0" .. "\157\1\42"
            .. le16(width) .. le16(height))
    end
    local function webpLossless(width, height)
        local w, h = width - 1, height - 1
        local b1 = w % 256
        local b2 = math.floor(w / 256) + (h % 4) * 64
        local b3 = math.floor(h / 4) % 256
        local b4 = math.floor(h / 1024) % 16
        return pad("RIFF" .. "\0\0\0\0" .. "WEBP" .. "VP8L" .. "\0\0\0\0" .. "\47" .. string.char(b1, b2, b3, b4))
    end
    local function webpExtended(width, height)
        return pad("RIFF" .. "\0\0\0\0" .. "WEBP" .. "VP8X" .. "\10\0\0\0" .. "\16\0\0\0"
            .. le24(width - 1) .. le24(height - 1))
    end

    before_each(function()
        saved_render, saved_device = package.loaded["ui/renderimage"], package.loaded.device
        package.loaded["suwayomi/downloads/page_resize"] = nil
        PageResize = require("suwayomi/downloads/page_resize")
    end)

    after_each(function()
        package.loaded["ui/renderimage"], package.loaded.device = saved_render, saved_device
    end)

    describe("imageSize", function()
        it("reads JPEG sizes, skipping segments before the frame header", function()
            assert.same({ 1400, 2000 }, { PageResize.imageSize(jpeg(1400, 2000)) })
            local app1 = "\255\225" .. be16(2 + 300) .. string.rep("x", 300)
            assert.same({ 1234, 1765 }, { PageResize.imageSize(jpeg(1234, 1765, app1 .. "\255\255")) })
        end)

        it("reads PNG and WebP sizes", function()
            assert.same({ 2800, 2000 }, { PageResize.imageSize(png(2800, 2000)) })
            assert.same({ 1400, 2000 }, { PageResize.imageSize(webpLossy(1400, 2000)) })
            assert.same({ 800, 12000 }, { PageResize.imageSize(webpLossless(800, 12000)) })
            assert.same({ 17, 9 }, { PageResize.imageSize(webpLossless(17, 9)) })
            assert.same({ 1400, 2000 }, { PageResize.imageSize(webpExtended(1400, 2000)) })
        end)

        it("returns nothing for unknown or truncated data", function()
            assert.is_nil(PageResize.imageSize("GIF89a" .. string.rep("\0", 64)))
            assert.is_nil(PageResize.imageSize("\255\216\255"))
            assert.is_nil(PageResize.imageSize(nil))
            assert.is_nil(PageResize.imageSize(pad("\255\216\255\218")))
        end)
    end)

    describe("targetSize", function()
        it("fits portrait pages to the portrait screen", function()
            assert.same({ 1176, 1680 }, { PageResize.targetSize(1400, 2000, 1264, 1680) })
            assert.same({ 1176, 1680 }, { PageResize.targetSize(1400, 2000, 1680, 1264) })
        end)

        it("fits two-page spreads to the rotated screen", function()
            assert.same({ 1680, 1200 }, { PageResize.targetSize(2800, 2000, 1264, 1680) })
        end)

        it("narrows long strips to the screen width only", function()
            assert.same({ 1264, 4740 }, { PageResize.targetSize(1600, 6000, 1264, 1680) })
            assert.is_nil(PageResize.targetSize(1000, 8000, 1264, 1680))
        end)

        it("keeps pages that are already close to screen size", function()
            assert.is_nil(PageResize.targetSize(1300, 1800, 1264, 1680))
            assert.is_nil(PageResize.targetSize(1000, 1400, 1264, 1680))
        end)

        it("keeps pages too large to decode safely", function()
            assert.is_nil(PageResize.targetSize(4000, 4000, 1264, 1680))
        end)

        it("rejects missing or invalid sizes", function()
            assert.is_nil(PageResize.targetSize(nil, 100, 1264, 1680))
            assert.is_nil(PageResize.targetSize(100, 100, 0, 1680))
        end)
    end)

    describe("resize", function()
        local render_calls, freed, scratch

        local function installRenderer(encoded, options)
            options = options or {}
            render_calls, freed = {}, 0
            package.loaded["ui/renderimage"] = {
                renderImageData = function(_, _, size, want_frames, width, height)
                    table.insert(render_calls, { size = size, frames = want_frames, width = width, height = height })
                    if options.fail_render then return nil end
                    return {
                        writeToFile = function(_, path, format, quality)
                            assert.are.equal("jpg", format)
                            assert.are.equal(90, quality)
                            if options.fail_write then return false, "disk full" end
                            local handle = assert(io.open(path, "wb"))
                            handle:write(encoded)
                            handle:close()
                            return true
                        end,
                        free = function() freed = freed + 1 end,
                    }
                end,
            }
        end

        before_each(function()
            scratch = os.tmpname()
            os.remove(scratch)
        end)

        it("re-encodes oversized pages at the target size and removes the scratch file", function()
            local page = jpeg(1400, 2000) .. string.rep("p", 5000)
            installRenderer("small-jpeg")
            assert.are.equal("small-jpeg", PageResize.resize(page, 1264, 1680, scratch))
            assert.same({ size = #page, frames = false, width = 1176, height = 1680 }, render_calls[1])
            assert.are.equal(1, freed)
            assert.is_nil(io.open(scratch, "rb"))
        end)

        it("keeps the original when the result is not smaller", function()
            local page = png(2800, 2000)
            installRenderer(string.rep("x", #page + 1))
            assert.is_nil(PageResize.resize(page, 1264, 1680, scratch))
            assert.are.equal(1, freed)
        end)

        it("keeps the original when decoding or writing fails", function()
            local page = jpeg(1400, 2000) .. string.rep("p", 5000)
            installRenderer("small", { fail_render = true })
            assert.is_nil(PageResize.resize(page, 1264, 1680, scratch))
            installRenderer("small", { fail_write = true })
            assert.is_nil(PageResize.resize(page, 1264, 1680, scratch))
            assert.are.equal(1, freed)
            package.loaded["ui/renderimage"] = { renderImageData = function() error("boom") end }
            assert.is_nil(PageResize.resize(page, 1264, 1680, scratch))
        end)

        it("does not decode pages it should keep", function()
            installRenderer("small")
            assert.is_nil(PageResize.resize(jpeg(1000, 1400), 1264, 1680, scratch))
            assert.is_nil(PageResize.resize("GIF89a" .. string.rep("\0", 64), 1264, 1680, scratch))
            assert.are.equal(0, #render_calls)
        end)
    end)

    it("reads the screen size from KOReader's device", function()
        package.loaded.device = { screen = { getWidth = function() return 1264 end, getHeight = function() return 1680 end } }
        assert.same({ 1264, 1680 }, { PageResize.screenSize() })
        package.loaded.device = {}
        assert.is_nil(PageResize.screenSize())
    end)
end)
