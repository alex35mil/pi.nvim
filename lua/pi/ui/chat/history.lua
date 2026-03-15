--- Chat history buffer — message rendering and scrolling.

---@class pi.ChatHistory
---@field _buf integer
---@field _win integer?
---@field _tab pi.TabId
---@field _scroll_scheduled boolean
---@field _status_extmark_id integer?
---@field _status_text string?
---@field _status_start_time number?
---@field _spinner_frames string[]
---@field _spinner_rate integer
---@field _spinner_index integer
---@field _spinner_timer uv.uv_timer_t?
---@field _fence_open boolean
---@field _first_delta boolean
---@field _agent_start_time number?
---@field _show_thinking boolean
---@field _is_thinking boolean
---@field _needs_separator boolean
---@field _thinking_accum pi.ThinkingAccum?
---@field _thinking_blocks pi.ThinkingBlock[]
---@field _tool_blocks table<string, pi.ToolBlock>
---@field _placeholder_extmark integer?
---@field _placeholder_mode? "loading"
---@field _has_conversation_content boolean
---@field _startup_block_line_count integer
---@field _startup_block_expanded boolean
---@field _startup_block_expanded_lines? string[]
---@field _startup_block_expanded_marks? pi.HighlightMark[]
---@field _startup_block_compact_lines? string[]
---@field _startup_block_compact_marks? pi.HighlightMark[]
---@field _startup_timestamp integer?
---@field _startup_sections pi.StartupSection[]
---@field _startup_loaded boolean whether startup data has been fetched at least once
---@field _startup_errors pi.SystemErrorEntry[]
---@field _pending_queue pi.PendingQueueEntry[]
---@field _pending_queue_extmark_id integer?
---@field _replaying boolean
---@field _agent_text_start_row integer?
---@field _last_agent_response_extmark_id integer?
local History = {}
History.__index = History

---@class pi.MdTable
---@field start_row integer 0-indexed first row in the buffer
---@field end_row integer 0-indexed last row in the buffer (inclusive)
---@field header string[] header cell texts (trimmed)
---@field aligns ("left"|"center"|"right")[] per-column alignment
---@field rows string[][] data rows, each a list of cell texts
---@field widths integer[] display width per column

---@class pi.ToolBlock
---@field tool_name string
---@field icon_extmark integer
---@field tail_extmark? integer marks last row of block after on_start; used for positional insertion in on_tool_end
---@field output_extmark? integer
---@field end_extmark? integer
---@field tool_input? table
---@field inline? boolean
---@field finished? boolean
---@field expanded? boolean
---@field expanded_inner_lines? string[]
---@field expanded_inner_extmarks? table[]
---@field collapsed_inner_lines? string[]
---@field collapsed_specs? string[]

---@class pi.ThinkingAccum
---@field lines string[]
---@field anchor integer
---@field start_time number
---@field buf_lines integer

---@class pi.ThinkingBlock
---@field header string
---@field lines string[]
---@field anchor integer
---@field line_count integer
---@field visible boolean

---@class pi.PendingQueueEntry
---@field queue_type "steer"|"follow_up"
---@field text string
---@field expanded_text string
---@field image_count? integer

---@class pi.ChatErrorOpts
---@field pad_top? boolean
---@field pad_bottom? boolean

---@class pi.HighlightMark
---@field row integer
---@field col_start integer
---@field col_end integer
---@field hl string

local Ft = require("pi.filetypes")
local Config = require("pi.config")
local Tools = require("pi.ui.chat.tools")

local ns = vim.api.nvim_create_namespace("pi-chat")

local SCROLL_THRESHOLD = 10
local STARTUP_HL_PRIORITY = 200

---@return integer
local function now_ms()
    return os.time() * 1000
end

---@param image_count integer
---@return string
local function format_attachment_info(image_count)
    local icon = Config.options.ui.labels.attachments
    return image_count == 1 and (icon .. " 1 image attached") or (icon .. " %d images attached"):format(image_count)
end

--- Capture extmarks in a row range (positions saved relative to start_row).
---@param buf integer
---@param ns_id integer
---@param start_row integer 0-indexed inclusive
---@param end_row integer 0-indexed inclusive
---@return table[]
local function capture_extmarks(buf, ns_id, start_row, end_row)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_id, { start_row, 0 }, { end_row, -1 }, { details = true })
    local result = {}
    for _, m in ipairs(marks) do
        local details = m[4] or {}
        local opts = {}
        for _, key in ipairs({
            "hl_group",
            "virt_text",
            "virt_text_pos",
            "hl_mode",
            "priority",
            "end_col",
            "line_hl_group",
            "hl_eol",
        }) do
            if details[key] ~= nil then
                opts[key] = details[key]
            end
        end
        if details.end_row then
            opts.end_row = details.end_row - start_row -- relative
        end
        result[#result + 1] = { row = m[2] - start_row, col = m[3], opts = opts }
    end
    return result
end

--- Restore previously captured extmarks offset by base_row.
---@param buf integer
---@param ns_id integer
---@param base_row integer 0-indexed
---@param saved table[]
local function restore_extmarks(buf, ns_id, base_row, saved)
    for _, em in ipairs(saved) do
        local opts = vim.deepcopy(em.opts)
        if opts.end_row then
            opts.end_row = base_row + opts.end_row
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, base_row + em.row, em.col, opts)
    end
end

---@class pi.SpinnerDef
---@field refresh_rate integer ms between frames
---@field frames string[]
local spinner = {
    classic = {
        refresh_rate = 80,
        frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    },
    robot = {
        refresh_rate = 300,
        frames = {
            "󰚩",
            "󱙺",
            "󱚝",
            "󱚞",
            "󱚟",
            "󱚠",
            "󱚡",
            "󱚢",
            "󱚣",
            "󱚤",
            "󱚟",
            "󱚠",
            "󱜙",
            "󱜚",
            "󱚥",
            "󱚦",
        },
    },
    compaction = {
        refresh_rate = 400,
        frames = {
            "󰏗",
            "󰏖",
            "󱧕",
            "󱧘",
        },
    },
}

--- Format an epoch-ms timestamp for display
---@param ts number epoch milliseconds
---@return string
local function format_time(ts)
    local secs = math.floor(ts / 1000)
    return os.date(" %b %-d %Y, %H:%M", secs) --[[@as string]]
end

---@param name string
local function wipe_stale_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end
end

--- Markdown tables

--- Parse cells from a pipe-delimited markdown table row.
---@param line string
---@return string[]
local function parse_table_cells(line)
    local inner = vim.trim(line):match("^|(.+)|$")
    if not inner then
        return {}
    end
    local cells = vim.split(inner, "|", { plain = true })
    for i, cell in ipairs(cells) do
        cells[i] = vim.trim(cell)
    end
    return cells
end

