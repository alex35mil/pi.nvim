--- completefunc fallback for @-mention and /command completion.
--- Triggered via <C-x><C-u> in the pi prompt buffer.

local M = {}

local Matcher = require("pi.completion")

---@param findstart integer
---@param base string
---@return integer|table[]
function M.completefunc(findstart, base)
    if findstart == 1 then
        local line = vim.api.nvim_get_current_line()
        local col = vim.fn.col(".") - 1

        -- Check for / at start of line (commands)
        local cursor_row = vim.fn.line(".")
        if cursor_row == 1 and line:byte(1) == 47 then -- /
            return 0
        end

        -- Check for @ (mentions)
        while col > 0 do
            col = col - 1
            local byte = line:byte(col + 1)
            if byte == 64 then -- @
                return col
            end
            if byte == 32 then -- space
                return -3
            end
        end
        return -3
    end

    -- /command completion
    if base:byte(1) == 47 then -- /
        local prefix = base:sub(2)
        return Matcher.complete_commands(prefix, function(cmd, _is_fuzzy)
            local detail = cmd.source
            if cmd.description then
                detail = detail .. ": " .. cmd.description
            end
            return { word = "/" .. cmd.name, kind = "c", menu = "[Pi]", info = detail }
        end)
    end

    -- @mention completion
    local prefix = base:sub(2) -- strip @
    return Matcher.complete_files(prefix, function(path)
        return { word = "@" .. path, kind = "f", menu = "[Pi]" }
    end)
end

return M
