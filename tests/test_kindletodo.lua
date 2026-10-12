--[[
KindleTodo test suite. Runs with KOReader's own LuaJIT (any platform build):

  KOREADER_DIR=/path/to/koreader tests/run.sh

Covers the task store (CRUD, ordering, dedupe, persistence, corruption
recovery) and the renderer (all layouts, determinism, overflow, long titles,
failure safety). Writes sample PNGs to $KINDLETODO_TEST_OUT for inspection.
]]

require("ffi").log = function() end
require("setupkoenv")

local plugin_dir = assert(os.getenv("KINDLETODO_PLUGIN"), "KINDLETODO_PLUGIN not set")
package.path = plugin_dir .. "/?.lua;" .. package.path

local Store = require("kindletodo_store")
local Json = require("kindletodo_json")
local Render = require("kindletodo_render")
local Wallpaper = require("kindletodo_wallpaper")

local OUT = assert(os.getenv("KINDLETODO_TEST_OUT"))
local KO = os.getenv("KOREADER_DIR") or "."
local NOW = os.time{ year = 2026, month = 10, day = 11, hour = 9 }

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok    " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local n = 0
local function freshDir()
    n = n + 1
    local d = OUT .. "/case" .. n
    os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "'")
    return d
end

local function titles(store)
    local t = {}
    for _, x in ipairs(store:tasks()) do table.insert(t, x.title) end
    return table.concat(t, "|")
end

-- Store ------------------------------------------------------------------------

test("json round-trip is deterministic and handles unicode/escapes", function()
    local doc = { tasks = { { title = 'Quote " back\\slash\nnew — “dash” ☐ 漢字', id = 1 } }, b = true, a = 1.5 }
    local s1 = Json.encode(doc)
    local back = Json.decode(s1)
    eq(back.tasks[1].title, doc.tasks[1].title, "title")
    eq(Json.encode(back), s1, "stable encoding")
    eq(Json.encode({ tasks = {} }):match("%[%]") ~= nil, true, "empty tasks is []")
end)

test("add / edit / toggle / delete", function()
    local s = Store.new(freshDir()); s:load()
    local a = s:add("  Buy   milk ", nil, NOW)
    eq(a.title, "Buy milk", "trim")
    local b = s:add("Physics homework", { priority = 1, due = "2026-10-12", section = "Physics" })
    eq(b.priority, 1); eq(b.due, "2026-10-12"); eq(b.section, "Physics")
    s:update(a.id, { title = "Buy oat milk", priority = 2 })
    eq(s:find(a.id).title, "Buy oat milk")
    s:toggle(a.id); eq(s:find(a.id).done, true)
    s:toggle(a.id); eq(s:find(a.id).done, false)
    eq(s:delete(b.id), true); eq(s:find(b.id), nil)
    eq(s:delete(999), false)
end)

test("rejects empty and duplicate tasks (accidental double entry)", function()
    local s = Store.new(freshDir()); s:load()
    s:add("Read chapter 3")
    local t, err = s:add("read  CHAPTER 3 ")
    eq(t, nil); eq(err, "duplicate")
    t, err = s:add("   ")
    eq(t, nil); eq(err, "empty")
    -- a completed task with the same text does not block re-adding it
    s:toggle(s:tasks()[1].id)
    eq(s:add("Read chapter 3") ~= nil, true, "re-add after done")
end)

test("invalid fields are cleared, not stored", function()
    local s = Store.new(freshDir()); s:load()
    local t = s:add("x", { priority = 9, due = "2026-13-40", time = "25:99" })
    eq(t.priority, 0); eq(t.due, nil); eq(t.time, nil)
    s:update(t.id, { due = "2026-10-20", time = "07:30" })
    eq(t.due, "2026-10-20"); eq(t.time, "07:30")
    s:update(t.id, { due = false, time = false })
    eq(t.due, nil); eq(t.time, nil)
end)

test("reorder: move, clamp, and new tasks land above completed ones", function()
    local s = Store.new(freshDir()); s:load()
    local a = s:add("A"); local b = s:add("B"); local c = s:add("C")
    s:move(c.id, -1); eq(titles(s), "A|C|B")
    s:move(a.id, 100); eq(titles(s), "C|B|A")
    s:move(a.id, -100); eq(titles(s), "A|C|B")
    s:toggle(b.id)
    s:add("D"); eq(titles(s), "A|C|D|B")
end)

test("clear completed", function()
    local s = Store.new(freshDir()); s:load()
    s:add("A"); local b = s:add("B"); local c = s:add("C")
    s:toggle(b.id); s:toggle(c.id)
    eq(s:clearCompleted(), 2); eq(titles(s), "A")
end)

