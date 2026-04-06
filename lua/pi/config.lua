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
---@field default pi.LayoutMode|fun(): pi.LayoutMode
---@field side pi.SideLayout|fun(): pi.SideLayout
---@field float pi.FloatLayout|fun(): pi.FloatLayout

---@alias pi.KeySpec string|{ [1]: string, modes: string[] }

---@class pi.ZenKeys
---@field toggle? pi.KeySpec Key to enter/exit zen mode
---@field exit? pi.KeySpec[] Additional keys that only exit zen mode

---@class pi.ZenConfig
---@field width? integer Prompt width in columns (default: textwidth if set, otherwise 80)
---@field keys pi.ZenKeys

---@class pi.DiffKeys
---@field accept pi.KeySpec
---@field reject pi.KeySpec
---@field expand_context pi.KeySpec
---@field shrink_context pi.KeySpec

---@class pi.DiffContextConfig
---@field base? integer
---@field step integer

---@class pi.DiffConfig
---@field context pi.DiffContextConfig
---@field keys pi.DiffKeys

---@alias pi.SpinnerPreset "classic"|"robot"

---@alias pi.VerbPair [string, string] [0]=active (e.g. "Cooking"), [1]=done (e.g. "Cooked")

---@class pi.VerbsConfig
---@field use_defaults? boolean When true (default), user pairs are appended to the built-in list; when false, they replace it
---@field pairs? pi.VerbPair[] Verb pairs

---@class pi.Labels
---@field user_message string
---@field agent_response string
---@field system_error string
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

---@alias pi.StatusLineBuiltinName
---| "tokens"
---| "cache"
---| "cost"
---| "compaction"
---| "context"
---| "attention"
---| "model"
---| "thinking"

---@class pi.StatusLineLayout
---@field left pi.StatusLineItem[] Built-in names, literal separators, or custom components
---@field right pi.StatusLineItem[] Built-in names, literal separators, or custom components

---@class pi.StatusLineComponentConfig
---@field icon? string|false Prefix icon rendered before the component text. Use false to disable.

---@class pi.StatusLineContextConfig
---@field icon? string|false Prefix icon rendered before the component text. Use false to disable.
---@field warn? number Percentage threshold for warning highlight (default 70)
---@field error? number Percentage threshold for error highlight (default 90)

---@class pi.StatusLineCostConfig
---@field icon? string|false Prefix icon rendered before the component text. Use false to disable.
---@field warn? number Optional cost threshold for warning highlight
---@field error? number Optional cost threshold for error highlight

---@class pi.StatusLineAttentionConfig
---@field icon? string|false Prefix icon rendered before the component text. Use false to disable.
---@field counter? boolean Show the pending attention count next to the icon.

---@class pi.StatusLineComponents
---@field tokens? pi.StatusLineComponentConfig
---@field cache? pi.StatusLineComponentConfig
---@field cost? pi.StatusLineCostConfig
---@field compaction? pi.StatusLineComponentConfig
---@field context? pi.StatusLineContextConfig
---@field attention? pi.StatusLineAttentionConfig
---@field model? pi.StatusLineComponentConfig
---@field thinking? pi.StatusLineComponentConfig

---@class pi.StatusLineConfig
---@field layout pi.StatusLineLayout
---@field components? pi.StatusLineComponents

---@class pi.UiAttentionConfig
---@field auto_open_on_prompt_focus boolean Automatically open the next pending attention request for the current tab when the prompt gains focus and has no draft.
---@field notify_on_completion boolean Show an info notification when the agent finishes a turn and the prompt does not have focus.

---@class pi.DialogKeys
---@field confirm? pi.KeySpec[]
---@field cancel? pi.KeySpec[]
---@field next? pi.KeySpec[]
---@field prev? pi.KeySpec[]

--- A preferred model entry for cycling/selection.
--- String: exact model ID.
--- Table: substring match with optional latest resolution.
---@alias pi.ModelEntry string|pi.ModelSpec

---@class pi.ModelSpec
---@field match string Substring to match against model IDs (case-insensitive), or exact ID when `exact` is true
---@field exact? boolean If true, `match` is treated as an exact model ID (case-sensitive) instead of a substring
---@field latest? boolean If true, pick the model whose ID sorts last among matches

---@class pi.DialogConfig
---@field border string|string[]
---@field max_width number max width as fraction of screen (<1) or columns (>=1)
---@field max_height number max height as fraction of screen (<1) or lines (>=1)
---@field indicator string sign text for selected item
---@field keys pi.DialogKeys

--- A single styled text chunk: { text, hl_group? }.
---@alias pi.CustomBlockChunk string[]

--- A line of styled chunks.
---@alias pi.CustomBlockLine pi.CustomBlockChunk[]

--- Return value from on_widget to render a custom block inline in history.
---@class pi.CustomBlock
---@field target "history" Where to render the block.
---@field block "custom" Block type.
---@field content pi.CustomBlockLine[] Lines of styled chunks to render.