--- Try to parse a contiguous block of lines as a markdown table.
---@param lines string[]
---@param buf_start_row integer 0-indexed buffer row of the first line
---@return pi.MdTable?
local function parse_table(lines, buf_start_row)
    if #lines < 3 then
        return nil
    end
    local header = parse_table_cells(lines[1])
    local ncols = #header
    if ncols == 0 then
        return nil
    end
    local sep_cells = parse_table_cells(lines[2])
    if #sep_cells ~= ncols then
        return nil
    end
    local aligns = {}
    for _, cell in ipairs(sep_cells) do
        if not cell:match("^:?%-+:?$") then
            return nil
        end
        local l = cell:sub(1, 1) == ":"
        local r = cell:sub(-1) == ":"
        if l and r then
            aligns[#aligns + 1] = "center"
        elseif r then
            aligns[#aligns + 1] = "right"
        else
            aligns[#aligns + 1] = "left"
        end
    end
    local data_rows = {}
    for i = 3, #lines do
        local cells = parse_table_cells(lines[i])
        local row = {}
        for j = 1, ncols do
            row[j] = cells[j] or ""
        end
        data_rows[#data_rows + 1] = row
    end
    -- Column widths: max display width across header + all data rows
    local widths = {}
    for j = 1, ncols do
        widths[j] = vim.fn.strdisplaywidth(header[j])
    end
    for _, row in ipairs(data_rows) do
        for j = 1, ncols do
            widths[j] = math.max(widths[j], vim.fn.strdisplaywidth(row[j]))
        end
    end
    for j = 1, ncols do
        widths[j] = math.max(widths[j], 1)
    end
    return {
        start_row = buf_start_row,
        end_row = buf_start_row + #lines - 1,
        header = header,
        aligns = aligns,
        rows = data_rows,
        widths = widths,
    }
end

--- Pad or align a cell string to a given display width.
---@param text string
---@param width integer target display width
---@param align "left"|"center"|"right"
---@return string
local function align_table_cell(text, width, align)
    local pad = width - vim.fn.strdisplaywidth(text)
    if pad <= 0 then
        return text
    end
    if align == "right" then
        return string.rep(" ", pad) .. text
    elseif align == "center" then
        local l = math.floor(pad / 2)
        return string.rep(" ", l) .. text .. string.rep(" ", pad - l)
    end
    return text .. string.rep(" ", pad)
end

--- Build a horizontal border line with box-drawing characters.
---@param widths integer[]
---@param left string corner/tee glyph
---@param mid string intersection glyph
---@param right string corner/tee glyph
---@param fill string horizontal fill glyph
---@return string
local function table_border(widths, left, mid, right, fill)
    local parts = { left }
    for i, w in ipairs(widths) do
        parts[#parts + 1] = string.rep(fill, w + 2) -- +2 for cell padding
        if i < #widths then
            parts[#parts + 1] = mid
        end
    end
    parts[#parts + 1] = right
    return table.concat(parts)
end

--- Build a data/header row line with box-drawing pipe characters.
---@param cells string[]
---@param widths integer[]
---@param aligns ("left"|"center"|"right")[]
---@return string
local function table_row(cells, widths, aligns)
    local parts = { "│" }
    for i, cell in ipairs(cells) do
        parts[#parts + 1] = " " .. align_table_cell(cell, widths[i], aligns[i] or "left") .. " │"
    end
    return table.concat(parts)
end

--- Apply PiTableBorder highlight to every │ character in a buffer line.
---@param buf integer
---@param ns_id integer
---@param row integer 0-indexed
---@param line string
local function highlight_table_pipes(buf, ns_id, row, line)
    local pipe = "│"
    local pos = 1
    while true do
        local s, e = line:find(pipe, pos, true)
        if not s then
            break
        end
        vim.api.nvim_buf_set_extmark(buf, ns_id, row, s - 1, {
            end_col = e,
            hl_group = "PiTableBorder",
            priority = 200,
        })
        pos = e + 1
    end
end

---@param tab pi.TabId
---@return pi.ChatHistory
function History.new(tab)
    local self = setmetatable({}, History)
    self._win = nil
    self._tab = tab
    self._scroll_scheduled = false
    self._status_extmark_id = nil
    self._status_text = nil
    self._status_start_time = nil
    self._spinner_index = 1
    self._spinner_timer = nil
    self:_pick_spinner()
    self._fence_open = false
    self._first_delta = false
    self._agent_start_time = nil
    self._show_thinking = Config.options.ui.show_thinking
    self._is_thinking = false
    self._needs_separator = false
    self._thinking_accum = nil
    self._thinking_blocks = {}
    self._tool_blocks = {}
    self._placeholder_extmark = nil
    self._placeholder_mode = nil
    self._has_conversation_content = false
    self._startup_block_line_count = 0
    self._startup_block_expanded = Config.options.ui.expand_startup_details
    self._startup_block_expanded_lines = nil
    self._startup_block_expanded_marks = nil
    self._startup_block_compact_lines = nil
    self._startup_block_compact_marks = nil
    self._startup_timestamp = nil
    self._startup_sections = {}
    self._startup_loaded = false
    self._startup_errors = {}
    self._pending_queue = {}
    self._pending_queue_extmark_id = nil
    self._replaying = false
    self._agent_text_start_row = nil
    self._last_agent_response_extmark_id = nil

    local panel = Config.options.ui.panels.history
    local name = panel.name and panel.name(tab) or ("π-chat | " .. tab)
    wipe_stale_buf(name)
    self._buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self._buf].buftype = "nofile"
    vim.bo[self._buf].filetype = Ft.history
    vim.bo[self._buf].swapfile = false
    vim.bo[self._buf].bufhidden = "hide"
    vim.bo[self._buf].modifiable = false
    vim.api.nvim_buf_set_name(self._buf, name)

    return self
end

---@param fn fun()
function History:_with_modifiable(fn)
    vim.bo[self._buf].modifiable = true
    local ok, err = pcall(fn)
    vim.bo[self._buf].modifiable = false
    if not ok then
        error(err)
    end
end

---@return boolean
function History:_should_auto_scroll()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return false
    end
    local cursor_line = vim.api.nvim_win_get_cursor(self._win)[1]
    local total = vim.api.nvim_buf_line_count(self._buf)
    return (total - cursor_line) <= SCROLL_THRESHOLD
end

function History:_maybe_scroll()
    if not self:_should_auto_scroll() then
        return
    end
    if self._scroll_scheduled then
        return
    end
    self._scroll_scheduled = true
    vim.schedule(function()
        self._scroll_scheduled = false
        self:_scroll_to_bottom()
    end)
end

--- Scroll to the last line with cursor at bottom of the window.
function History:_scroll_to_bottom()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    vim.api.nvim_win_call(self._win, function()
        -- G=last line, 0=col 1, zb=redraw with cursor at bottom
        vim.cmd("normal! G0zb")
    end)
end

local DEFAULT_SCROLL_LINES = 15

--- Scroll the history window by a number of lines.
---@param direction "up"|"down"
---@param lines? integer lines to scroll (default 15)
function History:scroll(direction, lines)
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    local count = lines or DEFAULT_SCROLL_LINES
    local key = direction == "up" and "\x19" or "\x05"
    vim.api.nvim_win_call(self._win, function()
        vim.cmd("normal! " .. count .. key)
    end)
end

--- Scroll the history window to the bottom (most recent message).
function History:scroll_to_bottom()
    self:_scroll_to_bottom()
end

--- Scroll the history window to the start of the most recent agent response.
function History:scroll_to_last_agent_response()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    if not self._last_agent_response_extmark_id then
        return
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, self._last_agent_response_extmark_id, {})
    if not pos or #pos == 0 then
        return
    end

    vim.api.nvim_win_call(self._win, function()
        vim.api.nvim_win_set_cursor(self._win, { pos[1] + 1, 0 })
        vim.cmd("normal! zt")
    end)
end

function History:_pick_spinner()
    local opt = Config.options.ui.spinner
    ---@type pi.SpinnerDef
    local s
    if type(opt) == "table" then
        s = { refresh_rate = opt.refresh_rate or 80, frames = opt.frames or opt }
    else
        s = spinner[opt] or spinner.robot
    end
    self._spinner_frames = s.frames
    self._spinner_rate = s.refresh_rate
end

function History:_update_status_extmark()
    -- Clear both extmarks
    if self._pending_queue_extmark_id then
        vim.api.nvim_buf_del_extmark(self._buf, ns, self._pending_queue_extmark_id)
        self._pending_queue_extmark_id = nil
    end
    if self._status_extmark_id then
        vim.api.nvim_buf_del_extmark(self._buf, ns, self._status_extmark_id)
        self._status_extmark_id = nil
    end

    local last_line = vim.api.nvim_buf_line_count(self._buf) - 1

    -- Pending queue extmark (rendered above status)
    if #self._pending_queue > 0 then
        ---@type table[]
        local virt = { { { "" } } }
        for _, entry in ipairs(self._pending_queue) do
            local label = entry.queue_type == "steer" and (Config.options.ui.labels.steer_message .. " ")
                or (Config.options.ui.labels.follow_up_message .. " ")
            local preview = entry.text:gsub("\n", " ")
            if preview == "" and entry.image_count and entry.image_count > 0 then
                preview = format_attachment_info(entry.image_count)
            end
            if #preview > 80 then
                preview = preview:sub(1, 77) .. "…"
            end
            virt[#virt + 1] = {
                { "  " .. label, "PiPendingQueueLabel" },
                { preview, "PiPendingQueueText" },
            }
        end
        self._pending_queue_extmark_id = vim.api.nvim_buf_set_extmark(self._buf, ns, last_line, 0, {
            virt_lines = virt,
        })
    end

    -- Status spinner extmark
    if not self._status_text then
        return
    end
    local frame = self._spinner_frames[self._spinner_index]
    local elapsed = ""
    if self._status_start_time then
        local secs = math.floor(vim.uv.hrtime() / 1e9 - self._status_start_time)
        if secs >= 60 then
            elapsed = " for " .. math.floor(secs / 60) .. "m " .. (secs % 60) .. "s"
        elseif secs >= 1 then
            elapsed = " for " .. secs .. "s"
        end
    end
    local content = frame .. "  " .. self._status_text
    local suffix = ""
    if self._is_thinking then
        suffix = " · " .. Config.options.ui.labels.thinking
    end
    local full_width = vim.fn.strdisplaywidth(content .. elapsed .. suffix)
    local pad = 0
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        local win_width = vim.api.nvim_win_get_width(self._win)
        pad = math.max(0, math.floor((win_width - full_width) / 2))
    end
    local padding = string.rep(" ", pad)
    self._status_extmark_id = vim.api.nvim_buf_set_extmark(self._buf, ns, last_line, 0, {
        virt_lines = {
            { { "" } },
            { { padding .. content, "PiBusy" }, { elapsed, "PiBusyTime" }, { suffix, "PiThinking" } },
            { { "" } },
        },
    })
end

---@param text string
function History:_append_text(text)
    local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
    local cur = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
    local col = #cur
    local lines = vim.split(text, "\n", { plain = true })
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_text(self._buf, last_line, col, last_line, col, lines)
    end)
    self:_update_status_extmark()
    self:_maybe_scroll()
end

---@param lines_list string[]
---@return integer start_row 0-indexed row where the first line was placed
function History:_append_lines(lines_list)
    local start_row = 0
    self:_with_modifiable(function()
        local line_count = vim.api.nvim_buf_line_count(self._buf)
        if line_count == 1 then
            local first = vim.api.nvim_buf_get_lines(self._buf, 0, 1, false)[1]
            if first == "" then
                vim.api.nvim_buf_set_lines(self._buf, 0, 1, false, lines_list)
                start_row = 0
                self:_maybe_scroll()
                return
            end
        end
        start_row = line_count
        vim.api.nvim_buf_set_lines(self._buf, line_count, line_count, false, lines_list)
    end)
    self:_update_status_extmark()
    self:_maybe_scroll()
    return start_row
end

--- Insert lines at a specific row instead of appending at the buffer end.
--- Used by on_tool_end to place output inside the correct tool block when
--- multiple tools run in parallel.
---@param row integer 0-indexed row to insert before
---@param lines_list string[]
---@return integer start_row 0-indexed row where the first line was placed
---@return integer next_row row after the last inserted line (for chaining)
function History:_insert_lines(row, lines_list)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, row, row, false, lines_list)
    end)
    self:_update_status_extmark()
    self:_maybe_scroll()
    return row, row + #lines_list
end

---@param header string
---@param content string[]
---@return string[]
function History:_build_thinking_block(header, content)
    local label = Config.options.ui.labels.thinking
    local result = { "", label .. " " .. header }
    for _, line in ipairs(content) do
        result[#result + 1] = line
    end
    result[#result + 1] = ""
    return result
end

---@param start_row integer
---@param count integer
function History:_apply_thinking_hl(start_row, count)
    for i = 0, count - 1 do
        local line = vim.api.nvim_buf_get_lines(self._buf, start_row + i, start_row + i + 1, false)[1] or ""
        vim.api.nvim_buf_set_extmark(self._buf, ns, start_row + i, 0, {
            end_col = #line,
            hl_group = "PiThinking",
        })
    end
end

---@param block_lines string[]
---@param anchor integer extmark id
function History:_insert_thinking_block(block_lines, anchor)
    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, anchor, {})
    local row = pos[1]
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, row, row, false, block_lines)
    end)
    self:_apply_thinking_hl(row + 1, #block_lines - 2)
    self:_update_status_extmark()
    self:_maybe_scroll()
end

---@param line_count integer
---@param anchor integer extmark id
function History:_remove_thinking_block(line_count, anchor)
    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, anchor, {})
    local anchor_row = pos[1]
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, anchor_row, anchor_row + line_count, false, {})
    end)
    self:_update_status_extmark()
    self:_maybe_scroll()
