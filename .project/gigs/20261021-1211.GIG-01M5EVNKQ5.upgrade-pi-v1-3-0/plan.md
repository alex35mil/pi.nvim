# Plan

## Overview

Bring pi.nvim's existing backend integration up to the published pi v1.3.0 API contract. Audit breaking changes since v0.79.3, update every affected existing integration rather than retaining outdated API paths, and verify normal chat, session, tool, extension-dialog, and statusline behavior against the target release.

### Plan highlights

- Use explicit prompt outcomes and model-supported thinking levels from v1.3.0.
- Reconcile session totals and context usage from the backend instead of reconstructing incomplete totals from assistant messages.
- Update event handling, nested-tool integration, protocol annotations, documentation, and compatibility declarations together.
- Target v1.3.0 without legacy compatibility branches. When the changes break earlier pi versions, set the minimum to exactly v1.3.0; otherwise preserve the earlier supported minimum.
- Keep the new entry-rendering API and session-tree feature in their separately queued Todos; retain current widget behavior in this upgrade.

## Scope and compatibility rule

This is a maintenance upgrade of existing capabilities, not merely a version-label change or a search for fatal incompatibilities. Adopt the current upstream APIs used to implement those capabilities. It does not add every upstream command as a new pi.nvim feature.

| Evidence after the API migration | Minimum supported version |
| --- | --- |
| The changed integration breaks a previously supported earlier pi version | 1.3.0 |
| The changed integration remains compatible with earlier supported pi versions | Retain the earlier supported minimum |

Do not substitute an intermediate minimum calculated from individual API introduction dates, add old-protocol branches, change the user's installed pi, or edit personal agent configuration. The current declared minimum is 0.80.4 and validation marker is 0.85.1. Direct use of model-supported thinking levels and explicit prompt outcomes introduces dependencies absent from the existing minimum; verify that boundary and apply the table. Update the validated marker to 1.3.0 only after actual target verification, recording remaining verification limits.

Public Lua functions, user commands, default keybindings, layouts, RPC adapter hooks, diff-review responses, and widget callbacks keep their existing purposes. `on_widget` deprecation/replacement and tree browsing/navigation are outside this Gig. Direct `abort` continues to abort without silently adding queue clearing or changing input-restoration behavior; `clear_queue` is a separate upstream capability, not a required new user action here.

## Evidence and upstream change inventory

Use the exact npm packages for v0.79.3 and v1.3.0, published target declarations and runtime, and tagged coding-agent, pi-ai, pi-agent-core, and pi-tui changelogs. Read release notes for the complete interval, including breaking changes recorded under Changed or Removed rather than only Breaking Changes headings. The source references below are version-pinned:

- https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/CHANGELOG.md
- https://github.com/earendil-works/pi/blob/v1.3.0/packages/ai/CHANGELOG.md
- https://github.com/earendil-works/pi/blob/v1.3.0/packages/agent/CHANGELOG.md
- https://github.com/earendil-works/pi/blob/v1.3.0/packages/tui/CHANGELOG.md
- https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/rpc.md
- https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/rpc-commands.md
- https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/json.md
- https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/rpc-extension-ui.md

Carry the complete inventory and capability mapping into the delivered result's supporting sections. Distinguish changes needing Lua implementation, already-compatible behavior, user-managed backend configuration, and APIs not imported by this subprocess frontend.

