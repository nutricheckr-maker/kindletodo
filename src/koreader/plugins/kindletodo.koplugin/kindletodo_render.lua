--[[
KindleTodo wallpaper renderer.

Draws the task list into an 8-bit grayscale BlitBuffer using KOReader's
FreeType bindings directly (no widget tree, no Device/Screen), so the very
same code runs inside the KOReader plugin and headless from the sleep hook.

Output is a pure function of (doc, opts): identical tasks, settings, date and
fonts give byte-identical PNGs.
]]

local Blitbuffer = require("ffi/blitbuffer")
local FT = require("ffi/freetype")

local Render = {}

Render.WIDTH, Render.HEIGHT = 1072, 1448 -- default: Kindle Paperwhite 4, portrait

-- Portrait screen sizes by Kindle serial device code (chars 4-6 of /proc/usid),
-- from KOReader's device table. Used by the headless CLI when the editor has
-- not recorded the real screen size yet.
local SIZE_BY_CODE = {}
for _, c in ipairs{ "0PP", "0T1", "0T2", "0T3", "0T4", "0T5", "0T6", "0T7", "0TJ", "0TK", "0TL",
                    "0TM", "0TN", "102", "103", "16Q", "16R", "16S", "16T", "16U", "16V" } do
    SIZE_BY_CODE[c] = { 1072, 1448 } -- Paperwhite 4 (10th gen)
end
for _, c in ipairs{ "10L", "0WF", "0WG", "0WH", "0WJ", "0VB" } do
    SIZE_BY_CODE[c] = { 600, 800 }   -- Kindle 10th gen (2019, "Basic 3")
end

function Render.sizeForSerial(sn)
    if type(sn) ~= "string" then return nil end
    local s = SIZE_BY_CODE[sn:sub(4, 6)]
    if s then return s[1], s[2] end
end

local WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }

-- E Ink panels show 16 gray levels; stick to multiples of 0x11.
local INK   = Blitbuffer.Color8(0x00)
local DARK  = Blitbuffer.Color8(0x33)
local MID   = Blitbuffer.Color8(0x55)
local SOFT  = Blitbuffer.Color8(0x88)
local PAPER = Blitbuffer.Color8(0xFF)

-- Fonts ---------------------------------------------------------------------

local face_cache = {}
local glyph_cache = {}

local function getFace(path, px)
    local key = path .. "@" .. px
    local f = face_cache[key]
    if not f then
        f = FT.newFaceSize(path, px)
        face_cache[key] = f
        glyph_cache[key] = {}
    end
    return f, key
end

-- A "font" is { path = primary, fallbacks = {...}, px = size }
local function glyph(font, cp)
    local paths = { font.path }
    for _, p in ipairs(font.fallbacks or {}) do table.insert(paths, p) end
    for i, path in ipairs(paths) do
        local face, key = getFace(path, font.px)
        local cache = glyph_cache[key]
        local g = cache[cp]
        if g then return g end
        if i == #paths or face:hasGlyph(cp) then
            g = face:renderGlyph(cp)
            cache[cp] = g
            return g
        end
    end
end

local function metrics(font)
    local face = getFace(font.path, font.px)
    local h, asc = face:getHeightAndAscender()
    return math.floor(h + 0.5), math.floor(asc + 0.5)
end

