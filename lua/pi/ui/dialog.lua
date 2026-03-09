--- Custom floating dialog UI for select, confirm, and input.

local M = {}

local ns = vim.api.nvim_create_namespace("pi-dialog")

local WINHIGHLIGHT = require("pi.ui.highlights").DIALOG_WINHIGHLIGHT

---@return boolean
local function is_insert()
    return vim.fn.mode():match("^i") ~= nil
end

---@return pi.DialogConfig
local function get_config()
    local config = require("pi.config")
    return config.options.ui.dialog
end

local BASE_KEYS = {
    confirm = { { "<CR>", modes = { "n", "i" } } },
    cancel = { "<Esc>", "q" },
    next = { "j", "<Down>" },
    prev = { "k", "<Up>" },
}

--- Bind a single key entry (string = normal only, table = specified modes).
---@param buf integer
---@param key string|pi.DialogKey
---@param handler function
local function bind_key(buf, key, handler)
    if type(key) == "string" then
        vim.keymap.set("n", key, handler, { buffer = buf, nowait = true })
    elseif type(key) == "table" then
        vim.keymap.set(key.modes or "n", key[1], handler, { buffer = buf, nowait = true })
    end
end

--- Bind base keys + user keys for a dialog action.
---@param buf integer
---@param action "confirm"|"cancel"|"next"|"prev"
---@param handler function
local function bind_keys(buf, action, handler)
    for _, key in ipairs(BASE_KEYS[action] or {}) do
        bind_key(buf, key, handler)
    end
    for _, key in ipairs(get_config().keys[action] or {}) do
        bind_key(buf, key, handler)
    end
end

---@param lines string[]
---@param title string
---@param opts? { modifiable?: boolean, min_width?: integer }
---@return { buf: integer, win: integer }
local function open_float(lines, title, opts)
    opts = opts or {}
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = opts.modifiable or false

    local max_width = opts.min_width or 0
    for _, line in ipairs(lines) do
        max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
    end
    local cfg = get_config()
    local pad = 4
    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local cap_w = cfg.max_width < 1 and math.floor(editor_w * cfg.max_width) or cfg.max_width
    local cap_h = cfg.max_height < 1 and math.floor(editor_h * cfg.max_height) or cfg.max_height
    local width = math.min(max_width + pad, cap_w)
    local height = math.min(#lines, cap_h)
    width = math.max(width, vim.fn.strdisplaywidth(title) + 4)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor((editor_h - height) / 2),
        col = math.floor((editor_w - width) / 2),
        width = width,
        height = height,
        style = "minimal",
        border = cfg.border,
        title = " " .. title .. " ",
        title_pos = "center",
    })
    vim.wo[win].winhighlight = WINHIGHLIGHT
    vim.wo[win].signcolumn = "yes"
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = true

    return { buf = buf, win = win }
end

---@param buf integer
---@param row integer 0-indexed
---@param total integer
local function highlight_selection(buf, row, total)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if row >= 0 and row < total then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
            sign_text = get_config().indicator,
            sign_hl_group = "PiDialogSelected",
        })
    end
end

--- Picker-style select dialog.
---@param opts { title: string, message?: string, options: string[], shortcuts?: table<string, string> }
---@param callback fun(choice: string?)
function M.select(opts, callback)
    local options = opts.options or {}
    if #options == 0 then
        callback(nil)
        return
    end

    local lines = {}
    local option_offset = 0 -- 0-indexed row where options start

    if opts.message and opts.message ~= "" then
        for _, line in ipairs(vim.split(opts.message, "\n", { plain = true })) do
            lines[#lines + 1] = line
        end
        lines[#lines + 1] = ""
        option_offset = #lines
    end

    for _, opt in ipairs(options) do
        lines[#lines + 1] = "  " .. opt
    end

    local was_insert = is_insert()
    vim.cmd("stopinsert")
    local float = open_float(lines, opts.title or "Select")
    local buf, win = float.buf, float.win
    local selected = 0 -- 0-indexed (relative to option_offset)

    vim.api.nvim_win_set_cursor(win, { option_offset + 1, 0 })
    highlight_selection(buf, option_offset + selected, #lines)

    local responded = false

    local function resolve(choice)
        if responded then
            return
        end
        responded = true
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
        vim.schedule(function()
            if was_insert then
                vim.cmd("startinsert")
            end
            callback(choice)
        end)
    end

    local function move(delta)
        selected = math.max(0, math.min(#options - 1, selected + delta))
        vim.api.nvim_win_set_cursor(win, { option_offset + selected + 1, 0 })
        highlight_selection(buf, option_offset + selected, #lines)
    end

    bind_keys(buf, "next", function()
        move(1)
    end)
    bind_keys(buf, "prev", function()
        move(-1)
    end)
    bind_keys(buf, "confirm", function()
        resolve(options[selected + 1])
    end)
    bind_keys(buf, "cancel", function()
        resolve(nil)
    end)
    if opts.shortcuts then
        for key, value in pairs(opts.shortcuts) do
            bind_key(buf, key, function()
                resolve(value)
            end)
        end
    end

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            resolve(nil)
        end,
    })
end

--- Confirm dialog with picker UI.
---@param opts { title: string, message?: string }
---@param callback fun(confirmed: boolean)
function M.confirm(opts, callback)
    M.select({
        title = opts.title or "Confirm",
        message = opts.message,
        options = { "Yes", "No" },
        shortcuts = {
            ["y"] = "Yes",
            ["n"] = "No",
        },
    }, function(choice)
        callback(choice == "Yes")
    end)
end

--- Input dialog with editable line.
---@param opts { title: string, default?: string }
---@param callback fun(value: string?)
function M.input(opts, callback)
    local default = opts.default or ""
    local lines = vim.split(default, "\n", { plain = true })

    local was_insert = is_insert()

    local float = open_float(lines, opts.title or "Input", { modifiable = true, min_width = 40 })
    local buf, win = float.buf, float.win

    -- Place cursor at end of last line and enter insert mode
    local last_line = lines[#lines] or ""
    vim.api.nvim_win_set_cursor(win, { #lines, #last_line })
    vim.cmd("startinsert!")

    local responded = false

    local function resolve(value)
        if responded then
            return
        end
        responded = true
        vim.cmd("stopinsert")
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
        vim.schedule(function()
            if was_insert then
                vim.cmd("startinsert")
            end
            callback(value)
        end)
    end

    local function submit()
        local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        resolve(table.concat(buf_lines, "\n"))
    end

    bind_keys(buf, "confirm", submit)
    bind_keys(buf, "cancel", function()
        resolve(nil)
    end)

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            resolve(nil)
        end,
    })
end

return M
