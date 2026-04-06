# pi.nvim — Agent Guidelines

Neovim plugin (Lua) — a frontend for the [pi coding agent](https://github.com/badlogic/pi-mono). Provides a chat UI, diff review, session management, and extension handling inside Neovim.

## Working Principles

- Be concise. Prefer small, targeted edits over full-file rewrites.
- Ask before broad, multi-file, or potentially destructive changes. State assumptions and tradeoffs briefly when they matter.
- Match the existing style and conventions of the file/project. Don't reformat unrelated code and avoid unrelated cleanup.
- Treat `lua/` as the source of truth; `README.md` is user-facing documentation, not authority over behavior.
- If public API, commands, keymaps, config defaults, or other user-visible behavior change, update `README.md` in the same change.
- Re-read a file immediately before editing it. Never rely on content from an earlier read — it may be stale.
- Handle errors explicitly. Don't swallow them or mask them with odd defaults. Use `pcall` for Neovim API calls that may fail (invalid windows/buffers) and `Notify.error/warn/info` for user-facing messages.

## Architecture

```
lua/pi/
├── init.lua              -- public API
├── config.lua            -- configuration
├── commands.lua          -- :Pi* user commands
├── rpc.lua               -- JSON-RPC over stdin/stdout to `pi --mode rpc`
├── filetypes.lua         -- pi filetype constants
├── health.lua            -- :checkhealth pi
├── notify.lua            -- vim.notify wrappers
├── keys.lua              -- shared key-binding utilities (pi.KeySpec)
├── models.lua            -- model selection: cycle, pick, resolve entries
├── thinking.lua          -- thinking visibility + level controls
├── attention.lua         -- pending attention state for blocking extension UI
├── startup.lua           -- startup block data (commands, extension widgets)
├── cache/
│   ├── files.lua         -- project file listing & cache
│   └── commands.lua      -- slash-command cache from RPC
├── sessions/
│   ├── manager.lua       -- session lifecycle, central event dispatcher
│   └── history.lua       -- session file parsing for resume
├── completion/
│   ├── init.lua          -- shared fuzzy-match logic
│   ├── blink.lua         -- blink.cmp source for @-mentions and commands
│   └── omnifunc.lua      -- built-in completefunc fallback
└── ui/
    ├── highlights.lua    -- highlight groups
    ├── diff.lua          -- pre-execution diff review (edit/write tools)
    ├── dialog.lua        -- floating select/confirm/input dialogs
    ├── extension.lua     -- extension_ui_request handler
    ├── winfix.lua        -- window option isolation for plugin windows
    └── chat/
        ├── init.lua        -- Chat class, orchestrates chat layout
        ├── layout.lua      -- window management (side panel / float stack)
        ├── history.lua     -- ChatHistory: message rendering, spinners, tool blocks
        ├── prompt.lua      -- prompt input buffer
        ├── attachments.lua -- image attachment management
        ├── mentions.lua    -- @-mention parsing, highlighting, expansion
        ├── decorators.lua  -- prompt buffer @-mention / /command highlighting
        ├── statusline.lua  -- configurable status line at prompt bottom
        ├── tools.lua       -- tool renderers + collapsed/expanded views
        └── zen.lua         -- full-screen overlay with centered prompt
```

## Key Patterns

### Event Flow
`rpc.lua` dispatches raw JSON events → `sessions/manager.lua:handle_event()` routes them → `Chat` → `ChatHistory` renders into the buffer. All UI mutations go through `vim.schedule()`.

### Buffer Modifications
History buffer is `modifiable=false` by default. All writes go through `History:_with_modifiable(fn)` which toggles modifiable, runs `fn`, then restores it.

### Extmarks
Extmarks (namespace `pi-chat`) are used extensively for: tool block borders (virtual text), highlighting, status spinners, thinking block anchors, and tool block expand/collapse range tracking. When replacing lines, extmarks must be captured before and restored after (`capture_extmarks` / `restore_extmarks` in history.lua).

### Tool Renderers
Each tool has a renderer in `tools.lua` (`pi.ToolRenderer`). Renderers define `on_start`/`on_end` for content, plus `input_visible`/`output_visible` thresholds for auto-collapse. Inline tools (like `read`) render as a single line. Custom renderers can be added to the `renderers` table.

### Layout Modes
Side layout uses `vsplit`/`split`. Float layout uses `nvim_open_win` with a stacked vertical arrangement (history float → prompt float → attachments float). Both are managed by `layout.lua` and share the same buffer instances.

### Session Per Tab
Each Neovim tabpage gets at most one session (`sessions[tab]`). Session owns an `Rpc` instance and a `Chat` instance. Cleanup happens on `TabClosed` and `VimLeavePre`.

## Reference Implementation

Before implementing a new feature, always consult the pi TUI interactive mode source first. The TUI is the reference frontend. Study how it handles the same feature (event flow, state tracking, edge cases) and mirror the approach, adapting for Neovim's buffer/extmark model.

Key source files (under `$(npm root -g)/@mariozechner/pi-coding-agent/`):
- `dist/modes/interactive/interactive-mode.js` — TUI frontend
- `dist/core/agent-session.js` / `agent-session.d.ts` — session layer shared by all frontends
- `dist/modes/rpc/rpc-types.d.ts` — RPC protocol types
- `docs/rpc.md` — RPC protocol documentation

## Conventions

- **Type annotations**: use `---@class`, `---@param`, `---@return`, `---@type`, `---@alias` (LuaLS/EmmyLua style) on all public and internal functions and fields.
- **Module pattern**: each file returns a single table/class. Classes use `setmetatable({}, Class)` with `Class.__index = Class`.
- **Private fields/methods**: prefixed with `_` (e.g., `self._buf`, `History:_append_lines`).
- **Scheduling**: any code touching Neovim UI from an RPC callback must be wrapped in `vim.schedule()`.
- **Config access**: always go through `require("pi.config").options`, never cache config values at module load time.
- **No globals**: all state lives in module-level locals or class fields.
- **Formatting**: use stylua defaults (4-space indent for Lua).

## Verification

- There is no automated test suite in this repo (yet). Verify changes by exercising the affected code path in headless Neovim where practical.
- Reading files or reviewing diffs is not verification.
- If a change can only be checked through interactive UI behavior, say so clearly instead of claiming success.
- In the final report, state exactly what was verified and what could not be verified in this environment.