| Release / boundary | Change and pi.nvim consequence |
| --- | --- |
| 0.79.4–0.79.10 | Literal provider credentials now require explicit environment interpolation; `pi update` becomes self-only; compaction results gain estimates and extension compaction events gain reason/retry metadata. No plugin credential/update implementation to migrate. Check compaction against the current event contract. |
| 0.80.0 / pi-ai | Root global streaming/catalog helpers move to `/compat`; `Provider` becomes `ProviderId`; raw provider API modules move and old `/base` exports disappear. Lua uses JSON subprocess records, not these imports. Check the README extension example against current exported types. |
| 0.80.0–0.80.2 / agent-core | Harness model/auth and compaction signatures change; selective-provider exports disappear; credential and shell option types are renamed. Not the coding-agent JSONL session contract and not imported by pi.nvim. |
| 0.80.3–0.80.6 | RPC gains entries/tree reads, settled-run events, and max thinking; usage gains reasoning tokens. Preserve settled-run ownership and use backend-supported thinking levels. Do not count reasoning twice. Tree work remains separate. |
| 0.80.7 | OpenAI `sendSessionIdHeader` is replaced by `sessionAffinityFormat`. User-managed models configuration; no plugin-generated setting to migrate. |
| 0.80.8 / provider and SDK | ModelRuntime replaces SDK AuthStorage/modelRegistry setup and canonical model/auth/refresh projections. Provider-scoped auth, login interaction, model headers, and refresh APIs change. No Lua SDK dependency; do not build an unnecessary SDK adapter. |
| 0.81.0–0.81.1 | RPC gains `get_available_thinking_levels`; session statistics include tool/compaction/summary usage; summarization gets retry events. Upgrade existing picker, accounting, and compaction activity handling. Agent harness SessionStorage/UUID/stream-function changes do not apply to Lua. |
| 0.82.0 | Built-in catalog freshness API changes and harness tools become context-aware. No Lua consumers of these TypeScript APIs. |
| 0.83.0 | TypeBox removes deprecated APIs; streamed assistant messages gain pending stop reason. No removed TypeBox API in the README permission example; partial messages must not be treated as final. |
| 0.84.0 / RPC | `message_update` loses cumulative message/partial snapshots; later releases retain top-level cumulative usage and complete tool identity. Existing delta rendering already avoids removed snapshots. Align annotations and live/final consumption with the target wire contract. |
| 0.84.0 / models, auth, harness | ModelsStreamTransforms becomes ModelsRequestTransforms; refresh/auth cancellation and publication contracts change; experimental lane-based harness sessions replace old harness repositories. No Lua import migration; coding-agent sessions remain v3. |
| 0.84.3–0.84.4 | Google thinking types renamed; model selection becomes session-scoped; new compaction failure/prompt/queue interfaces appear. Respect backend model support; do not add default persistence. Keep queue restoration and abort UX scoped to existing behavior. |
| 0.85.0 / pi-ai and pi-tui | Cloudflare binding fetch helper renamed; TUI environment/logging defaults removed and debug variable renamed. No plugin rendering of pi-tui components; Neovim options remain independent. |
| 0.86.0 | Provider streams receive TranscriptContext; ToolCall arguments/details become JSON-only; user_bash fails closed; system prompt/tool changes and cache-warming usage become persisted transcript data. Lua continues JSON values, ignores non-display system bookkeeping, and uses authoritative session accounting. |
| 0.87.0 | ContextEditEntry added; SessionManager becomes canonical for finalized provider context; boundary events expand; shouldStopAfterTurn replaced by finishTurn; settled-handler runs defer. Consume current message/context and settled contracts without manipulating backend histories or implementing agent hooks. |
| 0.99.0 | Prompt/steer/follow_up responses gain dispositions; nested calls gain parentToolCallId and bounded result metadata; built-ins use builtin source identifiers; `--no-extensions` also disables built-ins. Upgrade existing submission and tool integrations; treat source metadata opaquely. Mixed image/classifier catalog/schema changes are not a new chat-model picker surface. |
| 0.99.0 / pi-ai and pi-tui | Separate image model collections disappear into typed Models APIs; terminal color-query APIs replaced. No direct Lua dependency on these collections or terminal queries. |
| 1.0.0–1.0.1 | TUI fullscreen becomes default; experimental agent-core harness is removed in favor of pi-durable; npm shrinkwrap removed. pi.nvim stays a Neovim RPC frontend, not a terminal emulator or durable-harness client. |
| 1.0.3 | Azure provider renamed to azure; credential/models/settings keys need user migration. Preserve opaque provider IDs returned by backend; document relevant upstream migration without rewriting credentials. |
| 1.1.0 | agent_settled gains aborted; tool/assistant duration metadata added; stream return types and TUI Terminal contract change. Update current event/message annotations and consume run outcome without coupling Neovim to OSC terminal reporting. |
| 1.2.0 | before_agent_start becomes a messageType union and covers custom-message runs; session busy includes startup; theme schema/validation changes; MCP resource reporting changes; TUI cursor markers change; unreleased server/client/plugin stack removed. No matching hooks, terminal component rendering, or experimental client dependencies in Lua. Preserve backend lifecycle ownership and validate the bundled permission example. |
| 1.3.0 | Assistant message frames removed; Kimi Coding switches protocol and requires /v1 in custom base URLs; model switching drops cross-model thinking; resumed tools restore correctly. No frame/protocol adapter in Lua; document backend migration concerns and verify model/session behavior using target APIs. |

