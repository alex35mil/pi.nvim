--- Prompt buffer management.

---@class pi.ChatPrompt
---@field _buf integer
---@field _win integer?
---@field _layout pi.LayoutMode
---@field _bottom_padding_extmark integer?
---@field _attachments pi.ChatAttachments
---@field _tab pi.TabId
local Prompt = {}
Prompt.__index = Prompt

local Ft = require("pi.filetypes")
local Config = require("pi.config")
local Mentions = require("pi.ui.chat.mentions")

Prompt.HEIGHT = 5
Prompt.MAX_HEIGHT = 15

local ns = vim.api.nvim_create_namespace("pi-prompt")

---@param name string
local function wipe_stale_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end
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
    Mentions.attach(self._buf)

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = self._buf,
        callback = function()
            vim.cmd("stopinsert")
        end,
    })

    -- Auto-resize prompt window to fit content
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = self._buf,
        callback = function()
            self:_update_padding()
            self:resize()
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

---@param win integer?
function Prompt:set_win(win)
    self._win = win
end

---@param mode pi.LayoutMode
function Prompt:set_layout(mode)
    self._layout = mode
    if mode == "side" and not self._bottom_padding_extmark then
        local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
        self._bottom_padding_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, last_line, 0, {
            virt_lines = { { { " ", "" } } },
        })
    elseif mode == "float" and self._bottom_padding_extmark then
        vim.api.nvim_buf_del_extmark(self._buf, ns, self._bottom_padding_extmark)
        self._bottom_padding_extmark = nil
    end
end

function Prompt:_update_padding()
    if not self._bottom_padding_extmark then
        return
    end
    local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
    vim.api.nvim_buf_set_extmark(self._buf, ns, last_line, 0, {
        id = self._bottom_padding_extmark,
        virt_lines = { { { " ", "" } } },
    })
end

function Prompt:resize()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    local visual_lines = vim.api.nvim_win_text_height(self._win, {}).all
    local target_height = math.max(Prompt.HEIGHT, math.min(visual_lines, Prompt.MAX_HEIGHT))
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
    -- Float: neovim scrolls the view to keep cursor visible before TextChanged
    -- fires, leaving a stale topline after we grow the window. Reset when all
    -- content fits.
    if self._layout == "float" and visual_lines <= target_height then
        vim.api.nvim_win_call(self._win, function()
            vim.fn.winrestview({ topline = 1 })
        end)
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
    end
end

---@return integer
function Prompt:content_height()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return Prompt.HEIGHT
    end
    local line_count = vim.api.nvim_buf_line_count(self._buf)
    local target_height = math.max(Prompt.HEIGHT, math.min(line_count, Prompt.MAX_HEIGHT))
    if self._win and vim.api.nvim_win_is_valid(self._win) and vim.wo[self._win].winbar ~= "" then
        target_height = target_height + 1
    end
    return target_height
end

return Prompt
