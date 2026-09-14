# Changelog

## 2026-10-17

- **FIXED:** Validate diff reviews against disk content, reject ambiguous or unchanged edits, preserve line endings and empty files, and keep the review open when writing fails.

## 2026-09-14

- **ADDED:** Keep agent activity and steering, follow-up, and abort hints visible in the prompt statusline.
- **ADDED:** Keep pending steering and follow-up counts visible until Pi consumes the queued messages.
- **ADDED:** Bind `<C-c>` in the prompt to abort the active turn while preserving the session.
- **ADDED:** Add `:PiClear`, `/clear`, and Neovim-native slash actions for common Pi TUI workflows.
- **ADDED:** Add native `nvim-cmp` completion for `@` file mentions and `/` commands.
- **FIXED:** Show `Starting…` immediately after submitting a prompt instead of waiting for the first agent event.
- **FIXED:** Clear the immediate activity state when Pi rejects a prompt before the agent starts.
- **FIXED:** Keep the agent busy through retries, compaction, and queued continuations until Pi emits its authoritative settled event.
- **FIXED:** Reconcile pending messages from Pi queue snapshots and restore rejected or interrupted input instead of losing it.
- **FIXED:** Reset activity and queue state on chat clear or process exit, with an actionable error when Pi exits unexpectedly.
- **FIXED:** Reject multiline local slash actions without discarding the remaining prompt text.
- **CHANGED:** Require Pi 0.80.4 or newer for the authoritative `agent_settled` lifecycle event; validated through Pi 0.85.1.
- **CHANGED:** Use Pi's light/dark semantic colors for foreground accents while preserving the existing Neovim chat background.
- **CHANGED:** Keep the animated agent verb in chat history only; the prompt statusline now shows controls and queued-message counts without repeating it.
- **FIXED:** Apply highlight defaults immediately when pi.nvim is lazy-loaded and start Markdown Tree-sitter highlighting for chat history buffers.

## 2026-07-08

- **FIXED:** Show the assistant header before tool-only turns so tool calls do not appear under the user message.

## 2026-07-04
- **FIXED:** Make chat timestamp format configurable with `timestamp_format` option and use a platform-specific default to avoid the GNU `%-d` flag on Windows.
- **FIXED:** Use cross-platform path joining for session directories and file globbing (Windows compatibility).

## 2026-07-03

- **ADDED:** Add RPC adapter hooks for user-land command/event mapping of non-upstream-compatible backends.
- **FIXED:** Reject failed multi-edit diff reviews instead of opening an empty diff.
- **FIXED:** Suppress debug warnings for known redundant session state events.

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
