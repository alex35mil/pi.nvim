--- Slash-command catalogs — pi.nvim actions combined with commands fetched over Pi RPC.
---
--- Each session owns one catalog, so commands fetched by one tab's pi never
--- replace another tab's completion, highlighting, or startup data.

---@class pi.SourceInfo
---@field path string absolute file path to the command source
---@field source string source identifier
---@field scope? "user"|"project"|"temporary"
---@field origin? string
---@field baseDir? string

---@class pi.SlashCommand
---@field name string command name (invoke with /name)
---@field description? string human-readable description
---@field source "extension"|"prompt"|"skill"|"pi.nvim"
---@field sourceInfo? pi.SourceInfo structured source metadata from pi RPC

---@class pi.CommandCatalog
---@field _commands pi.SlashCommand[]
---@field _fetched boolean
---@field _last_fetch_time number
local Catalog = {}
Catalog.__index = Catalog

local SlashCommands = require("pi.commands").SlashCommands

local REFETCH_INTERVAL_NS = 30e9 -- 30 seconds

--- Create a catalog holding only pi.nvim's built-in commands.
---@return pi.CommandCatalog
function Catalog.new()
    local self = setmetatable({}, Catalog)
    self._commands = SlashCommands.list()
    self._fetched = false
    self._last_fetch_time = 0
    return self
end

--- Catalog for a tab's live session, or a built-ins-only catalog when the tab has none.
---@param tab pi.TabId
---@return pi.CommandCatalog
function Catalog.for_tab(tab)
    local session = require("pi.sessions.manager").get_for_tab(tab)
    if session then
        return session.commands
    end
    return Catalog.new()
end

--- Catalog for the session owning a pi prompt buffer (current buffer by default).
---@param buf? integer
---@return pi.CommandCatalog
function Catalog.for_buf(buf)
    return Catalog.for_tab(require("pi.workspace").prompt_tab(buf))
end

--- Replace the backend command list, keeping pi.nvim's built-in names reserved.
---@param commands pi.SlashCommand[]
function Catalog:set(commands)
    local list = SlashCommands.list()
    local reserved = {}
    for _, command in ipairs(list) do
        reserved[command.name] = true
    end
    for _, command in ipairs(commands) do
        if not reserved[command.name] then
            list[#list + 1] = command
        end
    end
    self._commands = list
    self._fetched = true
end

--- Current command list (built-ins only until the first fetch completes).
---@return pi.SlashCommand[]
function Catalog:list()
    return self._commands
end

--- Whether backend commands have been received at least once.
---@return boolean
function Catalog:is_ready()
    return self._fetched
end

--- Fetch commands over RPC and update this catalog.
---@param rpc pi.Rpc
---@param callback? fun(commands: pi.SlashCommand[])
function Catalog:fetch(rpc, callback)
    self._last_fetch_time = vim.uv.hrtime()
    rpc:send({ type = "get_commands" }, function(msg)
        if msg.success and msg.data and msg.data.commands then
            self:set(msg.data.commands)
        end
        if callback then
            vim.schedule(function()
                callback(self._commands)
            end)
        end
    end)
end

--- Refetch commands if enough time has passed since the last fetch.
---@param rpc pi.Rpc
function Catalog:refresh(rpc)
    if vim.uv.hrtime() - self._last_fetch_time >= REFETCH_INTERVAL_NS then
        self:fetch(rpc)
    end
end

--- Find commands matching a prefix (case-insensitive).
--- Skills are also matched by their short name (after "skill:").
---@param prefix string typed text after /
---@return pi.SlashCommand[]
function Catalog:match(prefix)
    if prefix == "" then
        return self._commands
    end
    local lprefix = prefix:lower()
    ---@type pi.SlashCommand[]
    local matches = {}
    for _, cmd in ipairs(self._commands) do
        local lname = cmd.name:lower()
        if lname:sub(1, #lprefix) == lprefix then
            matches[#matches + 1] = cmd
        elseif cmd.source == "skill" then
            local short = lname:match("^skill:(.+)$")
            if short and short:sub(1, #lprefix) == lprefix then
                matches[#matches + 1] = cmd
            end
        end
    end
    return matches
end

return Catalog
