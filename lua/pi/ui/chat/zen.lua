--- Zen mode — full-screen overlay with centered prompt for focused editing.

---@class pi.Zen
---@field _prompt pi.ChatPrompt
---@field _backdrop_win integer?
---@field _win integer?
---@field _prev_win integer?
---@field _winleave_aucmd integer?
---@field _resize_aucmd integer?
local Zen = {}
Zen.__index = Zen

local Config = require("pi.config")

--- Z-index: above normal pi floats (10) but below dialogs (default 50).
local BACKDROP_ZINDEX = 40
local ZEN_ZINDEX = 41

---@param prompt pi.ChatPrompt
---@return pi.Zen
function Zen.new(prompt)
    local self = setmetatable({}, Zen)
    self._prompt = prompt
    self._backdrop_win = nil
    self._win = nil
    self._prev_win = nil
    self._winleave_aucmd = nil
    self._resize_aucmd = nil
    return self
end

---@return boolean
function Zen:is_active()
    return self._win ~= nil and vim.api.nvim_win_is_valid(self._win)
end

--- Resolve the prompt width for zen mode.
--- Uses config `zen.width`, then `textwidth` if set, then 80.
---@return integer
local function resolve_width()
    local zen_cfg = Config.options.ui.zen
    if zen_cfg and zen_cfg.width then
        return zen_cfg.width
    end
    local tw = vim.bo.textwidth
    if tw and tw > 0 then
        return tw
    end
    return 80
end

--- Compute zen layout dimensions from current editor state.
---@return { top: integer, width: integer, height: integer, col: integer, ui_width: integer }
local function compute_geometry()
    local ui_width = vim.o.columns
    local tabline_height = 0
    local stl = vim.o.showtabline
    if stl == 2 or (stl == 1 and #vim.api.nvim_list_tabpages() > 1) then
        tabline_height = 1
    end
    local statusline_height = 0
    local ls = vim.o.laststatus
    if ls == 2 or ls == 3 or (ls == 1 and #vim.api.nvim_list_wins() > 1) then
        statusline_height = 1
    end
    local top = tabline_height
    local ui_height = vim.o.lines - vim.o.cmdheight - tabline_height - statusline_height
    local width = math.min(resolve_width(), ui_width)
    local col = math.floor((ui_width - width) / 2)
    return { top = top, width = width, height = ui_height, col = col, ui_width = ui_width }
end

function Zen:enter()
    if self:is_active() then
        return
    end

    -- Stash the current prompt window so we can restore on exit.
    self._prev_win = self._prompt:win()

    local g = compute_geometry()

    -- Full-screen backdrop
    local backdrop_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[backdrop_buf].buftype = "nofile"
    vim.bo[backdrop_buf].bufhidden = "wipe"

    self._backdrop_win = vim.api.nvim_open_win(backdrop_buf, false, {
        relative = "editor",
        width = g.ui_width,
        height = g.height,
        col = 0,
        row = g.top,
        style = "minimal",
        border = "none",
        zindex = BACKDROP_ZINDEX,
        focusable = false,
    })
    vim.wo[self._backdrop_win].winhighlight = "NormalFloat:PiZenBackdrop"

    self._win = vim.api.nvim_open_win(self._prompt:buf(), true, {
        relative = "editor",
        width = g.width,
        height = g.height,
        col = g.col,
        row = g.top,
        style = "minimal",
        border = "none",
        zindex = ZEN_ZINDEX,
    })

    vim.wo[self._win].wrap = true
    vim.wo[self._win].linebreak = true
    vim.wo[self._win].signcolumn = "no"
    vim.wo[self._win].foldcolumn = "0"
    vim.wo[self._win].foldenable = false
    vim.wo[self._win].list = false
    vim.wo[self._win].conceallevel = 2
    vim.wo[self._win].winfixbuf = true
    vim.wo[self._win].winhighlight = "NormalFloat:PiZen"
    -- Winfix fingerprint options — keep in sync with has_pi_fingerprint() in winfix.lua
    vim.wo[self._win].concealcursor = "nvic"
    vim.wo[self._win].number = false
    vim.wo[self._win].relativenumber = false
    vim.wo[self._win].cursorline = false

    -- Empty winbar as top padding
    vim.wo[self._win].winbar = "%#PiZen#"

    -- Tell the prompt about the new window so statusline targets it.
    -- Set zen flag first to prevent resize() from shrinking the float.
    self._prompt:set_zen(true)
    self._prompt:set_win(self._win)
    self._prompt:set_layout("float")

    -- Prevent navigating away: bounce back on WinLeave.
    -- Allow leaving to floating windows (dialogs, completion popups, etc.).
    self._winleave_aucmd = vim.api.nvim_create_autocmd("WinLeave", {
        callback = function()
            if not self:is_active() then
                return
            end
            local zen_win = self._win
            vim.schedule(function()
                if not zen_win or not vim.api.nvim_win_is_valid(zen_win) then
                    return
                end
                local cur = vim.api.nvim_get_current_win()
                if cur == zen_win then
                    return
                end
                -- Allow focus to move to other floating windows (dialogs, etc.)
                local cfg = vim.api.nvim_win_get_config(cur)
                if cfg and cfg.relative and cfg.relative ~= "" then
                    return
                end
                vim.api.nvim_set_current_win(zen_win)
            end)
        end,
    })

    -- Reposition floats on terminal resize.
    self._resize_aucmd = vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            if not self:is_active() then
                return
            end
            self:_reposition()
        end,
    })

    vim.cmd("startinsert")
