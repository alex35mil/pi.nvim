--- Chat layout — window creation, positioning, and management.

---@class pi.ChatLayout
---@field _mode pi.LayoutMode
---@field _history_win integer?
---@field _prompt_win integer?
---@field _attachments_win integer?
---@field _history pi.ChatHistory
---@field _prompt pi.ChatPrompt
---@field _attachments pi.ChatAttachments
local Layout = {}
Layout.__index = Layout

local Config = require("pi.config")
local Prompt = require("pi.ui.chat.prompt")
local Highlights = require("pi.ui.highlights")

--- Low z-index so other floats naturally sit on top.
local FLOAT_ZINDEX = 10

-- Capture editor options to inherit in π windows.
local editor_foldcolumn = vim.wo.foldcolumn

---@param win integer
---@param extra? fun(win: integer)
local function set_win_opts(win, extra)
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = editor_foldcolumn
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "nvic"
    vim.wo[win].cursorline = false
    vim.wo[win].winfixbuf = true
    if extra then
        extra(win)
    end
end

---@param win integer
---@param title string
---@param hl_group string
---@param title_hl_group? string
local function set_winbar(win, title, hl_group, title_hl_group)
    title_hl_group = title_hl_group or (hl_group .. "Title")
    vim.wo[win].winbar = "%#" .. hl_group .. "#%=%#" .. title_hl_group .. "# " .. title .. " %#" .. hl_group .. "#%="
end

---@param win integer
local function clear_winbar(win)
    vim.wo[win].winbar = ""
end

--- Update prompt title styling to reflect pending attention.
---@param has_attention boolean
function Layout:refresh_prompt_attention(has_attention)
    local pwin = self:prompt_win()
    if not pwin then
        return
    end

    if self._mode == "float" then
        vim.wo[pwin].winhighlight = has_attention and Highlights.CHAT_PROMPT_ATTENTION_WINHIGHLIGHT
            or Highlights.CHAT_PROMPT_WINHIGHLIGHT
        return
    end

    if Config.options.ui.layout.side.panels.prompt.winbar then
        set_winbar(
            pwin,
            Config.options.ui.panels.prompt.title,
            "PiChatPromptWinbar",
            has_attention and "PiChatPromptWinbarAttentionTitle" or "PiChatPromptWinbarTitle"
        )
    end
end

---@param mode pi.LayoutMode
---@param history pi.ChatHistory
---@param prompt pi.ChatPrompt
---@param attachments pi.ChatAttachments
---@return pi.ChatLayout
function Layout.new(mode, history, prompt, attachments)
    local self = setmetatable({}, Layout)
    self._mode = mode
    self._history_win = nil
    self._prompt_win = nil
    self._attachments_win = nil
    self._history = history
    self._prompt = prompt
    self._attachments = attachments

    attachments:set_on_change(function()
        self:_refresh_attachments()
    end)

    return self
end

---@param after_win integer
function Layout:_open_attachments_in_side_layout(after_win)
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(after_win)
    vim.cmd("belowright " .. self._attachments:count() .. "split")
    self._attachments_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._attachments_win, self._attachments:buf())
    vim.wo[self._attachments_win].winfixheight = true
    vim.wo[self._attachments_win].winfixwidth = true
    vim.wo[self._attachments_win].number = false
    vim.wo[self._attachments_win].relativenumber = false
    vim.wo[self._attachments_win].signcolumn = "no"
    vim.wo[self._attachments_win].foldcolumn = editor_foldcolumn
    vim.wo[self._attachments_win].cursorline = false
    vim.wo[self._attachments_win].winfixbuf = true
    vim.wo[self._attachments_win].wrap = false
    vim.api.nvim_set_current_win(prev_win)
end

