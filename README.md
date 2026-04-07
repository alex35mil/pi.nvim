# pi.nvim

Use the [pi coding agent](https://pi.dev) without leaving Neovim.

<p align="center">
    <img width="2884" height="1764" alt="π" src="https://github.com/user-attachments/assets/92ee94b2-8770-4b34-bc61-7f536362b341" />
    <sub>
        π
    </sub>
</p>

`pi.nvim` runs `pi --mode rpc` in the background and gives you an in-editor workflow for project-aware prompts, reviewed edits, session resume, and extension prompts.

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Keymaps](#keymaps)
- [Usage](#usage)
    - [Chat & layouts](#chat--layouts)
    - [Prompt](#prompt)
    - [Mentions](#mentions)
    - [Slash commands](#slash-commands)
    - [Completion](#completion)
    - [Attachments](#attachments)
    - [Zen mode](#zen-mode)
    - [Statusline](#statusline)
    - [Navigation](#navigation)
    - [Diff review](#diff-review)
    - [Attention & dialogs](#attention--dialogs)
    - [Startup block](#startup-block)
    - [Tool blocks](#tool-blocks)
    - [Models](#models)
    - [Thinking](#thinking)
    - [Sessions](#sessions)
    - [Extensions & custom rendering](#extensions--custom-rendering)
    - [Health & debugging](#health--debugging)
- [Commands](#commands)
- [API](#api)
- [Highlight groups](#highlight-groups)

## Features

- Chat with `pi` in a side panel or floating window
- Point `pi` at the exact code you mean with `@file` and `@file#L10-20` mentions
- Review agent-proposed edits in a two-way diff before they are applied, and tweak the proposed result if needed
- Keep separate conversations per tab and continue or resume past sessions for the current working directory
- Switch to zen mode for composing larger prompts comfortably
- Attach screenshots and other images from disk, clipboard, or drag-and-drop
- Queue follow-up instructions while the agent is still working
- Switch models and thinking levels mid-session
- See tool activity, diffs, and agent status inline, with collapsible tool blocks and a prompt status line
- Handle confirmations, selections, and other extension UI requests inside Neovim
- Use `/commands`, `@mentions`, and prompt completion out of the box, with optional `blink.cmp` integration

## Requirements

- Neovim 0.10+
- `pi` in `$PATH`

Optional but useful:

- `nvim-treesitter` markdown parser for nicer chat history highlighting
- [`HakonHarnes/img-clip.nvim`](https://github.com/HakonHarnes/img-clip.nvim) for `:PiPasteImage`
- `blink.cmp` if you want popup completion in the π prompt buffer

Run `:checkhealth pi` to verify.

## Installation

### vim.pack

```lua
vim.pack.add({ "https://github.com/alex35mil/pi.nvim" })

-- if you're fine with defaults:
require("pi").setup()

-- or, if you want to customize:
require("pi").setup({
    models = { ... },
    layout = { ... },
})
```

### lazy.nvim

```lua
{
    "alex35mil/pi.nvim",

    -- Optional: required only for `:PiPasteImage` (clipboard image paste).
    dependencies = { "HakonHarnes/img-clip.nvim" },

    -- if you're fine with defaults:
    config = true,

    -- or, if you want to customize:
    opts = {
        models = { ... },
        layout = { ... },
    },
}
```

## Quick start

1. Open a project in Neovim.
2. Run `:Pi`.
3. Type a prompt and press `<CR>`.
4. Mention files with `@path/to/file` or `@path/to/file#L12-20`.
5. Use `:PiContinue` or `:PiResume` to revisit earlier sessions for the current working directory.

## Configuration

All options are optional. These are the defaults:

```lua
---@type pi.Options
require("pi").setup({
    -- Path to the `pi` executable.
    bin = "pi",
    -- Enable RPC debug logging to `stdpath("log")/pi/<session>/rpc.log`.
    debug = false,
    -- Override the π agent directory used for session lookup.
    -- Defaults to $PI_CODING_AGENT_DIR or ~/.pi/agent.
    agent_dir = nil,
    -- Preferred models for cycling and :PiSelectModel dialog.
    -- Each entry is either a string (exact ID) or a table:
    --   { match = "opus", latest = true }
    --   { match = "gpt-5.3-codex", exact = true } or just "gpt-5.3-codex"
    models = nil,
    -- Spinner shown while the agent is working.
    -- Preset name ("classic"|"robot"), array of frames (strings), or
    -- { refresh_rate = ms, frames = { ... } }.
    spinner = "robot",
    -- Show thinking blocks by default.
    show_thinking = false,
    -- Default expand/collapse state for the startup block
    -- (skills, extensions, startup announcements).
    expand_startup_details = true,

    -- Chat panels
    panels = {
        -- Titles shown in panel winbars.
        history = { title = "π" },
        prompt = { title = "󰫽󰫿󰫼󰫺󰫽󰬁" },
        attachments = { title = "󰫮󰬁󰬁󰫮󰫰󰫵󰫺󰫲󰫻󰬁󰬀" },
    },

    -- Inline labels rendered in the chat history.
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

    -- Chat layout
    layout = {
        -- Default layout when opening the chat: "side" or "float".
        default = "side",
        side = {
            -- Side panel position: "right" or "bottom".
            position = "right",
            -- Width in columns when position is "right".
            width = 80,
            panels = {
                -- Show winbars on each panel in side layout.
                history = { winbar = true },
                prompt = { winbar = true },
                attachments = { winbar = true },
            },
        },
        float = {
            -- Width/height: fraction (<1) or columns/lines (>=1).
            width = 0.6,
            height = 0.8,
            border = "rounded",
        },
    },

    -- Status line in the prompt window
    statusline = {
        -- Components rendered in the prompt statusline.
        -- Entries are built-in component names, literal separators,
        -- or custom component functions.
        layout = {
            left = { "context", "  ", "attention" },
            right = { "model", "   ", "thinking" },
        },
        components = {
            tokens = { icon = "" },
            cache = { icon = "󰆼" },
            cost = { icon = "" },
            compaction = { icon = false },
            context = { icon = "", warn = 70, error = 90 }, -- `warn`/`error` are percentages of context window used.
            attention = { icon = "󰵚", counter = false },
            model = { icon = "󰚩" },
            thinking = { icon = "󰟶" },
        },
    },

    -- Diff review
    diff = {
        -- Visible context around each hunk.
        context = {
            -- Initial visible context around each hunk.
            -- nil means use current 'diffopt' context.
            base = nil,
            -- Lines added/removed by expand/shrink actions.
            step = 5,
        },
        -- Keymaps active inside the diff review tab.
        keys = {
            accept = "<Leader>da",
            reject = "<Leader>dr",
            expand_context = "<Leader>de",
            shrink_context = "<Leader>ds",
        },
    },

    -- Attention queue for user-input requests (confirms, selects, etc.)
    attention = {
        -- Auto-open the next pending attention request when the
        -- current tab's prompt is refocused and empty.
        -- If false, needs :PiAttention command to pull what's pending.
        auto_open_on_prompt_focus = true,
        -- Notify when the agent finishes a turn and the prompt is not focused.
        notify_on_completion = true,
    },

    -- Selects, confirmation dialogs
    dialog = {
        border = "rounded",
        -- Max size: fraction (<1) or columns/lines (>=1).
        max_width = 0.8,
        max_height = 0.8,
        -- Sign text for the selected item.
        indicator = "▸",
        keys = {
            -- Optional dialog keymaps; nil leaves built-in defaults in place.
            confirm = nil,
            cancel = nil,
            next = nil,
            prev = nil,
        },
    },

    -- Zen mode for composing larger prompts
    zen = {
        -- Prompt width in columns. nil = textwidth if set, otherwise 80.
        width = nil,
        keys = {
            -- Key to enter/exit zen mode.
            toggle = nil,
            -- Additional keys that only exit zen mode.
            exit = nil,
        },
    },

    -- Verb pairs for status messages, picked randomly per run.
    verbs = {
        -- When true, user pairs are appended to the built-in list;
        -- when false, they replace it.
        use_defaults = true,
        pairs = {
            { "Rewriting in Rust", "Rewrote in Rust" },
            { "Making no mistakes", "Made no mistakes" },
            -- ... and more built-in pairs
        },
    },

    -- Extension setWidget hook. Return a custom block to render inline
    -- in history, or nil to ignore. Not called for `:startup` widgets.
    on_widget = nil,
})
```

## Keymaps

`pi.nvim` intentionally ships with a very small default keymap set. Keymaps tend to be highly personal, and many users already have their own conventions, leader-based layouts, or other mapping systems. Pi tries to provide the API and a few sensible defaults, while leaving the final keymap design to you.

### Key specs

Several config fields (`diff.keys`, `dialog.keys`, `zen.keys`) accept a **key spec** instead of a plain string, so you can pin mappings to specific modes and bind multiple keys to the same action. A key spec is one of:

```lua
-- 1. A plain string — single mapping in the default modes for that field.
accept = "<Leader>da"

-- 2. A table with `.modes` — single mapping in the given modes.
accept = { "<C-CR>", modes = { "n", "i", "v" } }

-- 3. A list of the above — multiple keys bound to the same action.
accept = {
    "<Leader>da",
    { "<C-CR>", modes = { "n", "i", "v" } },
}
```

All three forms are accepted anywhere a key spec is expected. A table is interpreted as a single spec when it has a `.modes` field, and as a list of specs otherwise.

### Example setup

A reasonable starting point looks like this:

```lua
local pi = require("pi")

-- Global mappings — open / toggle / resume from anywhere.
vim.keymap.set({ "n", "v" }, "<Leader>pp", function() vim.cmd("Pi layout=side")  end, { desc = "Pi side"  })
vim.keymap.set({ "n", "v" }, "<Leader>pf", function() vim.cmd("Pi layout=float") end, { desc = "Pi float" })
vim.keymap.set({ "n", "v" }, "<Leader>pl", "<Cmd>PiToggleLayout<CR>",                 { desc = "Pi toggle layout" })
vim.keymap.set({ "n", "v" }, "<Leader>pc", "<Cmd>PiContinue<CR>",                     { desc = "Pi continue last session" })
vim.keymap.set({ "n", "v" }, "<Leader>pr", "<Cmd>PiResume<CR>",                       { desc = "Pi resume past session" })
vim.keymap.set({ "n", "v" }, "<Leader>pm", "<Cmd>PiSendMention<CR>",                  { desc = "Pi mention file/selection" })
vim.keymap.set({ "n", "v" }, "<Leader>pa", "<Cmd>PiAttention<CR>",                    { desc = "Pi open next attention request" })
```

The `<S-Up>` / `<S-Down>` mappings below are sort of placeholders — replace them with whatever keys you already use to move between windows in the rest of Neovim. The idea is that focus navigation inside π windows should match your normal buffer/window navigation, not introduce new conventions.

```lua
-- Buffer-local mappings inside π windows.
-- Filetypes: "pi-chat-history", "pi-chat-prompt", "pi-chat-attachments".
local group = vim.api.nvim_create_augroup("pi-keymaps", { clear = true })

local function map(buf, key, action, modes)
    vim.keymap.set(modes or { "n", "i", "v" }, key, action, { buffer = buf })
end

-- Shared across all π windows.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "pi-chat-history", "pi-chat-prompt", "pi-chat-attachments" },
    callback = function(event)
        map(event.buf, "<C-q>", "<Cmd>PiToggleChat<CR>")
        map(event.buf, "<M-c>", "<Cmd>PiAbort<CR>")
    end,
})

-- History window: jump to prompt.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-history",
    callback = function(event)
        map(event.buf, "<S-Down>", pi.focus_chat_prompt)
    end,
})

-- Prompt window: navigation, scrolling, model & thinking, sessions, attachments.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-prompt",
    callback = function(event)
        -- focus
        map(event.buf, "<S-Up>",   pi.focus_chat_history)
        map(event.buf, "<S-Down>", pi.focus_chat_attachments)
        -- scroll history from the prompt
        map(event.buf, "<C-Up>",   function() pi.scroll_chat_history("up", 2) end)
        map(event.buf, "<C-Down>", function() pi.scroll_chat_history("down", 2) end)
        -- model & thinking
        map(event.buf, "<M-m>", pi.cycle_model)
        map(event.buf, "<M-M>", pi.select_model)
        map(event.buf, "<M-t>", pi.cycle_thinking_level)
        map(event.buf, "<M-T>", pi.select_thinking_level)
        -- sessions & context
        map(event.buf, "<M-n>", pi.new_session)
        map(event.buf, "<M-x>", pi.compact)
        -- attachments
        map(event.buf, "<C-v>", pi.paste_image)
    end,
})

-- Attachments window: jump back to prompt, paste image.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-attachments",
    callback = function(event)
        map(event.buf, "<S-Up>", pi.focus_chat_prompt)
        map(event.buf, "<C-v>", pi.paste_image)
    end,
})
```

## Usage

This section walks through how `pi.nvim` actually works in practice. Each subsection is independent — jump straight to what you need.

### Chat & layouts

The chat is rendered in one of two layouts.

**Floating window** opens π as a centered floating window over the editor. Good for the parts of the workflow where the conversation _is_ the work — planning, brainstorming, debugging out loud, writing specs — and you don't need the code visible at the same time. Having the chat comfortably wide and centered is much easier on your neck than spending forty minutes craned toward a side panel on the right.

**Side panel** opens π as a vertical split anchored to the right edge of the editor (or to the bottom). Good for the parts of the workflow where the code _is_ the subject of the conversation — exploring an unfamiliar codebase, doing a review, asking targeted questions about specific files or regions, pulling things into the chat with `@mentions`. You want both the code and the agent on screen at the same time.

Pick a default with `layout.default = "side" | "float"`, or override per-invocation with `:Pi layout=side` / `:Pi layout=float`. Side dimensions live under `layout.side` (`position` is `"right"` or `"bottom"`, plus `width` / `height`); float dimensions live under `layout.float` (`width`, `height`, `border`). Both `side` and `float` also accept a function returning the table, which lets you compute size based on screen dimensions or other state at open time.

Each chat contains three panels:

| Panel | Filetype | Role |
| --- | --- | --- |
| `history` | `pi-chat-history` | Rendered conversation: messages, tools, diffs, thinking blocks. Read-only. |
| `prompt` | `pi-chat-prompt` | Where you type the next message. Multi-line buffer. |
| `attachments` | `pi-chat-attachments` | Pending image attachments queued for the next message. |

The filetype names are stable — you can target them from your own `FileType` autocmds (see [Keymaps](#keymaps) for an example).

Use `:PiToggleLayout` to swap `side` ↔ `float` without losing the conversation, and `:PiToggleChat` to hide and re-show the chat windows. Neither stops the agent. To actually shut down the underlying `pi --mode rpc` process for the current tab, use `:PiStop`.

Each panel has a winbar with a title controlled by `panels.<panel>.title` (a string). In side layout, the winbar can be disabled per-panel with `layout.side.panels.<panel>.winbar = false`. Separately, `panels.<panel>.name = function(tab_id) return ... end` lets you compute the underlying buffer name per tab — useful for distinguishing multiple π conversations in `:buffers`, statuslines, or tab bars.

### Prompt

The prompt buffer (`pi-chat-prompt`) is a regular multi-line buffer where you compose the next message. It clears itself after each submission, but its contents are preserved across `:PiToggleChat`, layout toggles, and tab switches — the buffer lives with the session.

Three buffer-local mappings control submission:

| Key | Mode | Action |
| --- | --- | --- |
| `<CR>` | normal, insert | Submit the prompt |
| `<A-CR>` | normal, insert | Submit as a follow-up |
| `<S-CR>` | insert | Insert a newline |

> [!NOTE]
> These keys are currently hardcoded. If you'd like them to be configurable, please open an issue.

When the agent is **idle**, `<CR>` and `<A-CR>` behave identically — they both send a regular prompt and start a new turn.

When the agent is **streaming**, the two diverge. Both options queue your message rather than sending it straight to the LLM — the difference is _when_ the queued message is fed back in:

- `<CR>` sends a **steer**. The agent finishes whatever tool calls are currently in flight, and your message is delivered just before the next LLM call. The agent doesn't stop mid-tool-call, but it also doesn't finish the whole task before reading you. Use it when you want to redirect the agent at the earliest possible boundary — e.g. you've spotted that it's going down the wrong path and want to correct course as soon as the current step lands.
- `<A-CR>` sends a **follow-up**. The message waits until the agent has fully finished the current turn (no more tool calls, no pending steers) and is then delivered as the next message. Use it when you want to add something for the agent to address _after_ it's done with the current work, without interrupting the flow.

Both queued messages are rendered in the history with distinct labels (`labels.steer_message` and `labels.follow_up_message`) so you can tell them apart later.

### Mentions

You can refer to files and directories anywhere in your prompt with `@path` mentions. Pi expands them just before sending the message:

| Written | Sent to the agent |
| --- | --- |
| `@lua/pi/init.lua` | `[file: lua/pi/init.lua]` |
| `@lua/pi/init.lua#L42` | `[file: lua/pi/init.lua, line: 42]` |
| `@lua/pi/init.lua#L10-40` | `[file: lua/pi/init.lua, lines: 10-40]` |
| `@lua/pi` | `[directory: lua/pi]` |

The file content itself is **not inlined**. Pi assumes the agent has a `read` tool and lets it pull the content on demand. There are two reasons for this:

1. **Inlined code has no context.** Dropping a snippet into the prompt strips it from its surroundings — the agent loses imports, neighboring functions, the rest of the file, the rest of the project. A reference, on the other hand, lets the agent open the file itself and decide how much context it actually needs.
2. **Mentions are usually woven into a sentence.** A typical prompt looks like _"check if the usage of `Foo` defined at @path/to/foo.rs#L5 makes sense in the function at @path/to/fn.rs#L120-150"_. If every mention expanded into an inline code block, the sentence would fall apart and the agent would have to reconstruct what referred to what. Keeping mentions as references preserves the natural flow of the prompt.

Mentions are validated against the filesystem at send time. Paths are resolved relative to the current working directory. Anything that doesn't resolve to an existing file or directory is sent through unchanged, so a stray `@todo` in your message stays a stray `@todo`.

Trailing punctuation works the way you'd expect: `(@lua/pi/init.lua)` and `Look at @lua/pi/init.lua.` both expand cleanly without dragging the punctuation into the path.

While typing, `@mentions` are highlighted in the prompt buffer so you can see at a glance which references will expand.

`:PiSendMention` inserts an `@mention` for the current buffer at the cursor position in the π prompt, opening the chat if needed. In normal mode it mentions the buffer as a whole; in visual mode (or with a `:'<,'>PiSendMention` range) it mentions just the selected lines. The command handles spacing around the insertion so you don't end up with double spaces or missing separators. It's also exposed as `pi.send_mention(args, opts)` from Lua — see the [Keymaps](#keymaps) example for typical bindings.

> [!TIP]
> Because `@mentions` expand to `[file: ..., line: ...]` / `[file: ..., lines: ...]`, it's worth teaching the agent to re-read the exact reference before answering. Consider adding the following to your global `AGENTS.md` (or equivalent):
>
> ```md
> ## File and line references
>
> When the user references a file with `[file: ...]` and a specific line or line range, you must re-read that exact reference immediately before answering, even if the file was read earlier in the conversation.
> ```

### Slash commands

Slash commands come from the **pi backend**, not from pi.nvim. They cover three sources:

- **Extension commands** — registered by pi extensions (e.g. `/permission-toggle-auto-accept`).
- **Prompt templates** — reusable prompt snippets, expanded server-side before being sent to the LLM.
- **Skills** — invoked as `/skill:name`, also expanded server-side.

pi.nvim fetches the available command list from the running session over RPC and refreshes it periodically, so the set of `/commands` you can use depends on which extensions, templates, and skills the backend has loaded for the current session.

To invoke a command, type it on the **first line** of the prompt:

```
/permission-toggle-auto-accept
```

Arguments, if the command takes any, follow on the same line:

```
/some-command arg1 arg2
```

Only the first line is recognized as a command — everything else in the same message is treated as plain prompt text. This is a [pi backend convention](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/rpc.md#get_commands), not a pi.nvim restriction. If you want a command and a regular prompt to take effect together, send them as two separate messages.

That said, this only applies to the explicit `/command` invocation path. Skills in particular are surfaced to the model as part of the system context: per the [Agent Skills spec](https://agentskills.io/specification), each skill's `name` and `description` are loaded at startup for _all_ available skills ("progressive disclosure"), and the full `SKILL.md` body is only loaded once the model decides to activate that skill. As a result, most models will pick up the right skill even when you _mention_ it inline ("please use the `commit` skill to write the message"), without you having to invoke `/skill:commit` explicitly. How reliably this works depends on the model and on how much other context it's juggling, so for anything load-bearing it's still safer to invoke the command explicitly on the first line.

While typing, the prompt buffer highlights `/commands` in real time, but **only if the command name actually matches one in the backend's command list**. If you don't see the highlight, either the command doesn't exist, you have a typo, or the cache hasn't been populated yet (it's fetched the first time the chat opens and refreshed every 30 seconds).

You can also invoke a command programmatically from Lua, without going through the prompt buffer:

```lua
require("pi").invoke("/permission-toggle-auto-accept")
-- the leading slash is optional:
require("pi").invoke("permission-toggle-auto-accept")
```

This is useful for binding commands directly to keymaps:

```lua
vim.keymap.set(
    "n", 
    "<Leader>pt", 
    function()
        require("pi").invoke("/permission-toggle-auto-accept")
    end,
    { desc = "Pi toggle auto-accept" },
)
```

Note that `pi.invoke` requires an active session — if no chat is running for the current tab, it will warn and do nothing.

### Completion

The π prompt buffer ships with completion for both `@mentions` and `/commands` out of the box. Two integrations are provided:

**1. Built-in `completefunc` (always on).** Every π prompt buffer has a `completefunc` set, so completion works without any extra configuration. If you don't use a completion plugin, trigger it manually in insert mode with:

```
<C-x><C-u>
```

This is the default Vim user-defined completion key. It will:

- Complete `@path` mentions against project files (resolved relative to the current working directory).
- Complete `/commands` against the backend's command list — but only when the cursor is on the first line of the prompt and that line starts with `/`.

The completion popup shows source metadata for `/commands` (`extension`, `prompt`, `skill`) and the command description when available.

**2. `blink.cmp` source (optional).** If you use [blink.cmp](https://github.com/Saghen/blink.cmp), pi.nvim ships a source at `pi.completion.blink` that integrates natively with the blink popup, including auto-trigger on `@`, `/`, and `.`. Scope it to the π prompt filetype with `per_filetype` so it doesn't interfere with completion in your regular files:

```lua
require("blink.cmp").setup({
    sources = {
        per_filetype = {
            ["pi-chat-prompt"] = { "pi" },
        },
        providers = {
            pi = { name = "Pi", module = "pi.completion.blink" },
        },
    },
})
```

Other completion plugins (nvim-cmp, etc.) aren't shipped as first-class sources, but they can usually bridge the built-in `completefunc` via their `omni`/`completefunc` source adapters. If you'd like a native source for another plugin, please open an issue.

### Attachments

π supports image attachments. Anything you attach is queued in the dedicated **attachments panel** (`pi-chat-attachments`) below the prompt and sent along with your next message as base64-encoded image data.

Supported formats: `png`, `jpg`/`jpeg`, `gif`, `webp`, `svg`.

There are three ways to attach an image:

**1. From a file path** with `:PiAttachImage`:

```vim
:PiAttachImage path/to/screenshot.png
```

The path is resolved relative to the current working directory. Also exposed as `pi.attach_image(path)` from Lua.

**2. From the clipboard** with `:PiPasteImage`:

```vim
:PiPasteImage
```

This requires [`HakonHarnes/img-clip.nvim`](https://github.com/HakonHarnes/img-clip.nvim) and a system clipboard tool (`pngpaste` on macOS, `xclip` on X11, `wl-paste` on Wayland). Clipboard images are auto-named `cb-image-1.png`, `cb-image-2.png`, and so on. Also exposed as `pi.paste_image()` from Lua.

**3. By drag-and-drop**, by dragging an image file into the π prompt buffer from your OS file manager. π intercepts the drop, recognizes it as a file path with a supported image extension, and adds it as an attachment instead of pasting the path as text. Plain-text pastes are not affected.

Once attached, items appear in the attachments panel as `󰂾 filename.png`. To remove an entry, focus the attachments panel, put the cursor on the line you want to drop, and press `dd` or `x`. Both buffer-local mappings remove the item under the cursor.

Attachments are cleared automatically when the message is sent. If you want to discard the queue without sending, just delete each entry with `dd`/`x`.

### Zen mode

Zen mode is a full-screen overlay that promotes the π prompt to a centered floating window over a dimmed backdrop. The history, attachments, and the rest of your editor disappear behind the backdrop, leaving only the prompt visible. It's the right mode when you need to compose a long message — a multi-paragraph spec, a detailed bug report, a planning brain dump — without the rest of the UI distracting you.

While zen is active:

- The prompt is centered horizontally and spans the full editor height.
- Width comes from `zen.width` (in columns); if unset, π falls back to your `'textwidth'`, then to 80.
- You can't accidentally navigate away — π bounces focus back to the prompt if you try to leave it. Floating windows like dialogs and completion popups are still allowed.
- The geometry auto-recomputes on `VimResized`.
- Submitting (`<CR>` / `<A-CR>`) automatically exits zen and returns you to the normal chat layout.

#### Configuring zen keys

Zen mode has **no default keymap** — you have to opt in by setting at least `zen.keys.toggle`. Optionally, you can also set `zen.keys.exit` to bind extra keys that only exit zen (the toggle key always works for both directions).

```lua
require("pi").setup({
    zen = {
        -- Optional: width in columns. nil = textwidth, then 80.
        width = 100,
        keys = {
            -- Toggle: enters zen when inactive, exits when active.
            toggle = { "<M-z>", modes = { "n", "i" } },
            -- Exit-only: any of these keys leaves zen but doesn't enter it.
            exit = {
                { "<Esc>", modes = "n" },
            },
        },
    },
})
```

The toggle key is registered as a permanent buffer-local mapping on the prompt buffer. Exit keys are bound only while zen is active, and any pre-existing buffer-local mappings on the same `lhs` are saved and restored when zen exits, so they don't get clobbered. See [Key specs](#key-specs) for the format of `zen.keys.toggle` / `zen.keys.exit` values.

### Statusline

π renders a configurable status line pinned to the bottom of the prompt buffer. It's where session-level info lives — current model, thinking level, context usage, token counts, cost, pending attention, and anything else you want to surface from your extensions.

The layout is split into **left** and **right** groups. Each group is just an array of items, and items can be:

- **A built-in component name** — a string matching one of the built-ins listed below.
- **A literal separator** — any other string, rendered between two _visible_ components as-is. If the next component is hidden, the separator is dropped too, so `{ "a", "  ", "b" }` automatically collapses to just `a` when `b` has nothing to show.
- **A custom component function** — `function(state) -> string|chunks|nil`. See below.

```lua
require("pi").setup({
    statusline = {
        layout = {
            left  = { "context", "  ", "cost", "  ", "attention" },
            right = { "model", "   ", "thinking" },
        },
    },
})
```

#### Built-in components

| Name | Example output | When it's visible |
| --- | --- | --- |
| `tokens` | `↑3.8k ↓58k` | Total input/output tokens used this session |
| `cache` | `R7.2M W416k` | Total prompt-cache read/write |
| `cost` | `$7.665` | Session cost is greater than zero |
| `context` | `63.9%/200k` | Current context window usage — percentage + total |
| `compaction` | `(auto)` | Auto-compaction is enabled |
| `attention` | `󰵚` / `󰵚 2` | There's at least one pending attention request |
| `model` | `claude-opus-4-6` | A model is active |
| `thinking` | `xhigh` / `thinking off` | The current model supports reasoning |

Any component that has nothing to show returns `nil` and is silently skipped (along with its adjacent separator).

#### Component config

Per-component options live under `statusline.components.<name>`:

```lua
statusline = {
    components = {
        -- Every built-in takes an `icon` prefix. Set to `false` to disable.
        compaction = { icon = false },
        model = { icon = "󰚩" },

        -- `context` supports warning / error thresholds as percentages
        -- of the model's context window. When crossed, the value is
        -- rendered in `PiStatusLineWarning` / `PiStatusLineError`.
        context = { icon = "", warn = 70, error = 90 },

        -- `cost` supports the same thresholds as raw numbers.
        -- cost = { icon = "", warn = 5, error = 10 },

        -- `attention` can show a numeric counter instead of the icon.
        attention = { icon = "󰵚", counter = false },
    },
},
```

#### Custom components

A custom component is a function that receives the current statusline state and returns either a string, a list of styled chunks, or `nil` to hide itself:

```lua
---@param state pi.StatusLineState
---@return string|string[][]|nil text
---@return string?             hl
local function my_component(state)
    -- ...
end
```

The `state` table exposes everything the built-ins see — model info, thinking level, token totals, cost, context usage, and a `state.extensions` map of per-extension status values (populated via the RPC `setStatus` call from extensions).

Drop a custom component anywhere in the layout array. For example, surfacing a status from an extension:

```lua
statusline = {
    layout = {
        left = {
            "context",
            "  ",
            function(state)
                if state.extensions["permission"] then
                    return "󰐌", "PiStatusLineOn"
                end
            end,
            "  ",
            "attention",
        },
        right = { "model", "   ", "thinking" },
    },
},
```

Return shapes:

- `"some text"` — single chunk, default highlight (`PiStatusLine`).
- `"some text", "MyHl"` — single chunk with an explicit highlight group.
- `{ { "part1", "Hl1" }, { "part2", "Hl2" } }` — multiple chunks with per-chunk highlights.
- `nil` — hide the component (and any adjacent separator).

### Navigation

Moving between π panels and scrolling the history without leaving the prompt are some of the most common things you do during a session, so they're worth setting up properly. As with the rest of [Keymaps](#keymaps), pi.nvim doesn't bind these by default — it just exposes the API and lets you wire it into the navigation conventions you already use.

#### Focus

Three functions move focus between the panels of the current chat:

```lua
local pi = require("pi")

pi.focus_chat_history()      -- jump to the history window
pi.focus_chat_prompt()       -- jump to the prompt window
pi.focus_chat_attachments()  -- jump to the attachments window
```

All three are no-ops when no π session is active in the current tab.

The natural place to bind them is inside the panel buffers themselves, via `FileType` autocmds on `pi-chat-history`, `pi-chat-prompt`, and `pi-chat-attachments`. The example in [Keymaps](#keymaps) wires `<S-Up>` / `<S-Down>` to walk between panels, but the actual keys are entirely up to you — use whatever you already use for window navigation in the rest of Neovim.

#### Scrolling history from the prompt

When the agent is in the middle of a long answer, you usually want to keep typing your next message _while_ peeking at what just scrolled past. Leaving the prompt to scroll the history is awkward, so π lets you scroll the history window from anywhere:

```lua
pi.scroll_chat_history("up")     -- scroll up by 15 lines (default)
pi.scroll_chat_history("down")   -- scroll down by 15 lines
pi.scroll_chat_history("up", 2)  -- finer-grained scroll, 2 lines at a time
```

The second argument is the line count; it defaults to `15` when omitted. Bind both a coarse and a fine-grained step if you want — a fast jump for skimming and a slow nudge for reading.

There are also two jump-style helpers:

```lua
pi.scroll_chat_history_to_bottom()                -- jump to the very latest line
pi.scroll_chat_history_to_last_agent_response()   -- jump to the start of the most recent agent message
```

The "last agent response" jump is particularly handy when the agent has just produced a long answer and you want to read it from the top without manually scrolling back.

Like the focus functions, all four scroll functions are no-ops when no session is active. See the [Keymaps](#keymaps) example for typical bindings inside the prompt buffer.

### Diff review

When an `edit` or `write` tool is about to run, pi.nvim can intercept it and open a two-way diff in a new tab so you can inspect, tweak, and accept or reject the change _before_ it lands on disk. This is the main review surface for agent-driven refactoring.

Once the diff is open:

- **Left pane** — the current file content.
- **Right pane** — the content the agent is proposing.
- Both panes are normal editable buffers. You can modify the _right_ pane before accepting — anything you change there becomes the new content and pi.nvim will write your edited version instead of the agent's original proposal.
- **Accept** with `<Leader>da` (default) — or just `:w` the right pane.
- **Reject** with `<Leader>dr`.
- **Expand / shrink** the surrounding diff context with `<Leader>de` / `<Leader>ds`. The initial context comes from `diff.context.base` (or `'diffopt'` when unset), and the step size from `diff.context.step`.

All keys are configurable under `diff.keys` using the [Key specs](#key-specs) format, so you can bind multiple keys, pin modes, or replace them entirely. The winbar of the proposed pane always shows the currently-bound keys for all four actions so you don't have to remember them.

#### You need a permission extension

Here's the part to understand before the rest of this section makes sense: **pi itself has no built-in permission system**. The agent dispatches tools whenever it decides to, and by default nothing stands between it and your files. pi.nvim's diff review _only_ triggers when an extension intercepts `edit`/`write` tool calls and routes them through a specially-formatted `ctx.ui.select` request.

In other words, **without a permission extension, there is no diff review**. The agent will apply edits directly, and you'll see them in the chat history as completed tool calls, not as reviewable diffs.

If you want a drop-in, fully-featured solution, use my reference implementation: [**alex35mil/agentic-af/extensions/permission**](https://github.com/alex35mil/agentic-af/tree/main/extensions/permission). It is very similar to Claude Code's allow / ask / deny model with glob rules, per-tool argument matching, skill-derived allowances, bash argument splitting and redirection safety, and an auto-accept toggle.

If you'd rather roll your own, or just want to understand the protocol, here's a minimal pi extension that intercepts `edit` and `write` tool calls, routes them through pi.nvim's diff review UI, and handles all response variants.

<details>
<summary><strong>Minimal example</strong> — click to expand</summary>

```ts
/**
 * Minimal diff-review permission extension for pi + pi.nvim.
 * Intercepts every `edit` and `write` tool call and routes it through
 * pi.nvim's diff review UI via ctx.ui.select.
 */
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent"

// Track which tool calls the user approved so we can flip the
// blocked-isError flag back in a message_end handler.
const approvedToolCalls = new Set<string>()

export default function (pi: ExtensionAPI) {
    pi.on("tool_call", async (event, ctx) => {
        if (event.toolName !== "edit" && event.toolName !== "write") {
            return undefined // other tools run without review
        }

        if (!ctx.hasUI) {
            return {
                block: true,
                reason: `[rejected] No UI available to review ${event.toolName}`,
            }
        }

        const path = (event.input as { path?: string }).path
        if (!path) return undefined

        // Build the payload pi.nvim recognizes as a diff review request.
        const title = JSON.stringify({
            prompt: `${event.toolName}: ${path}`,
            toolName: event.toolName,
            toolInput: event.input,
        })
        const choice = await ctx.ui.select(title, ["Accept", "Reject"])

        // pi TUI path: plain "Accept" — let the tool run normally.
        if (choice === "Accept") {
            return undefined
        }

        // pi.nvim path: structured JSON response.
        if (choice?.startsWith("{")) {
            const parsed = JSON.parse(choice)

            if (parsed.result === "Accepted") {
                // pi.nvim already wrote the file — block the tool so
                // pi's dispatcher doesn't double-write.
                approvedToolCalls.add(event.toolCallId)
                return {
                    block: true,
                    reason: `[accepted] User approved the edit. Changes applied to ${path} as proposed.`,
                }
            }

            if (parsed.result === "AcceptModified") {
                // pi.nvim wrote a user-modified version of the file.
                approvedToolCalls.add(event.toolCallId)
                return {
                    block: true,
                    reason:
                        `[accepted] User approved with modifications. ${path} was updated with user's version, which differs from what you proposed. Current content of ${path}:\n` +
                        "```\n" + parsed.content + "\n```",
                }
            }
        }

        // Anything else — rejected.
        ctx.abort()
        return {
            block: true,
            reason: `[rejected] User rejected the edit to ${path}. File unchanged.`,
        }
    })

    // Blocked tool results come back as isError=true. Flip that back
    // for approved calls so the agent doesn't treat accepted edits as
    // failures.
    pi.on("message_end", async (event) => {
        const msg = event.message as { role?: string; toolCallId?: string; isError?: boolean }
        if (msg.role !== "toolResult") return
        if (typeof msg.toolCallId !== "string") return
        if (approvedToolCalls.delete(msg.toolCallId)) {
            msg.isError = false
        }
    })
}
```

Drop that file into your pi extensions directory (usually `~/.pi/agent/extensions/<name>/index.ts`) and pi will load it on the next session. See the [pi extensions docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) for how extensions are discovered and registered.

</details>

#### Protocol reference

pi.nvim routes an extension `select` request to the diff review UI if and only if:

1. The request method is `select`, and
2. The `title` field is a JSON string that decodes to an object with `toolName === "edit"` or `"write"`.

Otherwise it's treated as a regular select dialog.

**Request payload** (`JSON.stringify` this and pass it as the `title` argument to `ctx.ui.select`):

```json
{
  "prompt": "edit: /abs/path/to/file.ts",
  "toolName": "edit",
  "toolInput": {
    "path": "/abs/path/to/file.ts",
    "edits": [{ "oldText": "...", "newText": "..." }]
  }
}
```

For `write`, replace `edits` with `"content": "<full file text>"`.

**Response** (the value returned from `await ctx.ui.select(...)`):

| Value | Meaning | Extension should… |
| --- | --- | --- |
| `"Accept"` | Only returned by the pi TUI, not by pi.nvim. | Return `undefined` and let the tool run normally. |
| `'{"result":"Accepted"}'` | User accepted. pi.nvim already wrote the file. | Return `{ block: true, reason: "[accepted] ..." }` so pi doesn't double-write. |
| `'{"result":"AcceptModified","content":"..."}'` | User edited the proposal, then accepted. pi.nvim already wrote the modified version. | Return `{ block: true, reason: "[accepted] ..." }`, ideally including the modified content so the agent sees the final state. |
| Anything else (`"Reject"`, `undefined`, cancellation) | User rejected. | Return `{ block: true, reason: "[rejected] ..." }`. |

For `AcceptModified` specifically, it's important to surface the final content back to the agent — not just the fact that the edit was accepted. The proposal the agent made and the bytes that actually landed on disk are no longer the same, and if the agent assumes its proposal went through verbatim it will reason about a file state that doesn't exist. The reference extension uses a `reason` string along these lines:

> `[accepted] User approved with modifications. <path> was updated with user's version, which differs from what you proposed. Current content of <path>:`
> ` ```
`
> `<full modified content>
`
> ` ``` `

This gives the agent three things in one message: confirmation that the edit landed, an explicit note that the user changed it, and the new authoritative content so the next turn starts from the right file state.

The `[accepted]` and `[rejected]` prefixes in the `reason` string are parsed by pi.nvim and used to pick the tool-call display status (completed vs rejected) in the chat history.

Because pi.nvim writes the file _itself_ for `Accepted` and `AcceptModified`, the extension **must** return `{ block: true }` in those cases. If it doesn't, pi's tool dispatcher will run the original `edit`/`write` on top of pi.nvim's version and you'll end up with a double-apply.

Blocked tool results come back to the agent with `isError: true`. For approved-but-blocked calls, flip that back in a `message_end` handler (as the minimal example does) so the LLM doesn't treat an accepted edit as a failure on the next turn.

### Attention & dialogs

Extensions can ask the user for input mid-turn — selects, confirms, free-form text, multi-line editors, and the diff review described above are all different flavors of the same thing under the hood: an `extension_ui_request` that blocks the agent until the user responds. pi.nvim calls these **attention requests**, and they share a single queue and UI surface.

#### Immediate vs queued

When a request arrives, pi.nvim decides between showing it immediately and queueing it:

- **Immediate** — if the current tab's π prompt is focused _and_ has no draft text, the request is dispatched right away. This is the common case while you're actively working with the agent: confirmations, selects, and diffs just pop up as soon as they're needed.
- **Queued** — otherwise (you're editing another file, you have draft text in the prompt, you're in a different tab, etc.), the request is added to a per-session queue, an attention indicator lights up in the statusline, and a notification appears so you don't lose track of it. The agent stays blocked on that request regardless.

Queued requests can be opened on demand with:

- `:PiAttention` — open the oldest queued request across all tabs, switching to its tab if needed.
- `pi.attention()` — same thing from Lua.

Both are no-ops when there's nothing queued.

#### Auto-open on prompt focus

By default (`attention.auto_open_on_prompt_focus = true`), simply focusing the π prompt with an empty draft pulls the next queued request for the current tab automatically. This matches the mental model of "the prompt is the place where the agent talks to you" — when you show up at the prompt ready to interact, π dispatches whatever's pending.

Disable this if you prefer to control the timing manually:

```lua
require("pi").setup({
    attention = {
        auto_open_on_prompt_focus = false,
    },
})
```

With auto-open disabled, you drain the queue explicitly with `:PiAttention`.

#### Completion notification

`attention.notify_on_completion` (default `true`) shows an info notification when the agent finishes a turn and the π prompt isn't focused:

> Agent finished - waiting for your input

Handy if you are working on something else, either code or talk with another agent in a neighbor tab, while the agent is working and want a heads-up when it's done. Disable with `attention.notify_on_completion = false`.

#### Querying the queue

A few Lua functions let you inspect the attention state without opening anything — useful for custom statuslines, tabline indicators, or extension widgets:

```lua
local pi = require("pi")

pi.attention_count()         -- pending requests for the current tab
pi.attention_count(tab_id)   -- pending requests for a specific tab
pi.attention_total()         -- pending requests across all tabs
pi.has_attention()           -- boolean shortcut for the current tab
pi.attention_state()         -- full state snapshot
```

pi.nvim also fires a `User` autocmd when a new request is added to the queue:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "PiAttentionRequested",
    callback = function(event)
        local data = event.data
        -- data.tab, data.kind ("diff"|"select"|"confirm"|"input"|"editor"),
        -- data.tab_count, data.total_count
    end,
})
```

The built-in `attention` statusline component already uses this state — see [Statusline](#statusline) for its icon/counter options.

#### Dialog UI

Selects, confirms, inputs, and editors are all rendered through pi.nvim's dialog UI. Everything lives under `dialog` in `setup()`:

```lua
require("pi").setup({
    dialog = {
        border = "rounded",
        -- Max size: fraction (<1) of editor, or columns/lines (>=1).
        max_width = 0.8,
        max_height = 0.8,
        -- Sign text shown next to the selected item in selects.
        indicator = "▸",
        keys = {
            -- Additional keys, on top of the built-in defaults below.
            -- See the Key specs section for the format.
            confirm = { { "<C-CR>", modes = { "n", "i" } } },
            cancel = nil,
            next = nil,
            prev = nil,
        },
    },
})
```

Dialogs always come with a base set of keybindings; `dialog.keys` adds to them rather than replacing them:

| Action | Built-in keys | What it does |
| --- | --- | --- |
| `confirm` | `<CR>` (normal + insert) | Accept the current selection / value |
| `cancel` | `<Esc>`, `q` (normal) | Dismiss without responding (extension sees a cancellation) |
| `next` | `j`, `<Down>` | Move to the next option (selects only) |
| `prev` | `k`, `<Up>` | Move to the previous option (selects only) |

Anything you add under `dialog.keys.<action>` is bound in addition to the built-ins, so you can keep the defaults and just add your preferred shortcuts on top.

### Startup block

At the top of every π chat history, pi.nvim renders a **startup block** — a summary of what the agent has available in the current session. It lives just above the first message and is always in the history buffer.

By default the block is fully expanded. Set `expand_startup_details = false` to have it start collapsed, and toggle it at any time with either:

- `<Tab>` on the block in the history buffer (the same `<Tab>` that expands/collapses tool blocks under the cursor).
- `:PiToggleStartupDetails` / `pi.toggle_startup_details()`.

#### What's in it

pi.nvim pulls the startup content from the backend's `get_commands` RPC response and groups it into up to three built-in sections:

- **`[Skills]`** — skill commands (`skill:name`) loaded for this session, with their location (`[user]` / `[project]` / `[path]`) and source path.
- **`[Prompts]`** — prompt templates (`/name`) loaded for this session, with location and path.
- **`[Extensions]`** — commands registered by pi extensions, with their source paths.

Sections only appear when they have at least one entry, so a bare session with no skills or extensions just shows whatever exists.

> [!WARNING]
> The startup block is currently **incomplete**, and this is an upstream pi limitation rather than something pi.nvim can fix on its own. The RPC interface only exposes a subset of what the session actually has loaded — for example, loaded extensions that don't register any `/commands` are not surfaced here (even though they're running and active), and memory files (`AGENTS.md`, etc.) aren't reported at all. Treat the block as a useful-but-partial snapshot until the upstream protocol catches up. Until then, the most reliable way for an extension to advertise itself is via [extension startup announcements](#extension-startup-announcements) — sending a `:startup` widget with whatever state it wants the user to see.

#### Extension startup announcements

Extensions can add their own sections to the startup block by calling `ctx.ui.setWidget` with a **widget key ending in `:startup`**. pi.nvim routes those widgets into the startup block instead of rendering them inline, and the `:startup` suffix is stripped from the key for display.

For example, an extension calling:

```ts
ctx.ui.setWidget("permission:startup", [
    "defaultMode: ask",
    "allow: read, bash(git *)",
    "deny:  bash(rm -rf *)",
])
```

renders in the startup block as:

```
[Extension: permission]
  defaultMode: ask
  allow: read, bash(git *)
  deny:  bash(rm -rf *)
```

This is the intended surface for extensions that want to show session-relevant state the user should see up-front (current mode, loaded rules, active hooks, etc.) without cluttering the conversation itself.

Note the distinction from regular widgets: `setWidget` calls with keys that **don't** end in `:startup` are passed to your `on_widget` config hook instead and can be rendered inline in the history. See the [Extensions & custom rendering](#extensions--custom-rendering) section below for the inline widget path.

### Tool blocks

When the agent invokes a tool, pi.nvim renders the call inline in the chat history as a **tool block**. Each block shows the tool name, its input summary, and its output, framed by a lightweight border in the gutter.

```
╭─ 󰻂 bash
│  rg -n 'foo' lua/
├────
│  …12 lines
│  lua/pi/init.lua:42: foo = 1
╰─  completed
```

The labels in the header and footer come from `labels.tool`, `labels.tool_success`, `labels.tool_failure` in your config. The success/failure icon on the bottom row reflects how the tool actually resolved (see [Status resolution](#status-resolution) below).

#### Inline vs full blocks

Tools come in two rendering styles:

- **Inline tools** render as a single line. `read` is the canonical example — it shows `read path/to/file (42 lines)` and stays on one line even when the file is huge, because inlining the content would just be noise. Consecutive inline tool calls are grouped without blank lines between them.
- **Full-block tools** get the multi-line bordered block shown above. `bash`, `edit`, `write`, and any tool pi.nvim doesn't have a dedicated renderer for fall into this category.

#### Auto-collapse and `<Tab>`

Every full-block tool has two collapse thresholds:

- `input_visible` — how many lines of the input/arguments to show when collapsed. Extra lines become `+N lines`.
- `output_visible` — how many lines of the tool output to show when collapsed. `output_visible = 0` hides the output section entirely when collapsed (used for `edit`/`write` where the diff is the input).

When a tool's input or output exceeds its threshold, the block is auto-collapsed on first render. You can toggle between the collapsed and fully-expanded view with `<Tab>` while the cursor is on the block in the history buffer. The same `<Tab>` also toggles the [Startup block](#startup-block) when the cursor is on that instead — pi.nvim dispatches based on what you're hovering over.

Built-in thresholds:

| Tool | `input_visible` | `output_visible` | Notes |
| --- | --- | --- | --- |
| `bash` | 1 | 1 | Shows first line of command + first line of output when collapsed |
| `read` | — | — | Always inline |
| `edit` | unlimited | 0 | Renders the proposed diff as input; no separate output section |
| `write` | unlimited | 0 | Same shape as `edit` for a whole-file write |
| (unknown) | 1 | 1 | Default renderer picks the first string argument as summary |

#### Status resolution

pi.nvim picks the tool's display status from the `isError` flag plus any status prefix embedded in the result text by an extension:

| Prefix in result | Display status |
| --- | --- |
| _none_ (and `isError=false`) | `completed` |
| `[accepted]` | `completed` (blocked but the action was applied) |
| `[rejected]` | `rejected` (user or policy refused) |
| `[aborted]` | `aborted` (turn was aborted while the tool was in flight) |
| _none_ (and `isError=true`) | `error` |

The prefix is stripped from the displayed text before the block is rendered, so your users never see the raw `[accepted]` / `[rejected]` markers — just the tool block in the corresponding state. This is how the permission extension in [Diff review](#diff-review) communicates "accepted but already applied elsewhere" back to pi.nvim without looking like an error.

#### Customization

> [!NOTE]
> Tool renderers are currently **hard-coded** in `lua/pi/ui/chat/tools.lua`. There's no config surface for registering your own renderer, adjusting built-in thresholds, or overriding the border glyphs. If you'd like any of these to be configurable, please open an issue.

### Models

π can talk to any model your local pi installation has access to — Claude, GPT, Gemini, Groq, OpenRouter, DeepSeek, locally-hosted models, and whatever else you've configured in your pi backend. pi.nvim doesn't manage credentials or provider wiring; all of that lives in pi itself. What pi.nvim _does_ give you is a way to shape the set of models you see, cycle through them quickly, and switch mid-session without restarting the chat.

#### The `models` list

The top-level `models` option in `setup()` is an optional **preferred list** of model entries. When set, it curates the subset used by the cycle and select commands below. When unset, pi.nvim falls back to whatever the backend has available.

Each entry is one of:

```lua
require("pi").setup({
    models = {
        -- 1. Plain string — exact model ID match (case-sensitive).
        "gpt-5.3-codex",

        -- 2. Exact match (equivalent to the bare string form).
        { match = "gpt-5.3-codex", exact = true },

        -- 3. Substring match (case-insensitive), all hits included in order.
        { match = "sonnet" },

        -- 4. Substring match with `latest = true` — picks the single model
        --    whose ID sorts last among the matches. Because provider IDs
        --    usually end in a date suffix, this resolves to the newest.
        { match = "opus", latest = true },
        { match = "gpt", latest = true },
    },
})
```

Entries are resolved at each cycle/select call against the backend's current model list. A warning is logged if an entry matches nothing.

#### Cycling and selecting

Three commands, each with a Lua API counterpart:

| Command | Lua | What it does |
| --- | --- | --- |
| `:PiCycleModel` | `pi.cycle_model()` | Step to the next model. With `models` configured, cycles within the resolved subset; otherwise uses the backend's own cycle. |
| `:PiSelectModel` | `pi.select_model()` | Open a dialog to pick a model. With `models` configured, shows only the resolved subset; otherwise falls back to all available models. |
| `:PiSelectModelAll` | `pi.select_model_all()` | Open a dialog with **all** backend-available models, ignoring the `models` config. Useful when you want to reach for something you haven't curated into your short list. |

All three take effect immediately and persist for the current session. The active model appears in the `model` statusline component (see [Statusline](#statusline)).

Typical setup binds the three operations in the prompt buffer: a fast cycle key, a filtered picker, and an "all models" escape hatch. The [Keymaps](#keymaps) example uses `<M-m>` / `<M-M>` / `<M-S-m>` for this.

### Thinking

Reasoning-capable models (Claude's extended thinking, OpenAI's `o*` family, OpenAI codex, etc.) emit **thinking blocks** alongside their normal output — an internal monologue the model uses to work through a problem before producing a final answer. pi.nvim renders these inline in the chat history with a distinct `labels.thinking` marker.

#### Visibility

Thinking blocks can be noisy, especially on models that think verbosely or on long turns, so pi.nvim hides them by default. You can flip the default and toggle visibility on demand:

- **Default**: `show_thinking` (bool in `setup()`) — `false` by default.
- **Toggle**: `:PiToggleThinking` / `pi.toggle_thinking()` — show or hide all thinking blocks in the current session.

Hiding thinking doesn't change anything on the backend or affect how the agent works; it's purely a view setting.

#### Thinking levels

Beyond visibility, reasoning-capable models let you pick _how much_ the model thinks. pi.nvim exposes the backend's six thinking levels:

```
off | minimal | low | medium | high | xhigh
```

`off` disables reasoning entirely (where the model supports that), and each successive level gives the model more budget to think. `xhigh` is OpenAI codex-max-only; the other five are broadly supported across reasoning models. The currently-active level appears in the `thinking` statusline component (see [Statusline](#statusline)).

Two ways to change it mid-session:

- **Cycle**: `:PiCycleThinking` / `pi.cycle_thinking_level()` — steps to the next level in the list. Handy for a single key you can tap repeatedly.
- **Pick**: `:PiSelectThinking` / `pi.select_thinking_level()` — opens a dialog with all six levels and the current one preselected.

Both operations require an active session with a reasoning-capable model; on a non-reasoning model they warn _"Current model does not support thinking"_ and leave state unchanged.

Typical setup binds both in the prompt buffer: cycle on a fast key (e.g. `<M-t>`) and pick on a shifted variant (`<M-T>`) — the [Keymaps](#keymaps) example already does this.

### Sessions

π is session-oriented: every conversation is persisted to disk as it happens, you can leave one in the middle of a turn and pick it up later, and pi.nvim gives you a few ways to navigate between them.

#### One chat per tab

pi.nvim keeps **one live session per Neovim tabpage**. Two different tabs give you two independent conversations with their own history, prompt buffer, attachments, model, and thinking level. Closing the tab tears the session down, and nothing bleeds across tabs. This is the natural unit of work in Neovim, and it maps cleanly to "one agent per task" — e.g. one tab for an exploratory refactor and another for feature implementation, each with their own context.

#### Storage and scoping

Session files are JSONL documents stored under:

```
<agent_dir>/sessions/<encoded-cwd>/*.jsonl
```

where `<agent_dir>` is resolved in this order:

1. `agent_dir` in `require("pi").setup(...)`
2. `$PI_CODING_AGENT_DIR` environment variable
3. `~/.pi/agent` (default)

Crucially, sessions are **scoped to the current working directory**. Sessions started in `~/Dev/project-a` are only visible to continue/resume when pi.nvim is running from the same directory. This matches how you'd actually want it: you don't want to accidentally resume an unrelated project's conversation just because you opened a chat in a new tab.

#### Starting, continuing, resuming

There are three ways to open a chat — each honors the usual `layout=side|float` override:

| Command | Lua | What it does |
| --- | --- | --- |
| `:Pi` | `pi.show()` / `pi.toggle()` | Open the chat. If the current tab has no session yet, starts a fresh conversation. |
| `:PiContinue` | `pi.continue_session()` | Load the **most recent** session for the current cwd. Skips the session currently live in another tab, so you can continue a different one. |
| `:PiResume` | `pi.resume_session()` | Open a picker listing **all past sessions for the current cwd**, with their display names, timestamps, and message counts. |

And mid-session management:

| Command | Lua | What it does |
| --- | --- | --- |
| `:PiNewSession` | `pi.new_session()` | Discard the current session in this tab and start a fresh one. Extensions can cancel this via the `session_before_switch` hook (e.g. to warn about unsaved draft state). |
| `:PiSessionName [name]` | `pi.set_session_name(name?)` | Set a human-readable display name for the current session. Without an argument, opens a dialog to type one. Without any argument and via the API, returns the current name. Names appear in the `:PiResume` picker so you can identify long-running conversations at a glance. |
| `:PiStop` | `pi.stop()` | Tear down the current session entirely, killing the backing `pi --mode rpc` process. Different from `:PiToggleChat`, which just hides the windows while the session keeps running. |

#### Compaction

Long sessions eventually run into the model's context window limit. pi delegates this to a **compaction** step: the backend summarizes older parts of the conversation and replaces them with the summary, freeing up tokens for new turns. pi supports both automatic and manual compaction.

- **Automatic compaction** is enabled at the backend level. When the conversation approaches the context threshold, pi compacts on its own and the `compaction` statusline component lights up (see [Statusline](#statusline)).
- **Manual compaction** — `:PiCompact [instructions]` / `pi.compact(instructions?)` — triggers compaction immediately. If you pass custom instructions, they're forwarded to the summarizer to guide what gets kept:

```vim
:PiCompact focus on architectural decisions and the reasoning behind them; drop intermediate tool outputs
```

Compaction can't run while the agent is streaming — wait for the current turn to finish (or abort it) first.

### Extensions & custom rendering

pi extensions are small TypeScript (or Node-compatible) modules that the backend loads at session start. They can intercept tool calls, register slash commands, expose keybindings, surface UI to the user, and inject arbitrary content into the chat. The permission extension in [Diff review](#diff-review) is one example; the `rules:load` / progressive-disclosure hooks in [agentic-af](https://github.com/alex35mil/agentic-af) are others.

pi.nvim is extension-aware. When pi runs under `--mode rpc`, extensions can address the client (pi.nvim) via the [extension UI protocol](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/rpc.md#extension-ui-protocol), and pi.nvim routes each method to the right surface in your editor:

| Extension UI method | Where pi.nvim surfaces it |
| --- | --- |
| `notify` | `vim.notify` via the configured notify dispatcher |
| `setStatus` | `state.extensions[key]` in the statusline state (readable by custom [statusline](#statusline) components) |
| `setWidget` with key ending in `:startup` | [Startup block](#startup-block) announcement |
| `setWidget` with any other key | Your `on_widget` config hook (see below) |
| `select` | Dialog or [diff review](#diff-review), depending on the payload |
| `confirm` | Confirmation dialog |
| `input` / `editor` | Input dialog |
| `setTitle`, `set_editor_text` | Currently ignored (warned once) |

Dialog-style methods (`select`, `confirm`, `input`, `editor`) flow through the [Attention & dialogs](#attention--dialogs) queue described above. This section focuses on the piece that hasn't been covered yet: `on_widget`.

#### Inline custom blocks via `on_widget`

> [!NOTE]
> Conceptually, this is a hack. `setWidget` was designed in the upstream pi protocol as a way for extensions to surface UI widgets in the TUI, not as a general extension ↔ pi.nvim communication channel. pi.nvim piggybacks on it because it's currently the **best handle pi provides** for an extension to push arbitrary data into the client. If/when pi gets a dedicated extension-to-client message type, this mechanism will likely be revisited. For now, treat `on_widget` as the escape hatch where "extension wants to say something to pi.nvim" becomes possible at all.

When an extension calls `ctx.ui.setWidget(key, lines)` with a key that **doesn't** end in `:startup`, pi.nvim passes it to your `on_widget` config function. The hook gets a chance to return a **custom block** that pi.nvim will render inline in the history — right at the point in the conversation where the extension fired.

The signature:

```lua
---@param key string            -- the widgetKey the extension sent
---@param lines string[]|nil    -- widgetLines (nil when the extension cleared the widget)
---@param placement string|nil  -- "aboveEditor" / "belowEditor" (as sent by the extension)
---@return pi.CustomBlock|nil
function(key, lines, placement)
    -- return a block, or nil to ignore this widget
end
```

Return `nil` to ignore a widget and let it vanish quietly. Return a `pi.CustomBlock` to render it inline:

```lua
---@class pi.CustomBlock
---@field target  "history"          -- only "history" is supported today
---@field block   "custom"           -- discriminator; always "custom"
---@field content pi.CustomBlockLine[]
```

A `pi.CustomBlockLine` is a list of styled chunks, and each chunk is a `{ text, hl_group? }` pair:

```lua
-- One line, two chunks with different highlights:
{
    { "    ╰  rule: ", "Comment" },
    { ".agents/rules/ts.md", "PiMention" },
}
```

#### Example

Let's walk through a concrete case. My [rules extension](https://github.com/alex35mil/agentic-af/tree/main/extensions/rules) discovers Markdown rule files under `~/.pi/agent/rules/` (global) and `<repo>/.agents/rules/` (project). Some rules are always-on — their bodies are injected into the system prompt on every turn. Others are **path-scoped**: they have a `paths:` glob list in the frontmatter and are only delivered when the agent reads a file that matches one of those globs. In that case the extension appends the rule body to the `read` tool result (so the agent sees it) _and_ fires a `setWidget("rules:load", [...rule paths])` so **you** can see, inline in the chat, which rules just got loaded for which file.

Without `on_widget`, that widget would simply be ignored by pi.nvim. With `on_widget`, it becomes a small annotation attached to the read tool call, telling you exactly which rules the agent now has in its context for the file it just read. It's the difference between trusting that the rules extension is doing its job and being able to _see_ it do its job.

Here's the hook that turns that widget into an inline annotation:

```lua
require("pi").setup({
    on_widget = function(key, lines)
        if key == "rules:load" and lines then
            local content = {}
            for _, line in ipairs(lines) do
                content[#content + 1] = {
                    { "   ╰  rule: " .. line, "Comment" },
                }
            end
            return {
                target = "history",
                block = "custom",
                content = content,
            }
        end
        return nil
    end,
})
```

On the extension side, the rules extension watches tool calls (`read`, `edit`, `write`, etc.) and, when it matches a file against one of its rule definitions, fires a widget listing the **paths of the rule files** that apply:

```ts
ctx.ui.setWidget("rules:load", [
    ".agents/rules/lua.md",
    ".agents/rules/neovim.md",
])
```

pi.nvim calls your `on_widget`, sees the returned block, and writes it into the history buffer at the current insertion point — so the list appears directly underneath the tool call that triggered it, making it obvious which rules the agent should have loaded for that particular file.

The payload the extension sends is deliberately minimal (just rule file paths); turning that into a nicely-formatted inline block — prefix, icon, highlight — is entirely the job of `on_widget` on the Neovim side. Different users can present the same widget data however they want without the extension having to know anything about styling.

#### Limitations

Same upstream constraint as [Startup block](#startup-block): `setWidget` in RPC mode only carries string arrays. Styling and structure are added _in pi.nvim_ by your `on_widget` hook — the extension can't pre-style the output. Give `on_widget` everything it needs to make decisions (the `key` namespaces widgets from different extensions, and `lines` carries the payload) and do the formatting there.

### Health & debugging

When something misbehaves — the agent doesn't respond, a tool doesn't render correctly, an extension event doesn't arrive — pi.nvim gives you a few places to look.

#### `:checkhealth pi`

The health check verifies the basics:

- The `pi` executable (from the `bin` config option, defaults to `"pi"`) exists and is in `$PATH`.
- Neovim is at version 0.10 or newer.

Run it any time you suspect something is off with the install:

```vim
:checkhealth pi
```

If the executable isn't found, either install pi or set `bin = "/absolute/path/to/pi"` in `setup()`.

#### RPC debug logging

pi.nvim communicates with the backend over a JSONL RPC protocol on the pi process's stdin/stdout. When that conversation goes wrong, the best diagnostic is a transcript of the protocol traffic.

There are two ways to enable it:

- **Statically**, from the start of every session: `debug = true` in `setup()`.
- **At runtime**, toggled on/off without restarting anything: `:PiToggleDebug` / `pi.toggle_debug()`. This override is in-memory only and lasts for the current Neovim session; restart clears it back to whatever `setup()` said.

Logs are written to:

```
<stdpath("log")>/pi/<cwd-slug>/rpc.log
```

where `<cwd-slug>` is the current working directory with `/` replaced by `--`. On a typical Linux setup that's something like `~/.local/state/nvim/log/pi/Users--you--Dev--myproject/rpc.log`. The log is **reset** every time debug is enabled, so each session starts with a clean transcript.

The log contains every RPC command pi.nvim sends and every event it receives, including any unhandled event types (useful when the pi protocol evolves and pi.nvim hasn't caught up yet). Tailing the file in another terminal while reproducing the bug is usually the fastest way to pinpoint where things diverge:

```sh
tail -f ~/.local/state/nvim/log/pi/*/rpc.log
```

When filing an issue, attaching the relevant section of `rpc.log` is by far the most useful thing you can include.

#### Process lifecycle

Each π session owns an underlying `pi --mode rpc` subprocess. One tab = one session = one process. The lifecycle is:

- **Spawned** lazily, the first time you open the chat in a tab (via `:Pi`, `:PiContinue`, `:PiResume`, `pi.toggle()`, etc.). There is no background daemon; nothing runs until you ask for it.
- **Alive** as long as the tab is alive. Hiding the chat (`:PiToggleChat`) or switching away from the tab does **not** stop the process — the session keeps running in the background, and any queued [attention](#attention--dialogs) requests keep being tracked.
- **Torn down** on `TabClosed` for the owning tab, or on `VimLeavePre` for all sessions at once. pi.nvim sends the appropriate shutdown, waits briefly, and lets the child exit cleanly.
- **Stopped explicitly** via `:PiStop` / `pi.stop()` — kills the RPC process for the current tab's session immediately and closes the chat windows. Use this when you want to reclaim resources without closing the tab, or to force a clean restart (a subsequent `:Pi` will spawn a fresh process).
- **Aborted** via `:PiAbort` / `pi.abort()` — cancels whatever the agent is currently doing mid-turn but keeps the session and process alive, so you can immediately send a new prompt. Different from `:PiStop`: abort stops the _agent_, stop kills the _process_.

#### What to check when something's wrong

A rough triage checklist for common symptoms:

| Symptom | First thing to check |
| --- | --- |
| `:Pi` does nothing / reports no executable | `:checkhealth pi` — is `bin` resolvable? |
| Chat opens but never gets a response | Enable debug logging and watch `rpc.log` — are commands going out? Are events coming back? |
| Diff review doesn't open on edit/write | Is a permission extension loaded? See [Diff review](#diff-review). |
| Extension UI request ignored | Check the extension's `widgetKey` / method — is it something pi.nvim knows how to route? See [Extensions & custom rendering](#extensions--custom-rendering). |
| Slash command not highlighted | The command cache may not be populated yet (fetched on first chat open, refreshed every 30 seconds). |
| Session doesn't continue with `:PiContinue` | Are you in the same cwd as when the session was started? Sessions are cwd-scoped — see [Sessions](#sessions). |
| Statusline component shows stale data | The statusline is pushed from RPC events; if they stopped flowing, `rpc.log` will show the gap. |
| Unhandled event warning | pi.nvim doesn't yet know about a new event type the backend is sending. Please [open an issue](https://github.com/alex35mil/pi.nvim/issues) with the event name and a snippet of `rpc.log`. |

## Commands

| Command | Description |
| --- | --- |
| `:Pi [layout=side\|float]` | Open or toggle the chat in the current tab |
| `:PiContinue [layout=side\|float]` | Continue the most recent session for the current working directory |
| `:PiResume [layout=side\|float]` | Pick and resume a past session for the current working directory |
| `:PiToggleChat` | Toggle chat visibility |
| `:PiToggleLayout` | Switch between side and float layout |
| `:PiAbort` | Abort the current agent operation |
| `:PiStop` | Stop the RPC process and close the chat |
| `:PiAttention` | Open the next queued attention request |
| `:PiNewSession` | Start a new conversation in the current tab/session |
| `:PiToggleStartupDetails` | Toggle the startup block between compact and expanded |
| `:PiToggleThinking` | Show or hide thinking blocks |
| `:PiCycleThinking` | Cycle to the next thinking level |
| `:PiSelectThinking` | Pick a thinking level |
| `:PiCycleModel` | Cycle the current model |
| `:PiSelectModel` | Pick from configured models, or all models if none are configured |
| `:PiSelectModelAll` | Pick from all available models |
| `:PiSendMention` | Mention the current file; in visual mode or with a range, mention the selection lines |
| `:PiAttachImage {path}` | Attach an image file to the prompt |
| `:PiPasteImage` | Attach an image from the clipboard |
| `:PiCompact [instructions]` | Ask π to compact the current conversation context |
| `:PiSessionName [name]` | Set or show the session display name |
| `:PiToggleDebug` | Toggle RPC debug logging |

## API

Everything exposed by the user commands is also available from Lua. Grab the module once and call into it directly:

```lua
local pi = require("pi")

-- Setup (called once from your config entrypoint)
pi.setup(opts?)

-- Chat lifecycle
pi.show(opts?)                -- open the chat; opts: { layout = "side"|"float" }
pi.toggle(opts?)              -- open or hide the chat
pi.toggle_chat()              -- hide/show the chat windows for the current tab
pi.toggle_layout(cb?)         -- swap side ↔ float; cb runs after the swap completes
pi.is_visible()               -- boolean: is the chat shown in the current tab?
pi.layout()                   -- "side" | "float" | nil

-- Sessions
pi.continue_session(opts?)    -- load the most recent session for the current cwd
pi.resume_session(opts?)      -- pick a past session for the current cwd
pi.new_session()              -- start a fresh conversation in the current tab
pi.set_session_name(name?)    -- set the session display name; without an arg, opens a dialog
pi.compact(instructions?)     -- manually compact the current session (optional guidance)
pi.changed_files()            -- string[]: files modified by edit/write tools this session

-- Agent control
pi.abort()                    -- cancel the current agent turn, keep the session alive
pi.stop()                     -- kill the RPC process and close the chat for the current tab

-- Prompt input
pi.send_mention(args?, opts?) -- insert an @-mention for the current buffer / selection
pi.attach_image(path)         -- queue an image file as an attachment
pi.paste_image()              -- queue an image from the clipboard (requires img-clip.nvim)
pi.invoke("/command")         -- invoke a backend slash command programmatically

-- Models
pi.cycle_model()              -- step to the next model in the configured (or all) list
pi.select_model()             -- dialog: pick from configured models (or all when no list is set)
pi.select_model_all()         -- dialog: pick from every backend-available model

-- Thinking
pi.toggle_thinking()          -- show/hide thinking blocks in the history
pi.cycle_thinking_level()     -- step to the next thinking level
pi.select_thinking_level()    -- dialog: pick a thinking level

-- Startup block
pi.toggle_startup_details()   -- collapse/expand the startup block

-- Attention queue
pi.attention()                -- open the oldest queued request, switching tab if needed
pi.attention_count(tab?)      -- integer: pending requests in a tab (current tab if omitted)
pi.attention_total()          -- integer: pending requests across all tabs
pi.attention_state(tab?)      -- full state snapshot for custom UI
pi.has_attention(tab?)        -- boolean shortcut for attention_count > 0

-- Navigation inside the chat
pi.focus_chat_history()
pi.focus_chat_prompt()
pi.focus_chat_attachments()
pi.scroll_chat_history(direction, lines?)          -- direction: "up" | "down"; lines defaults to 15
pi.scroll_chat_history_to_bottom()
pi.scroll_chat_history_to_last_agent_response()

-- Debug
pi.toggle_debug()             -- toggle RPC debug logging for the current Neovim session
```

## Highlight groups

All highlight groups are defined with `default = true`, so they can be overridden by your colorscheme or by a later `vim.api.nvim_set_hl` call. Most groups are computed from your base colorscheme at load time (pulling from `Normal`, `Title`, `Function`, `Comment`, `WarningMsg`, `DiagnosticError`), rather than linking directly to another group. Run `:hi PiGroupName` at any time to see the current value.

### Chat history

| Group | Role |
| --- | --- |
| `PiUserMessageLabel` | Inline label in front of a user message |
| `PiAgentResponseLabel` | Inline label in front of an agent response |
| `PiDebugLabel` | Inline label for debug entries |
| `PiStartupLabel` | Inline label for the startup block |
| `PiStartupErrorLabel` | Inline label for startup errors |
| `PiStartupHint` | Hint text inside the startup block |
| `PiStartupDetail` | Detail lines inside the startup block |
| `PiStartupError` | Error lines inside the startup block |
| `PiMessageDateTime` | Timestamp next to messages |
| `PiMessageQueueTag` | Queue tag (steer / follow-up) next to queued messages |
| `PiMessageAttachments` | Attachment summary under a message |
| `PiPendingQueueLabel` | Label for the pending queue area below the prompt |
| `PiPendingQueueText` | Text of pending queued messages |
| `PiThinking` | Thinking block body |
| `PiMention` | Highlighted `@mention` in the prompt and history |
| `PiCommand` | Highlighted `/command` on the first line of the prompt |
| `PiWelcome` | Welcome text on an empty chat |
| `PiWelcomeHint` | Hint text under the welcome |
| `PiBusy` | "Agent is working" status text |
| `PiBusyTime` | Elapsed time counter next to the busy status |
| `PiWarning` | Inline warning lines |
| `PiError` | Inline error lines |
| `PiDebug` | Inline debug lines |

### Tool blocks

| Group | Role |
| --- | --- |
| `PiToolBorder` | Tool block border glyphs (`╭─`, `│`, `├────`, `╰─`) |
| `PiToolHeader` | Tool block header row (tool name) |
| `PiToolCall` | Tool input / call summary |
| `PiToolOutput` | Tool output body |
| `PiToolStatus` | Tool status line (completed / rejected / aborted) |
| `PiToolCollapsed` | `+N lines` / `…N lines` markers on collapsed blocks |
| `PiToolError` | Tool error output |
| `PiTableBorder` | Table border inside tool output |
| `PiTableHeader` | Table header row inside tool output |
| `PiDiffAdd` | Added lines inside inline tool diffs (links to `DiffAdd`) |
| `PiDiffDelete` | Removed lines inside inline tool diffs (links to `DiffDelete`) |
| `PiDiffLineNr` | Line numbers inside inline tool diffs |

### Attachments

| Group | Role |
| --- | --- |
| `PiAttachmentIcon` | Icon prefix in the attachments buffer |
| `PiAttachmentFilename` | Filename text in the attachments buffer |

### Panels and layout

| Group | Role |
| --- | --- |
| `PiFloat` | `NormalFloat` for π float windows |
| `PiFloatBorder` | Border for π float windows |
| `PiChatHistoryWinbar` | Winbar background for the history panel (side layout) |
| `PiChatHistoryWinbarTitle` | Winbar title for the history panel (side layout) |
| `PiChatPromptWinbar` | Winbar background for the prompt panel (side layout) |
| `PiChatPromptWinbarTitle` | Winbar title for the prompt panel (side layout) |
| `PiChatPromptWinbarAttentionTitle` | Winbar title for the prompt panel when attention is pending |
| `PiChatAttachmentsWinbar` | Winbar background for the attachments panel (side layout) |
| `PiChatAttachmentsWinbarTitle` | Winbar title for the attachments panel (side layout) |
| `PiChatHistoryFloatTitle` | Float title for the history panel (float layout) |
| `PiChatPromptFloatTitle` | Float title for the prompt panel (float layout) |
| `PiChatPromptFloatAttentionTitle` | Float title for the prompt panel when attention is pending |
| `PiChatAttachmentsFloatTitle` | Float title for the attachments panel (float layout) |

### Zen mode

| Group | Role |
| --- | --- |
| `PiZen` | Background of the centered zen prompt window |
| `PiZenBackdrop` | Background of the dimmed zen backdrop |

### Dialogs

| Group | Role |
| --- | --- |
| `PiDialogTitle` | Dialog title bar |
| `PiDialogSelected` | Selected item in a select dialog (links to `Visual`) |

### Diff review

| Group | Role |
| --- | --- |
| `PiDiffWinbar` | Winbar background for the diff review tab |
| `PiDiffWinbarCurrent` | `CURRENT:` label on the left pane winbar |
| `PiDiffWinbarProposed` | `PROPOSED:` label on the right pane winbar |
| `PiDiffWinbarHint` | Key hint text (`[<Leader>da=accept ...]`) on the winbar |

### Statusline

| Group | Role |
| --- | --- |
| `PiStatusLine` | Default highlight for statusline chunks |
| `PiStatusLineAttention` | Attention component highlight |
| `PiStatusLineWarning` | `warn`-threshold highlight for `context` / `cost` components |
| `PiStatusLineError` | `error`-threshold highlight for `context` / `cost` components |

---

Phew! That's a long one. I prolly should make a site or something.
