--- Workspace descriptors: discovery, trust, parsing, and validation.
---
--- A descriptor is a static JSON file at `process.descriptor.path` inside the
--- tab's workspace. It says how this workspace's pi process is reached and
--- stopped (`process`, overriding the `setup()` options of the same name) and, when pi runs in a
--- separate filesystem such as a container, how its paths map to the host
--- (`paths`). Because it names a host command, it is used only when trusted
--- (Neovim's trust database, or a configured trusted location on a workspace's
--- first use). The content parsed is always the exact content `vim.secure.read`
--- verified.

local M = {}

local Config = require("pi.config")
local State = require("pi.execution.state")
local Workspace = require("pi.workspace")

---@class pi.DescriptorMount
---@field host string Absolute host path.
---@field path string Absolute path inside the environment.

--- How pi's paths map to the host, for pi in a separate filesystem.
---@class pi.DescriptorPaths
---@field workspace string Absolute path where the workspace appears to pi.
---@field mounts pi.DescriptorMount[] Other mounted folders.

--- How pi.nvim stops this launch; overrides the `setup()` option `process.stop` for this workspace.
---@class pi.DescriptorStop
---@field grace_ms? integer Grace period for this launch; nil = the `setup()` option `process.stop.grace_ms`.

--- pi started and owned by pi.nvim.
---@class pi.DescriptorSpawned
---@field kind "spawned"
---@field cmd string[]
---@field env? table<string, string>
---@field stop pi.DescriptorStop

--- Upper bound for a descriptor's `process.stop.grace_ms`, so a descriptor can't
--- stall Neovim's exit indefinitely.
M.MAX_STOP_GRACE_MS = 60000

--- A validated descriptor with `${{WORKSPACE}}` expanded and mount hosts absolute.
---@class pi.DescriptorSpec
---@field process pi.DescriptorSpawned
---@field paths? pi.DescriptorPaths Absent: pi runs on the host's own filesystem.

--- Result of resolving a tab's execution.
---@alias pi.ExecutionResolution
---| { kind: "local" } # no descriptor and no record: local pi
---| { kind: "descriptor", path: string, spec: pi.DescriptorSpec } # trusted, valid descriptor
---| { kind: "missing_after_use" } # recorded workspace without a descriptor: ask before local pi
---| { kind: "cancelled" } # the user declined or viewed the descriptor
---| { kind: "error", message: string } # denied, invalid, or unreadable descriptor

--- Descriptor path for a workspace.
---@param workspace string
---@return string
function M.path(workspace)
    return vim.fs.joinpath(workspace, Config.options.process.descriptor.path)
end