---@param col integer
---@param row integer
---@param width integer
---@param border string|string[]
function Layout:_open_attachments_in_float_layout(col, row, width, border)
    -- Available height: screen lines minus cmdline, statusline (1), rows above (row), border (2)
    local max_height = vim.o.lines - vim.o.cmdheight - 1 - row - 2
    if max_height < 1 then
        return
    end
    local height = math.min(self._attachments:count(), max_height)
    self._attachments_win = vim.api.nvim_open_win(self._attachments:buf(), false, {
        relative = "editor",
        width = width,
        height = height,
        col = col,
        row = row,
        style = "minimal",
        border = border,
        zindex = FLOAT_ZINDEX,
        title = " " .. Config.options.ui.panels.attachments.title .. " ",
        title_pos = "center",
    })
    vim.wo[self._attachments_win].winfixheight = true
    vim.wo[self._attachments_win].number = false
    vim.wo[self._attachments_win].relativenumber = false
    vim.wo[self._attachments_win].signcolumn = "yes"
    vim.wo[self._attachments_win].cursorline = false
    vim.wo[self._attachments_win].winfixbuf = true
    vim.wo[self._attachments_win].wrap = false
    vim.wo[self._attachments_win].winhighlight = Highlights.CHAT_ATTACHMENTS_WINHIGHLIGHT
end

function Layout:_close_history_win()
    local hwin = self:history_win()
    if hwin then
        vim.api.nvim_win_close(hwin, false)
    end
    self._history_win = nil
    self._history:set_win(nil)
end

function Layout:_close_prompt_win()
    local pwin = self:prompt_win()
    if pwin then
        vim.api.nvim_win_close(pwin, false)
    end
    self._prompt_win = nil
    self._prompt:set_win(nil)
end

function Layout:_close_attachments_win()
    local awin = self:attachments_win()
    if not awin then
        self._attachments_win = nil
        return
    end
    -- Move focus away before closing: try previous window, fall back to next
    -- if the previous window is the one we're closing (only window in column).
    if vim.api.nvim_get_current_win() == awin then
        vim.cmd("wincmd p")
        if vim.api.nvim_get_current_win() == awin then
            vim.cmd("wincmd w")
        end
    end
    vim.api.nvim_win_close(awin, false)
    self._attachments_win = nil
end

function Layout:_reposition_float_stack()
    if not self._history_win or not vim.api.nvim_win_is_valid(self._history_win) then
        return
    end
    if not self._prompt_win or not vim.api.nvim_win_is_valid(self._prompt_win) then
        return
    end

    local float_cfg = Config.options.ui.layout.float
    local ui_width = vim.o.columns
    local ui_height = vim.o.lines - vim.o.cmdheight - 1
    local border = float_cfg.border or "rounded"

    local width = vim.api.nvim_win_get_width(self._history_win)
    local history_height = vim.api.nvim_win_get_height(self._history_win)
    local prompt_height = vim.api.nvim_win_get_height(self._prompt_win)
    local attach_count = self._attachments:count()

    -- border takes 2 lines per window (top + bottom)
    local total = history_height + 2 + prompt_height + 2
    if attach_count > 0 then
        total = total + attach_count + 2
    end

    -- Shrink history if stack doesn't fit
    local overhead = total - history_height
    if total > ui_height then
        history_height = math.max(3, ui_height - overhead)
        total = history_height + overhead
    end

    -- If it still doesn't fit, skip attachments
    if total > ui_height and attach_count > 0 then
        total = total - attach_count - 2
        attach_count = 0
        self:_close_attachments_win()
    end

    local col = math.floor((ui_width - width) / 2)
    local row = math.max(0, math.floor((ui_height - total) / 2))

    vim.api.nvim_win_set_config(self._history_win, {
        relative = "editor",
        row = row,
        col = col,
        height = history_height,
        width = width,
    })

    local prompt_row = row + history_height + 2
    vim.api.nvim_win_set_config(self._prompt_win, {
        relative = "editor",
        row = prompt_row,
        col = col,
    })

    if attach_count > 0 then
        local attach_row = prompt_row + prompt_height + 2
        local awin = self:attachments_win()
        if awin then
            vim.api.nvim_win_set_config(awin, {
                relative = "editor",
                row = attach_row,
                col = col,
                width = width,
                height = attach_count,
            })
        else
            self:_open_attachments_in_float_layout(col, attach_row, width, border)
        end
    end
