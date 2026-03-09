--- Shared matching logic for @-mention and /command completion sources.

local FilesCache = require("pi.cache.files")
local CommandsCache = require("pi.cache.commands")

local M = {}

--- Check if all characters of query appear in order in target (case-insensitive).
function M.fuzzy_match(query, target)
    local qi = 1
    local ql = #query
    query = query:lower()
    target = target:lower()
    for ti = 1, #target do
        if target:byte(ti) == query:byte(qi) then
            qi = qi + 1
            if qi > ql then return true end
        end
    end
    return false
end

--- Two-pass file matching: prefix matches (with directory collapsing) then fuzzy matches (full paths).
--- Calls make_item(path_or_dir, kind, is_fuzzy) for each result.
--- kind is "file" or "dir". Results are returned in priority order.
---@param prefix string typed text after @
---@param make_item fun(path: string, kind: "file"|"dir", is_fuzzy: boolean): table
---@return table[]
function M.complete_files(prefix, make_item)
    local project_files = FilesCache.list()
    local items = {}
    local seen_dirs = {}
    local prefix_matched = {}

    -- Pass 1: prefix matches with directory collapsing
    for _, path in ipairs(project_files) do
        if prefix == "" or path:sub(1, #prefix) == prefix then
            prefix_matched[path] = true
            local rest = path:sub(#prefix + 1)
            local slash = rest:find("/")
            if slash then
                local dir = prefix .. rest:sub(1, slash)
                if not seen_dirs[dir] then
                    seen_dirs[dir] = true
                    items[#items + 1] = make_item(dir, "dir", false)
                end
            else
                items[#items + 1] = make_item(path, "file", false)
            end
        end
    end

    -- Pass 2: fuzzy matches on full path
    if prefix ~= "" then
        for _, path in ipairs(project_files) do
            if not prefix_matched[path] and M.fuzzy_match(prefix, path) then
                items[#items + 1] = make_item(path, "file", true)
            end
        end
    end

    return items
end

--- Two-pass command matching: prefix matches then fuzzy matches.
--- Skills are also matched by their short name (after "skill:").
--- Calls make_item(cmd, is_fuzzy) for each result.
---@param prefix string typed text after /
---@param make_item fun(cmd: pi.SlashCommand, is_fuzzy: boolean): table
---@return table[]
function M.complete_commands(prefix, make_item)
    local commands = CommandsCache.list()
    if prefix == "" then
        local items = {}
        for _, cmd in ipairs(commands) do
            items[#items + 1] = make_item(cmd, false)
        end
        return items
    end

    local lprefix = prefix:lower()
    local items = {}
    local seen = {}

    --- Check if lprefix is a prefix of name.
    ---@param name string already lowercased
    local function is_prefix(name)
        return name:sub(1, #lprefix) == lprefix
    end

    --- Get the short name for skills (after "skill:"), or nil.
    ---@param cmd pi.SlashCommand
    ---@return string? lowercased short name
    local function skill_short(cmd)
        if cmd.source == "skill" then
            return cmd.name:lower():match("^skill:(.+)$")
        end
    end

    -- Pass 1: prefix matches on full name or skill short name
    for _, cmd in ipairs(commands) do
        local lname = cmd.name:lower()
        local short = skill_short(cmd)
        if is_prefix(lname) or (short and is_prefix(short)) then
            seen[cmd.name] = true
            items[#items + 1] = make_item(cmd, false)
        end
    end

    -- Pass 2: fuzzy matches on full name or skill short name
    for _, cmd in ipairs(commands) do
        if not seen[cmd.name] then
            local lname = cmd.name:lower()
            local short = skill_short(cmd)
            if M.fuzzy_match(lprefix, lname) or (short and M.fuzzy_match(lprefix, short)) then
                items[#items + 1] = make_item(cmd, true)
            end
        end
    end

    return items
end

return M
