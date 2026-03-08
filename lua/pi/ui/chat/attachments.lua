---@class pi.Attachment
---@field name string
---@field data string base64-encoded
---@field mime string

---@class pi.ChatAttachments
---@field _items pi.Attachment[]
---@field _buf integer
---@field _on_change fun()?
---@field _rerendering boolean
---@field _clipboard_counter integer
local Attachments = {}
Attachments.__index = Attachments

local Ft = require("pi.filetypes")
local Config = require("pi.config")
local Notify = require("pi.notify")

local ns = vim.api.nvim_create_namespace("pi-attachments")

local mime_map = {
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    webp = "image/webp",
    svg = "image/svg+xml",
}

---@param path string
---@return string?
local function mime_from_path(path)
    local ext = path:match("%.(%w+)$")
    return ext and mime_map[ext:lower()] or nil
end

---@param path string
---@return string? base64
local function read_and_encode(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return vim.base64.encode(data)
end

---@return pi.ChatAttachments
function Attachments.new()
    local self = setmetatable({}, Attachments)
    self._items = {}
    self._on_change = nil
    self._rerendering = false
    self._clipboard_counter = 0

    self._buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self._buf].buftype = "nofile"
    vim.bo[self._buf].filetype = Ft.attachments
    vim.bo[self._buf].swapfile = false
    vim.bo[self._buf].bufhidden = "hide"

    vim.keymap.set("n", "dd", function()
        self:_remove_at_cursor()
    end, { buffer = self._buf, desc = "Remove π attachment" })
    vim.keymap.set("n", "x", function()
        self:_remove_at_cursor()
    end, { buffer = self._buf, desc = "Remove π attachment" })

    return self
end

function Attachments:_remove_at_cursor()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if row <= #self._items then
        self:remove(row)
    end
end

function Attachments:_update_buffer()
    vim.bo[self._buf].modifiable = true
    local icon = Config.options.ui.labels.attachment
    local lines = {}
    for _, item in ipairs(self._items) do
        lines[#lines + 1] = icon .. " " .. item.name
    end
    if #lines == 0 then
        lines = { "" }
    end
    vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, lines)
    vim.bo[self._buf].modifiable = false

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(self._buf, ns, 0, -1)
    local icon_len = #icon
    for i, _ in ipairs(self._items) do
        vim.api.nvim_buf_set_extmark(self._buf, ns, i - 1, 0, {
            end_col = icon_len,
            hl_group = "PiAttachmentIcon",
        })
        vim.api.nvim_buf_set_extmark(self._buf, ns, i - 1, icon_len, {
            end_row = i - 1,
            end_col = #lines[i],
            hl_group = "PiAttachmentFilename",
        })
    end
end

function Attachments:_rerender()
    if self._rerendering then
        return
    end
    self._rerendering = true
    self:_update_buffer()
    if self._on_change then
        self._on_change()
    end
    self._rerendering = false
end

---@param path string
---@return boolean
function Attachments:add_file(path)
    local mime = mime_from_path(path)
    if not mime then
        Notify.warn("Not a supported image format: " .. path)
        return false
    end
    local data = read_and_encode(path)
    if not data then
        Notify.error("Could not read file: " .. path)
        return false
    end
    local name = vim.fn.fnamemodify(path, ":t")
    self._items[#self._items + 1] = { name = name, data = data, mime = mime }
    self:_rerender()
    return true
end

---@return boolean
function Attachments:add_from_clipboard()
    local ok, img_clip = pcall(require, "img-clip.clipboard")
    if not ok then
        Notify.warn(
            "img-clip.nvim is required for clipboard image paste.\n" .. "Install it: { 'HakonHarnes/img-clip.nvim' }"
        )
        return false
    end

    if not img_clip.get_clip_cmd() then
        Notify.warn("No clipboard tool found (pngpaste, xclip, or wl-paste)")
        return false
    end

    if not img_clip.content_is_image() then
        Notify.warn("Clipboard does not contain an image")
        return false
    end

    local data = img_clip.get_base64_encoded_image()
    if not data then
        Notify.error("Failed to read image from clipboard")
        return false
    end

    self._clipboard_counter = self._clipboard_counter + 1
    local name = "cb-image-" .. self._clipboard_counter .. ".png"
    self._items[#self._items + 1] = { name = name, data = data, mime = "image/png" }
    self:_rerender()
    return true
end

---@param index integer
function Attachments:remove(index)
    if index >= 1 and index <= #self._items then
        table.remove(self._items, index)
        self:_rerender()
    end
end

function Attachments:clear()
    self._items = {}
    self:_rerender()
end

---@return pi.RpcImageContent[]
function Attachments:get()
    ---@type pi.RpcImageContent[]
    local result = {}
    for _, item in ipairs(self._items) do
        result[#result + 1] = { type = "image", data = item.data, mimeType = item.mime }
    end
    return result
end

---@return integer
function Attachments:count()
    return #self._items
end

---@return integer
function Attachments:buf()
    return self._buf
end

---@param fn fun()
function Attachments:set_on_change(fn)
    self._on_change = fn
end

return Attachments
