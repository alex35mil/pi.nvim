--- https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/src/modes/rpc/rpc-types.ts
---@alias pi.RpcEventType
---| "agent_start"
---| "agent_end"
---| "agent_settled"
---| "queue_update"
---| "message_start"
---| "message_update"
---| "message_end"
---| "turn_start"
---| "turn_end"
---| "tool_execution_start"
---| "tool_execution_update"
---| "tool_execution_end"
---| "compaction_start"
---| "compaction_end"
---| "entry_appended"
---| "thinking_level_changed"
---| "session_info_changed"
---| "auto_retry_start"
---| "auto_retry_end"
---| "summarization_retry_scheduled"
---| "summarization_retry_attempt_start"
---| "summarization_retry_finished"
---| "bash_execution_update"
---| "extension_ui_request"
---| "extension_error"
---| "response"
---| "_process_exit"
---| "_stderr"

--- https://github.com/earendil-works/pi/blob/v1.3.0/packages/ai/src/types.ts
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

--- https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/src/modes/rpc/rpc-types.ts
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
---| "get_session_stats"
---| "compact"
---| "set_thinking_level"
---| "cycle_thinking_level"
---| "get_available_thinking_levels"
---| "set_model"
---| "cycle_model"
---| "get_available_models"
---| "set_session_name"
---| "extension_ui_response"

---@alias pi.PromptDisposition "started"|"queued"|"handled"

---@class pi.SessionStats
---@field tokens { input: integer, output: integer, cacheRead: integer, cacheWrite: integer, total: integer }
---@field cost number
---@field contextUsage? { tokens: integer?, contextWindow: integer, percent: number? } JSON null tokens/percent mean unknown after compaction.

---@class pi.CodemodeCall
---@field id string
---@field name string
---@field args string
---@field status "running"|"ok"|"error"|"cancelled"
---@field durationMs? number
---@field error? string
---@field cost? number

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

--- https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/json.md
---@class pi.RpcEvent
---@field type pi.RpcEventType
---@field assistantMessageEvent? { type: pi.AssistantMessageEventType, contentIndex?: integer, delta?: string, content?: string, toolCall?: pi.ToolCall, id?: string, toolName?: string }
---@field toolName? string
---@field toolCallId? string
---@field parentToolCallId? string
---@field durationMs? number
---@field aborted? boolean
---@field willRetry? boolean
---@field reason? "manual"|"threshold"|"overflow"
---@field source? "compaction"|"branchSummary"
---@field usage? table
---@field entry? { type: string, [string]: any }
---@field args? table
---@field result? { content?: table[], details?: table }
---@field isError? boolean
---@field command? string
---@field success? boolean
---@field data? { disposition?: pi.PromptDisposition, [string]: any }
---@field code? integer
---@field error? string
---@field id? string
---@field method? string
---@field message? string|{ stopReason?: string, errorMessage?: string, [string]: any }
---@field messages? table[]
---@field steering? string[]
---@field followUp? string[]
---@field notifyType? "info"|"warning"|"error"
---@field options? string[]
---@field timeout? integer
---@field title? string
---@field prefill? string
---@field placeholder? string
---@field [string] any

---@class pi.ToolCall
---@field id string
---@field name string
---@field arguments table
---@field argumentsError? string

---@class pi.Rpc
---@field _job_id integer?
---@field _handler fun(msg: pi.RpcEvent)?
---@field _pending table<string, fun(msg: pi.RpcEvent)>
---@field _tab pi.TabId
---@field _workspace string Directory pi is launched in.
---@field _commands pi.CommandCatalog Command catalog updated by `ctx.set_commands()`.
---@field _log_path string Per-connection RPC debug log.
---@field _req_id integer
---@field _stdout_buf string
---@field _stopping boolean
local Rpc = {}
Rpc.__index = Rpc

local Config = require("pi.config")
local Cli = require("pi.cli")
local Notify = require("pi.notify")

local DEBUG_OVERRIDE = nil ---@type boolean?

--- Log files reset since debug was last enabled.
---@type table<string, boolean>
local log_reset_done = {}

--- Live connections, so toggling debug can reset every running session's log.
---@type table<pi.Rpc, true>
local live = setmetatable({}, { __mode = "k" })

local function debug_enabled()
    if DEBUG_OVERRIDE ~= nil then
        return DEBUG_OVERRIDE
    end
    return Config.options.debug
end

--- Root directory for RPC debug logs.
---@return string
function Rpc.log_dir()
    return vim.fn.stdpath("log") .. "/pi"
end

--- Log path for a connection: one directory per workspace, one file per tab.
---@param workspace string
---@param tab pi.TabId
---@return string
local function log_path_for(workspace, tab)
    local slug = workspace:gsub("^/", ""):gsub("/", "--")
    if slug == "" then
        slug = "root"
    end
    return Rpc.log_dir() .. "/" .. slug .. "/rpc-tab" .. tab .. ".log"
end

--- Recursively create directories (libuv-safe, no vim.fn).
---@param dir string
local function mkdirp(dir)
    local stat = vim.uv.fs_stat(dir)
    if stat then
        return
    end
    local parent = dir:match("(.+)/[^/]+$")
    if parent then
        mkdirp(parent)
    end
    vim.uv.fs_mkdir(dir, 493) -- 0755
end

--- Reset a log file (creates parent directories if needed).
---@param path string
local function reset_log(path)
    local dir = path:match("(.+)/[^/]+$")
    if dir then
        mkdirp(dir)
    end
    local file = io.open(path, "w")
    if file then
        file:close()
    end
    log_reset_done[path] = true