test("persistence across restarts, with backup of previous version", function()
    local d = freshDir()
    local s = Store.new(d); eq(s:load(), "new")
    s:add("First"); assert(s:save())
    s:add("Second"); assert(s:save())
    local s2 = Store.new(d); eq(s2:load(), "ok")
    eq(titles(s2), "First|Second")
    local bak = Store.new(d); bak.path = d .. "/todo.json.bak"; bak:load()
    eq(titles(bak), "First", "backup holds previous save")
    eq(io.open(d .. "/todo.json.tmp") == nil, true, "no temp file left")
end)

test("malformed main file: recovers from backup and keeps the damaged file", function()
    local d = freshDir()
    local s = Store.new(d); s:load()
    s:add("Keep me"); s:save()
    s:add("And me"); s:save()
    Store.writeFile(d .. "/todo.json", '{"tasks": [ {"title": "trunc')
    local s2 = Store.new(d)
    local status = s2:load()
    assert(status:find("restored from backup"), status)
    eq(titles(s2), "Keep me")
    local p = io.popen("ls '" .. d .. "' | grep -c corrupt"); local c = p:read("*l"); p:close()
    eq(c, "1", "corrupt copy preserved")
end)

test("garbage entries inside a valid file are dropped individually", function()
    local d = freshDir()
    Store.writeFile(d .. "/todo.json", Json.encode{
        tasks = { { title = "ok", id = 3 }, 42, { title = "" }, { notitle = true }, { title = "dup id", id = 3 } },
        settings = { layout = "bogus", show_completed = "yes" },
    })
    local s = Store.new(d); eq(s:load(), "ok")
    eq(titles(s), "ok|dup id")
    assert(s:tasks()[1].id ~= s:tasks()[2].id, "ids made unique")
    eq(s:settings().layout, "minimal"); eq(s:settings().show_completed, true)
end)

