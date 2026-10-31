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
---@field workspace string Directory pi was launched in; fixed for the life of this connection.
---@field execution pi.Execution How pi was launched and how its paths map to the host.
---@field commands pi.CommandCatalog Slash commands of this connection.
---@field session_dir? string Folder of pi's current session file, from `get_state`.
---@field persistent? boolean False when pi reports no session file (e.g. `--no-session`); nil until known.
---@field rpc pi.Rpc
---@field chat pi.Chat
---@field attention pi.SessionAttention
---@field startup_announcements table<string, pi.StartupAnnouncement> Extension startup data (keys ending with `:startup`) shown in the system preamble. Process-level: persists across session switches.
---@field system_errors pi.SystemErrorEntry[]
---@field changed_files table<string, true> Set of absolute file paths modified by edit/write tools during the current session.
---@field _pending_file_change_args? table<string, table> Pending tool args by tool call id for file-changing tools.
---@field _compaction_rebuilding? boolean True while compacted messages are being fetched/replayed.
---@field _compaction_event_queue? pi.RpcEvent[] Events received while compacted messages are being fetched/replayed.

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
local CommandCatalog = require("pi.cache.commands")
local Workspace = require("pi.workspace")
local Execution = require("pi.execution")
local Descriptor = require("pi.execution.descriptor")
local ExecState = require("pi.execution.state")
local Tools = require("pi.ui.chat.tools")

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
    session.commands:fetch(session.rpc, function(commands)
        show_startup_block(session, commands)
    end)
end

---@type table<pi.TabId, pi.Session>
local sessions = {}

---@type table<pi.TabId, pi.ChatDraft>
local recovered_drafts = {}

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

--- Run/message events cover turn boundaries. Direct RPC bash has no client UI yet.
---@type table<string, true>
local ignored_events = {
    turn_start = true,
    turn_end = true,
    bash_execution_update = true,
}

---@type fun(session: pi.Session, result: table, will_retry: boolean)?
local rebuild_after_compaction

---@type fun(session: pi.Session, flush_queue?: boolean, will_retry?: boolean)?
local finish_compaction_rebuild

---@param chat pi.Chat
local function restore_active_agent_status(chat)
    -- Compaction/retry cleanup can fire after agent_end (between turns).
    -- Only restore the spinner if an agent loop is still active.
    local active_verb = chat:active_verb()
    if chat:is_compacting() then
        chat:set_status({ type = "compaction" })
    elseif active_verb then
        chat:set_status({ type = "agent", text = active_verb .. "…" })
    else
        chat:set_status(nil)
    end
end

---@param args any
---@return table?
local function normalize_tool_args(args)
    if type(args) == "table" then
        return args
    end
    if type(args) ~= "string" or args == "" then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, args)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

---@param args table?
---@return string?
local function get_changed_file_path(args)
    if type(args) ~= "table" then
        return nil
    end
    local path = args.path or args.file_path or args.filePath
    if type(path) == "string" and path ~= "" then
        return path
    end
    return nil
end

---@param session pi.Session
---@param args table?
local function track_changed_file(session, args)
    local path = get_changed_file_path(args)
    if not path then
        return
    end
    local host, refusal = session.execution:tool_path(path)
    if host then
        session.changed_files[host] = true
    else
        session.execution:report_unresolved(path, assert(refusal))
    end
end

---@param session pi.Session
---@param tool_name string?
---@param tool_call_id string?
---@param args any
local function stash_file_tool_args(session, tool_name, tool_call_id, args)
    if (tool_name ~= "edit" and tool_name ~= "write") or type(tool_call_id) ~= "string" or tool_call_id == "" then
        return
    end
    local decoded = normalize_tool_args(args)
    if not decoded then
        return
    end
    session._pending_file_change_args = session._pending_file_change_args or {}
    session._pending_file_change_args[tool_call_id] = decoded
end

--- Recover successful nested file mutations from bounded persisted metadata.
---@param session pi.Session
---@param result table
local function track_nested_files(session, result)
    for _, call in ipairs(result.nestedCalls and result.nestedCalls.calls or {}) do
        if call.status == "ok" and (call.name == "edit" or call.name == "write") then
            track_changed_file(session, call.arguments)
        end
    end
