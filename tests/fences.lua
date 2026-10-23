-- Run from the repository root: nvim --headless -u NONE -l tests/fences.lua
vim.opt.runtimepath:append(vim.fn.getcwd())

local Fences = require("pi.ui.chat.fences")
local History = require("pi.ui.chat.history")
local Tools = require("pi.ui.chat.tools")

local prose = "Following assistant prose **bold**."
local output = "```text\n1\n2\n3\n4\n5\n6\n```"
local histories = {} ---@type pi.ChatHistory[]
local passed, failed = 0, 0

---@param actual any
---@param expected any
local function eq(actual, expected)
    assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

---@return pi.ChatHistory
local function history()
    local h = History.new(vim.api.nvim_get_current_tabpage())
    histories[#histories + 1] = h
    return h
end

--- Drain scheduled UI callbacks in order, without timing-based test sleeps.
local function drain()
    local done = false
    vim.schedule(function()
        done = true
    end)
    assert(
        vim.wait(1000, function()
            return done
        end),
        "scheduled rendering did not finish"
    )
    eq(vim.v.errmsg, "")
end

---@param name string
---@param fn fun()
local function test(name, fn)
    vim.v.errmsg = ""
    local ok, err = xpcall(fn, debug.traceback)
    for _, h in ipairs(histories) do
        vim.api.nvim_buf_delete(h:buf(), { force = true })
    end
    histories = {}
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. "\n" .. err)
    end
end

---@param h pi.ChatHistory
---@return string[]
local function lines(h)
    return vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
end

---@param source string
---@param row integer
local function assert_paragraph(source, row)
    local parser = vim.treesitter.get_string_parser(source, "markdown", { injections = { markdown = "" } })
    local root = parser:parse()[1]:root()
    local node = root:named_descendant_for_range(row, 0, row, 1)
    local paragraph = false
    while node do
        assert(node:type() ~= "fenced_code_block", "following prose is inside a fence")
        paragraph = paragraph or node:type() == "paragraph"
        node = node:parent()
    end
    assert(paragraph, "following prose is not a paragraph")
end

---@param h pi.ChatHistory
local function assert_prose(h)
    local content = lines(h)
    local found = false
    for i, line in ipairs(content) do
        if line == prose then
            assert_paragraph(table.concat(content, "\n"), i - 1)
            found = true
        end
    end
    assert(found, "assistant prose was lost")
end

---@param h pi.ChatHistory
local function append_assistant(h)
    h:on_agent_start()
    h:on_text_delta(prose)
    h:on_agent_end()
    drain()
end

---@param text string
---@return table
local function result(text)
    return { content = { { type = "text", text = text } } }
end

---@param name string
---@return table
local function args(name)
    return name == "codemode" and { code = 'text("Markdown output")' } or { command = "print Markdown" }
end

---@param h pi.ChatHistory
---@param block pi.ToolBlock
local function assert_tool_marks(h, block)
    local first = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.icon_extmark, {})[1]
    local last = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.end_extmark, {})[1]
    local marks = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), { first, 0 }, { last, -1 }, { details = true })
    local borders, highlights = {}, {}
    for _, mark in ipairs(marks) do
        local row, details = mark[2], mark[4]
        for _, chunk in ipairs(details.virt_text or {}) do
            if chunk[2] == "PiToolBorder" then
                borders[row] = true
            end
        end
        if details.hl_group == "PiToolOutput" then
            highlights[row] = true
        end
    end
    local content = lines(h)
    for row = first, last do
        assert(borders[row], "missing border at row " .. row)
    end
    for row = first + 1, last - 1 do
        local line = content[row + 1]
        if line == "```" or line == "6" then
            assert(highlights[row], "missing output highlight at row " .. row)
        end
    end
end