end

function Layout:_refresh_attachments()
    if not self._prompt_win or not vim.api.nvim_win_is_valid(self._prompt_win) then
        return
    end
    local is_float = self._mode == "float"

    if self._attachments:count() == 0 then
        local was_visible = self:attachments_win() ~= nil
        self:_close_attachments_win()
        vim.api.nvim_set_current_win(self._prompt_win)
        vim.cmd("startinsert")
        if was_visible then
            if is_float then
                self:_reposition_float_stack()
            else
                vim.api.nvim_win_call(self._history_win, function()
                    vim.cmd("wincmd _")
                end)
                vim.api.nvim_win_set_height(self._prompt_win, self._prompt:content_height())
            end
        end
        return
    end

    if is_float then
        self:_reposition_float_stack()
    else
        if not self:attachments_win() then
            self:_open_attachments_in_side_layout(self._prompt_win)
        end
        local awin = self:attachments_win()
        if awin then
            if Config.options.ui.layout.side.panels.attachments.winbar then
                set_winbar(awin, Config.options.ui.panels.attachments.title, "PiChatAttachmentsWinbar")
            end
            -- Account for winbar + padding in target height
            local aheight = self._attachments:count() + 1 -- +1 for padding line
            if vim.wo[awin].winbar ~= "" then
                aheight = aheight + 1
            end
            vim.api.nvim_win_set_height(awin, aheight)
        end
        -- Maximize history, then re-fix prompt and attachments heights.
        -- Capture attachment height before wincmd _ steals its space.
        local target_attachments_height = awin and vim.api.nvim_win_get_height(awin) or 0
        vim.api.nvim_win_call(self._history_win, function()
            vim.cmd("wincmd _")
        end)
        vim.api.nvim_win_set_height(self._prompt_win, self._prompt:content_height())
        if awin then
            vim.api.nvim_win_set_height(awin, target_attachments_height)
        end
    end
end

function Layout:_open_in_side_layout()
    local side_cfg = Config.options.ui.layout.side
    local panels = side_cfg.panels
    local w = side_cfg.width
    if w < 1 then
        w = math.floor(vim.o.columns * w)
    end
    vim.cmd("botright " .. w .. "vsplit")

    self._history_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._history_win, self._history:buf())
    set_win_opts(self._history_win, function(win)
        vim.wo[win].winfixwidth = true
        -- conceallevel=0: treesitter markdown can't conceal brackets/bold
        -- in tool output, so we don't need ``` fence wrappers.
        vim.wo[win].conceallevel = 0
    end)
    if panels.history.winbar then
        set_winbar(self._history_win, Config.options.ui.panels.history.title, "PiChatHistoryWinbar")
    end
    self._history:set_win(self._history_win)

    local prompt_winbar = panels.prompt.winbar
    local prompt_h = Prompt.HEIGHT + (prompt_winbar and 1 or 0)
    vim.cmd("belowright " .. prompt_h .. "split")
    self._prompt_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._prompt_win, self._prompt:buf())
    set_win_opts(self._prompt_win, function(win)
        vim.wo[win].winfixwidth = true
        vim.wo[win].winfixheight = true
        vim.wo[win].virtualedit = "onemore"
    end)
    if prompt_winbar then
        set_winbar(self._prompt_win, Config.options.ui.panels.prompt.title, "PiChatPromptWinbar")
    end
    self._prompt:set_layout("side")
    self._prompt:set_win(self._prompt_win)
end

