--- Configurable status line at the bottom of the prompt buffer.
--- Composed of named components arranged in left/right groups.
--- Renders padding virt_lines above the status to pin it to the window bottom.

--- Component function: receives state, returns either:
---   string, string?             — single chunk (text, optional hl)
---   table of {text, hl?} pairs  — multi-chunk with per-chunk highlights
---   nil                         — hidden (component not rendered)
---@alias pi.StatusLineComponentFn fun(state: pi.StatusLineState): string|string[][]|nil, string|nil

---@class pi.StatusLineState
---@field model_id string?
---@field model_context_window integer?
---@field model_reasoning boolean
---@field thinking_level string?
---@field context_tokens integer?
---@field total_input integer
---@field total_output integer
---@field total_cache_read integer
---@field total_cache_write integer
---@field total_cost number
---@field auto_compaction boolean
---@field extensions table<string, string> Extension status values set via setStatus

---@class pi.StatusLine
---@field _buf integer
---@field _tab pi.TabId
---@field _win_fn fun(): integer?
---@field _extmark_id integer?
---@field _virt_line_count integer
---@field _state pi.StatusLineState
local StatusLine = {}
StatusLine.__index = StatusLine

local Config = require("pi.config")
local Attention = require("pi.attention")

local ns = vim.api.nvim_create_namespace("pi-statusline")

-- Helpers

--- Format token count for display (e.g. 200000 -> "200k").
---@param count integer
---@return string
local function format_tokens(count)
    if count < 1000 then
        return tostring(count)
    elseif count < 9950 then
        return string.format("%.1fk", count / 1000)
    elseif count < 1000000 then
        return string.format("%dk", math.floor(count / 1000 + 0.5))
    elseif count < 9950000 then
        return string.format("%.1fM", count / 1000000)
    else
        return string.format("%dM", math.floor(count / 1000000 + 0.5))
    end
end

--- Get the text area width (excluding signcolumn, foldcolumn, number column).
---@param win integer
---@return integer
local function text_area_width(win)
    local info = vim.fn.getwininfo(win)
    if info and info[1] then
        return info[1].width - info[1].textoff
    end
    return vim.api.nvim_win_get_width(win)
end

--- Get status line config for a built-in component.
---@param name pi.StatusLineBuiltinName
---@return table
local function component_config(name)
    local components = ((Config.options.ui.statusline or {}).components or {})
    local cfg = components[name]
    return type(cfg) == "table" and cfg or {}
end

--- Normalize a component return value into chunks.
---@param result string|string[][]|nil
---@param hl string?
---@return string[][]?
local function normalize_chunks(result, hl)
    if result == nil then
        return nil
    end
    if type(result) == "table" then
        return result
    end
    return { { result, hl } }
end

--- Prefix a built-in component's first chunk with its configured icon.
---@param name pi.StatusLineBuiltinName
---@param chunks string[][]
---@return string[][]
local function prepend_icon(name, chunks)
    local icon = component_config(name).icon
    if type(icon) ~= "string" or icon == "" or #chunks == 0 then
        return chunks
    end
    local first = chunks[1][1]
    chunks[1] = { first == "" and icon or (icon .. " " .. first), chunks[1][2] }
    return chunks
end

-- Built-in Components

---@type table<string, pi.StatusLineComponentFn>
local builtin = {}

