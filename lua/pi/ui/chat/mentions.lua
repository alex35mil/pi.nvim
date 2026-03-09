--- @ mention handling: highlighting, expansion, and insertion.

local M = {}

local Files = require("pi.files")
local Notify = require("pi.notify")

local ns = vim.api.nvim_create_namespace("pi-mentions")

--- Parse mention ref, stripping optional #L range suffix.
---@param ref string
---@return string path
local function parse_path(ref)
    local path = ref:match("^(.-)#L%d+%-?%d*$")
    return path or ref
end

--- Update mention extmarks for a buffer.
---@param buf integer
function M.update(buf)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for row, line in ipairs(lines) do
        local col = 1
        while col <= #line do
            local start, finish, ref = line:find("@(%S+)", col)
            if not start then
                break
            end
            -- Strip trailing punctuation for path resolution
            local clean = ref:gsub("[%.,;:!%?]+$", "")
            finish = start + #clean -- adjust end to exclude punctuation
            local path = parse_path(clean)
            if Files.exists(path) then
                vim.api.nvim_buf_set_extmark(buf, ns, row - 1, start - 1, {
                    end_col = finish,
                    hl_group = "PiMention",
                })
            end
            col = finish + 1
        end
    end
end

--- Attach mention highlighting to a pi prompt buffer.
---@param buf integer
function M.attach(buf)
    local timer = assert(vim.uv.new_timer())
    local DEBOUNCE_MS = 150

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = buf,
        callback = function()
            timer:stop()
            timer:start(
                DEBOUNCE_MS,
                0,
                vim.schedule_wrap(function()
                    if vim.api.nvim_buf_is_valid(buf) then
                        M.update(buf)
                    end
                end)
            )
        end,
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            timer:stop()
            timer:close()
        end,
    })
end

--- Expand @-mentions into context hints the agent understands.
--- `@path/to/file` → `[file: path/to/file]`
--- `@path/to/file#L10` → `[file: path/to/file, line: 10]`
--- `@path/to/file#L10-20` → `[file: path/to/file, lines: 10-20]`
--- No file content is inlined — the agent has Read tool.
---@param text string
---@return string
function M.expand(text)
    local result = text:gsub("@(%S+)", function(ref)
        -- Strip trailing punctuation that's not part of the path
        local trailing = ""
        local clean = ref:gsub("([%.,;:!%?]+)$", function(m)
            trailing = m
            return ""
        end)
        local path, range = clean:match("^(.-)#L(%d+%-?%d*)$")
        if not path then
            path = clean
        end
        local abs = vim.fn.fnamemodify(path, ":p")
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

--- Insert an @-mention at the cursor in the pi prompt buffer.
---@param loc { path: string, start_line?: integer, end_line?: integer }
---@param opts? { focus?: boolean } default: focus = true
function M.send(loc, opts)
    opts = opts or {}
    local rel = vim.fn.fnamemodify(loc.path, ":.")
    local mention = "@" .. rel
    if loc.start_line and loc.end_line and loc.start_line ~= loc.end_line then
        mention = mention .. "#L" .. loc.start_line .. "-" .. loc.end_line
    elseif loc.start_line then
        mention = mention .. "#L" .. loc.start_line
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

        M.update(buf)
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