end

--- Read full-session billing and the backend's current context estimate.
---@param session pi.Session
function M.refresh_stats(session)
    session.rpc:send({ type = "get_session_stats" }, function(res)
        vim.schedule(function()
            if res.success then
                session.chat:update_stats(res.data)
            else
                Notify.warn(res.error or "Failed to fetch session statistics")
            end
        end)
    end)
end

--- Record where pi keeps this connection's sessions, from a `get_state` result.
---@param session pi.Session
---@param state table
local function record_session_storage(session, state)
    local file = state.sessionFile
    if type(file) == "string" and file ~= "" then
        -- As pi sees it; translated to the host when listing.
        session.session_dir = vim.fs.dirname(file)
        session.persistent = true
        session.execution:set_session_file(file)
    else
        session.session_dir = nil
        session.persistent = false
        session.execution:set_session_file(nil)
    end
end

--- Fetch current state and accounting for the status line.
---@param session pi.Session
---@param on_state? fun(ok: boolean, state?: table) Called (scheduled) after the state is applied.
function M.refresh_state(session, on_state)
    local sent = session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            if res.success then
                record_session_storage(session, res.data or {})
                session.chat:update_state(res.data)
            else
                Notify.warn(res.error or "Failed to fetch session state")
            end
            if on_state then
                on_state(res.success == true, res.success and (res.data or {}) or nil)
            end
        end)
    end)
    if not sent and on_state then
        vim.schedule(function()
            on_state(false)
        end)
    end
    M.refresh_stats(session)
end

