# `lib/log_buffer.exs`

What Xipe Totec said lately, as a file: `tables/logging_buffer.txt`, the last 100 lines, one file for every project and for CLI and
server alike. `recent_files/2` reads back the files the lines named.

**Decisions homed here**: [D-log-buffer](#d-log-buffer)
**Takes part in**: D-dialogue-do ([`lib/dialogue/do.exs`](lib-dialogue-do.exs.md))

<a id="d-log-buffer"></a>

## D-log-buffer — the lines said are the memory CLI and server share

**Decided** (2026-10-13, crux):

- Every line a command prints (results, a dialogue's text, answers to the window) is appended; past 100 lines the oldest go
- **A line names a file by putting its path last inside parentheses**, as a pass's limits line does —
  `eval: limit 5s per row (eval.timeout, /…/tables/project/001_calc/project.json)`. Only a path (with a `/`) ending in `.json` counts
- `dialogue update` offers the latest five distinct files, numbered
- **Best effort**: a line lost to two writers at once, or a file that cannot be written, never fails the command that spoke; with `nil`
  for the file nothing is written or read

**Why**: a CLI call is its own process, so the server cannot remember what it said; what was written down is the only thing both can
point back at ("the file that line named").

**Alternatives**: the server remembering per connection (the CLI would have nothing); asking for a path by hand.

**Files**: `lib/log_buffer.exs`, `lib/outcome_text.exs` (the limits line), `lib/dialogue/update.exs`, `main.exs`, `lib/serve_input.exs`;
tests `test/dialogue_update_test.exs`.

**Earlier**: commit 901166d; `document/範囲.md`.

## Notes

- Verified: not yet verified cold (written from the code, 2026-10-19)
