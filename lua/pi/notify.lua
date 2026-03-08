local M = {}

local PREFIX = "π │ "

---@param msg string
function M.debug(msg)
    vim.notify(PREFIX .. msg, vim.log.levels.DEBUG)
end

---@param msg string
function M.info(msg)
    vim.notify(PREFIX .. msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
    vim.notify(PREFIX .. msg, vim.log.levels.WARN)
end

---@param msg string
function M.error(msg)
    vim.notify(PREFIX .. msg, vim.log.levels.ERROR)
end

return M
