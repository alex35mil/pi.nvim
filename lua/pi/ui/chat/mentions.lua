--- @-mention expansion and insertion.

local M = {}

local Notify = require("pi.notify")
local Decorators = require("pi.ui.chat.decorators")
local Workspace = require("pi.workspace")

--- Punctuation pattern for characters that may follow an @-mention
--- but are not part of the path (e.g. `(@file)` or `@file.`).
local TRAILING_PUNCT = "[%.,;:!%?%)]+"

--- Strip trailing punctuation from a raw @-mention capture.
---@param ref string  raw capture from `@(%S+)`
---@return string clean  ref without trailing punctuation
---@return string trailing  the stripped punctuation (may be empty)
function M.strip_trailing(ref)
    local trailing = ""
    local clean = ref:gsub("(" .. TRAILING_PUNCT .. ")$", function(m)
        trailing = m
        return ""
    end)
    return clean, trailing
end

--- Expand @-mentions into context hints the agent understands.
--- `@path/to/file` → `[file: path/to/file]`
--- `@path/to/file#L10` → `[file: path/to/file, line: 10]`
--- `@path/to/file#L10-20` → `[file: path/to/file, lines: 10-20]`
--- `@path/to/dir/` → `[directory: path/to/dir/]`
--- No file content is inlined — the agent has Read tool.
--- Relative paths are checked against the session's workspace, where pi
--- resolves them. Absolute paths are translated to the path pi sees. A path
--- pi can't reach through the mapping (absolute, or relative with `..` out of
--- the workspace) is reported and left unexpanded.
---@param text string
---@param workspace string
---@param execution? pi.Execution session's execution; nil = local pi
---@return string
function M.expand(text, workspace, execution)
    local result = text:gsub("@(%S+)", function(ref)
        local clean, trailing = M.strip_trailing(ref)
        local path, range = clean:match("^(.-)#L(%d+%-?%d*)$")
        if not path then
            path = clean
        end
        local abs = Workspace.resolve(workspace, path)
        local is_dir = vim.fn.isdirectory(abs) == 1
        if not is_dir and vim.fn.filereadable(abs) ~= 1 then
            return nil
        end
        local shown = path
        if execution then
            local absolute = vim.startswith(vim.fs.normalize(path), "/")
            local reachable
            if absolute then
                reachable = execution:to_exec(abs)
            else
                reachable = execution:relative_to_host(path) == abs
            end
            if not reachable then
                Notify.warn("pi: @" .. path .. " is outside the mapped workspace; sent as plain text")
                return nil
            end
            if absolute then
                shown = reachable --[[@as string]]
            end
        end
        if is_dir then
            return "[directory: " .. shown .. "]" .. trailing
        end
        local expansion
        if range then
            local label = range:find("-") and "lines" or "line"
            expansion = "[file: " .. shown .. ", " .. label .. ": " .. range .. "]"
        else
            expansion = "[file: " .. shown .. "]"
        end
        return expansion .. trailing
    end)
    return result
end

--- Insert an @-mention at the cursor in the pi prompt buffer.
---@param loc { path: string, start_line?: integer, end_line?: integer }
---@param opts? { focus?: boolean } default: focus = true
function M.send(loc, opts)
    opts = opts or {}
    require("pi.sessions.manager").get_or_create(nil, function(session)
        if session then
            M._insert(session, loc, opts)
        end
    end)
end

---@param session pi.Session
---@param loc { path: string, start_line?: integer, end_line?: integer }
---@param opts { focus?: boolean }
function M._insert(session, loc, opts)
    local abs = vim.fn.fnamemodify(loc.path, ":p")
    local mention = "@" .. Workspace.relative(session.workspace, abs)
    if loc.start_line and loc.end_line and loc.start_line ~= loc.end_line then
        mention = mention .. "#L" .. loc.start_line .. "-" .. loc.end_line
    elseif loc.start_line then
        mention = mention .. "#L" .. loc.start_line
    end
    if opts.focus ~= false then
        session.chat:ensure_shown_and_focus_prompt()
    else
        session.chat:show()
    end

    vim.schedule(function()
        local buf = session.chat:prompt_buf()
        local win = session.chat:prompt_win()

        local row, col
        if win and vim.api.nvim_win_is_valid(win) then
            row, col = unpack(vim.api.nvim_win_get_cursor(win))
        else
            row = vim.api.nvim_buf_line_count(buf)
            local last_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
            col = #last_line
        end

        local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
        -- col is 0-indexed byte offset; insert at cursor position
        local before = col > 0 and line:sub(col, col) or ""
        local after = col < #line and line:sub(col + 1, col + 1) or ""

        local prefix = (before ~= "" and before ~= " ") and " " or ""
        local suffix = (after ~= " ") and " " or ""
        local insert = prefix .. mention .. suffix

        vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { insert })
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_cursor(win, { row, col + #insert })
        end

        Decorators.update(buf)
    end)
end

--- Send @-mention for current buffer.
--- Detects visual selection from either
--- command range args or visual mode marks.
---@param args? table command args from nvim_create_user_command
---@param opts? { focus?: boolean }
function M.send_current(args, opts)
    local buf = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" then
        Notify.warn("Buffer has no file")
        return
    end

    local loc = { path = path }
    if args and args.range and args.range > 0 then
        loc.start_line = args.line1
        loc.end_line = args.line2
    else
        local mode = vim.fn.mode()
        if mode == "v" or mode == "V" or mode == "\22" then
            vim.cmd("normal! \27") -- exit visual to set '< '> marks
            loc.start_line = vim.fn.line("'<")
            loc.end_line = vim.fn.line("'>")
        end
    end

    M.send(loc, opts)
end

return M
