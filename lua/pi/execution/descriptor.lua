--- Workspace descriptors: discovery, trust, parsing, and validation.
---
--- A descriptor is a static JSON file at `process.descriptor.path` inside the
--- tab's workspace. It says how this workspace's pi is started or reached and
--- stopped (`process`, a launch spec that replaces the global `process` setting
--- for this workspace; see `pi.execution.spec`) and, when pi runs in a
--- separate filesystem such as a container, how its paths map to the host
--- (`paths`). Because it names a host command, it is used only when trusted
--- (Neovim's trust database, or a configured trusted location on a workspace's
--- first use). The content parsed is always the exact content `vim.secure.read`
--- verified.

local M = {}

local Config = require("pi.config")
local Spec = require("pi.execution.spec")
local State = require("pi.execution.state")
local Workspace = require("pi.workspace")

--- Result of resolving a tab's execution.
---@alias pi.ExecutionResolution
---| { kind: "global" } # no descriptor and no record: the global `process` setting
---| { kind: "descriptor", path: string, spec: pi.LaunchSpec } # trusted, valid descriptor
---| { kind: "missing_after_use" } # recorded workspace without a descriptor: ask before the global setting
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
--- Parse and validate descriptor content for a workspace.
---@param content string
---@param workspace string host workspace, for `${{WORKSPACE}}`
---@return pi.LaunchSpec? spec
---@return string? err
function M.parse(content, workspace)
    local ok, raw = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
    if not ok then
        return nil, "malformed JSON: " .. tostring(raw)
    end
    return Spec.parse_descriptor(raw, workspace)
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
            done({ kind = "global" })
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