local function codepoints(s)
    local cps, chars = {}, {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local c = ch:byte(1)
        local cp
        if c < 0x80 then cp = c
        elseif c < 0xE0 then cp = (c % 0x20) * 0x40 + ch:byte(2) % 0x40
        elseif c < 0xF0 then cp = (c % 0x10) * 0x1000 + (ch:byte(2) % 0x40) * 0x40 + ch:byte(3) % 0x40
        else cp = (c % 0x08) * 0x40000 + (ch:byte(2) % 0x40) * 0x1000 + (ch:byte(3) % 0x40) * 0x40 + ch:byte(4) % 0x40
        end
        if cp < 32 then cp = 32 end
        table.insert(cps, cp)
        table.insert(chars, ch)
    end
    return cps, chars
end

local function measure(font, s, tracking)
    local w = 0
    for _, cp in ipairs(codepoints(s)) do
        w = w + glyph(font, cp).ax + (tracking or 0)
    end
    return w
end

local function drawText(bb, font, s, x, baseline, color, tracking)
    local pen = x
    for _, cp in ipairs(codepoints(s)) do
        local g = glyph(font, cp)
        local gw, gh = g.bb:getWidth(), g.bb:getHeight()
        if gw > 0 and gh > 0 then
            bb:colorblitFrom(g.bb, pen + g.l, baseline - g.t, 0, 0, gw, gh, color)
        end
        pen = pen + g.ax + (tracking or 0)
    end
    return pen - x
end

-- Greedy word wrap. Returns lines (at most max_lines; last one ellipsized).
local function wrap(font, text, width, max_lines)
    local lines, cur = {}, ""
    local function push(line) table.insert(lines, line) end
    for word in text:gmatch("%S+") do
        local cand = cur == "" and word or (cur .. " " .. word)
        if measure(font, cand) <= width then
            cur = cand
        else
            if cur ~= "" then push(cur) end
            cur = word
            -- break words longer than a whole line
            while measure(font, cur) > width do
                local cps, chars = codepoints(cur)
                local acc, cut = 0, 0
                for i, cp in ipairs(cps) do
                    acc = acc + glyph(font, cp).ax
                    if acc > width then break end
                    cut = i
                end
                cut = math.max(cut, 1)
                local head, tail = {}, {}
                for i, ch in ipairs(chars) do
                    table.insert(i <= cut and head or tail, ch)
                end
                push(table.concat(head))
                cur = table.concat(tail)
            end
        end
    end
    if cur ~= "" then push(cur) end
    if #lines == 0 then lines = { "" } end
    if #lines > max_lines then
        local kept = {}
        for i = 1, max_lines do kept[i] = lines[i] end
        local last = kept[max_lines] .. "…"
        while measure(font, last) > width and #last > 4 do
            -- drop one UTF-8 character before the ellipsis
            last = last:gsub("[%z\1-\127\194-\244][\128-\191]*…$", "…"):gsub(" …$", "…")
        end
        kept[max_lines] = last
        lines = kept
    end
    return lines
end

-- Primitives ----------------------------------------------------------------

local function hline(bb, x, y, w, t, color)
    bb:paintRect(x, y, w, t, color)
end

local function box(bb, x, y, size, stroke, color)
    bb:paintRect(x, y, size, stroke, color)
    bb:paintRect(x, y + size - stroke, size, stroke, color)
    bb:paintRect(x, y, stroke, size, color)
    bb:paintRect(x + size - stroke, y, stroke, size, color)
end

-- Thick polyline by stamping squares; crisp and deterministic.
local function stroke(bb, pts, thick, color)
    local r = math.floor(thick / 2)
    for i = 1, #pts - 1 do
        local x0, y0, x1, y1 = pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2]
        local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
        for s = 0, steps do
            local px = math.floor(x0 + (x1 - x0) * s / steps + 0.5)
            local py = math.floor(y0 + (y1 - y0) * s / steps + 0.5)
            bb:paintRect(px - r, py - r, thick, thick, color)
        end
    end
end

local function checkbox(bb, x, y, size, checked, color)
    local t = math.max(2, math.floor(size / 11))
    box(bb, x, y, size, t, color)
    if checked then
        stroke(bb, {
            { x + size * 0.22, y + size * 0.52 },
            { x + size * 0.42, y + size * 0.72 },
            { x + size * 0.80, y + size * 0.26 },
        }, t + math.max(1, math.floor(size / 20)), color)
    end
end

-- Dates ---------------------------------------------------------------------

local function ymd(epoch)
    return os.date("%Y-%m-%d", epoch)
end

local function dueLabel(due, now)
    local y, m, d = due:match("^(%d+)-(%d+)-(%d+)$")
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    local today = os.date("*t", now)
    local t0 = os.time{ year = today.year, month = today.month, day = today.day, hour = 12 }
    local days = math.floor((t - t0) / 86400 + 0.5)
    local wd = WEEKDAYS[os.date("*t", t).wday]:sub(1, 3)
    local date = string.format("%s %d %s", wd, tonumber(d), MONTHS[tonumber(m)]:sub(1, 3))
    if days < 0 then return "Overdue · " .. date, true end
    if days == 0 then return "Due today", true end
    if days == 1 then return "Due tomorrow", false end
    return "Due " .. date, false
end

-- Grouping per layout ---------------------------------------------------------

