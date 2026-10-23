--- Chat UI orchestration — layout, window management, and wiring.

---@class pi.ChatAgent
---@field send fun(msg: pi.RpcCommand, callback?: fun(response: pi.RpcEvent)): boolean?

---@class pi.SubmittedMessage
---@field text string
---@field expanded_text string
---@field attachments? pi.Attachment[]
---@field images? pi.RpcImageContent[]

---@class pi.ChatDraft
---@field text string
---@field attachments pi.Attachment[]

---@class pi.Chat
---@field _tab pi.TabId
---@field _agent pi.ChatAgent
---@field _layout pi.ChatLayout
---@field _history pi.ChatHistory
---@field _prompt pi.ChatPrompt
---@field _keymaps_set boolean
---@field _streaming boolean
---@field _replaying boolean
---@field _compacting boolean
---@field _assistant_block_open boolean
---@field _assistant_message_header_rendered boolean
---@field _assistant_tool_only_header_rendered boolean
---@field _assistant_message_timestamp number?
---@field _queue pi.BackendQueue
---@field _pending_submissions pi.SubmittedMessage[] Locally owned until an RPC response.
---@field _compaction_queue pi.CompactionQueuedMessage[]
---@field _compaction_prompt? pi.SubmittedMessage Leading handoff prompt awaiting a run.
---@field _active_verb string?
---@field _done_verb string?
---@field _last_turn_stop_reason "aborted"|"error"|nil
---@field _inflight_prompt? pi.SubmittedMessage
---@field _attachments pi.ChatAttachments
---@field _zen pi.Zen
local Chat = {}
Chat.__index = Chat

local Config = require("pi.config")
local Notify = require("pi.notify")
local CommandsCache = require("pi.cache.commands")
local SlashCommands = require("pi.commands").SlashCommands
local Layout = require("pi.ui.chat.layout")
local Attention = require("pi.attention")
local History = require("pi.ui.chat.history")
local Queue = require("pi.ui.chat.queue")
local Prompt = require("pi.ui.chat.prompt")
local Attachments = require("pi.ui.chat.attachments")
local Mentions = require("pi.ui.chat.mentions")
local Zen = require("pi.ui.chat.zen")

---@class pi.CompactionQueuedMessage
---@field mode "steer"|"follow_up"
---@field submission pi.SubmittedMessage

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
    self._replaying = false
    self._compacting = false
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = nil
    self._queue = Queue.new()
    self._pending_submissions = {}
    self._compaction_queue = {}
    self._compaction_prompt = nil
    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil
    self._inflight_prompt = nil
    self._zen = Zen.new(self._prompt)
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
                Attention.dismiss_notification(self._tab)
                self:_auto_dispatch_attention_on_prompt_focus()
                if vim.api.nvim_get_current_buf() ~= pbuf then
                    return
                end
                if vim.api.nvim_get_mode().mode ~= "i" then
                    local resume = self._prompt._resume_insert
                    if resume then
                        self._prompt._resume_insert = nil
                        if resume == "eol" then
                            vim.cmd("startinsert!")
                        elseif resume == "mid" then
                            -- Mid-line: move cursor right to undo the
                            -- InsertLeave left-shift, then enter insert.
                            vim.cmd("normal! l")
                            vim.cmd("startinsert")
                        else
                            -- bol: InsertLeave doesn't shift at col 0.
                            vim.cmd("startinsert")
                        end
                    else
                        vim.cmd("startinsert")
                    end
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

    vim.keymap.set({ "n", "i" }, "<C-c>", "<Cmd>PiAbort<CR>", {
        buffer = pbuf,
        desc = "Abort current π operation",
    })

    -- New line
    -- TODO?: Should be configurable?
    vim.keymap.set("i", "<S-CR>", function()
        vim.api.nvim_put({ "", "" }, "c", false, true)
    end, { buffer = pbuf, desc = "New line" })

    -- Toggle collapsible blocks (system preamble, compaction summaries, tool blocks)
    vim.keymap.set("n", "<Tab>", function()
        if self._history:toggle_startup_block() then
            return
        elseif self._history:toggle_compaction_block() then
            return
        elseif self._history:toggle_tool_block() then
            return
        end
    end, { buffer = hbuf, desc = "Toggle block under cursor" })

    -- Zen toggle key — permanent on the prompt buffer.
    -- Enters zen when inactive, exits when active.
    local zen_cfg = Config.options.zen
    local zen_keys = zen_cfg and zen_cfg.keys or nil
    if zen_keys and zen_keys.toggle then
        local Keys = require("pi.keys")
        for _, key in ipairs(Keys.resolve(zen_keys.toggle)) do
            Keys.bind(pbuf, key, function()
                self:zen_toggle()
            end, { modes = { "n", "i" }, nowait = true, desc = "Toggle π zen mode" })
        end
    end
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
    local icon = " " .. Config.options.labels.agent_response .. " "
    self._history:show_loading_placeholder({
        {
            { icon, "PiAgentResponseLabel" },
            { "  Loading session…", "PiBusy" },
        },
    })
