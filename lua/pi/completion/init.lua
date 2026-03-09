--- Shared matching logic for @-mention completion sources.

local Files = require("pi.files")

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
function M.complete(prefix, make_item)
    local project_files = Files.list()
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

return M
