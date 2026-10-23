# Plan

## Overview

Keep Markdown fences in one chat message or tool preview from turning later messages into code. The existing automatic closing behavior is retained, but one shared helper decides whether a fence actually crosses the rendered boundary.

### Plan highlights

- Share boundary protection across user messages, assistant completion, live/final tool output, and collapsed tool previews.
- Protect the actual preview after selecting and shortening its lines, including cached re-collapse.
- Match Markdown's delimiter and container rules using its existing optional parser; keep plain-text chat operational without that parser.
- Add runnable headless regressions that inspect Markdown syntax, not just delimiter counts.

## Root cause

### Symptom

A tool prints a fenced block containing six numbered lines. Its collapsed preview keeps the closing fence but drops the opener. The remaining fence becomes an opener, making subsequent assistant prose render as code. Expanding the tool restores normal formatting; re-collapse brings the bug back.

### Evidence

- A headless Neovim 0.12.0 reproduction on current code exercises real `ChatHistory` tool start/end, automatic collapse, expansion, and re-collapse. For both bash and the current dedicated codemode renderer, following prose is parsed inside `fenced_code_block` when collapsed and re-collapsed, but as a paragraph when expanded.
- Four independent closing checks exist: user messages, assistant completion, live tool output, and final tool output. Ordinary unclosed triple-backtick blocks are protected in all four. Unclosed four-backtick blocks, tilde blocks, and longer blocks containing shorter literal fences leak in all four.
- Syntax probes show that shorter/different delimiters and delimiters with trailing text do not close an active fence. Quotes, lists, indented code, and HTML blocks also affect whether a fence can reach later prose.
- A private boundary-analysis prototype passes 14 parser-backed fixtures covering these cases. This establishes the proposed algorithm, not a delivered fix.
- Pi's reference TUI renders fallback tool output as separate plain-text components. Neovim instead places messages and tool output in a shared Markdown buffer, so its adaptation must isolate syntax at rendered boundaries.

### Cause

`tools.lua:build_collapsed_view` selects an input head and output tail and truncates line width without rechecking Markdown boundaries. `History:_maybe_collapse_tool` caches that unsafe preview. The existing closing checks elsewhere count triple-backtick lines and append exactly three backticks; counting does not establish the Markdown parser's actual fence state.

This failure is deterministic during ordinary tool output and message rendering, not a race. Fixing the shared boundary operation costs less than maintaining separate incomplete checks or tool-specific workarounds.

## Proposed fix

### Shared boundary helper

Add `lua/pi/ui/chat/fences.lua` with one internal operation that takes the exact rendered source and returns the matching closing delimiter when following prose would otherwise remain inside a fenced code block.

Use the same optional `markdown` Tree-sitter parser used for history highlighting. Analyze the source with a private blank-line/prose suffix, locate that suffix by position, and inspect its syntax ancestors. When it is inside a fenced block, extract and normalize that block's opening delimiter to obtain a valid matching closer. The analysis suffix is never inserted into the chat or session data. Keep analysis scoped to the supplied message or preview, not unrelated transcript content.

This uses the parser's existing rules for backticks, tildes, delimiter lengths, indentation, quotes/lists, and literal HTML instead of introducing a separate Markdown grammar. Missing optional parser support leaves plain-text chat operational without syntax-dependent closing. Distinguish that expected absence from unexpected analysis failures; handle failures explicitly rather than substitute a guessed delimiter. Use APIs available in the supported Neovim 0.10 baseline.

### Boundary decision table

| Rendered source / environment | Action |
| --- | --- |
| Following prose parses inside a fenced block | Append that block's matching closer before later content. |
| Balanced source, ordinary text, or container/literal context that does not engulf later prose | Leave source unchanged. |
| Preview selection or width shortening changes the source | Analyze the final preview, not the original full output. |
| Assistant text arrives in split deltas | Rejoin only assistant text and analyze it at completion, preserving the current streaming boundary. |
| Markdown parser is unavailable | Keep chat operational as plain text; do not require installing a parser. |

### Consumers and preservation

- `lua/pi/ui/chat/tools.lua`: replace final-output parity counting with the helper. In `build_collapsed_view`, analyze the complete constructed preview after all line/width truncation, and append an untruncated synthetic closer when needed. Keep the lines/specs arrays aligned and render the synthetic row with existing tool styling. Preserve tool borders and the existing expanded-output auto-closed annotation, positioning it using the actual closer length rather than a fixed three-byte offset.
- `lua/pi/ui/chat/history.lua`: replace the user-message, assistant-completion, and live-output closing checks with direct helper use. Preserve assistant-only source accumulation so tool output cannot close an assistant fence, and preserve handling of delimiters split across streamed chunks.
- Keep current preview thresholds, input-head/output-tail selection, line-count summaries, hidden-output behavior, tool status resolution, and source/session data unchanged. A synthetic closing row is boundary protection, not additional source output.
- Keep expanded snapshots and extmarks intact. Cached collapsed content must already be protected so expansion and re-collapse need no new syntax workaround.
- Preserve the table formatter's existing behavior. This change unifies automatic boundary closing; it does not replace Markdown table rendering or change its parser-free operation.
- Record the bug fix in `CHANGELOG.md`. Keep README requirements accurate about optional Markdown highlighting; update user-facing text only where the delivered behavior changes a documented workflow or limitation. No new public API, configuration, or highlight group is planned.

## Verify

Add a standalone headless Lua regression entry point under `tests/`, runnable with `nvim --headless -u NONE -l tests/fences.lua`, without a test-framework dependency.

1. Exercise the shared helper with parser-backed assertions for ordinary/balanced text; unclosed backtick and tilde blocks; longer delimiters containing shorter or different fence-like lines; valid longer closers; invalid closers with trailing text; up-to-three-space indentation; four-space indented code; quote/list boundaries; and HTML literal fence content. Verify safe input is unchanged and applying protection twice does not append a second closer.
2. Reproduce the issue through real `ChatHistory` calls for bash, codemode, and the generic renderer. Append a real assistant message; inspect its Markdown syntax after initial collapse, expansion, and re-collapse. Test with following prose already present when toggling, not only before appending it. Confirm fences cannot absorb the next message.
3. Cover preview width shortening, a fence retained in input, hidden output, balanced/full output, line/spec alignment, source-line summaries, and exact expanded-content restoration. Verify synthetic closers are not themselves width-truncated and tool borders/highlights remain attached.
4. Exercise user messages, split assistant deltas, partial tool results replaced by final results, and assistant completion after intervening tool output. Assert message boundaries stay safe without borrowing delimiter state from another content source. Preserve ordinary table rendering and tables inside existing supported fenced examples.
5. Exercise the supported parser-unavailable path in isolation: no hard dependency or rendering failure, no injected analysis text, and plain tool/message rendering still works. Unexpected parser errors must not silently produce a guessed closer.
6. Run Lua syntax/loading checks, `stylua --check` on changed/new Lua files, and `git diff --check`. Limit formatting to touched code.

The local environment has Neovim 0.12.0 with a bundled Markdown parser. Report the Neovim versions actually exercised; do not claim runtime verification on 0.10 without running it. Headless syntax and buffer/extmark checks do not establish visual quality in interactive side, float, or zen layouts; report unrun visual checks explicitly.
