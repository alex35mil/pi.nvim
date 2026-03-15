---@alias pi.TabId integer Neovim tabpage handle

---@class pi.SessionAttention
---@field pending pi.AttentionEntry[]
---@field transition_seq? integer Hide queued entries with seq <= this while a session transition is in flight.

---@class pi.StartupAnnouncement
---@field lines string[]

---@class pi.SystemErrorEntry
---@field message string
---@field timestamp integer

---@class pi.Session
---@field tab pi.TabId
---@field rpc pi.Rpc
---@field chat pi.Chat
---@field attention pi.SessionAttention
---@field startup_announcements table<string, pi.StartupAnnouncement> Extension startup data (keys ending with `:startup`) shown in the system preamble. Process-level: persists across session switches.
---@field system_errors pi.SystemErrorEntry[]

---@class pi.SessionCreateOpts
---@field layout? pi.LayoutMode

local M = {}

local Rpc = require("pi.rpc")
local Chat = require("pi.ui.chat")
local Config = require("pi.config")
local Startup = require("pi.startup")
local Notify = require("pi.notify")
local Attention = require("pi.attention")
local Dialog = require("pi.ui.dialog")
local Extension = require("pi.ui.extension")
local CommandsCache = require("pi.cache.commands")

---@class pi.StartupSection
---@field header string
---@field items string[]
---@field hl? string

---@param session pi.Session
---@param commands? pi.SlashCommand[]
local function show_startup_block(session, commands)
    local sections = Startup.build_startup_sections(session, commands)
    session.chat:show_startup_block({ sections = sections, errors = session.system_errors })
end

--- Fetch commands and render the startup block on a session's chat.
---@param session pi.Session
local function fetch_commands_and_show_startup_block(session)
    CommandsCache.fetch(session.rpc, function(commands)
        show_startup_block(session, commands)
    end)
end

---@type table<pi.TabId, pi.Session>
local sessions = {}

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

--- Events we've reviewed and deliberately choose not to handle.
--- turn_start/turn_end: TUI doesn't handle them; lifecycle is fully
--- covered by message_start / message_end / agent_end.
---@type table<string, true>
local ignored_events = {
    turn_start = true,
    turn_end = true,
}

--- Fetch current state and update the status line.
---@param session pi.Session
function M.refresh_state(session)
    session.rpc:send({ type = "get_state" }, function(res)
        if res.success and res.data then
            vim.schedule(function()
                session.chat:update_state(res.data)
            end)
        end
    end)
end

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
        CommandsCache.refresh(session.rpc)
        M.refresh_state(session)
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
                -- NOTE: Ignored sub-events (safe, low priority):
                --   toolcall_start/delta/end — TUI uses these to show tool blocks
                --     during LLM streaming (before execution). We use
                --     tool_execution_start instead; negligible difference since
                --     tool blocks are collapsed anyway.
                --   start, done — redundant with message_start/end.
                --   text_start, text_end — text_delta suffices.
            end
        end
    elseif t == "tool_execution_start" then
        chat:on_tool_start(msg.toolName or "tool", msg.toolCallId, msg.args)
    elseif t == "tool_execution_end" then
        chat:on_tool_end(msg.toolName or "tool", msg.toolCallId, msg.result, msg.isError)
    elseif t == "auto_compaction_start" then
        chat:set_status({ type = "compaction" })
    elseif t == "auto_compaction_end" then
        chat:reset_usage()
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
        chat:set_status(nil)
        if msg.success == false then
            chat:on_error(
                "Retry failed after "
                    .. tostring(msg.attempt or 0)
                    .. " attempts: "
                    .. (msg.finalError or "Unknown error"),
                { pad_top = true, pad_bottom = true }
            )
        end
    elseif t == "extension_ui_request" then
        vim.schedule(function()
            Extension.handle(session, msg)
        end)
    elseif t == "extension_error" then
        local extension_path = type(msg.extensionPath) == "string" and msg.extensionPath or "unknown extension"
        local extension_event = type(msg.event) == "string" and msg.event or "unknown event"
        local error_message = type(msg.error) == "string" and msg.error or "Unknown error"
        local formatted = "Extension error ("
            .. vim.fn.fnamemodify(extension_path, ":~:.")
            .. ", "
            .. extension_event
            .. "):\n"
            .. error_message
        session.system_errors[#session.system_errors + 1] = {
            message = formatted,
            timestamp = os.time() * 1000,
        }
        chat:on_system_error(formatted, { pad_top = true, pad_bottom = true })
    elseif t == "_stderr" then
        if type(msg.message) == "string" and msg.message ~= "" then
            session.system_errors[#session.system_errors + 1] = {
                message = msg.message --[[@as string]],
                timestamp = os.time() * 1000,
            }
            chat:on_system_error(msg.message --[[@as string]], { pad_top = true, pad_bottom = true })
        end
    elseif t == "_process_exit" then
        vim.schedule(function()
            chat:set_status(nil)
            if Config.options.debug and msg.code ~= 0 and msg.code ~= 143 then
                print("Process exited with code " .. (msg.code or "-"))
            end
        end)
    elseif t == "response" then
        -- Normally handled by rpc:send() one-shot callbacks. Late error
        -- responses (e.g. async prompt failures like auth errors) arrive
        -- after the initial success response already consumed the callback.
        if msg.success == false and type(msg.error) == "string" then
            chat:on_error(msg.error, { pad_top = true, pad_bottom = true })
        end
        return false
    elseif t == "message_start" then
        chat:on_message_start(msg)
    elseif t == "message_end" then
        chat:on_message_end(msg)
    elseif t == "tool_execution_update" then
        chat:on_tool_update(msg.toolName or "tool", msg.toolCallId, msg)
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

