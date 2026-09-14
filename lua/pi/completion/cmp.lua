--- nvim-cmp completion source for @-mentions and /commands.
--- Register with: cmp.register_source("pi", require("pi.completion.cmp").new())

local Matcher = require("pi.completion")
local FilesCache = require("pi.cache.files")

---@type table<string, integer>
local source_kinds = {
    extension = vim.lsp.protocol.CompletionItemKind.Event,
    ["pi.nvim"] = vim.lsp.protocol.CompletionItemKind.Function,
    prompt = vim.lsp.protocol.CompletionItemKind.Snippet,
    skill = vim.lsp.protocol.CompletionItemKind.Module,
}

local source = {}

function source.new()
    return setmetatable({}, { __index = source })
end

function source:is_available()
    return FilesCache.is_pi_prompt_buf()
end

function source:get_trigger_characters()
    return { "@", "/", "." }
end

function source:get_keyword_pattern()
    return [[\%(@\|/\)\S*]]
end

---@param line string
---@param trigger integer byte value of trigger character
---@return integer? column 1-indexed position of the trigger character
local function find_trigger(line, trigger)
    for col = #line, 1, -1 do
        local byte = line:byte(col)
        if byte == trigger then
            return col
        end
        if byte == 32 then
            return nil
        end
    end
    return nil
end

---@param params cmp.SourceCompletionApiParams
---@param callback fun(response: lsp.CompletionResponse|nil)
function source:complete(params, callback)
    local cmp = require("cmp")
    local line = params.context.cursor_before_line

    if params.context.cursor.row == 1 and line:byte(1) == 47 then
        local prefix = line:sub(2)
        local items = Matcher.complete_commands(prefix, function(cmd, is_fuzzy)
            return {
                label = "/" .. cmd.name,
                kind = source_kinds[cmd.source] or cmp.lsp.CompletionItemKind.Function,
                insertText = "/" .. cmd.name,
                filterText = "/" .. cmd.name,
                sortText = (is_fuzzy and "1" or "0") .. cmd.name,
                detail = cmd.source .. (cmd.description and (": " .. cmd.description) or ""),
            }
        end)
        callback({ items = items, isIncomplete = true })
        return
    end

    local at_col = find_trigger(line, 64)
    if not at_col then
        callback()
        return
    end

    local prefix = line:sub(at_col + 1)
    local items = Matcher.complete_files(prefix, function(path, kind, is_fuzzy)
        return {
            label = "@" .. path,
            kind = kind == "dir" and cmp.lsp.CompletionItemKind.Folder or cmp.lsp.CompletionItemKind.File,
            insertText = "@" .. path,
            filterText = "@" .. path,
            sortText = (is_fuzzy and "1" or "0") .. path,
        }
    end)
    callback({ items = items, isIncomplete = true })
end

return source
