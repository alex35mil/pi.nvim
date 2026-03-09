--- Tool call rendering for chat history.

local M = {}

M.GLYPHS = { TOP = "╭─ ", MID = "│  ", SEP = "├──── ", BOT = "╰─ " }

---@param result? table
---@return string?
local function extract_result_text(result)
    if not result or not result.content then
        return nil
    end
    -- Live events: result.content = [{type: "text", text: "..."}]
    -- Replay toolResult: msg.content may be a string or array of strings
    local content = result.content
    if type(content) == "string" then
        local trimmed = vim.trim(content)
        return trimmed ~= "" and trimmed or nil
    end
    if type(content) ~= "table" then
        return nil
    end
    local parts = {}
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "text" and block.text then
            parts[#parts + 1] = block.text
        elseif type(block) == "string" then
            parts[#parts + 1] = block
        end
    end
    if #parts > 0 then
        return vim.trim(table.concat(parts, "\n"))
    end
    return nil
end

---@param history pi.ChatHistory
---@param row integer 0-indexed
---@param glyph string
function M.set_border(history, row, glyph)
    vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
        virt_text = { { glyph, "PiToolBorder" } },
        virt_text_pos = "inline",
        hl_mode = "replace",
    })
end

---@param history pi.ChatHistory
---@param text string
---@param hl_group? string
local function render_body_line(history, text, hl_group)
    local start = history:_append_lines({ text })
    M.set_border(history, start, M.GLYPHS.MID)
    if #text > 0 then
        vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), start, 0, {
            end_col = #text,
            hl_group = hl_group or "PiToolCall",
        })
    end
end

---@param history pi.ChatHistory
---@param text string
local function render_output(history, text)
    local sep_row = history:_append_lines({ "" })
    M.set_border(history, sep_row, M.GLYPHS.SEP)
    local output_lines = vim.split(text, "\n", { plain = true })
    -- The history buffer uses treesitter markdown for rendering agent prose.
    -- Tool output may contain ``` at the start of a line (e.g. a command that
    -- prints code fences). Treesitter treats these as code fence delimiters —
    -- an unclosed fence causes all content below to be styled as code.
    --
    -- We use conceallevel=0 on the history window so treesitter can't conceal
    -- characters (brackets, bold markers, etc.) inside tool output. But it still
    -- PARSES ``` as fence delimiters. To prevent leaking, we count fence lines
    -- and auto-close if odd — same approach used for user messages in history.lua.
    local auto_closed = false
    local fences = 0
    for _, line in ipairs(output_lines) do
        if line:match("^```") then
            fences = fences + 1
        end
    end
    if fences % 2 == 1 then
        output_lines[#output_lines + 1] = "```"
        auto_closed = true
    end
    local start = history:_append_lines(output_lines)
    for i = 0, #output_lines - 1 do
        M.set_border(history, start + i, M.GLYPHS.MID)
        local line = output_lines[i + 1] or ""
        if #line > 0 then
            vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), start + i, 0, {
                end_col = #line,
                hl_group = "PiToolOutput",
                priority = 200,
            })
        end
    end
    if auto_closed then
        local close_row = start + #output_lines - 1
        vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), close_row, 3, {
            virt_text = { { " ← auto-closed", "PiWarning" } },
            virt_text_pos = "inline",
        })
    end
end

