---@class pi.PanelOpts
---@field title string
---@field name? fun(tab: pi.TabId): string

---@class pi.Panels
---@field history pi.PanelOpts
---@field prompt pi.PanelOpts
---@field attachments pi.PanelOpts

---@class pi.SidePanelOpts
---@field winbar boolean

---@class pi.SidePanels
---@field history pi.SidePanelOpts
---@field prompt pi.SidePanelOpts
---@field attachments pi.SidePanelOpts

---@class pi.SideLayout
---@field position "right"|"bottom"
---@field width integer
---@field height? integer
---@field panels pi.SidePanels

---@class pi.FloatLayout
---@field width number width in columns (>=1) or fraction of screen (<1)
---@field height number height in lines (>=1) or fraction of screen (<1)
---@field border string|string[]
---@field win? vim.api.keyset.win_config Extra options passed to nvim_open_win

---@alias pi.LayoutMode "side"|"float"

---@class pi.LayoutConfig
---@field default pi.LayoutMode
---@field side pi.SideLayout
---@field float pi.FloatLayout

---@class pi.Keymaps
---@field diff_accept pi.DialogKey
---@field diff_reject pi.DialogKey

---@alias pi.SpinnerPreset "classic"|"robot"

---@alias pi.VerbPair [string, string] [0]=active (e.g. "Cooking"), [1]=done (e.g. "Cooked")

---@class pi.Labels
---@field user_message string
---@field agent_response string
---@field debug_message string
---@field tool string
---@field tool_success string
---@field tool_failure string
---@field steer_message string
---@field follow_up_message string
---@field thinking string
---@field attachment string
---@field attachments string
---@field error string

---@alias pi.StatusLineItem string|pi.StatusLineComponentFn

---@class pi.StatusLineLayout
---@field left pi.StatusLineItem[] Built-in names, literal separators, or custom components
---@field right pi.StatusLineItem[] Built-in names, literal separators, or custom components

---@class pi.StatusLineContextConfig
---@field warn? number Percentage threshold for warning highlight (default 70)
---@field error? number Percentage threshold for error highlight (default 90)

---@class pi.StatusLineCostConfig
---@field warn? number Cost threshold for warning highlight
---@field error? number Cost threshold for error highlight

---@class pi.StatusLineComponents
---@field context? pi.StatusLineContextConfig
---@field cost? pi.StatusLineCostConfig

---@class pi.StatusLineConfig
---@field layout pi.StatusLineLayout
---@field components? pi.StatusLineComponents

---@class pi.UiConfig
---@field spinner pi.SpinnerPreset|string[]|{ refresh_rate?: integer, frames: string[] } preset name or custom
---@field show_thinking boolean
---@field show_debug boolean
---@field panels pi.Panels
---@field labels pi.Labels
---@field layout pi.LayoutConfig
---@field statusline pi.StatusLineConfig
---@field dialog pi.DialogConfig
---@field verbs? pi.VerbPair[] Custom verb pairs for status messages, picked randomly per run

---@alias pi.DialogKey string|{ [1]: string, modes: string[] }

---@class pi.DialogKeys
---@field confirm? pi.DialogKey[]
---@field cancel? pi.DialogKey[]
---@field next? pi.DialogKey[]
---@field prev? pi.DialogKey[]

--- A preferred model entry for cycling/selection.
--- String: exact model ID.
--- Table: substring match with optional latest resolution.
---@alias pi.ModelEntry string|pi.ModelSpec

---@class pi.ModelSpec
---@field match string Substring to match against model IDs (case-insensitive)
---@field latest? boolean If true, pick the model whose ID sorts last among matches

---@class pi.DialogConfig
---@field border string|string[]
---@field max_width number max width as fraction of screen (<1) or columns (>=1)
---@field max_height number max height as fraction of screen (<1) or lines (>=1)
---@field indicator string sign text for selected item
---@field keys pi.DialogKeys

---@class pi.Options
---@field bin string
---@field agent_dir? string Override the π agent directory (default: $PI_CODING_AGENT_DIR or ~/.pi/agent)
---@field debug boolean Enable RPC debug logging to stdpath("log")/pi-rpc.log
---@field models? pi.ModelEntry[] Preferred models for cycling and :PiSelectModel
---@field ui pi.UiConfig
---@field keymaps pi.Keymaps

---@class pi.ConfigModule
---@field options pi.Options
local M = {}

math.randomseed(os.time())

---@type pi.Options
local defaults = {
    bin = "pi",
    debug = false,
    ui = {
        spinner = "robot",
        show_thinking = false,
        show_debug = false,
        panels = {
            history = { title = "π" },
            prompt = { title = "󰫽󰫿󰫼󰫺󰫽󰬁" },
            attachments = { title = "󰫮󰬁󰬁󰫮󰫰󰫵󰫺󰫲󰫻󰬁󰬀" },
        },
        labels = {
            user_message = "",
            agent_response = "󰚩",
            debug_message = "",
            tool = "󰻂",
            tool_success = "",
            tool_failure = "",
            steer_message = "󰾘",
            follow_up_message = "󱇼",
            thinking = "󰟶",
            attachment = "",
            attachments = "",
            error = " 󱚟 ",
        },
        layout = {
            default = "side",
            side = {
                position = "right",
                width = 80,
                panels = {
                    history = { winbar = true },
                    prompt = { winbar = true },
                    attachments = { winbar = true },
                },
            },
            float = {
                width = 0.6,
                height = 0.8,
                border = "rounded",
            },
        },
        statusline = {
            layout = {
                left = { "context" },
                right = { "model", " · ", "thinking" },
            },
        },
        dialog = {
            border = "rounded",
            max_width = 0.8,
            max_height = 0.8,
            indicator = "▸",
            keys = {
                -- confirm
                -- cancel
                -- next
                -- prev
            },
        },
        verbs = {
            { "rm -rf'ing /", "rm -rf'd /" },
            { "Cooking spaghetti", "Cooked" },
            { "Burning tokens", "Burned tokens" },
            { "Shaving yaks", "Shaved yak" },
            { "Racking up debt", "Racked up debt" },
            { "Mining bitcoins", "Mined ₿" },
            { "Stacking overflow", "Stacked overflow" },
            { "Opening kournikova.jpg", "Opened kournikova.jpg" },
            { "Deploying on Friday", "Paniced" },
            { "Jiggling wiggling", "Jiggled wiggled" },
            { "Rewriting in Rust", "Rewrote in Rust" },
            { "Git blaming", "Git blamed" },
            { "Tail-recursing", "Stack overflowed" },
            { "Making no mistakes", "Made no mistakes" },
            { "Making your codebase great again", "Made your codebase great again" },
            { "Dangerously skipping permissions", "Dangerously skipped permissions" },
            { "Agently replacing you", "Agently replaced you" },
        },
    },
    keymaps = {
        diff_accept = "<Leader>da",
        diff_reject = "<Leader>dr",
    },
}

---@type pi.Options
M.options = vim.deepcopy(defaults)

---@param opts? pi.Options
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", defaults, opts or {})
end

--- Pick a random verb pair, returns { active, done }.
--- Falls back to { "Working", "Completed" } if no custom verbs.
---@return pi.VerbPair
function M.random_verbs()
    local verbs = M.options.ui.verbs
    if not verbs or #verbs == 0 then
        return { "Working", "Completed" }
    end
    local pick = verbs[math.random(#verbs)]
    if pick[1] == "Deploying on Friday" and os.date("*t").wday ~= 6 then
        return M.random_verbs()
    end
    return pick
end

return M
