--- blink.cmp completion source for @-mentions and commands.
--- Register in blink config: module = "pi.completion.blink"

local Files = require("pi.files")
local Matcher = require("pi.completion")

local source = {}

function source.new()
    return setmetatable({}, { __index = source })
end

function source:enabled()
    return Files.is_pi_prompt_buf()
end

function source:get_trigger_characters()
    return { "@", "/", "." }
end

function source:get_completions(ctx, callback)
    local line = ctx.line
    local col = ctx.cursor[2]
    -- Walk backwards from cursor to find @
    local at_col = nil
    for i = col, 1, -1 do
        local byte = line:byte(i)
        if byte == 64 then -- @
            at_col = i
            break
        end
        if byte == 32 then -- space
            break
        end
    end
    if not at_col then
        callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
        return
    end

    local prefix = line:sub(at_col + 1, col)
    local items = Matcher.complete(prefix, function(path, kind, is_fuzzy)
        if is_fuzzy then
            return {
                label = "@" .. path,
                kind = vim.lsp.protocol.CompletionItemKind.File,
                insertText = "@" .. path,
                filterText = "@" .. path,
                sortText = "1" .. path,
                score_offset = -10,
            }
        end
        return {
            label = "@" .. path,
            kind = kind == "dir" and vim.lsp.protocol.CompletionItemKind.Folder
                or vim.lsp.protocol.CompletionItemKind.File,
            insertText = "@" .. path,
            filterText = "@" .. path,
            sortText = "0" .. path,
        }
    end)

    callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
end

return source