--- List all active sessions.
---@return pi.Session[]
function M.list()
    ---@type pi.Session[]
    local result = {}
    for _, session in pairs(sessions) do
        result[#result + 1] = session
    end
    table.sort(result, function(a, b)
        return a.tab < b.tab
    end)
    return result
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
        tab = tab,
        rpc = rpc,
        chat = chat,
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
    }

    rpc:set_handler(function(msg)
        handle_event(session, msg)
    end)

    sessions[tab] = session

    -- Fetch available /commands for completion, highlighting, and system info
    fetch_commands_and_show_startup_block(session)

    -- Fetch initial state for status line (model, thinking level)
    M.refresh_state(session)

    return session
end

--- Remove and clean up a session for the current tab.
function M.stop()
    local tab = current_tab()
    local session = sessions[tab]
    if not session then
        return
    end

    Attention.clear_session(session)
    session.rpc:stop()
    session.chat:hide()
    session.chat:clear()

    sessions[tab] = nil
end

---@param session pi.Session
local function start_new_session(session)
    if sessions[session.tab] ~= session or not session.rpc:is_running() then
        return
    end

    Attention.begin_session_transition(session)
    local sent = session.rpc:send({ type = "abort" }, function(abort_res)
        if not abort_res.success then
            vim.schedule(function()
                Attention.end_session_transition(session, false)
                Notify.error(abort_res.error or "Failed to abort current session")
            end)
            return
        end
        local sent_new = session.rpc:send({ type = "new_session" }, function(res)
            local data = res.data or {}
            vim.schedule(function()
                if not res.success then
                    Attention.end_session_transition(session, false)
                    Notify.error(res.error or "Failed to start new session")
                    return
                end
                if data.cancelled then
                    Attention.end_session_transition(session, false)
                    Notify.warn("New session was cancelled")
                    return
                end
                Attention.end_session_transition(session, true)
                session.chat:clear()
                fetch_commands_and_show_startup_block(session)
            end)
        end)
        if not sent_new then
            vim.schedule(function()
                Attention.end_session_transition(session, false)
            end)
        end
    end)
    if not sent then
        Attention.end_session_transition(session, false)
    end
end

--- Start a new conversation in the current tab's session.
function M.new_session()
    local session = M.get()
    if not session or not session.rpc:is_running() then
        return
    end

    if not session.chat:is_streaming() then
        start_new_session(session)
        return
    end

    Dialog.confirm({
        title = "Start new session?",
        message = "This opens a fresh session. You can resume the current conversation later.",
    }, function(confirmed)
        if not confirmed then
            return
        end
        start_new_session(session)
    end)
end

--- Replay messages from get_messages response into chat.
---@param session pi.Session
---@param messages table[]
local function replay_messages(session, messages)
    session.chat:set_replaying(true)
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
            if text ~= "" or image_count > 0 then
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
            local stop = msg.stopReason
            if stop ~= "aborted" and stop ~= "error" and type(msg.usage) == "table" then
                session.chat:add_usage(msg.usage)
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
    session.chat:set_replaying(false)
end

