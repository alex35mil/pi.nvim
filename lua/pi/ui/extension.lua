--- Handle extension UI requests (dialogs, notifications, etc.).

local M = {}

local Attention = require("pi.attention")
local Notify = require("pi.notify")
local Config = require("pi.config")
local Startup = require("pi.startup")
local CommandsCache = require("pi.cache.commands")

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
        local key = msg.widgetKey
        if type(key) ~= "string" then
            return
        end

        local widget_lines = {} ---@type string[]
        if type(msg.widgetLines) == "table" then
            for _, line in ipairs(msg.widgetLines) do
                if type(line) == "string" then
                    widget_lines[#widget_lines + 1] = line
                end
            end
        end

        -- Keys ending with `:startup` (e.g. "my-ext:startup") are startup
        -- announcements. They are stored in session.startup_announcements and
        -- rendered in the system preamble. on_widget is NOT called for them.
        local is_startup = key:sub(-#":startup") == ":startup"

        if is_startup then
            -- Store/clear startup announcement and re-render preamble.
            if #widget_lines > 0 then
                session.startup_announcements[key] = { lines = widget_lines }
            else
                session.startup_announcements[key] = nil
            end

            -- list() may be stale if the initial fetch hasn't completed yet;
            -- fetch_commands_and_show_startup_block will re-render once it does.
            session.chat:show_startup_block({
                sections = Startup.build_startup_sections(session, CommandsCache.list()),
                errors = session.system_errors,
            })
            return
        end

        -- Non-startup widget: route through on_widget callback.
        local on_widget = Config.options.on_widget
        if on_widget then
            local ok, result = pcall(on_widget, key, #widget_lines > 0 and widget_lines or nil, msg.widgetPlacement)
            if not ok then
                Notify.error("on_widget error: " .. tostring(result))
            elseif result then
                if result.target == "history" and result.block == "custom" then
                    session.chat:append_custom_block(result)
                end
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
