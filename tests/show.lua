-- Run from the repository root: nvim --headless -u NONE -l tests/show.lua
--
-- Each scenario runs in a child `nvim --embed`, because insert mode started by
-- `startinsert` is only observable once the editor processes input, which an
-- `-l` script never yields to. The child stubs descriptor resolution and the
-- RPC process, so no real pi starts.

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

--- Child setup: load pi.nvim with stubbed descriptor resolution and RPC.
local CHILD_SETUP = [[
local root = ...
vim.opt.runtimepath:append(root)
vim.o.swapfile = false

_G.T = { sent = {}, resolutions = {} }

local Descriptor = require("pi.execution.descriptor")
-- Hold each resolution so the test decides when and how creation finishes.
Descriptor.resolve = function(workspace, done)
    table.insert(T.resolutions, done)
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
        table.insert(T.sent, cmd.type)
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

require("pi").setup({})

--- Finish the oldest pending session creation.
---@param kind "local"|"cancelled"
function T.resolve(kind)
    local done = table.remove(T.resolutions, 1)
    assert(done, "no pending creation")
    done({ kind = kind })
end

---@return pi.Chat?
function T.chat()
    local s = require("pi.sessions.manager").get()
    return s and s.chat
end

---@param tab integer
---@return pi.Session?
function T.session_for(tab)
    return require("pi.sessions.manager").get_for_tab(tab)
end

--- Prompt state of the current tab's session.
function T.prompt_state()
    local chat = assert(T.chat(), "no session in current tab")
    local buf = chat:prompt_buf()
    local win = chat:prompt_win()
    return {
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        visible = win ~= nil,
        current = win ~= nil and vim.api.nvim_get_current_win() == win,
        cursor = win and vim.api.nvim_win_get_cursor(win) or nil,
    }
end

--- Messages that would submit text to pi.
function T.submissions()
    local out = {}
    for _, t in ipairs(T.sent) do
        if t == "prompt" or t == "steer" or t == "follow_up" then
            out[#out + 1] = t
        end
    end
    return out
end

--- Windows in a tab that show a pi chat buffer.
---@param tab integer
function T.pi_windows(tab)
    local Ft = require("pi.filetypes")
    local count = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
        if ft == Ft.prompt or ft == Ft.history then
            count = count + 1
        end
    end
    return count
end
]]

---@class ShowTestChild
---@field chan integer
local Child = {}
Child.__index = Child

---@return ShowTestChild
function Child.new()
    local chan = vim.fn.jobstart({ "nvim", "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n" }, {
        rpc = true,
        cwd = root,
    })
    assert(chan > 0, "failed to start child nvim")
    local self = setmetatable({ chan = chan }, Child)
    self:lua(CHILD_SETUP, root)
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
    for _ = 1, 5 do
        vim.wait(20, function()
            return false
        end)
        -- A request round-trip makes the child process its event loop.
        self:lua("return true")
    end
end

function Child:close()
    vim.fn.jobstop(self.chan)
end

---@param name string
---@param fn fun(child: ShowTestChild)
local function test(name, fn)
    local child = Child.new()
    local ok, err = xpcall(fn, debug.traceback, child)
    child:close()
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. "\n" .. err)
    end
end

