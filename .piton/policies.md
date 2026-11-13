# Project Policies

## Labels

When choosing labels for new or existing work:

- **Area** (one or more): apply every area the work affects, not only the primary one. Docs for a specific area belong to that area, not `Area: Docs`; `Area: Docs` is only for user-facing docs not tied to one area, and contributor/agent docs belong to `Area: Tooling`.
- **Area: Config & API** is added alongside the feature area whenever the work adds, changes, or removes a setup option, public Lua API, command, or keymap.
- **Area: Sessions vs. Area: Runtime:** Sessions covers the conversation and session store (lifecycle, resume, naming, tree navigation, reload of session state); Runtime covers the Pi process and connection (spawning, RPC transport, execution environments, workspaces, connectors, pi compatibility).
- **Dialogs** (`ui/dialog.lua`, attention flow) belong to `Area: Extensions`, never `Area: Layout`.
- **Breaking** is applied to every Deliverable that breaks public config or API; it requires a `!` commit and an `UPGRADING.md` entry.
