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
---@field _launch pi.Launch Command and environment to start.
---@field _log_path string Per-connection RPC debug log.
---@field _req_id integer
---@field _stdout_buf string
---@field _stopping boolean
---@field _stop? pi.RpcStopState In-flight stop request.
---@field _exit_code? integer Exit code once the process has exited.
---@field _stderr_tail string[] Last stderr lines, kept for cleanup reports.
local Rpc = {}
Rpc.__index = Rpc

--- What to start for a connection: local pi or a workspace descriptor's command.
---@class pi.Launch
---@field cmd string[] Complete argument list.
---@field env? table<string, string> Variables added to the inherited environment.
---@field descriptor? string Real path of the descriptor it came from; nil for local pi.
---@field stop_grace_ms? integer Grace period for this launch; nil = `process.stop.grace_ms`.

--- Outcome of a stop that didn't end cleanly.
---@alias pi.StopOutcome
---| "exit" # exited with a non-zero code after its input closed
---| "timeout" # still running when the grace period ended; force-stopped
---| "forced" # still running when Neovim's exit budget ended; force-stopped

---@class pi.StopReport
---@field outcome pi.StopOutcome
---@field code? integer
---@field command string
---@field workspace string
---@field descriptor? string Descriptor the launch came from; nil for local pi.
---@field stderr string[]
---@field log? string
---@field log_tail? string[] Last RPC log entries at the time of the stop (debug logging on); kept because the log is reset when the tab starts pi again.

---@class pi.RpcStopState
---@field timer? uv.uv_timer_t
---@field forced? pi.StopOutcome Set when the stop had to force the process down.
---@field callback? fun(report: pi.StopReport?)

local Config = require("pi.config")
local Notify = require("pi.notify")

local STDERR_TAIL = 20

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

--- Last log entries kept in a cleanup report, and the length each is cut to
--- (entries can be whole command catalogs).
local LOG_TAIL_ENTRIES = 10
local LOG_TAIL_ENTRY_CHARS = 300

