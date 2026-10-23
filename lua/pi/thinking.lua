--- Thinking controls: visibility toggle and level selection.

local M = {}

local Notify = require("pi.notify")

--- Toggle thinking block visibility.
---@param session pi.Session
function M.toggle(session)
    session.chat:toggle_thinking()
end

--- Send set_thinking_level RPC and refresh state on success.
---@param session pi.Session
---@param level string
function M.set(session, level)
    local Sessions = require("pi.sessions.manager")
    session.rpc:send({ type = "set_thinking_level", level = level }, function(res)
        vim.schedule(function()
            if res.success then
                Sessions.refresh_state(session)
            else
                Notify.warn(res.error or "Failed to set thinking level")
            end
        end)
    end)
end

--- Cycle to the next thinking level.
---@param session pi.Session
function M.cycle(session)
    local Sessions = require("pi.sessions.manager")
    session.rpc:send({ type = "cycle_thinking_level" }, function(res)
        vim.schedule(function()
            if not res.success then
                Notify.warn(res.error or "Failed to cycle thinking level")
            elseif res.data then
                Sessions.refresh_state(session)
            else
                Notify.warn("Current model does not support thinking")
            end
        end)
    end)
end

--- Select a thinking level from a picker.
---@param session pi.Session
function M.select(session)
    local Dialog = require("pi.ui.dialog")
    session.rpc:send({ type = "get_state" }, function(state)
        if not state.success then
            vim.schedule(function()
                Notify.warn(state.error or "Failed to fetch thinking state")
            end)
            return
        end
        session.rpc:send({ type = "get_available_thinking_levels" }, function(res)
            vim.schedule(function()
                if not res.success then
                    Notify.warn(res.error or "Failed to fetch thinking levels")
                    return
                end
                local levels = res.data and res.data.levels
                if type(levels) ~= "table" or #levels == 0 then
                    Notify.warn("Pi returned no supported thinking levels")
                    return
                end
                local initial_index = 1
                local current_level = state.data and state.data.thinkingLevel
                for i, level in ipairs(levels) do
                    if level == current_level then
                        initial_index = i
                        break
                    end
                end
                Dialog.select(
                    { title = "Thinking level", options = levels, initial_index = initial_index },
                    function(choice)
                        if choice then
                            M.set(session, choice)
                        end
                    end
                )
            end)
        end)
    end)
end

return M
