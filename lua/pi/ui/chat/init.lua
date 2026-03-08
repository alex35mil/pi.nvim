--- Chat UI orchestration — layout, window management, and wiring.

---@class pi.ChatAgent
---@field send fun(msg: pi.RpcCommand)

---@class pi.Chat
---@field _agent pi.ChatAgent
---@field _layout pi.ChatLayout
---@field _history pi.ChatHistory
---@field _prompt pi.ChatPrompt
---@field _keymaps_set boolean
---@field _active_verb string?
---@field _done_verb string?
---@field _attachments pi.ChatAttachments
local Chat = {}
Chat.__index = Chat

local Config = require("pi.config")
local Layout = require("pi.ui.chat.layout")
local History = require("pi.ui.chat.history")
local Prompt = require("pi.ui.chat.prompt")
local Attachments = require("pi.ui.chat.attachments")
local Mentions = require("pi.ui.chat.mentions")

---@param tab pi.TabId
---@param mode pi.LayoutMode
---@param agent pi.ChatAgent
---@return pi.Chat
function Chat.new(tab, mode, agent)
    local self = setmetatable({}, Chat)
    self._agent = agent
    self._attachments = Attachments.new()
    self._prompt = Prompt.new(tab, self._attachments)
    self._history = History.new(tab)
    self._layout = Layout.new(mode, self._history, self._prompt, self._attachments)
    self._keymaps_set = false
    self._active_verb = nil
    self._done_verb = nil
    return self
end

function Chat:_set_keymaps()
    if self._keymaps_set then
        return
    end
    self._keymaps_set = true

    local hbuf = self._history:buf()
    local pbuf = self._prompt:buf()

    -- Redirect insert-mode keys from history -> prompt
    for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "c", "C" }) do
        vim.keymap.set("n", key, function()
            self:ensure_shown_and_focus_prompt()
        end, { buffer = hbuf, desc = "Redirect to π prompt" })
    end

    -- Auto-redirect when entering history from outside
    vim.api.nvim_create_autocmd("WinEnter", {
        buffer = hbuf,
        callback = function()
            local pwin = self._layout:prompt_win()
            local prev = vim.fn.win_getid(vim.fn.winnr("#"))
            if prev == pwin then
                return
            end
            vim.schedule(function()
                if pwin and vim.api.nvim_win_is_valid(pwin) then
                    vim.api.nvim_set_current_win(pwin)
                    vim.cmd("startinsert")
                end
            end)
        end,
    })

    -- Auto-enter insert mode when focusing the prompt from outside
    vim.api.nvim_create_autocmd("WinEnter", {
        buffer = pbuf,
        callback = function()
            vim.schedule(function()
                -- Guard: by the time this runs, focus may have moved elsewhere
                local buf = vim.api.nvim_get_current_buf()
                if buf ~= pbuf then
                    return
                end
                if vim.api.nvim_get_mode().mode ~= "i" then
                    vim.cmd("startinsert")
                end
            end)
        end,
    })

    -- Submit keymaps on prompt
    vim.keymap.set("n", "<CR>", function()
        self:submit()
    end, { buffer = pbuf, desc = "Submit π prompt" })

    vim.keymap.set("i", "<CR>", function()
        self:submit()
    end, { buffer = pbuf, desc = "Submit π prompt" })

    -- New line
    -- TODO?: Should be configurable?
    vim.keymap.set("i", "<S-CR>", function()
        vim.api.nvim_put({ "", "" }, "c", false, true)
    end, { buffer = pbuf, desc = "New line" })
end

function Chat:show()
    if not self._layout:show() then
        -- already shown
        return
    end
    self:_set_keymaps()
    self._prompt:focus()
end

function Chat:hide()
    self._layout:hide()
end

function Chat:toggle_layout()
    self._layout:toggle()
    self:focus_prompt()
end

---@param mode pi.LayoutMode
function Chat:set_layout(mode)
    self._layout:set_mode(mode)
