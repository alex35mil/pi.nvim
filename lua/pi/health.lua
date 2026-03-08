local M = {}

M.check = function()
    vim.health.start("pi.nvim")

    local bin = require("pi.config").options.bin
    if vim.fn.executable(bin) == 1 then
        vim.health.ok("`" .. bin .. "` executable found")
    else
        vim.health.error("`" .. bin .. "` executable not found in PATH", {
            "Install pi from https://pi.dev",
        })
    end

    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10")
    else
        vim.health.warn("Neovim >= 0.10 recommended")
    end
end

return M
