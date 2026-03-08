local M = {}

M.DIALOG_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiDialogTitle"
M.CHAT_HISTORY_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatHistoryFloatTitle"
M.CHAT_PROMPT_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatTitle"
M.CHAT_ATTACHMENTS_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatAttachmentsFloatTitle"

local function set_defaults()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
    local func = vim.api.nvim_get_hl(0, { name = "Function", link = false })
    local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
    local diagnostic_error = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })

    local user = title
    local agent = func

    if user.fg then
        vim.api.nvim_set_hl(0, "PiUserMessageLabel", { default = true, fg = normal.bg, bg = user.fg, bold = true })
    end
    if agent.fg then
        vim.api.nvim_set_hl(0, "PiAgentResponseLabel", { default = true, fg = normal.bg, bg = agent.fg, bold = true })
    end
    vim.api.nvim_set_hl(0, "PiDebugLabel", { default = true, fg = normal.bg, bg = comment.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiMessageDateTime", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiMessageAttachments", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiThinking", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolBorder", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiToolHeader", { default = true, fg = func.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiToolCall", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolOutput", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiToolStatus", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolError", { default = true, fg = diagnostic_error.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiDebug", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiError", { default = true, fg = diagnostic_error.fg })
    vim.api.nvim_set_hl(0, "PiBusy", { default = true, fg = agent.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiBusyTime", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiMention", { default = true, fg = normal.fg, underline = true })
    vim.api.nvim_set_hl(0, "PiAttachmentFilename", { default = true, fg = normal.fg })
    vim.api.nvim_set_hl(0, "PiAttachmentIcon", { default = true, fg = comment.fg })

    vim.api.nvim_set_hl(0, "PiChatHistoryWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiChatHistoryWinbarTitle", { default = true, fg = normal.bg, bg = user.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiChatPromptWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiChatPromptWinbarTitle", { default = true, fg = comment.fg, bg = normal.bg, bold = true })
    vim.api.nvim_set_hl(0, "PiChatAttachmentsWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(
        0,
        "PiChatAttachmentsWinbarTitle",
        { default = true, fg = comment.fg, bg = normal.bg, bold = true }
    )

    vim.api.nvim_set_hl(0, "PiFloat", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiFloatBorder", { default = true, fg = comment.fg, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiDialogTitle", { default = true, fg = normal.bg, bg = agent.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiChatHistoryFloatTitle", { default = true, fg = normal.bg, bg = user.fg })
    vim.api.nvim_set_hl(0, "PiChatPromptFloatTitle", { default = true, fg = comment.fg, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiChatAttachmentsFloatTitle", { default = true, fg = comment.fg, bg = normal.bg })

    vim.api.nvim_set_hl(0, "PiDialogSelected", { default = true, link = "Visual" })

    vim.api.nvim_set_hl(0, "PiDiffStatusCurrent", { default = true, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffStatusProposed", { default = true, bold = true })
end

function M.setup()
    vim.api.nvim_create_autocmd({ "ColorScheme", "VimEnter" }, { callback = set_defaults })
end

return M