test("both files missing/broken: starts empty without crashing", function()
    local d = freshDir()
    Store.writeFile(d .. "/todo.json", "not json")
    Store.writeFile(d .. "/todo.json.bak", "also not json")
    local s = Store.new(d)
    local status = s:load()
    assert(status:find("started empty"), status)
    eq(#s:tasks(), 0)
end)

-- Rendering ----------------------------------------------------------------------

local fonts = assert(Render.findFonts(KO))

local function sampleDoc(layout, count, extra)
    local s = Store.new(freshDir()); s:load()
    local subjects = { "Physics", "Chemistry", "Biology", "English" }
    for i = 1, count do
        local t = s:add(string.format("Task number %d: revise notes and practise problems", i), {
            priority = i % 4, section = subjects[i % 4 + 1],
            due = i % 3 == 0 and "2026-10-1" .. (i % 9) or nil,
            time = string.format("%02d:%02d", 7 + i % 12, (i * 15) % 60),
        })
        if i % 5 == 0 then s:toggle(t.id) end
    end
    s:setSetting("layout", layout)
    s:setSetting("intention", "Deep work before noon.")
    if extra then extra(s) end
    return s.doc
end

local function pngBytes(path)
    local f = io.open(path, "rb"); local d = f:read("*a"); f:close(); return d
end

for _, layout in ipairs(Store.LAYOUTS) do
    test("layout '" .. layout .. "' renders a valid 1072x1448 grayscale PNG", function()
        local home = freshDir()
        local ok, info = Wallpaper.generate(sampleDoc(layout, 7), { ko_dir = KO, home = home, now = NOW })
        assert(ok, info)
        assert(Wallpaper.validate(home .. "/wallpaper.png", 1072, 1448))
        os.execute(string.format("cp '%s/wallpaper.png' '%s/sample-%s.png'", home, OUT, layout))
        eq(info.hidden, 0, "7 tasks fit")
    end)
end

for _, layout in ipairs(Store.LAYOUTS) do
    test("layout '" .. layout .. "' at 600x800 (Kindle 10th gen) fits 6 heavy tasks", function()
        local home = freshDir()
        local ok, info = Wallpaper.generate(sampleDoc(layout, 6), { ko_dir = KO, home = home, now = NOW, width = 600, height = 800 })
        assert(ok, info)
        assert(Wallpaper.validate(home .. "/wallpaper.png", 600, 800))
        os.execute(string.format("cp '%s/wallpaper.png' '%s/kt4-%s.png'", home, OUT, layout))
        eq(info.hidden, 0, "6 tasks fit")
    end)
end

test("screen size: recorded size wins, serial table maps KT4 and PW4", function()
    local home = freshDir()
    Wallpaper.saveScreenSize(800, 600, home) -- landscape input is normalised
    local w, h = Wallpaper.screenSize(home)
    eq(w, 600); eq(h, 800)
    eq(select(1, Render.sizeForSerial("G000VB0000000000")), 600, "KT4 serial")
    eq(select(2, Render.sizeForSerial("G000T1XXXXXXXXXX")), 1448, "PW4 serial")
    eq(Render.sizeForSerial("B0XXXX"), nil, "unknown")
    -- generate() picks the recorded size up by itself
    assert(Wallpaper.generate(sampleDoc("minimal", 2), { ko_dir = KO, home = home, now = NOW }))
    assert(Wallpaper.validate(home .. "/wallpaper.png", 600, 800))
end)

test("identical input gives byte-identical output", function()
    local doc = sampleDoc("study", 9)
    local h1, h2 = freshDir(), freshDir()
    assert(Wallpaper.generate(doc, { ko_dir = KO, home = h1, now = NOW }))
    assert(Wallpaper.generate(doc, { ko_dir = KO, home = h2, now = NOW }))
    eq(pngBytes(h1 .. "/wallpaper.png") == pngBytes(h2 .. "/wallpaper.png"), true, "same bytes")
end)

test("overflow: 40 tasks -> truncated with a 'more' note, text not shrunk below 76%", function()
    local home = freshDir()
    local ok, info = Wallpaper.generate(sampleDoc("minimal", 40), { ko_dir = KO, home = home, now = NOW })
    assert(ok, info)
    assert(info.hidden > 0, "some hidden")
    assert(info.scale >= 0.76, "scale floor")
    os.execute(string.format("cp '%s/wallpaper.png' '%s/sample-overflow.png'", home, OUT))
end)

test("very long titles wrap and ellipsize instead of clipping", function()
    local home = freshDir()
    local doc = sampleDoc("minimal", 0, function(s)
        s:add(string.rep("Supercalifragilisticexpialidocious ", 12))
        s:add(string.rep("W", 300))
        s:add("Short one")
    end)
    local ok, info = Wallpaper.generate(doc, { ko_dir = KO, home = home, now = NOW })
    assert(ok, info)
    eq(info.shown, 3); eq(info.hidden, 0)
    os.execute(string.format("cp '%s/wallpaper.png' '%s/sample-longtitles.png'", home, OUT))
end)

test("empty list renders", function()
    local home = freshDir()
    local ok, info = Wallpaper.generate(sampleDoc("minimal", 0), { ko_dir = KO, home = home, now = NOW })
    assert(ok, info)
    os.execute(string.format("cp '%s/wallpaper.png' '%s/sample-empty.png'", home, OUT))
end)

test("render failure keeps the previous wallpaper untouched", function()
    local home = freshDir()
    assert(Wallpaper.generate(sampleDoc("minimal", 3), { ko_dir = KO, home = home, now = NOW }))
    local before = pngBytes(home .. "/wallpaper.png")
    local ok = Wallpaper.generate(sampleDoc("minimal", 4), { ko_dir = "/nonexistent", home = home, now = NOW })
    eq(ok, nil, "fails without fonts")
    -- a doc that makes the renderer throw
    ok = Wallpaper.generate({ tasks = { { title = {} } }, settings = {} }, { ko_dir = KO, home = home, now = NOW })
    eq(ok, nil, "fails on bad data")
    eq(pngBytes(home .. "/wallpaper.png") == before, true, "image unchanged")
    eq(io.open(home .. "/wallpaper.png.tmp") == nil, true, "no temp left")
end)

test("successful render keeps the previous image as wallpaper.prev.png", function()
    local home = freshDir()
    assert(Wallpaper.generate(sampleDoc("minimal", 2), { ko_dir = KO, home = home, now = NOW }))
    local first = pngBytes(home .. "/wallpaper.png")
    assert(Wallpaper.generate(sampleDoc("minimal", 3), { ko_dir = KO, home = home, now = NOW }))
    eq(pngBytes(home .. "/wallpaper.prev.png") == first, true)
end)

test("validator rejects truncated / wrong-size images", function()
    local home = freshDir()
    assert(Wallpaper.generate(sampleDoc("minimal", 2), { ko_dir = KO, home = home, now = NOW }))
    local data = pngBytes(home .. "/wallpaper.png")
    Store.writeFile(home .. "/trunc.png", data:sub(1, #data - 20))
    eq(Wallpaper.validate(home .. "/trunc.png", 1072, 1448), nil, "truncated")
    eq(Wallpaper.validate(home .. "/wallpaper.png", 1236, 1648), nil, "wrong size")
    eq(Wallpaper.validate(home .. "/missing.png", 1072, 1448), nil, "missing")
end)

test("stamp hash tracks task changes (sleep hook staleness check)", function()
    local home = freshDir()
    local doc = sampleDoc("minimal", 2)
    assert(Wallpaper.generate(doc, { ko_dir = KO, home = home, now = NOW }))
    local _, hash = Wallpaper.stamp(home)
    eq(hash, Wallpaper.docHash(doc), "matches")
    doc.tasks[1].done = true
    assert(hash ~= Wallpaper.docHash(doc), "changes after edit")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
