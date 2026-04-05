--- Pi public API.

---@class Pi
local M = {}

local Config = require("pi.config")

local is_initialized = false

---@param chat pi.Chat
---@param mode? pi.LayoutMode
local function show_chat(chat, mode)
    if mode and chat:layout() ~= mode then
        chat:set_layout(mode)
        chat:focus_prompt()
    else
        chat:ensure_shown_and_focus_prompt()
    end
end

---@param opts? pi.Options
function M.setup(opts)
    Config.setup(opts)

    if is_initialized then
        return
    end

    is_initialized = true

    vim.treesitter.language.register("markdown", require("pi.filetypes").history)
    require("pi.ui.highlights").setup()
    require("pi.attention").setup_autocmds()
    require("pi.sessions.manager").setup_autocmds()
    require("pi.commands").setup()
    require("pi.ui.winfix").setup()
end

--- Show the chat and focus the prompt. Creates a session if none exists.
---@param opts? pi.SessionCreateOpts
function M.show(opts)
    local Sessions = require("pi.sessions.manager")
    local existing = Sessions.get()
    if existing then
        show_chat(existing.chat, opts and opts.layout or nil)
        return
    end

    local session = Sessions.get_or_create(opts)
    if session then
        session.chat:ensure_shown_and_focus_prompt()
    end
end

--- Toggle the chat. If a layout is given and the chat is visible in another
--- layout, switch to that layout instead of hiding. Creates a session if none exists.
---@param opts? pi.SessionCreateOpts
function M.toggle(opts)
    local Sessions = require("pi.sessions.manager")
    local existing = Sessions.get()
    if not existing then
        local session = Sessions.get_or_create(opts)
        if session then
            session.chat:ensure_shown_and_focus_prompt()
        end
        return
    end

    local requested_layout = opts and opts.layout or nil
    if existing.chat:is_visible() then
        if requested_layout and existing.chat:layout() ~= requested_layout then
            existing.chat:set_layout(requested_layout)
            existing.chat:focus_prompt()
        else
            existing.chat:hide()
        end
        return
    end

    show_chat(existing.chat, requested_layout)
end

--- Continue the most recent session for the current cwd.
---@param opts? pi.SessionCreateOpts
function M.continue_session(opts)
    require("pi.sessions.manager").continue_session(opts)
end

--- Show a picker to resume a past session.
---@param opts? pi.SessionCreateOpts
function M.resume_session(opts)
    require("pi.sessions.manager").resume_session(opts)
end

--- Toggle chat visibility. No-op if no session exists.
function M.toggle_chat()
    local session = require("pi.sessions.manager").get()
    if not session then
        return
    end
    session.chat:toggle()
end

--- Toggle between side and float layout. No-op if no session exists.
--- If given, callback runs after pi has switched layouts, focused the new
--- prompt window, and requested insert mode.
---@param cb? fun(layout: pi.LayoutMode)
function M.toggle_layout(cb)
    local session = require("pi.sessions.manager").get()
    if not session then
        return
    end
    if cb then
        session.chat:toggle_layout(function()
            cb(session.chat:layout())
        end)
    else
        session.chat:toggle_layout()
    end
end

--- Check whether the chat is currently visible.
---@return boolean
function M.is_visible()
    local session = require("pi.sessions.manager").get()
    return session ~= nil and session.chat:is_visible()
end

--- Return the current chat layout mode.
--- Returns nil if no session is active.
---@return pi.LayoutMode?
function M.layout()
    local session = require("pi.sessions.manager").get()
    if not session then
        return nil
    end
    return session.chat:layout()
end

--- Abort the current agent operation.
function M.abort()
    local session = require("pi.sessions.manager").get()
    if session and session.rpc:is_running() then
        require("pi.attention").clear_session(session)
        session.rpc:send({ type = "abort" })
    end
end

--- Stop the process and close the chat.
function M.stop()
    require("pi.sessions.manager").stop()
end

--- Open the next queued π attention request.
---@return boolean opened
function M.attention()
    return require("pi.attention").open_next()
end

--- Count active attention requests for a tab.
--- Pass nil or 0 for the current tab.
---@param tab? pi.TabId|0
---@return integer
function M.attention_count(tab)
    return require("pi.attention").count(tab)
end

--- Count active attention requests across all tabs.
---@return integer
function M.attention_total()
    return require("pi.attention").total_count()
end

--- Return a snapshot of the current attention state.
---@param current_tab? pi.TabId|0
---@return pi.AttentionState
function M.attention_state(current_tab)
    return require("pi.attention").state(current_tab)
end

---@param tab? pi.TabId|0
---@return boolean
function M.has_attention(tab)
    return require("pi.attention").has_attention(tab)
end

--- Start a new conversation in the current session.
function M.new_session()
    require("pi.sessions.manager").new_session()
end

--- Toggle thinking block visibility.
function M.toggle_thinking()
    local session = require("pi.sessions.manager").get()
    if session then
        require("pi.thinking").toggle(session)
    end
end

--- Toggle the startup block between compact and expanded.
function M.toggle_startup_details()
    local session = require("pi.sessions.manager").get()
    if session then
        session.chat:toggle_startup_block(false)
    end
end

--- Cycle to the next thinking level.
function M.cycle_thinking_level()
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("pi.notify").warn("No active session")
        return
    end
    require("pi.thinking").cycle(session)
end

--- Select a thinking level from a picker.
function M.select_thinking_level()
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("pi.notify").warn("No active session")
        return
    end
    require("pi.thinking").select(session)
end

--- Cycle to the next model.
--- If `models` is configured, cycles within the resolved subset.
function M.cycle_model()
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("pi.notify").warn("No active session")
        return
    end
    require("pi.models").cycle(session)
