# Changelog

## 2026-06-21

- **ADDED:** Add RPC adapter hooks for user-land command/event mapping of non-upstream-compatible backends.
- **ADDED:** Add configurable diff review keymap hints with `?` help, winbar hints, and disabled mode.
- **FIXED:** Restore diff review buffer-local keymaps after accept, reject, timeout, or manual tab close.

## 2026-06-18

- **BREAKING:** Change diff review note payloads to use `lineStart`, `lineEnd`, and `lines` instead of `line` and `lineText`.
- **ADDED:** Add range-based diff review notes with visual-line selection, wrapped note text, overlap handling, and multiline note input.
- **CHANGED:** Wrap markdown diff review panes for readability while preserving global wrapping defaults for other filetypes.
- **FIXED:** Keep the chat spinner visible when an automatic retry resumes agent work.

## 2026-06-17

- **ADDED:** Add `pi.scroll_chat_history_to_first_agent_response()` to jump to the first assistant response in the latest user turn.
- **ADDED:** Render live tool progress updates inside chat history tool blocks.
- **CHANGED:** Make `pi.scroll_chat_history_to_last_agent_response()` target the last assistant response in the latest user turn.
- **FIXED:** Give each assistant text message its own chat history response header while suppressing empty tool-only headers.
- **FIXED:** Prevent tool output containing NUL bytes from crashing collapsed history rendering.

## 2026-06-16

- **ADDED:** Add line-level notes to diff review, including note keymaps, configurable note icon, and note-aware review responses.
- **ADDED:** Add `pi.toggle_history_blocks()` to expand/collapse all expandable history blocks.

## 2026-06-15

- **BREAKING:** Replace `setup({ bin = "pi" })` with `setup({ cli = { bin = "pi", args = {} } })`.
- **ADDED:** Add `cli.args` for extra pi RPC startup arguments.
- **ADDED:** Render compaction summaries after successful compaction.
- **ADDED:** Queue message submits while compaction is running.
- **FIXED:** Handle current `compaction_start`/`compaction_end` RPC events.
- **FIXED:** Preserve message ordering and queued output during compaction replay.
- **FIXED:** Keep agent markdown fence auto-closing isolated from tool output.
