--- @-mention expansion and insertion.

local M = {}

local Notify = require("pi.notify")
local Decorators = require("pi.ui.chat.decorators")

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
---@param text string
---@return string
function M.expand(text)
    local result = text:gsub("@(%S+)", function(ref)
        local clean, trailing = M.strip_trailing(ref)
        local path, range = clean:match("^(.-)#L(%d+%-?%d*)$")
        if not path then
            path = clean
        end
        local abs = vim.fn.fnamemodify(path, ":p")
        if vim.fn.isdirectory(abs) == 1 then
            return "[directory: " .. path .. "]" .. trailing
        end
        if vim.fn.filereadable(abs) ~= 1 then
            return nil
        end
        local expansion
        if range then
            local label = range:find("-") and "lines" or "line"
            expansion = "[file: " .. path .. ", " .. label .. ": " .. range .. "]"
        else
            expansion = "[file: " .. path .. "]"
        end
        return expansion .. trailing
    end)
    return result
end

---@param loc { path: string, start_line?: integer, end_line?: integer, note?: string }
---@param opts? { focus?: boolean, append?: boolean, newline?: boolean } default: focus = true
function M.send(loc, opts)
    opts = opts or {}
    local rel = vim.fn.fnamemodify(loc.path, ":.")
    local mention = "@" .. rel
    if loc.start_line and loc.end_line and loc.start_line ~= loc.end_line then
        mention = mention .. "#L" .. loc.start_line .. "-" .. loc.end_line
    elseif loc.start_line then
        mention = mention .. "#L" .. loc.start_line
    end
    if loc.note and loc.note:match("%S") then
        mention = mention .. ' - ' .. loc.note
    end

    local session = require("pi.sessions.manager").get_or_create()
    if not session then
        return
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
        if opts.append then
            row = vim.api.nvim_buf_line_count(buf)
            local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
            col = #text
        elseif win and vim.api.nvim_win_is_valid(win) then
            row, col = unpack(vim.api.nvim_win_get_cursor(win))
        else
            row = vim.api.nvim_buf_line_count(buf)
            local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
            col = #text
        end

        if opts.newline then
            if opts.append then
                -- Append as a new line at end of buffer
                vim.api.nvim_buf_set_lines(buf, -1, -1, false, { mention })
                if win and vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), #mention })
                end
            else
                -- Insert at cursor, push remaining text to next line
                local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
                local left = line:sub(1, col)
                local right = line:sub(col + 1)
                local space = (left ~= "" and left:sub(-1) ~= " ") and " " or ""
                vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { left .. space .. mention, right })
                if win and vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
                end
            end
        else
            -- Insert mention inline at computed position
            local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
            local before_char = col > 0 and line:sub(col, col) or ""
            local after_char = col < #line and line:sub(col + 1, col + 1) or ""

            -- In append mode only add leading space gap; in cursor mode add smart spacing on both sides
            local prefix = (before_char ~= "" and before_char ~= " ") and " " or ""
            local suffix = (not opts.append and after_char ~= " ") and " " or ""

            local insert = prefix .. mention .. suffix
            vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { insert })
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_set_cursor(win, { row, col + #insert })
            end
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
