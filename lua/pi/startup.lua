--- Startup block data for RPC mode using only data provided by pi.
---
--- Current sources:
--- - RPC get_commands results for prompt / skill / extension-backed commands
--- - Extension startup announcements (setWidget keys ending with `:startup`)
---
--- No local filesystem discovery is performed here.

---@class pi.SystemCommandItem
---@field name? string
---@field location? "user"|"project"|"path"
---@field path? string

---@class pi.SystemSection
---@field title string
---@field lines string[]

local M = {}

---@param path string
---@return string
local function display_path(path)
    return vim.fn.fnamemodify(path, ":~:.")
end

---@param name string
---@return string
local function strip_skill_prefix(name)
    local stripped = name:gsub("^skill:", "")
    return stripped
end

---@param item pi.SystemCommandItem
---@return string
local function location_prefix(item)
    return item.location and ("[" .. item.location .. "] ") or ""
end

---@param items pi.SystemCommandItem[]
local function sort_items(items)
    local location_rank = { user = 1, project = 2, path = 3 }
    table.sort(items, function(a, b)
        local al = location_rank[a.location or "path"] or 99
        local bl = location_rank[b.location or "path"] or 99
        if al ~= bl then
            return al < bl
        end
        local an = (a.name or ""):lower()
        local bn = (b.name or ""):lower()
        if an ~= bn then
            return an < bn
        end
        local ap = a.path and display_path(a.path):lower() or ""
        local bp = b.path and display_path(b.path):lower() or ""
        return ap < bp
    end)
end

---@class pi.AddCommandItemOpts
---@field name? fun(cmd_name: string): string?
---@field dedupe_by_path? boolean

---@param map table<string, pi.SystemCommandItem>
---@param list pi.SystemCommandItem[]
---@param cmd pi.SlashCommand
---@param opts? pi.AddCommandItemOpts
local function add_command_item(map, list, cmd, opts)
    local path = type(cmd.path) == "string" and cmd.path ~= "" and cmd.path or nil
    local name = type(cmd.name) == "string" and cmd.name ~= "" and cmd.name or nil
    if opts and opts.name and name then
        name = opts.name(name)
    end
    if not path and not name then
        return
    end

    local key
    if path and (not opts or opts.dedupe_by_path ~= false) then
        key = "path:" .. path
    else
        key = (cmd.location or "") .. ":" .. (name or path or "")
    end

    local item = map[key]
    if item then
        if item.path == nil then
            item.path = path
        end
        if item.location == nil then
            item.location = cmd.location
        end
        if item.name == nil then
            item.name = name
        end
        return
    end

    item = {
        name = name,
        location = cmd.location,
        path = path,
    }
    map[key] = item
    list[#list + 1] = item
end

---@param commands? pi.SlashCommand[]
---@return pi.SystemCommandItem[] skills, pi.SystemCommandItem[] prompts, pi.SystemCommandItem[] extensions
local function collect_command_items(commands)
    local skills = {} ---@type pi.SystemCommandItem[]
    local prompts = {} ---@type pi.SystemCommandItem[]
    local extensions = {} ---@type pi.SystemCommandItem[]
    local skill_map = {} ---@type table<string, pi.SystemCommandItem>
    local prompt_map = {} ---@type table<string, pi.SystemCommandItem>
    local extension_map = {} ---@type table<string, pi.SystemCommandItem>

    if type(commands) == "table" then
        for _, cmd in ipairs(commands) do
            if cmd.source == "skill" then
                add_command_item(skill_map, skills, cmd, { name = strip_skill_prefix })
            elseif cmd.source == "prompt" then
                add_command_item(prompt_map, prompts, cmd)
            elseif cmd.source == "extension" then
                add_command_item(extension_map, extensions, cmd)
            end
        end
    end

    sort_items(skills)
    sort_items(prompts)
    sort_items(extensions)

    return skills, prompts, extensions
end

---@param items pi.SystemCommandItem[]
---@return string[]
local function format_skill_lines(items)
    local lines = {} ---@type string[]
    for _, item in ipairs(items) do
        local text = "  " .. location_prefix(item)
        if item.name then
            text = text .. "skill:" .. item.name
        end
        if item.path then
            if item.name then
                text = text .. " - "
            end
            text = text .. display_path(item.path)
        end
        lines[#lines + 1] = text
    end
    return lines
end

---@param items pi.SystemCommandItem[]
---@return string[]
local function format_prompt_lines(items)
    local lines = {} ---@type string[]
    for _, item in ipairs(items) do
        local text = "  " .. location_prefix(item)
        if item.name then
            text = text .. "/" .. item.name
        end
        if item.path then
            if item.name then
                text = text .. " - "
            end
            text = text .. display_path(item.path)
        end
        lines[#lines + 1] = text
    end
    return lines
end

---@param items pi.SystemCommandItem[]
---@return string[]
local function format_extension_lines(items)
    local lines = {} ---@type string[]
    for _, item in ipairs(items) do
        local text = "  " .. location_prefix(item)
        if item.path then
            text = text .. display_path(item.path)
        elseif item.name then
            text = text .. "/" .. item.name
        end
        lines[#lines + 1] = text
    end
    return lines
end

---@param session pi.Session
---@return pi.SystemSection[]
local function announcement_sections(session)
    local announcements = session.startup_announcements or {}
    local keys = {} ---@type string[]
    for key, entry in pairs(announcements) do
        if
            type(key) == "string"
            and type(entry) == "table"
            and type(entry.lines) == "table"
            and #entry.lines > 0
        then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)

    local sections = {} ---@type pi.SystemSection[]
    for _, key in ipairs(keys) do
        local entry = announcements[key]
        local lines = {} ---@type string[]
        for _, line in ipairs(entry.lines) do
            lines[#lines + 1] = line == "" and "" or ("  " .. line)
        end
        -- Strip `:startup` suffix so the title shows just the extension name.
        local display_key = key:gsub(":startup$", "")
        sections[#sections + 1] = {
            title = "[Extension: " .. display_key .. "]",
            lines = lines,
        }
    end
    return sections
end

---@param session pi.Session
---@param commands? pi.SlashCommand[]
---@return pi.SystemSection[]
function M.build_startup_sections(session, commands)
    local skills, prompts, extensions = collect_command_items(commands)
    local sections = {} ---@type pi.SystemSection[]

    if #skills > 0 then
        sections[#sections + 1] = { title = "[Skills]", lines = format_skill_lines(skills) }
    end
    if #prompts > 0 then
        sections[#sections + 1] = { title = "[Prompts]", lines = format_prompt_lines(prompts) }
    end
    if #extensions > 0 then
        sections[#sections + 1] = { title = "[Extensions]", lines = format_extension_lines(extensions) }
    end

    vim.list_extend(sections, announcement_sections(session))
    return sections
end

return M