-- Returns a flat list of items: { kind="heading", text=... } | { kind="task", task=... }
local function arrange(doc, opts_hide_done)
    local s = doc.settings
    local open, done = {}, {}
    for i, t in ipairs(doc.tasks) do
        local e = { t = t, idx = i }
        table.insert(t.done and done or open, e)
    end
    local items = {}
    local function addGroup(title, list)
        if #list == 0 then return end
        if title then table.insert(items, { kind = "heading", text = title }) end
        for _, e in ipairs(list) do table.insert(items, { kind = "task", task = e.t }) end
    end
    local function byIdx(a, b) return a.idx < b.idx end

    if s.layout == "priority" then
        local groups = { [1] = {}, [2] = {}, [3] = {}, [0] = {} }
        for _, e in ipairs(open) do table.insert(groups[e.t.priority], e) end
        addGroup("High priority", groups[1])
        addGroup("Medium", groups[2])
        addGroup("Low", groups[3])
        addGroup(#items > 0 and "Other" or nil, groups[0])
    elseif s.layout == "study" then
        local order, groups = {}, {}
        for _, e in ipairs(open) do
            local k = e.t.section or "General"
            if not groups[k] then groups[k] = {}; table.insert(order, k) end
            table.insert(groups[k], e)
        end
        for _, k in ipairs(order) do
            table.sort(groups[k], function(a, b)
                local da, db = a.t.due or "9999", b.t.due or "9999"
                if da ~= db then return da < db end
                return a.idx < b.idx
            end)
            addGroup(k, groups[k])
        end
    elseif s.layout == "timeblock" then
        local timed, untimed = {}, {}
        for _, e in ipairs(open) do table.insert(e.t.time and timed or untimed, e) end
        table.sort(timed, function(a, b)
            if a.t.time ~= b.t.time then return a.t.time < b.t.time end
            return a.idx < b.idx
        end)
        addGroup(#timed > 0 and "Schedule" or nil, timed)
        addGroup(#timed > 0 and "Anytime" or nil, untimed)
    else
        table.sort(open, byIdx)
        addGroup(nil, open)
    end
    if s.show_completed and #done > 0 and not opts_hide_done then
        addGroup("Done", done)
    end
    return items
end

-- Main ----------------------------------------------------------------------

--[[
opts = {
  now = epoch seconds (required for determinism),
  fonts = { serif, serif_bold, serif_italic, sans, sans_bold = paths, fallbacks = {paths} },
  width, height (optional),
}
Returns bb, info{ shown, hidden, scale }
]]
function Render.render(doc, opts)
    local W = opts.width or Render.WIDTH
    local H = opts.height or Render.HEIGHT
    local F = opts.fonts
    local now = assert(opts.now, "opts.now required")
    -- Everything is designed on the PW4's 1072px-wide canvas and scaled by u,
    -- so text keeps the same physical size on any screen (600px @167ppi ≈ 1072px @300ppi).
    local u = W / 1072
    local function px(n) return math.max(1, math.floor(n * u + 0.5)) end
    local function font(path, size)
        return { path = path, px = math.max(14, math.floor(size * u + 0.5)), fallbacks = F.fallbacks }
    end

    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    bb:fill(PAPER)

    local M = math.floor(W * 0.08)       -- side margin (≈86px)
    local CW = W - 2 * M
    local top = math.floor(H * 0.062)    -- top margin (≈90px)

    -- Header: weekday line, big date, optional intention, rule.
    -- The compact variant is only used when the full one would hide tasks.
    local tm = os.date("*t", now)
    local intention = doc.settings.intention or ""
    local function header(compact, draw)
        local kpx, dpx, ipx, ilines, gap = 30, 92, 38, 2, 26
        if compact then kpx, dpx, ipx, ilines, gap = 26, 66, 32, 1, 14 end
        local y = top
        local f_kicker = font(F.sans_bold, kpx)
        local _, kasc = metrics(f_kicker)
        if draw then
            drawText(bb, f_kicker, WEEKDAYS[tm.wday]:upper() .. "   ·   " .. tm.year, M, y + kasc, INK, px(5))
        end
        y = y + kasc + px(gap)
        local f_date = font(F.serif, dpx)
        local dh, dasc = metrics(f_date)
        if draw then
            drawText(bb, f_date, string.format("%d %s", tm.day, MONTHS[tm.month]), M - px(4), y + dasc, INK)
        end
        y = y + dh
        if intention ~= "" then
            local f_int = font(F.serif_italic, ipx)
            local ih, iasc = metrics(f_int)
            y = y + px(4)
            for _, line in ipairs(wrap(f_int, intention, CW, ilines)) do
                if draw then drawText(bb, f_int, line, M, y + iasc, DARK) end
                y = y + ih
            end
        end
        y = y + px(compact and 14 or 22)
        if draw then hline(bb, M, y, CW, px(4), INK) end
        return y + px(4) + px(compact and 26 or 34)
    end

    -- Footer reserves its space up front.
    local f_foot = font(F.sans, 26)
    local fh, fasc = metrics(f_foot)
    local footer_y = H - math.floor(H * 0.045) - fh
    local body_bottom = footer_y - px(30)

    local items = arrange(doc)
    local items_open = arrange(doc, true)
    local open_n, done_n = 0, 0
    for _, t in ipairs(doc.tasks) do
        if t.done then done_n = done_n + 1 else open_n = open_n + 1 end
    end
    local empty = #doc.tasks == 0 or (open_n == 0 and not doc.settings.show_completed)
    if empty then
        items = {}
        items_open = {}
    end

    -- Build the layout at a given scale; returns rows + used height.
    local timeblock = doc.settings.layout == "timeblock"
    local function build(scale, list)
        local L = {
            f_task = font(F.serif, 46 * scale),
            f_task_b = font(F.serif_bold, 46 * scale),
            f_meta = font(F.sans, 27 * scale),
            f_head = font(F.sans_bold, 25 * scale),
            f_time = font(F.sans_bold, 32 * scale),
        }
        L.th, L.tasc = metrics(L.f_task)
        L.lh = math.floor(L.th * 0.94) -- Noto line gap is already ~1.36em
        L.mh, L.masc = metrics(L.f_meta)
        L.hh, L.hasc = metrics(L.f_head)
        L.box = px(42 * scale)
        L.gutter = timeblock and px(128 * scale) or 0
        L.text_x = M + L.gutter + L.box + px(28 * scale)
        L.text_w = W - M - L.text_x
        L.gap = px(20 * scale)
        local max_lines = scale >= 0.9 and 3 or 2
        local rows, used = {}, 0
        for _, it in ipairs(list) do
            local r = { item = it }
            if it.kind == "heading" then
                r.h = px(6 * scale) + L.hh + px(10 * scale)
                if #rows == 0 then r.h = r.h - px(6 * scale) end
            else
                local t = it.task
                local f = (t.priority == 1 and not t.done) and L.f_task_b or L.f_task
                r.font = f
                r.lines = wrap(f, t.title, L.text_w, max_lines)
                r.meta = nil
                if doc.settings.show_due and t.due and not t.done then
                    r.meta, r.urgent = dueLabel(t.due, now)
                end
                if t.section and doc.settings.layout ~= "study" and not t.done then
                    r.meta = r.meta and (t.section .. "  ·  " .. r.meta) or t.section
                end
                r.h = #r.lines * L.lh + (r.meta and (L.mh + px(2)) or 0) + L.gap
            end
            r.y = used
            used = used + r.h
            table.insert(rows, r)
        end
        return L, rows, used
    end

    -- Fitting strategy, most legible first:
    --   1. everything, shrinking text down to 88%
    --   2. open tasks only (completed ones are summarised in the footer), down to 76%
    --   3. truncate at 76% and say how many are hidden
    --   (2b. the same again with a compact header)
    local compact = false
    local y = header(false, false)
    local avail = body_bottom - y
    local L, rows, used, scale
    local attempts = {
        { items, 1.0 }, { items, 0.94 }, { items, 0.88 },
        { items_open, 1.0 }, { items_open, 0.94 }, { items_open, 0.88 },
        { items_open, 0.82 }, { items_open, 0.76 },
        { items_open, 0.88, true }, { items_open, 0.82, true }, { items_open, 0.76, true },
    }
    for _, a in ipairs(attempts) do
        if a[3] and not compact then
            compact = true
            y = header(true, false)
            avail = body_bottom - y
        end
        scale = a[2]
        L, rows, used = build(a[2], a[1])
        if used <= avail then break end
    end
    header(compact, true)

    if empty then
        local f_empty = font(F.serif_italic, 44)
        local msg = #doc.tasks == 0 and "A clean page. Nothing to do." or "Everything is done."
        local w = measure(f_empty, msg)
        local _, easc = metrics(f_empty)
        drawText(bb, f_empty, msg, math.floor((W - w) / 2), math.floor((y + body_bottom) / 2) + math.floor(easc / 2), MID)
    end

    -- Still too tall at the smallest readable size: truncate from the end.
    local shown = rows
    local hidden = 0
    if used > avail then
        shown = {}
        for _, r in ipairs(rows) do
            if r.y + r.h <= avail then table.insert(shown, r) end
        end
        -- don't leave a dangling heading at the bottom
        while #shown > 0 and shown[#shown].item.kind == "heading" do table.remove(shown) end
        for _, r in ipairs(rows) do
            if r.item.kind == "task" and not r.item.task.done then hidden = hidden + 1 end
        end
        for _, r in ipairs(shown) do
            if r.item.kind == "task" and not r.item.task.done then hidden = hidden - 1 end
        end
    end

    local shown_tasks = 0
    for _, r in ipairs(shown) do
        local ry = y + r.y
        local it = r.item
        if it.kind == "heading" then
            local hy = ry + (r.y > 0 and px(6 * scale) or 0)
            drawText(bb, L.f_head, it.text:upper(), M, hy + L.hasc, MID, px(3))
            local tw = measure(L.f_head, it.text:upper(), px(3))
            local ly = hy + math.floor(L.hh / 2)
            hline(bb, M + tw + px(16), ly, CW - tw - px(16), px(2), SOFT)
        else
            shown_tasks = shown_tasks + 1
            local t = it.task
            local color = t.done and SOFT or INK
            local base = ry + L.tasc
            -- checkbox vertically centred on the first line's x-height region
            local by = base - math.floor(L.tasc * 0.70) - math.floor((L.box - L.tasc * 0.70) / 2)
            if timeblock and t.time and not t.done then
                drawText(bb, L.f_time, t.time, M, base, t.done and SOFT or INK)
            end
            checkbox(bb, M + L.gutter, by, L.box, t.done, color)
            -- priority mark in the left margin: solid bar = high, gray bar = medium
            if not t.done and (t.priority == 1 or t.priority == 2) and not timeblock then
                local bar_h = math.floor(L.box * 1.0)
                bb:paintRect(M - px(30 * scale), by, px(8 * scale),
                    bar_h, t.priority == 1 and INK or SOFT)
            end
            for i, line in ipairs(r.lines) do
                local lb = base + (i - 1) * L.lh
                local w = drawText(bb, r.font, line, L.text_x, lb, color)
                if t.done then
                    hline(bb, L.text_x - px(4), lb - math.floor(L.tasc * 0.30), w + px(8), math.max(1, px(3 * scale)), SOFT)
                end
            end
            if r.meta then
                local my = base + (#r.lines - 1) * L.lh + math.floor(L.th * 0.25) + L.masc
                drawText(bb, L.f_meta, r.meta, L.text_x, my, r.urgent and INK or MID)
            end
        end
    end

    -- Footer
    hline(bb, M, footer_y - px(18), CW, px(2), SOFT)
    local left = string.format("%d open  ·  %d done", open_n, done_n)
    drawText(bb, f_foot, left, M, footer_y + fasc, MID)
    if hidden > 0 then
        local right = string.format("+%d more not shown", hidden)
        local rw = measure(f_foot, right)
        drawText(bb, f_foot, right, W - M - rw, footer_y + fasc, INK)
    end

    return bb, { shown = shown_tasks, hidden = hidden, scale = scale, date = ymd(now) }
end

-- Font discovery: KOReader's bundled Noto faces (same files on every install,
-- which keeps output deterministic), plus fallbacks for non-Latin glyphs.
function Render.findFonts(ko_dir)
    local function exists(p)
        local f = p and io.open(p, "rb")
        if f then f:close(); return true end
    end
    local function pick(list)
        for _, p in ipairs(list) do if exists(p) then return p end end
    end
    local kf = ko_dir .. "/fonts/"
    local fonts = {
        serif = pick{ kf .. "noto/NotoSerif-Regular.ttf" },
        serif_bold = pick{ kf .. "noto/NotoSerif-Bold.ttf" },
        serif_italic = pick{ kf .. "noto/NotoSerif-Italic.ttf" },
        sans = pick{ kf .. "noto/NotoSans-Regular.ttf" },
        sans_bold = pick{ kf .. "noto/NotoSans-Bold.ttf" },
        fallbacks = {},
    }
    for _, p in ipairs{ kf .. "noto/NotoSans-Regular.ttf", kf .. "freefont/FreeSerif.ttf",
                        kf .. "noto/NotoSansDevanagariUI-Regular.ttf", kf .. "noto/NotoSansCJKsc-Regular.otf" } do
        if exists(p) then table.insert(fonts.fallbacks, p) end
    end
    for k, v in pairs(fonts) do
        if v == nil and k ~= "fallbacks" then return nil, "missing font: " .. k end
    end
    return fonts
end

return Render
