--- User-command and slash-command adapters over the Pi API.

---@class pi.NvimCommands
local NvimCommands = {}

---@class pi.SlashCommands
local SlashCommands = {}

---@type table<string, string[]>
local flag_values = { layout = { "side", "float" } }

---@param args string
---@return pi.SessionCreateOpts
local function parse_flags(args)
    ---@type pi.SessionCreateOpts
    local flags = {}
    local layout = args:match("layout=(%S+)")
    if layout == "side" or layout == "float" then
        flags.layout = layout
    end
    return flags
end

---@param prefix string
---@return string[]
local function complete_flags(prefix)
    ---@type string[]
    local candidates = {}
    for k, vals in pairs(flag_values) do
        for _, v in ipairs(vals) do
            candidates[#candidates + 1] = k .. "=" .. v
        end
    end
    table.sort(candidates)
    return vim.tbl_filter(function(c)
        return c:find(prefix, 1, true) == 1
    end, candidates)
end

--- Register Neovim's :Pi commands.
function NvimCommands.setup()
    local Pi = require("pi")

    vim.api.nvim_create_user_command("Pi", function(cmd)
        Pi.toggle(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Show or toggle π chat" })

    vim.api.nvim_create_user_command("PiContinue", function(cmd)
        Pi.continue_session(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Continue last π conversation" })

    vim.api.nvim_create_user_command("PiResume", function(cmd)
        Pi.resume_session(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Select a past π conversation" })

    vim.api.nvim_create_user_command("PiToggleChat", function()
        Pi.toggle_chat()
    end, { desc = "Toggle π chat window" })

    vim.api.nvim_create_user_command("PiToggleLayout", function()
        Pi.toggle_layout()
    end, { desc = "Toggle π layout (side/float)" })

    vim.api.nvim_create_user_command("PiAbort", function()
        Pi.abort()
    end, { desc = "Abort current π operation" })

    vim.api.nvim_create_user_command("PiStop", function()
        Pi.stop()
    end, { desc = "Stop π process and close chat" })

    vim.api.nvim_create_user_command("PiAttention", function()
        Pi.attention()
    end, { desc = "Open the next pending π attention request" })

    vim.api.nvim_create_user_command("PiNewSession", function()
        Pi.new_session()
    end, { desc = "Start new π session" })

    vim.api.nvim_create_user_command("PiClear", function()
        Pi.new_session()
    end, { desc = "Clear chat and start a fresh π session" })

    vim.api.nvim_create_user_command("PiToggleThinking", function()
        Pi.toggle_thinking()
    end, { desc = "Toggle π thinking visibility" })

    vim.api.nvim_create_user_command("PiToggleStartupDetails", function()
        Pi.toggle_startup_details()
    end, { desc = "Toggle π startup details between compact and expanded" })

    vim.api.nvim_create_user_command("PiCycleThinking", function()
        Pi.cycle_thinking_level()
    end, { desc = "Cycle π thinking level" })

    vim.api.nvim_create_user_command("PiSelectThinking", function()
        Pi.select_thinking_level()
    end, { desc = "Select π thinking level" })

    vim.api.nvim_create_user_command("PiCycleModel", function()
        Pi.cycle_model()
    end, { desc = "Cycle π model" })

    vim.api.nvim_create_user_command("PiSelectModel", function()
        Pi.select_model()
    end, { desc = "Select π model" })

    vim.api.nvim_create_user_command("PiSelectModelAll", function()
        Pi.select_model_all()
    end, { desc = "Select π model from all available (searchable)" })

    vim.api.nvim_create_user_command("PiSendMention", function(args)
        Pi.send_mention(args)
    end, { range = true, desc = "Send file or selection as @mention to Pi prompt" })

    vim.api.nvim_create_user_command("PiAttachImage", function(cmd)
        Pi.attach_image(cmd.args)
    end, { nargs = 1, complete = "file", desc = "Attach image file at path to π prompt" })

    vim.api.nvim_create_user_command("PiPasteImage", function()
        Pi.paste_image()
    end, { desc = "Paste an image from the clipboard as π attachment" })

    vim.api.nvim_create_user_command("PiCompact", function(cmd)
        local instructions = cmd.args ~= "" and cmd.args or nil
        Pi.compact(instructions)
    end, { nargs = "?", desc = "Compact π conversation context" })

    vim.api.nvim_create_user_command("PiSessionName", function(cmd)
        local name = cmd.args ~= "" and cmd.args or nil
        Pi.set_session_name(name)
    end, { nargs = "?", desc = "Set or show π session display name" })

    vim.api.nvim_create_user_command("PiToggleDebug", function()
        Pi.toggle_debug()
    end, { desc = "Toggle π RPC debug logging" })
end

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
function SlashCommands.list()
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
---@return string? error
function SlashCommands.execute(text)
    local name, args = text:match("^/([^%s]+)%s*(.*)$")
    if not name then
        return false
    end
    for _, command in ipairs(commands) do
        if command.name == name then
            if text:find("\n", 1, true) then
                return true, "/" .. name .. " must be sent on its own line"
            end
            command.run(args)
            return true
        end
    end
    return false
end

return { NvimCommands = NvimCommands, SlashCommands = SlashCommands }