--- Central event handler for a session.
---@param session pi.Session
---@param msg pi.RpcEvent
---@return boolean handled
local function handle_event(session, msg)
    local t = msg.type
    local chat = session.chat

    -- NOTE: This compaction-specific rebuild gate should become a small
    -- transaction helper if other session rebuild flows need event buffering.
    if session._compaction_rebuilding and t ~= "response" then
        if t == "_process_exit" and finish_compaction_rebuild then
            finish_compaction_rebuild(session, false)
        else
            session._compaction_event_queue = session._compaction_event_queue or {}
            session._compaction_event_queue[#session._compaction_event_queue + 1] = msg
            return true
        end
    end

    if t == "agent_start" then
        chat:on_agent_start()
    elseif t == "agent_end" then
        chat:on_agent_end()
    elseif t == "agent_settled" then
        chat:on_agent_settled(msg.aborted == true)
        session.commands:refresh(session.rpc)
        M.refresh_state(session)
    elseif t == "thinking_level_changed" or t == "session_info_changed" then
        M.refresh_state(session)
    elseif t == "entry_appended" then
        local entry = msg.entry
        if entry.type == "compaction" and rebuild_after_compaction then
            rebuild_after_compaction(session, entry, chat:is_streaming())
        elseif entry.type == "usage" or entry.type == "context_edit" then
            M.refresh_stats(session)
        end
        -- Custom entry presentation belongs to the separate entry-rendering API.
    elseif t == "queue_update" then
        chat:on_queue_update(msg.steering or {}, msg.followUp or {})
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
            elseif event.type == "toolcall_end" then
                local tool_call = event.toolCall
                if type(tool_call) == "table" then
                    stash_file_tool_args(session, tool_call.name, tool_call.id, tool_call.arguments)
                end
                -- NOTE: Other sub-events stay intentionally ignored:
                --   toolcall_start/delta — we render on tool_execution_start.
                --   start, done — redundant with message_start/end.
                --   text_start, text_end — text_delta suffices.
            end
        end
    elseif t == "tool_execution_start" then
        local args = normalize_tool_args(msg.args) or msg.args
        if not msg.parentToolCallId then
            chat:on_tool_start(msg.toolName or "tool", msg.toolCallId, args)
        end
        -- Nested file mutations still count even though their parent owns presentation.
        stash_file_tool_args(session, msg.toolName, msg.toolCallId, args)
    elseif t == "tool_execution_end" then
        if not msg.parentToolCallId then
            chat:on_tool_end(msg.toolName or "tool", msg.toolCallId, msg.result, msg.isError)
        end
        if session._pending_file_change_args then
            local completed = Tools.resolve_status(msg.result, msg.isError) == "completed"
            if completed then
                track_changed_file(session, session._pending_file_change_args[msg.toolCallId])
            end
            -- Direct calls still receive a finalized message_end; children do not.
            if completed or msg.parentToolCallId then
                session._pending_file_change_args[msg.toolCallId] = nil
            end
        end
    elseif t == "compaction_start" then
        chat:set_compacting(true)
        chat:set_status({ type = "compaction" })
    elseif t == "compaction_end" then
        if msg.aborted then
            chat:set_compacting(false)
            restore_active_agent_status(chat)
            chat:on_error("Compaction cancelled", { pad_top = true, pad_bottom = true })
            chat:flush_compaction_queue(msg.willRetry == true)
        elseif type(msg.errorMessage) == "string" and msg.errorMessage ~= "" then
            chat:set_compacting(false)
            restore_active_agent_status(chat)
            chat:on_error(msg.errorMessage, { pad_top = true, pad_bottom = true })
            chat:flush_compaction_queue(msg.willRetry == true)
        elseif type(msg.result) == "table" and rebuild_after_compaction then
            rebuild_after_compaction(session, msg.result, msg.willRetry == true)
        else
            chat:set_compacting(false)
            restore_active_agent_status(chat)
            chat:flush_compaction_queue(msg.willRetry == true)
        end
    elseif t == "auto_retry_start" then
        chat:set_status({ type = "agent", text = "Retrying…" })
    elseif t == "auto_retry_end" then
        if msg.success == false then
            chat:set_status(nil)
            chat:on_error(
                "Retry failed after "
                    .. tostring(msg.attempt or 0)
                    .. " attempts: "
                    .. (msg.finalError or "Unknown error"),
                { pad_top = true, pad_bottom = true }
            )
        else
            restore_active_agent_status(chat)
        end
    elseif t == "summarization_retry_scheduled" then
        chat:on_error(msg.errorMessage, { pad_top = true, pad_bottom = true })
        chat:set_status({ type = "agent", text = "Retrying summary…" })
    elseif t == "summarization_retry_attempt_start" then
        if msg.source == "compaction" then
            chat:set_status({ type = "compaction" })
        else
            chat:set_status({ type = "agent", text = "Summarizing branch…" })
        end
    elseif t == "summarization_retry_finished" then
        restore_active_agent_status(chat)
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
            chat:on_process_exit(msg.code, msg.expected == true)
        end)
    elseif t == "response" then
        -- Callbacks reconcile the submitted input; command failures are also
        -- shown in history. Failures after acceptance use the event stream.
        if msg.success == false and type(msg.error) == "string" then
            chat:on_error(msg.error, { pad_top = true, pad_bottom = true })
        end
        return false
    elseif t == "message_start" then
        chat:on_message_start(msg)
    elseif t == "message_end" then
        chat:on_message_end(msg)
        local message = msg.message
        if type(message) == "table" and (message.role == "assistant" or message.role == "toolResult") then
            M.refresh_stats(session)
            if message.role == "toolResult" then
                track_nested_files(session, message)
            end
        end
        if type(message) == "table" and message.role == "toolResult" and session._pending_file_change_args then
            local tool_call_id = message.toolCallId or message.toolUseId
            if type(tool_call_id) == "string" and tool_call_id ~= "" then
                if message.isError ~= true then
                    local args = session._pending_file_change_args[tool_call_id]
                    track_changed_file(session, args)
                end
                session._pending_file_change_args[tool_call_id] = nil
            end
        end
    elseif t == "tool_execution_update" then
        if not msg.parentToolCallId then
            chat:on_tool_update(msg.toolName or "tool", msg.toolCallId, msg)
        end
    elseif ignored_events[t] then
        return true
    else
        session.rpc:log_unhandled(t)
        return false
    end

    return true
end

