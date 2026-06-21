--- Shared key-binding utilities.

--- A single key specification: plain string or table with modes override.
---@alias pi.KeySpec string|{ [1]: string, modes: string|string[] }

--- One or more key specifications.
---@alias pi.KeySpecs pi.KeySpec|pi.KeySpec[]

local M = {}

--- Normalize a `pi.KeySpecs` value into a list of `pi.KeySpec`.
---
--- Accepts any of:
---   - `"<Esc>"` (string)
---   - `{ "<C-q>", modes = { "n", "i" } }` (single table spec with `.modes`)
---   - `{ "<Esc>", { "<C-q>", modes = "i" } }` (list of specs)
---   - `nil` → empty list
---
---@param keyspecs pi.KeySpecs|nil
---@return pi.KeySpec[]
function M.resolve(keyspecs)
    if keyspecs == nil then
        return {}
    end
    if type(keyspecs) == "string" then
        return { keyspecs }
    end
    -- Table with .modes → single KeySpec.
    if type(keyspecs) == "table" and keyspecs.modes then
        return { keyspecs }
    end
    -- Table of KeySpecs.
    return keyspecs --[[@as pi.KeySpec[] ]]
end

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
        vim.keymap.set(M.normalize_modes(default_modes), key, handler, map_opts)
    elseif type(key) == "table" then
        vim.keymap.set(M.modes(key, default_modes), key[1], handler, map_opts)
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

--- Normalize an lhs for effective-key comparisons.
---@param lhs string
---@return string
function M.normalize_lhs(lhs)
    local normalized = lhs:gsub("<([^>]+)>", function(token)
        return "<" .. token:lower() .. ">"
    end)
    return vim.api.nvim_replace_termcodes(normalized, true, true, true)
end

--- Normalize a mode string/table to a mode list.
---@param modes string|string[]
---@return string[]
function M.normalize_modes(modes)
    if type(modes) == "table" then
        return modes
    end
    local result = {}
    for i = 1, #modes do
        result[#result + 1] = modes:sub(i, i)
    end
    return result
end

--- Resolve the modes for a `pi.KeySpec`, falling back to defaults.
---@param key pi.KeySpec
---@param default_modes string|string[]
---@return string[]
function M.modes(key, default_modes)
    if type(key) == "table" and key.modes then
        return M.normalize_modes(key.modes)
    end
    return M.normalize_modes(default_modes)
end

--- Bind arrow keys to move by display line, so wrapped text is navigable.
---@param buf integer Buffer handle
function M.bind_wrapped_line_navigation(buf)
    vim.api.nvim_buf_set_keymap(buf, "i", "<Up>", "<C-o>g<Up>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, "i", "<Down>", "<C-o>g<Down>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, "n", "<Up>", "g<Up>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, "n", "<Down>", "g<Down>", { noremap = true, silent = true })
end

return M