end

---@return boolean
function Chat:is_visible()
    return self._layout:is_visible()
end

---@return integer
function Chat:prompt_buf()
    return self._prompt:buf()
end

---@return integer?
function Chat:prompt_win()
    return self._layout:prompt_win()
end

function Chat:focus_prompt()
    vim.schedule(function()
        self._prompt:focus()
    end)
end

function Chat:ensure_shown_and_focus_prompt()
    self:show()
    vim.schedule(function()
        self._prompt:focus()
    end)
end

function Chat:focus_history()
    local hwin = self._layout:history_win()
    if hwin then
        vim.api.nvim_set_current_win(hwin)
    end
end

function Chat:focus_attachments()
    local awin = self._layout:attachments_win()
    if awin then
        vim.api.nvim_set_current_win(awin)
    end
end

function Chat:toggle()
    if self._layout:is_visible() then
        self._layout:hide()
    else
        self:ensure_shown_and_focus_prompt()
    end
end

function Chat:submit()
    local text = self._prompt:text()

    if text == "" and self._attachments:count() == 0 then
        return
    end

    self._prompt:clear_text()

    local attachments = self._attachments:count() > 0 and self._attachments:get() or nil
    self._attachments:clear()

    local message = Mentions.expand(text)

    self._history:add_user_message(text, nil, attachments and #attachments or nil)

    ---@type pi.RpcCommand
    local cmd = {
        type = "prompt",
        message = message,
    }
    if attachments and #attachments > 0 then
        cmd.images = attachments
    end

    self._agent.send(cmd)
end

---@return string?
function Chat:active_verb()
    return self._active_verb
end

---@param text string?
function Chat:set_status(text)
    self._history:set_status(text)
end

---@param msg string
---@param timestamp? number
---@param image_count? integer
function Chat:add_user_message(msg, timestamp, image_count)
    self._history:add_user_message(msg, timestamp, image_count)
end

---@param timestamp? number
function Chat:on_agent_start(timestamp)
    local verbs = Config.random_verbs()
    self._active_verb = verbs[1]
    self._done_verb = verbs[2]
    self._history:on_agent_start(timestamp)
    self:set_status(verbs[1] .. "…")
end

---@param delta string
function Chat:on_text_delta(delta)
    self._history:on_text_delta(delta)
end

function Chat:on_agent_end()
    self._history:on_agent_end(self._done_verb)
    self:set_status(nil)
end

---@param error_message string
function Chat:on_error(error_message)
    self._history:on_error(error_message)
end

---@param text string
function Chat:on_stderr(text)
    self._history:on_stderr(text)
end

---@param tool_name string
---@param tool_call_id string
---@param tool_input? table
function Chat:on_tool_start(tool_name, tool_call_id, tool_input)
    self._history:on_tool_start(tool_name, tool_call_id, tool_input)
end

---@param tool_name string
---@param tool_call_id string
---@param result? table
---@param is_error? boolean
function Chat:on_tool_end(tool_name, tool_call_id, result, is_error)
    self._history:on_tool_end(tool_name, tool_call_id, result, is_error)
end

---@param tool_name string
---@param tool_call_id string
---@param msg table
function Chat:on_tool_update(tool_name, tool_call_id, msg)
    self._history:on_tool_update(tool_name, tool_call_id, msg)
end

function Chat:on_thinking_start()
    self._history:on_thinking_start()
end

---@param delta string
function Chat:on_thinking_delta(delta)
    self._history:on_thinking_delta(delta)
end

function Chat:on_thinking_end()
    self._history:on_thinking_end()
end

function Chat:toggle_thinking()
    self._history:toggle_thinking()
end

function Chat:clear()
    self._history:clear()
end

---@param path string
---@return boolean
function Chat:attach_image(path)
    return self._attachments:add_file(path)
end

---@return boolean
function Chat:attach_from_clipboard()
    return self._attachments:add_from_clipboard()
end

return Chat