local fixtures = {
    { "plain", "ordinary prose", nil },
    { "balanced", "```text\n1\n```", nil },
    { "unclosed triple", "```text\n1", "```" },
    { "unclosed four", "````markdown\n1", "````" },
    { "unclosed tilde", "~~~text\n1", "~~~" },
    { "mixed delimiters", "~~~markdown\n```lua\n1", "~~~" },
    { "short literal delimiter", "````markdown\n```lua\n1", "````" },
    { "closer with trailing text", "```text\n```not-a-closer\n1", "```" },
    { "longer valid closer", "```text\n1\n````", nil },
    { "one-space fence", " ```text\n1", "```" },
    { "two-space fence", "  ```text\n1", "```" },
    { "three-space fence", "   ```text\n1", "```" },
    { "indented code", "    ```text\n    1", nil },
    { "quote", "> ```text\n> 1", nil },
    { "list", "- item\n\n  ```text\n  1", nil },
    { "list then outside prose", "- item\n\n  ```text\n  1\n\nOutside prose", nil },
    { "literal HTML", "<pre>\n```text\n</pre>", nil },
    { "trailing newline", "~~~~text\n1\n", "~~~~" },
}

for _, fixture in ipairs(fixtures) do
    test("helper: " .. fixture[1], function()
        local source, expected = fixture[2], fixture[3]
        local closer = Fences.closer(source)
        eq(closer, expected)
        local protected = source .. (closer and ("\n" .. closer) or "")
        eq(Fences.closer(protected), nil)
        local text = protected .. "\n\n" .. prose
        assert_paragraph(text, #vim.split(text, "\n") - 1)
    end)
end

for _, name in ipairs({ "bash", "codemode", "custom_tool" }) do
    test(name .. ": collapse / expand / re-collapse with following message", function()
        local h = history()
        local original_result = result(output)
        local snapshot = vim.deepcopy(original_result)
        h:on_tool_start(name, "call", args(name))
        h:on_tool_end(name, "call", original_result, false)
        drain()
        local block = h._tool_blocks.call
        eq(block.expanded, false)
        local cached = vim.deepcopy(block.collapsed_inner_lines)
        append_assistant(h)
        assert_prose(h)
        assert_tool_marks(h, block)
        for _ = 1, 2 do
            assert(h:_set_tool_block_expanded(block, true))
            local first = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.icon_extmark, {})[1] + 1
            local last = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.end_extmark, {})[1]
            eq(vim.api.nvim_buf_get_lines(h:buf(), first, last, false), block.expanded_inner_lines)
            assert_prose(h)
            assert_tool_marks(h, block)
            assert(h:_set_tool_block_expanded(block, false))
            eq(block.collapsed_inner_lines, cached)
            assert_prose(h)
            assert_tool_marks(h, block)
        end
        eq(original_result, snapshot)
    end)
end

test("preview: input fence and hidden output", function()
    local preview, specs = Tools.build_collapsed_view({ "```lua", "1", "2", "```" }, { output }, true, 1, 0)
    eq(preview, { "```lua", " +3 lines", "```" })
    eq(specs, { "input", "summary", "input" })
    eq(Fences.closer(table.concat(preview, "\n")), nil)
end)

test("preview: unchanged balanced output and aligned specs", function()
    local preview, specs = Tools.build_collapsed_view({ "command" }, { "```", "1", "```" }, true, 1, 3)
    eq(preview, { "command", "", "```", "1", "```" })
    eq(specs, { "input", "separator", "output", "output", "output" })
end)

