--- blink.cmp completion source for @-mentions and /commands.
--- Register in blink config: module = "pi.completion.blink"

local Matcher = require("pi.completion")
local FilesCache = require("pi.cache.files")

---@type table<string, vim.lsp.protocol.CompletionItemKind>
local source_kinds = {
    extension = vim.lsp.protocol.CompletionItemKind.Event,
    prompt = vim.lsp.protocol.CompletionItemKind.Snippet,
    skill = vim.lsp.protocol.CompletionItemKind.Module,
}

local source = {}

function source.new()
    return setmetatable({}, { __index = source })
end

function source:enabled()
    return FilesCache.is_pi_prompt_buf()
end

function source:get_trigger_characters()
    return { "@", "/", "." }
end

--- Walk backwards from cursor to find a trigger character.
---@param line string
---@param col integer cursor column (1-indexed byte)
---@param trigger integer byte value of trigger char
---@return integer? col 1-indexed position of the trigger char, or nil
local function find_trigger(line, col, trigger)
    for i = col, 1, -1 do
        local byte = line:byte(i)
        if byte == trigger then
            return i
        end
        if byte == 32 then -- space
            return nil
        end
    end
    return nil
end

function source:get_completions(ctx, callback)
    local line = ctx.line
    local col = ctx.cursor[2]

    -- Try /command completion first — only at start of first line
    if ctx.cursor[1] == 1 then
        local slash_col = find_trigger(line, col, 47) -- /
        if slash_col and slash_col == 1 then
            local prefix = line:sub(2, col)
            local items = Matcher.complete_commands(prefix, function(cmd, is_fuzzy)
                return {
                    label = "/" .. cmd.name,
                    kind = source_kinds[cmd.source] or vim.lsp.protocol.CompletionItemKind.Function,
                    insertText = "/" .. cmd.name,
                    filterText = "/" .. cmd.name,
                    sortText = (is_fuzzy and "1" or "0") .. cmd.name,
                    score_offset = is_fuzzy and -10 or 0,
                    labelDetails = { description = cmd.description or "" },
                }
            end)
            callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
            return
        end
    end

    -- @mention completion
    local at_col = find_trigger(line, col, 64) -- @
    if not at_col then
        callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
        return
    end

    local prefix = line:sub(at_col + 1, col)
    local items = Matcher.complete_files(prefix, function(path, kind, is_fuzzy)
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
