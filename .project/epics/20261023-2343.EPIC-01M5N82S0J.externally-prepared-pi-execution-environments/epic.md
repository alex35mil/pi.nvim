# Support externally prepared Pi execution environments

## Overview

Users can operate Pi through the same Neovim keymaps and session commands while external preparation tooling selects and prepares the execution environment for each tab. A tab can launch Pi locally, launch it in an isolated environment, or later connect through a user-owned bridge to an existing Pi instance. Multiple tabs can use different environments for the same project without sharing connection-specific state.

This initiative separates frontend behavior from environment preparation. pi.nvim discovers an abstract, trusted execution descriptor from the tab's workspace and communicates through Pi RPC; external tooling owns provisioning and provider-specific infrastructure.

### Plan highlights

- Ordinary commands discover a trusted execution descriptor in the tab's workspace (its `:tcd` directory, otherwise the global working directory) when they create a connection. Without one, Pi runs locally as today, unless the workspace used a descriptor before; then pi.nvim reports the missing descriptor and asks for confirmation. A descriptor that is untrusted, invalid, or fails never falls back to local Pi. Trusted locations are broad umbrellas that may also contain ordinary checkouts; they make only a descriptor's first use automatic, and any later change needs explicit re-trust. Tabs without `:tcd` share the global workspace and its descriptor.
- Every owned launch stops through one contract: close Pi's input, wait for cleanup, then force-stop. Neovim exit waits up to a shared default of 5 seconds, and cleanup failures are reported visibly, including after exit. Cleanup that outlasts the budget is force-stopped and may be unfinished; crashes, forced termination, and frontends that skip Neovim's exit hooks belong to external supervision.
- Session discovery goes through a session store supplied with the execution context, so continue and resume never search another environment's sessions. The default store follows Pi's own session-directory overrides.
- Connection-specific state (commands, file lists, session storage, logs) is isolated per connection first, fixing today's cross-tab leakage before any new execution mode ships. Commands set through `ctx.set_commands()` in `rpc.map_event` then apply only to the connection that received them.
- First support launching Pi and continuing saved conversations, proven on a generic dedicated container; connect to already-running Pi instances later, together with conversation restoration.
- Deliver six ordered stages, ending with remote workspace access and cross-frontend handoff.
- Ship each Task through the repository default branch, main, after delivering the accepted Epic planning revision there.
- Keep provisioners, bridges, authentication, network access, and other frontends outside pi.nvim.

## Tab-bound execution and ordinary commands

An execution descriptor is provider-neutral information that tells pi.nvim how to run or reach Pi for one workspace: the complete launch command, working directory, and environment; the workspace relationship between host and execution paths; the session store; and the ownership and stop behavior. External preparation tooling writes it into the workspace it prepares, for example a worker clone or worktree. pi.nvim does not choose a sandbox, container, or development environment, and does not infer one from prompt text, workflow kind, or environment names.

When an ordinary command (for example `:Pi`, continue, or resume) needs a connection, pi.nvim looks for a descriptor in the tab's workspace:

- **No descriptor:** Pi runs locally through the configured global `cli.bin` and `cli.args` settings, exactly as today, unless the workspace is expected to have one (below).
- **Trusted, valid descriptor:** pi.nvim evaluates it and starts or reaches the described execution.
- **Untrusted, denied, invalid, or failing descriptor:** pi.nvim reports the problem and does not start a local Pi process instead.

Because a workspace's descriptor names commands to run, discovery requires trust. A descriptor is used only when Neovim's trust mechanism (`vim.secure`, the one `exrc` uses) has allowed it, or when it lives under a user-configured trusted location, such as a directory that holds a user's projects and the worker clones preparation tooling creates. A trusted location may contain both prepared workspaces and ordinary checkouts that run local Pi without a descriptor; being under one does not mean a workspace needs a descriptor. A trusted location only makes a descriptor's first use automatic; that first use normally happens right after preparation writes it, before any agent has run in the workspace. Any later change to a descriptor, inside or outside a trusted location, must be trusted again explicitly. This matters because the execution often has write access to its workspace: an agent that rewrites its own descriptor must never get a new host command run without the user's approval.

