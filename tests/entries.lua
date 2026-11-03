-- Run from the repository root: nvim --headless -u NONE -l tests/entries.lua
--
-- Covers extension custom entries (`pi.appendEntry`): active-branch selection
-- for replay, live `entry_appended` rendering through `entry_renderers`, and
-- replay from `get_entries`. RPC and descriptor resolution are stubbed, so no
-- real pi starts. Inputs are decoded from JSON text so `null` arrives as
-- `vim.NIL`, as it does over RPC.
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.o.swapfile = false

local passed, failed = 0, 0

---@param actual any
---@param expected any
---@param what? string
local function eq(actual, expected, what)
    assert(
        vim.deep_equal(actual, expected),
        (what and (what .. ": ") or "") .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected)
    )
end

---@param json string
---@return any
local function decode(json)
    return vim.json.decode(json)
end

---@param name string
---@param fn fun()
local function test(name, fn)
    vim.v.errmsg = ""
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. "\n" .. err)
    end
end

-- Active-branch selection ----------------------------------------------------

local Entries = require("pi.sessions.entries")

---@param list pi.SessionEntry[]
---@return string[]
local function ids(list)
    local out = {}
    for i, e in ipairs(list) do
        out[i] = e.id
    end
    return out
end

-- a <- b <- c (abandoned branch) and a <- b <- d <- e (active)
local BRANCHED = [[[
  {"type":"message","id":"a","parentId":null,"timestamp":"t","message":{"role":"user","content":"hi"}},
  {"type":"message","id":"b","parentId":"a","timestamp":"t","message":{"role":"assistant","content":"yo"}},
  {"type":"custom","id":"c","parentId":"b","timestamp":"t","customType":"x","data":{}},
  {"type":"message","id":"d","parentId":"b","timestamp":"t","message":{"role":"user","content":"again"}},
  {"type":"custom","id":"e","parentId":"d","timestamp":"t","customType":"x","data":{}}
]
]]

test("leaf path skips abandoned branches", function()
    eq(ids(Entries.context_entries(decode(BRANCHED), "e")), { "a", "b", "d", "e" })
    eq(ids(Entries.context_entries(decode(BRANCHED), "c")), { "a", "b", "c" })
end)

test("absent or unknown leaf falls back to the last entry", function()
    eq(ids(Entries.context_entries(decode(BRANCHED), nil)), { "a", "b", "d", "e" })
    eq(ids(Entries.context_entries(decode(BRANCHED), "missing")), { "a", "b", "d", "e" })
end)

test("JSON null leaf selects nothing", function()
    local data = decode('{"entries":' .. BRANCHED .. ',"leafId":null}')
    eq(data.leafId, vim.NIL)
    eq(Entries.context_entries(data.entries, data.leafId), {})
end)

test("compaction keeps entries from firstKeptEntryId, without system messages", function()
    local entries = decode([[[
      {"type":"message","id":"1","parentId":null,"timestamp":"t","message":{"role":"user","content":"old"}},
      {"type":"message","id":"2","parentId":"1","timestamp":"t","message":{"role":"user","content":"kept"}},
      {"type":"message","id":"3","parentId":"2","timestamp":"t","message":{"role":"system","content":"sys"}},
      {"type":"custom","id":"4","parentId":"3","timestamp":"t","customType":"x","data":{}},
      {"type":"compaction","id":"5","parentId":"4","timestamp":"t","summary":"s","tokensBefore":10,"firstKeptEntryId":"2"},
      {"type":"message","id":"6","parentId":"5","timestamp":"t","message":{"role":"user","content":"new"}}
    ]
    ]])
    eq(ids(Entries.context_entries(entries, "6")), { "5", "2", "4", "6" })
end)

test("only the latest compaction leads", function()
    local entries = decode([[[
      {"type":"message","id":"1","parentId":null,"timestamp":"t","message":{"role":"user","content":"a"}},
      {"type":"compaction","id":"2","parentId":"1","timestamp":"t","summary":"s1","tokensBefore":1,"firstKeptEntryId":"1"},
      {"type":"message","id":"3","parentId":"2","timestamp":"t","message":{"role":"user","content":"b"}},
      {"type":"compaction","id":"4","parentId":"3","timestamp":"t","summary":"s2","tokensBefore":2,"firstKeptEntryId":"3"},
      {"type":"message","id":"5","parentId":"4","timestamp":"t","message":{"role":"user","content":"c"}}
    ]
    ]])
    eq(ids(Entries.context_entries(entries, "5")), { "4", "3", "5" })
end)

