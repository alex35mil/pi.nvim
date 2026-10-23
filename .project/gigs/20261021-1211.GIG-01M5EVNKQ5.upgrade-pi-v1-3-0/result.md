# Result

## Overview

pi.nvim now uses the pi v1.3.0 RPC contract for prompt outcomes, model-supported thinking levels, lifecycle events, session accounting, and nested tools. Codemode progress renders inside its parent block, and the documented permission bridge returns successful results for edits already applied by Neovim.

The minimum and validated backend versions are 1.3.0. The migration directly uses APIs missing from previously supported releases: an isolated v0.80.5 subprocess rejected the thinking-level query and returned prompt responses without dispositions. This applies the requested compatibility rule rather than selecting an intermediate API-introduction version.

Widget callbacks and session-tree UI remain unchanged. The new entry-rendering API and tree navigation are separate work. Verification used isolated synthetic providers and sessions on macOS; real-provider behavior and interactive visual presentation were not checked.

## Implementation walkthrough

- **Prompt ownership:** successful submissions use `started`, `queued`, or `handled` directly. The old post-acceptance activity query is gone. Compaction handoffs retain steering/follow-up modes, independent running commands do not force the session idle, and rejected or unacknowledged input retains attachment recovery.
- **Thinking:** the picker asks the backend for the model's supported list, including `max` and off-only models. Backend failures are visible rather than replaced by a universal list. Extension-driven thinking and session-name events refresh state.
- **Accounting:** the statusline replaces its accounting state with `get_session_stats` snapshots. Full-session billing includes tool/model calls, compaction, summaries, and cache warming; current context usage remains separate and can be unknown after compaction. Replay no longer builds a partial assistant-only ledger.
- **Lifecycle:** native compaction and summarization-retry events drive the existing status/error surfaces. The backend's settled `aborted` outcome is consumed. Boundary compaction entries rebuild the current context, and usage/context-edit entries refresh accounting.
- **Tools:** nested execution events retain file-mutation tracking without creating independent transcript blocks. Codemode has a renderer for script input, structured call progress, durations, errors, and final output, reusing existing collapse and extmark machinery. Replay recovers successful nested edit/write paths from available bounded metadata; missing metadata is not fabricated.
- **Permission example:** built-in edit/write tool definitions are wrapped. Plain TUI approval delegates to the original implementation; Neovim acceptance returns a successful result without another write. Modified content and review notes remain visible to the agent. Direct and nested accepted edits were exercised against the published runtime.
- **Companion configuration:** Repository MCP settings move to `.agents/mcp.json` with the `mcpServers` root. Repository-specific permissions are preserved in Git-ignored `.agents/permissions.local.json`, and the old committed permissions file is removed. README command examples use `/permissions-*`, and the reference points to the renamed `extensions/permissions` directory.
- **Documentation:** README and changelog cover requirements, model-specific thinking, session-wide accounting, codemode behavior, and permission integration. Version-specific Azure/Kimi and permission-extension migration steps live in UPGRADING.md, linked from README; current pi/Node requirements remain in README. Reference links use the current alex35mil/pi-af repository name. Public commands, keybindings, layouts, statusline component fields, RPC adapter hooks, and widget behavior retain their purposes.

## Breaking-change audit