For the same reason, an agent must not be able to switch its workspace to host execution by deleting its descriptor. When a workspace that previously used a descriptor has no descriptor, pi.nvim reports the missing descriptor and starts local Pi only after the user explicitly confirms. pi.nvim's record that a workspace used a descriptor is durable: it survives Neovim restarts and lasts until the user explicitly clears it, so restarting Neovim does not reopen this path. How that record is stored and cleared is designed during Task planning. The global configuration names trusted locations only; it contains no project-specific execution knowledge. How pi.nvim asks for trust is designed during Task planning; whatever the interaction, a descriptor that is not trusted or whose trust is declined is reported and never falls back to local Pi.

A tab's workspace is its effective working directory: the tab-local directory when one is set with `:tcd`, otherwise Neovim's global working directory. Tabs without a tab-local directory share the global workspace and its descriptor, while each tab still gets its own Pi process and session; this suits several sessions on the same checkout. A worker clone or worktree gets its own tab-local directory, and therefore its own descriptor and execution, so preparation tooling sets `:tcd` for each worker tab it opens.

Each prepared workspace can carry its own descriptor, so one project can use host execution in one checkout, a lightweight container in a clone, and a fully provisioned environment in another clone. Two tabs for the same project bound to different workers get independent executions. The same global keymaps work in every tab, and ordinary commands take no profile or environment arguments.

A descriptor is evaluated when creating a connection, not at plugin setup and not on each RPC message. The resulting execution context is retained for that live connection. Showing, hiding, or focusing its chat does not reselect the environment, and a descriptor that appears, changes, or disappears while a connection is live does not move it; a tab already running local Pi stays local until an explicit stop or connection transition. Changing an active execution requires an explicit connection transition rather than a UI toggle.

The process-launch contract accommodates the complete argument list, working directory, and environment. User-owned wrappers can perform preparation before exposing Pi RPC. Startup must not block Neovim's main loop; diagnostics and startup failures remain distinct from protocol records.

If preparation fails before writing a descriptor in a workspace that never used one, the workspace is indistinguishable from an ordinary one and runs local Pi; preparation tooling reports its own failure. The exact descriptor file name, format, and fields, and whether discovery searches upward from the workspace directory (for example to its repository root), are defined during Task planning and may evolve as stages add capabilities.

## Execution ownership and shutdown

Location does not determine ownership. Each descriptor declares what its launch or connection owns. pi.nvim applies the matching lifecycle rather than inferring cleanup from an executable name or treating termination of a local connector process as proof of remote cleanup. pi.nvim itself owns only the process it starts; removing a container or other resource is performed by the user-owned launcher in response to pi.nvim's stop request.

| Execution arrangement | Resources owned by this launch or connection | Normal stop, tab closure, or Neovim exit |
| --- | --- | --- |
| Pi launched on the host | The new Pi process | Stop that process. |
| Pi launched in a newly created dedicated environment | The new Pi process and dedicated environment | Stop the dedicated environment and its Pi process. |
| Pi launched inside an already-running environment | Only the new Pi process | Stop Pi and leave the environment and its services running. |
| Connection through a bridge to an existing Pi | Only the client connection | Disconnect and leave Pi and its environment running. |

**Stop contract for owned launches.** Explicit stop, tab closure, and Neovim exit all use the same request: pi.nvim closes the launched process's standard input, which is Pi's documented orderly-shutdown signal and gives a wrapper the chance to clean up; waits a grace period (default 5 seconds); then force-stops the process. Unconfigured local Pi follows the same contract and normally exits immediately.

**Explicit stop and tab closure** wait without blocking Neovim and report a non-zero exit, timeout, or forced stop through normal notifications.