end

---@return integer
function History:buf()
    return self._buf
end

---@return integer
function History:ns()
    return ns
end

---@param win integer?
function History:set_win(win)
    self._win = win
end

---@return integer?
function History:win()
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        return self._win
    end
    return nil
end

---@alias pi.Status { type: "agent", text: string } | { type: "compaction" }

---@param status pi.Status?
function History:set_status(status)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end

        local text ---@type string?
        if status then
            if status.type == "compaction" then
                local s = spinner.compaction
                self._spinner_frames = s.frames
                self._spinner_rate = s.refresh_rate
                text = "Compacting…"
            else
                self:_pick_spinner()
                text = status.text
            end
        else
            self:_pick_spinner()
        end

        if text == self._status_text then
            return
        end
        self._status_text = text
        self._status_start_time = text and math.floor(vim.uv.hrtime() / 1e9) or nil
        self._spinner_index = 1
        self:_update_status_extmark()
        -- Force scroll (bypass _scroll_scheduled guard) so the spinner
        -- virt_lines are visible even if a prior scroll is still pending.
        if text and self:_should_auto_scroll() then
            self:_scroll_to_bottom()
        else
            self:_maybe_scroll()
        end

        -- Stop existing timer — rate may have changed between spinner types.
        if self._spinner_timer then
            self._spinner_timer:stop()
            self._spinner_timer:close()
            self._spinner_timer = nil
        end

        if text then
            self._spinner_timer = assert(vim.uv.new_timer())
            self._spinner_timer:start(
                self._spinner_rate,
                self._spinner_rate,
                vim.schedule_wrap(function()
                    if not self._status_text then
                        return
                    end
                    self._spinner_index = self._spinner_index % #self._spinner_frames + 1
                    self:_update_status_extmark()
                end)
            )
        end
    end)
end

--- Find and render all markdown tables in the given buffer range.
--- Skips tables inside fenced code blocks.
---@param from_row integer 0-indexed
---@param to_row integer 0-indexed (inclusive)
function History:_render_tables(from_row, to_row)
    if from_row > to_row then
        return
    end
    local all_lines = vim.api.nvim_buf_get_lines(self._buf, from_row, to_row + 1, false)
    ---@type pi.MdTable[]
    local tables = {}
    local in_fence = false
    local i = 1
    while i <= #all_lines do
        local line = all_lines[i]
        if line:match("^```") then
            in_fence = not in_fence
            i = i + 1
        elseif in_fence then
            i = i + 1
        else
            local trimmed = vim.trim(line)
            if trimmed:match("^|.+|$") then
                local block = { line }
                local j = i + 1
                while j <= #all_lines do
                    local nt = vim.trim(all_lines[j])
                    if nt:match("^|.+|$") then
                        block[#block + 1] = all_lines[j]
                        j = j + 1
                    else
                        break
                    end
                end
                if #block >= 3 then
                    local tbl = parse_table(block, from_row + i - 1)
                    if tbl then
                        tables[#tables + 1] = tbl
                    end
                end
                i = j
            else
                i = i + 1
            end
        end
    end
    -- Render in reverse order so earlier row indices remain valid.
    for t = #tables, 1, -1 do
        self:_render_md_table(tables[t])
    end
end

--- Replace a parsed markdown table with box-drawing rendered lines and extmarks.
---@param tbl pi.MdTable
function History:_render_md_table(tbl)
    local widths = tbl.widths
    local aligns = tbl.aligns

    -- Build replacement lines (same count as original).
    local new_lines = {}
    new_lines[1] = table_row(tbl.header, widths, aligns)
    new_lines[2] = table_border(widths, "├", "┼", "┤", "─")
    for _, row in ipairs(tbl.rows) do
        new_lines[#new_lines + 1] = table_row(row, widths, aligns)
    end

    local top = table_border(widths, "┌", "┬", "┐", "─")
    local bot = table_border(widths, "└", "┴", "┘", "─")

    -- Replace buffer lines.
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, tbl.start_row, tbl.end_row + 1, false, new_lines)
    end)

    -- Top border (virtual line above first row).
    vim.api.nvim_buf_set_extmark(self._buf, ns, tbl.start_row, 0, {
        virt_lines = { { { top, "PiTableBorder" } } },
        virt_lines_above = true,
    })

    -- Bottom border (virtual line below last row).
    local last_row = tbl.start_row + #new_lines - 1
    vim.api.nvim_buf_set_extmark(self._buf, ns, last_row, 0, {
        virt_lines = { { { bot, "PiTableBorder" } } },
    })

    -- Highlights.
    for i, line in ipairs(new_lines) do
        local row = tbl.start_row + i - 1
        if i == 1 then
            -- Header: bold on the whole line, border color on │ at higher priority.
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                end_col = #line,
                hl_group = "PiTableHeader",
                priority = 100,
            })
            highlight_table_pipes(self._buf, ns, row, line)
        elseif i == 2 then
            -- Separator: full border color.
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                end_col = #line,
                hl_group = "PiTableBorder",
            })
        else
            -- Data rows: border color on │ only.
            highlight_table_pipes(self._buf, ns, row, line)
        end
    end