---@param session pi.Session
---@param flush_queue? boolean default true
---@param will_retry? boolean
finish_compaction_rebuild = function(session, flush_queue, will_retry)
    local queued = session._compaction_event_queue or {}
    session._compaction_event_queue = {}
    session._compaction_rebuilding = false
    session.chat:set_compacting(false)
    restore_active_agent_status(session.chat)
    if flush_queue ~= false then
        session.chat:flush_compaction_queue(will_retry == true)
    end

    for i, queued_msg in ipairs(queued) do
        if session._compaction_rebuilding then
            local active_queue = session._compaction_event_queue or {}
            for j = i, #queued do
                active_queue[#active_queue + 1] = queued[j]
            end
            session._compaction_event_queue = active_queue
            return
        end
        handle_event(session, queued_msg)
    end
end

--- Get the session for the current tab. Returns nil if none exists.
---@return pi.Session?
function M.get()
    local tab = current_tab()
    return sessions[tab]
end

--- Get the session for a tab. Returns nil if none exists.
---@param tab pi.TabId
---@return pi.Session?
function M.get_for_tab(tab)
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

---@type table<pi.TabId, fun(session: pi.Session?)[]>
local creating = {}

--- Start a session for a tab with a resolved execution.
---@param tab pi.TabId
---@param workspace string
---@param execution pi.Execution
---@param opts pi.SessionCreateOpts
---@return pi.Session?
local function start_session(tab, workspace, execution, opts)
    local commands = CommandCatalog.new()
    local rpc = Rpc.new(tab, workspace, commands, execution:launch())

    if not rpc:start() then
        return nil
    end

    local layout = opts.layout or Config.resolve_default_layout_mode()

    ---@type pi.ChatAgent
    local agent = {
        send = function(msg, callback)
            return rpc:send(msg, callback)
        end,
    }

    local chat = Chat.new(tab, layout, agent)

    ---@type pi.Session
    local session = {
        tab = tab,
        workspace = workspace,
        execution = execution,
        commands = commands,
        rpc = rpc,
        chat = chat,
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        changed_files = {},
    }

    rpc:set_handler(function(msg)
        handle_event(session, msg)
    end)

    sessions[tab] = session

    local draft = recovered_drafts[tab]
    if draft then
        chat:restore_draft(draft)
        recovered_drafts[tab] = nil
    end

    -- Fetch available /commands for completion, highlighting, and system info
    fetch_commands_and_show_startup_block(session)

    -- Fetch initial state for status line (model, thinking level)
    M.refresh_state(session)

    return session
end

--- Ask before starting local pi in a workspace that used a descriptor.
---@param workspace string
---@param cb fun(confirmed: boolean)
local function confirm_local_after_descriptor(workspace, cb)
    Dialog.select({
        title = "pi descriptor missing",
        message = "This workspace used a pi descriptor before, but it's gone:\n"
            .. Descriptor.path(workspace)
            .. "\n\nStart pi locally on this machine instead?",
        options = { "Start local Pi", "Cancel" },
    }, function(choice)
        cb(choice == "Start local Pi")
    end)
end

--- Prompt replaceable for tests.
M._confirm_local_after_descriptor = confirm_local_after_descriptor

--- Get the current tab's session, creating it when needed. Creation resolves
--- the workspace's descriptor first, which may prompt, so the result arrives
--- through `cb` (nil when nothing was started).
---@param opts? pi.SessionCreateOpts
---@param cb fun(session: pi.Session?)
function M.get_or_create(opts, cb)
    opts = opts or {}
    local tab = current_tab()

    local session = sessions[tab]
    if session then
        cb(session)
        return
    end
    if creating[tab] then
        table.insert(creating[tab], cb)
        return
    end
    creating[tab] = { cb }

    local workspace = Workspace.tab_cwd(tab)

    ---@param created pi.Session?
    local function finish(created)
        local waiters = creating[tab] or {}
        creating[tab] = nil
        for _, waiter in ipairs(waiters) do
            waiter(created)
        end
    end

    ---@param execution pi.Execution
    local function launch(execution)
        if not vim.api.nvim_tabpage_is_valid(tab) then
            finish(nil)
            return
        end
        finish(start_session(tab, workspace, execution, opts))
    end

    Descriptor.resolve(workspace, function(result)
        local kind = result.kind
        if kind == "local" then
            launch(Execution.new_local(workspace))
        elseif kind == "descriptor" then
            launch(Execution.new_descriptor(workspace, result.spec, result.path))
        elseif kind == "missing_after_use" then
            M._confirm_local_after_descriptor(workspace, function(confirmed)
                if not confirmed then
                    finish(nil)
                    return
                end
                local ok, err = ExecState.clear_workspace(Workspace.realpath(workspace))
                if not ok then
                    Notify.error("Could not clear the descriptor record: " .. tostring(err))
                    finish(nil)
                    return
                end
                launch(Execution.new_local(workspace))
            end)
        elseif kind == "cancelled" then
            Notify.info("pi wasn't started: the workspace descriptor isn't trusted")
            finish(nil)
        elseif kind == "error" then
            Notify.error("pi wasn't started: " .. result.message)
            finish(nil)
        else
            error("unknown execution resolution: " .. tostring(kind))
        end
    end)
end

--- Notify about a stop that didn't end cleanly.
---@param report pi.StopReport
local function notify_stop_report(report)
    local what = ({
        exit = "exited with code " .. tostring(report.code),
        timeout = "didn't stop in time and was force-stopped",
        forced = "was force-stopped",
    })[report.outcome] or report.outcome
    local lines = {
        ("pi launch `%s` %s (%s, %s)"):format(
            report.command,
            what,
            report.workspace,
            report.descriptor and ("descriptor " .. report.descriptor) or "local pi"
        ),
    }
    vim.list_extend(lines, report.stderr)
    Notify.warn(table.concat(lines, "\n"))
end

--- Stop a session's launch in the background and report a stop that didn't end cleanly.
---@param session pi.Session
local function stop_launch(session)
    session.rpc:stop(function(report)
        if report then
            vim.schedule(function()
                notify_stop_report(report)
            end)
        end
    end)
end

--- Remove and clean up a session for the current tab.
function M.stop()
    local tab = current_tab()
    local session = sessions[tab]
    if not session then
        return
    end

    if not session.rpc:is_running() and session.chat:has_draft() then
        recovered_drafts[tab] = session.chat:snapshot_draft()
    end
    Attention.clear_session(session)
    stop_launch(session)
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
                session.startup_announcements = {}
                session.system_errors = {}
                session.changed_files = {}
                session._pending_file_change_args = nil
                session.chat:clear()
                fetch_commands_and_show_startup_block(session)
                M.refresh_state(session)
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
    local tool_call_args = {} ---@type table<string, table>
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
                            args = normalize_tool_args(part.arguments or part.args or part.input),
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
                    if tc.args then
                        tool_call_args[tc.id] = tc.args
                    end
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
            -- Track files changed by edit/write tools during replay.
            local tc_args = not is_error and tool_call_args[tool_call_id]
            if tc_args then
                track_changed_file(session, tc_args)
            end
            track_nested_files(session, msg)
        elseif role == "compactionSummary" then
            if pending_agent_end then
                session.chat:on_agent_end()
                pending_agent_end = false
            end
            session.chat:append_compaction_summary(msg.summary or "", tonumber(msg.tokensBefore) or 0)
        end
    end
    -- Flush any remaining pending agent_end
    if pending_agent_end then
        session.chat:on_agent_end()
    end
    session.chat:set_replaying(false)
end

---@param session pi.Session
---@param _result table
---@param will_retry boolean
rebuild_after_compaction = function(session, _result, will_retry)
    session._compaction_rebuilding = true
    session._compaction_event_queue = {}
    if will_retry then
        session.chat:flush_compaction_queue(true)
    end

    local sent = session.rpc:send({ type = "get_messages" }, function(res)
        vim.schedule(function()
            if not res.success then
                local err = res.error or "Failed to load compacted session messages"
                Notify.error(err)
                session.chat:on_error(err, { pad_top = true, pad_bottom = true })
                finish_compaction_rebuild(session, not will_retry, will_retry)
                return
            end

            local messages = (res.data or {}).messages or {}
            session.changed_files = {}
            session._pending_file_change_args = nil
            session.chat:clear_for_compaction_rebuild()
            show_startup_block(session, session.commands:list())
            replay_messages(session, messages)
            M.refresh_state(session)
            vim.schedule(function()
                finish_compaction_rebuild(session, not will_retry, will_retry)
            end)
        end)
    end)
    if not sent then
        finish_compaction_rebuild(session, false)
    end
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
            session.changed_files = {}
            session._pending_file_change_args = nil
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
                session.commands:fetch(session.rpc, function(commands)
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

--- A saved session in the picker or for continue. `path` is the session file
--- as pi sees it (what `switch_session` receives); `file` is the same file
--- on the host, for preview and delete.
---@class pi.StoredSession
---@field path string
---@field file string
---@field id string
---@field timestamp string
---@field name? string
---@field first_message string

--- Saved sessions of a connection's pi, newest first, or nil (after notifying)
--- when pi has none the host can list. Reads the folder pi reports, through the
--- connection's path mapping when pi runs in a separate filesystem.
---@param session pi.Session
---@return pi.StoredSession[]?
local function list_saved_sessions(session)
    if session.persistent == false then
        Notify.info("This pi has no persistent sessions (for example, it runs with --no-session)")
        return nil
    end
    local session_dir = session.session_dir
    if not session_dir then
        Notify.error("Pi did not report its session folder")
        return nil
    end
    local execution = session.execution
    local host_dir = execution:to_host(session_dir)
    if not host_dir then
        Notify.error(
            ("pi's session folder %s isn't reachable from the host; map it in the descriptor's `paths.mounts` (%s)"):format(
                session_dir,
                execution:label()
            )
        )
        return nil
    end
    local infos = require("pi.sessions.history").list(host_dir, function(cwd)
        return execution:is_workspace_cwd(cwd)
    end)
    ---@type pi.StoredSession[]
    local items = {}
    for _, info in ipairs(infos) do
        local rel = info.path:sub(#host_dir + 2)
        items[#items + 1] = {
            path = vim.fs.joinpath(session_dir, rel),
            file = info.path,
            id = info.id,
            timestamp = info.timestamp,
            name = info.name,
            first_message = info.first_message,
        }
    end
    return items
end

---@param sessions_list pi.StoredSession[]
---@param current_session_file? string
---@return string?
local function find_continue_session_path(sessions_list, current_session_file)
    for _, info in ipairs(sessions_list) do
        if info.path ~= current_session_file then
            return info.path
        end
    end
    return nil
end

--- Tear down a session that a session lookup started, keeping any recovered draft.
---@param session pi.Session
local function discard_started_session(session)
    if sessions[session.tab] ~= session then
        return
    end
    if session.chat:has_draft() then
        recovered_drafts[session.tab] = session.chat:snapshot_draft()
    end
    Attention.clear_session(session)
    stop_launch(session)
    session.chat:hide()
    session.chat:clear()
    sessions[session.tab] = nil
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

--- Continue the most recent saved session of the current tab's pi.
--- Starts pi first when the tab has none, because only a running pi knows its
--- session folder. With no previous session, the fresh pi stays open as a new chat.
---@param opts? pi.SessionCreateOpts
function M.continue_session(opts)
    local existing = M.get()
    M.get_or_create(opts, function(session)
        if not session then
            return
        end
        M.refresh_state(session, function(ok, state)
            if sessions[session.tab] ~= session then
                return
            end
            if not ok or not state then
                if not existing then
                    session.chat:ensure_shown_and_focus_prompt()
                end
                return
            end
            if existing and not is_empty_session_state(session, state) then
                return
            end

            local sessions_list = list_saved_sessions(session)
            if not sessions_list then
                session.chat:ensure_shown_and_focus_prompt()
                return
            end
            local session_path = find_continue_session_path(sessions_list, state.sessionFile)
            if not session_path then
                show_no_previous_sessions(session)
                return
            end
            session.chat:show({ loading = true })
            load_session(session, session_path)
        end)
    end)
end

--- Show a picker to resume a past session of the current tab's pi.
--- Starts pi first when the tab has none; that pi is stopped again when no
--- sessions exist or the picker is cancelled. An already running pi is kept.
---@param opts? pi.SessionCreateOpts
function M.resume_session(opts)
    local existing = M.get()
    M.get_or_create(opts, function(session)
        if not session then
            return
        end

        local function give_up()
            if not existing then
                discard_started_session(session)
            end
        end

        M.refresh_state(session, function(ok)
            if sessions[session.tab] ~= session then
                return
            end
            if not ok then
                give_up()
                return
            end
            local sessions_list = list_saved_sessions(session)
            if not sessions_list then
                give_up()
                return
            end
            if #sessions_list == 0 then
                Notify.info("No sessions found")
                give_up()
                return
            end
            M._pick_session(session, sessions_list, give_up)
        end)
    end)
end

--- Picker over saved sessions; loads the chosen one into `session`.
---@param session pi.Session
---@param sessions_list pi.StoredSession[]
---@param on_cancel fun()
function M._pick_session(session, sessions_list, on_cancel)
    ---@class pi.SessionSelectItem
    ---@field session pi.StoredSession
    ---@field file string Host file, for snacks.nvim's preview and delete.

    ---@type pi.SessionSelectItem[]
    local items = {}
    for i, stored in ipairs(sessions_list) do
        items[i] = {
            session = stored,
            file = stored.file,
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
            local label = session.name or (session.first_message ~= "" and session.first_message or "(empty)")
            return date .. "  " .. label
        end,
        snacks = {
            -- snacks.nvim (if installed) overrides vim.ui.select with its picker.
            -- It has a bug where the list height can be non-integer, crashing
            -- nvim_win_set_config. This `snacks` key is merged into the picker
            -- config and overrides the broken height calculation with math.floor.
            -- Safe to include even if snacks isn't used — the key is just ignored.
            layout = {
                config = function(layout)
                    for _, box in ipairs(layout.layout) do
                        if box.win == "list" then
                            box.height = math.floor(math.max(math.min(#items, vim.o.lines * 0.8 - 10), 2))
                        end
                    end
                end,
            },
            win = {
                input = { keys = { ["<C-x>"] = { "delete_session", mode = { "i", "n" }, desc = "Delete session" } } },
                list = { keys = { ["<C-x>"] = { "delete_session", mode = { "n" }, desc = "Delete session" } } },
            },
            actions = {
                delete_session = function(picker)
                    local selected = picker:selected({ fallback = true })
                    if #selected == 0 then
                        return
                    end
                    local n = #selected
                    local msg = n == 1 and "Delete session?" or ("Delete %d sessions?"):format(n)
                    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
                        return
                    end
                    ---@type table<string, boolean>
                    local deleted = {}
                    for _, sel in ipairs(selected) do
                        local path = sel.item.file
                        local ok, err = os.remove(path)
                        if ok then
                            deleted[path] = true
                        else
                            Notify.warn("Failed to delete session: " .. (err or path))
                        end
                    end
                    for i = #items, 1, -1 do
                        if deleted[items[i].file] then
                            table.remove(items, i)
                        end
                    end
                    if #items == 0 then
                        picker:close()
                        Notify.info("No sessions remaining")
                    else
                        picker:refresh()
                    end
                end,
            },
        },
    }, function(item)
        if sessions[session.tab] ~= session then
            return
        end
        if not item then
            on_cancel()
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
            stop_launch(session)
            sessions[tab] = nil
        end
    end
    for tab in pairs(recovered_drafts) do
        if not valid_tabs[tab] then
            recovered_drafts[tab] = nil
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
            end
            require("pi.execution.cleanup").stop_all_on_exit()
        end,
    })

    vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            for _, session in pairs(sessions) do
                if session.chat:is_visible() then
                    session.chat:on_resize()
                end
            end
        end,
    })
end

return M