**Neovim exit** closes the input of every owned launch at once and waits for all of them within one shared budget (default 5 seconds), so quitting with several tabs does not wait per tab. pi.nvim shows that it is waiting for cleanup. Launches still running when the budget ends are force-stopped, and their cleanup may be cut short; the documentation must say so. Because the editor is closing, cleanup failures at exit are:

- recorded and shown the next time pi.nvim starts, naming the affected execution, the outcome, and where to look; and
- passed to an optional user callback while Neovim is still running, so users can raise an immediate operating-system notification with their own command. pi.nvim does not ship a platform-specific notifier; documentation includes an example.

Cancellation or failure during startup follows the same ownership boundary; it must not destroy externally owned resources or silently switch targets.

The exit guarantee assumes the user interface runs Neovim's exit hooks and lets Neovim finish. Graphical frontends such as Neovide may close differently from `:qa` in a terminal. Forced termination, crashes, and host failure are not covered by normal shutdown hooks; reliable cleanup under those conditions belongs to external supervision, and the public contract must not claim otherwise.

## Conversations and persistent storage

A tab's execution descriptor, its live RPC connection, and its Pi conversation are separate concepts. Starting a new conversation does not select a different environment or imply that external services must be reprovisioned.

Saved-session continuation starts a new Pi process: after Pi stops, a later launch addresses the prepared environment and restores its saved conversation from the configured persistent storage. The execution working directory and relevant Pi arguments must refer to that environment's conversation data.

**Session store.** Continue and resume find saved conversations through a session store that belongs to the connection's execution context, not by reading a fixed host directory. Pi 1.3.0 offers no RPC command for listing sessions, so the store is supplied with the execution context. It:

- lists sessions with the details the picker shows (identifier, time, name, first message) and each session's path as seen by Pi, which is what pi.nvim passes when switching sessions;
- optionally deletes a session; and
- optionally previews a session.

When a store does not provide deletion or preview, those actions are hidden rather than attempted against host files. New, continue, and resume must never search or modify another worker's sessions.

**Default store.** Without a descriptor, the default store keeps today's local behavior, but resolves the session directory the way Pi does: an explicit `--session-dir` in `cli.args`, the `PI_CODING_AGENT_SESSION_DIR` environment variable, and Pi's `sessionDir` setting take precedence over the per-project directory under the agent directory. Today pi.nvim ignores these overrides, so continue and resume can search the wrong directory even for local Pi.

External preparation chooses and prepares durable session storage. For local isolated execution, session data is backed by host storage rather than disposable container-only storage. For remote execution, it uses appropriate persistent storage on the remote machine. The path visible to Pi inside an environment is distinct from the physical persistence location; the session store bridges them, and pi.nvim does not require direct filesystem access to the storage.

External preparation also makes the necessary settings, instructions, rules, skills, extensions, credentials, and dependencies available to Pi. pi.nvim consumes the selected execution and storage context; it does not provision storage, create mounts, copy the host setup through RPC, or distribute credentials. The configuration and storage selected for one connection must not overwrite another connection's execution context.

Live attachment is a later, distinct workflow. It connects to an already-running Pi through a user-owned service rather than starting a replacement process or merely reopening a saved conversation file.

## Parallel connections and workspace access

Each live connection retains its own execution context, command catalog, workspace association, session store, and diagnostics. Today several of these are shared module-wide: the slash-command cache (also written by the `rpc.map_event` adapter context), the project file cache, the session directory derived from Neovim's current directory, and the RPC debug log path fixed when the plugin loads. As a result, fetching commands in one tab already replaces another tab's completion. Background updates from one connection must not replace another connection's completion, startup, or session data. Health checks report on the configured local execution and must not imply that a prepared execution was validated. The existing one-session-per-tab model remains the starting point.

Workspace access is separate from RPC transport. Local and mounted-source workflows need an explicit relationship between the execution workspace and the correct host checkout. Relative paths and translated execution paths must address that bound workspace, not whichever directory happens to be current or a different copy of the project.

This ownership applies to file completion, source references, changed-file navigation, diff review, and session discovery. Reads and writes must reach the intended worker; a failed or unsupported mapping must not fall through to an unrelated local file.

