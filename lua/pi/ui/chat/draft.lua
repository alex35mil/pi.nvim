--- Prompt draft sync: reports the draft as `User PiDraftChanged` at
--- checkpoints, and replaces it from outside unless the user edited it since
--- the last checkpoint ("local edits win").

---@class pi.DraftInput
---@field text string
---@field attachments? pi.Attachment[] nil or empty: no attachments

---@class pi.DraftChangedData
---@field tab pi.TabId
---@field session_id? string nil until pi reports it
---@field session_file? string as pi sees it; nil until pi reports it (or with no session file)
---@field text string
---@field attachments pi.Attachment[]

--- Result of replacing a tab's draft.
---@alias pi.SetDraftResult
---| { status: "applied" }
---| { status: "no_session" } # the tab has no pi session
---| { status: "local_edits" } # the draft changed since its last checkpoint; nothing was replaced

--- Where a replacement comes from.
---@alias pi.DraftOrigin
---| "caller" # `pi.set_draft`: the caller already has this draft, so it isn't reported back
---| "pi" # an extension's `set_editor_text`: reported like any other change

---@class pi.ChatDraftSync
---@field _tab pi.TabId
---@field _prompt pi.ChatPrompt
---@field _attachments pi.ChatAttachments
---@field _session fun(): pi.Session? The live session that owns this chat, if any.
---@field _checkpoint string Fingerprint of the draft last reported or applied.
---@field _timer? uv.uv_timer_t Debounce timer, created on the first text change.
local DraftSync = {}
DraftSync.__index = DraftSync

local Config = require("pi.config")

---@param text string
---@param items pi.ChatAttachment[]
---@return string
local function fingerprint(text, items)
    local parts = { text }
    for _, item in ipairs(items) do
        parts[#parts + 1] = item.name
        parts[#parts + 1] = item.mime
        parts[#parts + 1] = item.digest
    end
    return table.concat(parts, "\0")
end

---@param tab pi.TabId
---@param prompt pi.ChatPrompt
---@param attachments pi.ChatAttachments
---@param session fun(): pi.Session?
---@return pi.ChatDraftSync
function DraftSync.new(tab, prompt, attachments, session)
    local self = setmetatable({}, DraftSync)
    self._tab = tab
    self._prompt = prompt
    self._attachments = attachments
    self._session = session
    self._checkpoint = fingerprint("", {})
    self._timer = nil

    local buf = prompt:buf()
    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
            self:_schedule_report()
        end,
    })
    vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
        buffer = buf,
        desc = "Report the π prompt draft when leaving the prompt",
        callback = function()
            self:report()
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if self._timer then
                self._timer:stop()
                if not self._timer:is_closing() then
                    self._timer:close()
                end
                self._timer = nil
            end
        end,
    })
    attachments:on_change(function(change)
        -- A replacement sets its own checkpoint once the text is in place too.
        if change ~= "replaced" then
            self:report()
        end
    end)
    return self
end

--- (Re)start the debounce after a text change.
function DraftSync:_schedule_report()
    if not self._timer then
        self._timer = assert(vim.uv.new_timer())
    end
    self._timer:stop()
    self._timer:start(
        Config.options.draft.debounce_ms,
        0,
        vim.schedule_wrap(function()
            self:report()
        end)
    )
end

---@return string
function DraftSync:_current()
    return fingerprint(self._prompt:text(), self._attachments:items())
end

--- Checkpoint: report the draft unless it equals the last one reported or
--- applied. Only a chat that belongs to a live session reports.
function DraftSync:report()
    if self._timer then
        self._timer:stop()
    end
    local session = self._session()
    if not session then
        return
    end
    local text = self._prompt:text()
    local items = self._attachments:items()
    local current = fingerprint(text, items)
    if current == self._checkpoint then
        return
    end
    self._checkpoint = current
    ---@type pi.Attachment[]
    local attachments = {}
    for i, item in ipairs(items) do
        attachments[i] = { name = item.name, data = item.data, mime = item.mime }
    end
    ---@type pi.DraftChangedData
    local data = {
        tab = self._tab,
        session_id = session.session_id,
        session_file = session.execution:session_file(),
        text = text,
        attachments = attachments,
    }
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "PiDraftChanged", modeline = false, data = data })
end

--- Replace the draft unless the user edited it since the last checkpoint.
--- `attachments = nil` keeps the current attachments (text-only replacement).
--- Never moves focus or changes the mode.
---@param text string
---@param attachments? pi.Attachment[]
---@param origin pi.DraftOrigin
---@return "applied"|"local_edits"
function DraftSync:replace(text, attachments, origin)
    if self:_current() ~= self._checkpoint then
        return "local_edits"
    end
    self._prompt:replace_text(text)
    if attachments then
        self._attachments:replace(attachments)
    end
    if origin == "caller" then
        self._checkpoint = self:_current()
    elseif origin == "pi" then
        self:report()
    else
        error("unknown draft origin: " .. tostring(origin))
    end
    return "applied"
end

return DraftSync
