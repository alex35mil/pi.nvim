--- pi CLI command construction.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")

---@type table<string, true>
local warned = {}

---@type table<string, integer>
local filtered_flags = {
    ["--print"] = 1,
    ["-p"] = 1,
    ["--export"] = 2,
    ["--list-models"] = 1,
    ["--help"] = 0,
    ["-h"] = 0,
    ["--version"] = 0,
    ["-v"] = 0,
}

---@param arg string
local function warn_filtered(arg)
    if warned[arg] then
        return
    end
    warned[arg] = true
    Notify.warn("Ignoring conflicting pi CLI arg: " .. arg)
end

---@param args string[]
---@param index integer
---@param max_count integer
---@return integer
local function skip_optional_values(args, index, max_count)
    local next_index = index
    for _ = 1, max_count do
        local value = args[next_index]
        if type(value) ~= "string" or value:sub(1, 1) == "-" then
            break
        end
        next_index = next_index + 1
    end
    return next_index
end

---@return string
function M.bin()
    local cli = Config.options.cli or {}
    return cli.bin or "pi"
end

---@param args any
---@return string[]
function M.filter_args(args)
    if type(args) ~= "table" then
        return {}
    end

    local result = {} ---@type string[]
    local i = 1
    while i <= #args do
        local arg = args[i]
        if type(arg) ~= "string" or arg == "" then
            i = i + 1
        elseif arg == "--mode" then
            warn_filtered(arg)
            i = i + 2
        elseif arg:match("^%-%-mode=") or arg:match("^%-%-list%-models=") or arg:match("^%-%-export=") then
            warn_filtered(arg)
            i = i + 1
        elseif filtered_flags[arg] then
            warn_filtered(arg)
            i = skip_optional_values(args, i + 1, filtered_flags[arg])
        else
            result[#result + 1] = arg
            i = i + 1
        end
    end

    return result
end

---@return string[]
function M.args()
    local cli = Config.options.cli or {}
    return M.filter_args(cli.args)
end

---@return string[]
function M.command()
    local cmd = { M.bin() }
    vim.list_extend(cmd, M.args())
    cmd[#cmd + 1] = "--mode"
    cmd[#cmd + 1] = "rpc"
    return cmd
end

return M