## Protocol and event ownership

`lua/pi/rpc.lua` owns current command/event/message annotations and JSONL framing. Keep splitting only on LF and correlating responses by ID. Add the current commands actually used by this migration, fields such as prompt disposition, parentToolCallId, durationMs, usage, aborted, and summarization events; remove obsolete auto-compaction event aliases from the native contract. Preserve RPC map_command/map_event hooks as the explicit custom-backend boundary.

`lua/pi/sessions/manager.lua` owns event routing and backend reads. Continue treating `agent_end` as an intermediate boundary and `agent_settled` as final. Use `aborted` as the session-level cancellation outcome rather than assuming an assistant message always reports the final cancellation. Handle `thinking_level_changed` and `session_info_changed` as real state changes, including changes initiated by extensions. Retain deliberate ignoring only for events whose payload does not affect an existing feature.

Handle summarization retry scheduled/attempt/finished events through the existing status/error surface, restoring compaction or active-run status at the documented boundaries. Do not add retry polling or a second retry state machine. `entry_appended` updates accounting for usage or compaction entries; arbitrary extension-entry rendering stays deferred. Classify unsupported new feature events explicitly instead of issuing false debug warnings.

## Submission state migration

`Chat` owns local input, acceptance, compaction handoff, and canonical queue display. Replace the `_reconcile_prompt` activity-query workaround with the v1.3.0 response disposition. Do not make a global session idle merely because one extension command was handled.

| Result for the submitted input | Local ownership / activity / compaction handoff |
| --- | --- |
| Send failure or unsuccessful response | Preserve existing restoration of that submission and still-unsent compaction inputs. |
| prompt: started | Backend owns the accepted input; retain starting activity until run events take over. Release the matching compaction handoff and send remaining inputs with their steering/follow-up modes. |
| prompt: queued | Backend owns the queued input; canonical queue snapshots and run events own its display and activity. Release matching handoff and submit remaining buffered entries as queued inputs. |
| prompt: handled | Complete only this input's local handoff. Retain independent running/compacting activity; advance the next buffered prompt when no run is active, or queue it when one is active. |
| steer/follow_up: queued | Backend owns the input; queue_update and delivery events control display. |
| steer/follow_up: handled | Input was consumed by an extension; do not fabricate a queued message or wait for its delivery. |
| A callback arrives after events already resolved its handoff | Do not regress run/queue state or resolve another submission with the same text. |

Preserve attachment recovery and per-submission identity. No get_state fallback for old prompt responses.

## Thinking controls

`lua/pi/thinking.lua` must query `get_available_thinking_levels` for the current model rather than owning a global six-level list. Keep the current backend level selected, include max when returned, and offer only supported values, including an off-only list for a nonreasoning model. Do not pretend a failed state/levels request produced a valid choice list. Surface actual backend failures through Notify. Existing cycle and set operations remain backend-owned and session-scoped.

The published v1.3.0 probe returned low/high/max for a synthetic reasoning model, off for a nonreasoning model, and a thinking_level_changed event after an extension command changed the level. The current headless plugin picker omitted max and offered unsupported off. This is an existing-control contract correction, not a new feature.

## Session statistics and context usage

`lua/pi/ui/chat/statusline.lua` owns the displayed accounting state; give it an authoritative session-statistics update operation instead of treating assistant usage as complete session totals. `get_session_stats` supplies complete tokens, cost, and contextUsage. Separate accumulated session billing from current context-window estimates; preserve null/unknown post-compaction context and do not replace it with the summary's generation usage.

Update `Chat` and manager consumers coherently: initial state, completed assistant/tool-usage updates, usage/compaction entries, compaction rebuild, new/switch/resume, and final settlement refresh the relevant canonical statistics. Remove assistant-only replay accumulation and prevent nested usage from being counted both on children and their parent. Keep existing public statusline state fields, components, and custom component functions; values become backend-authoritative across compaction and resume.

