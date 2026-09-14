local M = {}

local palettes = {
    dark = {
        accent = 0x8ABEB7,
        border = 0x5F87FF,
        success = 0xB5BD68,
        error = 0xCC6666,
        warning = 0xFFFF00,
        muted = 0x808080,
        thinking = 0x808080,
        command = 0x9575CD,
    },
    light = {
        accent = 0x5A8080,
        border = 0x547DA7,
        success = 0x588458,
        error = 0xAA5555,
        warning = 0x9A7326,
        muted = 0x6C6C6C,
        thinking = 0x6C6C6C,
        command = 0x7E57C2,
    },
}

M.DIALOG_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiDialogTitle"
M.CHAT_HISTORY_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatHistoryFloatTitle"
M.CHAT_PROMPT_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatTitle"
M.CHAT_PROMPT_ATTENTION_WINHIGHLIGHT =
    "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatAttentionTitle"
M.CHAT_ATTACHMENTS_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatAttachmentsFloatTitle"
M.DIFF_WINHIGHLIGHT = "WinBar:PiDiffWinbar,WinBarNC:PiDiffWinbar"

local function set_defaults()
    local fallback = palettes[vim.o.background == "light" and "light" or "dark"]
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
    local func = vim.api.nvim_get_hl(0, { name = "Function", link = false })
    local string_hl = vim.api.nvim_get_hl(0, { name = "String", link = false })
    local keyword_hl = vim.api.nvim_get_hl(0, { name = "Keyword", link = false })
    local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
    local warning = vim.api.nvim_get_hl(0, { name = "WarningMsg", link = false })
    local diagnostic_error = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })

    local palette = {
        accent = title.fg or fallback.accent,
        border = func.fg or fallback.border,
        success = string_hl.fg or fallback.success,
        error = diagnostic_error.fg or fallback.error,
        warning = warning.fg or fallback.warning,
        muted = comment.fg or fallback.muted,
        thinking = comment.fg or fallback.thinking,
        command = keyword_hl.fg or fallback.command,
    }

    -- These groups provide existing badge and winbar backgrounds. Keep them
    -- colorscheme-derived; the semantic palette is for text and glyphs only.
    local user = title
    local agent = func

    vim.api.nvim_set_hl(0, "PiBotIcon", { default = true, fg = palette.warning, bold = true })
    if user.fg then
        vim.api.nvim_set_hl(0, "PiUserMessageLabel", { default = true, fg = user.fg, bold = true })
    end
    if agent.fg then
        vim.api.nvim_set_hl(0, "PiAgentResponseLabel", { default = true, link = "PiBotIcon" })
    end
    vim.api.nvim_set_hl(0, "PiDebugLabel", { default = true, fg = comment.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiStartupLabel", { default = true, fg = comment.fg, bold = true, nocombine = true })
    vim.api.nvim_set_hl(0, "PiStartupHint", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiStartupErrorLabel", { default = true, fg = palette.error, bold = true, nocombine = true })
    vim.api.nvim_set_hl(0, "PiStartupDetail", { default = true, fg = comment.fg, nocombine = true })
    vim.api.nvim_set_hl(0, "PiStartupError", { default = true, fg = diagnostic_error.fg, nocombine = true })
    vim.api.nvim_set_hl(0, "PiCompactionLabel", { default = true, fg = palette.command, bold = true, nocombine = true })
    vim.api.nvim_set_hl(0, "PiCompactionText", { default = true, fg = comment.fg, nocombine = true })
    vim.api.nvim_set_hl(0, "PiCompactionHint", { default = true, fg = comment.fg, italic = true, nocombine = true })
    vim.api.nvim_set_hl(0, "PiMessageDateTime", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiMessageQueueTag", { default = true, fg = palette.warning, italic = true })
    vim.api.nvim_set_hl(0, "PiPendingQueueLabel", { default = true, fg = palette.warning, bold = true })
    vim.api.nvim_set_hl(0, "PiPendingQueueText", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiMessageAttachments", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiThinking", { default = true, fg = palette.thinking, italic = true })
    vim.api.nvim_set_hl(0, "PiToolBorder", { default = true, fg = palette.border })
    vim.api.nvim_set_hl(0, "PiToolIcon", { default = true, fg = palette.warning })
    vim.api.nvim_set_hl(0, "PiToolSuccessIcon", { default = true, fg = palette.success })
    vim.api.nvim_set_hl(0, "PiToolHeader", { default = true, fg = palette.accent, bold = true })
    vim.api.nvim_set_hl(0, "PiToolCall", { default = true, fg = palette.border })
    vim.api.nvim_set_hl(0, "PiToolOutput", { default = true, fg = palette.muted })
    vim.api.nvim_set_hl(0, "PiToolStatus", { default = true, fg = palette.success, italic = true })
    vim.api.nvim_set_hl(0, "PiToolCollapsed", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolError", { default = true, fg = diagnostic_error.fg or palette.error, italic = true })
    vim.api.nvim_set_hl(0, "PiWarning", { default = true, fg = warning.fg or palette.warning, italic = true })
    vim.api.nvim_set_hl(0, "PiTableBorder", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiTableHeader", { default = true, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffAdd", { default = true, link = "DiffAdd" })
    vim.api.nvim_set_hl(0, "PiDiffDelete", { default = true, link = "DiffDelete" })
    vim.api.nvim_set_hl(0, "PiDiffLineNr", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiDebug", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiError", { default = true, fg = diagnostic_error.fg })
    vim.api.nvim_set_hl(0, "PiWelcome", { default = true, fg = palette.warning })
    vim.api.nvim_set_hl(0, "PiWelcomeHint", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiBusy", { default = true, fg = palette.warning, bold = true })
    vim.api.nvim_set_hl(0, "PiBusyTime", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiMention", { default = true, fg = palette.border, underline = true })
    vim.api.nvim_set_hl(0, "PiCommand", { default = true, fg = palette.command, bold = true })
    vim.api.nvim_set_hl(0, "PiAttachmentFilename", { default = true, fg = normal.fg })
    vim.api.nvim_set_hl(0, "PiAttachmentIcon", { default = true, fg = palette.command })

    vim.api.nvim_set_hl(0, "PiChatHistoryWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiChatHistoryWinbarTitle", { default = true, fg = user.fg, bg = normal.bg, bold = true })
    vim.api.nvim_set_hl(0, "PiChatPromptWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiChatPromptWinbarTitle", { default = true, fg = comment.fg, bg = normal.bg, bold = true })
    vim.api.nvim_set_hl(
        0,
        "PiChatPromptWinbarAttentionTitle",
        { default = true, fg = warning.fg, bg = normal.bg, bold = true }
    )
    vim.api.nvim_set_hl(0, "PiChatAttachmentsWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(
        0,
        "PiChatAttachmentsWinbarTitle",
        { default = true, fg = comment.fg, bg = normal.bg, bold = true }
    )

    vim.api.nvim_set_hl(0, "PiFloat", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiFloatBorder", { default = true, fg = comment.fg, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiDialogTitle", { default = true, fg = title.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiChatHistoryFloatTitle", { default = true, fg = user.fg, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiChatPromptFloatTitle", { default = true, fg = comment.fg, bg = normal.bg })
    vim.api.nvim_set_hl(
        0,
        "PiChatPromptFloatAttentionTitle",
        { default = true, fg = warning.fg, bg = normal.bg, bold = true }
    )
    vim.api.nvim_set_hl(0, "PiChatAttachmentsFloatTitle", { default = true, fg = comment.fg, bg = normal.bg })

    vim.api.nvim_set_hl(0, "PiZen", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiZenBackdrop", { default = true, bg = normal.bg })

    vim.api.nvim_set_hl(0, "PiDialogSelected", { default = true, link = "Visual" })

    vim.api.nvim_set_hl(0, "PiDiffWinbar", { default = true, bg = agent.fg })
    vim.api.nvim_set_hl(0, "PiDiffWinbarCurrent", { default = true, fg = normal.bg, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffWinbarProposed", { default = true, fg = normal.bg, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffWinbarHint", { default = true, fg = normal.bg })
    vim.api.nvim_set_hl(0, "PiDiffReviewNote", { default = true, fg = warning.fg, italic = true })

    vim.api.nvim_set_hl(0, "PiStatusLine", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiStatusLineIcon", { default = true, fg = palette.border })
    vim.api.nvim_set_hl(0, "PiStatusLineActivity", { default = true, fg = palette.warning, bold = true })
    vim.api.nvim_set_hl(0, "PiStatusLineKey", { default = true, fg = palette.accent, bold = true })
    vim.api.nvim_set_hl(0, "PiStatusLineAttention", { default = true, fg = warning.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiStatusLineWarning", { default = true, fg = warning.fg })
    vim.api.nvim_set_hl(0, "PiStatusLineError", { default = true, fg = diagnostic_error.fg })
end

function M.setup()
    set_defaults()
    vim.api.nvim_create_autocmd("ColorScheme", { callback = set_defaults })
end

return M
