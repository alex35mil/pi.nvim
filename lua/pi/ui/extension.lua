--- Handle extension UI requests (dialogs, notifications, etc.).

local M = {}

local Attention = require("pi.attention")
local Notify = require("pi.notify")

---@param session pi.Session
---@param msg pi.RpcEvent
function M.handle(session, msg)
    local method = msg.method

    -- Fire-and-forget methods
    if method == "notify" then
        local handlers = {
            info = Notify.info,
            warning = Notify.warn,
            error = Notify.error,
        }
        local handler = handlers[msg.notifyType] or Notify.info
        if type(msg.message) == "string" then
            handler(msg.message --[[@as string]])
        else
            handler(vim.inspect(msg.message))
        end
        return
    end
    if method == "setStatus" then
        local key = msg.statusKey
        local value = msg.statusText -- nil clears
        if type(key) == "string" then
            session.chat:set_extension_status(key, value)
        end
        return
    end
    if method == "setTitle" or method == "setWidget" or method == "set_editor_text" then
        Notify.warn("Unhandled extension UI method: " .. method)
        return
    end

    -- Dialog methods (expect a response)
    if method == "select" or method == "confirm" or method == "input" or method == "editor" then
        Attention.present(session, msg)
        return
    end
end

return M
