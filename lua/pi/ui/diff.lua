--- Pre-execution diff review for edit/write tools.
--- Shows a diff before the tool executes; user accepts, modifies->accepts, or rejects.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")
local Highlights = require("pi.ui.highlights")

---@param path string
---@return string[]
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    return vim.split(content, "\n", { plain = true })
end

---@param path string
---@param lines string[]
---@return boolean
local function write_file(path, lines)
    local dir = vim.fn.fnamemodify(path, ":h")
    vim.fn.mkdir(dir, "p")
    local f = io.open(path, "w")
    if not f then
        Notify.error("Failed to write: " .. path)
        return false
    end
    f:write(table.concat(lines, "\n"))
    f:close()
    return true
end

---@param path string
---@return string
local function get_filetype(path)
    return vim.filetype.match({ filename = path }) or ""
end

---@param abs_path string
local function reload_buf_for_file(abs_path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            if vim.api.nvim_buf_get_name(b) == abs_path then
                vim.api.nvim_buf_call(b, function()
                    vim.cmd("edit!")
                end)
            end
        end
    end
end

---@param name string
local function wipe_stale_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end
end

---@param path string?
---@return string?
local function abs(path)
    if not path then
        return nil
    end
    if vim.startswith(path, "/") then
        return path
    end
    return vim.fn.getcwd() .. "/" .. path
end

-- AI models cannot reliably reproduce Unicode characters outside the basic
-- multilingual plane — in particular Nerd Font icons in the private-use
-- area (U+E000–U+F8FF). When the model reads a file it *sees* the icon,
-- but when it writes the oldText parameter of an Edit tool call the
-- multi-byte sequence (e.g. ef 81 97 for U+F057) is silently dropped or
-- replaced by a plain ASCII space. The oldText then has different bytes
-- than the file content and string.find fails.
--
-- Workaround: when exact byte match fails, fallback to a line-by-line
-- comparison that strips non-ASCII bytes (the "ASCII fingerprint").
-- Unchanged lines in the replacement are copied from the original content
-- so their multi-byte characters are preserved in the result.

--- Keep only printable ASCII — used to compare lines while ignoring
--- multi-byte encoding differences introduced by the AI model.
---@param s string
---@return string
local function ascii_fingerprint(s)
    return (s:gsub("[^\x20-\x7e]", ""))
end

--- Find the 1-based line index where `old_lines` match inside
--- `content_lines` using ASCII fingerprints.
---@param content_lines string[]
---@param old_lines string[]
---@return integer?
local function find_lines_fuzzy(content_lines, old_lines)
    for i = 1, #content_lines - #old_lines + 1 do
        local ok = true
        for j = 1, #old_lines do
            if ascii_fingerprint(content_lines[i + j - 1]) ~= ascii_fingerprint(old_lines[j]) then
                ok = false
                break
            end
        end
        if ok then
            return i
        end
    end
    return nil
end

--- Apply an edit to lines in memory.
---@param lines string[]
---@param old_str string
---@param new_str string
---@return string[]
local function apply_edit(lines, old_str, new_str)
    -- Fast path: exact byte match.
    local content = table.concat(lines, "\n")
    local start, finish = content:find(old_str, 1, true)
    if start then
        local result = content:sub(1, start - 1) .. new_str .. content:sub(finish + 1)
        return vim.split(result, "\n", { plain = true })
    end

    -- Slow path: line-by-line ASCII-fingerprint match (see comment above).
    local old_lines = vim.split(old_str, "\n", { plain = true })
    local new_lines = vim.split(new_str, "\n", { plain = true })
    local match_start = find_lines_fuzzy(lines, old_lines)
    if not match_start then
        Notify.error(
            "diff: The original content not found in file. The agent likely used stale content — add 'Always re-read files before editing' to your AGENTS.md"
        )
        return lines
    end

    -- Build a lookup so unchanged lines keep their original encoding.
    local orig_by_fp = {}
    for i = match_start, match_start + #old_lines - 1 do
        local fp = ascii_fingerprint(lines[i])
        if not orig_by_fp[fp] then
            orig_by_fp[fp] = lines[i]
        end
    end

    local result = {}
    for i = 1, match_start - 1 do
        result[#result + 1] = lines[i]
    end
    for _, nl in ipairs(new_lines) do
        local fp = ascii_fingerprint(nl)
        -- Preserve original bytes for lines the edit didn't change.
        result[#result + 1] = orig_by_fp[fp] or nl
    end
    for i = match_start + #old_lines, #lines do
        result[#result + 1] = lines[i]
    end
    return result
end

--- Open a diff review for a tool call.
---@param payload { prompt: string, toolName: string, toolInput: table }
---@param callback fun(result: string) Called with "Accept", json-encoded AcceptModified, or "Reject"
---@param opts? { timeout?: integer, on_timeout?: fun() }
function M.open(payload, callback, opts)
    opts = opts or {}
    local input = payload.toolInput
    local path = abs(input.path)
    if not path then
        callback("Reject")
        return
    end

    -- Prefer buffer content over disk — the tool already matched against the
    -- buffer, so reading from disk can fail on multi-byte characters.
    local before_lines
    local bufnr = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path then
            bufnr = b
            break
        end
    end
    if bufnr then
        before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        -- nvim_buf_get_lines strips trailing-newline info that read_file
        -- preserves as a trailing "".  Re-add it so apply_edit and
        -- write_file round-trip the file's eol state correctly.
        if vim.bo[bufnr].eol then
            table.insert(before_lines, "")
        end
    else
        before_lines = read_file(path)
    end
    local proposed_lines

    if payload.toolName == "edit" then
        local old_str = input.oldText or ""
        local new_str = input.newText or ""
        proposed_lines = apply_edit(before_lines, old_str, new_str)
    elseif payload.toolName == "write" then
        local content = input.content or ""
        proposed_lines = vim.split(content, "\n", { plain = true })
    else
        Notify.error("diff: unexpected tool: " .. tostring(payload.toolName))
        callback("Reject")
        return
    end

    -- Strip the trailing empty-string EOL marker that vim.split / read_file
    -- produce for files ending with "\n".  Neovim represents this via the
    -- buffer `eol` option rather than a visible line, so keeping it would
    -- show a phantom empty-line diff against the left side (which is opened
    -- with :edit and handles EOL natively).
    local proposed_eol = #proposed_lines > 0 and proposed_lines[#proposed_lines] == ""
    if proposed_eol then
        table.remove(proposed_lines)
    end

    local ft = get_filetype(path)
    local rel_path = vim.fn.fnamemodify(path, ":~:.")
    local after_name = "pi://review" .. path

    local prev_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local review_tab = vim.api.nvim_get_current_tabpage()

    -- Left: open the real original file
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local before_buf = vim.api.nvim_win_get_buf(left_win)
    local prev_modifiable = vim.bo[before_buf].modifiable
    local prev_readonly = vim.bo[before_buf].readonly
    vim.bo[before_buf].modifiable = false
    vim.bo[before_buf].readonly = true

    -- Right: proposed changes (editable)
    wipe_stale_buf(after_name)
    local after_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(after_buf, 0, -1, false, proposed_lines)
    vim.bo[after_buf].eol = proposed_eol
    vim.bo[after_buf].buftype = "acwrite"
    vim.api.nvim_buf_set_name(after_buf, after_name)
    vim.cmd("vsplit")
    local right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right_win, after_buf)
    if ft ~= "" then
        vim.bo[after_buf].filetype = ft
    end

    -- Reset window options that may be inherited from π windows.
    for _, w in ipairs({ left_win, right_win }) do
        vim.wo[w].number = true
        vim.wo[w].relativenumber = vim.go.relativenumber
        vim.wo[w].signcolumn = vim.go.signcolumn
        vim.wo[w].conceallevel = 0
        vim.wo[w].concealcursor = ""
        vim.wo[w].wrap = vim.go.wrap
        vim.wo[w].linebreak = vim.go.linebreak
        vim.wo[w].list = vim.go.list
        vim.wo[w].cursorline = vim.go.cursorline
        vim.wo[w].winfixbuf = false
        vim.wo[w].foldenable = true
        vim.wo[w].winhighlight = Highlights.DIFF_WINHIGHLIGHT
    end
    vim.cmd("wincmd =")

    -- Defer diffthis until async handlers have settled
    vim.defer_fn(function()
        if not vim.api.nvim_tabpage_is_valid(review_tab) then
            return
        end
        for _, win in ipairs({ right_win, left_win }) do -- should go right then left
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_call(win, function()
                    vim.cmd("diffthis")
                end)
            end
        end
        pcall(vim.api.nvim_win_call, left_win, function()
            vim.cmd("normal! gg]c")
        end)
        vim.api.nvim_set_current_win(right_win)
        vim.cmd("stopinsert")
    end, 50)

    local keymaps = Config.options.keymaps
    local accept_key = keymaps.diff_accept
    local reject_key = keymaps.diff_reject
    local accept_lhs = type(accept_key) == "table" and accept_key[1] or accept_key --[[@as string]]
    local reject_lhs = type(reject_key) == "table" and reject_key[1] or reject_key --[[@as string]]
    vim.wo[left_win].winbar = "%#PiDiffWinbar# %#PiDiffWinbarCurrent#CURRENT: " .. rel_path .. "%#PiDiffWinbar#"
    vim.wo[right_win].winbar = "%#PiDiffWinbar# %#PiDiffWinbarProposed# PROPOSED: "
        .. rel_path
        .. " %#PiDiffWinbar# %#PiDiffWinbarHint#["
        .. accept_lhs
        .. "=accept  "
        .. reject_lhs
        .. "=reject]%#PiDiffWinbar#"

    local responded = false
    local timeout = nil ---@type integer?

    local function close_review_tab()
        if timeout then
            pcall(vim.fn.timer_stop, timeout)
        end
        -- Clear winbar and diffoff on both windows to restore original state
        for _, w in ipairs({ left_win, right_win }) do
            if vim.api.nvim_win_is_valid(w) then
                vim.wo[w].winbar = ""
                vim.api.nvim_win_call(w, function()
                    vim.cmd("diffoff")
                end)
            end
        end
        -- Restore the real file buffer's original state
        if vim.api.nvim_buf_is_valid(before_buf) then
            vim.bo[before_buf].modifiable = prev_modifiable
            vim.bo[before_buf].readonly = prev_readonly
        end
        if review_tab and vim.api.nvim_tabpage_is_valid(review_tab) then
            vim.api.nvim_set_current_tabpage(review_tab)
            vim.cmd("tabclose")
        end
        -- Wipe the scratch review buffer
        if vim.api.nvim_buf_is_valid(after_buf) then
            vim.api.nvim_buf_delete(after_buf, { force = true })
        end
        if vim.api.nvim_tabpage_is_valid(prev_tab) then
            vim.api.nvim_set_current_tabpage(prev_tab)
        end
        local session = require("pi.sessions.manager").get()
        if session then
            session.chat:ensure_shown_and_focus_prompt()
        end
    end

    local function accept()
        if responded then
            return
        end
        responded = true

        local final_lines = vim.api.nvim_buf_get_lines(after_buf, 0, -1, false)

        -- Check if user modified the proposed content (before EOL fixup).
        local modified = #final_lines ~= #proposed_lines
        if not modified then
            for i, line in ipairs(final_lines) do
                if line ~= proposed_lines[i] then
                    modified = true
                    break
                end
            end
        end

        -- Restore EOL marker so write_file round-trips the trailing newline.
        if vim.bo[after_buf].eol then
            final_lines[#final_lines + 1] = ""
        end

        write_file(path, final_lines)
        require("pi.cache.files").invalidate()
        reload_buf_for_file(vim.fn.fnamemodify(path, ":p"))
        close_review_tab()

        if modified then
            callback(vim.json.encode({
                result = "AcceptModified",
                content = table.concat(final_lines, "\n"),
            }))
        else
            -- Send structured JSON so the extension knows the plugin already
            -- applied the change (and should block the tool). The TUI sends
            -- plain "Accept" — the extension lets the tool run in that case.
            callback(vim.json.encode({ result = "Accepted" }))
        end
    end

    local function reject()
        if responded then
            return
        end
        responded = true
        close_review_tab()
        callback("Reject")
    end

    if type(opts.timeout) == "number" and opts.timeout > 0 then
        timeout = vim.fn.timer_start(opts.timeout, function()
            vim.schedule(function()
                if responded then
                    return
                end
                responded = true
                close_review_tab()
                if opts.on_timeout then
                    opts.on_timeout()
                end
            end)
        end)
    end

    for _, b in ipairs({ before_buf, after_buf }) do
        local accept_modes = type(accept_key) == "table" and accept_key.modes or "n"
        local reject_modes = type(reject_key) == "table" and reject_key.modes or "n"
        vim.keymap.set(accept_modes, accept_lhs, accept, { buffer = b, desc = "Accept edit" })
        vim.keymap.set(reject_modes, reject_lhs, reject, { buffer = b, desc = "Reject edit" })
    end

    -- :w on the proposed buffer accepts the diff
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = after_buf,
        callback = function()
            accept()
        end,
    })
end

return M