function Layout:_open_in_float_layout()
    local float_cfg = Config.options.ui.layout.float
    local ui_width = vim.o.columns
    local ui_height = vim.o.lines - vim.o.cmdheight - 1

    ---@type integer
    local width = type(float_cfg.width) == "number" and float_cfg.width < 1 and math.floor(ui_width * float_cfg.width)
        or (float_cfg.width or 80)
    ---@type integer
    local total_height = type(float_cfg.height) == "number"
            and float_cfg.height < 1
            and math.floor(ui_height * float_cfg.height)
        or (float_cfg.height or 30)
    local history_height = total_height - Prompt.HEIGHT - 1
    local col = math.floor((ui_width - width) / 2)
    local row = math.floor((ui_height - total_height) / 2)
    local border = float_cfg.border or "rounded"
    local user_win = float_cfg.win or {}

    self._history_win = vim.api.nvim_open_win(
        self._history:buf(),
        false,
        vim.tbl_deep_extend("force", {
            relative = "editor",
            width = width,
            height = history_height,
            col = col,
            row = row,
            style = "minimal",
            border = border,
            zindex = FLOAT_ZINDEX,
            title = " " .. Config.options.ui.panels.history.title .. " ",
            title_pos = "center",
        }, user_win)
    )
    set_win_opts(self._history_win)
    vim.wo[self._history_win].winbar = ""
    vim.wo[self._history_win].winhighlight = Highlights.CHAT_HISTORY_WINHIGHLIGHT
    vim.wo[self._history_win].conceallevel = 0
    self._history:set_win(self._history_win)

    self._prompt_win = vim.api.nvim_open_win(
        self._prompt:buf(),
        true,
        vim.tbl_deep_extend("force", {
            relative = "editor",
            width = width,
            height = Prompt.HEIGHT,
            col = col,
            row = row + history_height + 2,
            style = "minimal",
            border = border,
            zindex = FLOAT_ZINDEX,
            title = " " .. Config.options.ui.panels.prompt.title .. " ",
            title_pos = "center",
        }, user_win)
    )
    set_win_opts(self._prompt_win, function(win)
        vim.wo[win].winfixheight = true
        vim.wo[win].virtualedit = "onemore"
    end)
    vim.wo[self._prompt_win].winbar = ""
    vim.wo[self._prompt_win].winhighlight = Highlights.CHAT_PROMPT_WINHIGHLIGHT
    self._prompt:set_layout("float")
    self._prompt:set_win(self._prompt_win)
end

---@return boolean opened true if a fresh open occurred
function Layout:show()
    if self._history_win and vim.api.nvim_win_is_valid(self._history_win) then
        return false
    end
    if self._mode == "float" then
        self:_open_in_float_layout()
    else
        self:_open_in_side_layout()
    end
    return true
end

function Layout:hide()
    -- Clear winbars before closing to prevent window-buffer-local
    -- winbar state from leaking into the next layout's windows.
    local awin = self:attachments_win()
    if awin then
        clear_winbar(awin)
    end
    local pwin = self:prompt_win()
    if pwin then
        clear_winbar(pwin)
    end
    local hwin = self:history_win()
    if hwin then
        clear_winbar(hwin)
    end

    self:_close_attachments_win()
    self:_close_prompt_win()
    self:_close_history_win()
end

---@return pi.LayoutMode
function Layout:mode()
    return self._mode
end

---@param mode pi.LayoutMode
function Layout:set_mode(mode)
    self:hide()
    self._mode = mode
    self:show()
    self._prompt:resize()
    if self._attachments:count() > 0 then
        self:_refresh_attachments()
    end
end

function Layout:toggle()
    self:set_mode(self._mode == "side" and "float" or "side")
end

---@return boolean
function Layout:is_visible()
    return self._history_win ~= nil and vim.api.nvim_win_is_valid(self._history_win)
end

---@return integer?
function Layout:history_win()
    if self._history_win and vim.api.nvim_win_is_valid(self._history_win) then
        return self._history_win
    end
    return nil
end

---@return integer?
function Layout:prompt_win()
    if self._prompt_win and vim.api.nvim_win_is_valid(self._prompt_win) then
        return self._prompt_win
    end
    return nil
end

---@return integer?
function Layout:attachments_win()
    if self._attachments_win and vim.api.nvim_win_is_valid(self._attachments_win) then
        return self._attachments_win
    end
    return nil
end

return Layout
