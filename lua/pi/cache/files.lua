--- Project file listing with per-workspace cache for completion and mention validation.

---@class pi.FileCache
---@field files string[]
---@field map table<string, true>
---@field timestamp number

local M = {}

---@type table<string, pi.FileCache>
local caches = {}

local CACHE_TTL_NS = 5e9 -- 5 seconds

--- Check if a buffer is a pi prompt buffer.
---@param buf? integer
---@return boolean
function M.is_pi_prompt_buf(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local ft = require("pi.filetypes")
    return vim.bo[buf].filetype == ft.prompt
end

--- List files (relative to the workspace) in a workspace directory.
---@param workspace string
---@return string[]
local function scan(workspace)
    local result = vim.system(
        { "git", "ls-files", "--cached", "--others", "--exclude-standard" },
        { text = true, cwd = workspace }
    ):wait()

    if result.code == 0 and result.stdout and result.stdout ~= "" then
        return vim.split(vim.trim(result.stdout), "\n", { plain = true, trimempty = true })
    end

    -- Not a git repository: list regular files, skipping hidden ones like `glob("**/*")`.
    local files = {}
    for name, kind in
        vim.fs.dir(workspace, {
            depth = math.huge,
            skip = function(dir_name)
                return not vim.startswith(vim.fs.basename(dir_name), ".")
            end,
        })
    do
        if kind == "file" and not vim.startswith(vim.fs.basename(name), ".") then
            files[#files + 1] = name
        end
    end
    return files
end

--- Get a workspace's project files (relative paths). Cached for 5s per workspace.
---@param workspace string
---@return string[]
function M.list(workspace)
    local now = vim.uv.hrtime()
    local cache = caches[workspace]
    if cache and (now - cache.timestamp) < CACHE_TTL_NS then
        return cache.files
    end

    local files = scan(workspace)
    local map = {}
    for _, f in ipairs(files) do
        map[f] = true
    end
    caches[workspace] = { files = files, map = map, timestamp = now }
    return files
end

--- Check if a path (relative to the workspace, or absolute) exists.
---@param workspace string
---@param path string
---@return boolean
function M.exists(workspace, path)
    M.list(workspace)
    local cache = caches[workspace]
    if cache and cache.map[path] then
        return true
    end
    local abs = require("pi.workspace").resolve(workspace, path)
    return vim.uv.fs_stat(abs) ~= nil
end

--- Invalidate a workspace's cached listing, or every listing when omitted.
---@param workspace? string
function M.invalidate(workspace)
    if workspace then
        caches[workspace] = nil
    else
        caches = {}
    end
end

return M
