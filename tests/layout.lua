-- Run from the repository root: nvim --headless -u NONE -l tests/layout.lua
--
-- Covers switching the chat layout with `pi.set_layout` / `pi.toggle_layout`:
-- which window stays current, which mode it's in, where the prompt cursor
-- ends up, and that existing commands still focus the prompt.
--
-- Each scenario runs in a child `nvim --embed`, because insert mode is only
-- observable once the editor processes input. The child stubs descriptor
-- resolution and the RPC process, so no real pi starts.

local root = vim.fn.getcwd()
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

--- Child setup: load pi.nvim with stubbed descriptor resolution and RPC, and
--- start a session with its chat shown in `layout`.
local CHILD_SETUP = [[
local root, layout = ...
vim.opt.runtimepath:append(root)
vim.o.swapfile = false

_G.T = { dispatched = 0, events = {} }

local Descriptor = require("pi.execution.descriptor")
Descriptor.resolve = function(workspace, done)
    done({ kind = "local" })
end

local Rpc = require("pi.rpc")
Rpc.new = function(tab)
    local rpc = { _tab = tab, _running = false }
    function rpc:start()
        self._running = true
        return true
    end
    function rpc:is_running()
        return self._running
    end
    function rpc:set_handler(fn) end
    function rpc:send(cmd, cb)
        if cb and (cmd.type == "get_commands" or cmd.type == "get_state") then
            vim.schedule(function()
                cb({ success = true, data = cmd.type == "get_commands" and { commands = {} } or {} })
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

-- Count attention dispatches instead of opening dialogs.
require("pi.attention").open_next_for_tab = function()
    T.dispatched = T.dispatched + 1
    return true
end

require("pi").setup({ layout = { default = layout } })

T.outside = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "outside one", "outside two" })
require("pi").show()

---@return pi.Chat
function T.chat()
    return require("pi.sessions.manager").get().chat
end

--- Window IDs of the chat, by kind.
function T.wins()
    local layout = T.chat()._layout
    return { history = layout:history_win(), prompt = layout:prompt_win(), attachments = layout:attachments_win() }
end

function T.state()
    local chat = T.chat()
    local pwin = chat:prompt_win()
    return {
        layout = chat:layout(),
        visible = chat:is_visible(),
        current = vim.api.nvim_get_current_win(),
        kind = chat:focus_kind(),
        cursor = vim.api.nvim_win_get_cursor(0),
        prompt_cursor = pwin and vim.api.nvim_win_get_cursor(pwin) or nil,
        prompt_lines = vim.api.nvim_buf_get_lines(chat:prompt_buf(), 0, -1, false),
    }
end

--- Leave the chat for the outside window, in normal mode.
function T.go_outside()
    vim.api.nvim_set_current_win(T.outside)
end

function T.set_prompt(lines, cursor)
    local chat = T.chat()
    vim.api.nvim_buf_set_lines(chat:prompt_buf(), 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(chat:prompt_win(), cursor)
end

--- Count WinEnter events on the outside window.
function T.watch_outside()
    T.events = {}
    vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
            if vim.api.nvim_get_current_win() == T.outside then
                table.insert(T.events, "WinEnter outside")
            end
        end,
    })
end

-- Insert-mode mappings that switch layouts, like a picker or a user mapping would.
vim.keymap.set("i", "<F2>", "<Cmd>lua require('pi').toggle_layout()<CR>")
vim.keymap.set("i", "<F3>", "<Cmd>lua require('pi').toggle_layout({ focus = false })<CR>")
]]

---@class LayoutTestChild
---@field chan integer
local Child = {}
Child.__index = Child

---@param layout "side"|"float"
---@return LayoutTestChild
function Child.new(layout)
    local chan = vim.fn.jobstart({ "nvim", "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n" }, {
        rpc = true,
        cwd = root,
    })
    assert(chan > 0, "failed to start child nvim")
    local self = setmetatable({ chan = chan }, Child)
    self:lua("vim.o.columns = 120; vim.o.lines = 40")
    self:lua(CHILD_SETUP, root, layout)
    self:settle()
    -- Start every scenario in the outside window, in normal mode.
    self:input("<Esc>")
    self:lua("T.go_outside()")
    self:settle()
    return self
end

---@param code string
---@param ... any
---@return any
function Child:lua(code, ...)
    return vim.rpcrequest(self.chan, "nvim_exec_lua", code, { ... })
