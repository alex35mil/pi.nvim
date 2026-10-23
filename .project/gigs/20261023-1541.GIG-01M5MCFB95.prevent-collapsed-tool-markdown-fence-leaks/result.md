# Result

## Overview

Collapsed tool previews no longer leave Markdown fences open over later chat messages. One shared boundary helper now protects previews, user messages, assistant completion, and live/final tool output, including longer backtick fences and tilde fences.

The helper uses the same optional Markdown parser as chat highlighting, so it respects list/quote boundaries and literal fence-like text. Chat remains operational without that parser. Existing preview limits, expanded tool content, styles, and public configuration remain unchanged.

Automated verification ran headless on Neovim 0.12.0, and the user confirmed the live fenced-output toggle reproduction looks correct. Neovim 0.10 runtime and systematic checks of all layout variants remain unrun.

## Implementation walkthrough

`lua/pi/ui/chat/fences.lua` analyzes whether following prose would fall inside a fenced block and returns its matching closer. Its private analysis text never enters the transcript. Collapsed previews are checked after line selection and width shortening; the resulting safe preview is cached for re-collapse. Existing message/output closing checks now share this helper instead of counting triple-backtick lines.

## Verification

- `nvim --headless -u NONE -l tests/fences.lua` — 43 regressions passed on Neovim 0.12.0, covering Markdown syntax, bash/codemode/generic tool toggles, stream boundaries, live-output replacement, preview limits, extmarks, tables, and optional-parser/error paths.
- Original bash/codemode reproduction — following prose remains a paragraph after collapse, expansion, and re-collapse in all six checks.
- Live tool-output reproduction with a closed fence and six numbered lines — user confirmed the toggle behavior looks correct in the running chat UI.
- Additional message/output boundary probe — all 24 user, assistant, live-tool, and final-tool cases preserve following prose.
- Lua `loadfile` checks for the changed/new Lua files — passed.
- `stylua --check lua/pi/ui/chat/fences.lua lua/pi/ui/chat/tools.lua lua/pi/ui/chat/history.lua tests/fences.lua` — passed.
- `git diff --check` — passed.

**Not run:**

- Systematic side, float, and zen layout checks — the user confirmed one live toggle reproduction; coverage of every layout variant was not established.
- Neovim 0.10 runtime checks — only Neovim 0.12.0 was exercised; the helper's APIs were checked against the 0.10 source.
