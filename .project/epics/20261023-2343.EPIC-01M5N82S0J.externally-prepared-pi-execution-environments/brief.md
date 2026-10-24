# Brief

Enable pi.nvim to launch or connect to Pi through user-defined launchers and connectors, using dynamically resolved, tab-scoped information supplied by external preparation tooling. Existing global keymaps and ordinary session commands remain unchanged.

Support Pi running on the host, in a newly created dedicated environment, or inside an existing environment, with explicit ownership and shutdown behavior. Keep parallel sessions’ connection state, workspace paths, configuration, and session storage isolated.

Deliver incrementally: dynamic launching; verification of owned-process execution workflows; externally owned connection lifecycles; live attachment and state restoration; remote workspace access; and cross-frontend handoff verification.

Environment provisioning, bridges, authentication, access policy, and other frontends remain externally owned. pi.nvim provides abstract integration interfaces rather than implementations tied to a particular runtime, service, or project.