end

---@return string
function Child:mode()
    return vim.rpcrequest(self.chan, "nvim_get_mode").mode
end

---@param keys string
function Child:input(keys)
    vim.rpcrequest(self.chan, "nvim_input", keys)
end

--- Let the child run its scheduled callbacks and pending input.
function Child:settle()
    for _ = 1, 6 do
        vim.wait(20, function()
            return false
        end)
        self:lua("return true")
    end
end

function Child:state()
    return self:lua("return T.state()")
end

function Child:close()
    vim.fn.jobstop(self.chan)
end

---@param name string
---@param layout "side"|"float"
---@param fn fun(child: LayoutTestChild)
local function test(name, layout, fn)
    local child = Child.new(layout)
    local ok, err = xpcall(fn, debug.traceback, child)
    child:close()
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. "\n" .. err)
    end
end

---@param child LayoutTestChild
---@param what string
local function assert_prompt_insert(child, what)
    local state = child:state()
    eq(state.kind, "prompt", what .. ": current chat window")
    eq(child:mode(), "i", what .. ": mode")
end

-- 1, 2, 17: focus = false from an ordinary window.
for _, case in ipairs({
    { from = "float", to = "side", call = "require('pi').set_layout('side', { focus = false })" },
    { from = "side", to = "float", call = "require('pi').set_layout('float', { focus = false })" },
    { from = "float", to = "side", call = "require('pi').toggle_layout({ focus = false })" },
    { from = "side", to = "float", call = "require('pi').toggle_layout({ focus = false })" },
}) do
    test(case.from .. " -> " .. case.to .. " (" .. case.call .. "): outside window keeps focus", case.from, function(child)
        child:lua("T.set_prompt({ 'hello world' }, { 1, 4 })")
        child:lua("vim.api.nvim_win_set_cursor(T.outside, { 2, 3 })")
        local before = child:state()
        eq(before.layout, case.from, "starting layout")
        child:lua(case.call)
        child:settle()
        local after = child:state()
        eq(after.layout, case.to, "layout")
        eq(after.visible, true, "visible")
        eq(after.current, before.current, "current window")
        eq(after.cursor, { 2, 3 }, "outside cursor")
        eq(child:mode(), "n", "mode")
        eq(after.prompt_cursor, { 1, 4 }, "prompt cursor")
        local wins = child:lua("return T.wins()")
        assert(wins.history and wins.prompt, "chat windows missing")
    end)
end

-- 3: focus = false from history and from the prompt in normal mode.
for _, kind in ipairs({ "history", "prompt" }) do
    test("focus = false from " .. kind .. " (normal mode): same kind stays current", "float", function(child)
        child:lua("T.set_prompt({ 'hello world' }, { 1, 4 })")
        child:lua("vim.api.nvim_set_current_win(T.wins()[...])", kind)
        child:settle()
        child:input("<Esc>")
        child:settle()
        local before = child:state()
        child:lua("require('pi').set_layout('side', { focus = false })")
        child:settle()
        local after = child:state()
        eq(after.layout, "side", "layout")
        eq(after.kind, kind, "current chat window")
        assert(after.current ~= before.current, "window was not rebuilt")
        eq(after.cursor, before.cursor, "cursor")
        eq(child:mode(), "n", "mode")
    end)
end

-- 4: toggle_layout({ on_done }) from the prompt, normal mode.
for _, case in ipairs({
    { line = "abcdef", col = 2, typed = "abcXdef", what = "mid-line" },
    { line = "abcdef", col = 5, typed = "abcdefX", what = "end of line" },
}) do
    test("toggle_layout({ on_done }) from prompt, normal mode, " .. case.what, "float", function(child)
        child:lua("vim.api.nvim_set_current_win(T.wins().prompt)")
        child:settle()
        child:input("<Esc>")
        child:settle()
        child:lua("local line, col = ...; T.set_prompt({ line }, { 1, col })", case.line, case.col)
        child:lua("require('pi').toggle_layout({ on_done = function(l) T.done = l end })")
        child:settle()
        eq(child:lua("return T.done"), "side", "on_done argument")
        eq(child:lua("return T.chat():layout()"), "side", "layout")
        assert_prompt_insert(child, "after toggle")
        child:input("X")
        child:settle()
        eq(child:state().prompt_lines, { case.typed }, "typed position")
    end)
