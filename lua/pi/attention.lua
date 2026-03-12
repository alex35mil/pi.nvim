--- Pending attention state for blocking extension UI requests.
--- Raw pending entries are owned by sessions; this module provides the
--- cross-session API, aggregation, timer pruning, and redraw hooks.

local M = {}

local Dialog = require("pi.ui.dialog")
local Diff = require("pi.ui.diff")
local Notify = require("pi.notify")

---@alias pi.AttentionKind "diff"|"select"|"confirm"|"input"|"editor"

---@class pi.AttentionEntry
---@field id string
---@field seq integer Global arrival order across sessions
---@field kind pi.AttentionKind
---@field expires_at integer?
---@field open fun(): boolean opened

---@class pi.AttentionTabState
---@field count integer

---@class pi.AttentionState
---@field current_tab pi.TabId
---@field current_tab_count integer
---@field total_count integer
---@field tabs table<pi.TabId, pi.AttentionTabState>

local uv = vim.uv or vim.loop
local redraw_scheduled = false
local autocmds_set = false
local prune_timer = nil ---@type uv.uv_timer_t?
local next_seq = 0

local prune_stale_queue
local reschedule_timer

---@return pi.Session[]
local function sessions()
    return require("pi.sessions.manager").list()
end

---@return integer
local function now_ms()
    return uv.now()
end

---@param session pi.Session
---@return pi.AttentionEntry[]
local function pending_entries(session)
    if not session.attention then
        session.attention = { pending = {} }
    end
    return session.attention.pending
end

local function request_redraw()
    if redraw_scheduled then
        return
    end
    redraw_scheduled = true
    vim.schedule(function()
        redraw_scheduled = false
        pcall(vim.cmd, "redrawstatus!")
        pcall(vim.cmd, "redrawtabline")
        local session = require("pi.sessions.manager").get()
        if session then
            session.chat:render_statusline()
            session.chat:refresh_prompt_attention()
        end
    end)
end

local function close_timer()
    if not prune_timer then
        return
    end
    pcall(prune_timer.stop, prune_timer)
    if not prune_timer:is_closing() then
        prune_timer:close()
    end
    prune_timer = nil
end

---@return uv.uv_timer_t
local function ensure_timer()
    if prune_timer and not prune_timer:is_closing() then
        return prune_timer
    end
    prune_timer = assert(uv.new_timer())
    return prune_timer
end

---@param tab? pi.TabId|0
---@return pi.TabId
local function resolve_tab(tab)
    if tab == nil or tab == 0 then
        return vim.api.nvim_get_current_tabpage()
    end
    return tab
end

---@return integer
local function next_attention_seq()
    next_seq = next_seq + 1
    return next_seq
end

---@param title string?
---@return table?
local function decode_diff_payload(title)
    local ok, payload = pcall(vim.json.decode, title or "")
    if ok and payload and (payload.toolName == "edit" or payload.toolName == "write") then
        return payload
    end
    return nil
end

---@param session pi.Session
---@param cmd pi.RpcCommand
local function send_response(session, cmd)
    if session.rpc:is_running() then
        session.rpc:send(cmd)
    end
end

---@param session pi.Session
---@param entry pi.AttentionEntry
---@param now? integer
---@return boolean
local function is_stale(session, entry, now)
    now = now or now_ms()
    if not session.rpc:is_running() then
        return true
    end
    if not vim.api.nvim_tabpage_is_valid(session.tab) then
        return true
    end
    return entry.expires_at ~= nil and now >= entry.expires_at
end

---@param session pi.Session
---@param entry pi.AttentionEntry
---@param now? integer
---@return boolean
local function is_visible(session, entry, now)
    if is_stale(session, entry, now) then
        return false
    end
    local transition_seq = session.attention and session.attention.transition_seq or nil
    return transition_seq == nil or entry.seq > transition_seq
end

---@param current_tab? pi.TabId|0
---@return pi.AttentionState
local function build_state(current_tab)
    local state = {
        current_tab = resolve_tab(current_tab),
        current_tab_count = 0,
        total_count = 0,
        tabs = {},
    }

    local now = now_ms()

    for _, session in ipairs(sessions()) do
        for _, entry in ipairs(pending_entries(session)) do
            if is_visible(session, entry, now) then
                state.total_count = state.total_count + 1
                local tab_state = state.tabs[session.tab]
                if not tab_state then
                    tab_state = {
                        count = 0,
                    }
                    state.tabs[session.tab] = tab_state
                end
                tab_state.count = tab_state.count + 1
            end
        end
    end

    local current = state.tabs[state.current_tab]
    state.current_tab_count = current and current.count or 0
    return state
end

---@param session pi.Session
---@param entry pi.AttentionEntry
local function emit_requested(session, entry)
    local state = build_state(session.tab)
    local tab_state = state.tabs[session.tab] or { count = 0 }
    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "PiAttentionRequested",
        modeline = false,
        data = {
            tab = session.tab,
            kind = entry.kind,
            tab_count = tab_state.count,
            total_count = state.total_count,
        },
    })
