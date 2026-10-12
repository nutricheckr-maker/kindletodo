--[[
KindleTodo wallpaper pipeline: render -> write temp PNG -> validate -> swap.

Files in the data dir (default /mnt/us/kindletodo):
  wallpaper.png       the active image the sleep hook paints
  wallpaper.prev.png  the previous known-good image
  wallpaper.stamp     "<YYYY-MM-DD> <shown> <hidden> <dochash>" of the last good render
  kindletodo.log      short log, trimmed automatically

The active image is only replaced after the new one has been fully written
and its PNG header checked, so a failed render never blanks the screensaver.
]]

local Render = require("kindletodo_render")
local Store = require("kindletodo_store")

local Wallpaper = {}

Wallpaper.DEFAULT_HOME = "/mnt/us/kindletodo"

function Wallpaper.home()
    return os.getenv("KINDLETODO_HOME") or Wallpaper.DEFAULT_HOME
end

function Wallpaper.paths(home)
    home = home or Wallpaper.home()
    return {
        home = home,
        image = home .. "/wallpaper.png",
        prev = home .. "/wallpaper.prev.png",
        tmp = home .. "/wallpaper.png.tmp",
        stamp = home .. "/wallpaper.stamp",
        log = home .. "/kindletodo.log",
        size = home .. "/screen.size",
    }
end

function Wallpaper.log(msg, home)
    local p = Wallpaper.paths(home)
    local f = io.open(p.log, "a")
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n")
    local size = f:seek("end")
    f:close()
    if size and size > 64 * 1024 then
        -- keep the last ~16 KiB
        local data = Store.readFile(p.log) or ""
        Store.writeFile(p.log, data:sub(-16 * 1024))
    end
end

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Check that `path` is a complete grayscale PNG of the expected size.
function Wallpaper.validate(path, w, h)
    local f = io.open(path, "rb")
    if not f then return nil, "no file" end
    local head = f:read(33) or ""
    local size = f:seek("end")
    f:seek("set", size - 12)
    local tail = f:read(12) or ""
    f:close()
    if #head < 33 or head:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil, "not a PNG" end
    if head:sub(13, 16) ~= "IHDR" then return nil, "bad header" end
    local pw, ph = be32(head, 17), be32(head, 21)
    if pw ~= w or ph ~= h then return nil, string.format("size %dx%d, expected %dx%d", pw, ph, w, h) end
    if head:byte(25) ~= 8 or head:byte(26) ~= 0 then return nil, "not 8-bit grayscale" end
    if tail:sub(5, 8) ~= "IEND" then return nil, "truncated" end
    return true
end

local function copyFile(src, dst)
    local data = Store.readFile(src)
    if not data then return false end
    return Store.writeFile(dst, data)
end

--- Portrait screen size: recorded by the editor (exact), else from the
--- Kindle serial number, else the Paperwhite 4 default.
function Wallpaper.screenSize(home)
    local s = Store.readFile(Wallpaper.paths(home).size)
    if s then
        local w, h = s:match("^(%d+)x(%d+)")
        if w then return tonumber(w), tonumber(h) end
    end
    local w, h
    w, h = Render.sizeForSerial(Store.readFile("/proc/usid"))
    if w then return w, h end
    return Render.WIDTH, Render.HEIGHT
end

function Wallpaper.saveScreenSize(w, h, home)
    w, h = math.min(w, h), math.max(w, h) -- always portrait
    return Store.writeFile(Wallpaper.paths(home).size, string.format("%dx%d\n", w, h))
end

--[[
Render `doc` and install it as the active wallpaper.
opts: { ko_dir = KOReader dir (for fonts), now = epoch, home = data dir,
        width/height = screen size (default: Wallpaper.screenSize) }
Returns true, info  or  nil, error (the old wallpaper is left untouched).
]]
function Wallpaper.generate(doc, opts)
    local p = Wallpaper.paths(opts.home)
    local fonts, ferr = Render.findFonts(opts.ko_dir)
    if not fonts then
        Wallpaper.log("render failed: " .. ferr, p.home)
        return nil, ferr
    end
    local W, H = opts.width, opts.height
    if not W then W, H = Wallpaper.screenSize(p.home) end
    local ok, bb, info = pcall(Render.render, doc, { now = opts.now or os.time(), fonts = fonts, width = W, height = H })
    if not ok then
        Wallpaper.log("render failed: " .. tostring(bb), p.home)
        return nil, "render failed: " .. tostring(bb)
    end
    os.remove(p.tmp)
    local wok, werr = pcall(bb.writePNG, bb, p.tmp)
    bb:free()
    if not wok then
        os.remove(p.tmp)
        Wallpaper.log("PNG write failed: " .. tostring(werr), p.home)
        return nil, "PNG write failed"
    end
    local valid, verr = Wallpaper.validate(p.tmp, W, H)
    if not valid then
        os.remove(p.tmp)
        Wallpaper.log("validation failed: " .. verr, p.home)
        return nil, "validation failed: " .. verr
    end
    -- Keep the last known-good image, then swap the new one in.
    if Wallpaper.validate(p.image, W, H) then
        copyFile(p.image, p.prev)
    end
    local rok, rerr = os.rename(p.tmp, p.image)
    if not rok then
        os.remove(p.tmp)
        Wallpaper.log("install failed: " .. tostring(rerr), p.home)
        return nil, "install failed"
    end
    Store.writeFile(p.stamp, string.format("%s %d %d %s\n", info.date, info.shown, info.hidden,
        Wallpaper.docHash(doc)))
    os.execute("sync")
    info.width, info.height = W, H
    return true, info
end

-- FNV-1a over the canonical JSON of the doc: changes whenever tasks or
-- settings change, so the sleep hook can tell if the image is out of date.
function Wallpaper.docHash(doc)
    local bit = require("bit")
    local data = require("kindletodo_json").encode(doc)
    local h = 0x811C9DC5
    for i = 1, #data do
        h = bit.bxor(h, data:byte(i))
        -- h * 16777619 == (h << 24) + h * 403, kept exact within double precision
        h = bit.tobit(bit.lshift(h, 24) + h * 403)
    end
    return bit.tohex(h)
end

--- Date and doc hash of the last successful render, or nil.
function Wallpaper.stamp(home)
    local s = Store.readFile(Wallpaper.paths(home).stamp)
    if not s then return nil end
    return s:match("^(%d%d%d%d%-%d%d%-%d%d)"), s:match("(%x+)%s*$")
end

return Wallpaper