end

-- 4: toggle_layout() from an insert-mode <Cmd> mapping in the prompt.
-- 13: the same with focus = false.
for _, key in ipairs({ "<F2>", "<F3>" }) do
    for _, case in ipairs({
        { col = 3, typed = "abcXdef", what = "mid-line" },
        { col = 5, typed = "abcdeXf", what = "before the last character" },
        { col = 6, typed = "abcdefX", what = "end of line" },
    }) do
        test("insert-mode " .. key .. " from prompt, " .. case.what, "float", function(child)
            child:lua("vim.api.nvim_set_current_win(T.wins().prompt)")
            child:settle()
            child:lua("T.set_prompt({ 'abcdef' }, { 1, select(1, ...) })", case.col)
            eq(child:mode(), "i", "starting mode")
            child:input(key)
            child:settle()
            eq(child:lua("return T.chat():layout()"), "side", "layout")
            assert_prompt_insert(child, "after switch")
            child:input("X")
            child:settle()
            eq(child:state().prompt_lines, { case.typed }, "typed position")
        end)
    end
end

-- 5: existing commands still focus the prompt.
test(":PiToggleLayout from an ordinary window focuses the prompt", "side", function(child)
    child:lua("vim.cmd('PiToggleLayout')")
    child:settle()
    eq(child:lua("return T.chat():layout()"), "float", "layout")
    assert_prompt_insert(child, ":PiToggleLayout")
end)

test(":Pi layout=float from an ordinary window focuses the prompt", "side", function(child)
    child:lua("vim.cmd('Pi layout=float')")
    child:settle()
    eq(child:lua("return T.chat():layout()"), "float", "layout")
    assert_prompt_insert(child, ":Pi layout=float")
end)

-- 6, 9: hidden chat.
for _, focus in ipairs({ false, true }) do
    test("hidden chat, focus = " .. tostring(focus), "float", function(child)
        child:lua("T.chat():hide()")
        child:settle()
        local before = child:state()
        eq(before.visible, false, "hidden")
        child:lua("require('pi').set_layout('side', { focus = ... })", focus)
        child:settle()
        local after = child:state()
        eq(after.visible, true, "visible")
        eq(after.layout, "side", "layout")
        if focus then
            assert_prompt_insert(child, "hidden chat")
        else
            eq(after.current, before.current, "current window")
            eq(child:mode(), "n", "mode")
        end
    end)
end

-- 7, 10: already in the requested layout.
test("same layout, focus = false: nothing changes", "side", function(child)
    local wins = child:lua("return T.wins()")
    local before = child:state()
    child:lua("require('pi').set_layout('side', { focus = false, on_done = function(l) T.done = l end })")
    child:settle()
    eq(child:lua("return T.wins()"), wins, "window IDs")
    eq(child:state().current, before.current, "current window")
    eq(child:mode(), "n", "mode")
    eq(child:lua("return T.done"), "side", "on_done")
end)

test("same layout, focus = true from history: prompt focused", "side", function(child)
    local wins = child:lua("return T.wins()")
    child:lua("vim.api.nvim_set_current_win(T.wins().history)")
    child:settle()
    child:input("<Esc>")
    child:lua("vim.api.nvim_set_current_win(T.wins().history)")
    child:settle()
    child:lua("require('pi').set_layout('side')")
    child:settle()
    eq(child:lua("return T.wins()"), wins, "window IDs")
    assert_prompt_insert(child, "same layout")
end)

-- 8: attachments in the side layout.
test("side layout with attachments, focus = false", "float", function(child)
    local path = root .. "/tests/layout.lua"
    child:lua("T.chat()._attachments._items = { { path = ..., name = 'img.png' } }", path)
    child:lua("T.chat()._attachments:_update_buffer()")
    child:lua("T.go_outside()")
    child:settle()
    local before = child:state()
    child:lua("require('pi').set_layout('side', { focus = false })")
    child:settle()
    local wins = child:lua("return T.wins()")
    assert(wins.attachments, "attachments window missing")
    eq(child:state().current, before.current, "current window")
    eq(child:mode(), "n", "mode")
end)

