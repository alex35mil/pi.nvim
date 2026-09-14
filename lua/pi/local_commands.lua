--- Neovim-native slash commands that mirror Pi TUI harness actions.

local M = {}

---@class pi.LocalCommand : pi.SlashCommand
---@field run fun(args: string)

---@type pi.LocalCommand[]
local commands = {
    {
        name = "abort",
        description = "Abort the active agent turn",
        source = "pi.nvim",
        run = function()
            require("pi").abort()
        end,
    },
    {
        name = "clear",
        description = "Start a fresh, resumable session",
        source = "pi.nvim",
        run = function()
            require("pi").new_session()
        end,
    },
    {
        name = "compact",
        description = "Compact context, optionally with instructions",
        source = "pi.nvim",
        run = function(args)
            require("pi").compact(args ~= "" and args or nil)
        end,
    },
    {
        name = "model",
        description = "Select the active model",
        source = "pi.nvim",
        run = function()
            require("pi").select_model()
        end,
    },
    {
        name = "name",
        description = "Set or show the session name",
        source = "pi.nvim",
        run = function(args)
            require("pi").set_session_name(args ~= "" and args or nil)
        end,
    },
    {
        name = "new",
        description = "Start a fresh session",
        source = "pi.nvim",
        run = function()
            require("pi").new_session()
        end,
    },
    {
        name = "resume",
        description = "Select a previous session",
        source = "pi.nvim",
        run = function()
            require("pi").resume_session()
        end,
    },
    {
        name = "thinking",
        description = "Select the thinking level",
        source = "pi.nvim",
        run = function()
            require("pi").select_thinking_level()
        end,
    },
}

---@return pi.SlashCommand[]
function M.list()
    local result = {}
    for _, command in ipairs(commands) do
        result[#result + 1] = {
            name = command.name,
            description = command.description,
            source = command.source,
        }
    end
    return result
end

---@param text string
---@return boolean handled
function M.execute(text)
    local name, args = text:match("^/([^%s]+)%s*(.*)$")
    if not name then
        return false
    end
    for _, command in ipairs(commands) do
        if command.name == name then
            command.run(args)
            return true
        end
    end
    return false
end

return M
