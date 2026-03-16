--- Shared key-binding utilities.

local M = {}

--- Bind a `pi.KeySpec` to a buffer.
---
--- When `key` is a plain string the mapping uses `default_modes` (or `"n"`).
--- When `key` is a table its `.modes` field overrides `default_modes`.
---
---@param buf integer Buffer handle
---@param key pi.KeySpec Key specification
---@param handler function Callback
---@param opts? { modes?: string|string[], desc?: string, nowait?: boolean }
function M.bind(buf, key, handler, opts)
    opts = opts or {}
    local default_modes = opts.modes or "n"
    local map_opts = { buffer = buf, desc = opts.desc, nowait = opts.nowait }

    if type(key) == "string" then
        vim.keymap.set(default_modes, key, handler, map_opts)
    elseif type(key) == "table" then
        vim.keymap.set(key.modes or default_modes, key[1], handler, map_opts)
    end
end

--- Extract the display LHS from a `pi.KeySpec`.
---@param key pi.KeySpec
---@return string
function M.lhs(key)
    if type(key) == "table" then
        return key[1]
    end
    return key --[[@as string]]
end

return M