end

---@param kind pi.AttentionKind
---@return string
local function kind_label(kind)
    if kind == "diff" then
        return "diff review"
    elseif kind == "confirm" then
        return "confirmation"
    elseif kind == "select" then
        return "selection"
    elseif kind == "editor" then
        return "editor input"
    end
    return "input"
end

---@param session pi.Session
---@param entry pi.AttentionEntry
local function notify_pending(session, entry)
    local suffix = session.tab == vim.api.nvim_get_current_tabpage() and "" or " in another tab"
    Notify.warn("Agent needs " .. kind_label(entry.kind) .. suffix .. " — run :PiAttention")
end

---@param kind pi.AttentionKind
local function notify_expired(kind)
    Notify.warn(kind_label(kind) .. " request expired")
end

---@param expires_at integer?
---@return integer?
local function remaining_timeout_ms(expires_at)
    if expires_at == nil then
        return nil
    end
    return expires_at - now_ms()
end

---@param session pi.Session
---@param msg pi.RpcEvent
---@return pi.AttentionEntry?
local function build_entry(session, msg)
    local id = tostring(msg.id or "")
    local expires_at = type(msg.timeout) == "number" and (now_ms() + msg.timeout) or nil

    if msg.method == "select" then
        local payload = decode_diff_payload(msg.title)
        if payload then
            return {
                id = id,
                seq = next_attention_seq(),
                kind = "diff",
                expires_at = expires_at,
                open = function()
                    local timeout = remaining_timeout_ms(expires_at)
                    if timeout ~= nil and timeout <= 0 then
                        return false
                    end
                    Diff.open(payload, function(result)
                        send_response(session, { type = "extension_ui_response", id = id, value = result })
                    end, {
                        timeout = timeout,
                        on_timeout = function()
                            notify_expired("diff")
                        end,
                    })
                    return true
                end,
            }
        end

        return {
            id = id,
            seq = next_attention_seq(),
            kind = "select",
            expires_at = expires_at,
            open = function()
                local timeout = remaining_timeout_ms(expires_at)
                if timeout ~= nil and timeout <= 0 then
                    return false
                end
                Dialog.select({
                    title = "Select",
                    message = msg.title,
                    options = msg.options or {},
                    timeout = timeout,
                    on_timeout = function()
                        notify_expired("select")
                    end,
                }, function(choice)
                    if choice then
                        send_response(session, { type = "extension_ui_response", id = id, value = choice })
                    else
                        send_response(session, { type = "extension_ui_response", id = id, cancelled = true })
                    end
                end)
                return true
            end,
        }
    end

    if msg.method == "confirm" then
        return {
            id = id,
            seq = next_attention_seq(),
            kind = "confirm",
            expires_at = expires_at,
            open = function()
                local timeout = remaining_timeout_ms(expires_at)
                if timeout ~= nil and timeout <= 0 then
                    return false
                end
                Dialog.confirm({
                    title = msg.title,
                    message = msg.message --[[@as string?]],
                    timeout = timeout,
                    on_timeout = function()
                        notify_expired("confirm")
                    end,
                }, function(confirmed)
                    if confirmed then
                        send_response(session, { type = "extension_ui_response", id = id, confirmed = true })
                    else
                        send_response(session, { type = "extension_ui_response", id = id, cancelled = true })
                    end
                end)
                return true
            end,
        }
    end

    if msg.method == "input" or msg.method == "editor" then
        return {
            id = id,
            seq = next_attention_seq(),
            kind = msg.method,
            expires_at = expires_at,
            open = function()
                local timeout = remaining_timeout_ms(expires_at)
                if timeout ~= nil and timeout <= 0 then
                    return false
                end
                Dialog.input({
                    title = msg.title or "Input",
                    default = msg.prefill or msg.placeholder or "",
                    timeout = timeout,
                    on_timeout = function()
                        notify_expired(msg.method --[[@as pi.AttentionKind]])
                    end,
                }, function(value)
                    if value then
                        send_response(session, { type = "extension_ui_response", id = id, value = value })
                    else
                        send_response(session, { type = "extension_ui_response", id = id, cancelled = true })
                    end
                end)
                return true
            end,
        }
    end

    return nil
end

---@param session pi.Session
---@param predicate fun(entry: pi.AttentionEntry): boolean
---@return integer removed
local function remove_matching(session, predicate)
    local removed = 0
    local pending = pending_entries(session)
    for i = #pending, 1, -1 do
        if predicate(pending[i]) then
            table.remove(pending, i)
            removed = removed + 1
        end
    end
    return removed
end

---@param session pi.Session
function M.begin_session_transition(session)
    if not session.attention then
        session.attention = { pending = {} }
    end
    if session.attention.transition_seq ~= nil then
        return
    end
    session.attention.transition_seq = next_seq
    request_redraw()
