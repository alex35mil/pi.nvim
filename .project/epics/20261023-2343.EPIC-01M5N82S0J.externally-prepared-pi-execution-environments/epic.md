# Support externally prepared Pi execution environments

## Overview

Users can operate Pi through the same Neovim keymaps and session commands while external preparation tooling selects and prepares the execution environment for each tab. A tab can launch Pi locally, launch it in an isolated environment, or later connect through a user-owned bridge to an existing Pi instance. Multiple tabs can use different environments for the same project without sharing connection-specific state.

This initiative separates frontend behavior from environment preparation. pi.nvim consumes an abstract execution binding and communicates through Pi RPC; external tooling owns provisioning and provider-specific infrastructure.

### Plan highlights

- Bind each tab to externally supplied execution information without requiring project-specific keymaps or profile arguments on ordinary commands.
- Release only resources owned by the selected launch or connection.
- First support launching Pi and continuing saved conversations; add connections to already-running Pi instances later.
- Each tab uses its selected worker's commands, workspace paths, settings, and session storage, so activity in one tab does not use another tab's context.
- External tooling prepares durable session storage: host-backed storage for local isolated execution and appropriate persistent storage on the remote machine for remote execution.
- Deliver six ordered stages, ending with remote workspace access and cross-frontend handoff.
- Keep provisioners, bridges, authentication, network access, and other frontends outside pi.nvim.

## Tab-bound execution and ordinary commands

An execution binding is the information external preparation associates with a Neovim tab: the user-defined launcher or connector and the inputs needed to address its environment and workspace. External tooling chooses whether to use a lightweight sandbox, a full development environment, or another execution arrangement. pi.nvim does not make that choice from prompt text or workflow kind.

Preparation can create a worker checkout, start services, obtain a target identity, bind its information to a new tab, and then invoke ordinary pi.nvim. The same global keymaps work in every prepared tab. Two tabs for the same project can have different bindings.

A resolver translates prepared inputs into a launch or connection specification. It is evaluated when creating a connection, not once at plugin setup and not on each RPC message. Its inputs are tab-specific; the preparation metadata source and format remain user-owned. A central project mapping module and automatic execution of a particular project configuration file are not prerequisites.

The process-launch contract accommodates the complete argument list, working directory, and environment. User-owned wrappers can perform preparation before exposing Pi RPC. Startup must not block Neovim's main loop; diagnostics and startup failures remain distinct from protocol records.

The resolved target and workspace are retained for that live connection. Showing, hiding, or focusing its chat does not reselect the environment. Changes elsewhere in Neovim do not silently move an active conversation to another target. Changing an active execution binding requires an explicit connection transition rather than a UI toggle.

An unconfigured tab retains current local execution through the configured global cli.bin and cli.args settings. Existing public APIs, commands, and global keymaps keep their current default behavior; prepared-connection interfaces are opt-in. Once a user selects a prepared binding, missing inputs, resolver failures, and unavailable targets are reported instead of starting an unintended local Pi process.

## Execution ownership and shutdown

Location does not determine ownership. Every launcher or connector supplies a lifecycle contract describing the resources it creates and releases. pi.nvim invokes that contract rather than inferring cleanup from an executable name or treating termination of a local connector job as proof of remote cleanup.

| Execution arrangement | Resources owned by this launch or connection | Normal stop, tab closure, or Neovim exit |
| --- | --- | --- |
| Pi launched on the host | The new Pi process | Stop that process. |
| Pi launched in a newly created dedicated environment | The new Pi process and dedicated environment | Stop the dedicated environment and its Pi process. |
| Pi launched inside an already-running environment | Only the new Pi process | Stop Pi and leave the environment and its services running. |
| Connection through a bridge to an existing Pi | Only the client connection | Disconnect and leave Pi and its environment running. |

The implementation remains abstract: a provider can implement resource cleanup through a wrapper or a connection lifecycle operation. pi.nvim does not ship a provisioner or assume a container runtime.

Explicit stop and normal frontend shutdown must release the correct owned resources and report cleanup failures. Cancellation or failure during startup follows the same ownership boundary; it must not destroy externally owned resources or silently switch targets.

Forced termination and host failure are not covered by normal Neovim shutdown hooks. Reliable cleanup under those conditions belongs to external supervision; the public contract must not claim otherwise.

## Conversations and persistent storage

A tab's prepared execution binding, its live RPC connection, and its Pi conversation are separate concepts. Starting a new conversation does not select a different environment or imply that external services must be reprovisioned.

Saved-session continuation starts a new Pi process: after Pi stops, a later launch addresses the prepared environment and restores its saved conversation from the configured persistent storage. The execution working directory and relevant Pi arguments must refer to that environment's conversation data. New, continue, and resume operations must not accidentally search another worker's session directory.

External preparation chooses and prepares durable session storage. For local isolated execution, session data is backed by host storage rather than disposable container-only storage. For remote execution, it uses appropriate persistent storage on the remote machine. The path visible to Pi inside an environment is distinct from the physical persistence location; pi.nvim does not require direct filesystem access to that location when the selected execution/session interface provides discovery and continuation.

External preparation also makes the necessary settings, instructions, rules, skills, extensions, credentials, and dependencies available to Pi. pi.nvim consumes the selected execution and storage context; it does not provision storage, create mounts, copy the host setup through RPC, or distribute credentials. The configuration and storage selected for one connection must not overwrite another connection's execution context.

Live attachment is a later, distinct workflow. It connects to an already-running Pi through a user-owned service rather than starting a replacement process or merely reopening a saved conversation file.

## Parallel connections and workspace access