The isolated target runtime reports 200 input tokens / $0.20 across assistant, tool, compaction, and cache-warming usage in the fixture, while the current assistant-only accounting sees 100 / $0.10. A separate headless check confirms that the current input<=0 guard drops valid cache-only usage. The common supported triggers are codemode model calls and ordinary compaction/cache warming, not an artificial race. One snapshot update at the owning accounting boundary is simpler than maintaining a second partial ledger.

## Nested and built-in tools

Upgrade nested-tool routing to recognize parentToolCallId. Follow the reference TUI: nested calls belong to their model-issued parent's presentation, not independent transcript tool rows. Keep edit/write changed-file tracking for successful nested calls even when their UI rows are not top-level. Preserve direct tool rendering, parallel call-ID correlation, error prefixes, and pre-execution review behavior.

Add a codemode renderer at the existing `pi.ToolRenderer` boundary in `lua/pi/ui/chat/tools.lua`. Render code input and the upstream details.calls list (tool names, argument previews, status, duration, and errors) during progress and from final stored results, alongside ordinary textual output. Reuse existing expand/collapse and tool-block/extmark machinery. The upstream codemode publisher emits empty content with details.calls while running, so a text-only fallback cannot show that progress. Do not execute returned JavaScript in Neovim, build a generic remote TUI renderer, or add new tool windows.

Use bounded nestedCalls metadata for successful edit/write tracking during replay where arguments are available; do not invent child results or missing paths when upstream truncates that metadata. Native get_session_stats remains the single billing source.

## Documentation and affected files

Expected product owners: `lua/pi/rpc.lua`, `lua/pi/thinking.lua`, `lua/pi/sessions/manager.lua`, `lua/pi/ui/chat/init.lua`, `lua/pi/ui/chat/statusline.lua`, `lua/pi/ui/chat/tools.lua`, and `lua/pi/compat.lua`. Modify adjacent history/rendering code only where required to consume the upgraded renderer coherently. Session JSONL listing and command/source caches need changes only for evidenced target-contract mismatches; preserve existing APIs otherwise.

Update README in the same change for compatibility requirements, model-specific thinking levels, authoritative statusline accounting, and meaningful nested-tool/compaction behavior or limitations. Link the current upstream RPC reference pages rather than dead detailed-page anchors where affected. Document relevant Azure/Kimi user configuration migration without inspecting or editing user credentials. Keep detailed audit evidence and verification in the completion artifact, not user documentation. Add release notes in CHANGELOG.

## Verification

Keep temporary fixtures, dependencies, and probes under this Gig's ignored local scratch directory. Use exact isolated pi packages with offline operation, synthetic credentials/model definitions, empty agent configuration, and synthetic session files. Do not call real providers or install globally without separate approval.

- Run target RPC integration checks for all existing command families: startup/state/commands, prompt acceptance and rejection, steer/follow-up queue handling, abort, thinking/model selection, session naming/new/switch/resume, compaction, extension dialogs, tool start/progress/end, and settled-run completion. Use a deterministic local provider or supported SDK fixtures for real run/tool/compaction sequences rather than claiming message injection alone tests model-driven chat.
- Run headless Neovim regressions at the owning boundaries: submission decision table with compaction handoffs and attachments; per-model thinking lists and errors; canonical accounting including cache-only/tool/compaction/usage entries and unknown context; extension-driven state changes; nested codemode progress/final/replay rendering, collapse behavior, and changed-file tracking.
- Check strict JSONL reconstruction across arbitrary byte chunks and Unicode line separators; keep map hooks and command-ID correlation intact.
- Probe the prior supported minimum's actual command/response contract for the directly adopted APIs and apply the user's version decision table. Do not build old-version fallback behavior.
- Validate the README permission example's imports/hook types and dialog flow against v1.3.0; ensure no double execution after accepted edits, including nested tool calls.
- Run stylua checks on changed Lua files and headless Lua loading/syntax checks. Review diffs for scope in addition to executable verification, not as a substitute.
- Record exact commands and actual results in result.md. Explicitly list interactive visual checks, real-provider behavior, and platforms not exercised here; do not call those verified.

No product edits before this plan passes planning review and user acceptance. Before final review, synchronize the result with actual implementation and verification and resolve all current-scope pending work.