--- Assert the prompt is current in insert mode with the cursor after `last_line`,
--- and that typing continues right there.
---@param child ShowTestChild
---@param row integer
---@param last_line string
local function assert_focused_at_end(child, row, last_line)
    local state = child:lua("return T.prompt_state()")
    assert(state.current, "prompt window is not current")
    eq(child:mode(), "i", "mode")
    eq(state.cursor, { row, #last_line }, "cursor")
    child:input("X")
    child:settle()
    state = child:lua("return T.prompt_state()")
    eq(state.lines[row], last_line .. "X", "typed character position")
end

local KICKOFF = "/task #12 (Epic #5) "

for _, draft in ipairs({ KICKOFF, "/task #12" }) do
    test("new session: draft " .. vim.inspect(draft), function(child)
        child:lua("require('pi').show({ layout = 'float', draft = ... })", draft)
        child:settle()
        eq(child:lua("return T.chat() == nil"), true, "session exists before creation finished")
        child:lua("T.resolve('local')")
        child:settle()
        local state = child:lua("return T.prompt_state()")
        eq(state.lines, { draft }, "prompt text")
        eq(child:lua("return T.chat():layout()"), "float", "layout")
        assert_focused_at_end(child, 1, draft)
        eq(child:lua("return T.submissions()"), {}, "submitted messages")
    end)
end

test("existing session: draft fills the running session's prompt", function(child)
    child:lua("require('pi').show()")
    child:settle()
    child:lua("T.resolve('local')")
    child:settle()
    -- Prompt already current and in insert mode.
    assert(child:lua("return T.prompt_state().current"), "prompt not focused after show()")
    child:lua("require('pi').show({ draft = ... })", KICKOFF)
    child:settle()
    eq(child:lua("return T.prompt_state().lines"), { KICKOFF }, "prompt text")
    assert_focused_at_end(child, 1, KICKOFF)
    eq(child:lua("return T.submissions()"), {}, "submitted messages")

    -- A later return to the prompt keeps the cursor where the user left it.
    child:input("<Esc>")
    child:settle()
    child:lua("vim.api.nvim_win_set_cursor(T.chat():prompt_win(), { 1, 3 })")
    child:lua("vim.cmd('wincmd p')")
    child:settle()
    child:lua("vim.api.nvim_set_current_win(T.chat():prompt_win())")
    child:settle()
    eq(child:mode(), "i", "mode after re-entry")
    eq(child:lua("return T.prompt_state().cursor"), { 1, 3 }, "cursor after re-entry")
end)

test("existing session hidden: draft shows the chat", function(child)
    child:lua("require('pi').show({ layout = 'side' })")
    child:settle()
    child:lua("T.resolve('local')")
    child:settle()
    child:lua("T.chat():hide()")
    child:settle()
    child:lua("require('pi').show({ layout = 'float', draft = ... })", KICKOFF)
    child:settle()
    eq(child:lua("return T.chat():layout()"), "float", "layout")
    assert_focused_at_end(child, 1, KICKOFF)
end)

test("existing draft: kept below the new draft", function(child)
    child:lua("require('pi').show()")
    child:settle()
    child:lua("T.resolve('local')")
    child:settle()
    child:input("typed already")
    child:settle()
    child:input("<Esc>")
    child:settle()
    child:lua("require('pi').show({ draft = ... })", KICKOFF)
    child:settle()
    eq(child:lua("return T.prompt_state().lines"), { KICKOFF, "", "typed already" }, "prompt text")
    assert_focused_at_end(child, 1, KICKOFF)
end)

test("multi-line draft: cursor at the end of its last line", function(child)
    child:lua("require('pi').show({ draft = 'first\\nsecond' })")
    child:settle()
    child:lua("T.resolve('local')")
    child:settle()
    eq(child:lua("return T.prompt_state().lines"), { "first", "second" }, "prompt text")
    assert_focused_at_end(child, 2, "second")
end)

test("cancelled creation: draft is discarded", function(child)
    child:lua("require('pi').show({ draft = ... })", KICKOFF)
    child:settle()
    child:lua("T.resolve('cancelled')")
    child:settle()
    eq(child:lua("return T.chat() == nil"), true, "session after cancel")
    eq(child:lua("return T.pi_windows(vim.api.nvim_get_current_tabpage())"), 0, "chat windows after cancel")

    child:lua("require('pi').show()")
    child:settle()
    child:lua("T.resolve('local')")
    child:settle()
    local state = child:lua("return T.prompt_state()")
    eq(state.lines, { "" }, "prompt text of the later session")
    assert(state.current, "prompt not focused")
end)

test("tab switch during creation: chat opens only in the requesting tab", function(child)
    local tab_a = child:lua("return vim.api.nvim_get_current_tabpage()")
    child:lua("require('pi').show({ layout = 'float', draft = ... })", KICKOFF)
    child:settle()
    child:lua("vim.cmd('tabnew')")
    child:settle()
    local tab_b = child:lua("return vim.api.nvim_get_current_tabpage()")
    child:lua("T.resolve('local')")
    child:settle()

    eq(child:lua("return vim.api.nvim_get_current_tabpage()"), tab_b, "current tab after creation")
    eq(child:lua("return T.pi_windows(...)", tab_b), 0, "chat windows in the other tab")
    eq(child:lua("return T.pi_windows(...)", tab_a), 0, "chat windows before returning")
    eq(child:lua("return T.session_for(...) ~= nil", tab_b), false, "session in the other tab")
    eq(
        child:lua("return vim.api.nvim_buf_get_lines(T.session_for(...).chat:prompt_buf(), 0, -1, false)", tab_a),
        { KICKOFF },
        "draft placed in the requesting tab's prompt"
    )
    eq(child:mode(), "n", "mode in the other tab")

    child:lua("vim.api.nvim_set_current_tabpage(...)", tab_a)
    child:settle()
    assert(child:lua("return T.pi_windows(...)", tab_a) > 0, "chat not shown after returning")
    eq(child:lua("return T.chat():layout()"), "float", "layout")
    assert_focused_at_end(child, 1, KICKOFF)
    eq(child:lua("return T.submissions()"), {}, "submitted messages")
end)

test("tab switch during creation: plain show() opens only in the requesting tab", function(child)
    local tab_a = child:lua("return vim.api.nvim_get_current_tabpage()")
    child:lua("require('pi').show()")
    child:settle()
    child:lua("vim.cmd('tabnew')")
    child:settle()
    local tab_b = child:lua("return vim.api.nvim_get_current_tabpage()")
    child:lua("T.resolve('local')")
    child:settle()
    eq(child:lua("return T.pi_windows(...)", tab_b), 0, "chat windows in the other tab")

    child:lua("vim.api.nvim_set_current_tabpage(...)", tab_a)
    child:settle()
    local state = child:lua("return T.prompt_state()")
    assert(state.current, "prompt not focused after returning")
    eq(child:mode(), "i", "mode")
end)

test("hiding cancels a deferred show", function(child)
    local tab_a = child:lua("return vim.api.nvim_get_current_tabpage()")
    child:lua("require('pi').show({ draft = ... })", KICKOFF)
    child:settle()
    child:lua("vim.cmd('tabnew')")
    child:settle()
    child:lua("T.resolve('local')")
    child:settle()
    child:lua("T.session_for(...).chat:hide()", tab_a)
    child:lua("vim.api.nvim_set_current_tabpage(...)", tab_a)
    child:settle()
    eq(child:lua("return T.pi_windows(...)", tab_a), 0, "chat windows after a hide")
end)

test("plain show(): unchanged", function(child)
    child:lua("require('pi').show()")
    child:settle()
    child:lua("T.resolve('local')")
    child:settle()
    local state = child:lua("return T.prompt_state()")
    eq(state.lines, { "" }, "prompt text")
    assert(state.current, "prompt not focused")
    eq(child:mode(), "i", "mode")
end)

print(string.format("Show regressions: %d passed, %d failed", passed, failed))
if failed > 0 then
    vim.cmd("cquit 1")
end