-- Session wiring ------------------------------------------------------------

_G.T = { sent = {}, handler = nil, entries = nil, notes = {} }

require("pi.execution.descriptor").resolve = function(_, done)
    done({ kind = "local" })
end

require("pi.rpc").new = function()
    local rpc = { _running = false }
    function rpc:start()
        self._running = true
        return true
    end
    function rpc:is_running()
        return self._running
    end
    function rpc:set_handler(fn)
        T.handler = fn
    end
    function rpc:send(cmd, cb)
        table.insert(T.sent, cmd.type)
        if cb then
            local data = {}
            if cmd.type == "get_commands" then
                data = { commands = {} }
            elseif cmd.type == "get_entries" then
                data = T.entries
            elseif cmd.type == "get_session_stats" then
                data = { tokens = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 }, cost = 0 }
            end
            vim.schedule(function()
                cb({ success = true, data = data })
            end)
        end
        return true
    end
    function rpc:stop(cb)
        self._running = false
        if cb then
            cb(nil)
        end
    end
    function rpc:command_name()
        return "pi"
    end
    return rpc
end

local notify = vim.notify
vim.notify = function(msg, level)
    table.insert(T.notes, { msg = msg, level = level })
end

require("pi").setup({
    entry_renderers = {
        ["rules:load"] = function(entry)
            local lines = {}
            for _, path in ipairs(entry.data.paths) do
                lines[#lines + 1] = { { "   ╰  rule: ", "Comment" }, { path, "PiMention" } }
            end
            return lines
        end,
        ["rules:empty"] = function()
            return nil
        end,
        ["rules:boom"] = function()
            error("kaboom")
        end,
        ["rules:block"] = function()
            return { target = "history", block = "custom", content = { { { "old block" } } } }
        end,
        ["rules:strings"] = function()
            return { "plain string" }
        end,
    },
})

local Manager = require("pi.sessions.manager")

--- Run scheduled callbacks until the event loop is idle.
local function drain()
    for _ = 1, 10 do
        local done = false
        vim.schedule(function()
            done = true
        end)
        assert(vim.wait(1000, function()
            return done
        end))
    end
end

---@return pi.Session
local function session()
    local s ---@type pi.Session?
    Manager.get_or_create({}, function(created)
        s = created
    end)
    drain()
    return assert(s, "session was not created")
end

local S = session()

---@return string[]
local function lines()
    return vim.api.nvim_buf_get_lines(S.chat._history:buf(), 0, -1, false)
end

---@param needle string
---@return integer count
local function count(needle)
    local n = 0
    for _, line in ipairs(lines()) do
        if line:find(needle, 1, true) then
            n = n + 1
        end
    end
    return n
end

---@param needle string
---@return integer? row 1-based
local function row_of(needle)
    for i, line in ipairs(lines()) do
        if line:find(needle, 1, true) then
            return i
        end
    end
end

---@param event table
local function emit(event)
    T.handler(event)
    drain()
end

---@param id string
---@param custom_type string
---@param data any
local function custom(id, custom_type, data)
    return { type = "custom", id = id, parentId = vim.NIL, timestamp = "t", customType = custom_type, data = data }
end

local function reset()
    S.chat:clear()
    T.notes = {}
    drain()
end

test("live custom entry renders under the running tool", function()
    reset()
    emit({ type = "agent_start" })
    emit({ type = "tool_execution_start", toolName = "read", toolCallId = "r1", args = { path = "a.ts" } })
    emit({ type = "entry_appended", entry = custom("e1", "rules:load", { paths = { ".agents/rules/testing.md" } }) })
    emit({ type = "tool_execution_end", toolName = "read", toolCallId = "r1", result = { content = {} } })
    local tool, rule = row_of("a.ts"), row_of("rule: .agents/rules/testing.md")
    assert(tool and rule and rule > tool, vim.inspect(lines()))

    local buf, ns = S.chat._history:buf(), S.chat._history:ns()
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { rule - 1, 0 }, { rule - 1, -1 }, { details = true })
    local groups = {}
    for _, m in ipairs(marks) do
        if m[4].hl_group then
            groups[m[4].hl_group] = true
        end
    end
    assert(groups.Comment and groups.PiMention, vim.inspect(marks))
    emit({ type = "agent_end" })
end)

