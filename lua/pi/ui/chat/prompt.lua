--- Prompt buffer management.

---@class pi.ChatPrompt
---@field _buf integer
---@field _win integer?
---@field _layout pi.LayoutMode
---@field _statusline pi.StatusLine
---@field _attachments pi.ChatAttachments
---@field _tab pi.TabId
local Prompt = {}
Prompt.__index = Prompt

local Ft = require("pi.filetypes")
local Config = require("pi.config")
local Decorators = require("pi.ui.chat.decorators")
local StatusLine = require("pi.ui.chat.statusline")

Prompt.HEIGHT = 5
Prompt.MAX_HEIGHT = 15

---@param name string
local function wipe_stale_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end
end

---@param win integer
---@return integer
local function window_text_rows(win)
    local info = vim.fn.getwininfo(win)
    if info and info[1] then
        return info[1].height
    end
    local height = vim.api.nvim_win_get_height(win)
    if vim.wo[win].winbar ~= "" then
        height = height - 1
    end
    return math.max(height, 1)
end

---@param mode string?
---@return boolean
local function is_visual_mode(mode)
    local first = mode and mode:sub(1, 1) or ""
    return first == "v" or first == "V" or first == "\22"
end

---@param tab pi.TabId
---@param attachments pi.ChatAttachments
---@return pi.ChatPrompt
function Prompt.new(tab, attachments)
    local self = setmetatable({}, Prompt)
    self._win = nil
    self._attachments = attachments
    self._tab = tab

    local panel = Config.options.ui.panels.prompt
    local name = panel.name and panel.name(tab) or ("π-prompt | " .. tab)
    wipe_stale_buf(name)
    self._buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self._buf].buftype = "nofile"
    vim.bo[self._buf].filetype = Ft.prompt
    vim.bo[self._buf].swapfile = false
    vim.bo[self._buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(self._buf, name)

    vim.bo[self._buf].completefunc = "v:lua.require'pi.completion.omnifunc'.completefunc"
    Decorators.attach(self._buf)

    -- Arrow keys move by display line so wrapped text is navigable
    vim.api.nvim_buf_set_keymap(self._buf, "i", "<Up>", "<C-o>g<Up>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(self._buf, "i", "<Down>", "<C-o>g<Down>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(self._buf, "n", "<Up>", "g<Up>", { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(self._buf, "n", "<Down>", "g<Down>", { noremap = true, silent = true })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = self._buf,
        callback = function()
            vim.cmd("stopinsert")
        end,
    })

    self._statusline = StatusLine.new(self._buf, tab, function()
        return self:win()
    end)

    -- Auto-resize prompt window to fit content while editing.
    -- Order matters: resize first (uses content height minus status padding),
    -- then render status line (uses resulting window height for padding).
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = self._buf,
        callback = function()
            self:resize()
            self:_render_statusline()
        end,
    })

    -- Visual-mode delete-all (e.g. ggVGx) can leave the statusline extmark
    -- visually stale until after the mode switch completes. Re-render once
    -- when leaving Visual mode instead of syncing on every line change.
    vim.api.nvim_create_autocmd("ModeChanged", {
        buffer = self._buf,
        callback = function()
            local ev = vim.v.event or {}
            if not is_visual_mode(ev.old_mode) or is_visual_mode(ev.new_mode) then
                return
            end
            vim.schedule(function()
                self:resize()
                self:_render_statusline()
            end)
        end,
    })

    -- Re-render status line padding when the window is resized externally
    -- (e.g. <C-w>+, split drag). Without this, padding stays stale until
    -- the next text change.
    vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
            if self._win and vim.api.nvim_win_is_valid(self._win) then
                for _, win in ipairs(vim.v.event.windows) do
                    if win == self._win then
                        self:_render_statusline()
                        return
                    end
                end
            end
        end,
    })

    -- Override vim.paste to intercept drag-and-drop image file paths
    local original_paste = vim.paste
    vim.paste = (function(original)
        return function(lines, phase)
            if vim.api.nvim_get_current_buf() ~= self._buf then
                return original(lines, phase)
            end
            local line = lines[1]
            if line and #lines == 1 and line ~= "" then
                local stat = vim.uv.fs_stat(line)
                if stat and stat.type == "file" then
                    local ext = line:match("%.(%w+)$")
                    if ext and vim.tbl_contains({ "png", "jpg", "jpeg", "gif", "webp", "svg" }, ext:lower()) then
                        self._attachments:add_file(line)
                        return true
                    end
                end
            end
            return original(lines, phase)
        end
    end)(original_paste)

    return self
end

---@return integer
function Prompt:buf()
    return self._buf
end

---@return pi.StatusLine
function Prompt:statusline()
    return self._statusline
end

--- Re-render the prompt statusline and reset wrapped scrolling when the
--- whole prompt fits again. Neovim can leave stale skipcol/topline state
--- after a wrapped line splits before the statusline extmark is moved.
function Prompt:_render_statusline()
    self._statusline:render()
    self:_reset_view_if_content_fits()
end

function Prompt:_reset_view_if_content_fits()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    if vim.api.nvim_win_text_height(self._win, {}).all > window_text_rows(self._win) then
        return
    end
    vim.api.nvim_win_call(self._win, function()
        vim.fn.winrestview({ topline = 1, skipcol = 0 })
    end)
end

---@param win integer?
function Prompt:set_win(win)
    self._win = win
    self:_render_statusline()
end

---@param mode pi.LayoutMode
function Prompt:set_layout(mode)
    self._layout = mode
    self:_render_statusline()
end

function Prompt:resize()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    local visual_lines = vim.api.nvim_win_text_height(self._win, {}).all
    -- Subtract status line virt_lines (padding + status) so padding doesn't
    -- prevent the window from shrinking. Add 1 back for the status line itself.
    local content_lines = visual_lines - self._statusline:virt_line_count() + 1
    local target_height = math.max(Prompt.HEIGHT, math.min(content_lines, Prompt.MAX_HEIGHT))
    if vim.wo[self._win].winbar ~= "" then
        target_height = target_height + 1
    end
    local current_height = vim.api.nvim_win_get_height(self._win)
    if target_height ~= current_height then
        if self._layout == "float" then
            vim.api.nvim_win_set_config(self._win, { height = target_height })
        else
            vim.api.nvim_win_set_height(self._win, target_height)
        end
    end
end

---@return integer?
function Prompt:win()
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        return self._win
    end
    return nil
end

function Prompt:focus()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    vim.api.nvim_set_current_win(self._win)
    vim.schedule(function()
        vim.cmd("startinsert")
    end)
end

---@return string
function Prompt:text()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return ""
    end
    local lines = vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)
    return vim.fn.trim(table.concat(lines, "\n"))
end

function Prompt:clear_text()
    if self._buf and vim.api.nvim_buf_is_valid(self._buf) then
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
        self:resize()
        self:_render_statusline()
    end
end

---@return integer
function Prompt:content_height()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return Prompt.HEIGHT
    end
    local line_count = vim.api.nvim_buf_line_count(self._buf) + 1 -- +1 for status line
    local target_height = math.max(Prompt.HEIGHT, math.min(line_count, Prompt.MAX_HEIGHT))
    if self._win and vim.api.nvim_win_is_valid(self._win) and vim.wo[self._win].winbar ~= "" then
        target_height = target_height + 1
    end
    return target_height
end

return Prompt
