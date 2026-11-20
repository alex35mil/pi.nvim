-- Run from the repository root: nvim --headless -u NONE -l tests/focus_trap.lua
--
-- Covers keeping focus inside the chat in float layout: a normal window in the
-- chat's tab sends focus back to the chat window that had it last, while
-- floats, the command-line window, other tabs, the side layout, and a hidden
-- chat are left alone.
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
--- start a session with its chat shown in float layout.
local CHILD_SETUP = [[
local root = ...
vim.opt.runtimepath:append(root)
vim.o.swapfile = false

_G.T = {}

local Descriptor = require("pi.execution.descriptor")
Descriptor.resolve = function(workspace, done)
    done({ kind = "global" })
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

require("pi.attention").open_next_for_tab = function()
    return false
end

require("pi").setup({ layout = { default = "float" } })

T.outside = vim.api.nvim_get_current_win()
require("pi").show()

---@return pi.Chat
function T.chat()
    return require("pi.sessions.manager").get().chat
end

--- What the current window is: a chat window kind, "outside", "float", or "normal".
function T.where()
    local chat = T.chat()
    local kind = chat:focus_kind()
    if kind then
        return kind
    end
    local win = vim.api.nvim_get_current_win()
    if win == T.outside then
        return "outside"
    end
    if chat._zen._win == win then
        return "zen"
    end
    return vim.api.nvim_win_get_config(win).relative ~= "" and "float" or "normal"
end

--- Open a picker-like float and take focus.
function T.open_picker()
    local buf = vim.api.nvim_create_buf(false, true)
    T.picker = vim.api.nvim_open_win(buf, true, {
        relative = "editor", row = 2, col = 2, width = 30, height = 3, zindex = 50,
    })
end

--- Close it the way a Snacks picker does: focus its "main" window (a normal
--- window, since floats and non-file buffers are skipped), then close.
function T.close_picker()
    vim.api.nvim_set_current_win(T.outside)
    vim.api.nvim_win_close(T.picker, true)
end

function T.trap_count()
    local n = 0
    for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "WinEnter" })) do
        if a.desc == "Keep focus inside the π float chat" then
            n = n + 1
        end
    end
    return n
end
]]

---@class FocusTrapTestChild
---@field chan integer
local Child = {}
Child.__index = Child

---@return FocusTrapTestChild
function Child.new()
    local chan = vim.fn.jobstart({ "nvim", "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n" }, {
        rpc = true,
        cwd = root,
    })
    assert(chan > 0, "failed to start child nvim")
    local self = setmetatable({ chan = chan }, Child)
    self:lua("vim.o.columns = 120; vim.o.lines = 40")
    self:lua(CHILD_SETUP, root)
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

---@return string
function Child:where()
    return self:lua("return T.where()")
end

function Child:close()
    vim.fn.jobstop(self.chan)
end

---@param name string
---@param fn fun(child: FocusTrapTestChild)
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

test("a picker closing from the prompt returns to the prompt in insert mode", function(child)
    eq(child:where(), "prompt", "starting window")
    eq(child:mode(), "i", "starting mode")
    child:lua("T.open_picker()")
    child:settle()
    eq(child:where(), "float", "picker keeps focus")
    child:lua("T.close_picker()")
    child:settle()
    eq(child:where(), "prompt", "after close")
    eq(child:mode(), "i", "mode after close")
end)

test("a picker closing from the history returns to the history", function(child)
    child:input("<Esc>")
    child:lua("vim.api.nvim_set_current_win(T.chat()._layout:history_win())")
    child:settle()
    eq(child:where(), "history", "starting window")
    child:lua("T.open_picker()")
    child:settle()
    child:lua("T.close_picker()")
    child:settle()
    eq(child:where(), "history", "after close")
    eq(child:mode(), "n", "mode after close")
end)

