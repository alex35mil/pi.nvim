--- Launch specs: how a tab's pi is started or reached, and how pi.nvim stops it.
---
--- The global `process` setting and a workspace descriptor's `process` object
--- are the same spec, parsed and validated here. A descriptor may also carry
--- `paths`, the mapping for pi in a separate filesystem; the global setting
--- has none, since a mapping belongs to one workspace.

local M = {}

---@class pi.DescriptorMount
---@field host string Absolute host path.
---@field path string Absolute path inside the environment.

--- How pi's paths map to the host, for pi in a separate filesystem.
---@class pi.DescriptorPaths
---@field workspace string Absolute path where the workspace appears to pi.
---@field mounts pi.DescriptorMount[] Other mounted folders.

--- How pi.nvim stops this launch or connector.
---@class pi.SpecStop
---@field grace_ms? integer Grace period; nil = the `setup()` option `process.stop.grace_ms`.

--- Automatic reconnect of an attached pi.
---@class pi.SpecReconnect
---@field enabled boolean
---@field give_up_after_ms integer|false false = retry until detached or stopped.

--- pi started and owned by pi.nvim.
---@class pi.SpawnedProcess
---@field kind "spawned"
---@field cmd string[] Complete argument list, run as given.
---@field env? table<string, string>
---@field stop pi.SpecStop

--- pi kept running by the user's tooling, reached through a connector that
--- pi.nvim starts and owns; closing the connector only disconnects.
---@class pi.AttachedProcess
---@field kind "attached"
---@field cmd string[] The connector's complete argument list, run as given.
---@field env? table<string, string> The connector's environment.
---@field stop pi.SpecStop
---@field terminate? string[] Command that ends the attached pi; may contain `${{SESSION_ID}}` / `${{SESSION_FILE}}`.
---@field reconnect pi.SpecReconnect

---@alias pi.LaunchProcess pi.SpawnedProcess|pi.AttachedProcess

--- A validated launch spec with `${{WORKSPACE}}` expanded and mount hosts absolute.
---@class pi.LaunchSpec
---@field process pi.LaunchProcess
---@field paths? pi.DescriptorPaths Absent: pi runs on the host's own filesystem.

--- Where a spec is read from, which decides a few rules.
---@alias pi.SpecSource
---| "descriptor" # a workspace's JSON descriptor
---| "setup" # the global `process` setting in `setup()`

---@class pi.SpecContext
---@field workspace string Host workspace, for `${{WORKSPACE}}` and relative mount hosts.
---@field source pi.SpecSource

--- Upper bound for a descriptor's `process.stop.grace_ms`, so a descriptor can't
--- stall Neovim's exit indefinitely.
M.MAX_STOP_GRACE_MS = 60000

--- Reconnect settings an attached spec gets when it sets none.
---@type pi.SpecReconnect
M.DEFAULT_RECONNECT = { enabled = true, give_up_after_ms = 60000 }

--- Validation failure naming the offending field.
---@class pi.SpecError
---@field field string
---@field message string

---@param field string
---@param message string
---@return pi.SpecError
local function invalid(field, message)
    return { field = field, message = message }
end

--- `vim.json.decode` marks empty JSON objects with `vim.empty_dict()`'s
--- metatable, which tells `{}` apart from `[]`.
local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

--- An object (string-keyed table). An empty Lua table from `setup()` counts,
--- since Lua can't tell `{}` from `[]`; an empty JSON array doesn't.
---@param v any
---@param ctx pi.SpecContext
---@return boolean
local function is_object(v, ctx)
    if type(v) ~= "table" then
        return false
    end
    if next(v) == nil then
        return ctx.source == "setup" or getmetatable(v) == EMPTY_DICT_MT
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
---@return pi.SpecError?
local function check_fields(field, obj, allowed)
    for key in pairs(obj) do
        if not allowed[key] then
            local name = field == "" and tostring(key) or (field .. "." .. tostring(key))
            return invalid(name, "unknown field")
        end
    end
    return nil
end

--- Who reads a value, which decides what other `$` forms mean.
---@alias pi.SpecValueReader
---| "command" # `cmd`, `env`, `terminate`: handed to the started command, which may expand `$VAR`/`${VAR}` itself
---| "pi.nvim" # `paths`: read by pi.nvim, where nothing would expand a `$`