Each live connection retains its own execution context, command catalog, and workspace association. Background updates from one connection must not replace another connection's completion or startup data. The existing one-session-per-tab model remains the starting point; externally prepared tabs provide independently selectable workers.

Workspace access is separate from RPC transport. Local and mounted-source workflows need an explicit relationship between the execution workspace and the correct host checkout. Relative paths and translated execution paths must address that bound workspace, not whichever directory happens to be current or a different copy of the project.

This ownership applies to file completion, source references, changed-file navigation, diff review, and session discovery. Reads and writes must reach the intended worker; a failed or unsupported mapping must not fall through to an unrelated local file.

Initial isolated-process workflows use host-accessible sources through the appropriate workspace relationship. Continuation and session discovery address the externally prepared durable storage through the selected execution/session interface. Host-backed persistence does not require pi.nvim to treat a container-visible path as a host path or read session files directly. A later stage extends source-file operations to remote environments without a local source mount. Unsupported workspace operations must be communicated explicitly rather than presented as working remote features.

Public connection and workspace interfaces remain provider-neutral. Specific transport addresses, environment identifiers, metadata formats, and remote file protocols belong to user-provided implementations.

## Live attachment and frontend handoff

pi.nvim accepts a user-provided connector that presents the Pi RPC command, response, and event contract. A remote service using another protocol is adapted outside the frontend; pi.nvim does not standardize or ship that service.

Attachment initializes the UI from the existing conversation and current agent state, then continues consuming activity without losing or duplicating content at the initialization boundary. The attachment stage must define and validate behavior for an active run and pending blocking extension UI, not demonstrate only an idle conversation.

Disconnecting releases the frontend connection. It does not imply aborting Pi, terminating the environment, or deleting conversation storage. Reconnection restores the current session rather than relying on frontend state retained before disconnection. Connection loss is visible and does not trigger an unintended replacement Pi process.

Other clients may be another Neovim instance or an external mobile or browser frontend. Authentication, network routing, target discovery, and whether one or several clients may control Pi are service responsibilities. pi.nvim handles the connection outcomes without exposing those policies as environment-selection modes.

The handoff outcome is that a user can disconnect pi.nvim, continue through another frontend, and return to the current Pi conversation. Providing that other frontend is outside this initiative.

## Compatibility and integration boundaries

Without prepared connection data, pi.nvim continues to run on the local host using the existing configured cli.bin and cli.args settings. Existing public APIs, commands, keymaps, and default session behavior remain unchanged. New execution-binding and connection interfaces are opt-in additions; this Epic does not require a breaking change to the default user workflow. Any future proposal that needs such a breaking change requires separate user approval. Chat visibility, conversation management, and connection/resource shutdown must not become implicit environment-selection actions.

Connection-specific state and workspace behavior belong in their owning abstractions and must be consumed consistently by completion, session management, and UI code. The initiative must not bypass existing shared components through caller-specific container or remote special cases.

Documentation must describe public interfaces, ownership, configuration and storage responsibilities, and meaningful limitations as each stage becomes available. A demonstrated RPC connection alone does not establish that lifecycle, filesystem integration, or remote continuation works.

The initiative provides integration contracts and verification support. It excludes environment provisioning, runtime management implementations, credential distribution, bridge services, network-access configuration, other frontends, and service-side client arbitration.

## Ordered Tasks

1. **Introduce dynamic tab-bound process launching** — Define and implement the abstract prepared-input/resolver and owned-process launch contracts, including complete arguments, working directory, environment, startup diagnostics, and shutdown ownership. Bind execution context and connection-specific state to each session so ordinary commands and global keymaps work unchanged across independently prepared tabs. Preserve unconfigured local execution and report selected-binding failures without host fallback. This stage does not attach to an existing Pi or implement a provisioner.

2. **Validate owned-process execution workflows** — Build on the launch contract to establish usable host, dedicated-environment, and existing-environment execution. Verify correct shutdown boundaries, externally supplied Pi resources, persistent new/continue/resume behavior, mounted-source path relationships, and two independent workers. Make the shared-workspace and lifecycle integration changes needed for those outcomes, with project-independent documentation and verification evidence. Do not introduce bridge attachment or claim support for unmounted remote workspaces.

3. **Introduce externally owned connection lifecycles** — Extend the connection boundary to user-owned connectors whose shutdown releases a connection rather than an agent or environment. Define connection failure, explicit disconnect, and lifecycle dispatch while preserving owned-process behavior. This stage establishes externally owned transport/lifecycle integration; it does not claim complete live-session restoration before the next stage.

4. **Support live attachment and state restoration** — Build on externally owned connections to initialize the UI from an existing Pi conversation and state, coordinate initialization with subsequent events, and address attachment during active work and pending extension interactions. Reconnection must recover current state without spawning a replacement agent. Leave bridge protocols, authentication, and client-control policies external.

5. **Support remote workspace access** — Extend the workspace boundary beyond local and mounted sources through user-provided implementations for source-file operations, integrated with execution-bound session discovery. Connect completion, source references, changed-file navigation, and diff review to the bound remote workspace; make unsupported operations explicit and prevent unintended host-file access. Reuse the live-connection contract without adding provider-specific remote infrastructure.

6. **Validate cross-frontend handoff** — Verify the complete generic workflow against a user-owned external service: connect from pi.nvim, detach while Pi remains available, operate through another frontend, and return to the current conversation. Include the declared workspace capabilities, lifecycle boundaries, and connection-loss behavior in the evidence and documentation. Do not build or ship a bridge, network-access service, or another frontend as part of this stage.
