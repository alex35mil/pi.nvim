--- A connection's execution context: what was launched, how its paths relate
--- to the host, and whether pi's working directory has been verified.
---
--- Two kinds:
--- - `local`: pi.nvim starts pi on the host in the workspace.
--- - `descriptor`: pi runs where a workspace descriptor put it.
---
--- And two filesystems:
--- - `host`: pi sees the host's own filesystem (local pi, or a descriptor
---   without `paths`, such as an OS-level sandbox). Paths are used as given.
--- - `mapped`: pi runs in a separate filesystem (a descriptor with `paths`).
---   Paths are translated through the mapping; unmapped paths are refused.

local Cli = require("pi.cli")
local Notify = require("pi.notify")
local PathMap = require("pi.execution.paths")
local Workspace = require("pi.workspace")

---@alias pi.ExecutionKind "local"|"descriptor"

--- The filesystem pi sees.
---@alias pi.ExecutionFilesystem
---| { kind: "host" } # the host's own filesystem
---| { kind: "mapped", map: pi.PathMap } # a separate filesystem mapped to the host

--- Working-directory verification for relative tool paths.
---@alias pi.CwdVerification
---| "verified" # pi's recorded working directory matches the expected path
---| "unverified" # not checked successfully yet
---| "trusted" # pi has no persistent session; the declared path is trusted

--- Why a path from pi's tools can't be resolved on the host.
---@alias pi.PathRefusal
---| { kind: "outside_mapping", path: string } # resolves outside every mapped folder
---| { kind: "cwd_pending", reason: string } # pi's working directory isn't known yet
---| { kind: "cwd_mismatch", cwd: string } # pi runs somewhere other than the workspace
---| { kind: "session_unmapped", file: string } # pi's session file isn't reachable, so the check can't run

---@class pi.Execution
---@field kind pi.ExecutionKind
---@field workspace string Host workspace.
---@field descriptor? string Real path of the descriptor (descriptor kind).
---@field _launch pi.Launch
---@field _fs pi.ExecutionFilesystem
---@field _cwd pi.CwdVerification
---@field _session_file? string Current session file as pi reports it.
---@field _reported table<string, true> Messages already shown for this connection.
local Execution = {}
Execution.__index = Execution

--- Local pi on the host.
---@param workspace string
---@return pi.Execution
function Execution.new_local(workspace)
    local self = setmetatable({}, Execution)
    self.kind = "local"
    self.workspace = workspace
    self._launch = { cmd = Cli.command() }
    self._fs = { kind = "host" }
    -- pi.nvim starts local pi itself with the workspace as its working directory.
    self._cwd = "verified"
    self._reported = {}
    return self
end

--- pi launched from a trusted workspace descriptor.
---@param workspace string
---@param spec pi.DescriptorSpec
---@param descriptor string real path of the descriptor
---@return pi.Execution
function Execution.new_descriptor(workspace, spec, descriptor)
    local self = setmetatable({}, Execution)
    self.kind = "descriptor"
    self.workspace = workspace
    self.descriptor = descriptor
    self._launch = {
        cmd = vim.deepcopy(spec.process.cmd),
        env = spec.process.env and vim.deepcopy(spec.process.env) or nil,
        descriptor = descriptor,
        stop_grace_ms = spec.process.stop.grace_ms,
    }
    if spec.paths then
        self._fs = { kind = "mapped", map = PathMap.new(workspace, spec.paths) }
    else
        self._fs = { kind = "host" }
    end
    self._cwd = "unverified"
    self._reported = {}
    return self
end

--- What to start for this connection.
---@return pi.Launch
function Execution:launch()
    return vim.deepcopy(self._launch)
end

--- Short label for messages: the descriptor path, or "local pi".
---@return string
function Execution:label()
    if self.kind == "local" then
        return "local pi"
    elseif self.kind == "descriptor" then
        return "descriptor " .. assert(self.descriptor)
    end
    error("unknown execution kind: " .. tostring(self.kind))
end

--- Show a message once per connection.
---@param key string
---@param message string
function Execution:_report_once(key, message)
    if self._reported[key] then
        return
    end
    self._reported[key] = true
    Notify.warn(message)
end

--- Host path for an absolute path pi reported, or nil when it isn't mapped.
---@param exec_path string
---@return string?
function Execution:to_host(exec_path)
    local fs = self._fs
    if fs.kind == "host" then
        return vim.fs.normalize(exec_path)
    elseif fs.kind == "mapped" then
        return fs.map:to_host(exec_path)
    end
    error("unknown filesystem kind: " .. tostring(fs.kind))
end

--- Path pi sees for an absolute host path, or nil when it isn't mapped.
---@param host_path string
---@return string?
function Execution:to_exec(host_path)
    local fs = self._fs
    if fs.kind == "host" then
        return vim.fs.normalize(host_path)
    elseif fs.kind == "mapped" then
        return fs.map:to_exec(host_path)
    end
    error("unknown filesystem kind: " .. tostring(fs.kind))
end

