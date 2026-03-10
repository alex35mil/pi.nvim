--- Handle extension UI requests (dialogs, notifications, etc.).

local M = {}

local Diff = require("pi.ui.diff")
local Dialog = require("pi.ui.dialog")
local Notify = require("pi.notify")

---@param session pi.Session
---@param msg pi.RpcEvent
function M.handle(session, msg)
    local id = msg.id
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

    local rpc = session.rpc

    -- Dialog methods (expect a response)
    if method == "select" then
        -- Check for diff review request (JSON-encoded title with toolName)
        local ok, payload = pcall(vim.json.decode, msg.title or "")
        if ok and payload and (payload.toolName == "edit" or payload.toolName == "write") then
            Diff.open(payload, function(result)
                rpc:send({ type = "extension_ui_response", id = id, value = result })
            end)
            return
        end

        Dialog.select({ title = "Select", message = msg.title, options = msg.options or {} }, function(choice)
            if choice then
                rpc:send({ type = "extension_ui_response", id = id, value = choice })
            else
                rpc:send({ type = "extension_ui_response", id = id, cancelled = true })
            end
        end)
        return
    end

    if method == "confirm" then
        Dialog.confirm({
            title = msg.title,
            message = msg.message --[[@as string?]],
        }, function(confirmed)
            if confirmed then
                rpc:send({ type = "extension_ui_response", id = id, confirmed = true })
            else
                rpc:send({ type = "extension_ui_response", id = id, cancelled = true })
            end
        end)
        return
    end

    if method == "input" or method == "editor" then
        Dialog.input({
            title = msg.title or "Input",
            default = msg.prefill or msg.placeholder or "",
        }, function(value)
            if value then
                rpc:send({ type = "extension_ui_response", id = id, value = value })
            else
                rpc:send({ type = "extension_ui_response", id = id, cancelled = true })
            end
        end)
        return
    end
end

return M
