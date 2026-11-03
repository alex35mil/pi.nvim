--- Session entry selection for chat replay.
---
--- Mirrors pi's `buildSessionPath` + `buildContextEntries` (session-manager.js):
--- the TUI renders a resumed or compacted session from these entries, so
--- custom entries appear in their persisted position.

local M = {}

--- A persisted session entry as returned by the `get_entries` RPC command.
--- JSON `null` fields arrive as `vim.NIL`.
---@class pi.SessionEntry
---@field type string
---@field id string
---@field parentId string|userdata|nil
---@field timestamp string
---@field message? table `message` entries
---@field customType? string `custom` entries
---@field data? any `custom` entries
---@field summary? string `compaction` entries
---@field tokensBefore? number `compaction` entries
---@field firstKeptEntryId? string `compaction` entries

--- An extension entry appended with `pi.appendEntry(customType, data)`.
---@class pi.CustomEntry
---@field type "custom"
---@field id string
---@field customType string
---@field data any
---@field timestamp string

--- Walk from the leaf to the root.
---@param entries pi.SessionEntry[]
---@param leaf_id string|userdata|nil `vim.NIL` (JSON null) = no leaf; nil = absent
---@return pi.SessionEntry[]
local function session_path(entries, leaf_id)
    if leaf_id == vim.NIL then
        return {}
    end
    local by_id = {} ---@type table<string, pi.SessionEntry>
    for _, entry in ipairs(entries) do
        by_id[entry.id] = entry
    end
    local leaf = type(leaf_id) == "string" and by_id[leaf_id] or nil
    leaf = leaf or entries[#entries]
    local reversed = {} ---@type pi.SessionEntry[]
    local seen = {} ---@type table<string, boolean>
    local current = leaf
    while current and not seen[current.id] do
        seen[current.id] = true
        reversed[#reversed + 1] = current
        local parent = current.parentId
        current = type(parent) == "string" and by_id[parent] or nil
    end
    local path = {} ---@type pi.SessionEntry[]
    for i = #reversed, 1, -1 do
        path[#path + 1] = reversed[i]
    end
    return path
end

---@param entry pi.SessionEntry
---@return boolean
local function is_system_message(entry)
    return entry.type == "message" and type(entry.message) == "table" and entry.message.role == "system"
end

--- Active, compaction-aware entries: the latest compaction first, then the
--- entries it kept, then everything after it. Without a compaction, the path.
---@param entries pi.SessionEntry[]
---@param leaf_id string|userdata|nil `leafId` from `get_entries`
---@return pi.SessionEntry[]
function M.context_entries(entries, leaf_id)
    local path = session_path(entries, leaf_id)
    local compaction_idx ---@type integer?
    for i, entry in ipairs(path) do
        if entry.type == "compaction" then
            compaction_idx = i
        end
    end
    if not compaction_idx then
        return path
    end
    local compaction = path[compaction_idx]
    local result = { compaction } ---@type pi.SessionEntry[]
    local found_first_kept = false
    for i = 1, compaction_idx - 1 do
        local entry = path[i]
        if entry.id == compaction.firstKeptEntryId then
            found_first_kept = true
        end
        if found_first_kept and not is_system_message(entry) then
            result[#result + 1] = entry
        end
    end
    for i = compaction_idx + 1, #path do
        result[#result + 1] = path[i]
    end
    return result
end

return M
