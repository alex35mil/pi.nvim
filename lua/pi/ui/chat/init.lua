--- Chat UI orchestration — layout, window management, and wiring.

---@class pi.ChatAgent
---@field send fun(msg: pi.RpcCommand)

---@class pi.Chat
---@field _tab pi.TabId
---@field _agent pi.ChatAgent
---@field _layout pi.ChatLayout
---@field _history pi.ChatHistory
---@field _prompt pi.ChatPrompt
---@field _keymaps_set boolean
---@field _streaming boolean
---@field _steer_delivered boolean
---@field _active_verb string?
---@field _done_verb string?
---@field _last_turn_stop_reason "aborted"|"error"|nil
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
    self._tab = tab
    self._agent = agent
    self._attachments = Attachments.new()
    self._prompt = Prompt.new(tab, self._attachments)
    self._history = History.new(tab)
    self._layout = Layout.new(mode, self._history, self._prompt, self._attachments)
    self._keymaps_set = false
    self._streaming = false
    self._steer_delivered = false
    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil
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

    -- Auto-redirect when entering history from outside in side layout only.
    vim.api.nvim_create_autocmd("WinEnter", {
        buffer = hbuf,
        callback = function()
            if self._layout:mode() == "float" then
                return
            end

            local pwin = self._layout:prompt_win()
            local prev = vim.fn.win_getid(vim.fn.winnr("#"))
            if prev == pwin then
                return
            end

            local entered_win = vim.api.nvim_get_current_win()
            vim.schedule(function()
                if self._layout:mode() == "float" then
                    return
                end
                if vim.api.nvim_get_current_win() ~= entered_win then
                    return
                end
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
                self:_auto_dispatch_attention_on_prompt_focus()
                if vim.api.nvim_get_current_buf() ~= pbuf then
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

    -- Follow-up: queued until agent finishes
    vim.keymap.set("n", "<A-CR>", function()
        self:submit_follow_up()
    end, { buffer = pbuf, desc = "Submit π follow-up" })

    vim.keymap.set("i", "<A-CR>", function()
        self:submit_follow_up()
    end, { buffer = pbuf, desc = "Submit π follow-up" })

    -- New line
    -- TODO?: Should be configurable?
    vim.keymap.set("i", "<S-CR>", function()
        vim.api.nvim_put({ "", "" }, "c", false, true)
    end, { buffer = pbuf, desc = "New line" })

    -- Toggle collapsible blocks (system preamble, tool blocks)
    vim.keymap.set("n", "<Tab>", function()
        if self._history:toggle_startup_block() then
            return
        elseif self._history:toggle_tool_block() then
            return
        end
    end, { buffer = hbuf, desc = "Toggle block under cursor" })
end

---@class pi.ChatShowOpts
---@field loading? boolean Show "Loading session…" placeholder

---@param opts? pi.ChatShowOpts
function Chat:show(opts)
    if not self._layout:show() then
        -- already shown
        self:refresh_prompt_attention()
        return
    end
    self:_set_keymaps()
    if opts and opts.loading then
        self:show_loading()
    else
        -- Render the welcome header with loading hint until startup data arrives.
        self._history:show_loading_startup()
    end
    self:refresh_prompt_attention()
    self._prompt:focus()
end

--- Show a loading placeholder on the empty history buffer.
function Chat:show_loading()
    local icon = " " .. Config.options.ui.labels.agent_response .. " "
    self._history:show_loading_placeholder({
        {
            { icon, "PiAgentResponseLabel" },
            { "  Loading session…", "PiWelcomeHint" },
        },
    })
end

function Chat:hide()
    self._layout:hide()
end

function Chat:toggle_layout()
    self._layout:toggle()
    self:refresh_prompt_attention()
    self:focus_prompt()
end

---@param mode pi.LayoutMode
function Chat:set_layout(mode)
    self._layout:set_mode(mode)
    self:refresh_prompt_attention()
end

---@return pi.LayoutMode
function Chat:layout()
    return self._layout:mode()
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

---@return "history"|"prompt"|"attachments"|nil
function Chat:focus_kind()
    local current_tab = vim.api.nvim_get_current_tabpage()
    local current_win = vim.api.nvim_get_current_win()
    if self._tab and self._tab ~= current_tab then
        return nil
    end

    local history_win = self._layout:history_win()
    if history_win and history_win == current_win then
        return "history"
    end

    local prompt_win = self._layout:prompt_win()
    if prompt_win and prompt_win == current_win then
        return "prompt"
    end

    local attachments_win = self._layout:attachments_win()
    if attachments_win and attachments_win == current_win then
        return "attachments"
    end

    return nil
end

---@return boolean
function Chat:has_focus()
    return self:focus_kind() ~= nil
end

---@return boolean
function Chat:has_prompt_focus()
    return self:focus_kind() == "prompt"
end

---@return boolean
function Chat:has_draft()
    return self._prompt:text() ~= "" or self._attachments:count() > 0
end

---@return boolean opened
function Chat:_auto_dispatch_attention_on_prompt_focus()
    local attention_config = Config.options.ui.attention
    if not attention_config or not attention_config.auto_open_on_prompt_focus then
        return false
    end
    if not self:has_prompt_focus() or self:has_draft() then
        return false
    end
    return require("pi.attention").open_next_for_tab(self._tab)
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

--- Submit the prompt. When streaming, sends as a steer (interrupt); otherwise regular prompt.
function Chat:submit()
    self:_send_message(self._streaming and "steer" or nil)
end

--- Submit the prompt as a follow-up. When streaming, queued until agent finishes;
--- otherwise sends as a regular prompt.
function Chat:submit_follow_up()
    self:_send_message(self._streaming and "follow_up" or nil)
end

---@return boolean
function Chat:is_streaming()
    return self._streaming
end

--- Send the current prompt contents as a message.
--- When queue_type is set, the message is added to the pending queue (virtual text)
--- instead of the chat history. It moves to the history when `message_start` arrives.
---@param queue_type "steer"|"follow_up"|nil
function Chat:_send_message(queue_type)
    local text = self._prompt:text()

    if text == "" and self._attachments:count() == 0 then
        return
    end

    self._prompt:clear_text()

    local attachments = self._attachments:count() > 0 and self._attachments:get() or nil
    self._attachments:clear()

    local expanded = Mentions.expand(text)

    if queue_type then
        -- Queued message: show in pending area, render in history on delivery
        self._history:add_pending_queue_entry(queue_type, text, expanded, attachments and #attachments or nil)
    else
        -- Immediate: render in history now
        self._history:add_user_message(text, nil, attachments and #attachments or nil)
    end

    ---@type pi.RpcCommand
    local cmd
    if queue_type == "steer" then
        cmd = { type = "steer", message = expanded }
    elseif queue_type == "follow_up" then
        cmd = { type = "follow_up", message = expanded }
    else
        cmd = { type = "prompt", message = expanded }
    end
    if attachments and #attachments > 0 then
        cmd.images = attachments
    end

    self._agent.send(cmd)
end

---@return string?
function Chat:active_verb()
    return self._active_verb
end

---@param status pi.Status?
function Chat:set_status(status)
    self._history:set_status(status)
end

---@param msg string
---@param timestamp? number
---@param image_count? integer
function Chat:add_user_message(msg, timestamp, image_count)
    self._history:add_user_message(msg, timestamp, image_count)
end

---@param replaying boolean
function Chat:set_replaying(replaying)
    self._history._replaying = replaying
end

---@param timestamp? number
function Chat:on_agent_start(timestamp)
    self._streaming = true
    self._last_turn_stop_reason = nil
    local verbs = Config.random_verbs()
    self._active_verb = verbs[1]
    self._done_verb = verbs[2]
    self._history:on_agent_start(timestamp)
    self:set_status({ type = "agent", text = verbs[1] .. "…" })
end

---@param delta string
function Chat:on_text_delta(delta)
    self._history:on_text_delta(delta)
end

function Chat:on_agent_end()
    self._streaming = false
    self._steer_delivered = false
    -- Flush any remaining pending queue entries into the history.
    -- Normally they are moved on message_start, but if the agent ends
    -- without delivering them (e.g. abort), render them now so they
    -- don't silently vanish.
    for _, entry in ipairs(self._history:get_pending_queue()) do
        self._history:add_user_message(entry.text, nil, entry.image_count, entry.queue_type)
    end
    self._history:clear_pending_queue()

    local completion_text = self._done_verb
    local force_completion = false
    if self._last_turn_stop_reason == "aborted" then
        completion_text = "Aborted"
        force_completion = true
    elseif self._last_turn_stop_reason == "error" then
        completion_text = "Failed"
        force_completion = true
    end

    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil

    self._history:on_agent_end(completion_text, { force_completion = force_completion })
    self:set_status(nil)
end

--- Handle message_start events. When a user message arrives and matches
--- a pending queue entry, move it from the queue into the chat history.
---@param msg pi.RpcEvent
function Chat:on_message_start(msg)
    local message = msg.message
    if not message then
        return
    end

    if message.role == "user" then
        -- Extract text and attachments from the user message content
        local text = ""
        local image_count = 0
        if type(message.content) == "string" then
            text = message.content
        elseif type(message.content) == "table" then
            for _, part in ipairs(message.content) do
                if type(part) == "string" then
                    text = text .. part
                elseif type(part) == "table" and part.type == "text" then
                    text = text .. (part.text or "")
                elseif type(part) == "table" and part.type == "image" then
                    image_count = image_count + 1
                end
            end
        end
        local entry = self._history:remove_pending_queue_entry(text)
        if entry then
            self._steer_delivered = true
            self._history:add_user_message(
                entry.text,
                nil,
                image_count > 0 and image_count or entry.image_count,
                entry.queue_type
            )
        end
    elseif message.role == "assistant" and self._steer_delivered then
        -- After a steered user message is delivered, the agent starts a new
        -- assistant turn.  Add a fresh assistant header so tool calls and
        -- text don't look like they belong to the user.
        self._steer_delivered = false
        self._history:on_agent_start(message.timestamp)
    end
end

--- Handle message_end events.  When an assistant message ends with
--- stopReason "aborted" or "error", mark all pending tool blocks as
--- errored so they don't hang open forever.
--- Also updates status line context usage from assistant message usage.
---@param msg pi.RpcEvent
function Chat:on_message_end(msg)
    local message = msg.message
    if not message or message.role ~= "assistant" then
        return
    end

    local stop = message.stopReason

    -- Accumulate usage stats (skip aborted/errored messages —
    -- they may have zero or stale usage, matching TUI's estimateContextTokens).
    if stop ~= "aborted" and stop ~= "error" and type(message.usage) == "table" then
        self._prompt:statusline():add_usage(message.usage)
    end

    if stop == "aborted" or stop == "error" then
        self._last_turn_stop_reason = stop

        local error_message
        if stop == "aborted" then
            error_message = "[aborted] Operation aborted"
        else
            error_message = message.errorMessage or "Error"
        end
        self._history:mark_pending_tools_errored(error_message)

        local has_tool_calls = false
        if type(message.content) == "table" then
            for _, part in ipairs(message.content) do
                if type(part) == "table" and part.type == "toolCall" then
                    has_tool_calls = true
                    break
                end
            end
        end
        if stop == "error" and not has_tool_calls then
            self._history:on_error(error_message)
        end
    end
end

--- Update status line state (model, thinking level) from get_state response.
---@param data table
function Chat:update_state(data)
    self._prompt:statusline():update_state(data)
end

--- Accumulate usage stats on the status line (e.g. after session replay).
---@param usage table
function Chat:add_usage(usage)
    self._prompt:statusline():add_usage(usage)
end

--- Set or clear an extension status value on the status line.
---@param key string
---@param value string? nil to clear
function Chat:set_extension_status(key, value)
    self._prompt:statusline():set_extension_status(key, value)
end

--- Render a custom block inline in the chat history.
---@param block pi.CustomBlock
function Chat:append_custom_block(block)
    self._history:append_custom_block(block)
end

--- Re-render the prompt status line.
function Chat:render_statusline()
    self._prompt:statusline():render()
end

--- Refresh prompt title styling when attention state changes.
function Chat:refresh_prompt_attention()
    self._layout:refresh_prompt_attention(require("pi.attention").has_attention(self._tab))
end

--- Reset status line usage stats (new session / clear).
function Chat:reset_usage()
    self._prompt:statusline():reset_usage()
end

---@param opts { sections: pi.StartupSection[], errors?: pi.SystemErrorEntry[] }
function Chat:show_startup_block(opts)
    self._history:show_startup_block(opts)
end

function Chat:clear_placeholder()
    self._history:clear_placeholder()
end

---@param error_message string
---@param opts? pi.ChatErrorOpts
function Chat:on_error(error_message, opts)
    self._history:on_error(error_message, opts)
end

---@param error_message string
---@param opts? pi.ChatErrorOpts
function Chat:on_system_error(error_message, opts)
    self._history:on_system_error(error_message, opts)
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

--- Toggle the startup block between compact and expanded.
---@param check_cursor? boolean default true; false skips cursor check (for commands)
---@return boolean toggled
function Chat:toggle_startup_block(check_cursor)
    return self._history:toggle_startup_block(check_cursor)
end

function Chat:clear()
    self._streaming = false
    self._steer_delivered = false
    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil
    self._history:clear()
    self._prompt:statusline():reset_usage()
end

--- Scroll the history window by a number of lines.
---@param direction "up"|"down"
---@param lines? integer lines to scroll (default 15)
function Chat:scroll_history(direction, lines)
    self._history:scroll(direction, lines)
end

--- Scroll the history window to the bottom (most recent message).
function Chat:scroll_history_to_bottom()
    self._history:scroll_to_bottom()
end

--- Scroll the history window to the start of the most recent agent response.
function Chat:scroll_history_to_last_agent_response()
    self._history:scroll_to_last_agent_response()
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