---@return string[]
local function trusted_roots()
    local roots = {}
    for _, dir in ipairs(Config.options.process.descriptor.trusted_paths or {}) do
        if type(dir) == "string" and dir ~= "" then
            roots[#roots + 1] = Workspace.realpath(vim.fs.normalize(dir))
        end
    end
    return roots
end

---@param real string
---@return boolean
local function under_trusted_location(real)
    for _, root in ipairs(trusted_roots()) do
        local prefix = root:gsub("/+$", "") .. "/"
        if vim.startswith(real, prefix) then
            return true
        end
    end
    return false
end

--- Read-only hint from Neovim's trust database: "allowed", "denied", or nil.
--- Only decides whether to prompt; the content used is always verified by
--- `vim.secure.read`.
---@param real string
---@return "allowed"|"denied"|nil
local function trust_hint(real)
    local f = io.open(vim.fn.stdpath("state") .. "/trust", "r")
    if not f then
        return nil
    end
    local content = f:read("*a") or ""
    f:close()
    local entry
    for line in vim.gsplit(content, "\n", { plain = true }) do
        local hash, file = line:match("^(%S+) (.+)$")
        if file == real then
            entry = hash
        end
    end
    if entry == "!" then
        return "denied"
    end
    if not entry then
        return nil
    end
    local file = io.open(real, "rb")
    if not file then
        return nil
    end
    local bytes = file:read("*a")
    file:close()
    if bytes and vim.fn.sha256(bytes) == entry then
        return "allowed"
    end
    return nil
end

--- `vim.secure.read` for a file: the verified content, or nil when not trusted.
--- (It returns `true` only for directories.)
---@param real string
---@return string?
local function secure_read(real)
    local content = vim.secure.read(real)
    if type(content) == "string" then
        return content
    end
    return nil
end

--- `vim.secure.trust`, ensuring its state directory exists first (Neovim
--- asserts on writing the trust file when the directory is missing).
---@param opts vim.trust.opts
---@return boolean ok
---@return string? err
local function secure_trust(opts)
    vim.fn.mkdir(vim.fn.stdpath("state"), "p")
    local ok, res, err = pcall(vim.secure.trust, opts)
    if not ok then
        return false, tostring(res)
    end
    return res, err
end

---@param choice "allow"|"view"|"deny"|nil
---@param real string
---@param done fun(content: string?, err?: string, cancelled?: boolean)
local function apply_choice(choice, real, done)
    if choice == "allow" then
        local ok, err = secure_trust({ action = "allow", path = real })
        if not ok then
            done(nil, "could not trust " .. real .. ": " .. tostring(err))
            return
        end
        local content = secure_read(real)
        if not content then
            done(nil, nil, true)
            return
        end
        done(content)
    elseif choice == "deny" then
        secure_trust({ action = "deny", path = real })
        done(nil, nil, true)
    elseif choice == "view" then
        vim.cmd("sview " .. vim.fn.fnameescape(real))
        done(nil, nil, true)
    else
        done(nil, nil, true)
    end
end

--- Default trust prompt: allow / view / deny.
---@param path string
---@param cb fun(choice: "allow"|"view"|"deny"|nil)
function M.default_prompt(path, cb)
    require("pi.ui.dialog").select({
        title = "Untrusted pi descriptor",
        message = "This workspace's pi descriptor runs a command on your machine:\n"
            .. path
            .. "\n\nAllow it to launch pi?",
        options = { "Allow", "View", "Deny" },
        shortcuts = { a = "Allow", v = "View", d = "Deny" },
    }, function(choice)
        cb(choice and choice:lower() or nil)
    end)
end

--- Trust prompt, replaceable for tests.
---@type fun(path: string, cb: fun(choice: "allow"|"view"|"deny"|nil))
M.prompt = M.default_prompt

--- Resolve trusted content for a descriptor, prompting when needed.
---@param real string real path of the descriptor
---@param workspace_real string real path of the workspace
---@param done fun(content: string?, err?: string, cancelled?: boolean)
local function trusted_content(real, workspace_real, done)
    local hint = trust_hint(real)
    if hint == "denied" then
        done(nil, "descriptor is denied in Neovim's trust database (:trust to change): " .. real)
        return
    end
    if hint == "allowed" then
        local content = secure_read(real)
        if content then
            done(content)
        else
            done(nil, nil, true)
        end
        return
    end
    -- First use under a trusted location, only for a workspace that never used a descriptor.
    if under_trusted_location(real) and not State.used_descriptor(workspace_real) then
        apply_choice("allow", real, done)
        return
    end
    M.prompt(real, function(choice)
        apply_choice(choice, real, done)
    end)
end

--- Validation failure naming the offending field.
---@class pi.DescriptorError
---@field field string
---@field message string

---@param field string
---@param message string
---@return pi.DescriptorError
local function invalid(field, message)
    return { field = field, message = message }
end

--- `vim.json.decode` marks empty JSON objects with `vim.empty_dict()`'s
--- metatable, which tells `{}` apart from `[]`.
local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

---@param v any
---@return boolean
local function is_object(v)
    if type(v) ~= "table" then
        return false
    end
    if next(v) == nil then
        return getmetatable(v) == EMPTY_DICT_MT
    end
    return not vim.islist(v)
end

---@param v any
---@return boolean
local function is_list(v)
    return type(v) == "table" and getmetatable(v) ~= EMPTY_DICT_MT and vim.islist(v)
end

---@param field string
---@param obj table
---@param allowed table<string, true>
---@return pi.DescriptorError?
local function check_fields(field, obj, allowed)
    for key in pairs(obj) do
        if not allowed[key] then
            local name = field == "" and tostring(key) or (field .. "." .. tostring(key))
            return invalid(name, "unknown field")
        end
    end
    return nil
end

--- Who reads a descriptor value, which decides what other `$` forms mean.
---@alias pi.DescriptorValueReader
---| "command" # `cmd` and `env`: handed to the started command, which may expand `$VAR`/`${VAR}` itself
---| "pi.nvim" # `paths`: read by pi.nvim, where nothing would expand a `$`

--- Placeholders a descriptor value may use, by exact (uppercase) name.
---@type table<string, true>
local PLACEHOLDERS = { WORKSPACE = true }

--- Expand `${{WORKSPACE}}`. Any other `${{…}}` (names are case-sensitive),
--- or an unclosed `${{`, is invalid. `${{` is never valid shell syntax, so it
--- can't collide with what a command means by `$VAR` or `${VAR}`; those pass
--- through for a command. Where pi.nvim reads the value itself, a `$` or a
--- leading `~` is invalid, since nothing would expand it.
---@param field string
---@param value any
---@param workspace string
---@param reader pi.DescriptorValueReader
---@return string? expanded
---@return pi.DescriptorError? err
local function expand(field, value, workspace, reader)
    if type(value) ~= "string" then
        return nil, invalid(field, "must be a string")
    end
    -- Checked on the value without its placeholders, so a workspace path
    -- that itself contains `$` or `${{` isn't mistaken for a problem.
    local rest = value:gsub("%${{.-}}", "")
    if rest:find("${{", 1, true) then
        return nil, invalid(field, "has an unclosed `${{` (write `${{WORKSPACE}}`)")
    end
    for name in value:gmatch("%${{(.-)}}") do
        if not PLACEHOLDERS[name] then
            local hint = PLACEHOLDERS[name:upper()] and ("; did you mean `${{%s}}`?"):format(name:upper())
                or " (only `${{WORKSPACE}}` is supported)"
            return nil, invalid(field, ("unknown placeholder `${{%s}}`%s"):format(name, hint))
        end
    end
    if reader == "pi.nvim" then
        if rest:find("$", 1, true) then
            return nil,
                invalid(
                    field,
                    "can't use `$` variables: pi.nvim reads this path itself and nothing expands them (only `${{WORKSPACE}}` is supported)"
                )
        end
        if vim.startswith(value, "~") then
            return nil,
                invalid(
                    field,
                    "can't start with `~`: pi.nvim doesn't expand it; use an absolute path or `${{WORKSPACE}}`"
                )
        end
    elseif reader ~= "command" then
        error("unknown descriptor value reader: " .. tostring(reader))
    end
    local out = value:gsub("%${{WORKSPACE}}", function()
        return workspace
    end)
    return out
end

---@param p string
---@return boolean
local function is_absolute(p)
    return vim.startswith(p, "/")
end

---@param raw any
---@param workspace string
---@return pi.DescriptorSpawned? spawned
---@return pi.DescriptorError? err
local function parse_process(raw, workspace)
    if raw == nil then
        return nil, invalid("process", "is required")
    end
    if not is_object(raw) then
        return nil, invalid("process", "must be an object")
    end
    if raw.kind == nil then
        return nil, invalid("process.kind", 'is required ("spawned")')
    end
    if raw.kind ~= "spawned" then
        return nil,
            invalid("process.kind", ('unsupported kind %s (only "spawned" is supported)'):format(vim.inspect(raw.kind)))
    end
    local err = check_fields("process", raw, { kind = true, cmd = true, env = true, stop = true })
    if err then
        return nil, err
    end
    if not is_list(raw.cmd) or #raw.cmd == 0 then
        return nil, invalid("process.cmd", "must be a non-empty array of strings")
    end
    ---@type string[]
    local cmd = {}
    for i, arg in ipairs(raw.cmd) do
        local value, aerr = expand(("process.cmd[%d]"):format(i), arg, workspace, "command")
        if not value then
            return nil, aerr
        end
        cmd[i] = value
    end
    ---@type table<string, string>?
    local env = nil
    if raw.env ~= nil then
        if not is_object(raw.env) then
            return nil, invalid("process.env", "must be an object of strings")
        end
        env = {}
        for name, v in pairs(raw.env) do
            local value, eerr = expand("process.env." .. tostring(name), v, workspace, "command")
            if not value then
                return nil, eerr
            end
            env[name] = value
        end
    end
    ---@type pi.DescriptorStop
    local stop = {}
    if raw.stop ~= nil then
        if not is_object(raw.stop) then
            return nil, invalid("process.stop", "must be an object")
        end
        local serr = check_fields("process.stop", raw.stop, { grace_ms = true })
        if serr then
            return nil, serr
        end
        local grace = raw.stop.grace_ms
        if
            grace ~= nil
            and (type(grace) ~= "number" or grace ~= math.floor(grace) or grace < 0 or grace > M.MAX_STOP_GRACE_MS)
        then
            return nil,
                invalid("process.stop.grace_ms", ("must be an integer from 0 to %d"):format(M.MAX_STOP_GRACE_MS))
        end
        stop.grace_ms = grace
    end
    return { kind = "spawned", cmd = cmd, env = env, stop = stop }
end

---@param raw any
---@param workspace string
---@return pi.DescriptorPaths? paths
---@return pi.DescriptorError? err
local function parse_paths(raw, workspace)
    if not is_object(raw) then
        return nil, invalid("paths", "must be an object")
    end
    local err = check_fields("paths", raw, { workspace = true, mounts = true })
    if err then
        return nil, err
    end
    if raw.workspace == nil then
        return nil, invalid("paths.workspace", "is required")
    end
    local ws, werr = expand("paths.workspace", raw.workspace, workspace, "pi.nvim")
    if not ws then
        return nil, werr
    end
    if not is_absolute(ws) then
        return nil, invalid("paths.workspace", "must be an absolute path")
    end
    ---@type pi.DescriptorMount[]
    local mounts = {}
    if raw.mounts ~= nil then
        if not is_list(raw.mounts) then
            return nil, invalid("paths.mounts", "must be an array")
        end
        for i, m in ipairs(raw.mounts) do
            local field = ("paths.mounts[%d]"):format(i)
            if not is_object(m) then
                return nil, invalid(field, 'must be an object with "host" and "path"')
            end
            local merr = check_fields(field, m, { host = true, path = true })
            if merr then
                return nil, merr
            end
            if m.host == nil then
                return nil, invalid(field .. ".host", "is required")
            end
            if m.path == nil then
                return nil, invalid(field .. ".path", "is required")
            end
            local host, herr = expand(field .. ".host", m.host, workspace, "pi.nvim")
            if not host then
                return nil, herr
            end
            if host == "" then
                return nil, invalid(field .. ".host", "must not be empty")
            end
            local path, perr = expand(field .. ".path", m.path, workspace, "pi.nvim")
            if not path then
                return nil, perr
            end
            if not is_absolute(path) then
                return nil, invalid(field .. ".path", "must be an absolute path")
            end
            if not is_absolute(host) then
                host = vim.fs.joinpath(workspace, host)
            end
            mounts[i] = { host = vim.fs.normalize(host), path = vim.fs.normalize(path) }
        end
    end
    return { workspace = vim.fs.normalize(ws), mounts = mounts }
end

--- Parse and validate descriptor content for a workspace.
---@param content string
---@param workspace string host workspace, for `${{WORKSPACE}}`
---@return pi.DescriptorSpec? spec
---@return string? err
function M.parse(content, workspace)
    local ok, raw = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
    if not ok then
        return nil, "malformed JSON: " .. tostring(raw)
    end
    if not is_object(raw) then
        return nil, "the descriptor must be a JSON object"
    end
    local function fail(e)
        return nil, ("`%s` %s"):format(e.field, e.message)
    end
    local err = check_fields("", raw, { process = true, paths = true })
    if err then
        return fail(err)
    end
    local spawned, perr = parse_process(raw.process, workspace)
    if not spawned then
        return fail(perr)
    end
    ---@type pi.DescriptorPaths?
    local paths = nil
    if raw.paths ~= nil then
        local p, paerr = parse_paths(raw.paths, workspace)
        if not p then
            return fail(paerr)
        end
        paths = p
    end
    return { process = spawned, paths = paths }
end

--- Resolve how to run pi for a tab's workspace.
---@param workspace string
---@param done fun(result: pi.ExecutionResolution)
function M.resolve(workspace, done)
    local file = M.path(workspace)
    local workspace_real = Workspace.realpath(workspace)
    local stat = vim.uv.fs_lstat(file)
    if not stat then
        if State.used_descriptor(workspace_real) then
            done({ kind = "missing_after_use" })
        else
            done({ kind = "local" })
        end
        return
    end
    local real = vim.uv.fs_realpath(file)
    if not real then
        done({ kind = "error", message = "descriptor is not readable: " .. file })
        return
    end

    trusted_content(real, workspace_real, function(content, err, cancelled)
        if err then
            done({ kind = "error", message = err })
            return
        end
        if cancelled or not content then
            done({ kind = "cancelled" })
            return
        end
        local spec, perr = M.parse(content, workspace)
        if not spec then
            done({ kind = "error", message = ("invalid descriptor %s: %s"):format(real, perr) })
            return
        end
        local rec_ok, rec_err = State.record_workspace(workspace_real)
        if not rec_ok then
            done({ kind = "error", message = "could not record descriptor use: " .. tostring(rec_err) })
            return
        end
        done({ kind = "descriptor", path = real, spec = spec })
    end)
end

return M
