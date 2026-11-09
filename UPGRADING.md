# Upgrading

## `process.cli` replaced by `process.cmd` (2026-11-07)

`process` is now a launch spec with the same fields as a workspace descriptor's `process`. Its `cmd` is the complete command, run exactly as given: pi.nvim no longer appends `--mode rpc` or drops arguments that conflict with RPC mode. `setup()` raises an error when `process.cli` is set, showing the equivalent `cmd`.

```lua
-- Before
process = { cli = { bin = "omp", args = { "--approve" } } }

-- After
process = { cmd = { "omp", "--approve", "--mode", "rpc" } }
```

Without `process.cli`, nothing changes: the default `cmd` is `{ "pi", "--mode", "rpc" }`.

## `pi.toggle_layout` takes options (2026-11-06)

`pi.toggle_layout` now takes the same options table as the new `pi.set_layout`. If you pass a callback, move it into `on_done`:

```lua
-- Before
require("pi").toggle_layout(function(layout) ... end)

-- After
require("pi").toggle_layout({ on_done = function(layout) ... end })
```

The old form raises an error naming the replacement. `:PiToggleLayout` and `pi.toggle_layout()` without arguments need no change.

## pi 1.3.0

pi.nvim does not change your backend settings or credentials. When upgrading an older backend:

- Rename the Azure provider key from `azure-openai-responses` to `azure` in `auth.json`, `models.json`, and relevant `settings.json` model/provider entries, or sign in again. The `AZURE_OPENAI_*` environment variables are unchanged.
- Include `/v1` in any custom `kimi-coding` base URL in `models.json`.
- Use the tool-wrapper pattern in [Diff review](README.md#diff-review) for permission extensions that handle already-applied edits, including nested calls through codemode.
