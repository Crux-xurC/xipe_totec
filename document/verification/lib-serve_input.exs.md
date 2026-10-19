# `lib/serve_input.exs`

The `input` method: one line typed into tezcatl's dialogue window, `{"text": <line>}`. When a dialogue is held the line is its answer;
otherwise `lib/input.exs` reads it as the CLI would, and this module runs it — commands through the server one by one, waiting for an
evaluation before the next — and answers with the CLI's own lines.

**Decisions homed here**: [D-input-line](#d-input-line)
**Takes part in**: D-dialogue-core ([`lib/in_out.exs`](lib-in_out.exs.md)), D-envelope ([`lib/protocol.exs`](lib-protocol.exs.md)),
D-help-table ([`lib/help.exs`](lib-help.exs.md))

<a id="d-input-line"></a>

## D-input-line — the window sends a line uninterpreted; Xipe Totec reads it as the CLI would

**Decided** (2026-09-27, with tezcatl's dialogue window; extended 2026-10-05): tezcatl sends every line as it was typed and never
interprets it (as emacs-vent's `kind:"input"` leaves keys to Emacs). Meaning is decided here.

- **A line is what follows `xipe` in a terminal** (a leading `xipe` allowed): `help [<command>]`, `version`, `show`, `scan`,
  `eval [id...] [--include-writes]`, `search`, the `dialogue …` commands, `quit dialogue`, `do <method> … [-- …]`, or a line beginning with
  a method name (a word with `/`, or one of `Methods`) read as `do` without the word. `'…'` and `"…"` are removed as a shell would, so a line
  copied from a terminal reads the same. `<dir>`, `--dir`, `--mix` are not taken (the target is the open project)
- **In a `--` list without `do`**, a step may be the window's shorthand `scan` or `eval [id...]` (`scan -- node/resolve … -- eval …`). With
  `do` the line is exactly `xipe do`'s, no shorthands
- **Commands that need a terminal are refused** with an error saying so: `choice project`, `table generate`, `start`/`serve`, `config`,
  `refresh` (they choose or start projects, or write Xipe Totec's own files)
- **The answer is the CLI's lines** in `dialogue.text` (`OutcomeText`, `Show`, `Help`), and for commands `result.outcomes` per command. A
  failing command does not fail the reply; only a line that cannot be read is an `input_error`
- **Commands run like the CLI's**: in order, each an ordinary server request, `$<n>.<path>` resolved from the earlier results; an
  evaluation goes to the pass queue and the line **waits for that pass** before going on, so `… -- eval … -- row/check` sees the values.
  The waiting is in a process of its own; the connection (shared by tezcatl's windows) keeps answering
- **A command that starts a dialogue ends the line**: its question is the reply. One that finishes at once with commands (`dialogue do`
  given everything) has them run in its place

**Why**: tezcatl stays a window that never parses Xipe Totec's text; one syntax for terminal and window; waiting keeps a line's meaning the
same as in a terminal.

**Alternatives**: tezcatl translating lines into method calls; answering an evaluation at once and letting the next command race it.

**Files**: `lib/serve_input.exs`, `lib/input.exs`, `lib/serve_socket.exs` (the `input` frame), `lib/serve_project.exs`
(`request_dialogue/5`, `watch:`), `lib/outcome_text.exs`, `lib/show.exs`, `lib/help.exs`; tests `test/input_test.exs`,
`test/serve_input_test.exs`; tezcatl's `test/e2e/xipe_input.mjs`.

**Earlier**: `Old.md` §40, §41.4, §48.

## Notes

- Lines sent without waiting for the answer run at the same time; the window's way is one line, then its answer (`範囲.md`)
- Two windows share one dialogue (one connection, one slot): another window's line becomes the answer (`範囲.md`)
- Verified: not yet verified cold (written from the code, 2026-10-19)
