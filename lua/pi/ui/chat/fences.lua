--- Keep a rendered Markdown fence from absorbing the next message.

local M = {}

--- Return the matching closer only when a following paragraph would be fenced.
--- The probe stays private: container boundaries must be interpreted by the same
--- Markdown parser as the history, rather than by a second delimiter scanner.
---@param text string exact rendered source, after any preview truncation
---@return string? closer
function M.closer(text)
    local source = text .. "\n\npi boundary"
    local _, newlines = text:gsub("\n", "")
    local row = newlines + 2
    -- Only the outer Markdown grammar matters; do not parse injected languages.
    local ok, parser = pcall(vim.treesitter.get_string_parser, source, "markdown", {
        injections = { markdown = "" },
    })
    if not ok then
        -- Markdown highlighting is optional. A missing parser cannot leak syntax.
        if #vim.api.nvim_get_runtime_file("parser/markdown.*", false) == 0 then
            return nil
        end
        error("Could not analyze Markdown fence boundary: " .. tostring(parser))
    end

    local trees = parser:parse()
    if not trees or not trees[1] then
        error("Could not parse Markdown fence boundary")
    end
    local node = trees[1]:root():named_descendant_for_range(row, 0, row, 1)
    while node and node:type() ~= "fenced_code_block" do
        node = node:parent()
    end
    if not node then
        return nil
    end
    for child in node:iter_children() do
        if child:type() == "fenced_code_block_delimiter" then
            return vim.trim(vim.treesitter.get_node_text(child, source))
        end
    end
    error("Active Markdown fence has no opening delimiter")
end

return M