end

---@param msg string
---@param timestamp? number
---@param image_count? integer
---@param queue_type? "steer"|"follow_up"
function History:add_user_message(msg, timestamp, image_count, queue_type)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_begin_conversation_content()
        local label = " " .. Config.options.ui.labels.user_message .. " "
        local has_message_text = msg ~= ""
        local msg_lines = has_message_text and vim.split(msg, "\n", { plain = true }) or {}
        -- Treesitter highlights fenced code blocks — an unclosed fence bleeds
        -- into everything below. We track fence parity and auto-close if odd.
        local fences = 0
        for _, line in ipairs(msg_lines) do
            if line:match("^```") then
                fences = fences + 1
            end
        end
        if fences % 2 == 1 then
            msg_lines[#msg_lines + 1] = "```"
        end
        local time = timestamp or (os.time() * 1000)
        local time_str = format_time(time)
        local queue_tag = ""
        if queue_type == "steer" then
            queue_tag = "  " .. Config.options.ui.labels.steer_message
        elseif queue_type == "follow_up" then
            queue_tag = "  " .. Config.options.ui.labels.follow_up_message
        end
        local label_line = label .. time_str .. queue_tag
        local lines = { "", label_line }
        vim.list_extend(lines, msg_lines)
        if image_count and image_count > 0 then
            local info = format_attachment_info(image_count)
            lines[#lines + 1] = ""
            lines[#lines + 1] = info
        end
        local start = self:_append_lines(lines)
        local label_row = start + 1
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
            end_col = #label,
            hl_group = "PiUserMessageLabel",
        })
        local time_end = #label + #time_str
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, #label, {
            end_col = time_end,
            hl_group = "PiMessageDateTime",
        })
        if queue_tag ~= "" then
            vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, time_end, {
                end_col = time_end + #queue_tag,
                hl_group = "PiMessageQueueTag",
            })
        end
        if image_count and image_count > 0 then
            local info_row = start + #lines - 1
            local info_text = lines[#lines]
            vim.api.nvim_buf_set_extmark(self._buf, ns, info_row, 0, {
                end_col = #info_text,
                hl_group = "PiMessageAttachments",
            })
        end
        self:_scroll_to_bottom()
    end)
end

---@param timestamp? number
function History:on_agent_start(timestamp)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_begin_conversation_content()
        self._agent_start_time = vim.uv.hrtime() / 1e9
        self._first_delta = true
        self._needs_separator = false
        self._last_was_inline = false
        self:_pick_spinner()
        local label = " " .. Config.options.ui.labels.agent_response .. " "
        local time = timestamp or (os.time() * 1000)
        local time_str = format_time(time)
        local label_line = label .. time_str
        local start = self:_append_lines({ "", label_line, "" })
        local label_row = start + 1
        self._last_agent_response_extmark_id = vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {})
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
            end_col = #label,
            hl_group = "PiAgentResponseLabel",
        })
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, #label, {
            end_col = #label_line,
            hl_group = "PiMessageDateTime",
        })
        self._agent_text_start_row = start + 2
    end)
end

---@param delta string
function History:on_text_delta(delta)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        if self._first_delta then
            self._first_delta = false
            delta = delta:gsub("^\n+", "")
            if delta == "" then
                return
            end
        end
        if self._needs_separator then
            self._needs_separator = false
            self:_append_lines({ "", "" })
        end
        self._last_was_inline = false
        for _ in delta:gmatch("```") do
            self._fence_open = not self._fence_open
        end
        self:_append_text(delta)
    end)
end

---@param done_verb? string
---@param opts? { force_completion?: boolean }
function History:on_agent_end(done_verb, opts)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        -- Agent may stop mid-stream with an open fence (see _fence_open tracking
        -- in on_agent_delta). Close it so highlighting doesn't bleed.
        if self._fence_open then
            self:_append_text("\n```")
            self._fence_open = false
        end
        -- Render markdown tables in the agent response text.
        if self._agent_text_start_row then
            local scan_end = vim.api.nvim_buf_line_count(self._buf) - 1
            self:_render_tables(self._agent_text_start_row, scan_end)
            self._agent_text_start_row = nil
        end
        if not self._agent_start_time then
            return
        end
        local elapsed = vim.uv.hrtime() / 1e9 - self._agent_start_time
        local secs = math.floor(elapsed)
        self._agent_start_time = nil
        local force_completion = opts and opts.force_completion == true
        if secs < 1 and not force_completion then
            return
        end
        local verb = done_verb or "Completed"
        local text
        if secs >= 60 then
            text = verb .. " in " .. math.floor(secs / 60) .. "m " .. (secs % 60) .. "s"
        elseif secs >= 1 then
            text = verb .. " in " .. secs .. "s"
        else
            text = verb .. " in <1s"
        end
        local start = self:_append_lines({ "", text })
        vim.api.nvim_buf_set_extmark(self._buf, ns, start + 1, 0, {
            end_col = #text,
            hl_group = "PiBusyTime",
        })
    end)
end

