--- Path mapping between the host and the paths pi sees inside its environment.
---
--- Used only for pi in a separate filesystem (a descriptor with `paths`). The
--- workspace (host) maps to `paths.workspace`, plus any `paths.mounts`. The
--- most specific matching prefix wins. Paths outside every entry are unmapped:
--- callers refuse them instead of guessing.

---@class pi.PathMap
---@field _entries { host: string, exec: string }[] Sorted longest prefix first.
---@field workspace string Host workspace.
---@field workspace_exec string Workspace path as pi sees it.
local PathMap = {}
PathMap.__index = PathMap

---@param p string
---@return string
local function clean(p)
    local n = vim.fs.normalize(p)
    if #n > 1 then
        n = n:gsub("/+$", "")
    end
    return n
end

---@param path string
---@param prefix string
---@return string? rest
local function strip(path, prefix)
    if path == prefix then
        return ""
    end
    if prefix == "/" then
        return path:sub(2)
    end
    if vim.startswith(path, prefix .. "/") then
        return path:sub(#prefix + 2)
    end
    return nil
end

---@param base string
---@param rest string
---@return string
local function join(base, rest)
    if rest == "" then
        return base
    end
    if base == "/" then
        return "/" .. rest
    end
    return base .. "/" .. rest
end

--- Build a mapping for a workspace.
---@param workspace string host workspace
---@param paths pi.DescriptorPaths
---@return pi.PathMap
function PathMap.new(workspace, paths)
    local self = setmetatable({}, PathMap)
    self.workspace = clean(workspace)
    self.workspace_exec = clean(paths.workspace)
    self._entries = { { host = self.workspace, exec = self.workspace_exec } }
    for _, m in ipairs(paths.mounts) do
        self._entries[#self._entries + 1] = { host = clean(m.host), exec = clean(m.path) }
    end
    return self
end

---@param path string
---@param from "host"|"exec"
---@param to "host"|"exec"
---@return string?
function PathMap:_translate(path, from, to)
    local p = clean(path)
    local best, best_len
    for _, e in ipairs(self._entries) do
        local rest = strip(p, e[from])
        if rest and (not best_len or #e[from] > best_len) then
            best, best_len = join(e[to], rest), #e[from]
        end
    end
    return best
end

--- Host path for an absolute path pi reported, or nil when unmapped.
---@param exec_path string
---@return string?
function PathMap:to_host(exec_path)
    return self:_translate(exec_path, "exec", "host")
end

--- Path pi sees for an absolute host path, or nil when unmapped.
---@param host_path string
---@return string?
function PathMap:to_exec(host_path)
    return self:_translate(host_path, "host", "exec")
end

return PathMap