--- Placeholders by exact (uppercase) name. `WORKSPACE` is expanded when the
--- spec is parsed; the session ones are kept and filled when `terminate` runs.
---@type table<string, "parse"|"terminate">
local PLACEHOLDERS = { WORKSPACE = "parse", SESSION_ID = "terminate", SESSION_FILE = "terminate" }

--- Expand `${{WORKSPACE}}` and validate the other placeholders. Unknown
--- `${{…}}` names (they're case-sensitive) and an unclosed `${{` are invalid;
--- session placeholders are valid only where `session` is true. `${{` is
--- never valid shell syntax, so it can't collide with what a command means by
--- `$VAR` or `${VAR}`; those pass through for a command. Where pi.nvim reads
--- the value itself, a `$` or a leading `~` is invalid, since nothing would
--- expand it.
---@param field string
---@param value any
---@param ctx pi.SpecContext
---@param reader pi.SpecValueReader
---@param session boolean whether session placeholders are allowed here
---@return string? expanded
---@return pi.SpecError? err
local function expand(field, value, ctx, reader, session)
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
        local when = PLACEHOLDERS[name]
        if when == nil then
            local hint = PLACEHOLDERS[name:upper()] and ("; did you mean `${{%s}}`?"):format(name:upper())
                or " (supported: `${{WORKSPACE}}`, and in `process.terminate` `${{SESSION_ID}}` and `${{SESSION_FILE}}`)"
            return nil, invalid(field, ("unknown placeholder `${{%s}}`%s"):format(name, hint))
        elseif when == "terminate" then
            if not session then
                return nil, invalid(field, ("can't use `${{%s}}`: it's only valid in `process.terminate`"):format(name))
            end
        elseif when ~= "parse" then
            error("unknown placeholder timing: " .. tostring(when))
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
        error("unknown spec value reader: " .. tostring(reader))
    end
    local out = value:gsub("%${{WORKSPACE}}", function()
        return ctx.workspace
    end)
    return out
end

---@param p string
---@return boolean
local function is_absolute(p)
    return vim.startswith(p, "/")
end

--- A non-empty argument list.
---@param field string
---@param raw any
---@param ctx pi.SpecContext
---@param session boolean
---@return string[]? args
---@return pi.SpecError? err
local function parse_args(field, raw, ctx, session)
    if not is_list(raw) or #raw == 0 then
        return nil, invalid(field, "must be a non-empty array of strings")
    end
    ---@type string[]
    local args = {}
    for i, arg in ipairs(raw) do
        local value, err = expand(("%s[%d]"):format(field, i), arg, ctx, "command", session)
        if not value then
            return nil, err
        end
        args[i] = value
    end
    return args
end

---@param raw any
---@param ctx pi.SpecContext
---@return table<string, string>? env
---@return pi.SpecError? err
local function parse_env(raw, ctx)
    if raw == nil then
        return nil
    end
    if not is_object(raw, ctx) then
        return nil, invalid("process.env", "must be an object of strings")
    end
    ---@type table<string, string>
    local env = {}
    for name, v in pairs(raw) do
        local value, err = expand("process.env." .. tostring(name), v, ctx, "command", false)
        if not value then
            return nil, err
        end
        env[name] = value
    end
    return env
end

--- Keys of `process.stop` that only the global setting has (Neovim-exit reporting).
---@type table<string, true>
local SETUP_STOP_KEYS = { on_failure = true, report_failures_on_start = true }

---@param raw any
---@param ctx pi.SpecContext
---@return pi.SpecStop? stop
---@return pi.SpecError? err
local function parse_stop(raw, ctx)
    ---@type pi.SpecStop
    local stop = {}
    if raw == nil then
        return stop
    end
    if not is_object(raw, ctx) then
        return nil, invalid("process.stop", "must be an object")
    end
    local allowed = { grace_ms = true }
    if ctx.source == "setup" then
        allowed = vim.tbl_extend("force", allowed, SETUP_STOP_KEYS)
    end
    local err = check_fields("process.stop", raw, allowed)
    if err then
        return nil, err
    end
    local grace = raw.grace_ms
    if grace ~= nil then
        local integer = type(grace) == "number" and grace == math.floor(grace) and grace >= 0
        if ctx.source == "descriptor" then
            if not integer or grace > M.MAX_STOP_GRACE_MS then
                return nil,
                    invalid("process.stop.grace_ms", ("must be an integer from 0 to %d"):format(M.MAX_STOP_GRACE_MS))
            end
        elseif ctx.source == "setup" then
            if not integer then
                return nil, invalid("process.stop.grace_ms", "must be a non-negative integer (milliseconds)")
            end
        else
            error("unknown spec source: " .. tostring(ctx.source))
        end
    end
    stop.grace_ms = grace
    return stop
end

---@param raw any
---@param ctx pi.SpecContext
---@return pi.SpecReconnect? reconnect
---@return pi.SpecError? err
local function parse_reconnect(raw, ctx)
    if raw == nil then
        return vim.deepcopy(M.DEFAULT_RECONNECT)
    end
    if not is_object(raw, ctx) then
        return nil, invalid("process.reconnect", "must be an object")
    end
    local err = check_fields("process.reconnect", raw, { enabled = true, give_up_after_ms = true })
    if err then
        return nil, err
    end
    local reconnect = vim.deepcopy(M.DEFAULT_RECONNECT)
    if raw.enabled ~= nil then
        if type(raw.enabled) ~= "boolean" then
            return nil, invalid("process.reconnect.enabled", "must be true or false")
        end
        reconnect.enabled = raw.enabled
    end
    local give_up = raw.give_up_after_ms
    if give_up ~= nil then
        local integer = type(give_up) == "number" and give_up == math.floor(give_up) and give_up >= 0
        if give_up ~= false and not integer then
            return nil,
                invalid(
                    "process.reconnect.give_up_after_ms",
                    "must be a non-negative integer (milliseconds), or false to retry until detached"
                )
        end
        reconnect.give_up_after_ms = give_up
    end
    return reconnect
end

--- Keys of `process` that only the global setting has.
---@type table<string, true>
local SETUP_PROCESS_KEYS = { descriptor = true }

---@param raw any
---@param ctx pi.SpecContext
---@return pi.LaunchProcess? process
---@return pi.SpecError? err
local function parse_process(raw, ctx)
    if raw == nil then
        return nil, invalid("process", "is required")
    end
    if not is_object(raw, ctx) then
        return nil, invalid("process", "must be an object")
    end
    local kind = raw.kind
    if kind == nil then
        if ctx.source == "descriptor" then
            return nil, invalid("process.kind", 'is required ("spawned" or "attached")')
        end
        kind = "spawned"
    end
    local allowed = { kind = true, cmd = true, env = true, stop = true }
    if kind == "attached" then
        allowed.terminate = true
        allowed.reconnect = true
    elseif kind ~= "spawned" then
        return nil,
            invalid("process.kind", ('unsupported kind %s ("spawned" or "attached")'):format(vim.inspect(kind)))
    end
    if ctx.source == "setup" then
        allowed = vim.tbl_extend("force", allowed, SETUP_PROCESS_KEYS)
    end
    for _, attached_only in ipairs({ "terminate", "reconnect" }) do
        if raw[attached_only] ~= nil and not allowed[attached_only] then
            return nil, invalid("process." .. attached_only, 'is only valid with `kind = "attached"`')
        end
    end
    local err = check_fields("process", raw, allowed)
    if err then
        return nil, err
    end
    if raw.cmd == nil then
        return nil, invalid("process.cmd", "is required")
    end
    local cmd, cerr = parse_args("process.cmd", raw.cmd, ctx, false)
    if not cmd then
        return nil, cerr
    end
    local env, eerr = parse_env(raw.env, ctx)
    if eerr then
        return nil, eerr
    end
    local stop, serr = parse_stop(raw.stop, ctx)
    if not stop then
        return nil, serr
    end
    if kind == "spawned" then
        ---@type pi.SpawnedProcess
        return { kind = "spawned", cmd = cmd, env = env, stop = stop }
    end
    ---@type string[]?
    local terminate = nil
    if raw.terminate ~= nil then
        local t, terr = parse_args("process.terminate", raw.terminate, ctx, true)
        if not t then
            return nil, terr
        end
        terminate = t
    end
    local reconnect, rerr = parse_reconnect(raw.reconnect, ctx)
    if not reconnect then
        return nil, rerr
    end
    ---@type pi.AttachedProcess
    return { kind = "attached", cmd = cmd, env = env, stop = stop, terminate = terminate, reconnect = reconnect }
end

---@param raw any
---@param ctx pi.SpecContext
---@return pi.DescriptorPaths? paths
---@return pi.SpecError? err
local function parse_paths(raw, ctx)
    if not is_object(raw, ctx) then
        return nil, invalid("paths", "must be an object")
    end
    local err = check_fields("paths", raw, { workspace = true, mounts = true })
    if err then
        return nil, err
    end
    if raw.workspace == nil then
        return nil, invalid("paths.workspace", "is required")
    end
    local ws, werr = expand("paths.workspace", raw.workspace, ctx, "pi.nvim", false)
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
            if not is_object(m, ctx) then
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
            local host, herr = expand(field .. ".host", m.host, ctx, "pi.nvim", false)
            if not host then
                return nil, herr
            end
            if host == "" then
                return nil, invalid(field .. ".host", "must not be empty")
            end
            local path, perr = expand(field .. ".path", m.path, ctx, "pi.nvim", false)
            if not path then
                return nil, perr
            end
            if not is_absolute(path) then
                return nil, invalid(field .. ".path", "must be an absolute path")
            end
            if not is_absolute(host) then
                host = vim.fs.joinpath(ctx.workspace, host)
            end
            mounts[i] = { host = vim.fs.normalize(host), path = vim.fs.normalize(path) }
        end
    end
    return { workspace = vim.fs.normalize(ws), mounts = mounts }
end

---@param e pi.SpecError
---@return string
local function describe(e)
    return ("`%s` %s"):format(e.field, e.message)
end

--- Parse and validate a decoded descriptor (`process` and optional `paths`).
---@param raw any decoded JSON
---@param workspace string host workspace
---@return pi.LaunchSpec? spec
---@return string? err
function M.parse_descriptor(raw, workspace)
    ---@type pi.SpecContext
    local ctx = { workspace = workspace, source = "descriptor" }
    if not is_object(raw, ctx) then
        return nil, "the descriptor must be a JSON object"
    end
    local err = check_fields("", raw, { process = true, paths = true })
    if err then
        return nil, describe(err)
    end
    local process, perr = parse_process(raw.process, ctx)
    if not process then
        return nil, describe(assert(perr))
    end
    ---@type pi.DescriptorPaths?
    local paths = nil
    if raw.paths ~= nil then
        local p, paerr = parse_paths(raw.paths, ctx)
        if not p then
            return nil, describe(assert(paerr))
        end
        paths = p
    end
    return { process = process, paths = paths }
end

--- Parse and validate the global `process` setting for a workspace.
---@param process table `Config.options.process`
---@param workspace string host workspace
---@return pi.LaunchSpec? spec
---@return string? err
function M.parse_setup(process, workspace)
    local parsed, err = parse_process(process, { workspace = workspace, source = "setup" })
    if not parsed then
        return nil, describe(assert(err))
    end
    return { process = parsed }
end

--- The global `process` setting as a spec for a workspace. `setup()` has
--- validated it, so a failure here is a bug.
---@param workspace string
---@return pi.LaunchSpec
function M.global(workspace)
    local spec, err = M.parse_setup(require("pi.config").options.process, workspace)
    if not spec then
        error("pi.nvim: the validated `process` setting failed to parse: " .. tostring(err))
    end
    return spec
end

--- Values for the session placeholders in `terminate`, from the latest `get_state`.
---@class pi.SessionValues
---@field session_id? string
---@field session_file? string

--- Fill `${{SESSION_ID}}` and `${{SESSION_FILE}}` in a validated `terminate`.
---@param args string[]
---@param values pi.SessionValues
---@return string[]? filled
---@return string? missing name of a placeholder whose value isn't known yet
function M.fill_session(args, values)
    local by_name = { SESSION_ID = values.session_id, SESSION_FILE = values.session_file }
    ---@type string[]
    local out = {}
    for i, arg in ipairs(args) do
        local missing = nil
        out[i] = arg:gsub("%${{([%u_]+)}}", function(name)
            local value = by_name[name]
            if value == nil or value == "" then
                missing = missing or name
                return ""
            end
            return value
        end)
        if missing then
            return nil, missing
        end
    end
    return out
end

--- Display form of a command, for prompts and messages.
---@param cmd string[]
---@return string
function M.display(cmd)
    local parts = {}
    for i, arg in ipairs(cmd) do
        parts[i] = arg:find("[%s'\"]") and vim.inspect(arg) or arg
    end
    return table.concat(parts, " ")
end

return M
