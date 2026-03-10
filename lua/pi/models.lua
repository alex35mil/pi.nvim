--- Model selection: cycling, picking, and resolving configured model entries.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")

--- Resolve configured model entries against available backend models.
--- Returns the matched subset in config order.
---@param entries pi.ModelEntry[]
---@param all_models table[] models from get_available_models
---@return table[] resolved  matched backend model objects
function M.resolve_entries(entries, all_models)
    ---@type table[]
    local resolved = {}
    ---@type table<string, true>
    local seen = {}
    for _, entry in ipairs(entries) do
        local matched = false
        if type(entry) == "string" then
            -- Exact ID match
            for _, m in ipairs(all_models) do
                if m.id == entry and not seen[m.provider .. "/" .. m.id] then
                    resolved[#resolved + 1] = m
                    seen[m.provider .. "/" .. m.id] = true
                    matched = true
                end
            end
            if not matched then
                Notify.warn("Configured model not found: " .. entry)
            end
        elseif type(entry) == "table" and entry.match then
            local needle = entry.match:lower()
            ---@type table[]
            local matches = {}
            for _, m in ipairs(all_models) do
                if m.id:lower():find(needle, 1, true) and not seen[m.provider .. "/" .. m.id] then
                    matches[#matches + 1] = m
                end
            end
            if entry.latest then
                -- Pick the model whose ID sorts last (date suffixes sort naturally)
                table.sort(matches, function(a, b)
                    return a.id < b.id
                end)
                if #matches > 0 then
                    local m = matches[#matches]
                    resolved[#resolved + 1] = m
                    seen[m.provider .. "/" .. m.id] = true
                    matched = true
                end
            else
                for _, m in ipairs(matches) do
                    resolved[#resolved + 1] = m
                    seen[m.provider .. "/" .. m.id] = true
                    matched = true
                end
            end
            if not matched then
                Notify.warn('No models matched "' .. entry.match .. '"')
            end
        end
    end
    return resolved
end

--- Format a model for display: "model-id  [provider]"
---@param model table
---@return string
function M.format_label(model)
    return model.id .. "  [" .. model.provider .. "]"
end

--- Send set_model RPC and notify on result.
---@param session pi.Session
---@param model table backend model object with .provider and .id
function M.set(session, model)
    local Sessions = require("pi.sessions.manager")
    session.rpc:send({ type = "set_model", provider = model.provider, modelId = model.id }, function(res)
        vim.schedule(function()
            if res.success then
                Sessions.refresh_state(session)
            else
                Notify.warn(res.error or "Failed to set model")
            end
        end)
    end)
end

--- Fetch available models from the backend, then call fn with them.
---@param session pi.Session
---@param fn fun(models: table[])
function M.with_available(session, fn)
    session.rpc:send({ type = "get_available_models" }, function(res)
        vim.schedule(function()
            if not res.success then
                Notify.warn(res.error or "Failed to fetch models")
                return
            end
            local models = (res.data or {}).models or {}
            if #models == 0 then
                Notify.warn("No models available")
                return
            end
            fn(models)
        end)
    end)
end

--- Cycle to the next model.
--- If `models` is configured, cycles within the resolved subset.
---@param session pi.Session
function M.cycle(session)
    local entries = Config.options.models
    if not entries or #entries == 0 then
        -- No config — use backend's built-in cycle
        session.rpc:send({ type = "cycle_model" }, function(res)
            vim.schedule(function()
                if res.success and res.data then
                    require("pi.sessions.manager").refresh_state(session)
                elseif res.success then
                    Notify.info("Only one model available")
                else
                    Notify.warn(res.error or "Failed to cycle model")
                end
            end)
        end)
        return
    end
    -- Configured models — resolve and cycle manually
    M.with_available(session, function(all_models)
        local resolved = M.resolve_entries(entries, all_models)
        if #resolved == 0 then
            Notify.warn("No configured models matched available models")
            return
        end
        if #resolved == 1 then
            Notify.info("Only one model in list")
            return
        end
        -- Find current model and advance to next
        session.rpc:send({ type = "get_state" }, function(state_res)
            vim.schedule(function()
                local current = state_res.success and state_res.data and state_res.data.model
                local current_key = current and (current.provider .. "/" .. current.id) or ""
                local next_idx = 1
                for i, m in ipairs(resolved) do
                    if m.provider .. "/" .. m.id == current_key then
                        next_idx = (i % #resolved) + 1
                        break
                    end
                end
                M.set(session, resolved[next_idx])
            end)
        end)
    end)
end

--- Select a model from configured models (or all if none configured).
--- Uses Dialog.select for the curated list.
---@param session pi.Session
function M.select(session)
    local Dialog = require("pi.ui.dialog")
    M.with_available(session, function(all_models)
        local entries = Config.options.models
        local models = (entries and #entries > 0) and M.resolve_entries(entries, all_models) or all_models
        if #models == 0 then
            Notify.warn("No configured models matched available models")
            return
        end
        ---@type string[]
        local labels = {}
        for i, m in ipairs(models) do
            labels[i] = M.format_label(m)
        end
        Dialog.select({ title = "Select model", options = labels }, function(choice)
            if not choice then
                return
            end
            for i, l in ipairs(labels) do
                if l == choice then
                    M.set(session, models[i])
                    return
                end
            end
        end)
    end)
end

--- Select a model from all available models using vim.ui.select (searchable).
---@param session pi.Session
function M.select_all(session)
    M.with_available(session, function(models)
        ---@type string[]
        local labels = {}
        for i, m in ipairs(models) do
            labels[i] = M.format_label(m)
        end
        vim.ui.select(labels, {
            prompt = "Select model",
            -- snacks.nvim workaround: its picker can compute non-integer
            -- heights, crashing nvim_win_set_config. Force math.floor.
            snacks = {
                layout = {
                    config = function(layout)
                        for _, box in ipairs(layout.layout) do
                            if box.win == "list" then
                                box.height = math.floor(math.max(math.min(#labels, vim.o.lines * 0.8 - 10), 2))
                            end
                        end
                    end,
                },
            },
        }, function(_, idx)
            if not idx then
                return
            end
            M.set(session, models[idx])
        end)
    end)
end

return M
