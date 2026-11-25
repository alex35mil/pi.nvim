-- Run from the repository root: nvim --headless -u NONE -l tests/draft.lua
--
-- Covers prompt draft sync: `User PiDraftChanged` reports, `pi.set_draft`
-- replacements with "local edits win", and pi's `set_editor_text`.
--
-- Each scenario runs in a child `nvim --embed`, because typing and window
-- events are only observable once the editor processes input. The child stubs
-- descriptor resolution and the RPC process, so no real pi starts.

local root = vim.fn.getcwd()
local passed, failed = 0, 0

local DEBOUNCE_MS = 300

---@param actual any
---@param expected any
---@param what? string
local function eq(actual, expected, what)
    assert(
        vim.deep_equal(actual, expected),
        (what and (what .. ": ") or "") .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected)
    )
end

--- Child setup: load pi.nvim with stubbed descriptor resolution and RPC,
--- record every PiDraftChanged payload, and keep each session's RPC handler.
local CHILD_SETUP = [[
local root, debounce_ms = ...
vim.opt.runtimepath:append(root)
vim.o.swapfile = false

_G.T = { sent = {}, resolutions = {}, reports = {}, handlers = {}, rpcs = {} }

local Descriptor = require("pi.execution.descriptor")
Descriptor.resolve = function(workspace, done)
    table.insert(T.resolutions, done)
end

local Rpc = require("pi.rpc")
Rpc.new = function(tab)
    local rpc = { _tab = tab, _running = false }
    T.rpcs[tab] = rpc
    function rpc:start()
        self._running = true
        return true
    end
    function rpc:is_running()
        return self._running
    end
    function rpc:set_handler(fn)
        T.handlers[tab] = fn
    end
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

require("pi").setup({ draft = { debounce_ms = debounce_ms } })

vim.api.nvim_create_autocmd("User", {
    pattern = "PiDraftChanged",
    callback = function(ev)
        table.insert(T.reports, ev.data)
    end,
})

--- Start a session in the current tab and show its chat.
function T.start()
    require("pi").show()
    vim.wait(50, function() return #T.resolutions > 0 end)
    local done = table.remove(T.resolutions, 1)
    assert(done, "no pending creation")
    done({ kind = "global" })
end

---@return pi.Chat
function T.chat()
    local s = assert(require("pi.sessions.manager").get(), "no session in current tab")
    return s.chat
end

function T.prompt_lines()
    return vim.api.nvim_buf_get_lines(T.chat():prompt_buf(), 0, -1, false)
end

function T.attachment_names()
    local out = {}
    for _, item in ipairs(T.chat()._attachments:snapshot()) do
        out[#out + 1] = item.name
    end
    return out
end

--- Reports, summarized: text and attachment names (data checked separately).
function T.summary()
    local out = {}
    for _, r in ipairs(T.reports) do
        local names = {}
        for _, a in ipairs(r.attachments) do
            names[#names + 1] = a.name
        end
        out[#out + 1] = { text = r.text, attachments = names }
    end
    return out
end

--- Write a small PNG-named file and return its path.
function T.image(name)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. name
    local f = assert(io.open(path, "wb"))
    f:write("img:" .. name)
    f:close()
    return path
end

---@param tab integer
---@param text string
function T.set_editor_text(tab, text)
    T.handlers[tab]({ type = "extension_ui_request", id = "x1", method = "set_editor_text", text = text })
end
]]

---@class DraftTestChild
---@field chan integer
local Child = {}
Child.__index = Child

---@return DraftTestChild
function Child.new()
    local chan = vim.fn.jobstart({ "nvim", "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n" }, {
        rpc = true,
        cwd = root,
    })
    assert(chan > 0, "failed to start child nvim")
    local self = setmetatable({ chan = chan }, Child)
    self:lua(CHILD_SETUP, root, DEBOUNCE_MS)
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

--- Let the child run its scheduled callbacks and pending input (~100 ms).
function Child:settle()
    for _ = 1, 5 do
        vim.wait(20, function()
            return false
        end)
        self:lua("return true")
    end
end

--- Wait past the debounce.
function Child:wait_debounce()
    vim.wait(DEBOUNCE_MS + 150, function()
        return false
    end)
    self:settle()
end

function Child:close()
    vim.fn.jobstop(self.chan)
end

---@param child DraftTestChild
local function start(child)
    child:lua("T.start()")
    child:settle()
    assert(child:lua("return T.chat():prompt_win() == vim.api.nvim_get_current_win()"), "prompt not focused")
end

---@param name string
---@param fn fun(child: DraftTestChild)
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

test("typing reports once after the debounce, not before", function(child)
    start(child)
    child:input("hel")
    child:settle()
    child:input("lo")
    child:settle()
    eq(child:lua("return #T.reports"), 0, "reports before the pause")
    child:wait_debounce()
    eq(child:lua("return T.summary()"), { { text = "hello", attachments = {} } }, "reports after the pause")
    local r = child:lua("return T.reports[1]")
    eq(r.tab, child:lua("return vim.api.nvim_get_current_tabpage()"), "tab")
    -- Nothing new: no second report.
    child:wait_debounce()
    eq(child:lua("return #T.reports"), 1, "reports after another pause")
end)

test("attachments report immediately, with their data", function(child)
    start(child)
    child:lua("T.chat():attach_image(T.image('a.png'))")
    eq(child:lua("return T.summary()"), { { text = "", attachments = { "a.png" } } }, "after add")
    local r = child:lua("return T.reports[1].attachments[1]")
    eq(r.mime, "image/png", "mime")
    eq(r.data, vim.base64.encode("img:a.png"), "data")
    child:lua("T.chat()._attachments:remove(1)")
    eq(child:lua("return T.summary()[2]"), { text = "", attachments = {} }, "after remove")
end)

test("leaving the prompt, hiding, toggling, and switching tabs report", function(child)
    start(child)
    child:input("one")
    child:settle()
    child:lua("vim.cmd('wincmd p')")
    child:settle()
    eq(child:lua("return T.summary()"), { { text = "one", attachments = {} } }, "after leaving")

    -- Leaving again with the same draft: no report.
    child:lua("vim.api.nvim_set_current_win(T.chat():prompt_win())")
    child:settle()
    child:lua("vim.cmd('wincmd p')")
    child:settle()
    eq(child:lua("return #T.reports"), 1, "reports after leaving again unchanged")

    -- A change while the prompt isn't current, then hide.
    child:lua("vim.api.nvim_buf_set_lines(T.chat():prompt_buf(), 0, -1, false, { 'two' })")
    child:lua("T.chat():hide()")
    eq(child:lua("return T.summary()[2]"), { text = "two", attachments = {} }, "after hide")

    -- toggle_chat hides through Chat:toggle.
    child:lua("require('pi').toggle_chat()")
    child:settle()
    child:lua("vim.api.nvim_buf_set_lines(T.chat():prompt_buf(), 0, -1, false, { 'three' })")
    child:lua("require('pi').toggle_chat()")
    eq(child:lua("return T.summary()[3]"), { text = "three", attachments = {} }, "after toggle_chat")

    -- Switching tabs from the prompt.
    child:lua("require('pi').toggle_chat()")
    child:settle()
    child:lua("vim.api.nvim_set_current_win(T.chat():prompt_win())")
    child:settle()
    child:input("<Esc>A four<Esc>")
    child:settle()
    child:lua("vim.cmd('tabnew')")
    child:settle()
    eq(child:lua("return T.summary()[4]"), { text = "three four", attachments = {} }, "after tab switch")
    eq(child:lua("return #T.reports"), 4, "report count")
end)

test("sending reports the empty draft once and still ends in insert mode", function(child)
    start(child)
    child:input("send me<Esc>")
    child:wait_debounce()
    eq(child:mode(), "n", "mode before sending")
    child:input("<CR>")
    child:settle()
    eq(
        child:lua("return T.summary()"),
        { { text = "send me", attachments = {} }, { text = "", attachments = {} } },
        "reports"
    )
    eq(child:mode(), "i", "mode after sending from normal mode")
    child:wait_debounce()
    eq(child:lua("return #T.reports"), 2, "no report after the send settles")

    -- A draft sent before its report: the empty draft equals the last report,
    -- so nothing changed for other clients.
    child:input("quick<CR>")
    child:settle()
    child:wait_debounce()
    eq(child:lua("return #T.reports"), 2, "reports after a quick send")
end)

test("a crash-recovered draft is reported when restored", function(child)
    start(child)
    child:lua("T.chat():attach_image(T.image('c.png'))")
    child:input("unsent")
    child:settle()
    local tab = child:lua("return vim.api.nvim_get_current_tabpage()")
    -- The process died; :PiStop keeps the draft for the next :Pi.
    child:lua("T.rpcs[...]._running = false", tab)
    child:lua("require('pi').stop()")
    child:settle()
    child:lua("T.reports = {}")
    child:lua("T.start()")
    child:settle()
    eq(child:lua("return T.prompt_lines()"), { "unsent" }, "restored text")
    eq(child:lua("return T.summary()"), { { text = "unsent", attachments = { "c.png" } } }, "reports")
    eq(child:lua("return T.reports[1].session_id == nil"), true, "session_id is nil before pi reports it")
end)

test("set_draft applies on an untouched draft, without focus change or echo", function(child)
    start(child)
    child:input("<Esc>")
    child:lua("vim.cmd('wincmd p')")
    child:settle()
    local win = child:lua("return vim.api.nvim_get_current_win()")
    local result = child:lua(
        [[return require('pi').set_draft(0, { text = 'from\nelsewhere', attachments = { { name = 'r.png', data = 'AAAA', mime = 'image/png' } } })]]
    )
    eq(result, { status = "applied" }, "result")
    child:settle()
    eq(child:lua("return T.prompt_lines()"), { "from", "elsewhere" }, "text")
    eq(child:lua("return T.attachment_names()"), { "r.png" }, "attachments")
    eq(child:lua("return vim.api.nvim_get_current_win()"), win, "current window")
    eq(child:mode(), "n", "mode")

    -- Replacing with no attachments closes the window without taking focus.
    eq(child:lua("return require('pi').set_draft(0, { text = 'bare' })"), { status = "applied" }, "second result")
    child:settle()
    eq(child:lua("return T.attachment_names()"), {}, "attachments after second")
    eq(child:lua("return vim.api.nvim_get_current_win()"), win, "current window after second")
    eq(child:mode(), "n", "mode after second")

    -- No echo, after the debounce or leaving the prompt.
    child:wait_debounce()
    child:lua("vim.api.nvim_set_current_win(T.chat():prompt_win())")
    child:settle()
    child:lua("vim.cmd('wincmd p')")
    child:settle()
    eq(child:lua("return #T.reports"), 0, "echoed reports")
end)

test("set_draft keeps the cursor of a focused prompt in insert mode", function(child)
    start(child)
    eq(child:mode(), "i", "mode")
    eq(child:lua("return require('pi').set_draft(0, { text = 'abc' })"), { status = "applied" }, "result")
    child:settle()
    eq(child:mode(), "i", "mode after")
    assert(child:lua("return T.chat():prompt_win() == vim.api.nvim_get_current_win()"), "prompt lost focus")
    eq(child:lua("return vim.api.nvim_win_get_cursor(0)"), { 1, 0 }, "cursor")
end)

test("set_draft refuses over unreported local edits", function(child)
    start(child)
    child:input("mine")
    child:settle()
    eq(child:lua("return require('pi').set_draft(0, { text = 'theirs' })"), { status = "local_edits" }, "result")
    eq(child:lua("return T.prompt_lines()"), { "mine" }, "text kept")
    -- Once reported, a replacement applies.
    child:wait_debounce()
    eq(child:lua("return T.summary()"), { { text = "mine", attachments = {} } }, "report")
    eq(child:lua("return require('pi').set_draft(0, { text = 'theirs' })"), { status = "applied" }, "after report")
    eq(child:lua("return T.prompt_lines()"), { "theirs" }, "text replaced")
end)

test("set_draft updates a hidden chat, shown on open", function(child)
    start(child)
    child:lua("T.chat():hide()")
    child:settle()
    eq(child:lua("return require('pi').set_draft(0, { text = 'while hidden' })"), { status = "applied" }, "result")
    eq(child:lua("return T.chat():is_visible()"), false, "still hidden")
    child:lua("require('pi').show()")
    child:settle()
    eq(child:lua("return T.prompt_lines()"), { "while hidden" }, "text on show")
    eq(child:lua("return #T.reports"), 0, "echoed reports")
end)

test("set_draft without a session; argument checks", function(child)
    eq(child:lua("return require('pi').set_draft(0, { text = 'x' })"), { status = "no_session" }, "no session")
    local err = child:lua("return select(2, pcall(require('pi').set_draft, 0, { text = 1 }))")
    assert(tostring(err):find("draft.text must be a string"), "text error: " .. tostring(err))
    err = child:lua("return select(2, pcall(require('pi').set_draft, 0, { text = 'x', attachments = { {} } }))")
    assert(err:find("attachments%[1%]"), "attachment error: " .. tostring(err))
    err = child:lua([[
        local result
        local t = vim.uv.new_timer()
        t:start(0, 0, function()
            result = select(2, pcall(require('pi').set_draft, 0, { text = 'x' }))
            t:close()
        end)
        vim.wait(500, function() return result ~= nil end)
        return result
    ]])
    assert(tostring(err):find("fast event"), "fast event error: " .. tostring(err))
end)

test("set_editor_text replaces only the text and reports it", function(child)
    start(child)
    child:lua("T.chat():attach_image(T.image('k.png'))")
    child:settle()
    child:lua("T.reports = {}")
    local tab = child:lua("return vim.api.nvim_get_current_tabpage()")
    child:lua("T.set_editor_text(...)", tab, "from pi")
    child:settle()
    eq(child:lua("return T.prompt_lines()"), { "from pi" }, "text")
    eq(child:lua("return T.attachment_names()"), { "k.png" }, "attachments kept")
    eq(child:lua("return T.summary()"), { { text = "from pi", attachments = { "k.png" } } }, "reports")

    -- Over unreported local edits it changes nothing and doesn't warn.
    child:input("<End> mine")
    child:settle()
    child:lua("T.notified = 0; local n = vim.notify; vim.notify = function(...) T.notified = T.notified + 1 return n(...) end")
    child:lua("T.set_editor_text(...)", tab, "overwrite")
    child:settle()
    eq(child:lua("return T.prompt_lines()"), { "from pi mine" }, "text kept")
    eq(child:lua("return T.notified"), 0, "notifications")
end)

test("each tab is its own draft source", function(child)
    start(child)
    local tab_a = child:lua("return vim.api.nvim_get_current_tabpage()")
    child:lua("vim.cmd('tabnew')")
    child:settle()
    start(child)
    local tab_b = child:lua("return vim.api.nvim_get_current_tabpage()")
    child:input("in b")
    child:settle()
    eq(child:lua("return require('pi').set_draft(...)", tab_a, { text = "to a" }), { status = "applied" }, "tab a")
    eq(child:lua("return require('pi').set_draft(...)", tab_b, { text = "to b" }), { status = "local_edits" }, "tab b")
    child:wait_debounce()
    local reports = child:lua("return T.reports")
    eq(#reports, 1, "reports")
    eq(reports[1].tab, tab_b, "reporting tab")
end)

print(("draft: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
