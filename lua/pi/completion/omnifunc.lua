--- completefunc fallback for @-mention and commands completion.
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

    local prefix = base:sub(2) -- strip @
    return Matcher.complete(prefix, function(path)
        return { word = "@" .. path, kind = "f", menu = "[Pi]" }
    end)
end

return M