--- Load a session by path: switch_session -> clear chat -> get_messages -> replay.
---@param session pi.Session
---@param session_path string
local function load_session(session, session_path)
    Attention.begin_session_transition(session)

    local sent_switch = session.rpc:send({ type = "switch_session", sessionPath = session_path }, function(msg)
        local data = msg.data or {}
        if not msg.success then
            vim.schedule(function()
                Attention.end_session_transition(session, false)
                Notify.error(msg.error or "Failed to switch session")
            end)
            return
        end
        if data.cancelled then
            vim.schedule(function()
                Attention.end_session_transition(session, false)
                Notify.warn("Session switch was cancelled")
            end)
            return
        end

        Attention.end_session_transition(session, true)
        M.refresh_state(session)

        vim.schedule(function()
            session.chat:clear()
            session.chat:show_loading()
        end)

        local sent_messages = session.rpc:send({ type = "get_messages" }, function(res)
            vim.schedule(function()
                session.chat:clear_placeholder()
                if not res.success then
                    local err = res.error or "Failed to load session messages"
                    Notify.error(err)
                    session.chat:on_error(err, { pad_top = true, pad_bottom = true })
                    session.chat:ensure_shown_and_focus_prompt()
                    return
                end

                local messages = (res.data or {}).messages or {}
                -- Fetch commands, show startup block, then replay.
                CommandsCache.fetch(session.rpc, function(commands)
                    show_startup_block(session, commands)
                    replay_messages(session, messages)
                    session.chat:ensure_shown_and_focus_prompt()
                end)
            end)
        end)
        if not sent_messages then
            vim.schedule(function()
                session.chat:clear()
                Notify.error("Failed to load session messages")
                session.chat:on_error("Failed to load session messages", { pad_top = true, pad_bottom = true })
                session.chat:ensure_shown_and_focus_prompt()
            end)
        end
    end)

    if not sent_switch then
        Attention.end_session_transition(session, false)
    end
end

---@param current_session_file? string
---@return string?
local function find_continue_session_path(current_session_file)
    local History = require("pi.sessions.history")
    local sessions_list = History.list()
    for _, session in ipairs(sessions_list) do
        if session.path ~= current_session_file then
            return session.path
        end
    end
    return nil
end

---@param session pi.Session
---@param state table?
---@return boolean
local function is_empty_session_state(session, state)
    if type(state) ~= "table" then
        return false
    end

    local message_count = type(state.messageCount) == "number" and state.messageCount or nil
    local pending_count = type(state.pendingMessageCount) == "number" and state.pendingMessageCount or nil
    if message_count == nil or pending_count == nil then
        return false
    end

    return message_count == 0
        and pending_count == 0
        and state.isStreaming ~= true
        and state.isCompacting ~= true
        and not session.chat:has_draft()
end

---@param session pi.Session
local function show_no_previous_sessions(session)
    Notify.info("No previous sessions found")
    session.chat:ensure_shown_and_focus_prompt()
end

--- Continue the most recent session for the current cwd.
---@param opts? pi.SessionCreateOpts
function M.continue_session(opts)
    local session = M.get()
    if not session then
        local session_path = find_continue_session_path(nil)
        session = M.get_or_create(opts)
        if not session then
            return
        end
        if not session_path then
            show_no_previous_sessions(session)
            return
        end
        session.chat:show({ loading = true })
        load_session(session, session_path)
        return
    end

    local sent = session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            if M.get() ~= session then
                return
            end
            if not res.success then
                Notify.error(res.error or "Failed to fetch session state")
                return
            end

            local state = res.data or {}
            if not is_empty_session_state(session, state) then
                return
            end

            local session_path = find_continue_session_path(state.sessionFile)
            if not session_path then
                show_no_previous_sessions(session)
                return
            end

            session.chat:show({ loading = true })
            load_session(session, session_path)
        end)
    end)
    if not sent then
        Notify.error("Failed to fetch session state")
    end
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

    ---@class pi.SessionSelectItem
    ---@field session pi.SessionInfo
    ---@field file string

    ---@type pi.SessionSelectItem[]
    local items = {}
    for i, session in ipairs(sessions_list) do
        items[i] = {
            session = session,
            file = session.path,
        }
    end

    vim.ui.select(items, {
        prompt = "Resume session",
        kind = "pi-resume-session",
        -- Pass picker items with a `file` field so backends like snacks.nvim
        -- can preview the raw session file when preview is enabled. Other
        -- vim.ui.select implementations ignore extra fields and render via
        -- `format_item`.
        format_item = function(item)
            local session = item.session
            local date = session.timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)") or session.timestamp
            local label = session.name
                or (session.first_message ~= "" and session.first_message or "(empty)")
            return date .. "  " .. label
        end,
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
                            box.height = math.floor(math.max(math.min(#items, vim.o.lines * 0.8 - 10), 2))
                        end
                    end
                end,
            },
        },
    }, function(item)
        if not item then
            return
        end
        local session = M.get_or_create(opts)
        if not session then
            return
        end
        session.chat:show({ loading = true })
        load_session(session, item.session.path)
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
            Attention.clear_session(session)
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
                Attention.clear_session(session)
                session.rpc:stop()
            end
        end,
    })
end

return M
