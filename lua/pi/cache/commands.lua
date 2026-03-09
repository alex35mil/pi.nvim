--- Slash-command cache — fetches available /commands from the pi RPC process.

---@class pi.SlashCommand
---@field name string command name (invoke with /name)
---@field description? string human-readable description
---@field source "extension"|"prompt"|"skill"
---@field location? "user"|"project"|"path"
---@field path? string absolute file path to the command source

local M = {}

---@type pi.SlashCommand[]
local cache = {}

---@type boolean
local fetched = false

---@type number
local last_fetch_time = 0

local REFETCH_INTERVAL_NS = 30e9 -- 30 seconds

--- Replace the cached command list.
---@param commands pi.SlashCommand[]
function M.set(commands)
    cache = commands
    fetched = true
end

--- Get the cached command list (may be empty if not yet fetched).
---@return pi.SlashCommand[]
function M.list()
    return cache
end

--- Whether commands have been fetched at least once.
---@return boolean
function M.is_ready()
    return fetched
end

--- Clear the cache so the next access triggers a fresh fetch.
function M.invalidate()
    cache = {}
    fetched = false
end

--- Fetch commands from an RPC session and update the cache.
---@param rpc pi.Rpc
---@param callback? fun(commands: pi.SlashCommand[])
function M.fetch(rpc, callback)
    last_fetch_time = vim.uv.hrtime()
    rpc:send({ type = "get_commands" }, function(msg)
        if msg.success and msg.data and msg.data.commands then
            M.set(msg.data.commands)
        end
        if callback then
            vim.schedule(function()
                callback(cache)
            end)
        end
    end)
end

--- Refetch commands if enough time has passed since the last fetch.
---@param rpc pi.Rpc
function M.refresh(rpc)
    local now = vim.uv.hrtime()
    if now - last_fetch_time >= REFETCH_INTERVAL_NS then
        M.fetch(rpc)
    end
end

--- Find commands matching a prefix (case-insensitive).
--- Skills are also matched by their short name (after "skill:").
---@param prefix string typed text after /
---@return pi.SlashCommand[]
function M.match(prefix)
    if prefix == "" then
        return cache
    end
    local lprefix = prefix:lower()
    ---@type pi.SlashCommand[]
    local matches = {}
    for _, cmd in ipairs(cache) do
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

return M
