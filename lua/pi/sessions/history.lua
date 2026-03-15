local M = {}

local Config = require("pi.config")

---@class pi.SessionInfo
---@field id string            session id from header
---@field path string          absolute path to .jsonl file
---@field timestamp string     ISO timestamp from header
---@field modified number      file mtime (for sorting)
---@field first_message string first user message (truncated)
---@field name? string         display name from session_info entry

--- Resolve the pi agent directory.
---@return string
local function get_agent_dir()
    if Config.options.agent_dir then
        return Config.options.agent_dir
    end
    local env = vim.env.PI_CODING_AGENT_DIR
    if env and env ~= "" then
        return env
    end
    return vim.fn.expand("~/.pi/agent")
end

--- Encode a cwd path into the directory name format pi uses.
--- e.g. "/Users/Alex/Dev/project" → "--Users-Alex-Dev-project--"
---@param cwd string
---@return string
local function encode_cwd(cwd)
    local encoded = cwd:gsub("^/", ""):gsub("/", "-")
    return "--" .. encoded .. "--"
end

--- Get the sessions directory for the current cwd.
---@return string
function M.get_sessions_dir()
    local agent_dir = get_agent_dir()
    local cwd = vim.fn.getcwd()
    return agent_dir .. "/sessions/" .. encode_cwd(cwd)
end

--- Parse a .jsonl session file: read header + first user message.
---@param path string
---@return pi.SessionInfo?
local function parse_session_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local header_line = file:read("*l")
    if not header_line or header_line == "" then
        file:close()
        return nil
    end
    local ok, header = pcall(vim.json.decode, header_line)
    if not ok or not header or header.type ~= "session" then
        file:close()
        return nil
    end

    -- Scan entire file for first user message and session name (latest wins).
    local first_message = ""
    local name = nil
    for line in file:lines() do
        local lok, entry = pcall(vim.json.decode, line)
        if lok and entry then
            if entry.type == "session_info" and type(entry.name) == "string" and entry.name ~= "" then
                name = entry.name:match("^%s*(.-)%s*$") -- trim
            end
            if first_message == "" and entry.type == "message" then
                local msg = entry.message
                if msg and msg.role == "user" then
                    local content = msg.content
                    if type(content) == "string" then
                        first_message = content
                    elseif type(content) == "table" then
                        for _, part in ipairs(content) do
                            if type(part) == "table" and part.type == "text" then
                                first_message = part.text or ""
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    file:close()

    -- Truncate to single line, max 80 chars
    first_message = first_message:gsub("\n", " "):sub(1, 80)

    return {
        path = path,
        id = header.id or "",
        timestamp = header.timestamp or "",
        modified = vim.fn.getftime(path),
        first_message = first_message,
        name = name,
    }
end

--- List all sessions for the current cwd, sorted by modified time (newest first).
---@return pi.SessionInfo[]
function M.list()
    local dir = M.get_sessions_dir()
    ---@type string[]
    local files = vim.fn.glob(dir .. "/*.jsonl", false, true)
    ---@type pi.SessionInfo[]
    local sessions = {}
    for _, file in ipairs(files) do
        local info = parse_session_file(file)
        if info then
            sessions[#sessions + 1] = info
        end
    end
    table.sort(sessions, function(a, b)
        return a.modified > b.modified
    end)
    return sessions
end

return M
