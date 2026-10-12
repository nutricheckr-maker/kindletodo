--[[
Headless entry point, run with KOReader's own LuaJIT from the KOReader dir:

  cd /mnt/us/koreader && ./luajit plugins/kindletodo.koplugin/kindletodo_cli.lua <cmd>

Commands:
  render            render todo.json and install the wallpaper
  render-if-stale   same, but only if the date or the tasks changed since the last render
  check             validate todo.json and the active wallpaper, print a report

Exit status 0 on success. Used by the sleep hook to keep the date current
without any polling: it only runs when the Kindle is going to sleep.
]]

require("ffi").log = function() end -- silence KOReader's library loader
require("setupkoenv")

local plugin_dir = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

local Store = require("kindletodo_store")
local Wallpaper = require("kindletodo_wallpaper")
local Render = require("kindletodo_render")

local cmd = arg[1] or "render"
local home = Wallpaper.home()
local ko_dir = os.getenv("KOREADER_DIR") or "."

local store = Store.new(home)
local status = store:load()

if cmd == "check" then
    print("data dir:     " .. home)
    print("todo.json:    " .. status .. ", " .. #store:tasks() .. " tasks, layout " .. store:settings().layout)
    local p = Wallpaper.paths(home)
    local W, H = Wallpaper.screenSize(home)
    local ok, err = Wallpaper.validate(p.image, W, H)
    print("wallpaper:    " .. (ok and string.format("valid %dx%d grayscale PNG", W, H) or ("INVALID (" .. tostring(err) .. ")")))
    local date, hash = Wallpaper.stamp(home)
    print("last render:  " .. tostring(date) .. (hash == Wallpaper.docHash(store.doc) and " (matches tasks)" or " (tasks changed since)"))
    local fonts, ferr = Render.findFonts(ko_dir)
    print("fonts:        " .. (fonts and "ok" or ferr))
    os.exit(ok and fonts and 0 or 1)
end

if cmd == "render-if-stale" then
    local today = os.date("%Y-%m-%d")
    local p = Wallpaper.paths(home)
    local date, hash = Wallpaper.stamp(home)
    if date == today and hash == Wallpaper.docHash(store.doc)
            and Wallpaper.validate(p.image, Wallpaper.screenSize(home)) then
        print("up to date")
        os.exit(0)
    end
elseif cmd ~= "render" then
    io.stderr:write("unknown command: " .. cmd .. "\n")
    os.exit(2)
end

local ok, info = Wallpaper.generate(store.doc, { ko_dir = ko_dir, home = home, now = os.time() })
if not ok then
    io.stderr:write("kindletodo: " .. tostring(info) .. "\n")
    os.exit(1)
end
Wallpaper.log(string.format("rendered (%s): %d shown, %d hidden", cmd, info.shown, info.hidden), home)
print(string.format("ok %s shown=%d hidden=%d scale=%.2f", info.date, info.shown, info.hidden, info.scale))
os.exit(0)
