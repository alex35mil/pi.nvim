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

---@class pi.ToolRenderer
---@field on_start? fun(history: pi.ChatHistory, args: table?)
---@field on_end? fun(history: pi.ChatHistory, args: table?, result: table?, is_error: boolean?)

---@type table<string, pi.ToolRenderer>
local renderers = {
    bash = {
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
