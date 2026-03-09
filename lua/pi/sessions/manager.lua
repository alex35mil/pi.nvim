---@alias pi.TabId integer Neovim tabpage handle

---@class pi.Session
---@field rpc pi.Rpc
---@field chat pi.Chat

---@class pi.SessionCreateOpts
---@field layout? pi.LayoutMode

local M = {}

local Rpc = require("pi.rpc")
local Chat = require("pi.ui.chat")
local Config = require("pi.config")
local Notify = require("pi.notify")
local Extension = require("pi.ui.extension")

---@type table<pi.TabId, pi.Session>
local sessions = {}

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

--- Events we've reviewed and deliberately choose not to handle.
---@type table<string, true>
local ignored_events = {
    message_start = true,
    message_end = true,
}

--- Central event handler for a session.
---@param session pi.Session
---@param msg pi.RpcEvent
---@return boolean handled
local function handle_event(session, msg)
    local t = msg.type
    local chat = session.chat

    if t == "agent_start" then
        chat:on_agent_start()
    elseif t == "agent_end" then
        chat:on_agent_end()
    elseif t == "message_update" then
        local event = msg.assistantMessageEvent
        if event then
            if event.type == "thinking_start" then
                chat:on_thinking_start()
            elseif event.type == "thinking_delta" then
                chat:on_thinking_delta(event.delta or "")
            elseif event.type == "thinking_end" then
                chat:on_thinking_end()
            elseif event.type == "text_delta" then
                chat:on_thinking_end() -- no-op if not thinking
                chat:on_text_delta(event.delta or "")
            else
                Rpc.log_unhandled(t)
                return false
            end
        end
    elseif t == "tool_execution_start" then
        chat:on_tool_start(msg.toolName or "tool", msg.toolCallId, msg.args)
    elseif t == "tool_execution_end" then
        chat:on_tool_end(msg.toolName or "tool", msg.toolCallId, msg.result, msg.isError)
    elseif t == "auto_compaction_start" then
        chat:set_status({ type = "compaction" })
    elseif t == "auto_compaction_end" then
        -- Compaction can fire after agent_end (between turns).
        -- Only restore the spinner if an agent loop is still active.
        if chat:active_verb() then
            chat:set_status({ type = "agent", text = chat:active_verb() .. "…" })
        else
            chat:set_status(nil)
        end
    elseif t == "auto_retry_start" then
        chat:set_status({ type = "agent", text = "Retrying…" })
    elseif t == "auto_retry_end" then
        chat:set_status({ type = "agent", text = (chat:active_verb() or "Working") .. "…" })
    elseif t == "extension_ui_request" then
        vim.schedule(function()
            Extension.handle(session, msg)
        end)
    elseif t == "_stderr" then
        if Config.options.ui.show_debug and type(msg.message) == "string" then
            chat:on_stderr(msg.message --[[@as string]])
        end
    elseif t == "_process_exit" then
        vim.schedule(function()
            chat:set_status(nil)
            if msg.code ~= 0 then
                print("Process exited with code " .. (msg.code or "-"))
            end
        end)
    elseif t == "response" then
        return false -- handled by rpc:send() one-shot callbacks
    elseif t == "tool_execution_update" then
        chat:on_tool_update(msg.toolName or "tool", msg.toolCallId, msg)
    elseif t == "turn_end" then
        local tmsg = msg.message
        if tmsg and tmsg.stopReason == "error" and tmsg.errorMessage then
            chat:on_error(tmsg.errorMessage)
        end
    -- TODO: Handle missing events
    elseif ignored_events[t] then
        return true
    else
        Rpc.log_unhandled(t)
        return false
    end

    return true
end

--- Get the session for the current tab. Returns nil if none exists.
---@return pi.Session?
function M.get()
    local tab = current_tab()
    return sessions[tab]
end

--- Get or create a session for the current tab.
---@param opts? pi.SessionCreateOpts
---@return pi.Session?
function M.get_or_create(opts)
    opts = opts or {}

    local tab = current_tab()

    local session = sessions[tab]
    if session then
        return session
    end

    local rpc = Rpc.new(tab)

    if not rpc:start() then
        Notify.error("Failed to start process")
        return nil
    end

    local layout = opts.layout or Config.options.ui.layout.default

    ---@type pi.ChatAgent
    local agent = {
        send = function(msg)
            rpc:send(msg)
        end,
    }

    local chat = Chat.new(tab, layout, agent)

    ---@type pi.Session
    session = {
        rpc = rpc,
        chat = chat,
    }

    rpc:set_handler(function(msg)
        handle_event(session, msg)
    end)

    sessions[tab] = session

    return session
end

--- Remove and clean up a session for the current tab.
function M.stop()
    local tab = current_tab()
    local session = sessions[tab]
    if not session then
        return
    end

    session.rpc:stop()
    session.chat:hide()
    session.chat:clear()

    sessions[tab] = nil
end

