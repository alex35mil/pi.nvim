--- Durable execution state under stdpath("state")/pi/:
--- workspaces that launched from a descriptor, and cleanup failures saved at exit.

local M = {}

---@return string
local function dir()
    return vim.fn.stdpath("state") .. "/pi"
end

---@param name string
---@return string
local function path(name)
    return dir() .. "/" .. name
end

---@param name string
---@return table?
local function read_json(name)
    local f = io.open(path(name), "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

---@param name string
---@param value table
---@return boolean ok
---@return string? err
local function write_json(name, value)
    vim.fn.mkdir(dir(), "p")
    local tmp = path(name) .. ".tmp"
    local f, open_err = io.open(tmp, "w")
    if not f then
        return false, open_err
    end
    f:write(vim.json.encode(value))
    f:close()
    local ok, rename_err = os.rename(tmp, path(name))
    if not ok then
        return false, rename_err
    end
    return true
end

local WORKSPACES = "descriptor-workspaces.json"
local FAILURES = "cleanup-failures.json"

--- Whether a workspace (real path) has launched from a descriptor.
---@param workspace string
---@return boolean
function M.used_descriptor(workspace)
    local data = read_json(WORKSPACES) or {}
    return data[workspace] == true
end

--- Record that a workspace (real path) launched from a descriptor.
---@param workspace string
---@return boolean ok
---@return string? err
function M.record_workspace(workspace)
    local data = read_json(WORKSPACES) or {}
    if data[workspace] == true then
        return true
    end
    data[workspace] = true
    return write_json(WORKSPACES, data)
end

--- Clear a workspace's record (the user confirmed local Pi for it).
---@param workspace string
---@return boolean ok
---@return string? err
function M.clear_workspace(workspace)
    local data = read_json(WORKSPACES) or {}
    if data[workspace] == nil then
        return true
    end
    data[workspace] = nil
    return write_json(WORKSPACES, data)
end

---@class pi.SavedCleanupFailure: pi.CleanupFailureReport
---@field time integer Unix time of the failure.
---@field callback_error? string Error raised by `process.stop.on_failure`.

--- Append cleanup failures saved during Neovim exit.
---@param failures pi.SavedCleanupFailure[]
---@return boolean ok
---@return string? err
function M.save_failures(failures)
    if #failures == 0 then
        return true
    end
    local data = read_json(FAILURES) or {}
    vim.list_extend(data, failures)
    return write_json(FAILURES, data)
end

--- Take and clear saved cleanup failures.
---@return pi.SavedCleanupFailure[]
function M.take_failures()
    local data = read_json(FAILURES)
    if not data or #data == 0 then
        return {}
    end
    os.remove(path(FAILURES))
    return data
end

return M
