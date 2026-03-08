--- Tool call rendering for chat history.

local M = {}

M.GLYPHS = { TOP = "╭─ ", MID = "│  ", SEP = "├──── ", BOT = "╰─ " }

---@param result? table
---@return string?
local function extract_result_text(result)
    if not result or not result.content then
        return nil
    end
    local parts = {}
    for _, block in ipairs(result.content) do
        if type(block) == "table" and block.type == "text" and block.text then
            parts[#parts + 1] = block.text
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
        hl_mode = "combine",
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
    -- Wrap in fenced code block for treesitter highlighting, then conceal
    -- the ``` delimiters so only the syntax highlighting is visible.
    local output_lines = vim.split(text, "\n", { plain = true })
    table.insert(output_lines, 1, "```")
    output_lines[#output_lines + 1] = "```"
    local start = history:_append_lines(output_lines)
    for i = 0, #output_lines - 1 do
        M.set_border(history, start + i, M.GLYPHS.MID)
        if i > 0 and i < #output_lines - 1 then
            local line = output_lines[i + 1] or ""
            if #line > 0 then
                vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), start + i, 0, {
                    end_col = #line,
                    hl_group = "PiToolOutput",
                    priority = 200,
                })
            end
        end
    end
    vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), start, 0, {
        end_col = 3,
        conceal = "",
    })
    vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), start + #output_lines - 1, 0, {
        end_col = 3,
        conceal = "",
    })
end

--- Build a structured collapsed view for a tool block.
--- Input: ≤ input_visible as-is, otherwise first input_visible line(s) + "+N lines".
--- Separator: always shown if output exists.
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

    -- Separator
    if has_output then
        lines[#lines + 1] = ""
        specs[#specs + 1] = "separator"
    end

    -- Output
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
        -- Output section: separator, ```, actual lines..., ```
        local content_start = output_row + 2 -- skip separator + opening ```
        local content_end = footer_row - 1 -- skip closing ```
        if content_end > content_start then
            output_lines = vim.api.nvim_buf_get_lines(buf, content_start, content_end, false)
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
        on_start = function(history, args)
            if args and (args.path or args.file_path) then
                render_body_line(history, args.path or args.file_path)
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