Initial isolated-process workflows use host-accessible sources through the appropriate workspace relationship. A later stage extends source-file operations to remote environments without a local source mount. Unsupported workspace operations must be communicated explicitly rather than presented as working remote features.

Public connection and workspace interfaces remain provider-neutral. Specific transport addresses, environment identifiers, metadata formats, and remote file protocols belong to user-provided implementations.

## Live attachment and frontend handoff

pi.nvim accepts a user-provided connector that presents the Pi RPC command, response, and event contract. A remote service using another protocol is adapted outside the frontend; pi.nvim does not standardize or ship that service. Connectors are introduced together with conversation restoration, so connecting to an existing Pi never presents an empty or partial chat as a working feature.

Attachment initializes the UI from the existing conversation and current agent state, then continues consuming activity without losing or duplicating content at the initialization boundary. The attachment stage must define and validate behavior for an active run and pending blocking extension UI, not demonstrate only an idle conversation.

Disconnecting releases the frontend connection. It does not imply aborting Pi, terminating the environment, or deleting conversation storage. The attachment stage must also define what happens to a blocking extension dialog that is open in pi.nvim when the connection ends, without answering it on the user's behalf. Reconnection restores the current session rather than relying on frontend state retained before disconnection. Connection loss is visible and does not trigger an unintended replacement Pi process.

Other clients may be another Neovim instance or an external mobile or browser frontend. Authentication, network routing, target discovery, and whether one or several clients may control Pi are service responsibilities. pi.nvim handles the connection outcomes without exposing those policies as environment-selection modes.

The handoff outcome is that a user can disconnect pi.nvim, continue through another frontend, and return to the current Pi conversation. Providing that other frontend is outside this initiative.

## Compatibility and integration boundaries

Without a descriptor, pi.nvim continues to run on the local host using the existing configured `cli.bin` and `cli.args` settings. Existing public APIs, commands, keymaps, and default session behavior remain unchanged, with three documented exceptions:

- the default session store honors Pi's session-directory overrides;
- `ctx.set_commands()` in `rpc.map_event`, documented today as replacing the shared slash-command cache, replaces only the command catalog of the connection that received the event; the README and configuration type descriptions change with it; and
- unconfigured local Pi follows the owned-launch stop contract: stopping closes its input, waits up to the grace period, then force-stops it, instead of terminating the process immediately. On Neovim exit it shares the exit budget, waiting indicator, and cleanup-failure reporting. Local Pi normally exits as soon as its input closes, so this adds no noticeable delay in the usual case.

Descriptor discovery, trusted locations, the session store, and connector interfaces are opt-in additions; this Epic does not require a breaking change to the default user workflow. Any future proposal that needs such a breaking change requires separate user approval. Chat visibility, conversation management, and connection/resource shutdown must not become implicit environment-selection actions.

pi.nvim never runs commands from a workspace descriptor that the user has not trusted, directly or through a configured trusted location.

Connection-specific state and workspace behavior belong in their owning abstractions and must be consumed consistently by completion, session management, and UI code. The initiative must not bypass existing shared components through caller-specific container or remote special cases.

Documentation must describe public interfaces, ownership, trust, configuration and storage responsibilities, and meaningful limitations as each stage becomes available. A demonstrated RPC connection alone does not establish that lifecycle, filesystem integration, or remote continuation works.

The initiative provides integration contracts and verification support. It excludes environment provisioning, runtime management implementations, credential distribution, bridge services, network-access configuration, operating-system notifiers, other frontends, and service-side client arbitration.

## Task delivery strategy

The approved strategy is repository-default delivery: future Tasks start from and target main rather than using the Epic branch as an umbrella integration target.

The ordered stages provide usable incremental capabilities while preserving the default local workflow. Earlier launching improvements can ship without waiting for live attachment, remote workspace access, or cross-frontend handoff. Each Task must leave main working; prerequisites land before dependent Tasks begin. The Epic does not require intentionally incomplete intermediate states to accumulate on a long-lived integration branch.