--- ↑3.8k ↓58k
function builtin.tokens(state)
    local parts = {}
    if state.total_input > 0 then
        parts[#parts + 1] = "↑" .. format_tokens(state.total_input)
    end
    if state.total_output > 0 then
        parts[#parts + 1] = "↓" .. format_tokens(state.total_output)
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " ")
end

--- R7.2M W416k
function builtin.cache(state)
    local parts = {}
    if state.total_cache_read > 0 then
        parts[#parts + 1] = "R" .. format_tokens(state.total_cache_read)
    end
    if state.total_cache_write > 0 then
        parts[#parts + 1] = "W" .. format_tokens(state.total_cache_write)
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " ")
end

--- $7.665
function builtin.cost(state)
    if state.total_cost <= 0 then
        return nil
    end
    local cfg = component_config("cost")
    local text = string.format("$%.3f", state.total_cost)
    if cfg.error and state.total_cost >= cfg.error then
        return text, "PiStatusLineError"
    elseif cfg.warn and state.total_cost >= cfg.warn then
        return text, "PiStatusLineWarning"
    end
    return text
end

--- 63.9%/200k or -/200k when context is unknown
function builtin.context(state)
    if not state.model_context_window or state.model_context_window <= 0 then
        return nil
    end
    local cfg = component_config("context")
    local total = format_tokens(state.model_context_window)
    if not state.context_tokens then
        return "-/" .. total
    end
    local pct = (state.context_tokens / state.model_context_window) * 100
    local text = string.format("%.1f%%/%s", pct, total)
    if cfg.error and pct > cfg.error then
        return text, "PiStatusLineError"
    elseif cfg.warn and pct > cfg.warn then
        return text, "PiStatusLineWarning"
    end
    return text
end

--- (auto)
function builtin.compaction(state)
    if state.auto_compaction then
        return "(auto)"
    end
    return nil
end

--- 󰵚 / 󰵚 2
---@param tab pi.TabId
---@return pi.StatusLineComponentFn
local function attention_component(tab)
    return function(_)
        local count = Attention.count(tab)
        if count <= 0 then
            return nil
        end

        local cfg = component_config("attention")
        if cfg.counter == true then
            return tostring(count), "PiStatusLineAttention"
        end

        if cfg.icon == false then
            return tostring(count), "PiStatusLineAttention"
        end

        return "", "PiStatusLineAttention"
    end
end

--- claude-opus-4-6
function builtin.model(state)
    if state.model_id then
        return state.model_id
    end
    return nil
end

--- xhigh / thinking off
function builtin.thinking(state)
    if not state.model_reasoning or not state.thinking_level then
        return nil
    end
    if state.thinking_level == "off" then
        return "thinking off"
    end
    return state.thinking_level
end

-- StatusLine

---@return pi.StatusLineState
local function new_state()
    return {
        model_id = nil,
        model_context_window = nil,
        model_reasoning = false,
        thinking_level = nil,
        context_tokens = nil,
        total_input = 0,
        total_output = 0,
        total_cache_read = 0,
        total_cache_write = 0,
        total_cost = 0,
        auto_compaction = false,
        extensions = {},
    }
end

---@param buf integer
---@param tab pi.TabId
---@param win_fn fun(): integer?
---@return pi.StatusLine
function StatusLine.new(buf, tab, win_fn)
    local self = setmetatable({}, StatusLine)
    self._buf = buf
    self._tab = tab
    self._win_fn = win_fn
    self._extmark_id = nil
    self._virt_line_count = 0
    self._state = new_state()
    self:render()
    return self
end

--- Number of virt_lines currently rendered (padding + status).
--- Used by Prompt:resize() to subtract padding from visual line count.
---@return integer
function StatusLine:virt_line_count()
    return self._virt_line_count
end

--- Update model, thinking level, auto-compaction from get_state response.
---@param data table
function StatusLine:update_state(data)
    local s = self._state
    local model = data.model
    if model then
        s.model_id = model.id
        s.model_context_window = model.contextWindow
        s.model_reasoning = model.reasoning == true
    else
        s.model_id = nil
        s.model_context_window = nil
        s.model_reasoning = false
    end
    s.thinking_level = data.thinkingLevel
    if data.autoCompactionEnabled ~= nil then
        s.auto_compaction = data.autoCompactionEnabled
    end
    self:render()
end

--- Accumulate usage from one assistant message.
--- Token totals (input, output, cache, cost) are summed across all calls.
--- context_tokens is overwritten (not accumulated) — the latest message's
--- total is the best estimate of current context window usage
--- (matches TUI's calculateContextTokens).
--- Skips messages with zero input (aborted/errored before reaching the model).
---@param usage table
function StatusLine:add_usage(usage)
    if not usage or (usage.input or 0) <= 0 then
        return
    end
    local s = self._state
    s.total_input = s.total_input + (usage.input or 0)
    s.total_output = s.total_output + (usage.output or 0)
    s.total_cache_read = s.total_cache_read + (usage.cacheRead or 0)
    s.total_cache_write = s.total_cache_write + (usage.cacheWrite or 0)
    local cost = type(usage.cost) == "table" and (usage.cost.total or 0) or 0
    s.total_cost = s.total_cost + cost
    -- Overwrite: latest message is the best context window estimate
    s.context_tokens = (usage.input or 0) + (usage.output or 0) + (usage.cacheRead or 0) + (usage.cacheWrite or 0)
    self:render()
end

--- Reset all usage stats (new session / clear).
function StatusLine:reset_usage()
    local s = self._state
    s.context_tokens = nil
    s.total_input = 0
    s.total_output = 0
    s.total_cache_read = 0
    s.total_cache_write = 0
    s.total_cost = 0
    self:render()
end

--- Set or clear an extension status value.
--- Called when an extension sends setStatus via extension_ui_request.
---@param key string
---@param value string? nil to clear
function StatusLine:set_extension_status(key, value)
    self._state.extensions[key] = value
    self:render()
end

--- Try to resolve a layout item as a component function.
--- Functions: call directly.
--- Strings: look up in built-in table.
--- Returns nil if the item is a literal separator string.
---@param item any
---@param tab pi.TabId
---@return pi.StatusLineComponentFn?, pi.StatusLineBuiltinName?
local function resolve_component(item, tab)
    local t = type(item)
    if t == "function" then
        return item, nil
    elseif item == "attention" then
        return attention_component(tab), "attention"
    elseif t == "string" and builtin[item] then
        return builtin[item], item
    end
    return nil, nil
end

--- Evaluate a layout array and return chunks (text + hl pairs).
--- Items are built-in names, custom component functions, or literal
--- separator strings. Separators only render between two visible
--- components. When a hidden component merges two separator groups, the
--- last separator before the next visible component is used.
---
--- Components may return:
---   string, string?       — single chunk (text, optional hl)
---   table of {text, hl}   — multi-chunk (detected when first return is a table)
---   nil                   — hidden
---@param items any[]
---@param state pi.StatusLineState
---@param tab pi.TabId
---@return string[][] chunks  list of {text, hl}
---@return integer width  total display width
local function eval_side(items, state, tab)
    -- First pass: evaluate all items into a flat list of tagged entries.
    -- Components produce one or more chunks; separators produce a literal.
    ---@type { kind: "component"|"separator", chunks: string[][]? }[]
    local entries = {}
    for _, item in ipairs(items) do
        local fn, builtin_name = resolve_component(item, tab)
        if fn then
            local result, hl = fn(state)
            local chunks = normalize_chunks(result, hl)
            if chunks and builtin_name then
                chunks = prepend_icon(builtin_name, chunks)
            end
            entries[#entries + 1] = { kind = "component", chunks = chunks }
        elseif type(item) == "string" then
            entries[#entries + 1] = { kind = "separator", chunks = { { item } } }
        end
    end

    -- Second pass: collect visible components with separators between them.
    -- Separators only render between two visible components.
    -- When components are hidden, buffer separators and use the last group.
    ---@type string[][]
    local chunks = {}
    local total_width = 0
    local has_prev = false -- a visible component exists before current position
    local pending_seps = {} -- buffered separator texts since last visible component

    for _, entry in ipairs(entries) do
        if entry.kind == "component" then
            if entry.chunks then
                -- Emit separators between this and the previous visible component
                if has_prev then
                    if #pending_seps > 0 then
                        for _, sep in ipairs(pending_seps) do
                            chunks[#chunks + 1] = { sep, "PiStatusLine" }
                            total_width = total_width + vim.fn.strdisplaywidth(sep)
                        end
                    else
                        -- No explicit separator — default single space
                        chunks[#chunks + 1] = { " ", "PiStatusLine" }
                        total_width = total_width + 1
                    end
                end
                pending_seps = {}
                for _, chunk in ipairs(entry.chunks) do
                    chunks[#chunks + 1] = { chunk[1], chunk[2] or "PiStatusLine" }
                    total_width = total_width + vim.fn.strdisplaywidth(chunk[1])
                end
                has_prev = true
            else
                -- Hidden component — discard buffered separators
                pending_seps = {}
            end
        else
            -- Separator — buffer it
            if has_prev and entry.chunks then
                pending_seps[#pending_seps + 1] = entry.chunks[1][1]
            end
        end
    end
    -- Trailing separators after the last visible component are discarded.
    return chunks, total_width
end

--- Re-render the status line extmark on the last line of the buffer.
function StatusLine:render()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end

    local win = self._win_fn()
    local width = win and text_area_width(win) or 80

    local sl_cfg = Config.options.ui.statusline
    local left_names = sl_cfg and sl_cfg.layout and sl_cfg.layout.left or { "context" }
    local right_names = sl_cfg and sl_cfg.layout and sl_cfg.layout.right or { "model", " · ", "thinking" }

    local left_chunks, left_width = eval_side(left_names, self._state, self._tab)
    local right_chunks, right_width = eval_side(right_names, self._state, self._tab)

    -- Truncate right side if it doesn't fit (left has priority).
    -- right_margin keeps 1 column of breathing room before the window edge.
    local right_margin = 1
    local min_gap = 2
    if left_width + min_gap + right_width + right_margin > width then
        local avail = width - left_width - min_gap - right_margin
        if avail > 0 then
            -- Rebuild right side truncated to avail columns
            local kept_width = 0
            ---@type string[][]
            local kept = {}
            for _, chunk in ipairs(right_chunks) do
                local cw = vim.fn.strdisplaywidth(chunk[1])
                if kept_width + cw <= avail then
                    kept[#kept + 1] = chunk
                    kept_width = kept_width + cw
                else
                    local remaining = avail - kept_width
                    if remaining > 0 then
                        -- TODO: strcharpart uses char indices, not display width;
                        -- would miscount wide chars (CJK, emoji). Fine for typical
                        -- model names and status values which are ASCII.
                        kept[#kept + 1] = { vim.fn.strcharpart(chunk[1], 0, remaining), chunk[2] }
                        kept_width = kept_width + remaining
                    end
                    break
                end
            end
            right_chunks = kept
            right_width = kept_width
        else
            right_chunks = {}
            right_width = 0
        end
    end

    -- Assemble: left + padding + right
    local gap = math.max(min_gap, width - left_width - right_width - right_margin)
    ---@type string[][]
    local status_chunks = {}
    for _, c in ipairs(left_chunks) do
        status_chunks[#status_chunks + 1] = c
    end
    status_chunks[#status_chunks + 1] = { string.rep(" ", gap), "" }
    for _, c in ipairs(right_chunks) do
        status_chunks[#status_chunks + 1] = c
    end
    if #left_chunks == 0 and #right_chunks == 0 then
        status_chunks = { { " ", "" } }
    end

    -- Build virt_lines: padding to pin status to the window bottom.
    -- Compute visual content height (with wrapping) by subtracting our own
    -- old virt_lines from the total reported by nvim_win_text_height.
    ---@type string[][][]
    local virt_lines = {}
    if win then
        local win_height = vim.api.nvim_win_get_height(win)
        local has_winbar = vim.wo[win].winbar ~= ""
        local text_rows = win_height - (has_winbar and 1 or 0)
        local visual_total = vim.api.nvim_win_text_height(win, {}).all
        local visual_content = visual_total - self._virt_line_count
        local pad_count = math.max(0, text_rows - visual_content - 1)
        for i = 1, pad_count do
            virt_lines[i] = { { " ", "" } }
        end
    end
    virt_lines[#virt_lines + 1] = status_chunks
    self._virt_line_count = #virt_lines

    local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
    if self._extmark_id then
        vim.api.nvim_buf_set_extmark(self._buf, ns, last_line, 0, {
            id = self._extmark_id,
            virt_lines = virt_lines,
        })
    else
        self._extmark_id = vim.api.nvim_buf_set_extmark(self._buf, ns, last_line, 0, {
            virt_lines = virt_lines,
        })
    end
end

function StatusLine:destroy()
    if self._extmark_id and self._buf and vim.api.nvim_buf_is_valid(self._buf) then
        pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, self._extmark_id)
        self._extmark_id = nil
    end
end

return StatusLine
