--- Shared file listing with cache for completion and mention validation.

---@class pi.FileCache
---@field files string[]
---@field map table<string, true>
---@field cwd string
---@field timestamp number

local M = {}

---@type pi.FileCache?
local cache = nil

local CACHE_TTL_NS = 5e9 -- 5 seconds

--- Check if a buffer is a pi prompt buffer.
---@param buf? integer
---@return boolean
function M.is_pi_prompt_buf(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local ft = require("pi.filetypes")
    return vim.bo[buf].filetype == ft.prompt
end

--- Get project files (relative paths). Cached for 5s.
---@return string[]
function M.list()
    local cwd = vim.fn.getcwd()
    local now = vim.uv.hrtime()
    if cache and cache.cwd == cwd and (now - cache.timestamp) < CACHE_TTL_NS then
        return cache.files
    end

    local files = {}
    local result = vim.system(
        { "git", "ls-files", "--cached", "--others", "--exclude-standard" },
        { text = true, cwd = cwd }
    )
        :wait()

    if result.code == 0 and result.stdout and result.stdout ~= "" then
        files = vim.split(vim.trim(result.stdout), "\n", { plain = true, trimempty = true })
    else
        local raw = vim.fn.glob("**/*", false, true)
        for _, f in ipairs(raw) do
            if vim.fn.isdirectory(f) == 0 then
                files[#files + 1] = f
            end
        end
    end

    local map = {}
    for _, f in ipairs(files) do
        map[f] = true
    end

    cache = { files = files, map = map, timestamp = now, cwd = cwd }
    return files
end

--- Check if a relative path exists in the project.
---@param path string
---@return boolean
function M.exists(path)
    M.list()
    if cache and cache.map[path] then
        return true
    end
    local abs = vim.fn.fnamemodify(path, ":p")
    return vim.fn.filereadable(abs) == 1
end

--- Invalidate the cache.
function M.invalidate()
    cache = nil
end

return M
