--[[--
KindleTodo: a todo list that becomes the Kindle sleep screen.

Opened from KOReader's Tools menu, a gesture ("Todo list" dispatcher action),
or KUAL (KindleTodo › Open todo editor), which drops a flag file and starts
KOReader; in that case closing the list exits KOReader back to the Kindle UI.

Every change is saved to todo.json immediately; the wallpaper is re-rendered
two seconds after the last change (so a burst of edits costs one render) and
always before the editor closes.

@module koplugin.kindletodo
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local Store = require("kindletodo_store")
local Wallpaper = require("kindletodo_wallpaper")

local LAYOUT_NAMES = {
    minimal = _("Minimal"),
    priority = _("Priority first"),
    study = _("Study planner"),
    timeblock = _("Time-blocked"),
}
local PRIORITY_MARK = { [0] = "", "!!!", "!!", "!" }

local function dataHome()
    local env = os.getenv("KINDLETODO_HOME")
    if env then return env end
    if Device:isKindle() then return Wallpaper.DEFAULT_HOME end
    return DataStorage:getDataDir() .. "/kindletodo"
end

-- Device-side helper (sleep hook, diagnostics). Lives in /mnt/us so it works
-- with or without KUAL.
local function hookScript()
    return (os.getenv("KINDLETODO_US") or "/mnt/us") .. "/extensions/kindletodo/bin/kindletodo.sh"
end

local KindleTodo = WidgetContainer:extend{
    name = "kindletodo",
    is_doc_only = false,
}

function KindleTodo:init()
    self.home = dataHome()
    Dispatcher:registerAction("kindletodo_open", {
        category = "none", event = "ShowKindleTodo", title = _("Todo list"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    -- Launched from KUAL? Open straight into the list, and exit KOReader on close.
    local flag = self.home .. "/open.flag"
    if lfs.attributes(flag, "mode") == "file" then
        os.remove(flag)
        UIManager:nextTick(function() self:show(true) end)
    end
end

function KindleTodo:addToMainMenu(menu_items)
    menu_items.kindletodo = {
        text = _("Todo list"),
        sorting_hint = "tools",
        callback = function() self:show(false) end,
    }
end

function KindleTodo:onShowKindleTodo()
    self:show(false)
    return true
end

-- Data ------------------------------------------------------------------------

function KindleTodo:ensureLoaded()
    if lfs.attributes(self.home, "mode") ~= "directory" then
        lfs.mkdir(self.home)
    end
    self.store = Store.new(self.home)
    local status = self.store:load()
    logger.info("KindleTodo: load", status)
    if status ~= "ok" and status ~= "new" then
        UIManager:show(InfoMessage:new{ text = _("Todo list recovered: ") .. status, timeout = 4 })
    end
end

-- Persist now; re-render the wallpaper shortly (debounced).
function KindleTodo:commit()
    local ok, err = self.store:save()
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not save tasks: ") .. tostring(err) })
        return
    end
    self.dirty = true
    UIManager:unschedule(self.render_cb)
    self.render_cb = self.render_cb or function() self:renderNow(true) end
    UIManager:scheduleIn(2, self.render_cb)
    self:refreshList()
end

function KindleTodo:renderNow(quiet)
    if self.render_cb then UIManager:unschedule(self.render_cb) end
    -- Record the real panel size so the headless sleep-hook renders match.
    local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
    local w, h = math.min(sw, sh), math.max(sw, sh)
    Wallpaper.saveScreenSize(w, h, self.home)
    local ok, info = Wallpaper.generate(self.store.doc, {
        ko_dir = lfs.currentdir(), home = self.home, now = os.time(), width = w, height = h,
    })
    if ok then
        self.dirty = false
        Wallpaper.log(string.format("rendered (editor): %d shown, %d hidden", info.shown, info.hidden), self.home)
        self:applyKOReaderScreensaver()
        if not quiet then
            local msg = _("Sleep screen updated.")
            if info.hidden > 0 then
                msg = msg .. "\n" .. string.format(_("%d tasks did not fit and are summarised."), info.hidden)
            end
            UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
        end
    else
        UIManager:show(InfoMessage:new{
            text = _("Sleep screen NOT updated (previous image kept):\n") .. tostring(info),
        })
    end
    return ok
end

-- When KOReader itself is running at sleep time it draws its own sleep screen;
-- point it at our image (remembering the user's previous choice).
function KindleTodo:applyKOReaderScreensaver()
    local want = self.store:settings().koreader_screensaver
    local image = self.home .. "/wallpaper.png"
    local cur_type = G_reader_settings:readSetting("screensaver_type")
    local cur_file = G_reader_settings:readSetting("screensaver_document_cover")
    local ours = cur_type == "document_cover" and cur_file == image
    if want and not ours then
        G_reader_settings:saveSetting("kindletodo_prev_ss_type", cur_type or "disable")
        G_reader_settings:saveSetting("kindletodo_prev_ss_file", cur_file)
        G_reader_settings:saveSetting("screensaver_type", "document_cover")
        G_reader_settings:saveSetting("screensaver_document_cover", image)
    elseif not want and ours then
        G_reader_settings:saveSetting("screensaver_type",
            G_reader_settings:readSetting("kindletodo_prev_ss_type") or "disable")
        G_reader_settings:saveSetting("screensaver_document_cover",
            G_reader_settings:readSetting("kindletodo_prev_ss_file"))
    end
end

-- Sleep hook ----------------------------------------------------------------------

--- Run a helper command; returns true on exit status 0, nil if the helper is missing.
function KindleTodo:hookCmd(cmd)
    local script = hookScript()
    if lfs.attributes(script, "mode") ~= "file" then return nil end
    local rc = os.execute(string.format("QUIET=1 sh '%s' %s", script, cmd))
    return rc == 0 or rc == true
end

function KindleTodo:hookRunning()
    return self:hookCmd("running") == true
end

function KindleTodo:toggleHook()
    if self:hookRunning() then
        self:hookCmd("stop")
    else
        self:hookCmd("start")
    end
    local on = self:hookRunning()
    self:notify(on and _("Sleep hook on: the todo list will show when the Kindle sleeps.")
                    or _("Sleep hook off: the stock sleep screen is back."))
end

function KindleTodo:diagnostics()
    local info = InfoMessage:new{ text = _("Running diagnostics…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    self:hookCmd("diagnose")
    UIManager:close(info)
    UIManager:setDirty("all", "full") -- the live paint test drew over us
    local text = Store.readFile(self.home .. "/diagnostics.txt") or _("Diagnostics helper not found.")
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{ title = _("KindleTodo diagnostics"), text = text, monospace_font = true })
end

-- List view ---------------------------------------------------------------------

local function taskLabel(t)
    local box = t.done and "☑  " or "☐  "
    return box .. t.title
end

local function taskMeta(t)
    local parts = {}
    if t.time then table.insert(parts, t.time) end
    if t.due then table.insert(parts, t.due:sub(6)) end -- MM-DD
    if PRIORITY_MARK[t.priority] ~= "" and not t.done then table.insert(parts, PRIORITY_MARK[t.priority]) end
    return table.concat(parts, "  ")
end

function KindleTodo:buildItems()
    local items = {
        { text = _("＋  Add task"), bold = true, add = true },
    }
    for _, t in ipairs(self.store:tasks()) do
        table.insert(items, {
            text = taskLabel(t),
            mandatory = taskMeta(t),
            dim = t.done,
            task_id = t.id,
        })
    end
    return items
end

function KindleTodo:subtitle()
    local open, done = self.store:counts()
    return string.format(_("%d open · %d done · %s"), open, done,
        LAYOUT_NAMES[self.store:settings().layout])
end

function KindleTodo:refreshList(select_id)
    if not self.menu then return end
    local items = self:buildItems()
    local itemnumber = -1 -- keep current page
    if select_id then
        for i, it in ipairs(items) do
            if it.task_id == select_id then itemnumber = i end
        end
    end
    self.menu:switchItemTable(nil, items, itemnumber, nil, self:subtitle())
end

function KindleTodo:show(exit_on_close)
    if self.menu then return end
    self:ensureLoaded()
    self.exit_on_close = exit_on_close
    -- Arm the sleep hook if it isn't running (e.g. after a reboot).
    if Device:isKindle() and self:hookCmd("running") == false then
        self:hookCmd("start")
    end
    local plugin = self
    self.menu = Menu:new{
        title = _("Todo"),
        subtitle = self:subtitle(),
        item_table = self:buildItems(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        -- 8 fixed-height rows (~160px each on the PW4) = big touch targets;
        -- long titles wrap inside the row instead of growing it.
        items_per_page = 8,
        multilines_show_more_text = true,
        onLeftButtonTap = function() plugin:showOptions() end,
        onMenuSelect = function(_menu, item)
            if item.add then plugin:addTask() else plugin:taskActions(item.task_id) end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item.task_id then
                plugin.store:toggle(item.task_id)
                plugin:commit()
            end
            return true
        end,
        close_callback = function() plugin:close() end,
    }
    UIManager:show(self.menu)
end

function KindleTodo:close()
    if not self.menu then return end
    -- (Menu:onCloseAllMenus has already closed the widget itself.)
    if self.dirty then self:renderNow(true) end
    self.menu = nil
    if self.exit_on_close then
        self.exit_on_close = false
        -- Back to the stock Kindle UI.
        UIManager:nextTick(function() self.ui:handleEvent(Event:new("Exit")) end)
    end
end

-- Dialogs -----------------------------------------------------------------------

function KindleTodo:notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

function KindleTodo:addTask()
    local dialog
    local added = 0
    local function add(keep_open)
        local text = dialog:getInputText()
        if Store.trim(text) == "" then
            if not keep_open then UIManager:close(dialog) end
            return
        end
        local t, err = self.store:add(text)
        if not t then
            self:notify(err == "duplicate" and _("That task is already on the list.") or _("Task is empty."))
            return
        end
        added = added + 1
        self:commit()
        if keep_open then
            dialog:setInputText("")
            dialog:onShowKeyboard()
        else
            UIManager:close(dialog)
        end
    end
    dialog = InputDialog:new{
        title = _("New task"),
        input_hint = _("e.g. Revise chapter 4 notes"),
        description = _("Set priority, due date or subject afterwards by tapping the task."),
        buttons = {{
            { text = _("Close"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Add + next"), callback = function() add(true) end },
            { text = _("Add"), is_enter_default = true, callback = function() add(false) end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KindleTodo:editTitle(t)
    local dialog
    dialog = InputDialog:new{
        title = _("Edit task"),
        input = t.title,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local ok, err = self.store:update(t.id, { title = dialog:getInputText() })
                if not ok then
                    self:notify(err == "duplicate" and _("Another open task already has that text.") or _("Task is empty."))
                    return
                end
                UIManager:close(dialog)
                self:commit()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KindleTodo:pickPriority(t)
    local dialog
    local function row(p, label)
        return {{ text = (t.priority == p and "● " or "") .. label, callback = function()
            UIManager:close(dialog)
            self.store:update(t.id, { priority = p })
            self:commit()
        end }}
    end
    dialog = ButtonDialog:new{
        title = _("Priority"),
        buttons = { row(1, _("High  !!!")), row(2, _("Medium  !!")), row(3, _("Low  !")), row(0, _("None")) },
    }
    UIManager:show(dialog)
end

function KindleTodo:pickDue(t)
    local y, m, d
    if t.due then
        y, m, d = t.due:match("^(%d+)-(%d+)-(%d+)$")
    end
    local now = os.date("*t")
    UIManager:show(DateTimeWidget:new{
        year = tonumber(y) or now.year,
        month = tonumber(m) or now.month,
        day = tonumber(d) or now.day,
        year_min = now.year - 1,
        title_text = _("Due date"),
        ok_text = _("Set due date"),
        extra_text = _("No due date"),
        extra_callback = function(w)
            w:onClose()
            self.store:update(t.id, { due = false })
            self:commit()
        end,
        callback = function(time)
            self.store:update(t.id, { due = string.format("%04d-%02d-%02d", time.year, time.month, time.day) })
            self:commit()
        end,
    })
end

function KindleTodo:pickTime(t)
    local h, mi = 9, 0
    if t.time then h, mi = t.time:match("^(%d+):(%d+)$") end
    UIManager:show(DateTimeWidget:new{
        hour = tonumber(h), min = tonumber(mi),
        title_text = _("Time block"),
        info_text = _("Used by the time-blocked layout."),
        ok_text = _("Set time"),
        extra_text = _("No time"),
        extra_callback = function(w)
            w:onClose()
            self.store:update(t.id, { time = false })
            self:commit()
        end,
        callback = function(time)
            self.store:update(t.id, { time = string.format("%02d:%02d", time.hour, time.min) })
            self:commit()
        end,
    })
end

function KindleTodo:pickSection(t)
    -- Offer existing subjects as one-tap buttons to spare the keyboard.
    local seen, names = {}, {}
    for _, x in ipairs(self.store:tasks()) do
        if x.section and not seen[x.section] then
            seen[x.section] = true
            table.insert(names, x.section)
        end
    end
    table.sort(names)
    local dialog
    local function set(v)
        UIManager:close(dialog)
        self.store:update(t.id, { section = v })
        self:commit()
    end
    local buttons, row = {}, {}
    for _, n in ipairs(names) do
        table.insert(row, { text = (t.section == n and "● " or "") .. n, callback = function() set(n) end })
        if #row == 2 then table.insert(buttons, row); row = {} end
    end
    if #row > 0 then table.insert(buttons, row) end
    table.insert(buttons, {
        { text = _("New subject…"), callback = function()
            UIManager:close(dialog)
            local input
            input = InputDialog:new{
                title = _("Subject / section"),
                input_hint = _("e.g. Physics"),
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                    { text = _("Set"), is_enter_default = true, callback = function()
                        UIManager:close(input)
                        self.store:update(t.id, { section = input:getInputText() })
                        self:commit()
                    end },
                }},
            }
            UIManager:show(input)
            input:onShowKeyboard()
        end },
        { text = _("None"), callback = function() set(false) end },
    })
    dialog = ButtonDialog:new{ title = _("Subject (study planner sections)"), buttons = buttons }
    UIManager:show(dialog)
end

function KindleTodo:taskActions(id)
    local t = self.store:find(id)
    if not t then return end
    local dialog
    local function act(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local function moveBy(delta)
        return act(function()
            self.store:move(id, delta)
            self:commit()
            self:refreshList(id)
        end)
    end
    local n = #self.store:tasks()
    dialog = ButtonDialog:new{
        title = t.title,
        buttons = {
            {{ text = t.done and _("☐  Mark not done") or _("☑  Mark done"), callback = act(function()
                self.store:toggle(id)
                self:commit()
            end) }},
            {
                { text = _("Edit text"), callback = act(function() self:editTitle(t) end) },
                { text = _("Priority"), callback = act(function() self:pickPriority(t) end) },
            },
            {
                { text = _("Due date"), callback = act(function() self:pickDue(t) end) },
                { text = _("Time"), callback = act(function() self:pickTime(t) end) },
                { text = _("Subject"), callback = act(function() self:pickSection(t) end) },
            },
            {
                { text = _("▲ Up"), callback = moveBy(-1) },
                { text = _("▼ Down"), callback = moveBy(1) },
            },
            {
                { text = _("⤒ To top"), callback = moveBy(-n) },
                { text = _("⤓ To bottom"), callback = moveBy(n) },
            },
            {{ text = _("Delete task"), callback = act(function()
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this task?\n\n") .. t.title,
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self.store:delete(id)
                        self:commit()
                    end,
                })
            end) }},
        },
    }
    UIManager:show(dialog)
end

function KindleTodo:showOptions()
    local s = self.store:settings()
    local dialog
    local function act(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local function toggle(key)
        return act(function()
            self.store:setSetting(key, not s[key])
            self:commit()
        end)
    end
    local function onoff(v) return v and _("on") or _("off") end
    local layout_row = {}
    for _, l in ipairs(Store.LAYOUTS) do
        table.insert(layout_row, {
            text = (s.layout == l and "● " or "") .. LAYOUT_NAMES[l],
            callback = act(function()
                self.store:setSetting("layout", l)
                self:commit()
            end),
        })
    end
    local open, done = self.store:counts()
    dialog = ButtonDialog:new{
        title = _("Sleep screen layout"),
        buttons = {
            { layout_row[1], layout_row[2] },
            { layout_row[3], layout_row[4] },
            {{ text = _("Daily intention…"), callback = act(function() self:editIntention() end) }},
            {
                { text = _("Completed: ") .. onoff(s.show_completed), callback = toggle("show_completed") },
                { text = _("Due dates: ") .. onoff(s.show_due), callback = toggle("show_due") },
            },
            {{ text = _("Also KOReader sleep screen: ") .. onoff(s.koreader_screensaver),
               callback = toggle("koreader_screensaver") }},
            {
                { text = _("Preview"), callback = act(function() self:preview() end) },
                { text = _("Regenerate now"), callback = act(function() self:renderNow(false) end) },
            },
            {
                { text = _("Sleep hook: ") .. (self:hookRunning() and _("on") or _("off")),
                  enabled = lfs.attributes(hookScript(), "mode") == "file",
                  callback = act(function() self:toggleHook() end) },
                { text = _("Diagnostics"), callback = act(function() self:diagnostics() end) },
            },
            {{ text = string.format(_("Clear %d completed…"), done), enabled = done > 0,
               callback = act(function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Remove %d completed tasks?\nThis cannot be undone."), done),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        self.store:clearCompleted()
                        self:commit()
                    end,
                })
            end) }},
            {{ text = self.exit_on_close and _("Done — back to Kindle") or _("Close"),
               callback = act(function() self.menu:onClose() end) }},
        },
    }
    UIManager:show(dialog)
end

function KindleTodo:editIntention()
    local dialog
    dialog = InputDialog:new{
        title = _("Daily intention"),
        input = self.store:settings().intention,
        input_hint = _("One line under the date (leave empty for none)"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                UIManager:close(dialog)
                self.store:setSetting("intention", Store.trim(dialog:getInputText()):sub(1, 200))
                self:commit()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KindleTodo:preview()
    if self.dirty and not self:renderNow(true) then return end
    local image = self.home .. "/wallpaper.png"
    if lfs.attributes(image, "mode") ~= "file" then
        self:notify(_("No wallpaper yet."))
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    UIManager:show(ImageViewer:new{
        file = image,
        fullscreen = true,
        with_title_bar = false,
    })
end

return KindleTodo