--- Parse treesitter highlights for a source string.
---@param text string  source code
---@param lang string  treesitter language
---@return table<integer, {sc: integer, ec: integer, hl: string}[]>  0-based line → highlights
local function ts_highlights(text, lang)
    local result = {}
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not parser then
        return result
    end
    local trees = parser:parse()
    if not trees or #trees == 0 then
        return result
    end
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
        return result
    end
    for id, node in query:iter_captures(trees[1]:root(), text) do
        local hl = "@" .. query.captures[id] .. "." .. lang
        local sr, sc, er, ec = node:range()
        for row = sr, er do
            result[row] = result[row] or {}
            local s = (row == sr) and sc or 0
            local e = (row == er) and ec or nil
            result[row][#result[row] + 1] = { sc = s, ec = e, hl = hl }
        end
    end
    return result
end

--- Apply treesitter syntax highlights to rendered diff lines.
---@param buf integer
---@param ns integer
---@param rendered table[]
---@param start_row integer  0-indexed row of first code fence
---@param old_hl table  highlights from ts_highlights(old_text)
---@param new_hl table  highlights from ts_highlights(new_text)
local function apply_diff_syntax(buf, ns, rendered, start_row, old_hl, new_hl)
    for i, r in ipairs(rendered) do
        local src_hl = r.src_kind == "new" and new_hl or old_hl
        local line_hls = src_hl[r.src_line] or {}
        local row = start_row + i - 1
        for _, h in ipairs(line_hls) do
            local sc = r.prefix_len + h.sc
            local ec = h.ec and (r.prefix_len + h.ec) or nil
            vim.api.nvim_buf_set_extmark(buf, ns, row, sc, {
                end_col = ec,
                hl_group = h.hl,
                priority = 300, -- above diff background
            })
        end
    end
end

---@param history pi.ChatHistory
---@param old_text string
---@param new_text string
---@param line_offset? integer  added to line numbers (0-based file offset)
---@param path? string  file path for syntax highlighting
local function render_diff(history, old_text, new_text, line_offset, path)
    line_offset = line_offset or 0
    -- Ensure trailing newlines for vim.diff
    if not old_text:find("\n$") then
        old_text = old_text .. "\n"
    end
    if not new_text:find("\n$") then
        new_text = new_text .. "\n"
    end
    local diff_text = vim.diff(old_text, new_text)
    if not diff_text or diff_text == "" then
        return
    end

    -- Parse unified diff: collect content lines with line numbers, highlight type, and source mapping
    ---@type { text: string, hl: string?, src_kind: "old"|"new", src_line: integer, prefix_len: integer }[]
    local rendered = {}
    local old_ln, new_ln
    local old_idx, new_idx -- 0-based indices into old_text/new_text
    for line in diff_text:gmatch("[^\n]*") do
        local c = line:sub(1, 1)
        if line:match("^@@") then
            local os, ns = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
            old_idx = tonumber(os) - 1
            new_idx = tonumber(ns) - 1
            old_ln = tonumber(os) + line_offset
            new_ln = tonumber(ns) + line_offset
        elseif c == "-" and old_ln then
            local prefix = string.format("%4d - ", old_ln)
            rendered[#rendered + 1] = {
                text = prefix .. line:sub(2),
                hl = "PiDiffDelete",
                src_kind = "old",
                src_line = old_idx,
                prefix_len = #prefix,
            }
            old_ln = old_ln + 1
            old_idx = old_idx + 1
        elseif c == "+" and new_ln then
            local prefix = string.format("%4d + ", new_ln)
            rendered[#rendered + 1] = {
                text = prefix .. line:sub(2),
                hl = "PiDiffAdd",
                src_kind = "new",
                src_line = new_idx,
                prefix_len = #prefix,
            }
            new_ln = new_ln + 1
            new_idx = new_idx + 1
        elseif c == " " and old_ln then
            local prefix = string.format("%4d   ", old_ln)
            rendered[#rendered + 1] = {
                text = prefix .. line:sub(2),
                src_kind = "old",
                src_line = old_idx,
                prefix_len = #prefix,
            }
            old_ln = old_ln + 1
            new_ln = (new_ln or 0) + 1
            old_idx = (old_idx or 0) + 1
            new_idx = (new_idx or 0) + 1
        end
    end
    if #rendered == 0 then
        return
    end

    local sep_row = history:_append_lines({ "" })
    M.set_border(history, sep_row, M.GLYPHS.SEP)

    local lines = {}
    for _, r in ipairs(rendered) do
        lines[#lines + 1] = r.text
    end

    local start = history:_append_lines(lines)
    for i = 0, #lines - 1 do
        M.set_border(history, start + i, M.GLYPHS.MID)
    end

    -- Apply full-line background highlights and line number styling
    -- hl_group + hl_eol extends to window edge; end_row = row+1 makes it "multiline" (required for hl_eol)
    -- Border virt_text uses hl_mode="replace" so it ignores the hl_group background
    for i, r in ipairs(rendered) do
        local row = start + i - 1
        -- Diff background
        if r.hl then
            vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
                end_row = row + 1,
                hl_group = r.hl,
                hl_eol = true,
            })
        end
        -- Line number + sign prefix in comment color
        vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
            end_col = r.prefix_len,
            hl_group = "PiDiffLineNr",
            priority = 300,
        })
    end

    -- Apply treesitter syntax highlights
    if path then
        local ft = vim.filetype.match({ filename = path })
        if ft then
            local lang = vim.treesitter.language.get_lang(ft) or ft
            local lok = pcall(vim.treesitter.language.inspect, lang)
            if lok then
                local old_hl = ts_highlights(old_text, lang)
                local new_hl = ts_highlights(new_text, lang)
                apply_diff_syntax(history:buf(), history:ns(), rendered, start, old_hl, new_hl)
            end
        end
    end