Reviewed the complete v0.79.3-to-v1.3.0 interval in the tagged [coding-agent](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/CHANGELOG.md), [pi-ai](https://github.com/earendil-works/pi/blob/v1.3.0/packages/ai/CHANGELOG.md), [agent-core](https://github.com/earendil-works/pi/blob/v1.3.0/packages/agent/CHANGELOG.md), and [pi-tui](https://github.com/earendil-works/pi/blob/v1.3.0/packages/tui/CHANGELOG.md) changelogs, including changes recorded outside Breaking Changes headings. Compared published RPC declarations and inspected the target runtime and TUI reference frontend.

| Boundary | Change | Consequence for pi.nvim |
| --- | --- | --- |
| 0.79.4–0.79.10 | Plain provider credential literals require explicit environment interpolation; self-only update semantics; compaction estimates and extension reason/retry metadata. | No plugin-managed credentials or update flow. Current compaction contracts are used. |
| 0.80.0 / pi-ai | Global helpers move to `/compat`; Provider becomes ProviderId; raw API modules move; old `/base` exports disappear. | Lua uses RPC rather than these imports. The updated TypeScript example compiles against the target exports. |
| 0.80.0–0.80.2 / agent-core | Harness model/auth and compaction signatures, credential discriminator, shell option types, and selective-provider entrypoints change. | No direct imports; these are not the coding-agent session-file interface. |
| 0.80.3–0.80.6 | Entries/tree reads, settled events, max thinking, reasoning usage. | Supported-level picker and settled lifecycle use the target contract. Reasoning is not counted again on top of output. Tree UI is deferred. |
| 0.80.7 | sendSessionIdHeader replaced by sessionAffinityFormat. | User-managed models configuration, not a plugin-generated field. |
| 0.80.8 | SDK ModelRuntime replaces AuthStorage/modelRegistry setup and old projections; provider-scoped authentication, login interaction, headers, and refresh APIs change. | No SDK/auth adapter is imported by Lua; backend owns model/auth resolution. |
| 0.81.0–0.81.1 | Supported-thinking RPC, complete session usage, summarization retries; harness storage, UUID and stream-function contracts change. | Picker, statistics and retry handling migrated. Harness-only TypeScript changes do not affect the subprocess frontend. |
| 0.82.0 | Catalog freshness API and context-aware harness tool contracts change. | No matching Lua imports. |
| 0.83.0 | Removed deprecated TypeBox APIs; pending streaming stop reason. | The permission example uses current types; partial assistant messages are not treated as final. |
| 0.84.0 / RPC | Cumulative message/partial snapshots removed from message_update; later releases retain cumulative usage and complete tool identity. | Existing delta rendering already avoids removed snapshots. Native annotations reflect the target wire format; framing and correlation are verified. |
| 0.84.0 / models, auth, harness | ModelsRequestTransforms rename; concrete cancellation signals and generation-checked catalog publication; lane-based experimental harness sessions replace old repositories. | No direct Lua migration. Coding-agent session files remain v3, not the experimental harness format. |
| 0.84.3–0.84.4 | Google thinking type rename; session-scoped model selection; compaction failure, UI-prompt and queue interfaces. | Backend remains owner of supported levels and selection. Existing abort and queue-restoration UX is preserved; no new queue-clearing action was added. |
| 0.85.0 | Cloudflare binding helper renamed; TUI environment/logging defaults removed. | No direct imports or pi-tui component rendering in Neovim. |
| 0.86.0 | TranscriptContext provider streams, JSON-only arguments/details, fail-closed user_bash; persisted system/tool changes and cache-warming usage. | JSON RPC remains the boundary. Bookkeeping messages are not rendered as conversation prose, and accounting is backend-authoritative. |
| 0.87.0 | ContextEditEntry; canonical SessionManager provider context; expanded boundaries; finishTurn replaces shouldStopAfterTurn; deferred settled-handler runs. | No direct agent-hook migration. The frontend consumes canonical messages and waits for session settlement. |
| 0.99.0 / RPC and tools | Prompt dispositions, parentToolCallId, bounded nested metadata, builtin source identifiers; no-extensions also disables built-ins. | Submission and nested-tool integrations migrated. Source metadata remains opaque, and existing CLI arguments are preserved. |
| 0.99.0 / pi-ai and pi-tui | Separate image collections removed into typed Models APIs; mixed catalog/schema changes; terminal color queries replaced. | No direct dependency on those APIs. Chat model selection remains the existing backend-provided surface. |
| 1.0.0–1.0.1 | Fullscreen TUI default; experimental agent-core harness removed in favor of pi-durable; npm shrinkwrap removed. | Neovim remains an RPC frontend, without a terminal renderer or experimental client dependency. |
| 1.0.3 | Azure provider renamed from azure-openai-responses to azure. | Provider IDs are passed through from the backend. UPGRADING.md describes the user-managed credentials/models/settings migration; credentials are not rewritten. |
| 1.1.0 | Settled aborted outcome; duration metadata; stricter stream return types and Terminal program-status contract. | Current outcome/metadata fields are represented. Neovim is not coupled to the terminal OSC interface. |
| 1.2.0 | before_agent_start messageType union and custom-message runs; startup counts busy; theme schemas, MCP resource reporting, cursor markers change; experimental server/client/plugin stack removed. | No corresponding hook, MCP-management, theme-component, or experimental-client imports in Lua. Existing lifecycle ownership and permission integration were verified. |
| 1.3.0 | Assistant message frames removed; Kimi Coding switches protocol and custom base URLs require /v1; cross-model thinking changes; resumed tools restored. | No frame/provider-wire adapter in Lua. UPGRADING.md describes the Kimi migration; model/session APIs were exercised on the target release. |

For future extension annotations, `pi.appendEntry(customType, data)` was verified to emit structured `entry_appended` records without entering model context. `pi.sendMessage()` instead emits custom-message events and contributes model context. For future tree work, an extension command's `ctx.navigateTree()` was verified to navigate in-place through RPC; there is still no native `navigate_tree` command in v1.3.0. Neither feature is implemented in this change.

## Verification

All final checks passed on Node.js 24.21.0 and Neovim 0.12.0 on macOS. Runtime packages and fixtures were isolated from personal agent configuration; no external model-provider calls were made.

- `node .project/gigs/20261021-1211.GIG-01M5EVNKQ5.upgrade-pi-v1-3-0/.local/scratch/verify-native.mjs` — passed target startup/command discovery, Unicode delta streaming, prompt outcomes, extension dialogs, direct/nested permission approval, actual codemode execution and stored metadata, steering/follow-up delivery, rejected busy input, provider retry, generated split-turn compaction and summary retry, aborted settlement, naming, new sessions and switch/resume. The v0.80.5 compatibility probe reproduced both missing APIs.
- `nvim --headless -u NONE -l .project/gigs/20261021-1211.GIG-01M5EVNKQ5.upgrade-pi-v1-3-0/.local/scratch/verify-plugin.lua` — passed supported/off-only thinking lists and errors, canonical accounting, prompt/compaction decision cases, rejected and unacknowledged input/attachment recovery, structured tool output and collapse/expansion, nested tracking/replay, extension-driven state changes, summary retry/abort routing, byte-chunked LF/CRLF framing, Unicode separators, event mapping and response correlation.
- `nvim --headless -u NONE -l .project/gigs/20261021-1211.GIG-01M5EVNKQ5.upgrade-pi-v1-3-0/.local/scratch/verify-e2e.lua` — passed actual Neovim-to-v1.3.0 subprocess chat, nested codemode rendering/file tracking, and generated compaction/retry rebuild with preserved billing and unknown context.
- `npm exec --yes --package typescript -- tsc --noEmit --strict --skipLibCheck --module nodenext --moduleResolution nodenext --target es2024 .project/gigs/20261021-1211.GIG-01M5EVNKQ5.upgrade-pi-v1-3-0/.local/scratch/runtime/check-permission.ts` — TypeScript 7.0.2 passed the README example against published v1.3.0 types.
- `stylua --check lua/pi/compat.lua lua/pi/rpc.lua lua/pi/thinking.lua lua/pi/sessions/manager.lua lua/pi/ui/chat/{init,statusline,tools,history}.lua` — passed.
- Headless `loadfile` checks over `lua/pi/**/*.lua` — passed.
- `node --input-type=module` (inline migration/documentation assertions) — passed migrated MCP JSON configuration, the byte-preserving local permission-policy move and its Git exclusion, current permissions command examples, README pi/Node requirements, all three upgrade-guide migration steps, relative links including the diff-review heading anchor, current pi-af links, and absence of old-name references in public docs. GitHub fetches confirmed the renamed repository and permissions/rules directories. The complete native, headless, end-to-end, TypeScript, formatting, and syntax verification set passed again with these companion migrations.

**Not run:**

- Exact v0.80.4 runtime check — the npm registry does not serve that version; the next published previously supported release, v0.80.5, was tested instead.
- External model providers, real credentials, and network authentication flows — verification used pi's synthetic provider and empty agent configuration.
- Interactive visual inspection of floats, scrolling, resizing, and attention/diff dialogs — this environment used headless Neovim; buffer content, extmarks and collapse behavior were exercised.
- Neovim 0.10, Linux and Windows execution — those runtimes/platforms were not available in this verification environment.