--- Replay messages from get_messages response into chat.
---@param session pi.Session
---@param messages table[]
local function replay_messages(session, messages)
    local pending_agent_end = false
    for _, msg in ipairs(messages) do
        local role = msg.role
        -- Flush pending agent_end before a user message
        if pending_agent_end and role == "user" then
            session.chat:on_agent_end()
            pending_agent_end = false
        end
        if role == "user" then
            local text = ""
            local image_count = 0
            if type(msg.content) == "string" then
                text = msg.content
            elseif type(msg.content) == "table" then
                for _, part in ipairs(msg.content) do
                    if type(part) == "string" then
                        text = text .. part
                    elseif type(part) == "table" and part.type == "text" then
                        text = text .. (part.text or "")
                    elseif type(part) == "table" and part.type == "image" then
                        image_count = image_count + 1
                    end
                end
            end
            if text ~= "" then
                session.chat:add_user_message(text, msg.timestamp, image_count > 0 and image_count or nil)
            end
        elseif role == "assistant" then
            local text = ""
            local tool_calls = {} ---@type { id: string, name: string, args: table? }[]
            if type(msg.content) == "string" then
                text = msg.content
            elseif type(msg.content) == "table" then
                for _, part in ipairs(msg.content) do
                    if type(part) == "string" then
                        text = text .. part
                    elseif type(part) == "table" and part.type == "text" then
                        text = text .. (part.text or "")
                    elseif type(part) == "table" and part.type == "toolCall" then
                        tool_calls[#tool_calls + 1] = {
                            id = part.toolCallId or part.id or "",
                            name = part.toolName or part.name or "tool",
                            args = part.arguments or part.args or part.input,
                        }
                    end
                end
            end
            if text ~= "" or #tool_calls > 0 then
                -- Suppress agent header for tool-only continuation turns:
                -- if previous turn was tool-only and this turn is also tool-only,
                -- skip the header to keep consecutive tool calls visually grouped.
                local tool_only = text == "" and #tool_calls > 0
                if not (tool_only and pending_agent_end) then
                    if pending_agent_end then
                        session.chat:on_agent_end()
                        pending_agent_end = false
                    end
                    session.chat:on_agent_start(msg.timestamp)
                end
                if text ~= "" then
                    session.chat:on_text_delta(text)
                end
                -- Don't call on_agent_end yet — tool results follow as separate messages.
                -- Store pending tool calls so on_tool_end can fire before on_agent_end.
                for _, tc in ipairs(tool_calls) do
                    session.chat:on_tool_start(tc.name, tc.id, tc.args)
                end
                if #tool_calls == 0 then
                    session.chat:on_agent_end()
                else
                    pending_agent_end = true
                end
            end
        elseif role == "toolResult" then
            local tool_call_id = msg.toolCallId or msg.toolUseId or ""
            local tool_name = msg.toolName or "tool"
            local is_error = msg.isError == true
            -- msg itself has .content, matching what on_tool_end expects as result
            session.chat:on_tool_end(tool_name, tool_call_id, msg, is_error)
        end
    end
    -- Flush any remaining pending agent_end
    if pending_agent_end then
        session.chat:on_agent_end()
    end
end

--- Load a session by path: switch_session -> get_messages -> replay into chat.
---@param session pi.Session
---@param session_path string
local function load_session(session, session_path)
    session.rpc:send({ type = "switch_session", sessionPath = session_path }, function(msg)
        local data = msg.data or {}
        if data.cancelled then
            vim.schedule(function()
                Notify.warn("Session switch was cancelled")
            end)
            return
        end
        session.rpc:send({ type = "get_messages" }, function(res)
            vim.schedule(function()
                local messages = (res.data or {}).messages or {}
                replay_messages(session, messages)
                session.chat:ensure_shown_and_focus_prompt()
            end)
        end)
    end)
end

--- Continue the most recent session for the current cwd.
---@param opts? pi.SessionCreateOpts
function M.continue_session(opts)
    local session = M.get_or_create(opts)
    if not session then
        return
    end
    session.chat:show()

    local History = require("pi.sessions.history")
    local sessions_list = History.list()
    if #sessions_list == 0 then
        Notify.info("No previous sessions found")
        session.chat:ensure_shown_and_focus_prompt()
        return
    end

    load_session(session, sessions_list[1].path)
end

--- Show a picker to resume a past session.
---@param opts? pi.SessionCreateOpts
function M.resume_session(opts)
    local History = require("pi.sessions.history")
    local sessions_list = History.list()
    if #sessions_list == 0 then
        Notify.info("No sessions found")
        return
    end

    ---@type string[]
    local labels = {}
    for i, session in ipairs(sessions_list) do
        local date = session.timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)") or session.timestamp
        local msg = session.first_message ~= "" and session.first_message or "(empty)"
        labels[i] = date .. "  " .. msg
    end

    vim.ui.select(labels, {
        prompt = "Resume session",
        -- snacks.nvim (if installed) overrides vim.ui.select with its picker.
        -- It has a bug where the list height can be non-integer, crashing
        -- nvim_win_set_config. This `snacks` key is merged into the picker
        -- config and overrides the broken height calculation with math.floor.
        -- Safe to include even if snacks isn't used — the key is just ignored.
        snacks = {
            layout = {
                config = function(layout)
                    for _, box in ipairs(layout.layout) do
                        if box.win == "list" then
                            box.height = math.floor(math.max(math.min(#labels, vim.o.lines * 0.8 - 10), 2))
                        end
                    end
                end,
            },
        },
    }, function(_, idx)
        if not idx then
            return
        end
        local chosen = sessions_list[idx]
        local session = M.get_or_create(opts)
        if not session then
            return
        end
        session.chat:show()
        load_session(session, chosen.path)
    end)
end

--- Clean up sessions for closed tabs.
function M.cleanup()
    ---@type table<pi.TabId, boolean>
    local valid_tabs = {}
    for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        valid_tabs[t] = true
    end
    for tab, session in pairs(sessions) do
        if not valid_tabs[tab] then
            session.rpc:stop()
            sessions[tab] = nil
        end
    end
end

--- Set up the TabClosed autocmd (called once from init.setup).
function M.setup_autocmds()
    vim.api.nvim_create_autocmd("TabClosed", {
        callback = function()
            vim.schedule(function()
                M.cleanup()
            end)
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            for _, session in pairs(sessions) do
                session.rpc:stop()
            end
        end,
    })
end

return M