end

---@param log_path string
---@param tag string
---@param msg table|string
local function log(log_path, tag, msg)
    if not debug_enabled() then
        return
    end
    if not log_reset_done[log_path] then
        reset_log(log_path)
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

--- Adapter context for one connection; `set_commands` updates only its catalog.
---@param commands pi.CommandCatalog
---@return pi.RpcAdapterContext
local function adapter_context(commands)
    return {
        set_commands = function(list)
            if type(list) ~= "table" then
                vim.schedule(function()
                    Notify.error("RPC ctx.set_commands expects a command list table")
                end)
                return
            end
            commands:set(list)
        end,
    }
end

---@param mapper function
---@param msg table
---@param ctx pi.RpcAdapterContext
---@return table?
local function map_event(mapper, msg, ctx)
    local ok, mapped = pcall(mapper, vim.deepcopy(msg), ctx)
    if not ok then
        vim.schedule(function()
            Notify.error("RPC map_event error: " .. tostring(mapped))
        end)
        return msg
    end
    if mapped == nil then
        return nil
    end
    if type(mapped) ~= "table" then
        vim.schedule(function()
            Notify.error("RPC map_event must return an event table or nil")
        end)
        return msg
    end
    if type(mapped.type) ~= "string" or mapped.type == "" then
        vim.schedule(function()
            Notify.error("RPC map_event returned an event without a string type")
        end)
        return msg
    end
    return mapped
end

---@param mapper function
---@param cmd table
---@param ctx pi.RpcAdapterContext
---@return table?
local function map_command(mapper, cmd, ctx)
    local ok, mapped = pcall(mapper, cmd, ctx)
    if not ok then
        vim.schedule(function()
            Notify.error("RPC map_command error: " .. tostring(mapped))
        end)
        return nil
    end
    if mapped == nil then
        return nil
    end
    if type(mapped) ~= "table" then
        vim.schedule(function()
            Notify.error("RPC map_command must return a command table or nil")
        end)
        return nil
    end
    if type(mapped.id) ~= "string" or mapped.id == "" then
        vim.schedule(function()
            Notify.error("RPC map_command returned a command without a string id")
        end)
        return nil
    end
    return mapped
end

---@type table<string, true>
local warned = {}

---@param tab pi.TabId
---@param workspace string directory pi is launched in
---@param commands pi.CommandCatalog catalog that `ctx.set_commands()` updates
---@return pi.Rpc
function Rpc.new(tab, workspace, commands)
    local self = setmetatable({}, Rpc)
    self._job_id = nil
    self._handler = nil
    self._pending = {}
    self._tab = tab
    self._workspace = workspace
    self._commands = commands
    self._log_path = log_path_for(workspace, tab)
    self._req_id = 1
    self._stdout_buf = ""
    self._stopping = false
    return self
end

---@param tag string
---@param msg table|string
function Rpc:_log(tag, msg)
    log(self._log_path, tag, msg)
end

---@param msg pi.RpcEvent
function Rpc:_dispatch(msg)
    local event_mapper = Config.options.rpc and Config.options.rpc.map_event
    if type(event_mapper) == "function" then
        msg = map_event(event_mapper, msg, adapter_context(self._commands)) --[[@as pi.RpcEvent]]
    end
    if not msg or not msg.type then
        return
    end

    self:_log("incoming", msg)

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
    self._stopping = false
    local cmd = Cli.command()
    self._job_id = vim.fn.jobstart(cmd, {
        cwd = self._workspace,
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
    live[self] = true
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

    local command_mapper = Config.options.rpc and Config.options.rpc.map_command
    if type(command_mapper) == "function" then
        cmd = map_command(command_mapper, cmd, adapter_context(self._commands)) --[[@as pi.RpcCommand]]
    end
    if not cmd then
        return false
    end

    if callback then
        self._pending[cmd.id] = callback
    end
    self:_log("outgoing", cmd)
    vim.fn.chansend(self._job_id, vim.json.encode(cmd) .. "\n")
    return true
end

---@param fn fun(msg: pi.RpcEvent)
function Rpc:set_handler(fn)
    self._handler = fn
end

function Rpc:stop()
    live[self] = nil
    if self._job_id then
        self._stopping = true
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
                self:_log("ERROR", "Failed to decode: " .. err .. " | " .. line)
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
    live[self] = nil
    local expected = self._stopping
    self._job_id = nil
    self._stdout_buf = ""
    self._pending = {}
    self._stopping = false
    self:_dispatch({ type = "_process_exit", code = code, expected = expected })
end

--- Toggle debug logging. Turning it on resets every running connection's log;
--- connections started later begin with a fresh log of their own.
function Rpc.toggle_debug()
    DEBUG_OVERRIDE = not debug_enabled()
    if debug_enabled() then
        log_reset_done = {}
        for rpc in pairs(live) do
            reset_log(rpc._log_path)
        end
        Notify.info("Debug ON -> " .. Rpc.log_dir())
    else
        Notify.info("Debug OFF")
    end
end

---@param event_type string
function Rpc:log_unhandled(event_type)
    if warned[event_type] then
        return
    end

    warned[event_type] = true

    self:_log("UNHANDLED", event_type)

    if debug_enabled() then
        vim.schedule(function()
            Notify.warn("Unhandled event: " .. event_type)
        end)
    end
end

return Rpc