test("preview: tail counts and width-shortened closer", function()
    local preview, specs = Tools.build_collapsed_view({}, vim.split(output, "\n"), true, 1, 1)
    eq(preview, { "", "…7 lines", "```", "```" })
    eq(#preview, #specs)
    local narrow, narrow_specs = Tools.build_collapsed_view({}, { "````", "1", "````    " }, true, 1, 3, 6)
    eq(narrow[#narrow], "````")
    assert(narrow[#narrow - 1]:find("…", 1, true))
    eq(#narrow, #narrow_specs)
    eq(Fences.closer(table.concat(narrow, "\n")), nil)
end)

test("expanded output: annotation follows actual delimiter length", function()
    local h = history()
    h:set_blocks_expanded(true)
    h:on_tool_start("bash", "call", args("bash"))
    h:on_tool_end("bash", "call", result("````text\n1"), false)
    drain()
    local found = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
            if chunk[1] == " ← auto-closed" then
                eq(mark[3], 4)
                eq(lines(h)[mark[2] + 1], "````")
                found = true
            end
        end
    end
    assert(found, "missing auto-closed annotation")
end)

for _, fixture in ipairs({ fixtures[3], fixtures[4], fixtures[5], fixtures[7], fixtures[11], fixtures[15] }) do
    test("user boundary: " .. fixture[1], function()
        local h = history()
        h:add_user_message(fixture[2])
        append_assistant(h)
        assert_prose(h)
    end)
    test("assistant split deltas: " .. fixture[1], function()
        local h = history()
        h:on_agent_start()
        h:on_text_delta(fixture[2]:sub(1, 2))
        h:on_text_delta(fixture[2]:sub(3))
        h:on_agent_end()
        append_assistant(h)
        assert_prose(h)
    end)
end

for _, name in ipairs({ "bash", "codemode" }) do
    test(name .. ": live output replaced by final result", function()
        local h = history()
        h:on_tool_start(name, "call", args(name))
        h:on_tool_update(name, "call", { partialResult = result("~~~~text\npartial") })
        drain()
        append_assistant(h)
        assert_prose(h)
        h:on_tool_update(name, "call", { partialResult = result("````text\nreplacement") })
        drain()
        assert_prose(h)
        h:on_tool_end(name, "call", result(output), false)
        drain()
        eq(h._tool_blocks.call.live_update_extmark, nil)
        assert(not table.concat(lines(h), "\n"):find("replacement", 1, true))
        assert_prose(h)
    end)
end

test("assistant completion uses only assistant source after tool output", function()
    local h = history()
    h:on_agent_start()
    h:on_text_delta("Assistant source")
    h:on_tool_start("bash", "call", args("bash"))
    h:on_tool_end("bash", "call", result("```text\n1"), false)
    drain()
    eq(table.concat(h._agent_text_chunks), "Assistant source")
    h:on_agent_end()
    drain()
    eq(lines(h)[#lines(h)], " completed")
    append_assistant(h)
    assert_prose(h)
end)

test("ordinary table rendering and fenced table preservation", function()
    local table_text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    local h = history()
    h:on_agent_start()
    h:on_text_delta(table_text .. "\n\n```text\n" .. table_text .. "\n```")
    h:on_agent_end()
    drain()
    local text = table.concat(lines(h), "\n")
    assert(text:find("│", 1, true), "ordinary table was not formatted")
    assert(text:find("```text\n" .. table_text .. "\n```", 1, true), "fenced table was modified")
end)

test("optional parser absent: plain rendering continues", function()
    local get_parser = vim.treesitter.get_string_parser
    local get_files = vim.api.nvim_get_runtime_file
    vim.treesitter.get_string_parser = function()
        error("no parser for markdown")
    end
    vim.api.nvim_get_runtime_file = function(pattern, all)
        if pattern == "parser/markdown.*" then
            return {}
        end
        return get_files(pattern, all)
    end
    local ok, err = xpcall(function()
        eq(Fences.closer("```text\n1"), nil)
        local h = history()
        h:add_user_message("user text")
        h:on_tool_start("bash", "call", args("bash"))
        h:on_tool_end("bash", "call", result(output), false)
        append_assistant(h)
        assert(table.concat(lines(h), "\n"):find(prose, 1, true))
        local preview = Tools.build_collapsed_view({}, { "```" }, true, 1, 1)
        eq(preview, { "", "```" })
    end, debug.traceback)
    vim.treesitter.get_string_parser = get_parser
    vim.api.nvim_get_runtime_file = get_files
    assert(ok, err)
end)

test("unexpected parser failure is explicit", function()
    local get_parser = vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function()
        error("analysis failure")
    end
    local ok, err = pcall(Fences.closer, "```text\n1")
    vim.treesitter.get_string_parser = get_parser
    assert(not ok, "unexpected failure was silently ignored")
    assert(tostring(err):find("analysis failure", 1, true))
end)

print(string.format("Fence regressions: %d passed, %d failed", passed, failed))
if failed > 0 then
    vim.cmd("cquit 1")
end