-- 11: pi.show({ layout }) on a visible chat in the other layout.
test("pi.show({ layout }) switches and focuses the prompt", "float", function(child)
    child:lua("require('pi').show({ layout = 'side' })")
    child:settle()
    eq(child:lua("return T.chat():layout()"), "side", "layout")
    assert_prompt_insert(child, "pi.show")
end)

-- 12, 15: callers in insert mode, in a split and in a float, both directions.
for _, from in ipairs({ "float", "side" }) do
    local to = from == "float" and "side" or "float"
    for _, where in ipairs({ "split", "float" }) do
        for _, mode in ipairs({ "n", "i" }) do
            test(where .. " caller in mode " .. mode .. ", " .. from .. " -> " .. to, from, function(child)
                if where == "float" then
                    child:lua([[
                        local buf = vim.api.nvim_create_buf(false, true)
                        T.picker = vim.api.nvim_open_win(buf, true, {
                            relative = "editor", row = 2, col = 2, width = 30, height = 3, zindex = 50,
                        })
                    ]])
                end
                child:settle()
                if mode == "i" then
                    child:input("i")
                    child:settle()
                end
                local before = child:state()
                eq(child:mode(), mode, "starting mode")
                child:lua("require('pi').set_layout(..., { focus = false })", to)
                child:settle()
                local after = child:state()
                eq(after.layout, to, "layout")
                eq(after.current, before.current, "current window")
                eq(child:mode(), mode, "mode")
            end)
        end
    end
end

-- 14: attention handling.
test("toggle_layout() from an empty prompt dispatches pending attention", "float", function(child)
    child:lua("vim.api.nvim_set_current_win(T.wins().prompt)")
    child:settle()
    child:input("<Esc>")
    child:settle()
    child:lua("T.dispatched = 0")
    child:lua("require('pi').toggle_layout()")
    child:settle()
    eq(child:lua("return T.dispatched"), 1, "dispatches")
end)

test("focus = false from the prompt in insert mode doesn't dispatch attention", "float", function(child)
    child:lua("vim.api.nvim_set_current_win(T.wins().prompt)")
    child:settle()
    eq(child:mode(), "i", "starting mode")
    child:lua("T.dispatched = 0")
    child:input("<F3>")
    child:settle()
    eq(child:lua("return T.dispatched"), 0, "dispatches")
    assert_prompt_insert(child, "after switch")
end)

-- 16: no WinEnter on an outside window while switching from the prompt.
test("switching from the prompt never enters an outside window", "float", function(child)
    child:lua("vim.api.nvim_set_current_win(T.wins().prompt)")
    child:settle()
    child:lua("T.watch_outside()")
    child:lua("vim.cmd('PiToggleLayout')")
    child:settle()
    child:lua("require('pi').toggle_layout({ focus = false })")
    child:settle()
    eq(child:lua("return T.events"), {}, "outside WinEnter events")
    assert_prompt_insert(child, "after switches")
end)

-- 18: the old callback form is rejected.
test("toggle_layout(fn) raises an error and changes nothing", "float", function(child)
    local res = child:lua([[
        local ok, err = pcall(require('pi').toggle_layout, function() end)
        return { ok = ok, err = tostring(err) }
    ]])
    eq(res.ok, false, "pcall ok")
    assert(res.err:find("toggle_layout({ on_done = cb })", 1, true), "error message: " .. res.err)
    child:settle()
    eq(child:lua("return T.chat():layout()"), "float", "layout")
end)

