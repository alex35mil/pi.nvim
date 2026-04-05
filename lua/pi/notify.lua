local M = {}

local PREFIX = "π │ "

--- Notify with explicit level and extra options.
---@param msg string
---@param level integer vim.log.levels.*
---@param opts? table Extra options passed to vim.notify (e.g. id, timeout)
function M.dispatch(msg, level, opts)
    vim.notify(PREFIX .. msg, level, opts or {})
end

---@param msg string
function M.debug(msg)
    M.dispatch(msg, vim.log.levels.DEBUG)
end

---@param msg string
function M.info(msg)
    M.dispatch(msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
    M.dispatch(msg, vim.log.levels.WARN)
end

---@param msg string
function M.error(msg)
    M.dispatch(msg, vim.log.levels.ERROR)
end

return M
