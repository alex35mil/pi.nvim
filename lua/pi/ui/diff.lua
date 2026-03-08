--- Pre-execution diff review for edit/write tools.
--- Shows a diff before the tool executes; user accepts, modifies->accepts, or rejects.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")

---@param path string
---@return string[]
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    return vim.split(content, "\n", { plain = true })
end

---@param path string
---@param lines string[]
---@return boolean
local function write_file(path, lines)
    local dir = vim.fn.fnamemodify(path, ":h")
    vim.fn.mkdir(dir, "p")
    local f = io.open(path, "w")
    if not f then
        Notify.error("Failed to write: " .. path)
        return false
    end
    f:write(table.concat(lines, "\n"))
    f:close()
    return true
end

---@param path string
---@return string
local function get_filetype(path)
    return vim.filetype.match({ filename = path }) or ""
end

---@param abs_path string
local function reload_buf_for_file(abs_path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            if vim.api.nvim_buf_get_name(b) == abs_path then
                vim.api.nvim_buf_call(b, function()
                    vim.cmd("edit!")
                end)
            end
        end
    end
end

---@param name string
local function wipe_stale_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end
end

---@param path string?
---@return string?
local function abs(path)
    if not path then
        return nil
    end
    if vim.startswith(path, "/") then
        return path
    end
    return vim.fn.getcwd() .. "/" .. path
end

--- Apply an edit to lines in memory.
---@param lines string[]
---@param old_str string
---@param new_str string
---@return string[]
local function apply_edit(lines, old_str, new_str)
    local content = table.concat(lines, "\n")
    local start, finish = content:find(old_str, 1, true)
    if not start then
        Notify.error("diff: old content not found in file")
        return lines
    end
    local result = content:sub(1, start - 1) .. new_str .. content:sub(finish + 1)
    return vim.split(result, "\n", { plain = true })
end

--- Open a diff review for a tool call.
---@param payload { prompt: string, toolName: string, toolInput: table }
---@param callback fun(result: string) Called with "Accept", json-encoded AcceptModified, or "Reject"
function M.open(payload, callback)
    local input = payload.toolInput
    local path = abs(input.path)
    if not path then
        callback("Reject")
        return
    end

    local before_lines = read_file(path)
    local proposed_lines

    if payload.toolName == "edit" then
        local old_str = input.oldText or ""
        local new_str = input.newText or ""
        proposed_lines = apply_edit(before_lines, old_str, new_str)
    elseif payload.toolName == "write" then
        local content = input.content or ""
        proposed_lines = vim.split(content, "\n", { plain = true })
    else
        Notify.error("diff: unexpected tool: " .. tostring(payload.toolName))
        callback("Reject")
        return
    end

    local ft = get_filetype(path)
    local rel_path = vim.fn.fnamemodify(path, ":~:.")
    local after_name = "pi://review" .. path

    local prev_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local review_tab = vim.api.nvim_get_current_tabpage()

    -- Left: open the real original file
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd("noautocmd edit " .. vim.fn.fnameescape(path))
    local before_buf = vim.api.nvim_win_get_buf(left_win)
    local prev_modifiable = vim.bo[before_buf].modifiable
    local prev_readonly = vim.bo[before_buf].readonly
    vim.bo[before_buf].modifiable = false
    vim.bo[before_buf].readonly = true
    vim.cmd("diffthis")
    if ft ~= "" then
        vim.bo[before_buf].filetype = ft
    end

    -- Right: proposed changes (editable)
    wipe_stale_buf(after_name)
    local after_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(after_buf, 0, -1, false, proposed_lines)
    vim.bo[after_buf].buftype = "acwrite"
    vim.api.nvim_buf_set_name(after_buf, after_name)
    vim.cmd("vsplit")
    local right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right_win, after_buf)
    if ft ~= "" then
        vim.bo[after_buf].filetype = ft
    end
    vim.cmd("diffthis")

    vim.wo[right_win].number = true
    vim.cmd("wincmd =")

    vim.schedule(function()
        if not vim.api.nvim_tabpage_is_valid(review_tab) then
            return
        end
        pcall(vim.api.nvim_win_call, left_win, function()
            vim.cmd("normal! gg]c")
        end)
        vim.api.nvim_set_current_win(right_win)
        vim.cmd("stopinsert")
        vim.defer_fn(function()
            if vim.api.nvim_tabpage_is_valid(review_tab) then
                vim.cmd("diffupdate")
            end
        end, 50)
    end)

    local keymaps = Config.options.keymaps
    local accept_key = keymaps.diff_accept
    local reject_key = keymaps.diff_reject
    vim.wo[left_win].winbar = " %#PiDiffStatusCurrent#CURRENT: " .. rel_path .. "%*"
    vim.wo[right_win].winbar = " %#PiDiffStatusProposed#PROPOSED: "
        .. rel_path
        .. "%*  ["
        .. accept_key
        .. "=accept  "
        .. reject_key
        .. "=reject]"

    local responded = false

    local function close_review_tab()
        -- diffoff on both windows to restore fold/scroll settings
        for _, w in ipairs({ left_win, right_win }) do
            if vim.api.nvim_win_is_valid(w) then
                vim.api.nvim_win_call(w, function()
                    vim.cmd("diffoff")
                end)
            end
        end
        -- Restore the real file buffer's original state
        if vim.api.nvim_buf_is_valid(before_buf) then
            vim.bo[before_buf].modifiable = prev_modifiable
            vim.bo[before_buf].readonly = prev_readonly
        end
        if review_tab and vim.api.nvim_tabpage_is_valid(review_tab) then
            vim.api.nvim_set_current_tabpage(review_tab)
            vim.cmd("tabclose")
        end
        if vim.api.nvim_tabpage_is_valid(prev_tab) then
            vim.api.nvim_set_current_tabpage(prev_tab)
        end
        local session = require("pi.sessions.manager").get()
        if session then
            session.chat:ensure_shown_and_focus_prompt()
        end
    end

    local function accept()
        if responded then
            return
        end
        responded = true

        local final_lines = vim.api.nvim_buf_get_lines(after_buf, 0, -1, false)
        write_file(path, final_lines)
        require("pi.files").invalidate()
        reload_buf_for_file(vim.fn.fnamemodify(path, ":p"))
        close_review_tab()

        -- Check if user modified the proposed content
        local modified = #final_lines ~= #proposed_lines
        if not modified then
            for i, line in ipairs(final_lines) do
                if line ~= proposed_lines[i] then
                    modified = true
                    break
                end
            end
        end

        if modified then
            callback(vim.json.encode({
                result = "AcceptModified",
                content = table.concat(final_lines, "\n"),
            }))
        else
            callback("Accept")
        end
    end

    local function reject()
        if responded then
            return
        end
        responded = true
        close_review_tab()
        callback("Reject")
    end

    for _, b in ipairs({ before_buf, after_buf }) do
        vim.keymap.set("n", accept_key, accept, { buffer = b, desc = "Accept edit" })
        vim.keymap.set("n", reject_key, reject, { buffer = b, desc = "Reject edit" })
    end

    -- :w on the proposed buffer accepts the diff
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = after_buf,
        callback = function()
            accept()
        end,
    })
end

return M
