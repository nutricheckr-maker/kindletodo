--[[
KindleTodo task store.

Single human-readable JSON file (todo.json) holding tasks + settings.
Saves are atomic-ish on the Kindle's FAT32 userstore:
  1. write todo.json.tmp, flush, close
  2. copy current todo.json -> todo.json.bak (last known-good)
  3. rename tmp -> todo.json
  4. sync
Loading falls back to .bak if the main file is missing or malformed, and a
malformed file is preserved as todo.json.corrupt-<time> so it is never lost.

Pure Lua + a JSON decoder; usable inside KOReader and from the headless CLI.
]]

local Json = require("kindletodo_json")

local Store = {}
Store.__index = Store

Store.PRIORITIES = { [0] = "None", "High", "Medium", "Low" }
Store.LAYOUTS = { "minimal", "priority", "study", "timeblock" }

local DEFAULT_SETTINGS = {
    layout = "minimal",
    intention = "",
    show_completed = true,
    show_due = true,
    koreader_screensaver = true,
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
end
Store.trim = trim

local function normTitle(s)
    return trim(s):lower()
end

local function validDate(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    m, d = tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 or d > 31 then return nil end
    return s
end

local function validTime(s)
    if type(s) ~= "string" then return nil end
    local h, mi = s:match("^(%d%d):(%d%d)$")
    if not h then return nil end
    if tonumber(h) > 23 or tonumber(mi) > 59 then return nil end
    return s
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local ok, werr = f:write(data)
    if not ok then f:close(); return nil, werr end
    ok, werr = f:flush()
    f:close()
    if not ok then return nil, werr end
    return true
end
Store.readFile = readFile
Store.writeFile = writeFile

-- Coerce one decoded task into a clean record; nil if unusable.
local function sanitizeTask(t)
    if type(t) ~= "table" then return nil end
    local title = trim(t.title)
    if title == "" then return nil end
    local pr = tonumber(t.priority) or 0
    if pr < 0 or pr > 3 then pr = 0 end
    local section = type(t.section) == "string" and trim(t.section) or nil
    if section == "" then section = nil end
    return {
        id = tonumber(t.id),
        title = title,
        done = t.done == true,
        priority = math.floor(pr),
        due = validDate(t.due),
        time = validTime(t.time),
        section = section,
        created = tonumber(t.created) or 0,
    }
end

-- Validate a decoded document. Returns a clean doc, or nil + reason.
local function sanitizeDoc(doc)
    if type(doc) ~= "table" or type(doc.tasks) ~= "table" then
        return nil, "missing task list"
    end
    local clean = { version = 1, tasks = {}, settings = {} }
    local max_id, seen = 0, {}
    for _, raw in ipairs(doc.tasks) do
        local t = sanitizeTask(raw)
        if t then
            if t.id and t.id > max_id and not seen[t.id] then max_id = t.id end
            table.insert(clean.tasks, t)
        end
    end
    -- assign ids to tasks lacking one or colliding
    for _, t in ipairs(clean.tasks) do
        if not t.id or seen[t.id] then
            max_id = max_id + 1
            t.id = max_id
        end
        seen[t.id] = true
    end
    clean.next_id = math.max(tonumber(doc.next_id) or 0, max_id + 1)
    local s = type(doc.settings) == "table" and doc.settings or {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        if type(s[k]) == type(v) then clean.settings[k] = s[k] else clean.settings[k] = v end
    end
    local layout_ok = false
    for _, l in ipairs(Store.LAYOUTS) do
        if clean.settings.layout == l then layout_ok = true end
    end
    if not layout_ok then clean.settings.layout = DEFAULT_SETTINGS.layout end
    clean.settings.intention = trim(clean.settings.intention):sub(1, 200)
    return clean
end

local function emptyDoc()
    return sanitizeDoc({ tasks = {} })
end

function Store.new(dir)
    local self = setmetatable({}, Store)
    self.dir = dir
    self.path = dir .. "/todo.json"
    self.bak = dir .. "/todo.json.bak"
    self.tmp = dir .. "/todo.json.tmp"
    self.doc = emptyDoc()
    return self
end

local function decodeFile(path)
    local data = readFile(path)
    if data == nil then return nil, "missing" end
    local ok, doc = pcall(Json.decode, data)
    if not ok then return nil, "malformed JSON" end
    return sanitizeDoc(doc)
end

--- Load tasks. Returns a short status string describing any recovery.
function Store:load()
    local doc, err = decodeFile(self.path)
    if doc then
        self.doc = doc
        return "ok"
    end
    local status
    if err ~= "missing" then
        -- Keep the damaged file for the user; never overwrite it silently.
        os.rename(self.path, self.path .. ".corrupt-" .. os.time())
        status = "main file " .. err .. "; "
    else
        status = ""
    end
    local bdoc = decodeFile(self.bak)
    if bdoc then
        self.doc = bdoc
        return status .. "restored from backup"
    end
    self.doc = emptyDoc()
    return err == "missing" and "new" or (status .. "started empty")
end

function Store:save()
    local data = Json.encode(self.doc)
    -- Round-trip check: never replace a good file with something unreadable.
    local ok, back = pcall(Json.decode, data)
    if not ok or not sanitizeDoc(back) then
        return nil, "encode check failed"
    end
    local wok, werr = writeFile(self.tmp, data)
    if not wok then return nil, werr end
    local cur = readFile(self.path)
    if cur and decodeFile(self.path) then
        writeFile(self.bak, cur)
    end
    local rok, rerr = os.rename(self.tmp, self.path)
    if not rok then return nil, rerr end
    os.execute("sync")
    return true
end

-- Accessors ---------------------------------------------------------------

function Store:tasks() return self.doc.tasks end
function Store:settings() return self.doc.settings end

function Store:find(id)
    for i, t in ipairs(self.doc.tasks) do
        if t.id == id then return t, i end
    end
end

function Store:isDuplicate(title, except_id)
    local n = normTitle(title)
    for _, t in ipairs(self.doc.tasks) do
        if not t.done and t.id ~= except_id and normTitle(t.title) == n then
            return true
        end
    end
    return false
end

--- Add a task. Returns the task, or nil + "empty" | "duplicate".
function Store:add(title, fields, now)
    title = trim(title)
    if title == "" then return nil, "empty" end
    if self:isDuplicate(title) then return nil, "duplicate" end
    fields = fields or {}
    local t = sanitizeTask{
        title = title,
        priority = fields.priority,
        due = fields.due,
        time = fields.time,
        section = fields.section,
        created = now or os.time(),
    }
    t.id = self.doc.next_id
    self.doc.next_id = self.doc.next_id + 1
    -- New tasks go after the last open task so completed ones stay at the bottom.
    local pos = #self.doc.tasks + 1
    for i, ex in ipairs(self.doc.tasks) do
        if ex.done then pos = i; break end
    end
    table.insert(self.doc.tasks, pos, t)
    return t
end

--- Update fields of a task. `fields.due`/`time`/`section` may be false to clear.
function Store:update(id, fields)
    local t = self:find(id)
    if not t then return nil, "missing" end
    if fields.title ~= nil then
        local title = trim(fields.title)
        if title == "" then return nil, "empty" end
        if self:isDuplicate(title, id) then return nil, "duplicate" end
        t.title = title
    end
    if fields.priority ~= nil then
        local p = tonumber(fields.priority) or 0
        t.priority = (p >= 0 and p <= 3) and math.floor(p) or 0
    end
    if fields.due ~= nil then t.due = fields.due and validDate(fields.due) or nil end
    if fields.time ~= nil then t.time = fields.time and validTime(fields.time) or nil end
    if fields.section ~= nil then
        local s = fields.section and trim(fields.section) or ""
        t.section = s ~= "" and s or nil
    end
    return t
end

function Store:toggle(id)
    local t = self:find(id)
    if not t then return nil end
    t.done = not t.done
    return t
end

function Store:delete(id)
    local _, i = self:find(id)
    if not i then return false end
    table.remove(self.doc.tasks, i)
    return true
end

--- Move a task by delta positions (clamped). Returns new index.
function Store:move(id, delta)
    local _, i = self:find(id)
    if not i then return nil end
    local list = self.doc.tasks
    local j = math.max(1, math.min(#list, i + delta))
    if j ~= i then
        local t = table.remove(list, i)
        table.insert(list, j, t)
    end
    return j
end

function Store:clearCompleted()
    local kept, n = {}, 0
    for _, t in ipairs(self.doc.tasks) do
        if t.done then n = n + 1 else table.insert(kept, t) end
    end
    self.doc.tasks = kept
    return n
end

function Store:setSetting(key, value)
    if DEFAULT_SETTINGS[key] == nil then return false end
    if type(value) ~= type(DEFAULT_SETTINGS[key]) then return false end
    self.doc.settings[key] = value
    return true
end

function Store:counts()
    local open, done = 0, 0
    for _, t in ipairs(self.doc.tasks) do
        if t.done then done = done + 1 else open = open + 1 end
    end
    return open, done
end

Store._sanitizeDoc = sanitizeDoc
return Store
