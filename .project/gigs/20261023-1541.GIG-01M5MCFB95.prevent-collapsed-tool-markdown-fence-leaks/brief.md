# Brief

Prevent collapsed tool output from leaking Markdown fences into later chat

Collapsing tool output containing fenced Markdown can make subsequent chat messages render as code.

### Reproduction
1. Have codemode or bash print a fenced code block containing six numbered lines.
2. Let the tool output collapse.
3. Append an assistant message.

The preview drops the opening fence but retains the closing fence, which Markdown interprets as a new opener. Expanding the tool restores normal formatting.

Reproduced against pre-upgrade commit `10dec5f` with both bash and codemode’s generic renderer.

### Scope
Fix fence-boundary handling in the shared collapsed-preview renderer (`lua/pi/ui/chat/tools.lua`), rather than adding a codemode-specific workaround.

### Acceptance
- Collapsed tool output cannot change subsequent messages’ Markdown formatting.
- Parser-backed regressions cover codemode and bash across collapse, expansion, and re-collapse.
