--- https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/modes/rpc/rpc-types.ts
---@alias pi.RpcEventType
---| "agent_start"
---| "agent_end"
---| "message_start"
---| "message_update"
---| "message_end"
---| "turn_start"
---| "turn_end"
---| "tool_execution_start"
---| "tool_execution_update"
---| "tool_execution_end"
---| "auto_compaction_start"
---| "auto_compaction_end"
---| "auto_retry_start"
---| "auto_retry_end"
---| "extension_ui_request"
---| "extension_error"
---| "response"
---| "_process_exit"
---| "_stderr"

--- https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/types.ts
---@alias pi.AssistantMessageEventType
---| "start"
---| "text_start"
---| "text_delta"
---| "text_end"
---| "thinking_start"
---| "thinking_delta"
---| "thinking_end"
---| "toolcall_start"
---| "toolcall_delta"
---| "toolcall_end"
---| "done"
---| "error"

--- https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/modes/rpc/rpc-types.ts
---@alias pi.RpcCommandType
---| "prompt"
---| "steer"
---| "follow_up"
---| "abort"
---| "new_session"
---| "switch_session"
---| "get_messages"
---| "get_commands"
---| "get_state"
---| "set_thinking_level"
---| "cycle_thinking_level"
---| "extension_ui_response"

---@class pi.RpcImageContent
---@field type "image"
---@field data string base64-encoded
---@field mimeType string

---@class pi.RpcCommand
---@field type pi.RpcCommandType
---@field id? string
---@field message? string
---@field images? pi.RpcImageContent[]
---@field sessionPath? string
---@field value? string
---@field confirmed? boolean
---@field cancelled? boolean
---@field [string] any

--- https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/rpc.md
---@class pi.RpcEvent
---@field type pi.RpcEventType
---@field assistantMessageEvent? { type: pi.AssistantMessageEventType, delta?: string, toolCall?: pi.ToolCall }
---@field toolName? string
---@field toolCallId? string
---@field args? table
---@field result? { content?: table[], details?: table }
---@field isError? boolean
---@field command? string
---@field success? boolean
---@field data? table
---@field code? integer
---@field id? string
---@field method? string
---@field message? string|{ stopReason?: string, errorMessage?: string, [string]: any }
---@field messages? table[]
---@field notifyType? "info"|"warning"|"error"
---@field options? string[]
---@field title? string
---@field prefill? string
---@field placeholder? string
---@field [string] any

---@class pi.ToolCall
---@field id string
---@field name string
---@field arguments string|table

---@class pi.Rpc
---@field _job_id integer?
---@field _handler fun(msg: pi.RpcEvent)?
---@field _pending table<string, fun(msg: pi.RpcEvent)>
---@field _tab pi.TabId
---@field _req_id integer
---@field _stdout_buf string
local Rpc = {}
Rpc.__index = Rpc

local Config = require("pi.config")
local Notify = require("pi.notify")

local DEBUG_OVERRIDE = nil ---@type boolean?
local log_reset_done = false

local function debug_enabled()
    if DEBUG_OVERRIDE ~= nil then
        return DEBUG_OVERRIDE
    end
    return Config.options.debug
end

---@type string
local log_path = vim.fn.stdpath("log") .. "/pi-rpc.log"

--- Reset the log file.
local function reset_log()
    local file = io.open(log_path, "w")
    if file then
        file:close()
    end
    log_reset_done = true
end

---@param tag string
---@param msg table|string
local function log(tag, msg)
    if not debug_enabled() then
        return
    end
    if not log_reset_done then
        reset_log()
    end
    local file = io.open(log_path, "a")
    if not file then
        return
    end
    local ts = os.date("%H:%M:%S")
    local json = type(msg) == "string" and msg or vim.json.encode(msg)
    file:write(string.format("[%s] [%s] %s\n\n\n", ts, tag, json))
    file:close()
end

---@type table<string, true>
local warned = {}

---@param tab pi.TabId
---@return pi.Rpc
function Rpc.new(tab)
    local self = setmetatable({}, Rpc)
    self._job_id = nil
    self._handler = nil
    self._pending = {}
    self._tab = tab
    self._req_id = 1
    self._stdout_buf = ""
    return self
end

---@param msg pi.RpcEvent
function Rpc:_dispatch(msg)
    if not msg.type then
        return
    end

    log("incoming", msg)

    if self._handler then
        self._handler(msg)
    end

    if msg.id and self._pending[msg.id] then
        local cb = self._pending[msg.id]
        self._pending[msg.id] = nil
        cb(msg)
    end
end

---@return boolean
function Rpc:start()
    if self._job_id then
        return true
    end
    self._stdout_buf = ""
    ---@type string[]
    local cmd = { Config.options.bin, "--mode", "rpc" }
    self._job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            self:_on_stdout(data)
        end,
        on_stderr = function(_, data)
            self:_on_stderr(data)
        end,
        on_exit = function(_, code)
            self:_on_exit(code)
        end,
        stdout_buffered = false,
        stderr_buffered = false,
    })
    if self._job_id <= 0 then
        Notify.error("Failed to start process. Is 'pi' installed?")
        self._job_id = nil
        return false
    end
    return true
end

---@param cmd pi.RpcCommand
---@param callback? fun(msg: pi.RpcEvent)
---@return boolean
function Rpc:send(cmd, callback)
    if not self._job_id then
        Notify.error("Process not running")
        return false
    end
    if not cmd.id then
        cmd.id = self._tab .. ":" .. self._req_id
        self._req_id = self._req_id + 1
    end
    if callback then
        self._pending[cmd.id] = callback
    end
    log("outgoing", cmd)
    vim.fn.chansend(self._job_id, vim.json.encode(cmd) .. "\n")
    return true
end

---@param fn fun(msg: pi.RpcEvent)
function Rpc:set_handler(fn)
    self._handler = fn
end

function Rpc:stop()
    if self._job_id then
        vim.fn.jobstop(self._job_id)
        self._job_id = nil
    end
    self._stdout_buf = ""
    self._pending = {}
end

---@return boolean
function Rpc:is_running()
    return self._job_id ~= nil
end

---@param data string[]?
function Rpc:_on_stdout(data)
    if not data then
        return
    end
    data[1] = self._stdout_buf .. data[1]
    self._stdout_buf = data[#data]
    for i = 1, #data - 1 do
        local line = data[i]
        if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and msg then
                self:_dispatch(msg)
            else
                local err = tostring(msg)
                log("ERROR", "Failed to decode: " .. err .. " | " .. line)
                vim.schedule(function()
                    Notify.warn("Failed to decode RPC message: " .. err)
                end)
            end
        end
    end
end

---@param data string[]?
function Rpc:_on_stderr(data)
    if not data then
        return
    end
    for _, line in ipairs(data) do
        if line ~= "" then
            self:_dispatch({ type = "_stderr", message = line })
        end
    end
end

---@param code integer
function Rpc:_on_exit(code)
    self._job_id = nil
    self._stdout_buf = ""
    self:_dispatch({ type = "_process_exit", code = code })
end

function Rpc.toggle_debug()
    DEBUG_OVERRIDE = not debug_enabled()
    if debug_enabled() then
        reset_log()
        Notify.info("Debug ON -> " .. log_path)
    else
        Notify.info("Debug OFF")
    end
end

---@param event_type string
function Rpc.log_unhandled(event_type)
    if warned[event_type] then
        return
    end

    warned[event_type] = true

    log("UNHANDLED", event_type)

    if debug_enabled() then
        vim.schedule(function()
            Notify.warn("Unhandled event: " .. event_type)
        end)
    end
end

return Rpc
