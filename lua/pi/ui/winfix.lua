--- Window option isolation for plugin windows.
---
--- Problem: windows created from pi windows (split, tabnew) inherit pi's
--- window-local options (nonumber, signcolumn=no, etc.).
---
--- Solution: capture the user's window option defaults at setup time, before
--- any pi windows exist. On BufEnter, detect windows that inherited pi's
--- options via a multi-option fingerprint and reset them to the captured
--- defaults.

local M = {}

local Ft = require("pi.filetypes")

--- Options that pi sets on its windows.
---@type string[]
local OPTION_NAMES = {
    "wrap",
    "linebreak",
    "number",
    "relativenumber",
    "signcolumn",
    "foldcolumn",
    "foldenable",
    "list",
    "conceallevel",
    "concealcursor",
    "cursorline",
    "winfixbuf",
    "winfixheight",
    "winfixwidth",
    "winbar",
    "winhighlight",
    "virtualedit",
}

--- Pi filetypes whose windows should keep pi options.
local PI_FILETYPES = {
    [Ft.history] = true,
    [Ft.prompt] = true,
    [Ft.attachments] = true,
}

--- User defaults captured at setup time.
---@type table<string, any>
local user_defaults = {}

--- Check whether a window carries pi's option fingerprint.
--- Tests options that set_win_opts always sets for UI reasons.
---@param win integer
---@return boolean
local function has_pi_fingerprint(win)
    return vim.wo[win].concealcursor == "nvic"
        and not vim.wo[win].number
        and not vim.wo[win].relativenumber
        and not vim.wo[win].cursorline
end

--- Capture user defaults and set up the BufEnter autocmd. Must be called
--- once during plugin setup, before any pi windows are opened.
function M.setup()
    for _, name in ipairs(OPTION_NAMES) do
        user_defaults[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
    end

    vim.api.nvim_create_autocmd("BufEnter", {
        callback = function(ev)
            if PI_FILETYPES[vim.bo[ev.buf].filetype] then
                return
            end
            local win = vim.api.nvim_get_current_win()
            if not has_pi_fingerprint(win) then
                return
            end
            for name, default in pairs(user_defaults) do
                pcall(vim.api.nvim_set_option_value, name, default, { win = win })
            end
        end,
    })
end

return M