test("set_layout with an unknown mode reports an error and changes nothing", "float", function(child)
    child:lua([[
        T.notes = {}
        vim.notify = function(msg, level) table.insert(T.notes, { msg, level }) end
        require('pi').set_layout('bottom', { focus = false })
    ]])
    child:settle()
    local notes = child:lua("return T.notes")
    eq(#notes, 1, "notifications")
    eq(notes[1][2], vim.log.levels.ERROR, "level")
    eq(child:lua("return T.chat():layout()"), "float", "layout")
end)

-- 19: pi.show() focusing an empty prompt runs attention handling.
for _, case in ipairs({ { draft = false, expected = 1 }, { draft = true, expected = 0 } }) do
    test("pi.show() from outside, draft = " .. tostring(case.draft) .. ": attention dispatch", "float", function(child)
        child:lua("T.chat():hide()")
        if case.draft then
            child:lua("vim.api.nvim_buf_set_lines(T.chat():prompt_buf(), 0, -1, false, { 'draft' })")
        end
        child:settle()
        child:lua("T.dispatched = 0")
        child:lua("require('pi').show()")
        child:settle()
        eq(child:lua("return T.dispatched"), case.expected, "dispatches")
    end)
end

-- Final review F1: an attention dialog opened on prompt focus keeps focus,
-- in normal mode, instead of being put into insert mode by the prompt.
for _, case in ipairs({
    { what = "pi.show() on a hidden chat", prep = "T.chat():hide()", call = "require('pi').show()" },
    { what = ":PiToggleLayout from outside", prep = "", call = "vim.cmd('PiToggleLayout')" },
}) do
    test(case.what .. ": a real attention dialog stays in normal mode", "float", function(child)
        child:lua(case.prep)
        child:settle()
        child:lua([[
            require("pi.attention").open_next_for_tab = function()
                if T.dialog_opened then
                    return false
                end
                T.dialog_opened = true
                require("pi.ui.dialog").confirm({ title = "Proceed?" }, function(ok)
                    T.answer = ok
                end)
                T.dialog_win = vim.api.nvim_get_current_win()
                return true
            end
        ]])
        child:lua(case.call)
        child:settle()
        eq(child:lua("return T.dialog_opened"), true, "dialog opened")
        eq(child:lua("return vim.api.nvim_get_current_win() == T.dialog_win"), true, "dialog window is current")
        eq(child:mode(), "n", "mode")
        child:input("y")
        child:settle()
        eq(child:lua("return T.answer"), true, "dialog answered with y")
    end)
end

local MENTION_FILE = root .. "/tests/layout.lua"
local MENTION = "@tests/layout.lua"

-- 20: send_mention inserts before focusing; cursor right after the mention.
test("send_mention on a hidden chat: mention first, no attention, cursor after it", "float", function(child)
    child:lua("T.chat():hide()")
    child:settle()
    child:lua("T.dispatched = 0")
    child:lua("require('pi').send_mention({ path = ... })", MENTION_FILE)
    child:settle()
    eq(child:lua("return T.dispatched"), 0, "dispatches")
    eq(child:state().prompt_lines, { MENTION .. " " }, "prompt text")
    assert_prompt_insert(child, "after send_mention")
    child:input("X")
    child:settle()
    eq(child:state().prompt_lines, { MENTION .. " X" }, "typed position")
end)

test("send_mention on a visible chat with a draft: inserted at the prompt cursor", "side", function(child)
    child:lua("T.set_prompt({ 'see and fix' }, { 1, 3 })")
    child:lua("T.go_outside()")
    child:settle()
    child:lua("T.dispatched = 0")
    child:lua("require('pi').send_mention({ path = ... })", MENTION_FILE)
    child:settle()
    eq(child:lua("return T.dispatched"), 0, "dispatches")
    eq(child:state().prompt_lines, { "see " .. MENTION .. " and fix" }, "prompt text")
    assert_prompt_insert(child, "after send_mention")
    child:input("X")
    child:settle()
    eq(child:state().prompt_lines, { "see " .. MENTION .. " Xand fix" }, "typed position")
end)

-- 21: send_mention without focus.
test("send_mention({ focus = false }) on a visible chat keeps the outside window", "side", function(child)
    local before = child:state()
    child:lua("require('pi').send_mention({ path = ... }, { focus = false })", MENTION_FILE)
    child:settle()
    local after = child:state()
    eq(after.prompt_lines, { MENTION .. " " }, "prompt text")
    eq(after.current, before.current, "current window")
    eq(child:mode(), "n", "mode")
    eq(after.prompt_cursor, { 1, #MENTION + 1 }, "prompt cursor")
end)

test("send_mention({ focus = false }) on a hidden chat opens it, as before", "float", function(child)
    child:lua("T.chat():hide()")
    child:settle()
    child:lua("T.dispatched = 0")
    child:lua("require('pi').send_mention({ path = ... }, { focus = false })", MENTION_FILE)
    child:settle()
    eq(child:lua("return T.dispatched"), 0, "dispatches")
    local state = child:state()
    eq(state.visible, true, "visible")
    eq(state.prompt_lines, { MENTION .. " " }, "prompt text")
    eq(state.kind, "prompt", "current chat window")
end)

print(string.format("Layout switching: %d passed, %d failed", passed, failed))
if failed > 0 then
    vim.cmd("cquit 1")
end