---@class pi.Options
---@field bin string
---@field agent_dir? string Override the π agent directory (default: $PI_CODING_AGENT_DIR or ~/.pi/agent)
---@field debug boolean Enable RPC debug logging to stdpath("log")/pi-rpc.log
---@field models? pi.ModelEntry[] Preferred models for cycling and :PiSelectModel
---@field spinner pi.SpinnerPreset|string[]|{ refresh_rate?: integer, frames: string[] } preset name or custom
---@field show_thinking boolean
---@field expand_startup_details boolean Default expand/collapse state for the startup block (skills, extensions, startup announcements). Always rendered; Tab on the block or API call toggles.
---@field panels pi.Panels
---@field labels pi.Labels
---@field layout pi.LayoutConfig
---@field statusline pi.StatusLineConfig
---@field diff pi.DiffConfig
---@field attention pi.UiAttentionConfig
---@field zen pi.ZenConfig
---@field dialog pi.DialogConfig
---@field verbs pi.VerbsConfig Verb pairs for status messages, picked randomly per run
---@field on_widget? fun(key: string, lines: string[]?, placement: string?): pi.CustomBlock? Handle extension setWidget calls. Return a custom block to render inline in history, or nil to ignore. Not called for `:startup` widgets (keys ending with `:startup`), which are always stored as startup announcements and rendered in the system preamble.

---@class pi.ConfigModule
---@field options pi.Options
local M = {}

math.randomseed(os.time())

---@type pi.Options
local defaults = {
    bin = "pi",
    debug = false,
    spinner = "robot",
    show_thinking = false,
    expand_startup_details = true,
    panels = {
        history = { title = "π" },
        prompt = { title = "󰫽󰫿󰫼󰫺󰫽󰬁" },
        attachments = { title = "󰫮󰬁󰬁󰫮󰫰󰫵󰫺󰫲󰫻󰬁󰬀" },
    },
    labels = {
        user_message = "",
        agent_response = "󰚩",
        system_error = "󱚟",
        tool = "󰻂",
        tool_success = "",
        tool_failure = "",
        steer_message = "󰾘",
        follow_up_message = "󱇼",
        thinking = "󰟶",
        attachment = "",
        attachments = "",
        error = "󰘨 󱚟 󱔁 ",
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
            left = { "context", "  ", "attention" },
            right = { "model", "   ", "thinking" },
        },
        components = {
            tokens = { icon = "" },
            cache = { icon = "󰆼" },
            cost = { icon = "" },
            compaction = { icon = false },
            context = { icon = "", warn = 70, error = 90 },
            attention = { icon = "󰵚", counter = false },
            model = { icon = "󰚩" },
            thinking = { icon = "󰟶" },
        },
    },
    diff = {
        context = {
            base = nil,
            step = 5,
        },
        keys = {
            accept = "<Leader>da",
            reject = "<Leader>dr",
            expand_context = "<Leader>de",
            shrink_context = "<Leader>ds",
        },
    },
    attention = {
        auto_open_on_prompt_focus = true,
        notify_on_completion = true,
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
    zen = {
        width = nil,
        keys = {
            toggle = nil,
            exit = nil,
        },
    },
    verbs = {
        use_defaults = true,
        pairs = {
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
}

---@type pi.Options
M.options = vim.deepcopy(defaults)

---@param opts? pi.Options
function M.setup(opts)
    -- Stash user verbs before deep-extend mangles the list.
    local user_verbs = opts and opts.verbs or nil
    if opts then
        opts = vim.deepcopy(opts)
        opts.verbs = nil
    end

    M.options = vim.tbl_deep_extend("force", defaults, opts or {})

    -- Resolve verbs: merge or replace based on use_defaults.
    if user_verbs then
        local use_defaults = user_verbs.use_defaults
        if use_defaults == nil then
            use_defaults = defaults.verbs.use_defaults
        end
        local user_pairs = user_verbs.pairs or {}
        if use_defaults then
            local merged = vim.deepcopy(defaults.verbs.pairs) --[[@as pi.VerbPair[] ]]
            vim.list_extend(merged, user_pairs)
            M.options.verbs = { use_defaults = true, pairs = merged }
        else
            M.options.verbs = { use_defaults = false, pairs = user_pairs }
        end
    end
end

--- Resolve a config value that may be a function, merging the result with
--- a fallback table when provided.
---@generic T
---@param value T|fun(): T
---@param fallback? T
---@return T
local function resolve(value, fallback)
    if type(value) ~= "function" then
        return value
    end
    local result = value()
    if fallback and type(result) == "table" and type(fallback) == "table" then
        return vim.tbl_deep_extend("force", fallback, result)
    end
    return result
end

--- Resolve layout.default (may be a string or a function returning one).
---@return pi.LayoutMode
function M.resolve_default_layout_mode()
    return resolve(M.options.layout.default) --[[@as pi.LayoutMode]]
end

--- Resolve layout.side (may be a table or a function returning a partial table).
---@return pi.SideLayout
function M.resolve_side_layout()
    return resolve(M.options.layout.side, defaults.layout.side) --[[@as pi.SideLayout]]
end

--- Resolve layout.float (may be a table or a function returning a partial table).
---@return pi.FloatLayout
function M.resolve_float_layout()
    return resolve(M.options.layout.float, defaults.layout.float) --[[@as pi.FloatLayout]]
end

--- Pick a random verb pair, returns { active, done }.
--- Falls back to { "Working", "Completed" } if no custom verbs.
---@return pi.VerbPair
function M.random_verbs()
    local pairs = M.options.verbs and M.options.verbs.pairs
    if not pairs or #pairs == 0 then
        return { "Working", "Completed" }
    end
    local pick = pairs[math.random(#pairs)]
    if pick[1] == "Deploying on Friday" and os.date("*t").wday ~= 6 then
        return M.random_verbs()
    end
    return pick
end

return M