end

---@param session pi.Session
---@param committed boolean
function M.end_session_transition(session, committed)
    local transition_seq = session.attention and session.attention.transition_seq or nil
    if transition_seq == nil then
        return
    end
    if committed then
        remove_matching(session, function(entry)
            return entry.seq <= transition_seq
        end)
    end
    session.attention.transition_seq = nil
    reschedule_timer(true)
    request_redraw()
end

---@param skip_prune? boolean
reschedule_timer = function(skip_prune)
    if prune_timer then
        pcall(prune_timer.stop, prune_timer)
    end

    local now = now_ms()
    local next_delay = nil ---@type integer?
    local has_stale = false

    for _, session in ipairs(sessions()) do
        for _, entry in ipairs(pending_entries(session)) do
            if is_stale(session, entry, now) then
                has_stale = true
            elseif entry.expires_at ~= nil then
                local delay = math.max(0, entry.expires_at - now)
                next_delay = next_delay and math.min(next_delay, delay) or delay
            end
        end
    end

    if has_stale and not skip_prune then
        prune_stale_queue()
        return
    end

    if next_delay == nil then
        return
    end

    ensure_timer():start(
        next_delay,
        0,
        vim.schedule_wrap(function()
            prune_stale_queue()
        end)
    )
end

prune_stale_queue = function()
    local removed = 0
    local now = now_ms()
    for _, session in ipairs(sessions()) do
        removed = removed
            + remove_matching(session, function(entry)
                return is_stale(session, entry, now)
            end)
    end
    reschedule_timer(true)
    if removed > 0 then
        request_redraw()
    end
end

--- Present a blocking extension UI request immediately only when the π
--- prompt has focus and there is no draft; otherwise queue it for later.
---@param session pi.Session
---@param msg pi.RpcEvent
---@return boolean handled
function M.present(session, msg)
    local entry = build_entry(session, msg)
    if not entry then
        return false
    end

    if session.chat:has_prompt_focus() and not session.chat:has_draft() then
        if not entry.open() then
            notify_expired(entry.kind)
        end
        return true
    end

    remove_matching(session, function(existing)
        return existing.id == entry.id
    end)
    local pending = pending_entries(session)
    pending[#pending + 1] = entry
    reschedule_timer()
    request_redraw()
    notify_pending(session, entry)
    emit_requested(session, entry)
    return true
end

--- Open the oldest queued attention request, switching to its tab if needed.
---@return boolean opened
function M.open_next()
    prune_stale_queue()

    local expired = false

    while true do
        local best_session = nil ---@type pi.Session?
        local best_index = nil ---@type integer?
        local best_entry = nil ---@type pi.AttentionEntry?

        for _, session in ipairs(sessions()) do
            for i, entry in ipairs(pending_entries(session)) do
                if is_visible(session, entry) and (not best_entry or entry.seq < best_entry.seq) then
                    best_session = session
                    best_index = i
                    best_entry = entry
                end
            end
        end

        if not best_session or not best_index or not best_entry then
            if not expired then
                Notify.info("No pending π requests")
            end
            return false
        end

        table.remove(pending_entries(best_session), best_index)
        reschedule_timer(true)
        request_redraw()

        local timeout = remaining_timeout_ms(best_entry.expires_at)
        if timeout ~= nil and timeout <= 0 then
            notify_expired(best_entry.kind)
            expired = true
        else
            if best_session.tab ~= vim.api.nvim_get_current_tabpage() then
                vim.api.nvim_set_current_tabpage(best_session.tab)
            end
            if best_entry.open() then
                return true
            end
            notify_expired(best_entry.kind)
            expired = true
        end
    end
end

--- Remove all queued requests for a session.
---@param session pi.Session
function M.clear_session(session)
    local pending = pending_entries(session)
    local removed = #pending
    if removed == 0 then
        return
    end
    session.attention.pending = {}
    reschedule_timer(true)
    request_redraw()
end

--- Count active attention requests for a tab.
--- Pass nil or 0 for the current tab.
---@param tab? pi.TabId|0
---@return integer
function M.count(tab)
    return build_state(tab).current_tab_count
end

--- Count active attention requests across all tabs.
---@return integer
function M.total_count()
    return build_state().total_count
end

---@param tab? pi.TabId|0
---@return boolean
function M.has_attention(tab)
    return M.count(tab) > 0
end

--- Return a snapshot of the current attention state.
---@param current_tab? pi.TabId|0
---@return pi.AttentionState
function M.state(current_tab)
    return build_state(current_tab)
end

--- Backwards-compatible alias for global count.
---@return integer
function M.pending_count()
    return M.total_count()
end

function M.setup_autocmds()
    if autocmds_set then
        return
    end
    autocmds_set = true

    vim.api.nvim_create_autocmd("TabEnter", {
        callback = function()
            request_redraw()
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            close_timer()
        end,
    })
end

return M
