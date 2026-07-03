--- Pre-execution diff review for edit/write tools.
--- Shows a diff before the tool executes; user accepts, modifies->accepts, or rejects.

local M = {}

local Config = require("pi.config")
local Dialog = require("pi.ui.dialog")
local Keys = require("pi.keys")
local Notify = require("pi.notify")
local Highlights = require("pi.ui.highlights")

local DEFAULT_DIFF_CONTEXT = 6
local note_ns = vim.api.nvim_create_namespace("pi-diff-review-notes")

---@return string[]
local function diffopt_items()
    return vim.split(vim.go.diffopt, ",", { plain = true, trimempty = true })
end

---@return integer
local function diff_context()
    for _, item in ipairs(diffopt_items()) do
        local value = item:match("^context:(%d+)$")
        if value then
            return tonumber(value) or DEFAULT_DIFF_CONTEXT
        end
    end
    return DEFAULT_DIFF_CONTEXT
end

---@param context integer
local function set_diff_context(context)
    context = math.max(0, context)

    local items = {}
    for _, item in ipairs(diffopt_items()) do
        if not item:match("^context:%d+$") then
            items[#items + 1] = item
        end
    end
    items[#items + 1] = "context:" .. context
    vim.go.diffopt = table.concat(items, ",")
end

---@param left_win integer
---@param right_win integer
local function refresh_diff_windows(left_win, right_win)
    for _, win in ipairs({ left_win, right_win }) do
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_call(win, function()
                vim.cmd("diffupdate")
            end)
        end
    end
end

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

--- Apply multiple edits against the original content.
--- All matches are resolved against the original string, not incrementally.
---@param lines string[]
---@param edits table[]
---@return string[]?
local function apply_edits(lines, edits)
    local content = table.concat(lines, "\n")
    local replacements = {}

    for _, edit in ipairs(edits) do
        local old_str = edit.oldText or ""
        local new_str = edit.newText or ""

        if old_str == "" then
            Notify.error("diff: Empty oldText is not supported in multi-edit review")
            return nil
        end

        local search_from = 1
        local start_pos, end_pos = nil, nil

        while true do
            local s, e = content:find(old_str, search_from, true)
            if not s then
                break
            end

            local overlaps = false
            for _, existing in ipairs(replacements) do
                if not (e < existing.start_pos or s > existing.end_pos) then
                    overlaps = true
                    break
                end
            end

            if not overlaps then
                start_pos, end_pos = s, e
                break
            end

            search_from = s + 1
        end

        if not start_pos then
            Notify.error(
                "diff: The original content not found in file. The agent likely used stale content — add 'Always re-read files before editing' to your AGENTS.md"
            )
            return nil
        end

        replacements[#replacements + 1] = {
            start_pos = start_pos,
            end_pos = end_pos,
            new_str = new_str,
        }
    end

    table.sort(replacements, function(a, b)
        return a.start_pos < b.start_pos
    end)

    for i = 2, #replacements do
        local prev = replacements[i - 1]
        local curr = replacements[i]
        if curr.start_pos <= prev.end_pos then
            Notify.error("diff: Overlapping edits are not supported")
            return nil
        end
    end

    local parts = {}
    local last_pos = 1

    for _, replacement in ipairs(replacements) do
        parts[#parts + 1] = content:sub(last_pos, replacement.start_pos - 1)
        parts[#parts + 1] = replacement.new_str
        last_pos = replacement.end_pos + 1
    end

    parts[#parts + 1] = content:sub(last_pos)

    local result = table.concat(parts)
    return vim.split(result, "\n", { plain = true })
end

---@class pi.DiffReviewNote
---@field buf integer
---@field mark_ids integer[]
---@field side "current"|"proposed"
---@field start_row integer 0-indexed inclusive
---@field end_row integer 0-indexed inclusive
---@field note string
---@field seq integer

local NOTE_TEXT_PREFIX = "  │ "
local NOTE_SEPARATOR_PREFIX = "  "
local NOTE_SEPARATOR_CHAR = "─"

---@param value integer
---@param min integer
---@param max integer
---@return integer
local function clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

---@param note string
---@return string
local function note_preview(note)
    local first = vim.split(note, "\n", { plain = true })[1] or ""
    if vim.fn.strdisplaywidth(first) > 80 then
        return vim.fn.strcharpart(first, 0, 77) .. "…"
    end
    return first
end

---@param text string
---@param width integer
---@return string[]
local function wrap_note_line(text, width)
    width = math.max(1, width)
    if text == "" then
        return { "" }
    end

    local lines = {}
    local rest = text
    while rest ~= "" do
        local chunk = vim.fn.strcharpart(rest, 0, width)
        if chunk == "" then
            break
        end
        lines[#lines + 1] = chunk
        rest = vim.fn.strcharpart(rest, vim.fn.strchars(chunk))
    end
    return lines
end

---@param width integer
---@return pi.CustomBlockLine
local function note_separator_virt_line(width)
    local sep_width = math.max(1, width - vim.fn.strdisplaywidth(NOTE_SEPARATOR_PREFIX))
    return { { NOTE_SEPARATOR_PREFIX .. string.rep(NOTE_SEPARATOR_CHAR, sep_width), "PiDiffReviewNote" } }
end

---@param note string
---@param width integer
---@param separator_before boolean
---@return pi.CustomBlockLine[]
local function note_virt_lines(note, width, separator_before)
    local lines = {}
    local text_width = math.max(1, width - vim.fn.strdisplaywidth(NOTE_TEXT_PREFIX))
    if separator_before then
        lines[#lines + 1] = note_separator_virt_line(width)
    end
    for _, line in ipairs(vim.split(note, "\n", { plain = true })) do
        for _, wrapped in ipairs(wrap_note_line(line, text_width)) do
            lines[#lines + 1] = { { NOTE_TEXT_PREFIX .. wrapped, "PiDiffReviewNote" } }
        end
    end
    return lines
end

---@param buf integer
---@param row integer
---@param virt_lines pi.CustomBlockLine[]
---@param priority integer
---@return integer
local function set_note_group_text_mark(buf, row, virt_lines, priority)
    return vim.api.nvim_buf_set_extmark(buf, note_ns, row, 0, {
        virt_lines = virt_lines,
        priority = priority,
    })
end

---@param buf integer
---@param row integer
---@param text string
---@param priority integer
---@return integer
local function set_note_sign_mark(buf, row, text, priority)
    return vim.api.nvim_buf_set_extmark(buf, note_ns, row, 0, {
        sign_text = text,
        sign_hl_group = "PiDiffReviewNote",
        priority = priority,
    })
end

--- Open a diff review for a tool call.
---@param payload { prompt: string, toolName: string, toolInput: table }
---@param callback fun(result: string) Called with json-encoded review result, or "Reject" for no-note rejection/backcompat
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
        if type(input.edits) == "table" and #input.edits > 0 then
            proposed_lines = apply_edits(before_lines, input.edits)
            if not proposed_lines then
                callback("Reject")
                return
            end
        else
            Notify.error("diff: edit tool input missing edits[]")
            callback("Reject")
            return
        end
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

    local rel_path = vim.fn.fnamemodify(path, ":~:.")
    local after_name = "pi://review" .. path
    local prev_diffopt = vim.go.diffopt
    local diff_context_config = Config.options.diff.context
    local initial_context = diff_context_config.base or diff_context()
    local context_step = math.max(1, diff_context_config.step or 5)
    local notes = {} ---@type pi.DiffReviewNote[]

    set_diff_context(initial_context)

    local prev_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local review_tab = vim.api.nvim_get_current_tabpage()

    -- Left: open the real original file
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local before_buf = vim.api.nvim_win_get_buf(left_win)
    local ft = vim.bo[before_buf].filetype
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

    local is_markdown = ft == "markdown"

    local function apply_wrap_options()
        for _, w in ipairs({ left_win, right_win }) do
            if vim.api.nvim_win_is_valid(w) then
                vim.wo[w].wrap = is_markdown or vim.go.wrap
                vim.wo[w].linebreak = is_markdown or vim.go.linebreak
            end
        end
    end

    -- Reset window options that may be inherited from the chat window.
    for _, w in ipairs({ left_win, right_win }) do
        vim.wo[w].number = true
        vim.wo[w].relativenumber = vim.go.relativenumber
        vim.wo[w].signcolumn = vim.go.signcolumn
        vim.wo[w].conceallevel = 0
        vim.wo[w].concealcursor = ""
        vim.wo[w].wrap = is_markdown or vim.go.wrap
        vim.wo[w].linebreak = is_markdown or vim.go.linebreak
        vim.wo[w].list = vim.go.list
        vim.wo[w].cursorline = vim.go.cursorline
        vim.wo[w].winfixbuf = false
        vim.wo[w].winhighlight = Highlights.DIFF_WINHIGHLIGHT
    end
    vim.cmd("wincmd =")

    ---@return integer?
    local function first_valid_review_win()
        for _, win in ipairs({ right_win, left_win }) do
            if vim.api.nvim_win_is_valid(win) then
                return win
            end
        end
        return nil
    end

    -- Enable diff: focus each pane and run diffthis synchronously.
    vim.api.nvim_set_current_win(left_win)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(right_win)
    vim.cmd("diffthis")
    apply_wrap_options()

    -- Post-render fixup: re-run diffthis on the left pane after
    -- Neovim has rendered at least once, then jump to the first
    -- change and sync viewports.
    vim.defer_fn(function()
        if not vim.api.nvim_tabpage_is_valid(review_tab) then
            return
        end
        if vim.api.nvim_win_is_valid(left_win) then
            vim.api.nvim_set_current_win(left_win)
            vim.cmd("diffthis")
        end
        if vim.api.nvim_win_is_valid(right_win) then
            vim.api.nvim_set_current_win(right_win)
            pcall(function()
                vim.cmd("normal! gg]c")
            end)
            vim.cmd("syncbind")
        end
        apply_wrap_options()
    end, 200)

    local diff_keys = Config.options.diff.keys
    local accept_keys = Keys.resolve(diff_keys.accept)
    local reject_keys = Keys.resolve(diff_keys.reject)
    local edit_note_keys = Keys.resolve(diff_keys.edit_note)
    local delete_note_keys = Keys.resolve(diff_keys.delete_note)
    local list_notes_keys = Keys.resolve(diff_keys.list_notes)
    local expand_context_keys = Keys.resolve(diff_keys.expand_context)
    local shrink_context_keys = Keys.resolve(diff_keys.shrink_context)
    local actions = {
        { label = "Accept", hint = "accept", keys = accept_keys },
        { label = "Reject", hint = "reject", keys = reject_keys },
        { label = "Add/edit note", hint = "note", keys = edit_note_keys },
        { label = "Delete note", hint = "del-note", keys = delete_note_keys },
        { label = "List notes", hint = "notes", keys = list_notes_keys },
        { label = "Expand context", hint = "expand", keys = expand_context_keys },
        { label = "Shrink context", hint = "shrink", keys = shrink_context_keys },
    }

    local function lhs_values(keys)
        local values = {}
        for _, key in ipairs(keys) do
            values[#values + 1] = Keys.lhs(key)
        end
        return values
    end

    local function lhs_collides(lhs)
        if lhs == "" then
            return false
        end
        local normalized = Keys.normalize_lhs(lhs)
        for _, action in ipairs(actions) do
            for _, action_lhs in ipairs(lhs_values(action.keys)) do
                if Keys.normalize_lhs(action_lhs) == normalized then
                    return true
                end
            end
        end
        return false
    end

    local function resolve_keymap_hints()
        local value = Config.options.diff.keymap_hints
        if value == nil then
            value = "dialog"
        end
        if value == false then
            return { mode = "none" }
        end
        if value == "winbar" then
            return { mode = "winbar" }
        end
        if value == true or value == "dialog" then
            return { mode = "dialog", key = "?" }
        end
        Notify.warn("diff: unsupported diff.keymap_hints; falling back to dialog")
        return { mode = "dialog", key = "?" }
    end

    local hint_config = resolve_keymap_hints()
    local help_key = hint_config.mode == "dialog" and hint_config.key or nil
    local help_lhs = help_key and Keys.lhs(help_key) or ""
    local help_collides = help_lhs ~= "" and lhs_collides(help_lhs)

    vim.wo[left_win].winbar = "%#PiDiffWinbar# %#PiDiffWinbarCurrent#CURRENT: " .. rel_path .. "%#PiDiffWinbar#"
    local proposed_winbar = "%#PiDiffWinbar# %#PiDiffWinbarProposed# PROPOSED: " .. rel_path
    if hint_config.mode == "winbar" then
        proposed_winbar = proposed_winbar .. " %#PiDiffWinbar# %#PiDiffWinbarHint#["
        for i, action in ipairs(actions) do
            local first_lhs = action.keys[1] and Keys.lhs(action.keys[1]) or ""
            if i > 1 then
                proposed_winbar = proposed_winbar .. "  "
            end
            proposed_winbar = proposed_winbar .. first_lhs .. "=" .. action.hint
        end
        proposed_winbar = proposed_winbar .. "]%#PiDiffWinbar#"
    elseif hint_config.mode == "dialog" and not help_collides then
        proposed_winbar = proposed_winbar
            .. " %#PiDiffWinbar# %#PiDiffWinbarHint#["
            .. help_lhs
            .. "=keymaps]%#PiDiffWinbar#"
    end
    vim.wo[right_win].winbar = proposed_winbar

    local function show_keymap_dialog()
        local lines = {}
        for _, action in ipairs(actions) do
            local values = lhs_values(action.keys)
            local keys_text = #values > 0 and table.concat(values, ", ") or "(unbound)"
            lines[#lines + 1] = action.label .. ": " .. keys_text
        end
        Dialog.info({ title = "Diff review keymaps", lines = lines })
    end

    local responded = false
    local cleaned_up = false
    local timeout = nil ---@type integer?
    local tracked_keymaps = {} ---@type table<string, { buf: integer, mode: string, lhs: string, original: table|false }>

    ---@param buf integer
    ---@param mode string
    ---@param lhs string
    ---@return string
    local function keymap_id(buf, mode, lhs)
        return tostring(buf) .. ":" .. mode .. ":" .. Keys.normalize_lhs(lhs)
    end

    ---@param buf integer
    ---@param mode string
    ---@param lhs string
    ---@return table|false
    local function current_buf_keymap(buf, mode, lhs)
        local ok, existing = pcall(vim.api.nvim_buf_call, buf, function()
            return vim.fn.maparg(lhs, mode, false, true)
        end)
        if ok and existing and existing.buffer == 1 then
            return existing
        end
        return false
    end

    ---@param buf integer
    ---@param key pi.KeySpec
    ---@param handler function
    ---@param opts? { modes?: string|string[], desc?: string, nowait?: boolean }
    local function bind_review_key(buf, key, handler, opts)
        opts = opts or {}
        local lhs = Keys.lhs(key)
        local modes = Keys.modes(key, opts.modes or "n")
        for _, mode in ipairs(modes) do
            local id = keymap_id(buf, mode, lhs)
            if tracked_keymaps[id] == nil then
                tracked_keymaps[id] = {
                    buf = buf,
                    mode = mode,
                    lhs = lhs,
                    original = vim.api.nvim_buf_is_valid(buf) and current_buf_keymap(buf, mode, lhs) or false,
                }
            end
        end
        Keys.bind(buf, key, handler, opts)
    end

    local function update_context(delta)
        local next_context = math.max(initial_context, diff_context() + delta)
        set_diff_context(next_context)
        refresh_diff_windows(left_win, right_win)
    end

    local note_refresh_group =
        vim.api.nvim_create_augroup("pi-diff-review-notes-" .. tostring(after_buf), { clear = true })
    local on_key_ns = vim.api.nvim_create_namespace("pi-diff-review-keys-" .. tostring(after_buf))
    local pending_line_key = nil ---@type { buf: integer, key: string, row: integer }?
    local next_note_seq = 0

    ---@param buf integer
    ---@return "current"|"proposed"?
    local function note_side(buf)
        if buf == before_buf then
            return "current"
        elseif buf == after_buf then
            return "proposed"
        end
        return nil
    end

    ---@param entry pi.DiffReviewNote
    ---@return integer
    local function note_start(entry)
        return entry.start_row
    end

    ---@param entry pi.DiffReviewNote
    ---@return integer
    local function note_end(entry)
        return entry.end_row
    end

    ---@param entry pi.DiffReviewNote
    ---@return integer?
    local function note_win(entry)
        if entry.buf == before_buf then
            return left_win
        elseif entry.buf == after_buf then
            return right_win
        end
        return nil
    end

    ---@param entry pi.DiffReviewNote
    ---@return integer
    local function note_width(entry)
        local win = note_win(entry)
        if win and vim.api.nvim_win_is_valid(win) then
            return math.max(20, vim.api.nvim_win_get_width(win) - 8)
        end
        return 80
    end

    ---@param entry pi.DiffReviewNote
    local function clear_note_marks(entry)
        if not vim.api.nvim_buf_is_valid(entry.buf) then
            entry.mark_ids = {}
            return
        end
        for _, mark_id in ipairs(entry.mark_ids or {}) do
            pcall(vim.api.nvim_buf_del_extmark, entry.buf, note_ns, mark_id)
        end
        entry.mark_ids = {}
    end

    ---@param entry pi.DiffReviewNote
    local function delete_note(entry)
        clear_note_marks(entry)
        for i, existing in ipairs(notes) do
            if existing == entry then
                table.remove(notes, i)
                break
            end
        end
    end

    local function refresh_all_notes()
        for i = #notes, 1, -1 do
            local entry = notes[i]
            clear_note_marks(entry)
            if not vim.api.nvim_buf_is_valid(entry.buf) then
                table.remove(notes, i)
            else
                local line_count = vim.api.nvim_buf_line_count(entry.buf)
                if line_count <= 0 then
                    table.remove(notes, i)
                else
                    entry.start_row = clamp(entry.start_row, 0, line_count - 1)
                    entry.end_row = clamp(entry.end_row, entry.start_row, line_count - 1)
                    if not entry.seq then
                        next_note_seq = next_note_seq + 1
                        entry.seq = next_note_seq
                    end
                end
            end
        end

        table.sort(notes, function(a, b)
            if a.buf == b.buf then
                if a.end_row == b.end_row then
                    if a.start_row == b.start_row then
                        return a.seq < b.seq
                    end
                    return a.start_row < b.start_row
                end
                return a.end_row < b.end_row
            end
            return a.buf < b.buf
        end)

        local i = 1
        while i <= #notes do
            local first = notes[i]
            local group = {}
            local j = i
            while j <= #notes and notes[j].buf == first.buf and notes[j].end_row == first.end_row do
                group[#group + 1] = notes[j]
                j = j + 1
            end

            table.sort(group, function(a, b)
                if a.start_row == b.start_row then
                    return a.seq < b.seq
                end
                return a.start_row > b.start_row
            end)

            local width = note_width(first)
            local virt_lines = {}
            for group_index, entry in ipairs(group) do
                if group_index > 1 then
                    virt_lines[#virt_lines + 1] = note_separator_virt_line(width)
                end
                for _, line in ipairs(note_virt_lines(entry.note, width, false)) do
                    virt_lines[#virt_lines + 1] = line
                end
            end
            first.mark_ids[#first.mark_ids + 1] = set_note_group_text_mark(first.buf, first.end_row, virt_lines, 200)

            local icon = Config.options.diff.icons.note
            if icon then
                for note_index, entry in ipairs(group) do
                    local priority = 200 + note_index
                    entry.mark_ids[#entry.mark_ids + 1] = set_note_sign_mark(entry.buf, entry.start_row, icon, priority)
                    for row = entry.start_row + 1, entry.end_row do
                        entry.mark_ids[#entry.mark_ids + 1] = set_note_sign_mark(entry.buf, row, "·", priority)
                    end
                end
            end

            i = j
        end
    end

    ---@param entry pi.DiffReviewNote
    ---@return string
    local function note_range_label(entry)
        local start_line = note_start(entry) + 1
        local end_line = note_end(entry) + 1
        if start_line == end_line then
            return tostring(start_line)
        end
        return tostring(start_line) .. "-" .. tostring(end_line)
    end

    ---@param buf integer
    ---@param row integer
    ---@return pi.DiffReviewNote[]
    local function find_notes_at(buf, row)
        local found = {}
        for _, entry in ipairs(notes) do
            if entry.buf == buf and row >= note_start(entry) and row <= note_end(entry) then
                found[#found + 1] = entry
            end
        end
        return found
    end

    ---@param win integer
    ---@param buf integer
    ---@param forced_start? integer
    ---@param forced_end? integer
    ---@return integer, integer, boolean
    local function selected_range(win, buf, forced_start, forced_end)
        if vim.api.nvim_win_get_buf(win) ~= buf then
            local row = vim.api.nvim_win_get_cursor(win)[1] - 1
            return row, row, false
        end

        if forced_start and forced_end then
            local line_count = vim.api.nvim_buf_line_count(buf)
            return clamp(math.min(forced_start, forced_end), 0, line_count - 1),
                clamp(math.max(forced_start, forced_end), 0, line_count - 1),
                true
        end

        if vim.fn.mode() ~= "V" then
            local row = vim.api.nvim_win_get_cursor(win)[1] - 1
            return row, row, false
        end

        local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
        local visual_pos = vim.fn.getpos("v")
        local visual_row = (visual_pos[2] or cursor_row + 1) - 1
        local line_count = vim.api.nvim_buf_line_count(buf)
        local start_row = clamp(math.min(cursor_row, visual_row), 0, line_count - 1)
        local end_row = clamp(math.max(cursor_row, visual_row), 0, line_count - 1)
        return start_row, end_row, true
    end

    ---@param entries pi.DiffReviewNote[]
    ---@param title string
    ---@param callback fun(entry: pi.DiffReviewNote?)
    local function choose_note(entries, title, callback)
        if #entries == 0 then
            callback(nil)
            return
        end
        if #entries == 1 then
            callback(entries[1])
            return
        end

        local options = {}
        local option_entries = {}
        for _, entry in ipairs(entries) do
            local label = tostring(#options + 1)
                .. ". "
                .. entry.side
                .. ":"
                .. note_range_label(entry)
                .. " "
                .. note_preview(entry.note)
            options[#options + 1] = label
            option_entries[label] = entry
        end
        Dialog.select({ title = title, options = options }, function(choice)
            callback(choice and option_entries[choice] or nil)
        end)
    end

    ---@param entries pi.DiffReviewNote[]
    ---@param row integer
    ---@param callback fun(entry: pi.DiffReviewNote|false?) false means create new; nil means cancelled
    local function choose_note_to_edit(entries, row, callback)
        if #entries == 0 then
            callback(false)
            return
        end
        if #entries == 1 then
            callback(entries[1])
            return
        end

        local options = { "Create new note on line " .. tostring(row + 1) }
        local option_entries = { [options[1]] = false }
        for _, entry in ipairs(entries) do
            local label = tostring(#options + 1)
                .. ". Edit "
                .. entry.side
                .. ":"
                .. note_range_label(entry)
                .. " "
                .. note_preview(entry.note)
            options[#options + 1] = label
            option_entries[label] = entry
        end
        Dialog.select({ title = "Review notes", options = options }, function(choice)
            if choice == nil then
                callback(nil)
            else
                callback(option_entries[choice])
            end
        end)
    end

    ---@param existing pi.DiffReviewNote?
    ---@param buf integer
    ---@param side "current"|"proposed"
    ---@param start_row integer
    ---@param end_row integer
    local function prompt_note(existing, buf, side, start_row, end_row)
        local range = start_row == end_row and tostring(start_row + 1)
            or (tostring(start_row + 1) .. "-" .. tostring(end_row + 1))
        local title = (existing and "Edit" or "Add") .. " review note for " .. side .. " line " .. range

        Dialog.input({
            title = title,
            default = existing and existing.note or "",
            multiline = true,
        }, function(value)
            if value == nil then
                return
            end
            value = vim.trim(value)

            if existing then
                if value == "" then
                    delete_note(existing)
                else
                    existing.note = value
                    refresh_all_notes()
                end
                return
            end

            if value == "" then
                return
            end
            next_note_seq = next_note_seq + 1
            notes[#notes + 1] = {
                buf = buf,
                mark_ids = {},
                side = side,
                start_row = start_row,
                end_row = end_row,
                note = value,
                seq = next_note_seq,
            }
            refresh_all_notes()
        end)
    end

    ---@param forced_start? integer
    ---@param forced_end? integer
    local function edit_note(forced_start, forced_end)
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        local side = note_side(buf)
        if not side then
            Notify.warn("Move cursor to the current or proposed diff pane to add a review note")
            return
        end

        local start_row, end_row, is_visual = selected_range(win, buf, forced_start, forced_end)
        if is_visual then
            prompt_note(nil, buf, side, start_row, end_row)
            return
        end

        local matches = find_notes_at(buf, start_row)
        choose_note_to_edit(matches, start_row, function(existing)
            if existing == nil then
                return
            end
            if existing == false then
                prompt_note(nil, buf, side, start_row, end_row)
            else
                prompt_note(existing, buf, side, start_row, end_row)
            end
        end)
    end

    local function delete_note_at_cursor()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        local side = note_side(buf)
        if not side then
            Notify.warn("Move cursor to the current or proposed diff pane to delete a review note")
            return
        end

        local row = vim.api.nvim_win_get_cursor(win)[1] - 1
        local matches = find_notes_at(buf, row)
        if #matches == 0 then
            Notify.warn("No review note on this line")
            return
        end
        choose_note(matches, "Choose review note to delete", function(entry)
            if entry then
                delete_note(entry)
                refresh_all_notes()
            end
        end)
    end

    local function list_notes()
        local options = {}
        local option_entries = {}
        for _, entry in ipairs(notes) do
            local label = tostring(#options + 1)
                .. ". "
                .. entry.side
                .. ":"
                .. note_range_label(entry)
                .. " "
                .. note_preview(entry.note)
            options[#options + 1] = label
            option_entries[label] = entry
        end

        if #options == 0 then
            Notify.info("No review notes")
            return
        end

        Dialog.select({ title = "Review notes", options = options }, function(choice)
            local entry = choice and option_entries[choice] or nil
            if not entry then
                return
            end
            local win = note_win(entry)
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_set_current_win(win)
                vim.api.nvim_win_set_cursor(win, { note_start(entry) + 1, 0 })
            end
        end)
    end

    ---@return table[]
    local function collect_notes()
        local collected = {}
        for _, entry in ipairs(notes) do
            if vim.api.nvim_buf_is_valid(entry.buf) then
                local start_row = note_start(entry)
                local end_row = note_end(entry)
                local lines = vim.api.nvim_buf_get_lines(entry.buf, start_row, end_row + 1, false)
                if #lines > 0 then
                    collected[#collected + 1] = {
                        path = path,
                        side = entry.side,
                        lineStart = start_row + 1,
                        lineEnd = end_row + 1,
                        lines = lines,
                        note = entry.note,
                    }
                end
            end
        end
        table.sort(collected, function(a, b)
            if a.side == b.side then
                return a.lineStart < b.lineStart
            end
            return a.side < b.side
        end)
        return collected
    end

    ---@param entry pi.DiffReviewNote
    ---@param firstline integer
    ---@param lastline integer
    ---@param new_lastline integer
    ---@return boolean delete
    local function update_note_for_lines(entry, firstline, lastline, new_lastline)
        local old_count = lastline - firstline
        local new_count = new_lastline - firstline
        local delta = new_count - old_count
        local start_row = entry.start_row
        local end_row = entry.end_row

        if old_count == 0 then
            if delta <= 0 then
                return false
            end
            local insert_at = firstline
            local key = pending_line_key
            if insert_at < start_row then
                entry.start_row = start_row + delta
                entry.end_row = end_row + delta
            elseif insert_at == start_row then
                if key and key.buf == entry.buf and key.key == "o" and key.row == start_row - 1 then
                    entry.start_row = start_row + delta
                    entry.end_row = end_row + delta
                else
                    entry.end_row = end_row + delta
                end
            elseif insert_at > start_row and insert_at <= end_row then
                entry.end_row = end_row + delta
            elseif insert_at == end_row + 1 then
                if key and key.buf == entry.buf and key.key == "o" and key.row == end_row then
                    entry.end_row = end_row + delta
                end
            end
            return false
        end

        local old_end = lastline - 1
        if old_end < start_row then
            entry.start_row = start_row + delta
            entry.end_row = end_row + delta
            return false
        end
        if firstline > end_row then
            return false
        end

        local before_count = math.max(0, firstline - start_row)
        local after_count = math.max(0, end_row - old_end)
        local new_len = before_count + new_count + after_count
        if new_len <= 0 then
            return true
        end

        local new_start = firstline <= start_row and firstline or start_row
        entry.start_row = new_start
        entry.end_row = new_start + new_len - 1
        return false
    end

    vim.on_key(function(key)
        if vim.fn.mode() ~= "n" then
            return
        end
        local translated = vim.fn.keytrans(key)
        if translated ~= "o" and translated ~= "O" then
            return
        end
        local win = vim.api.nvim_get_current_win()
        if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= after_buf then
            return
        end
        pending_line_key = {
            buf = after_buf,
            key = translated,
            row = vim.api.nvim_win_get_cursor(win)[1] - 1,
        }
    end, on_key_ns)

    vim.api.nvim_buf_attach(after_buf, false, {
        on_lines = function(_, buf, _, firstline, lastline, new_lastline)
            if buf ~= after_buf then
                return
            end
            for i = #notes, 1, -1 do
                local entry = notes[i]
                if entry.buf == buf and update_note_for_lines(entry, firstline, lastline, new_lastline) then
                    delete_note(entry)
                end
            end
            pending_line_key = nil
            refresh_all_notes()
        end,
    })

    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
        group = note_refresh_group,
        callback = function()
            if review_tab and vim.api.nvim_tabpage_is_valid(review_tab) then
                refresh_all_notes()
            end
        end,
    })

    ---@param result string
    ---@param extra? table
    ---@param review_notes table[]
    ---@return string
    local function encode_result(result, extra, review_notes)
        extra = extra or {}
        extra.result = result
        if #review_notes > 0 then
            extra.notes = review_notes
        end
        return vim.json.encode(extra)
    end

    local function truthy(value)
        return value == true or value == 1
    end

    local function restore_tracked_keymaps()
        for id, entry in pairs(tracked_keymaps) do
            tracked_keymaps[id] = nil
            if vim.api.nvim_buf_is_valid(entry.buf) then
                pcall(vim.keymap.del, entry.mode, entry.lhs, { buffer = entry.buf })
                local original = entry.original
                if original then
                    local rhs = original.callback or original.rhs
                    if rhs then
                        pcall(vim.keymap.set, entry.mode, entry.lhs, rhs, {
                            buffer = entry.buf,
                            silent = truthy(original.silent),
                            nowait = truthy(original.nowait),
                            expr = truthy(original.expr),
                            remap = not truthy(original.noremap),
                            script = truthy(original.script),
                            replace_keycodes = truthy(original.replace_keycodes),
                            desc = original.desc,
                        })
                    end
                end
            end
        end
    end

    local function cleanup_review_resources()
        if cleaned_up then
            return
        end
        cleaned_up = true
        if timeout then
            pcall(vim.fn.timer_stop, timeout)
            timeout = nil
        end
        restore_tracked_keymaps()
        vim.on_key(nil, on_key_ns)
        pcall(vim.api.nvim_del_augroup_by_id, note_refresh_group)
        for _, entry in ipairs(notes) do
            clear_note_marks(entry)
        end
        -- Clear winbar and drop all diff state in the review tab, including
        -- any hidden buffers that may still be remembered by the diff engine.
        for _, w in ipairs({ left_win, right_win }) do
            if vim.api.nvim_win_is_valid(w) then
                vim.wo[w].winbar = ""
            end
        end
        vim.go.diffopt = prev_diffopt
        local diff_win = first_valid_review_win()
        if diff_win then
            vim.api.nvim_win_call(diff_win, function()
                vim.cmd("diffoff!")
            end)
        end
        -- Restore the real file buffer's original state
        if vim.api.nvim_buf_is_valid(before_buf) then
            vim.bo[before_buf].modifiable = prev_modifiable
            vim.bo[before_buf].readonly = prev_readonly
        end
    end

    local function close_review_tab()
        cleanup_review_resources()
        -- Close all windows except left_win — this handles right_win
        -- plus any plugin floats that landed in
        -- the review tab and can make tabclose fail with E445.
        if review_tab and vim.api.nvim_tabpage_is_valid(review_tab) then
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(review_tab)) do
                if win ~= left_win and vim.api.nvim_win_is_valid(win) then
                    pcall(vim.api.nvim_win_close, win, true)
                end
            end
        end
        if vim.api.nvim_buf_is_valid(after_buf) then
            vim.api.nvim_buf_delete(after_buf, { force = true })
        end
        if review_tab and vim.api.nvim_tabpage_is_valid(review_tab) then
            vim.api.nvim_set_current_tabpage(review_tab)
            vim.cmd("tabclose")
        end
        if vim.api.nvim_tabpage_is_valid(prev_tab) then
            vim.api.nvim_set_current_tabpage(prev_tab)
        end
        local session = require("pi.sessions.manager").get()
        if session then
            session.chat:ensure_shown_and_focus_prompt()
        end
    end

    local review_tab_closed_autocmd
    review_tab_closed_autocmd = vim.api.nvim_create_autocmd("TabClosed", {
        group = note_refresh_group,
        callback = function()
            if vim.api.nvim_tabpage_is_valid(review_tab) then
                return
            end
            pcall(vim.api.nvim_del_autocmd, review_tab_closed_autocmd)
            cleanup_review_resources()
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(after_buf) then
                    pcall(vim.api.nvim_buf_delete, after_buf, { force = true })
                end
            end)
            if responded then
                return
            end
            responded = true
            callback("Reject")
        end,
    })

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

        local review_notes = collect_notes()
        write_file(path, final_lines)
        require("pi.cache.files").invalidate()
        reload_buf_for_file(vim.fn.fnamemodify(path, ":p"))
        close_review_tab()

        if modified then
            callback(encode_result("AcceptModified", {
                content = table.concat(final_lines, "\n"),
            }, review_notes))
        else
            -- Send structured JSON so the extension knows the plugin already
            -- applied the change (and should block the tool). The TUI sends
            -- plain "Accept" — the extension lets the tool run in that case.
            callback(encode_result("Accepted", nil, review_notes))
        end
    end

    local function reject()
        if responded then
            return
        end
        responded = true
        local review_notes = collect_notes()
        close_review_tab()
        if #review_notes > 0 then
            callback(encode_result("Rejected", nil, review_notes))
        else
            callback("Reject")
        end
    end

    if type(opts.timeout) == "number" and opts.timeout > 0 then
        timeout = vim.fn.timer_start(opts.timeout, function()
            vim.schedule(function()
                if responded or cleaned_up then
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

    local function edit_note_visual()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.fn.mode() ~= "V" then
            vim.schedule(edit_note)
            return
        end
        local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
        local visual_pos = vim.fn.getpos("v")
        local visual_row = (visual_pos[2] or cursor_row + 1) - 1
        vim.schedule(function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_set_current_win(win)
            end
            if vim.api.nvim_buf_is_valid(buf) then
                edit_note(cursor_row, visual_row)
            end
        end)
    end

    ---@param buf integer
    ---@param key pi.KeySpec
    local function bind_edit_note_key(buf, key)
        if type(key) == "string" then
            bind_review_key(buf, key, edit_note, { desc = "Add/edit review note" })
            bind_review_key(buf, key, edit_note_visual, { modes = "x", desc = "Add review note for selected lines" })
            return
        end

        if type(key) ~= "table" then
            return
        end

        local modes = Keys.modes(key, "n")
        local normal_modes = {}
        local visual_modes = {}
        for _, mode in ipairs(modes) do
            if mode == "x" or mode == "v" then
                visual_modes[#visual_modes + 1] = mode
            else
                normal_modes[#normal_modes + 1] = mode
            end
        end
        if #normal_modes > 0 then
            bind_review_key(buf, { key[1], modes = normal_modes }, edit_note, { desc = "Add/edit review note" })
        end
        if #visual_modes > 0 then
            bind_review_key(
                buf,
                { key[1], modes = visual_modes },
                edit_note_visual,
                { desc = "Add review note for selected lines" }
            )
        end
    end

    for _, b in ipairs({ before_buf, after_buf }) do
        for _, k in ipairs(accept_keys) do
            bind_review_key(b, k, accept, { desc = "Accept edit" })
        end
        for _, k in ipairs(reject_keys) do
            bind_review_key(b, k, reject, { desc = "Reject edit" })
        end
        for _, k in ipairs(edit_note_keys) do
            bind_edit_note_key(b, k)
        end
        for _, k in ipairs(delete_note_keys) do
            bind_review_key(b, k, delete_note_at_cursor, { desc = "Delete review note" })
        end
        for _, k in ipairs(list_notes_keys) do
            bind_review_key(b, k, list_notes, { desc = "List review notes" })
        end
        for _, k in ipairs(expand_context_keys) do
            bind_review_key(b, k, function()
                update_context(context_step)
            end, { desc = "Expand diff context" })
        end
        for _, k in ipairs(shrink_context_keys) do
            bind_review_key(b, k, function()
                update_context(-context_step)
            end, { desc = "Shrink diff context" })
        end
        if help_key and not help_collides then
            bind_review_key(b, help_key, show_keymap_dialog, { desc = "Show diff keymaps" })
        end
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