test("same entry id renders once", function()
    reset()
    local e = custom("dup", "rules:load", { paths = { "dup.md" } })
    emit({ type = "entry_appended", entry = e })
    emit({ type = "entry_appended", entry = e })
    eq(count("rule: dup.md"), 1)
end)

test("entries without a renderer, or rendering nothing, add no lines", function()
    reset()
    local before = #lines()
    emit({ type = "entry_appended", entry = custom("n1", "unknown", {}) })
    emit({ type = "entry_appended", entry = custom("n2", "rules:empty", {}) })
    eq(#lines(), before)
end)

test("renderer error is reported and later entries still render", function()
    reset()
    emit({ type = "entry_appended", entry = custom("b1", "rules:boom", {}) })
    emit({ type = "entry_appended", entry = custom("b2", "rules:load", { paths = { "after.md" } }) })
    local reported = false
    for _, n in ipairs(T.notes) do
        reported = reported or (n.level == vim.log.levels.ERROR and n.msg:find('"rules:boom"', 1, true) ~= nil)
    end
    assert(reported, vim.inspect(T.notes))
    eq(count("rule: after.md"), 1)
end)

test("malformed renderer results are reported and skipped", function()
    reset()
    local before = #lines()
    emit({ type = "entry_appended", entry = custom("m1", "rules:block", {}) })
    emit({ type = "entry_appended", entry = custom("m2", "rules:strings", {}) })
    eq(#lines(), before)
    eq(vim.v.errmsg, "")
    local reported = {}
    for _, n in ipairs(T.notes) do
        if n.level == vim.log.levels.ERROR and n.msg:find("must return nil or a list of lines", 1, true) then
            reported[#reported + 1] = n.msg:match('%["([^"]+)"%]')
        end
    end
    eq(reported, { "rules:block", "rules:strings" })
end)

-- Replay ----------------------------------------------------------------------

--- user -> assistant tool call -> rule entry -> tool result -> rule entry ->
--- tool-only continuation -> tool result -> final text, then a compaction.
local REPLAY = [[{
  "leafId": "k",
  "entries": [
    {"type":"message","id":"a","parentId":null,"timestamp":"2026-11-02T10:00:00Z","message":{"role":"user","content":"read it","timestamp":1}},
    {"type":"message","id":"b","parentId":"a","timestamp":"t","message":{"role":"assistant","timestamp":2,"content":[{"type":"toolCall","id":"r1","name":"read","arguments":{"path":"one.ts"}}]}},
    {"type":"custom","id":"c","parentId":"b","timestamp":"t","customType":"rules:load","data":{"paths":["one.md"]}},
    {"type":"message","id":"d","parentId":"c","timestamp":"t","message":{"role":"toolResult","toolCallId":"r1","toolName":"read","content":[{"type":"text","text":"x"}]}},
    {"type":"custom","id":"e","parentId":"d","timestamp":"t","customType":"rules:load","data":{"paths":["between.md"]}},
    {"type":"message","id":"f","parentId":"e","timestamp":"t","message":{"role":"assistant","timestamp":3,"content":[{"type":"toolCall","id":"r2","name":"read","arguments":{"path":"two.ts"}}]}},
    {"type":"message","id":"g","parentId":"f","timestamp":"t","message":{"role":"toolResult","toolCallId":"r2","toolName":"read","content":[{"type":"text","text":"y"}]}},
    {"type":"message","id":"h","parentId":"g","timestamp":"t","message":{"role":"assistant","timestamp":4,"content":[{"type":"text","text":"All done."}]}},
    {"type":"custom","id":"abandoned","parentId":"b","timestamp":"t","customType":"rules:load","data":{"paths":["abandoned.md"]}},
    {"type":"compaction","id":"k","parentId":"h","timestamp":"t","summary":"Summary text","tokensBefore":1234,"firstKeptEntryId":"a"}
  ]
}]]

test("replay renders custom entries in persisted order on the active branch", function()
    reset()
    T.entries = decode(REPLAY)
    T.sent = {}
    emit({ type = "entry_appended", entry = T.entries.entries[10] })
    drain()
    assert(vim.tbl_contains(T.sent, "get_entries"), vim.inspect(T.sent))
    assert(not vim.tbl_contains(T.sent, "get_messages"), vim.inspect(T.sent))

    local user, one, rule1, between, two, done =
        row_of("read it"), row_of("one.ts"), row_of("rule: one.md"), row_of("rule: between.md"), row_of("two.ts"), row_of("All done.")
    assert(user and one and rule1 and between and two and done, vim.inspect(lines()))
    assert(user < one and one < rule1 and rule1 < between and between < two and two < done, vim.inspect(lines()))
    eq(count("abandoned.md"), 0)
    eq(count("rule: one.md"), 1)
end)

test("custom entry before a tool-only continuation adds no agent header", function()
    -- Same transcript without the custom entries: header and separator layout must match.
    local without = decode(REPLAY)
    local kept = {}
    for _, e in ipairs(without.entries) do
        if e.type ~= "custom" then
            kept[#kept + 1] = e
        end
    end
    kept[2].parentId = "a"
    kept[3].parentId = "b"
    kept[4].parentId = "d"
    without.entries = kept

    ---@param data table
    ---@return string[]
    local function replayed(data)
        reset()
        T.entries = data
        emit({ type = "entry_appended", entry = data.entries[#data.entries] })
        drain()
        local out = {}
        for _, line in ipairs(lines()) do
            if not line:find("rule: ", 1, true) then
                out[#out + 1] = line
            end
        end
        return out
    end

    eq(replayed(decode(REPLAY)), replayed(without))
end)

-- Deprecated on_widget ------------------------------------------------------

test("on_widget warns once and still routes widgets", function()
    T.notes = {}
    local seen = {}
    local function hook(key, widget_lines)
        seen[#seen + 1] = key
        return { target = "history", block = "custom", content = { { { "widget: " .. widget_lines[1] } } } }
    end
    require("pi.config").setup({ on_widget = hook })
    require("pi.config").setup({ on_widget = hook })
    eq(#T.notes, 0, "warning is deferred, not sent from setup()")
    drain()
    local warnings = 0
    for _, n in ipairs(T.notes) do
        if n.level == vim.log.levels.WARN and n.msg:find("on_widget", 1, true) then
            warnings = warnings + 1
        end
    end
    eq(warnings, 1)

    reset()
    emit({ type = "extension_ui_request", method = "setWidget", widgetKey = "rules:load", widgetLines = { "w.md" } })
    eq(seen, { "rules:load" })
    eq(count("widget: w.md"), 1)
end)

test("on_widget warning set up during startup waits for VimEnter", function()
    local init = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
        "vim.opt.runtimepath:append(" .. vim.inspect(vim.fn.getcwd()) .. ")",
        "_G.notes = {}",
        "vim.notify = function(msg) table.insert(_G.notes, msg) end",
        "require('pi.config').setup({ on_widget = function() end })",
        "_G.during_init = #_G.notes",
    }, init)
    local out = vim.system({
        "nvim",
        "--headless",
        "-i",
        "NONE",
        "-n",
        "-u",
        init,
        "-c",
        -- -c runs before VimEnter, so wait one more tick for the warning scheduled from it.
        "lua vim.schedule(function() vim.schedule(function() io.stdout:write(_G.during_init .. ' ' .. #_G.notes .. '\\n'); vim.cmd('qa!') end) end)",
    }, { text = true }):wait(10000)
    vim.fn.delete(init)
    eq(vim.trim(out.stdout or ""), "0 1", "warnings during init / after VimEnter (stderr: " .. (out.stderr or "") .. ")")
end)

vim.notify = notify
print(string.format("Entry rendering: %d passed, %d failed", passed, failed))
if failed > 0 then
    vim.cmd("cquit 1")
end
vim.cmd("qall!")