end

--- Reposition backdrop and prompt floats to match current editor dimensions.
function Zen:_reposition()
    local g = compute_geometry()
    if self._backdrop_win and vim.api.nvim_win_is_valid(self._backdrop_win) then
        vim.api.nvim_win_set_config(self._backdrop_win, {
            relative = "editor",
            width = g.ui_width,
            height = g.height,
            col = 0,
            row = g.top,
        })
    end
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        vim.api.nvim_win_set_config(self._win, {
            relative = "editor",
            width = g.width,
            height = g.height,
            col = g.col,
            row = g.top,
        })
    end
end

function Zen:exit()
    if not self:is_active() then
        return
    end

    -- Remove autocmds
    if self._winleave_aucmd then
        vim.api.nvim_del_autocmd(self._winleave_aucmd)
        self._winleave_aucmd = nil
    end
    if self._resize_aucmd then
        vim.api.nvim_del_autocmd(self._resize_aucmd)
        self._resize_aucmd = nil
    end

    -- Capture cursor position before closing — this is where the user
    -- left off and should be restored in the prompt window.
    local cursor ---@type integer[]?
    local zen_win = self._win
    if zen_win and vim.api.nvim_win_is_valid(zen_win) then
        cursor = vim.api.nvim_win_get_cursor(zen_win)
    end

    -- Close the zen float
    self._win = nil
    if zen_win and vim.api.nvim_win_is_valid(zen_win) then
        vim.api.nvim_win_close(zen_win, true)
    end

    -- Close the backdrop
    if self._backdrop_win and vim.api.nvim_win_is_valid(self._backdrop_win) then
        vim.api.nvim_win_close(self._backdrop_win, true)
    end
    self._backdrop_win = nil

    -- Restore the original prompt window and cursor position.
    -- If the original window was closed externally, fall back to
    -- re-showing the prompt via focus (which triggers layout show).
    self._prompt:set_zen(false)
    local prev_valid = self._prev_win and vim.api.nvim_win_is_valid(self._prev_win)
    if prev_valid then
        self._prompt:set_win(self._prev_win)
        self._prompt:resize()
        if cursor then
            pcall(vim.api.nvim_win_set_cursor, self._prev_win, cursor)
        end
        self._prompt:focus()
    else
        -- Original window gone — clear stale state so prompt can be
        -- re-attached when the layout is next shown.
        self._prompt:set_win(nil)
    end
    self._prev_win = nil
end

function Zen:toggle()
    if self:is_active() then
        self:exit()
    else
        self:enter()
    end
end

return Zen