end

--- Select a model from configured models (or all if none configured).
--- Uses Dialog.select for the curated list.
function M.select_model()
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("pi.notify").warn("No active session")
        return
    end
    require("pi.models").select(session)
end

--- Select a model from all available models using vim.ui.select (searchable).
function M.select_model_all()
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("pi.notify").warn("No active session")
        return
    end
    require("pi.models").select_all(session)
end

--- Send an @-mention to the prompt.
--- With no args or command args: mentions current buffer (with visual selection if any).
--- With a loc table: mentions the given path and optional line range.
---@param args? table|{ path: string, start_line?: integer, end_line?: integer }
---@param opts? { focus?: boolean } default: focus = true
function M.send_mention(args, opts)
    local Mentions = require("pi.ui.chat.mentions")
    if args and args.path then
        Mentions.send(args, opts)
    else
        Mentions.send_current(args, opts)
    end
end

--- Attach an image file to the prompt.
---@param path string
---@return boolean
function M.attach_image(path)
    local session = require("pi.sessions.manager").get()
    if session then
        return session.chat:attach_image(path)
    end
    return false
end

--- Paste an image from clipboard as an attachment.
---@return boolean
function M.paste_image()
    local session = require("pi.sessions.manager").get()
    if session then
        local in_prompt = vim.bo.filetype == require("pi.filetypes").prompt
        local cursor = in_prompt and vim.api.nvim_win_get_cursor(0) or nil
        local ok = session.chat:attach_from_clipboard()
        if ok and cursor then
            vim.schedule(function()
                pcall(vim.api.nvim_win_set_cursor, 0, cursor)
                vim.cmd("startinsert")
            end)
        end
        return ok
    end
    return false
end

--- Manually compact conversation context.
---@param custom_instructions? string optional instructions to guide compaction
function M.compact(custom_instructions)
    local Notify = require("pi.notify")
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        Notify.warn("No active session")
        return
    end
    if session.chat:is_streaming() then
        Notify.warn("Cannot compact while streaming")
        return
    end

    session.chat:set_status({ type = "compaction" })

    ---@type table
    local cmd = { type = "compact" }
    if custom_instructions and custom_instructions ~= "" then
        cmd.customInstructions = custom_instructions
    end

    session.rpc:send(cmd, function(res)
        vim.schedule(function()
            session.chat:set_status(nil)
            if res.success then
                session.chat:reset_usage()
            else
                Notify.error("Compaction failed: " .. (res.error or "unknown error"))
            end
        end)
    end)
end

--- Set or show the session display name.
--- With no argument, shows the current name. With a name, sets it.
---@param name? string session name to set (nil to show current)
function M.set_session_name(name)
    local Notify = require("pi.notify")
    local Dialog = require("pi.ui.dialog")
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        Notify.warn("No active session")
        return
    end

    if name and name ~= "" then
        session.rpc:send({ type = "set_session_name", name = name }, function(res)
            vim.schedule(function()
                if res.success then
                    Notify.info("Session name set: " .. name)
                else
                    Notify.error("Failed to set session name: " .. (res.error or "unknown error"))
                end
            end)
        end)
        return
    end

    -- No name provided — prompt for one, pre-filling with current name
    session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            if not res.success then
                Notify.error("Failed to get session state")
                return
            end
            Dialog.input({
                title = "Session Name",
                default = res.data and res.data.sessionName or "",
            }, function(value)
                if value and value ~= "" then
                    M.set_session_name(value)
                end
            end)
        end)
    end)
end

--- Toggle RPC debug logging.
function M.toggle_debug()
    require("pi.rpc").toggle_debug()
end

--- Scroll the chat history by a number of lines.
--- Can be called from the prompt buffer to scroll without leaving it.
---@param direction "up"|"down"
---@param lines? integer lines to scroll (default 15)
function M.scroll_chat_history(direction, lines)
    local session = require("pi.sessions.manager").get()
    if session then
        session.chat:scroll_history(direction, lines)
    end
end

--- Scroll the chat history to the bottom (most recent message).
function M.scroll_chat_history_to_bottom()
    local session = require("pi.sessions.manager").get()
    if session then
        session.chat:scroll_history_to_bottom()
    end
end

--- Scroll the chat history to the start of the most recent agent response.
function M.scroll_chat_history_to_last_agent_response()
    local session = require("pi.sessions.manager").get()
    if session then
        session.chat:scroll_history_to_last_agent_response()
    end
end

--- Focus the chat history window.
function M.focus_chat_history()
    local session = require("pi.sessions.manager").get()
    if session then
        session.chat:focus_history()
    end
end

--- Focus the chat prompt window.
function M.focus_chat_prompt()
    local session = require("pi.sessions.manager").get()
    if session then
        session.chat:focus_prompt()
    end
end

--- Focus the chat attachments window.
function M.focus_chat_attachments()
    local session = require("pi.sessions.manager").get()
    if session then
        session.chat:focus_attachments()
    end
end

--- Invoke an extension command on the current session.
--- Accepts with or without leading "/" (e.g. "toggle-auto-accept" or "/toggle-auto-accept").
---@param command string
function M.invoke(command)
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("pi.notify").warn("No active session")
        return
    end
    if command:sub(1, 1) ~= "/" then
        command = "/" .. command
    end
    session.rpc:send({ type = "prompt", message = command })
end

--- Return the list of file paths modified by edit/write tools during the current session.
--- Returns an empty table if no session is active or no files have been changed.
---@return string[]
function M.changed_files()
    local session = require("pi.sessions.manager").get()
    if not session then
        return {}
    end
    return vim.tbl_keys(session.changed_files)
end

return M