---@param error_message string
---@param opts? pi.ChatErrorOpts
function History:on_error(error_message, opts)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        local icon = Config.options.ui.labels.error
        local error_lines = vim.split(error_message, "\n", { plain = true })
        local indent = string.rep(" ", vim.fn.strdisplaywidth(icon) + 1)
        error_lines[1] = icon .. " " .. error_lines[1]
        for i = 2, #error_lines do
            error_lines[i] = indent .. error_lines[i]
        end

        local lines = {}
        if opts and opts.pad_top then
            lines[#lines + 1] = ""
        end
        local first_error_row = #lines + 1
        for _, line in ipairs(error_lines) do
            lines[#lines + 1] = line
        end
        if opts and opts.pad_bottom then
            lines[#lines + 1] = ""
        end

        local start = self:_append_lines(lines)
        for i, line in ipairs(error_lines) do
            vim.api.nvim_buf_set_extmark(self._buf, ns, start + first_error_row + i - 2, 0, {
                end_col = #line,
                hl_group = "PiError",
            })
        end
        self:_maybe_scroll()
    end)
end

---@param error_message string
---@param timestamp integer
---@param opts? pi.ChatErrorOpts
function History:_append_system_error_block(error_message, timestamp, opts)
    local label = " " .. Config.options.ui.labels.system_error .. " "
    local time_str = format_time(timestamp)
    local label_line = label .. time_str
    local error_lines = vim.split(error_message, "\n", { plain = true })

    local lines = {}
    if opts and opts.pad_top then
        lines[#lines + 1] = ""
    end
    local label_row_offset = #lines
    lines[#lines + 1] = label_line
    for _, line in ipairs(error_lines) do
        lines[#lines + 1] = line
    end
    if opts and opts.pad_bottom then
        lines[#lines + 1] = ""
    end

    local start = self:_append_lines(lines)
    local label_row = start + label_row_offset
    vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
        end_col = #label,
        hl_group = "PiStartupErrorLabel",
        priority = STARTUP_HL_PRIORITY,
    })
    vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, #label, {
        end_col = #label_line,
        hl_group = "PiMessageDateTime",
        priority = STARTUP_HL_PRIORITY,
    })
    for i, line in ipairs(error_lines) do
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row + i, 0, {
            end_col = #line,
            hl_group = "PiStartupError",
            priority = STARTUP_HL_PRIORITY,
        })
    end
    self:_maybe_scroll()
end

---@param sections table[]
---@return pi.StartupSection[]
function History:_normalize_startup_sections(sections)
    local normalized = {} ---@type pi.StartupSection[]
    for _, section in ipairs(sections or {}) do
        local header = section.header or section.title
        local items = section.items or section.lines or {}
        if type(header) == "string" and type(items) == "table" then
            local normalized_items = {} ---@type string[]
            for _, item in ipairs(items) do
                if type(item) == "string" then
                    normalized_items[#normalized_items + 1] = item
                end
            end
            if #normalized_items > 0 then
                normalized[#normalized + 1] = {
                    header = header,
                    items = normalized_items,
                    hl = section.hl,
                }
            end
        end
    end
    return normalized
end

function History:_begin_conversation_content()
    if self._has_conversation_content then
        return
    end
    self._has_conversation_content = true
    self:clear_placeholder()
end

--- Build the welcome header used by both compact and expanded startup views.
---@return string[], pi.HighlightMark[]
function History:_build_startup_header()
    local lines = {} ---@type string[]
    local marks = {} ---@type pi.HighlightMark[]

    -- Welcome lines (always shown)
    local label = " " .. Config.options.ui.labels.agent_response .. " "
    local body = "  Hi! Ask me anything or describe what you'd like to build."
    local hint_prefix = "     Use "
    local mention = "@file"
    local hint_middle = " to mention files or "
    local command = "/command"
    local hint_suffix = " for shortcuts."

    lines[#lines + 1] = ""
    lines[#lines + 1] = label .. body
    local welcome_row = #lines - 1
    marks[#marks + 1] = { row = welcome_row, col_start = 0, col_end = #label, hl = "PiAgentResponseLabel" }
    marks[#marks + 1] = { row = welcome_row, col_start = #label, col_end = #lines[#lines], hl = "PiWelcome" }

    lines[#lines + 1] = ""
    local hint_line = hint_prefix .. mention .. hint_middle .. command .. hint_suffix
    lines[#lines + 1] = hint_line
    local hint_row = #lines - 1
    local col = 0
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #hint_prefix, hl = "PiWelcomeHint" }
    col = col + #hint_prefix
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #mention, hl = "PiMention" }
    col = col + #mention
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #hint_middle, hl = "PiWelcomeHint" }
    col = col + #hint_middle
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #command, hl = "PiCommand" }
    col = col + #command
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #hint_suffix, hl = "PiWelcomeHint" }

    lines[#lines + 1] = ""

    return lines, marks
end

--- Build the compact (collapsed) startup block: header + summary line.
---@return string[], pi.HighlightMark[]
function History:_build_compact_startup()
    local lines, marks = self:_build_startup_header()

    -- Build summary from known categories; count startup announcement sections separately.
    local known_headers = { ["[Skills]"] = "skills", ["[Prompts]"] = "prompts", ["[Extensions]"] = "extensions" }
    local parts = {} ---@type string[]
    local announcement_count = 0
    for _, section in ipairs(self._startup_sections) do
        local label = known_headers[section.header]
        if label then
            parts[#parts + 1] = #section.items .. " " .. label
        else
            announcement_count = announcement_count + 1
        end
    end
    if announcement_count > 0 then
        parts[#parts + 1] = announcement_count
            .. " extension"
            .. (announcement_count > 1 and "s" or "")
            .. " reported startup info"
    end
    local summary = "     Loaded resources: " .. table.concat(parts, ", ")
    lines[#lines + 1] = summary
    marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #summary, hl = "PiStartupDetail" }

    local hint = "     Run :PiToggleStartupDetails to expand the details or focus this block and hit Tab"
    lines[#lines + 1] = hint
    marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #hint, hl = "PiStartupHint" }

    return lines, marks
end

--- Build the expanded startup block: header + full section listing.
---@return string[], pi.HighlightMark[]
function History:_build_expanded_startup()
    local lines, marks = self:_build_startup_header()

    local intro = "     Loaded resources:"
    lines[#lines + 1] = intro
    marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #intro, hl = "PiStartupDetail" }

    for _, section in ipairs(self._startup_sections) do
        lines[#lines + 1] = ""
        local header_line = "     " .. section.header
        lines[#lines + 1] = header_line
        marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #header_line, hl = "PiStartupDetail" }
        for _, item in ipairs(section.items) do
            local item_line = "     " .. item
            lines[#lines + 1] = item_line
            marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #item_line, hl = "PiStartupDetail" }
        end
    end

    return lines, marks
end

--- Build error lines/marks for startup errors.
---@param base_row integer row offset for marks
---@return string[], pi.HighlightMark[]
function History:_build_startup_error_lines(base_row)
    local lines = {} ---@type string[]
    local marks = {} ---@type pi.HighlightMark[]
    for _, entry in ipairs(self._startup_errors) do
        if base_row + #lines > 0 then
            lines[#lines + 1] = ""
        end
        local label = " " .. Config.options.ui.labels.system_error .. " "
        local time_str = format_time(entry.timestamp)
        local label_line = label .. time_str
        lines[#lines + 1] = label_line
        marks[#marks + 1] = {
            row = base_row + #lines - 1,
            col_start = 0,
            col_end = #label,
            hl = "PiStartupErrorLabel",
        }
        marks[#marks + 1] = {
            row = base_row + #lines - 1,
            col_start = #label,
            col_end = #label_line,
            hl = "PiMessageDateTime",
        }
        local error_lines = vim.split(entry.message, "\n", { plain = true })
        for _, line in ipairs(error_lines) do
            lines[#lines + 1] = line
            marks[#marks + 1] = {
                row = base_row + #lines - 1,
                col_start = 0,
                col_end = #line,
                hl = "PiStartupError",
            }
        end
    end
    return lines, marks
end

--- Write lines and highlight marks into the buffer, replacing the startup block region.
---@param lines string[]
---@param marks pi.HighlightMark[]
---@param scroll_to_bottom boolean
function History:_apply_startup_block(lines, marks, scroll_to_bottom)
    local start_row = 0
    local old_count = self._startup_block_line_count
    if old_count > 0 then
        vim.api.nvim_buf_clear_namespace(self._buf, ns, start_row, start_row + old_count)
    end
    self:_with_modifiable(function()
        if #lines == 0 then
            if old_count == 0 then
                return
            end
            local line_count = vim.api.nvim_buf_line_count(self._buf)
            if start_row == 0 and line_count == old_count then
                vim.api.nvim_buf_set_lines(self._buf, 0, old_count, false, { "" })
            else
                vim.api.nvim_buf_set_lines(self._buf, start_row, start_row + old_count, false, {})
            end
            return
        end

        if old_count > 0 then
            vim.api.nvim_buf_set_lines(self._buf, start_row, start_row + old_count, false, lines)
            return
        end

        local line_count = vim.api.nvim_buf_line_count(self._buf)
        local first = vim.api.nvim_buf_get_lines(self._buf, 0, 1, false)[1]
        if start_row == 0 and line_count == 1 and first == "" then
            vim.api.nvim_buf_set_lines(self._buf, 0, 1, false, lines)
        else
            vim.api.nvim_buf_set_lines(self._buf, start_row, start_row, false, lines)
        end
    end)

    self._startup_block_line_count = #lines
    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(self._buf, ns, start_row + mark.row, mark.col_start, {
            end_col = mark.col_end,
            hl_group = mark.hl,
            priority = STARTUP_HL_PRIORITY,
        })
    end
    self:_update_status_extmark()
    if scroll_to_bottom then
        self:_scroll_to_bottom()
    end
end

function History:_render_startup_block(scroll_to_bottom)
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end

    -- Build and cache both views. Compact/expanded only differ when sections exist.
    if #self._startup_sections > 0 then
        self._startup_block_compact_lines, self._startup_block_compact_marks = self:_build_compact_startup()
        self._startup_block_expanded_lines, self._startup_block_expanded_marks = self:_build_expanded_startup()
    else
        self._startup_block_compact_lines = nil
        self._startup_block_compact_marks = nil
        self._startup_block_expanded_lines = nil
        self._startup_block_expanded_marks = nil
    end

    -- Pick active view. Always start with the welcome header.
    local lines, marks
    if self._startup_block_expanded and self._startup_block_expanded_lines then
        lines = vim.deepcopy(self._startup_block_expanded_lines)
        marks = vim.deepcopy(self._startup_block_expanded_marks)
    elseif self._startup_block_compact_lines then
        lines = vim.deepcopy(self._startup_block_compact_lines)
        marks = vim.deepcopy(self._startup_block_compact_marks)
    else
        lines, marks = self:_build_startup_header()
        if not self._startup_loaded then
            -- Still waiting for startup data — show loading hint.
            local loading = "     Loading resources…"
            lines[#lines + 1] = loading
            marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #loading, hl = "PiStartupHint" }
        end
    end

    -- Append startup errors after the startup block.
    if #self._startup_errors > 0 then
        local err_lines, err_marks = self:_build_startup_error_lines(#lines)
        vim.list_extend(lines, err_lines)
        vim.list_extend(marks, err_marks)
    end

    self:_apply_startup_block(lines, marks, scroll_to_bottom)
end

--- Toggle the startup block between compact and expanded.
--- With check_cursor=true (default), only toggles if the cursor is on the block.
--- With check_cursor=false, toggles unconditionally (for commands).
---@param check_cursor? boolean default true
---@return boolean toggled true if the block was toggled
function History:toggle_startup_block(check_cursor)
    if not self._startup_block_compact_lines or not self._startup_block_expanded_lines then
        return false
    end
    if check_cursor ~= false then
        local win = self:win()
        if not win then
            return false
        end
        local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed
        local end_row = self._startup_block_line_count
        if cursor_row >= end_row then
            return false
        end
    end
    self._startup_block_expanded = not self._startup_block_expanded
    self:_render_startup_block(false)
    return true
end

---@param error_message string
---@param opts? pi.ChatErrorOpts
function History:on_system_error(error_message, opts)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        local timestamp = now_ms()
        if not self._has_conversation_content then
            self._startup_errors[#self._startup_errors + 1] = {
                message = error_message,
                timestamp = timestamp,
            }
            if self._placeholder_mode == "loading" then
                self:clear_placeholder()
            end
            self:_render_startup_block(true)
            return
        end
        self:_append_system_error_block(error_message, timestamp, opts)
    end)
end

---@param opts { sections: pi.StartupSection[], errors?: pi.SystemErrorEntry[] }
function History:show_startup_block(opts)
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    self._startup_sections = self:_normalize_startup_sections(opts.sections)
    self._startup_loaded = true
    self._startup_errors = vim.deepcopy(opts.errors or {})
    if #self._startup_sections > 0 then
        self._startup_timestamp = self._startup_timestamp or now_ms()
    else
        self._startup_timestamp = nil
    end
    if not self._has_conversation_content and self._placeholder_mode == "loading" then
        self:clear_placeholder()
    end
    self:_render_startup_block(#self._startup_errors > 0 and not self._has_conversation_content)
end

--- Render a custom block inline in the history.
--- Each line is an array of chunks: { {text, hl?}, ... }.
---@param block pi.CustomBlock
function History:append_custom_block(block)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        if not block.content or #block.content == 0 then
            return
        end
        for _, line_chunks in ipairs(block.content) do
            -- Build the plain text for the buffer line
            local parts = {} ---@type string[]
            for _, chunk in ipairs(line_chunks) do
                parts[#parts + 1] = chunk[1] or ""
            end
            local text = table.concat(parts)
            local row = self:_append_lines({ text })

            -- Apply chunk highlights
            local col = 0
            for _, chunk in ipairs(line_chunks) do
                local chunk_text = chunk[1] or ""
                local hl = chunk[2]
                if hl and #chunk_text > 0 then
                    vim.api.nvim_buf_set_extmark(self._buf, ns, row, col, {
                        end_col = col + #chunk_text,
                        hl_group = hl,
                    })
                end
                col = col + #chunk_text
            end
        end
    end)
end

---@param tool_name string
---@param tool_call_id string
---@param tool_input? table
function History:on_tool_start(tool_name, tool_call_id, tool_input)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_begin_conversation_content()
        self._needs_separator = false
        local icon = Config.options.ui.labels.tool
        local renderer = Tools.get_renderer(tool_name)

        -- Inline tools render as a single line: icon + tool_name + detail
        if renderer.inline then
            local detail = renderer.inline_text and renderer.inline_text(tool_input) or nil
            local line = icon .. " " .. tool_name .. (detail and ("  " .. detail) or "")

            -- Skip blank line between consecutive inline tools
            local need_gap = not self._last_was_inline
            local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
            local cur = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
            local lines = (cur == "" or not need_gap) and { line } or { "", line }
            local start = self:_append_lines(lines)
            local row = lines[1] == "" and start + 1 or start

            Tools.set_border(self, row, Tools.GLYPHS.MID)
            local icon_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                end_col = #icon,
                hl_group = "PiToolHeader",
            })
            -- Tool name
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, #icon, {
                end_col = #icon + 1 + #tool_name,
                hl_group = "PiToolHeader",
            })
            -- Detail (path etc.) in subdued color
            if detail then
                local detail_start = #icon + 1 + #tool_name + 2
                vim.api.nvim_buf_set_extmark(self._buf, ns, row, detail_start, {
                    end_col = #line,
                    hl_group = "PiToolCall",
                })
            end

            if tool_call_id then
                self._tool_blocks[tool_call_id] = {
                    tool_name = tool_name,
                    icon_extmark = icon_extmark,
                    tool_input = tool_input,
                    inline = true,
                }
            end

            self._last_was_inline = true
            self:_update_status_extmark()
            self:_maybe_scroll()
            return
        end

        self._last_was_inline = false

        -- Standard multi-line tool block
        local header = icon .. " " .. tool_name

        local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
        local cur = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
        local lines = cur == "" and { header } or { "", header }
        local start = self:_append_lines(lines)
        local header_row = lines[1] == "" and start + 1 or start

        Tools.set_border(self, header_row, Tools.GLYPHS.TOP)
        local icon_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, 0, {
            end_col = #icon,
            hl_group = "PiToolHeader",
        })
        vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, #icon, {
            end_col = #header,
            hl_group = "PiToolHeader",
        })

        if renderer.on_start then
            renderer.on_start(self, tool_input)
        end

        if tool_call_id then
            -- tail_extmark marks the last row of the block after on_start.
            -- on_tool_end uses it to insert output at the right position
            -- when multiple tools run in parallel.
            local tail_row = vim.api.nvim_buf_line_count(self._buf) - 1
            self._tool_blocks[tool_call_id] = {
                tool_name = tool_name,
                icon_extmark = icon_extmark,
                tail_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, tail_row, 0, {}),
                tool_input = tool_input,
                expanded = true,
            }
        end
    end)
end

---@param tool_name string
---@param tool_call_id string
---@param result? table
---@param is_error? boolean
function History:on_tool_end(tool_name, tool_call_id, result, is_error)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end

        local should_scroll = self:_should_auto_scroll()

        local block = tool_call_id and self._tool_blocks[tool_call_id]

        -- Guard: skip if this tool already finished (race between
        -- tool_execution_end and mark_pending_tools_errored, both scheduled).
        if block and block.finished then
            return
        end
        if block then
            block.finished = true
        end

        -- Inline tools: append status indicator to the existing line
        if block and block.inline then
            local labels = Config.options.ui.labels
            local status = Tools.resolve_status(result, is_error)
            local is_success = status == "completed"
            local icon_hl = is_success and "PiToolHeader" or "PiToolError"
            local status_icon = is_success and labels.tool_success or labels.tool_failure
            local status_hl = is_success and "PiToolStatus" or "PiToolError"

            -- Update icon color
            local icon = Config.options.ui.labels.tool
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.icon_extmark, {})
            if not pos[1] then
                return
            end
            vim.api.nvim_buf_set_extmark(self._buf, ns, pos[1], 0, {
                id = block.icon_extmark,
                end_col = #icon,
                hl_group = icon_hl,
            })

            -- Append status as virtual text at end of line
            local renderer = Tools.get_renderer(tool_name)
            local extra = renderer.inline_status and renderer.inline_status(result, is_error) or nil
            local row = pos[1]
            local line = vim.api.nvim_buf_get_lines(self._buf, row, row + 1, false)[1] or ""
            local virt = {}
            if extra then
                virt[#virt + 1] = { " " .. extra, "PiToolStatus" }
            end
            virt[#virt + 1] = { "  " .. status_icon, status_hl }
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, #line, {
                virt_text = virt,
                virt_text_pos = "inline",
            })

            self._needs_separator = true
            self:_update_status_extmark()
            if should_scroll then
                self:_scroll_to_bottom()
            end
            return
        end

        -- Compute insertion point: after the tool block's on_start content.
        -- When tools run in parallel, multiple headers are appended before
        -- any on_tool_end fires, so we must insert output at the correct
        -- position rather than appending at the buffer end.
        local insert_at ---@type integer?
        if block and block.tail_extmark then
            local tail_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.tail_extmark, {})
            if tail_pos[1] then
                insert_at = tail_pos[1] + 1
            end
        end

        local output_start = insert_at or vim.api.nvim_buf_line_count(self._buf)

        local renderer = Tools.get_renderer(tool_name)
        if renderer.on_end then
            insert_at = renderer.on_end(self, block and block.tool_input, result, is_error, insert_at)
        end

        -- Mark the first output line (if renderer.on_end added anything)
        local output_end = insert_at or vim.api.nvim_buf_line_count(self._buf)
        if block and output_end > output_start then
            block.output_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, output_start, 0, {})
        end

        local labels = Config.options.ui.labels
        local status = Tools.resolve_status(result, is_error)
        local is_success = status == "completed"
        local footer = is_success and (labels.tool_success .. " completed") or (labels.tool_failure .. " " .. status)
        local footer_hl = is_success and "PiToolStatus" or "PiToolError"
        local start
        if insert_at then
            start, insert_at = self:_insert_lines(insert_at, { footer })
        else
            start = self:_append_lines({ footer })
        end
        Tools.set_border(self, start, Tools.GLYPHS.BOT)
        local footer_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, start, 0, {
            end_col = #footer,
            hl_group = footer_hl,
        })

        if block then
            local icon_hl = is_success and "PiToolHeader" or "PiToolError"
            local icon = Config.options.ui.labels.tool
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.icon_extmark, {})
            if pos[1] then
                vim.api.nvim_buf_set_extmark(self._buf, ns, pos[1], 0, {
                    id = block.icon_extmark,
                    end_col = #icon,
                    hl_group = icon_hl,
                })
            end
            block.end_extmark = footer_extmark
            block.expanded = true
            self:_maybe_collapse_tool(tool_call_id)
        end

        self._needs_separator = true

        if should_scroll then
            self:_scroll_to_bottom()
        end
    end)
end

--- Collapse a tool block based on per-renderer visible line thresholds.
---@param tool_call_id string
function History:_maybe_collapse_tool(tool_call_id)
    local block = self._tool_blocks[tool_call_id]
    if not block or not block.end_extmark then
        return
    end

    local header_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.icon_extmark, {})
    local footer_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.end_extmark, {})
    local header_row = header_pos[1]
    local footer_row = footer_pos[1]
    if not header_row or not footer_row then
        return
    end
    local inner_start = header_row + 1

    local renderer = Tools.get_renderer(block.tool_name)
    local input_vis = renderer.input_visible or math.huge
    local output_vis = renderer.output_visible or math.huge

    local input_lines, output_lines, has_output = Tools.extract_tool_sections(self, block)
    -- Subtract border glyph width so truncation accounts for inline virt_text
    local win_width = self._win and vim.api.nvim_win_is_valid(self._win) and vim.api.nvim_win_get_width(self._win) or 0
    local border_w = vim.fn.strdisplaywidth(Tools.GLYPHS.MID)
    local gutters = (self._win and vim.wo[self._win].foldcolumn or "0")
    local gutter_w = tonumber(gutters) or 0
    local max_width = win_width > 0 and (win_width - border_w - gutter_w - border_w) or 0
    if not Tools.should_collapse(input_lines, output_lines, input_vis, output_vis, max_width) then
        return
    end
    local collapsed, specs =
        Tools.build_collapsed_view(input_lines, output_lines, has_output, input_vis, output_vis, max_width)

    -- Save expanded state
    block.expanded_inner_lines = vim.api.nvim_buf_get_lines(self._buf, inner_start, footer_row, false)
    block.expanded_inner_extmarks = capture_extmarks(self._buf, ns, inner_start, footer_row - 1)
    block.collapsed_inner_lines = collapsed
    block.collapsed_specs = specs

    -- Replace inner content
    vim.api.nvim_buf_clear_namespace(self._buf, ns, inner_start, footer_row)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, inner_start, footer_row, false, collapsed)
    end)
    Tools.apply_collapsed_extmarks(self, inner_start, specs, collapsed)

    block.expanded = false
end

--- Toggle expand/collapse for the tool block under the cursor.
---@return boolean toggled true if a tool block was toggled
function History:toggle_tool_block()
    local win = self:win()
    if not win then
        return false
    end
    local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed

    -- Find the block containing the cursor
    local target_block
    for _, block in pairs(self._tool_blocks) do
        if block.end_extmark and block.collapsed_inner_lines then
            local h = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.icon_extmark, {})[1]
            local f = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.end_extmark, {})[1]
            if cursor_row >= h and cursor_row <= f then
                target_block = block
                break
            end
        end
    end

    if not target_block then
        return false
    end

    local header_row = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, target_block.icon_extmark, {})[1]
    local footer_row = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, target_block.end_extmark, {})[1]
    local inner_start = header_row + 1

    vim.api.nvim_buf_clear_namespace(self._buf, ns, inner_start, footer_row)
    self:_with_modifiable(function()
        if target_block.expanded then
            vim.api.nvim_buf_set_lines(self._buf, inner_start, footer_row, false, target_block.collapsed_inner_lines)
            Tools.apply_collapsed_extmarks(
                self,
                inner_start,
                target_block.collapsed_specs,
                target_block.collapsed_inner_lines
            )
            target_block.expanded = false
        else
            vim.api.nvim_buf_set_lines(self._buf, inner_start, footer_row, false, target_block.expanded_inner_lines)
            restore_extmarks(self._buf, ns, inner_start, target_block.expanded_inner_extmarks)
            target_block.expanded = true
        end
    end)
    return true
