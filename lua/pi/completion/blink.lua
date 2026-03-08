--- blink.cmp completion source for @-mentions and commands.
--- Register in blink config: module = "pi.completion.blink"

local Files = require("pi.files")

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

    -- Typed prefix after @
    local prefix = line:sub(at_col + 1, col)
    local project_files = Files.list()
    local items = {}
    local seen_dirs = {}

    for _, path in ipairs(project_files) do
        if prefix == "" or path:sub(1, #prefix) == prefix then
            local rest = path:sub(#prefix + 1)
            local slash = rest:find("/")
            if slash then
                -- Directory entry: show only next level
                local dir = prefix .. rest:sub(1, slash)
                if not seen_dirs[dir] then
                    seen_dirs[dir] = true
                    items[#items + 1] = {
                        label = "@" .. dir,
                        kind = vim.lsp.protocol.CompletionItemKind.Folder,
                        insertText = "@" .. dir,
                        filterText = "@" .. dir,
                    }
                end
            else
                -- File entry
                items[#items + 1] = {
                    label = "@" .. path,
                    kind = vim.lsp.protocol.CompletionItemKind.File,
                    insertText = "@" .. path,
                    filterText = "@" .. path,
                }
            end
        end
    end
    callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
end

return source
