---@class pi.Compat
---@field min_supported string minimum pi version supported by this plugin
---@field validated string latest pi version manually validated against this plugin
local M = {
    -- Keep these in sync with release validation notes.
    min_supported = "0.65.2",
    validated = "0.65.2",
}

---@param version string
---@return integer[]?
local function parse_version(version)
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then
        return nil
    end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

---Extract `x.y.z` from arbitrary version output (e.g. `pi v0.65.2`).
---@param text string
---@return string?
function M.extract_version(text)
    return text:match("(%d+%.%d+%.%d+)")
end

---Compare two semantic versions (`x.y.z`).
---@param a string
---@param b string
---@return integer? cmp returns -1, 0, 1; nil when parsing fails
function M.compare_versions(a, b)
    local av = parse_version(a)
    local bv = parse_version(b)
    if not av or not bv then
        return nil
    end

    for i = 1, 3 do
        if av[i] < bv[i] then
            return -1
        elseif av[i] > bv[i] then
            return 1
        end
    end

    return 0
end

return M