--- Last entries of a connection's log, newest last, each shortened.
---@param path string
---@return string[]?
local function read_log_tail(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local size = file:seek("end") or 0
    file:seek("set", math.max(0, size - 256 * 1024))
    local content = file:read("*a") or ""
    file:close()
    ---@type string[]
    local entries = {}
    for line in vim.gsplit(content, "\n", { plain = true }) do
        if line:match("^%[%d%d:%d%d:%d%d%] %[") then
            if #line > LOG_TAIL_ENTRY_CHARS then
                line = line:sub(1, LOG_TAIL_ENTRY_CHARS) .. "…"
            end
            entries[#entries + 1] = line
            if #entries > LOG_TAIL_ENTRIES then
                table.remove(entries, 1)
            end
        end
    end
    return entries
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
---@param launch pi.Launch command and environment to start
---@return pi.Rpc
function Rpc.new(tab, workspace, commands, launch)
    local self = setmetatable({}, Rpc)
    self._job_id = nil
    self._handler = nil
    self._pending = {}
    self._tab = tab
    self._workspace = workspace
    self._commands = commands
    self._launch = launch
    self._log_path = log_path_for(workspace, tab)
    self._req_id = 1
    self._stdout_buf = ""
    self._stopping = false
    self._stderr_tail = {}
    return self
end

--- Name of the launched command, for reports.
---@return string
function Rpc:command_name()
    return vim.fs.basename(self._launch.cmd[1] or "?")
end

--- Last stderr lines of the launch.
---@return string[]
function Rpc:stderr_tail()
    return vim.deepcopy(self._stderr_tail)
end

---@param outcome pi.StopOutcome
---@param code? integer
---@return pi.StopReport
function Rpc:_report(outcome, code)
    return {
        outcome = outcome,
        code = code,
        command = self:command_name(),
        workspace = self._workspace,
        descriptor = self._launch.descriptor,
        stderr = self:stderr_tail(),
        log = debug_enabled() and self._log_path or nil,
        log_tail = debug_enabled() and read_log_tail(self._log_path) or nil,
    }
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
    self._exit_code = nil
    self._stderr_tail = {}
    -- An empty Lua table reaches jobstart as a list, which it rejects; pass env only when set.
    local env = self._launch.env
    if env and next(env) == nil then
        env = nil
    end
    self._job_id = vim.fn.jobstart(self._launch.cmd, {
        cwd = self._workspace,
        env = env,
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
        Notify.error("Failed to start " .. self:command_name() .. ". Is it installed and executable?")
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
    if not self._job_id or self._stopping then
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

--- Grace period for this launch when it stops: the descriptor's, otherwise the configured one.
---@return integer
function Rpc:grace_ms()
    if self._launch.stop_grace_ms then
        return self._launch.stop_grace_ms
    end
    -- Validated by `Config.setup()`.
    return Config.options.process.stop.grace_ms
end

--- Ask the launch to stop: close its input (pi's orderly shutdown, and the
--- wrapper's cue to clean up), wait up to the grace period, then force it.
--- `callback` runs once the process has exited, with a report when the stop
--- didn't end cleanly (non-zero exit or forced), otherwise nil.
---@param callback? fun(report: pi.StopReport?)
function Rpc:stop(callback)
    self._pending = {}
    if not self._job_id then
        if callback then
            callback(nil)
        end
        return
    end
    if self._stop then
        -- Already stopping; chain the new callback.
        local previous = self._stop.callback
        self._stop.callback = function(report)
            if previous then
                previous(report)
            end
            if callback then
                callback(report)
            end
        end
        return
    end

    self._stopping = true
    self._stop = { callback = callback }
    pcall(vim.fn.chanclose, self._job_id, "stdin")

    local timer = assert(vim.uv.new_timer())
    self._stop.timer = timer
    timer:start(
        self:grace_ms(),
        0,
        vim.schedule_wrap(function()
            if self._job_id and self._stop then
                self._stop.forced = "timeout"
                vim.fn.jobstop(self._job_id)
            end
        end)
    )
end

--- Stop every live launch at once and wait for all of them within one shared
--- budget, the longest grace period among them (Neovim exit). Launches still
--- running when it ends are force-stopped.
--- Blocks; returns a report per launch whose stop didn't end cleanly.
---@return pi.StopReport[]
function Rpc.stop_all_blocking()
    ---@type pi.Rpc[]
    local rpcs = {}
    for rpc in pairs(live) do
        if rpc._job_id then
            rpcs[#rpcs + 1] = rpc
        end
    end
    if #rpcs == 0 then
        return {}
    end

    local ids = {}
    local budget = 0
    for i, rpc in ipairs(rpcs) do
        budget = math.max(budget, rpc:grace_ms())
        rpc._stopping = true
        rpc._pending = {}
        if rpc._stop and rpc._stop.timer then
            rpc._stop.timer:stop()
            rpc._stop.timer:close()
            rpc._stop.timer = nil
        end
        pcall(vim.fn.chanclose, rpc._job_id, "stdin")
        ids[i] = rpc._job_id
    end

    -- Wait for each job against one shared deadline. A single multi-job
    -- `jobwait` can return before the timeout once an earlier job in the list
    -- exits, leaving later, slower jobs to be force-stopped early.
    local deadline = vim.uv.hrtime() + budget * 1e6
    ---@type integer[]
    local results = {}
    for i, id in ipairs(ids) do
        local remaining = math.max(0, math.floor((deadline - vim.uv.hrtime()) / 1e6))
        results[i] = vim.fn.jobwait({ id }, remaining)[1]
    end
    ---@type pi.StopReport[]
    local reports = {}
    for i, rpc in ipairs(rpcs) do
        local status = results[i]
        if status == -1 then
            -- Still running: force it down; its cleanup may be cut short.
            pcall(vim.fn.jobstop, ids[i])
            reports[#reports + 1] = rpc:_report("forced")
        else
            local code = status >= 0 and status or rpc._exit_code
            if code and code ~= 0 then
                reports[#reports + 1] = rpc:_report("exit", code)
            end
        end
        live[rpc] = nil
    end
    return reports
end

--- Number of live launches.
---@return integer
function Rpc.live_count()
    local n = 0
    for rpc in pairs(live) do
        if rpc._job_id then
            n = n + 1
        end
    end
    return n
end

---@return boolean
function Rpc:is_running()
    return self._job_id ~= nil and not self._stopping
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
            local tail = self._stderr_tail
            tail[#tail + 1] = line
            if #tail > STDERR_TAIL then
                table.remove(tail, 1)
            end
            -- While stopping, stderr is kept for the report, not shown as chat errors.
            if not self._stopping then
                self:_dispatch({ type = "_stderr", message = line })
            end
        end
    end
end

---@param code integer
function Rpc:_on_exit(code)
    live[self] = nil
    local expected = self._stopping
    local stop = self._stop
    self._stop = nil
    self._exit_code = code
    self._job_id = nil
    self._stdout_buf = ""
    self._pending = {}
    self._stopping = false
    if stop and stop.timer then
        stop.timer:stop()
        stop.timer:close()
    end
    self:_dispatch({ type = "_process_exit", code = code, expected = expected })
    if stop and stop.callback then
        ---@type pi.StopReport?
        local report = nil
        if stop.forced then
            report = self:_report(stop.forced)
        elseif code ~= 0 then
            report = self:_report("exit", code)
        end
        stop.callback(report)
    end
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