test("window commands from the chat can't reach a normal window", function(child)
    child:lua("vim.cmd('wincmd t')")
    child:settle()
    eq(child:where(), "prompt", "after wincmd t")
    child:lua("vim.api.nvim_set_current_win(T.outside)")
    child:settle()
    eq(child:where(), "prompt", "after nvim_set_current_win")
end)

test("a split opened from the chat is left again", function(child)
    child:input("<Esc>")
    child:lua("vim.api.nvim_set_current_win(T.outside); vim.cmd('new')")
    child:settle()
    eq(child:where(), "prompt", "after split")
end)

test("the command-line window keeps focus", function(child)
    child:input("<Esc>q:")
    child:settle()
    eq(child:lua("return vim.fn.getcmdwintype()"), ":", "cmdwin type")
    child:input("<C-c><C-c>")
    child:settle()
    eq(child:where(), "prompt", "after leaving the cmdwin")
end)

test("another tab's windows aren't trapped", function(child)
    child:lua("vim.cmd('tabnew'); T.tab2 = vim.api.nvim_get_current_win(); vim.cmd('vsplit'); vim.cmd('wincmd p')")
    child:settle()
    eq(child:lua("return vim.api.nvim_get_current_win() == T.tab2"), true, "other tab window current")
    child:lua("vim.cmd('tabclose')")
    child:settle()
    eq(child:where(), "prompt", "back in the chat's tab")
end)

test("zen mode returns to the zen float", function(child)
    child:lua("T.chat():zen_toggle()")
    child:settle()
    eq(child:where(), "zen", "zen current")
    child:lua("vim.api.nvim_set_current_win(T.outside)")
    child:settle()
    eq(child:where(), "zen", "after leaving zen")
    child:lua("T.chat():zen_toggle()")
    child:settle()
    eq(child:where(), "prompt", "after zen exit")
end)

test("side layout and a hidden chat don't trap", function(child)
    child:lua("require('pi').set_layout('side')")
    child:settle()
    child:lua("vim.api.nvim_set_current_win(T.outside)")
    child:settle()
    eq(child:where(), "outside", "side layout")
    eq(child:lua("return T.trap_count()"), 0, "traps in side layout")
    child:lua("require('pi').set_layout('float')")
    child:settle()
    eq(child:lua("return T.trap_count()"), 1, "traps in float layout")
    child:lua("T.chat():hide()")
    child:settle()
    child:lua("vim.api.nvim_set_current_win(T.outside)")
    child:settle()
    eq(child:where(), "outside", "hidden chat")
    eq(child:lua("return T.trap_count()"), 0, "traps when hidden")
end)

test("switching to float from the side history keeps the history as the return target", function(child)
    child:lua("require('pi').set_layout('side')")
    child:settle()
    child:input("<Esc>")
    child:lua("vim.api.nvim_set_current_win(T.chat()._layout:history_win())")
    child:settle()
    child:lua("require('pi').set_layout('float', { focus = false })")
    child:settle()
    eq(child:where(), "history", "after switch")
    child:lua("vim.api.nvim_set_current_win(T.outside)")
    child:settle()
    eq(child:where(), "history", "after leaving")
end)

test("floats closed by hand drop the trap; reopening installs one", function(child)
    child:lua([[
        local layout = T.chat()._layout
        vim.api.nvim_win_close(layout:prompt_win(), true)
        vim.api.nvim_win_close(layout:history_win(), true)
    ]])
    child:settle()
    child:lua("vim.api.nvim_set_current_win(T.outside); vim.cmd('new'); vim.cmd('close')")
    child:settle()
    eq(child:where(), "outside", "after manual close")
    eq(child:lua("return T.trap_count()"), 0, "traps after manual close")
    child:lua("require('pi').show()")
    child:settle()
    eq(child:lua("return T.trap_count()"), 1, "traps after reopening")
end)

print(string.format("Float focus trap: %d passed, %d failed", passed, failed))
if failed > 0 then
    vim.cmd("cquit 1")
end