--- The workspace path as pi sees it.
---@return string
function Execution:workspace_exec()
    local fs = self._fs
    if fs.kind == "host" then
        return self.workspace
    elseif fs.kind == "mapped" then
        return fs.map.workspace_exec
    end
    error("unknown filesystem kind: " .. tostring(fs.kind))
end

--- Record pi's current session file (from `get_state`); nil = no persistent session.
---@param session_file? string
function Execution:set_session_file(session_file)
    self._session_file = session_file
    if session_file == nil and self._cwd ~= "verified" then
        -- No session file at all: nothing to check, the declared path is trusted.
        self._cwd = "trusted"
    elseif session_file ~= nil and self._cwd == "trusted" then
        self._cwd = "unverified"
    end
end

--- Read the `cwd` recorded in a session file header on the host.
---@param host_file string
---@return string? cwd
---@return boolean exists
local function header_cwd(host_file)
    local f = io.open(host_file, "r")
    if not f then
        return nil, false
    end
    local line = f:read("*l")
    f:close()
    if not line or line == "" then
        return nil, true
    end
    local ok, header = pcall(vim.json.decode, line)
    if ok and type(header) == "table" and type(header.cwd) == "string" then
        return header.cwd, true
    end
    return nil, true
end

--- Whether a cwd recorded by pi is this connection's workspace.
---@param cwd string
---@return boolean
function Execution:is_workspace_cwd(cwd)
    local host = self:to_host(cwd)
    if not host then
        return false
    end
    return Workspace.realpath(host) == Workspace.realpath(self.workspace)
end

--- Check that pi runs in the expected working directory.
---@return pi.PathRefusal? refusal nil when verified
function Execution:_verify_cwd()
    if self._cwd == "verified" or self._cwd == "trusted" then
        return nil
    end
    local file = self._session_file
    if not file then
        return { kind = "cwd_pending", reason = "pi hasn't reported its session file yet" }
    end
    local host_file = self:to_host(file)
    if not host_file then
        return { kind = "session_unmapped", file = file }
    end
    local cwd, exists = header_cwd(host_file)
    if not exists then
        return { kind = "cwd_pending", reason = "pi hasn't written its session file yet" }
    end
    if not cwd then
        return { kind = "cwd_pending", reason = "pi's session file has no working directory" }
    end
    if self:is_workspace_cwd(cwd) then
        self._cwd = "verified"
        return nil
    end
    return { kind = "cwd_mismatch", cwd = cwd }
end

--- Host path for a path relative to pi's working directory, or nil when it
--- leaves every mapped folder. On a separate filesystem the path is resolved
--- in pi's coordinates first, so `../x` from `/workspace` is `/x` there, not
--- the host folder next to the workspace.
---@param path string relative path
---@return string?
function Execution:relative_to_host(path)
    local fs = self._fs
    if fs.kind == "host" then
        return vim.fs.normalize(vim.fs.joinpath(self.workspace, path))
    elseif fs.kind == "mapped" then
        return fs.map:to_host(vim.fs.normalize(vim.fs.joinpath(fs.map.workspace_exec, path)))
    end
    error("unknown filesystem kind: " .. tostring(fs.kind))
end

--- Host path for a file path from one of pi's tools, or nil with the refusal.
--- Absolute paths go through the mapping; relative paths resolve against pi's
--- working directory once it's verified.
---@param path string
---@return string? host_path
---@return pi.PathRefusal? refusal
function Execution:tool_path(path)
    local expanded = vim.fs.normalize(path)
    if vim.startswith(expanded, "/") then
        local host = self:to_host(expanded)
        if not host then
            return nil, { kind = "outside_mapping", path = expanded }
        end
        return host
    end
    local refusal = self:_verify_cwd()
    if refusal then
        return nil, refusal
    end
    local host = self:relative_to_host(expanded)
    if not host then
        return nil, { kind = "outside_mapping", path = expanded }
    end
    return host
end

--- Report a tool path that couldn't be resolved. An unreachable session file
--- blocks every relative path, so it's reported once per connection; other
--- refusals once per path.
---@param path string
---@param refusal pi.PathRefusal
function Execution:report_unresolved(path, refusal)
    local kind = refusal.kind
    if kind == "session_unmapped" then
        self:_report_once(
            "session-unmapped",
            ("pi: not opening relative paths from pi: its session file %s isn't mapped to the host, so its working directory can't be checked (%s)"):format(
                refusal.file,
                self:label()
            )
        )
    elseif kind == "outside_mapping" then
        self:_report_once(
            "outside:" .. path,
            ("pi: not opening %s: it's outside the mapped workspace (%s)"):format(path, self:label())
        )
    elseif kind == "cwd_pending" then
        self:_report_once("pending:" .. path, ("pi: not opening %s: %s"):format(path, refusal.reason))
    elseif kind == "cwd_mismatch" then
        self:_report_once(
            "mismatch:" .. path,
            ("pi: not opening %s: pi runs in %s, but the workspace is at %s (%s)"):format(
                path,
                refusal.cwd,
                self:workspace_exec(),
                self:label()
            )
        )
    else
        error("unknown path refusal: " .. tostring(kind))
    end
end

return Execution