end

---@param tool_name string
---@param tool_call_id string
---@param msg table
function History:on_tool_update(tool_name, tool_call_id, msg) end

--- Mark all pending (unfinished) tool blocks as errored.
--- Called on message_end when the assistant message was aborted or errored,
--- mirroring TUI behaviour that closes out hanging tool blocks.
---@param error_message string
function History:mark_pending_tools_errored(error_message)
    ---@type { id: string, name: string }[]
    local pending = {}
    for id, block in pairs(self._tool_blocks) do
        if not block.finished then
            pending[#pending + 1] = { id = id, name = block.tool_name }
        end
    end
    if #pending == 0 then
        return
    end
    local error_result = { content = { { type = "text", text = error_message } } }
    for _, p in ipairs(pending) do
        self:on_tool_end(p.name, p.id, error_result, true)
    end
end

function History:on_thinking_start()
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self._is_thinking = true
        local label = Config.options.ui.labels.thinking
        local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
        local anchor = vim.api.nvim_buf_set_extmark(self._buf, ns, last_line, 0, {
            right_gravity = false,
        })
        self._thinking_accum = {
            lines = { "" },
            anchor = anchor,
            start_time = vim.uv.hrtime() / 1e9,
            buf_lines = 0,
        }
        if self._show_thinking then
            local header_text = label .. " Thinking…"
            local block = { "", header_text, "", "" }
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, anchor, {})
            local row = pos[1]
            self:_with_modifiable(function()
                vim.api.nvim_buf_set_lines(self._buf, row, row, false, block)
            end)
            self:_apply_thinking_hl(row + 1, 1)
            self._thinking_accum.buf_lines = 4
        end
        self:_update_status_extmark()
        self:_maybe_scroll()
    end)
