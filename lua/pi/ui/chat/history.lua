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
local History = {}
History.__index = History

---@class pi.ToolBlock
---@field tool_name string
---@field icon_extmark integer
---@field output_extmark? integer
---@field end_extmark? integer
---@field tool_input? table
---@field inline? boolean
---@field expanded boolean
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

local Ft = require("pi.filetypes")
local Config = require("pi.config")
local Tools = require("pi.ui.chat.tools")

local ns = vim.api.nvim_create_namespace("pi-chat")

local SCROLL_THRESHOLD = 10

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
    if self._status_extmark_id then
        vim.api.nvim_buf_del_extmark(self._buf, ns, self._status_extmark_id)
        self._status_extmark_id = nil
    end
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
    local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
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

---@param msg string
---@param timestamp? number
---@param image_count? integer
function History:add_user_message(msg, timestamp, image_count)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        local label = " " .. Config.options.ui.labels.user_message .. " "
        local msg_lines = vim.split(msg, "\n", { plain = true })
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
        local label_line = label .. time_str
        local lines = { "", label_line }
        vim.list_extend(lines, msg_lines)
        if image_count and image_count > 0 then
            local icon = Config.options.ui.labels.attachments
            local info = image_count == 1 and (icon .. " 1 image attached")
                or (icon .. " %d images attached"):format(image_count)
            lines[#lines + 1] = ""
            lines[#lines + 1] = info
        end
        local start = self:_append_lines(lines)
        local label_row = start + 1
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
            end_col = #label,
            hl_group = "PiUserMessageLabel",
        })
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, #label, {
            end_col = #label_line,
            hl_group = "PiMessageDateTime",
        })
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
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
            end_col = #label,
            hl_group = "PiAgentResponseLabel",
        })
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, #label, {
            end_col = #label_line,
            hl_group = "PiMessageDateTime",
        })
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
        for _ in delta:gmatch("```") do
            self._fence_open = not self._fence_open
        end
        self:_append_text(delta)
    end)
end

---@param done_verb? string
function History:on_agent_end(done_verb)
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
        if not self._agent_start_time then
            return
        end
        local secs = math.floor(vim.uv.hrtime() / 1e9 - self._agent_start_time)
        self._agent_start_time = nil
        if secs < 1 then
            return
        end
        local verb = done_verb or "Completed"
        local text
        if secs >= 60 then
            text = verb .. " in " .. math.floor(secs / 60) .. "m " .. (secs % 60) .. "s"
        else
            text = verb .. " in " .. secs .. "s"
        end
        local start = self:_append_lines({ "", text })
        vim.api.nvim_buf_set_extmark(self._buf, ns, start + 1, 0, {
            end_col = #text,
            hl_group = "PiBusyTime",
        })
    end)
end

---@param error_message string
function History:on_error(error_message)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        local icon = Config.options.ui.labels.error
        local text = icon .. " " .. error_message
        local start = self:_append_lines({ text })
        vim.api.nvim_buf_set_extmark(self._buf, ns, start, 0, {
            end_col = #text,
            hl_group = "PiError",
        })
        self:_maybe_scroll()
    end)
end

---@param text string
function History:on_stderr(text)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        local label = " " .. Config.options.ui.labels.debug_message .. " "
        local time_str = format_time(os.time() * 1000)
        local label_line = label .. time_str
        local start = self:_append_lines({ "", label_line, text })
        local label_row = start + 1
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
            end_col = #label,
            hl_group = "PiDebugLabel",
        })
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, #label, {
            end_col = #label_line,
            hl_group = "PiMessageDateTime",
        })
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row + 1, 0, {
            end_col = #text,
            hl_group = "PiDebug",
        })
        self:_maybe_scroll()
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
            self._tool_blocks[tool_call_id] = {
                tool_name = tool_name,
                icon_extmark = icon_extmark,
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

        local pre_output_line = vim.api.nvim_buf_line_count(self._buf) - 1

        local renderer = Tools.get_renderer(tool_name)
        if renderer.on_end then
            renderer.on_end(self, block and block.tool_input, result, is_error)
        end

        -- Mark the first output line (if renderer.on_end added anything)
        local post_output_line = vim.api.nvim_buf_line_count(self._buf) - 1
        if block and post_output_line > pre_output_line then
            block.output_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, pre_output_line + 1, 0, {})
        end

        local labels = Config.options.ui.labels
        local status = Tools.resolve_status(result, is_error)
        local is_success = status == "completed"
        local footer = is_success and (labels.tool_success .. " completed") or (labels.tool_failure .. " " .. status)
        local footer_hl = is_success and "PiToolStatus" or "PiToolError"
        local start = self:_append_lines({ footer })
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
function History:toggle_tool_block()
    local win = self:win()
    if not win then
        return
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
        return
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
end

---@param tool_name string
---@param tool_call_id string
---@param msg table
function History:on_tool_update(tool_name, tool_call_id, msg) end

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
    self._thinking_accum = nil
    self._thinking_blocks = {}
    self._tool_blocks = {}
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
    end)
end

return History