end

-- ── Collapse helpers ────────────────────────────────────────────────

--- Build a structured collapsed view for a tool block.
--- Input: ≤ input_visible as-is, otherwise first input_visible line(s) + "+N lines".
--- Separator + output hidden entirely when output_visible = 0.
--- Output: ≤ output_visible as-is, otherwise "…N lines" + last output_visible line(s).
---@param input_lines string[]
---@param output_lines string[] actual output (no separator/code fences)
---@param has_output boolean
---@param input_visible integer
---@param output_visible integer
---@return string[] lines
---@return string[] specs  parallel array: "input"|"summary"|"separator"|"output"
function M.build_collapsed_view(input_lines, output_lines, has_output, input_visible, output_visible)
    local lines, specs = {}, {}

    -- Input
    if #input_lines <= input_visible then
        for _, l in ipairs(input_lines) do
            lines[#lines + 1] = l
            specs[#specs + 1] = "input"
        end
    else
        for i = 1, input_visible do
            lines[#lines + 1] = input_lines[i]
            specs[#specs + 1] = "input"
        end
        lines[#lines + 1] = " +" .. (#input_lines - input_visible) .. " lines"
        specs[#specs + 1] = "summary"
    end

    -- Separator + Output (hidden entirely when output_visible = 0)
    if has_output and output_visible > 0 then
        lines[#lines + 1] = ""
        specs[#specs + 1] = "separator"

        if #output_lines <= output_visible then
            for _, l in ipairs(output_lines) do
                lines[#lines + 1] = l
                specs[#specs + 1] = "output"
            end
        elseif #output_lines > 0 then
            lines[#lines + 1] = "…" .. (#output_lines - output_visible) .. " lines"
            specs[#specs + 1] = "summary"
            for i = #output_lines - output_visible + 1, #output_lines do
                lines[#lines + 1] = output_lines[i]
                specs[#specs + 1] = "output"
            end
        end
    end

    return lines, specs
end

--- Apply border and highlight extmarks to collapsed lines.
---@param history pi.ChatHistory
---@param base_row integer 0-indexed first row
---@param specs string[] parallel array of line types
---@param lines string[]
function M.apply_collapsed_extmarks(history, base_row, specs, lines)
    local hl_map = { input = "PiToolCall", summary = "PiToolCollapsed", output = "PiToolOutput" }
    for i, spec in ipairs(specs) do
        local row = base_row + i - 1
        local glyph = spec == "separator" and M.GLYPHS.SEP or M.GLYPHS.MID
        M.set_border(history, row, glyph)
        local hl = hl_map[spec]
        if hl and #lines[i] > 0 then
            vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
                end_col = #lines[i],
                hl_group = hl,
            })
        end
    end
end

--- Extract input lines and actual output lines from a tool block's inner range.
---@param history pi.ChatHistory
---@param block pi.ToolBlock
---@return string[] input_lines
---@return string[] output_lines  (actual content, no separator/code fences)
---@return boolean has_output
function M.extract_tool_sections(history, block)
    local buf = history:buf()
    local ns_id = history:ns()
    local header_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, block.icon_extmark, {})[1]
    local footer_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, block.end_extmark, {})[1]
    local has_output = block.output_extmark ~= nil

    local input_end = footer_row
    if has_output then
        input_end = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, block.output_extmark, {})[1]
    end
    local input_lines = vim.api.nvim_buf_get_lines(buf, header_row + 1, input_end, false)

    local output_lines = {}
    if has_output then
        local output_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, block.output_extmark, {})[1]
        -- Output section: separator, actual lines...
        local content_start = output_row + 1 -- skip separator
        if content_start < footer_row then
            output_lines = vim.api.nvim_buf_get_lines(buf, content_start, footer_row, false)
        end
    end

    return input_lines, output_lines, has_output
end

--- Check whether a tool block should be collapsed based on renderer thresholds.
---@param input_lines string[]
---@param output_lines string[]
---@param input_visible integer
---@param output_visible integer
---@return boolean
function M.should_collapse(input_lines, output_lines, input_visible, output_visible)
    return #input_lines > input_visible or #output_lines > output_visible
end

--- Renderers ---

---@class pi.ToolRenderer
---@field on_start? fun(history: pi.ChatHistory, args: table?)
---@field on_end? fun(history: pi.ChatHistory, args: table?, result: table?, is_error: boolean?)
---@field input_visible? integer  lines to show when collapsed (default: show all)
---@field output_visible? integer lines to show when collapsed (default: show all)

---@type table<string, pi.ToolRenderer>
local renderers = {
    bash = {
        input_visible = 1,
        output_visible = 1,
        on_start = function(history, args)
            if args and (args.command or args.cmd) then
                local cmd = args.command or args.cmd
                local lines = vim.split(cmd, "\n", { plain = true })
                for _, line in ipairs(lines) do
                    render_body_line(history, line)
                end
            end
        end,
        on_end = function(history, _, result)
            local text = extract_result_text(result)
            if text and text ~= "" then
                render_output(history, text)
            end
        end,
    },
    read = {
        on_start = function(history, args)
            if args and (args.path or args.file_path) then
                render_body_line(history, args.path or args.file_path)
            end
        end,
    },
    edit = {
        output_visible = 0,
        on_start = function(history, args)
            if args and (args.path or args.file_path) then
                render_body_line(history, args.path or args.file_path)
            end
        end,
        on_end = function(history, args)
            if args and args.oldText and args.newText then
                -- Find the starting line number of oldText in the file
                local offset = 0
                local path = args.path or args.file_path
                if path then
                    local abs = vim.fn.fnamemodify(path, ":p")
                    for _, b in ipairs(vim.api.nvim_list_bufs()) do
                        if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs then
                            local content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
                            local pos = content:find(args.oldText, 1, true)
                            if pos then
                                local _, count = content:sub(1, pos - 1):gsub("\n", "\n")
                                offset = count
                            end
                            break
                        end
                    end
                end
                render_diff(history, args.oldText, args.newText, offset, path)
            end
        end,
    },
    write = {
        on_start = function(history, args)
            if args and (args.path or args.file_path) then
                render_body_line(history, args.path or args.file_path)
            end
        end,
    },
}

---@type pi.ToolRenderer
local default_renderer = {
    input_visible = 1,
    output_visible = 1,
    on_end = function(history, _, result)
        local text = extract_result_text(result)
        if text and text ~= "" then
            render_output(history, text)
        end
    end,
}

---@param tool_name string
---@return pi.ToolRenderer
function M.get_renderer(tool_name)
    return renderers[tool_name] or default_renderer
end

return M