end

---@param delta string
function History:on_thinking_delta(delta)
    vim.schedule(function()
        if not self._thinking_accum then
            return
        end
        local parts = vim.split(delta, "\n", { plain = true })
        self._thinking_accum.lines[#self._thinking_accum.lines] = self._thinking_accum.lines[#self._thinking_accum.lines]
            .. parts[1]
        for i = 2, #parts do
            self._thinking_accum.lines[#self._thinking_accum.lines + 1] = parts[i]
        end

        if not self._show_thinking then
            return
        end
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, self._thinking_accum.anchor, {})
        local anchor_row = pos[1]
        local insert_row = anchor_row + self._thinking_accum.buf_lines - 1
        self:_with_modifiable(function()
            local last_content_row = insert_row - 1
            local cur = vim.api.nvim_buf_get_lines(self._buf, last_content_row, last_content_row + 1, false)[1] or ""
            vim.api.nvim_buf_set_text(self._buf, last_content_row, #cur, last_content_row, #cur, { parts[1] })
            if #parts > 1 then
                local new_lines = {}
                for i = 2, #parts do
                    new_lines[#new_lines + 1] = parts[i]
                end
                vim.api.nvim_buf_set_lines(self._buf, insert_row, insert_row, false, new_lines)
                self._thinking_accum.buf_lines = self._thinking_accum.buf_lines + #new_lines
            end
        end)
        local content_start = anchor_row + 2
        local content_count = self._thinking_accum.buf_lines - 3
        if content_count > 0 then
            self:_apply_thinking_hl(content_start, content_count)
        end
        self:_update_status_extmark()
        self:_maybe_scroll()
    end)
end

function History:on_thinking_end()
    vim.schedule(function()
        if not self._thinking_accum or not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self._is_thinking = false
        local elapsed = math.floor(vim.uv.hrtime() / 1e9 - self._thinking_accum.start_time)
        local header
        if elapsed >= 60 then
            header = "Thought for " .. math.floor(elapsed / 60) .. "m " .. (elapsed % 60) .. "s"
        else
            header = "Thought for " .. elapsed .. "s"
        end

        local visible = self._show_thinking
        local line_count

        if visible then
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, self._thinking_accum.anchor, {})
            local header_row = pos[1] + 1
            local label = Config.options.ui.labels.thinking
            local header_text = label .. " " .. header
            self:_with_modifiable(function()
                vim.api.nvim_buf_set_lines(self._buf, header_row, header_row + 1, false, { header_text })
            end)
            self:_apply_thinking_hl(header_row, 1)
            line_count = self._thinking_accum.buf_lines
        else
            local block_lines = self:_build_thinking_block(header, self._thinking_accum.lines)
            line_count = #block_lines
        end

        self._thinking_blocks[#self._thinking_blocks + 1] = {
            header = header,
            lines = self._thinking_accum.lines,
            anchor = self._thinking_accum.anchor,
            line_count = line_count,
            visible = visible,
        }
        self._thinking_accum = nil
        self:_update_status_extmark()
    end)
end

function History:toggle_thinking()
    vim.schedule(function()
        self._show_thinking = not self._show_thinking
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        for _, block in ipairs(self._thinking_blocks) do
            if self._show_thinking and not block.visible then
                local block_lines = self:_build_thinking_block(block.header, block.lines)
                self:_insert_thinking_block(block_lines, block.anchor)
                block.line_count = #block_lines
                block.visible = true
            elseif not self._show_thinking and block.visible then
                self:_remove_thinking_block(block.line_count, block.anchor)
                block.visible = false
            end
        end
    end)
end

---@return boolean
function History:has_conversation_content()
    return self._has_conversation_content
end

--- Show a placeholder message (virtual text) on the history buffer.
--- Replaces any existing placeholder.
---@param virt_lines table[] virt_lines spec for nvim_buf_set_extmark
---@param opts? { force?: boolean, mode?: "loading" }
function History:set_placeholder(virt_lines, opts)
    self:clear_placeholder()
    if not (opts and opts.force) then
        local line_count = vim.api.nvim_buf_line_count(self._buf)
        if line_count ~= 1 then
            return
        end
        local first = vim.api.nvim_buf_get_lines(self._buf, 0, 1, false)[1]
        if first ~= "" then
            return
        end
    end
    self._placeholder_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, 0, 0, {
        virt_lines = virt_lines,
    })
    self._placeholder_mode = opts and opts.mode or nil
end

---@param virt_lines table[]
function History:show_loading_placeholder(virt_lines)
    self:set_placeholder(virt_lines, { mode = "loading" })
end

--- Remove the placeholder message if present.
function History:clear_placeholder()
    if not self._placeholder_extmark then
        self._placeholder_mode = nil
        return
    end
    pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, self._placeholder_extmark)
    self._placeholder_extmark = nil
    self._placeholder_mode = nil
