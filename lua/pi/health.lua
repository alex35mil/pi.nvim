local Compat = require("pi.compat")

local M = {}

---@param bin string
---@return string? version
---@return string? err
local function get_pi_version(bin)
    local output = vim.fn.system({ bin, "--version" })
    if vim.v.shell_error ~= 0 then
        return nil, "failed to run `" .. bin .. " --version`: " .. vim.trim(output)
    end

    local version = Compat.extract_version(output)
    if not version then
        return nil, "could not parse version from `" .. vim.trim(output) .. "`"
    end

    return version, nil
end

M.check = function()
    vim.health.start("pi.nvim")

    local bin = require("pi.config").options.bin
    local bin_found = vim.fn.executable(bin) == 1
    if bin_found then
        vim.health.ok("`" .. bin .. "` executable found")

        local version, err = get_pi_version(bin)
        if not version then
            vim.health.warn("Could not determine pi version: " .. (err or "unknown error"))
        else
            local cmp_min = Compat.compare_versions(version, Compat.min_supported)
            local cmp_validated = Compat.compare_versions(version, Compat.validated)

            if cmp_min == nil or cmp_validated == nil then
                vim.health.warn(
                    "Could not compare pi version `"
                        .. version
                        .. "` against supported range (min="
                        .. Compat.min_supported
                        .. ", validated="
                        .. Compat.validated
                        .. ")"
                )
            elseif cmp_min < 0 then
                vim.health.error(
                    "pi version `"
                        .. version
                        .. "` is older than minimum supported `"
                        .. Compat.min_supported
                        .. "`"
                )
            elseif cmp_validated > 0 then
                vim.health.warn(
                    "pi version `"
                        .. version
                        .. "` is newer than last validated `"
                        .. Compat.validated
                        .. "` (expected to work, but not validated yet)"
                )
            else
                vim.health.ok(
                    "pi version `"
                        .. version
                        .. "` is within supported/validated range (min="
                        .. Compat.min_supported
                        .. ", validated="
                        .. Compat.validated
                        .. ")"
                )
            end
        end
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
