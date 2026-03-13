--- Handle extension UI requests (dialogs, notifications, etc.).

local M = {}

local Attention = require("pi.attention")
local Notify = require("pi.notify")
local Config = require("pi.config")
local CommandsCache = require("pi.cache.commands")
local SystemReport = require("pi.system_report")

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
    if method == "setWidget" then
        -- Extensions can publish named text blocks ("widgets") that appear in the
        -- system preamble at session start. This is the only mechanism for extensions
        -- to surface persistent info in the UI via RPC without injecting into the
        -- conversation context. Ideally the RPC protocol would provide a dedicated
        -- event for extensions to report loaded resources to the UI, but no such
        -- mechanism exists yet.
        local key = msg.widgetKey
        if type(key) == "string" then
            local widget_lines = {} ---@type string[]
            if type(msg.widgetLines) == "table" then
                for _, line in ipairs(msg.widgetLines) do
                    if type(line) == "string" then
                        widget_lines[#widget_lines + 1] = line
                    end
                end
            end
            if #widget_lines > 0 then
                session.widgets[key] = {
                    lines = widget_lines,
                    placement = msg.widgetPlacement,
                }
            else
                session.widgets[key] = nil
            end

            -- list() may be stale if the initial fetch hasn't completed yet;
            -- fetch_commands_and_show_system_info will re-render once it does.
            if Config.options.ui.show_system_messages then
                session.chat:show_system_info(
                    SystemReport.build_startup_sections(session, CommandsCache.list()),
                    session.system_errors
                )
            end
        end
        return
    end
    if method == "setTitle" or method == "set_editor_text" then
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