Before initializing the next Task, deliver the current accepted Epic planning revision into main through approved Git and provider operations. A squash merge is supported when exact configured GitHub evidence confirms delivery of the current Epic branch revision to its stored target. The original source commit need not be an ancestor of main. Default-target Task initialization must also verify that the working accepted Epic plan exactly matches the plan available on the local target branch.

The Task-target pointer was switched to the default target after verified delivery of the earlier accepted planning revision, so future Tasks start from and target main. Each later accepted planning revision, including this one, must be delivered to main before the next Task is initialized, and the Epic branch must carry the same Task-target metadata as main before planning is committed. The Epic remains In Progress; merging its planning work does not complete the initiative. Existing Tasks retain their stored start and target. A later strategy change requires explicit approval and the normal Epic plan-review and acceptance flow.

## Ordered Tasks

1. **Isolate connection-specific state** — Give each session its own slash-command catalog (including commands set through `ctx.set_commands()` in `rpc.map_event`, with its documentation updated), project file list, session directory, and RPC diagnostics, so activity in one tab never replaces another tab's completion or startup data. Fix the default session store to resolve Pi's session-directory overrides (`--session-dir` in `cli.args`, `PI_CODING_AGENT_SESSION_DIR`, the `sessionDir` setting) and keep health checks consistent with it. Local behavior is otherwise unchanged. This stage introduces no descriptors or new execution modes.

2. **Launch Pi from trusted workspace descriptors** — Introduce descriptor discovery from the tab's workspace with the trust rules (Neovim trust or configured trusted locations), the owned launch contract (complete command, working directory, environment, non-blocking startup, separate diagnostics), the stop contract with grace period and the shared Neovim-exit budget, and cleanup-failure reporting (notifications, next-start report, optional callback). Introduce the session store with optional delete and preview, and the mounted-source workspace relationship. Prove it end to end with a generic dedicated container on a copy-on-write clone or worktree: launch, new/continue/resume against host-backed storage, and clean shutdown. Missing descriptors keep local launch behavior, except in workspaces durably recorded as having used one, which need explicit confirmation; unconfigured local Pi also adopts the new stop contract; failures never fall back to local. Does not cover already-running environments, connectors, or remote workspaces.

3. **Validate the remaining owned-process workflows** — Extend descriptors to launching Pi inside an already-running environment, where stopping leaves the environment and its services running. Verify two independent workers for the same project in parallel tabs, persistent new/continue/resume in each, correct ownership boundaries for host, dedicated, and existing environments, and Neovim exit from both a terminal and a graphical frontend (including closing the window, not only `:qa`). Make the shared lifecycle and workspace changes these outcomes need, with project-independent documentation and verification evidence. Do not introduce connectors or claim support for unmounted remote workspaces.

4. **Attach to running Pi through user-owned connectors** — Accept user-owned connectors that present Pi RPC, with a lifecycle whose stop releases only the client connection. Initialize the UI from the existing conversation and agent state, coordinate that initialization with subsequent events, and handle attachment during active work and pending extension dialogs. Define connection failure, explicit disconnect (including dialogs open at that moment), and reconnection that restores current state without spawning a replacement Pi. Leave bridge protocols, authentication, and client-control policies external.

5. **Support remote workspace access** — Extend the workspace boundary beyond local and mounted sources through user-provided implementations for source-file operations, integrated with the connection's session store. Connect completion, source references, changed-file navigation, and diff review to the bound remote workspace; make unsupported operations explicit and prevent unintended host-file access. Reuse the connector contract without adding provider-specific remote infrastructure.

6. **Validate cross-frontend handoff** — Verify the complete generic workflow against a user-owned external service: connect from pi.nvim, detach while Pi remains available, operate through another frontend, and return to the current conversation. Include the declared workspace capabilities, lifecycle boundaries, and connection-loss behavior in the evidence and documentation. Do not build or ship a bridge, network-access service, or another frontend as part of this stage.
