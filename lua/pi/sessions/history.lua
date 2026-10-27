--- Saved-session listing for the default session store.
---
--- The session folder is never computed here: it is the folder pi reports for
--- its current session file, so pi's own `--session-dir`,
--- `PI_CODING_AGENT_SESSION_DIR`, and `sessionDir` resolution is honored.

local M = {}

local Workspace = require("pi.workspace")

---@class pi.SessionInfo
---@field id string            session id from header
---@field path string          absolute path to .jsonl file
---@field timestamp string     ISO timestamp from header
---@field modified number      file mtime (for sorting)
---@field first_message string first user message (truncated)
---@field name? string         display name from session_info entry
---@field cwd? string          working directory recorded in the header

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
        cwd = type(header.cwd) == "string" and header.cwd ~= "" and header.cwd or nil,
    }
end

--- List a session folder's sessions for a workspace, newest first.
--- A folder may be shared by several projects (custom session dirs), so only
--- sessions recorded for the workspace are kept. Paths are compared with
--- symlinks resolved, because pi records its real working directory.
--- Sessions whose header records no directory are kept.
---@param dir string session folder reported by pi
---@param workspace string session workspace
---@return pi.SessionInfo[]
function M.list(dir, workspace)
    local real_workspace = Workspace.realpath(workspace)
    ---@type pi.SessionInfo[]
    local sessions = {}
    for name, kind in vim.fs.dir(dir) do
        if kind == "file" and name:match("%.jsonl$") then
            local info = parse_session_file(vim.fs.joinpath(dir, name))
            if info and (not info.cwd or Workspace.realpath(info.cwd) == real_workspace) then
                sessions[#sessions + 1] = info
            end
        end
    end
    table.sort(sessions, function(a, b)
        return a.modified > b.modified
    end)
    return sessions
end

return M
