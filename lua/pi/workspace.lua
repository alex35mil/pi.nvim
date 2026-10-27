--- Workspace resolution: the project directory a tab's pi connection works in.
---
--- A live session's workspace is the directory pi was launched in and never
--- changes for that connection. Without a session, a tab's workspace is its
--- effective working directory: tab-local (`:tcd`) or global. Window-local
--- `:lcd` directories are ignored.

local M = {}

--- Buffer variable holding the tab that owns a pi prompt buffer.
M.PROMPT_TAB_VAR = "pi_tab"

--- Effective working directory of a tab, ignoring window-local `:lcd`.
---@param tab pi.TabId
---@return string
function M.tab_cwd(tab)
    local ok, tabnr = pcall(vim.api.nvim_tabpage_get_number, tab)
    if not ok then
        return vim.fn.getcwd(-1, -1)
    end
    return vim.fn.getcwd(-1, tabnr)
end

--- Workspace for a tab: its live session's workspace, else the tab's effective cwd.
---@param tab pi.TabId
---@return string
function M.for_tab(tab)
    local session = require("pi.sessions.manager").get_for_tab(tab)
    if session then
        return session.workspace
    end
    return M.tab_cwd(tab)
end

--- Tab that owns a pi prompt buffer, or the current tab for any other buffer.
---@param buf? integer
---@return pi.TabId
function M.prompt_tab(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local ok, tab = pcall(function()
        return vim.b[buf][M.PROMPT_TAB_VAR]
    end)
    if ok and type(tab) == "number" and vim.api.nvim_tabpage_is_valid(tab) then
        return tab
    end
    return vim.api.nvim_get_current_tabpage()
end

--- Resolve a path against a workspace. Absolute and `~` paths are used as given.
---@param workspace string
---@param path string
---@return string
function M.resolve(workspace, path)
    local expanded = vim.fs.normalize(path)
    if vim.startswith(expanded, "/") or expanded:match("^%a:[\\/]") then
        return expanded
    end
    return vim.fs.normalize(vim.fs.joinpath(workspace, expanded))
end

--- Make an absolute path relative to a workspace when it lies inside it.
---@param workspace string
---@param path string
---@return string
function M.relative(workspace, path)
    local root = vim.fs.normalize(workspace):gsub("/+$", "")
    local target = vim.fs.normalize(path)
    if target == root then
        return "."
    end
    if vim.startswith(target, root .. "/") then
        return target:sub(#root + 2)
    end
    return target
end

--- Real path with symlinks resolved; falls back to the normalized path when it doesn't exist.
---@param path string
---@return string
function M.realpath(path)
    return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

return M
