--- Restore boundary bookkeeping: which records received while a chat was
--- being rebuilt from a snapshot (`get_entries`) the snapshot already shows.
---
--- A boundary is any point after which pi may already be running or may be a
--- different process: attaching, reconnecting, a session switch, a new
--- session, and the rebuild after compaction. Records that arrive between the
--- boundary and the snapshot response are held, then applied in order minus
--- what the snapshot already contains:
--- - messages, identified by role and timestamp (a message is persisted at its
---   `message_end`, so it's either in the snapshot and ended, or neither);
--- - tool execution starts whose tool call the snapshot already drew;
--- - tool execution updates and ends whose result the snapshot already has.
--- Everything else is applied.

local M = {}

--- What a snapshot already shows.
---@class pi.RestoreIndex
---@field messages table<string, true> role + timestamp keys of persisted messages
---@field tool_calls table<string, true> tool call ids in persisted assistant messages
---@field tool_results table<string, true> tool call ids with a persisted result

---@param message table?
---@return string?
local function message_key(message)
    if type(message) ~= "table" or type(message.role) ~= "string" then
        return nil
    end
    local ts = message.timestamp
    if ts == nil or ts == vim.NIL then
        return nil
    end
    return message.role .. "\0" .. tostring(ts)
end

--- Index the entries of a `get_entries` response.
---@param entries pi.SessionEntry[]
---@return pi.RestoreIndex
function M.index(entries)
    ---@type pi.RestoreIndex
    local index = { messages = {}, tool_calls = {}, tool_results = {} }
    for _, entry in ipairs(entries or {}) do
        local message = entry.type == "message" and entry.message or nil
        if type(message) == "table" then
            local key = message_key(message)
            if key then
                index.messages[key] = true
            end
            if message.role == "assistant" and type(message.content) == "table" then
                for _, part in ipairs(message.content) do
                    if type(part) == "table" and part.type == "toolCall" then
                        local id = part.id or part.toolCallId
                        if type(id) == "string" then
                            index.tool_calls[id] = true
                        end
                    end
                end
            elseif message.role == "toolResult" then
                local id = message.toolCallId or message.toolUseId
                if type(id) == "string" then
                    index.tool_results[id] = true
                end
            end
        end
    end
    return index
end

---@param index pi.RestoreIndex
---@param message table?
---@return boolean
local function in_snapshot(index, message)
    local key = message_key(message)
    return key ~= nil and index.messages[key] == true
end

--- Records to apply after a rebuild from `index`, in order.
---@param held pi.RpcEvent[]
---@param index pi.RestoreIndex
---@return pi.RpcEvent[] apply
---@return integer dropped_user user `message_start`s dropped because the snapshot already shows them
function M.filter(held, index)
    ---@type pi.RpcEvent[]
    local apply = {}
    local dropped_user = 0
    --- The message the current `message_update`s belong to: drop or keep.
    ---@type { drop: boolean }?
    local current = nil

    --- Whether the next held `message_end` is a message the snapshot shows.
    ---@param from integer
    ---@return boolean
    local function next_end_in_snapshot(from)
        for j = from, #held do
            if held[j].type == "message_end" then
                return in_snapshot(index, held[j].message --[[@as table?]])
            end
        end
        return false
    end

    for i, msg in ipairs(held) do
        local t = msg.type
        local keep = true
        if t == "message_start" then
            local message = msg.message --[[@as table?]]
            local drop = in_snapshot(index, message)
            current = { drop = drop }
            keep = not drop
            if drop and type(message) == "table" and message.role == "user" then
                dropped_user = dropped_user + 1
            end
        elseif t == "message_update" then
            -- Updates carry no message; they belong to the message started
            -- last, or to one that started before the boundary.
            if not current then
                current = { drop = next_end_in_snapshot(i + 1) }
            end
            keep = not current.drop
        elseif t == "message_end" then
            keep = not in_snapshot(index, msg.message --[[@as table?]])
            current = nil
        elseif t == "tool_execution_start" then
            local id = msg.toolCallId
            keep = not (type(id) == "string" and (index.tool_calls[id] or index.tool_results[id]))
        elseif t == "tool_execution_update" or t == "tool_execution_end" then
            local id = msg.toolCallId
            keep = not (type(id) == "string" and index.tool_results[id])
        end
        if keep then
            apply[#apply + 1] = msg
        end
    end
    return apply, dropped_user
end

return M