end

--- Add a message to the pending queue (displayed as virtual text at the bottom).
---@param queue_type "steer"|"follow_up"
---@param display_text string raw user text (for display)
---@param expanded_text string expanded text (for matching on delivery)
---@param image_count? integer
function History:add_pending_queue_entry(queue_type, display_text, expanded_text, image_count)
    self._pending_queue[#self._pending_queue + 1] = {
        queue_type = queue_type,
        text = display_text,
        expanded_text = expanded_text,
        image_count = image_count,
    }
    self:_update_status_extmark()
    if self:_should_auto_scroll() then
        self:_scroll_to_bottom()
    end
end

--- Remove the first pending queue entry whose expanded_text matches.
--- Called when `message_start` arrives for a delivered steering/follow-up message.
---@param text string the user message text from the event
---@return pi.PendingQueueEntry? entry the removed entry, or nil if not found
function History:remove_pending_queue_entry(text)
    for i, entry in ipairs(self._pending_queue) do
        if entry.expanded_text == text then
            table.remove(self._pending_queue, i)
            self:_update_status_extmark()
            return entry
        end
    end
    return nil
end

--- Get a shallow copy of pending queue entries.
---@return pi.PendingQueueEntry[]
function History:get_pending_queue()
    return { unpack(self._pending_queue) }
end

--- Clear all pending queue entries.
function History:clear_pending_queue()
    if #self._pending_queue == 0 then
        return
    end
    self._pending_queue = {}
    self:_update_status_extmark()
end

function History:clear()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    if self._spinner_timer then
        self._spinner_timer:stop()
        self._spinner_timer:close()
        self._spinner_timer = nil
    end
    self._status_text = nil
    self._status_extmark_id = nil
    self._pending_queue = {}
    self._pending_queue_extmark_id = nil
    self._thinking_accum = nil
    self._thinking_blocks = {}
    self._tool_blocks = {}
    self._has_conversation_content = false
    self._startup_block_line_count = 0
    self._startup_block_expanded = Config.options.ui.expand_startup_details
    self._startup_block_expanded_lines = nil
    self._startup_block_expanded_marks = nil
    self._startup_block_compact_lines = nil
    self._startup_block_compact_marks = nil
    self._startup_timestamp = nil
    self._startup_sections = {}
    self._startup_loaded = false
    self._startup_errors = {}
    self:clear_placeholder()
    self._placeholder_mode = nil
    self._agent_text_start_row = nil
    self._last_agent_response_extmark_id = nil
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
    end)
end

return History