end

function Chat:hide()
    if self._zen:is_active() then
        self._zen:exit()
    end
    self._layout:hide()
end

--- Handle editor resize. Re-evaluates layout config and updates geometry.
function Chat:on_resize()
    self._layout:on_resize()
    self:refresh_prompt_attention()
end

---@param cb? fun()
function Chat:toggle_layout(cb)
    self._prompt._resume_insert = nil
    self._layout:toggle()
    self:refresh_prompt_attention()

    -- Determine how to re-enter insert mode based on the normal-mode
    -- cursor position after the switch.  InsertLeave shifts the cursor
    -- left by 1 (except at col 0), so we compensate:
    --   eol (on or past last char) → startinsert!  (A)
    --   bol (col 0)                → startinsert   (no shift happened)
    --   mid                        → normal! l + startinsert
    local pwin = self._layout:prompt_win()
    if pwin then
        local cur = vim.api.nvim_win_get_cursor(pwin)
        local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pwin), cur[1] - 1, cur[1], false)[1] or ""
        local last_col = math.max(0, #line - 1)
        if cur[2] >= last_col then
            self._prompt._resume_insert = "eol"
        elseif cur[2] == 0 then
            self._prompt._resume_insert = "bol"
        else
            self._prompt._resume_insert = "mid"
        end
    end

    self:focus_prompt(cb)
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

--- Capture input independently of the chat's buffers and attachment list.
---@return pi.ChatDraft
function Chat:snapshot_draft()
    return { text = self._prompt:text(), attachments = self._attachments:snapshot() }
end

--- Restore saved input ahead of any current draft.
---@param draft pi.ChatDraft
function Chat:restore_draft(draft)
    self._prompt:restore_text(draft.text)
    self._attachments:restore(draft.attachments)
end

---@return boolean opened
function Chat:_auto_dispatch_attention_on_prompt_focus()
    local attention_config = Config.options.attention
    if not attention_config or not attention_config.auto_open_on_prompt_focus then
        return false
    end
    if not self:has_prompt_focus() or self:has_draft() then
        return false
    end
    return require("pi.attention").open_next_for_tab(self._tab)
end

---@param cb? fun()
function Chat:focus_prompt(cb)
    vim.schedule(function()
        self._prompt:focus(cb)
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

--- Toggle zen mode (full-screen prompt float).
function Chat:zen_toggle()
    if not self._layout:is_visible() then
        self:ensure_shown_and_focus_prompt()
    end
    self._zen:toggle()
end

---@return boolean
function Chat:zen_active()
    return self._zen:is_active()
end

--- Submit the prompt. When streaming, sends as a steer (interrupt); otherwise regular prompt.
function Chat:submit()
    if self:_execute_local_command() then
        return
    end
    if self._compacting or self._compaction_prompt then
        self:_queue_compaction_message("steer")
        return
    end
    self:_send_message(self._streaming and "steer" or nil)
end

--- Submit the prompt as a follow-up. When streaming, queued until agent finishes;
--- otherwise sends as a regular prompt.
function Chat:submit_follow_up()
    if self:_execute_local_command() then
        return
    end
    if self._compacting or self._compaction_prompt then
        self:_queue_compaction_message("follow_up")
        return
    end
    self:_send_message(self._streaming and "follow_up" or nil)
end

---@return boolean handled
function Chat:_execute_local_command()
    local text = self._prompt:text()
    if not text:match("^/[^%s]+%s*.*$") then
        return false
    end
    local handled, err = SlashCommands.execute(text)
    if not handled then
        return false
    end
    if err then
        Notify.warn(err)
        return true
    end
    self._prompt:clear_text()
    return true
end

---@return boolean
function Chat:is_streaming()
    return self._streaming
end

---@return boolean
function Chat:is_compacting()
    return self._compacting
end

---@param compacting boolean
function Chat:set_compacting(compacting)
    self._compacting = compacting
end

---@param text string
---@return boolean
function Chat:_is_extension_command(text)
    if not text:match("^%s*/") then
        return false
    end
    local name = text:match("^%s*/([^%s]+)")
    if not name then
        return false
    end
    for _, command in ipairs(CommandsCache.list()) do
        if command.name == name and command.source == "extension" then
            return true
        end
    end
    return false
end

--- Reconcile only this prompt's handoff; run events own global activity.
---@param submission pi.SubmittedMessage
---@param disposition pi.PromptDisposition
function Chat:_reconcile_prompt(submission, disposition)
    if self._inflight_prompt ~= submission and self._compaction_prompt ~= submission then
        return
    end
    local continuing = disposition == "started" or disposition == "queued"
    if disposition == "handled" and self._inflight_prompt == submission then
        self._inflight_prompt = nil
        if not self._streaming and not self._compacting then
            self:set_status(nil)
        end
    end
    if self._compaction_prompt == submission then
        self._compaction_prompt = nil
        self:flush_compaction_queue(continuing or self._streaming)
    end
end

--- Capture locally owned input before clearing the editor.
---@return pi.SubmittedMessage?
function Chat:_capture_submission()
    local text = self._prompt:text()
    if text == "" and self._attachments:count() == 0 then
        return nil
    end
    if self._zen:is_active() then
        self._zen:exit()
    end
    local attachment_items = self._attachments:count() > 0 and self._attachments:snapshot() or nil
    ---@type pi.SubmittedMessage
    local submission = {
        text = text,
        expanded_text = Mentions.expand(text),
        attachments = attachment_items,
        images = attachment_items and self._attachments:get() or nil,
    }
    self._prompt:clear_text()
    self._attachments:clear()
    self._pending_submissions[#self._pending_submissions + 1] = submission
    return submission
end

--- RPC callbacks identify their own submission, including identical inputs.
---@param submission pi.SubmittedMessage
---@return boolean removed
function Chat:_resolve_submission(submission)
    for i, pending in ipairs(self._pending_submissions) do
        if pending == submission then
            table.remove(self._pending_submissions, i)
            return true
        end
    end
    return false
end

---@param submissions pi.SubmittedMessage[]
function Chat:_restore_submissions(submissions)
    local restored_text = {}
    local restored_attachments = {}
    for _, submission in ipairs(submissions) do
        restored_text[#restored_text + 1] = submission.text
        if submission.attachments then
            vim.list_extend(restored_attachments, submission.attachments)
        end
    end
    if #restored_text > 0 then
        self._prompt:restore_text(table.concat(restored_text, "\n\n"))
    end
    self._attachments:restore(restored_attachments)
end

---@param submission pi.SubmittedMessage
function Chat:_restore_submission(submission)
    if self._inflight_prompt == submission then
        self._inflight_prompt = nil
        if not self._streaming and not self._compacting then
            self:set_status(nil)
        end
    end
    local restored = { submission }
    if self._compaction_prompt == submission then
        self._compaction_prompt = nil
        for _, entry in ipairs(self._compaction_queue) do
            self:_resolve_submission(entry.submission)
            restored[#restored + 1] = entry.submission
        end
        self._compaction_queue = {}
        self:_refresh_pending_queue()
    end
    self:_restore_submissions(restored)
end

---@param submission pi.SubmittedMessage
---@param command_type "prompt"|"steer"|"follow_up"
---@return boolean
function Chat:_send_submission(submission, command_type)
    ---@type pi.RpcCommand
    local cmd = { type = command_type, message = submission.expanded_text, images = submission.images }
    if command_type == "prompt" then
        self._inflight_prompt = submission
    end
    local callback = function(response)
        vim.schedule(function()
            if not self:_resolve_submission(submission) then
                return
            end
            if response.success == false then
                self:_restore_submission(submission)
            elseif command_type == "prompt" then
                self:_reconcile_prompt(submission, response.data.disposition)
            end
        end)
    end
    local sent = self._agent.send(cmd, callback)
    if sent == false then
        if self:_resolve_submission(submission) then
            self:_restore_submission(submission)
        end
        return false
    end
    if command_type == "prompt" and not self._streaming and not self._compacting then
        self:set_status({ type = "agent", text = "Starting…" })
    end
    return true
end

--- Render Pi's confirmed queue alongside messages still buffered locally.
function Chat:_refresh_pending_queue()
    ---@type pi.PendingQueueEntry[]
    local entries = self._queue:pending()
    for _, entry in ipairs(self._compaction_queue) do
        entries[#entries + 1] = {
            queue_type = entry.mode,
            text = entry.submission.text,
            image_count = entry.submission.images and #entry.submission.images or nil,
        }
    end
    self._history:set_pending_queue(entries)
    self._prompt:statusline():set_pending_queue(entries)
end

---@param mode "steer"|"follow_up"
function Chat:_queue_compaction_message(mode)
    local submission = self:_capture_submission()
    if not submission then
        return
    end
    if self:_is_extension_command(submission.text) then
        self._history:add_user_message(submission.text, nil, submission.images and #submission.images or nil)
        self:_send_submission(submission, "prompt")
        return
    end
    self._compaction_queue[#self._compaction_queue + 1] = { mode = mode, submission = submission }
    self:_refresh_pending_queue()
    Notify.info("Queued message for after compaction")
end

---@param will_retry boolean
function Chat:flush_compaction_queue(will_retry)
    if #self._compaction_queue == 0 then
        return
    end
    if will_retry then
        local queued = self._compaction_queue
        self._compaction_queue = {}
        self._compaction_prompt = nil
        self:_refresh_pending_queue()
        for _, entry in ipairs(queued) do
            self:_send_submission(entry.submission, entry.mode)
        end
        return
    end
    if self._compacting or self._compaction_prompt then
        return
    end
    local first = table.remove(self._compaction_queue, 1)
    local submission = first.submission
    self._compaction_prompt = submission
    self:_refresh_pending_queue()
    self._history:add_user_message(submission.text, nil, submission.images and #submission.images or nil)
    self:_send_submission(submission, "prompt")
end

--- Send current input; Pi's snapshots control the displayed backend queue.
---@param queue_type "steer"|"follow_up"|nil
function Chat:_send_message(queue_type)
    local submission = self:_capture_submission()
    if not submission then
        return
    end
    if not queue_type then
        self._history:add_user_message(submission.text, nil, submission.images and #submission.images or nil)
    end
    self:_send_submission(submission, queue_type or "prompt")
end

---@return string?
function Chat:active_verb()
    return self._active_verb
end

---@param status pi.Status?
function Chat:set_status(status)
    self._history:set_status(status)
    local text = status and (status.type == "compaction" and "Compacting…" or status.text) or nil
    self._prompt:statusline():set_activity(text, status ~= nil and status.type == "agent" and self._streaming)
end

---@param msg string
---@param timestamp? number
---@param image_count? integer
function Chat:add_user_message(msg, timestamp, image_count)
    self._history:add_user_message(msg, timestamp, image_count)
end

---@param replaying boolean
function Chat:set_replaying(replaying)
    self._replaying = replaying
    self._history._replaying = replaying
end

---@param timestamp? number
function Chat:on_agent_start(timestamp)
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = timestamp
    if self._replaying then
        return
    end
    self._streaming = true
    self._inflight_prompt = nil
    self._compaction_prompt = nil
    self._last_turn_stop_reason = nil
    local verbs = Config.random_verbs()
    self._active_verb = verbs[1]
    self._done_verb = verbs[2]
    self:set_status({ type = "agent", text = verbs[1] .. "…" })
    self:flush_compaction_queue(true)
end

function Chat:_ensure_assistant_block_open()
    if self._assistant_block_open then
        self._assistant_message_header_rendered = true
        return
    end
    self._history:on_agent_start(self._assistant_message_timestamp)
    self._assistant_block_open = true
    self._assistant_message_header_rendered = true
end

---@param delta string
function Chat:on_text_delta(delta)
    if not self._assistant_block_open and not delta:match("%S") then
        return
    end
    self:_ensure_assistant_block_open()
    self._assistant_tool_only_header_rendered = false
    self._history:on_text_delta(delta)
end

function Chat:clear_for_compaction_rebuild()
    self:_clear_rendered_history()
    self._compacting = true
    self:_refresh_pending_queue()
end

function Chat:on_agent_end()
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = nil
    if self._replaying then
        self._history:on_agent_end()
        return
    end
    local completion_text = self._done_verb
    local force_completion = false
    if self._last_turn_stop_reason == "aborted" then
        completion_text = "Aborted"
        force_completion = true
    elseif self._last_turn_stop_reason == "error" then
        completion_text = "Failed"
        force_completion = true
    end

    self._done_verb = nil
    self._last_turn_stop_reason = nil

    self._history:on_agent_end(completion_text, { force_completion = force_completion })
end

--- Pi is authoritative here: retries, compaction, and queued turns are complete.
---@param aborted boolean
function Chat:on_agent_settled(aborted)
    self._streaming = false
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = nil
    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil
    self._queue:settled()
    self:_refresh_pending_queue()
    self:set_status(nil)

    if not self:has_prompt_focus() then
        local attention_config = Config.options.attention
        if attention_config and attention_config.notify_on_completion then
            local outcome = aborted and "Agent aborted" or "Agent finished"
            Attention.notify(self._tab, outcome .. " - waiting for your input", vim.log.levels.INFO)
        end
    end
end

--- Queue snapshots contain backend text, independently of local submissions.
---@param steering string[]
---@param follow_up string[]
function Chat:on_queue_update(steering, follow_up)
    self._queue:update(steering, follow_up)
    self:_refresh_pending_queue()
end

---@param code integer?
---@param expected? boolean
function Chat:on_process_exit(code, expected)
    local pending = self._pending_submissions
    self._pending_submissions = {}
    self:_restore_submissions(pending)

    self._streaming = false
    self._compacting = false
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = nil
    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil
    self._inflight_prompt = nil
    self._compaction_prompt = nil
    self._compaction_queue = {}
    self._queue:clear()
    self._history:mark_pending_tools_errored("[failed] Pi process exited")
    self:_refresh_pending_queue()
    self:set_status(nil)

    if not expected then
        self:on_system_error(
            "Pi process exited unexpectedly (code " .. tostring(code or "unknown") .. "). Run :PiStop, then reopen :Pi.",
            { pad_top = true, pad_bottom = true }
        )
    end
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
        local entry = self._queue:consume(text)
        self:_refresh_pending_queue()
        if entry then
            self._history:add_user_message(entry.text, nil, image_count > 0 and image_count or nil, entry.queue_type)
        end
    elseif message.role == "assistant" then
        self._assistant_block_open = false
        self._assistant_message_header_rendered = false
        self._assistant_message_timestamp = message.timestamp
    end
end

--- Handle message_end events.  When an assistant message ends with
--- stopReason "aborted" or "error", mark all pending tool blocks as
--- errored so they don't hang open forever.
---@param msg pi.RpcEvent
function Chat:on_message_end(msg)
    local message = msg.message
    if not message or message.role ~= "assistant" then
        return
    end

    local stop = message.stopReason

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
    self._assistant_block_open = false
end

--- Update status line state (model, thinking level) from get_state response.
---@param data table
function Chat:update_state(data)
    self._prompt:statusline():update_state(data)
end

--- Replace accounting with the backend's complete session snapshot.
---@param stats pi.SessionStats
function Chat:update_stats(stats)
    self._prompt:statusline():update_stats(stats)
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

---@param summary string
---@param tokens_before integer
function Chat:append_compaction_summary(summary, tokens_before)
    self._history:append_compaction_summary(summary, tokens_before)
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
    if not self._assistant_message_header_rendered and not self._assistant_tool_only_header_rendered then
        self:_ensure_assistant_block_open()
        self._assistant_tool_only_header_rendered = true
    end
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

--- Toggle all expandable history blocks
---@return boolean changed
function Chat:toggle_history_blocks()
    return self._history:toggle_blocks_expanded()
end

--- Clear rendered messages without resetting the live agent run.
function Chat:_clear_rendered_history()
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = nil
    self._history:clear()
    self._prompt:statusline():set_pending_queue({})
    self._prompt:statusline():reset_usage()
end

function Chat:clear()
    self._streaming = false
    self._compacting = false
    self:set_replaying(false)
    self._queue:clear()
    self._pending_submissions = {}
    self._compaction_queue = {}
    self._compaction_prompt = nil
    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil
    self._inflight_prompt = nil
    self:_clear_rendered_history()
    self._prompt:statusline():set_activity(nil, false)
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

--- Scroll the history window to the first agent response in the latest user turn.
function Chat:scroll_history_to_first_agent_response()
    self._history:scroll_to_first_agent_response()
end

--- Scroll the history window to the last agent response in the latest user turn.
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
