---@class pi.Attachment
---@field name string
---@field data string base64-encoded
---@field mime string

--- An attachment in the prompt, with a digest of its data computed once when
--- it enters the list, so drafts compare without touching the data.
---@class pi.ChatAttachment: pi.Attachment
---@field digest string sha256 of `data`

--- What changed the attachment list.
---@alias pi.AttachmentChange
---| "added" # the user added one (file, drag-and-drop, clipboard)
---| "removed" # the user removed one
---| "cleared" # emptied because the draft was sent
---| "restored" # input put back (failed send, crash recovery)
---| "replaced" # replaced from outside (`pi.set_draft`); never moves focus

---@class pi.ChatAttachments
---@field _items pi.ChatAttachment[]
---@field _buf integer
---@field _listeners fun(change: pi.AttachmentChange)[]
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

---@param item pi.Attachment
---@return pi.ChatAttachment
local function with_digest(item)
    return { name = item.name, data = item.data, mime = item.mime, digest = vim.fn.sha256(item.data) }
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
    self._listeners = {}
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
    local icon = Config.options.labels.attachment
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

---@param change pi.AttachmentChange
function Attachments:_rerender(change)
    if self._rerendering then
        return
    end
    self._rerendering = true
    self:_update_buffer()
    for _, listener in ipairs(self._listeners) do
        listener(change)
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
    self._items[#self._items + 1] = with_digest({ name = name, data = data, mime = mime })
    self:_rerender("added")
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
    self._items[#self._items + 1] = with_digest({ name = name, data = data, mime = "image/png" })
    self:_rerender("added")
    return true
end

---@param index integer
function Attachments:remove(index)
    if index >= 1 and index <= #self._items then
        table.remove(self._items, index)
        self:_rerender("removed")
    end
end

--- Empty the list because its draft was sent.
function Attachments:clear()
    self._items = {}
    self:_rerender("cleared")
end

--- Replace the whole list from outside.
---@param items pi.Attachment[]
function Attachments:replace(items)
    local replaced = {}
    for i, item in ipairs(items) do
        replaced[i] = with_digest(item)
    end
    self._items = replaced
    self:_rerender("replaced")
end

--- Independent copies of the attachments, without digests.
---@return pi.Attachment[]
function Attachments:snapshot()
    local out = {}
    for i, item in ipairs(self._items) do
        out[i] = { name = item.name, data = item.data, mime = item.mime }
    end
    return out
end

--- The current attachments, digests included. Read-only: callers must not
--- modify the returned list or its items.
---@return pi.ChatAttachment[]
function Attachments:items()
    return self._items
end

--- Restore rejected attachments ahead of any attachments added since submission.
---@param items pi.Attachment[]?
function Attachments:restore(items)
    if not items or #items == 0 then
        return
    end
    local current = self._items
    local restored = {}
    for i, item in ipairs(items) do
        restored[i] = with_digest(item)
    end
    vim.list_extend(restored, current)
    self._items = restored
    self:_rerender("restored")
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

--- Run `fn` after every change to the list.
---@param fn fun(change: pi.AttachmentChange)
function Attachments:on_change(fn)
    self._listeners[#self._listeners + 1] = fn
end

return Attachments
