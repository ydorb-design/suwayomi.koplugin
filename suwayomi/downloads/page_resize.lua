-- Boundary: optional downscaling of downloaded chapter pages.
--
-- Responsibility: read image dimensions from JPEG, PNG and WebP headers, choose
-- a screen-sized target, and re-encode oversized pages as JPEG through
-- KOReader's image renderer.
-- Owned state: none.
-- Dependencies: ui/renderimage (decode and scale) and the returned BlitBuffer's
-- writeToFile; both are loaded lazily inside the download worker.
-- External data: page bytes are untrusted. Unknown formats, missing sizes,
-- failures, or results that are not smaller keep the original page unchanged.

local PageResize = {}

-- Decoding allocates the full source bitmap: skip pages above this size so a
-- resize can never be what pushes an e-reader out of memory.
PageResize.MAX_SOURCE_PIXELS = 8 * 1000 * 1000
-- Re-encoding costs quality and time; only worth it for a clear reduction.
PageResize.MAX_SCALE = 0.85
PageResize.JPEG_QUALITY = 90
-- Taller than this aspect is a long strip: fit its width, not the screen.
PageResize.STRIP_ASPECT = 3

local function be16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function le16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local function le24(s, i) return s:byte(i) + s:byte(i + 1) * 256 + s:byte(i + 2) * 65536 end
local function be32(s, i) return be16(s, i) * 65536 + be16(s, i + 2) end

local JPEG_SOF = {
    [0xC0] = true, [0xC1] = true, [0xC2] = true, [0xC3] = true, [0xC5] = true, [0xC6] = true,
    [0xC7] = true, [0xC9] = true, [0xCA] = true, [0xCB] = true, [0xCD] = true, [0xCE] = true,
    [0xCF] = true,
}

local function jpegSize(s)
    local i = 3
    while i + 8 <= #s do
        if s:byte(i) ~= 0xFF then return nil end
        local marker = s:byte(i + 1)
        if marker == 0xFF then
            i = i + 1
        elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
            i = i + 2
        elseif marker == 0xD9 or marker == 0xDA then
            return nil
        else
            if JPEG_SOF[marker] then return be16(s, i + 7), be16(s, i + 5) end
            local length = be16(s, i + 2)
            if length < 2 then return nil end
            i = i + 2 + length
        end
    end
end

-- Returns width, height for JPEG, PNG or WebP data, or nil.
function PageResize.imageSize(s)
    if type(s) ~= "string" or #s < 30 then return nil end
    if s:byte(1) == 0xFF and s:byte(2) == 0xD8 then return jpegSize(s) end
    if s:sub(1, 8) == "\137PNG\r\n\26\n" and s:sub(13, 16) == "IHDR" then
        return be32(s, 17), be32(s, 21)
    end
    if s:sub(1, 4) == "RIFF" and s:sub(9, 12) == "WEBP" then
        local chunk = s:sub(13, 16)
        if chunk == "VP8 " and s:sub(24, 26) == "\157\001\042" then
            return le16(s, 27) % 16384, le16(s, 29) % 16384
        elseif chunk == "VP8L" and s:byte(21) == 0x2F then
            local b1, b2, b3, b4 = s:byte(22, 25)
            local width = 1 + b1 + (b2 % 64) * 256
            local height = 1 + math.floor(b2 / 64) + b3 * 4 + (b4 % 16) * 1024
            return width, height
        elseif chunk == "VP8X" then
            return 1 + le24(s, 25), 1 + le24(s, 28)
        end
    end
end

-- Target size for a page of `width` x `height` on a screen, or nil to keep it.
-- Landscape pages (spreads) fit the rotated screen; long strips fit its width.
function PageResize.targetSize(width, height, screen_width, screen_height)
    if not (width and height and screen_width and screen_height) then return nil end
    if width <= 0 or height <= 0 or screen_width <= 0 or screen_height <= 0 then return nil end
    if width * height > PageResize.MAX_SOURCE_PIXELS then return nil end
    local short_side = math.min(screen_width, screen_height)
    local long_side = math.max(screen_width, screen_height)
    local scale
    if height > width * PageResize.STRIP_ASPECT then
        scale = short_side / width
    elseif width > height then
        scale = math.min(long_side / width, short_side / height)
    else
        scale = math.min(short_side / width, long_side / height)
    end
    if scale > PageResize.MAX_SCALE then return nil end
    return math.max(1, math.floor(width * scale + 0.5)), math.max(1, math.floor(height * scale + 0.5))
end

local function readAndRemove(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local content = handle:read("*a")
    handle:close()
    os.remove(path)
    return content
end

-- Returns resized JPEG bytes, or nil to keep the original page.
-- `scratch_path` is a writable temporary file path next to the chapter archive.
function PageResize.resize(body, screen_width, screen_height, scratch_path)
    local width, height = PageResize.imageSize(body)
    local target_width, target_height = PageResize.targetSize(width, height, screen_width, screen_height)
    if not target_width or not scratch_path then return nil end
    local ok, result = pcall(function()
        local RenderImage = require("ui/renderimage")
        local bitmap = RenderImage:renderImageData(body, #body, false, target_width, target_height)
        if not bitmap then return nil end
        local written = bitmap:writeToFile(scratch_path, "jpg", PageResize.JPEG_QUALITY)
        bitmap:free()
        local encoded = readAndRemove(scratch_path)
        if written == false or not encoded or #encoded == 0 or #encoded >= #body then return nil end
        return encoded
    end)
    if not ok then
        os.remove(scratch_path)
        return nil
    end
    return result
end

-- True on KOReader's e-reader platforms, where resizing pays off the most.
function PageResize.isEReader()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" then return false end
    for _, check in ipairs({ "isKobo", "isKindle", "isPocketBook", "isRemarkable", "isCervantes" }) do
        local fn = Device[check]
        if type(fn) == "function" then
            local called, result = pcall(fn, Device)
            if called and result then return true end
        end
    end
    return false
end

-- Current screen size, or nil outside KOReader.
function PageResize.screenSize()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" or not Device.screen then return nil end
    local got, width, height = pcall(function()
        return Device.screen:getWidth(), Device.screen:getHeight()
    end)
    if not got or not tonumber(width) or not tonumber(height) then return nil end
    return tonumber(width), tonumber(height)
end

return PageResize
