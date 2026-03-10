--- Thinking controls: visibility toggle and level selection.

local M = {}

local Notify = require("pi.notify")

---@type string[]
local LEVELS = { "off", "minimal", "low", "medium", "high", "xhigh" }

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
                Notify.warn("Current model does not support thinking")
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
            if res.success and res.data then
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
    session.rpc:send({ type = "get_state" }, function(res)
        local initial_index = 1
        local current_level = res.success and res.data and res.data.thinkingLevel or nil
        if type(current_level) == "string" then
            for i, level in ipairs(LEVELS) do
                if level == current_level then
                    initial_index = i
                    break
                end
            end
        end

        vim.schedule(function()
            Dialog.select(
                { title = "Thinking level", options = LEVELS, initial_index = initial_index },
                function(choice)
                    if not choice then
                        return
                    end
                    M.set(session, choice)
                end
            )
        end)
    end)
end

return M
