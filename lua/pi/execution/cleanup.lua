--- Neovim-exit cleanup and reporting.
---
--- On exit every live launch is asked to stop at once and given one shared
--- budget. Failures can't be seen while Neovim closes, so they go to the
--- optional `process.stop.on_failure` callback and, unless turned off, are
--- saved and shown the next time pi.nvim starts.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")
local Rpc = require("pi.rpc")
local State = require("pi.execution.state")

--- Stop every live launch within the shared budget, then report failures.
function M.stop_all_on_exit()
    local count = Rpc.live_count()
    if count == 0 then
        return
    end
    vim.api.nvim_echo({ { ("pi: waiting for %d launch(es) to stop…"):format(count), "WarningMsg" } }, false, {})
    vim.cmd("redraw")

    local reports = Rpc.stop_all_blocking()
    if #reports == 0 then
        return
    end

    local stop = Config.options.process.stop
    local save = stop.report_failures_on_start ~= false
    ---@type pi.SavedCleanupFailure[]
    local saved = {}
    for _, report in ipairs(reports) do
        ---@type pi.SavedCleanupFailure
        local record = vim.tbl_extend("force", report, { time = os.time() })
        if type(stop.on_failure) == "function" then
            local ok, err = pcall(stop.on_failure, vim.deepcopy(report))
            if not ok then
                record.callback_error = tostring(err)
            end
        end
        saved[#saved + 1] = record
    end
    if save then
        -- Nothing can be shown now; the next start reports these.
        State.save_failures(saved)
    end
end

---@param failure pi.SavedCleanupFailure
---@return string
local function describe(failure)
    local what = ({
        exit = "exited with code " .. tostring(failure.code),
        timeout = "didn't stop in time and was force-stopped",
        forced = "was still running when Neovim exited and was force-stopped",
    })[failure.outcome] or tostring(failure.outcome)
    local lines = {
        ("%s: `%s` in %s %s"):format(os.date("%Y-%m-%d %H:%M", failure.time), failure.command, failure.workspace, what),
        "  " .. (failure.descriptor and ("descriptor: " .. failure.descriptor) or "local pi"),
    }
    for _, line in ipairs(failure.stderr or {}) do
        lines[#lines + 1] = "  " .. line
    end
    if failure.log_tail and #failure.log_tail > 0 then
        lines[#lines + 1] = "  last log entries:"
        for _, entry in ipairs(failure.log_tail) do
            lines[#lines + 1] = "    " .. entry
        end
    end
    if failure.log then
        lines[#lines + 1] = "  log: " .. failure.log .. " (reset when this tab starts pi again)"
    end
    if failure.callback_error then
        lines[#lines + 1] = "  on_failure failed: " .. failure.callback_error
    end
    return table.concat(lines, "\n")
end

--- Show cleanup failures saved during the last Neovim exit, then clear them.
function M.report_saved_failures()
    local failures = State.take_failures()
    if #failures == 0 then
        return
    end
    local parts = { "pi: cleanup failed when Neovim last exited; resources may still be running:" }
    for _, failure in ipairs(failures) do
        parts[#parts + 1] = describe(failure)
    end
    Notify.warn(table.concat(parts, "\n"))
end

return M
