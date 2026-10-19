# `lib/dialogue/do.exs`

`dialogue do <method> [key=value...]`: a method call put together by asking — the required parameters the starting line left out are
asked for one at a time, the finished call is shown, and (for a method that writes) run after `y`. `lib/dialogue/rewrite.exs` and
`lib/dialogue/update.exs` lead into it: they ask for the table, row and column, or the file and key, then hand over to it.

**Decisions homed here**: [D-dialogue-do](#d-dialogue-do)
**Takes part in**: D-dialogue-core ([`lib/in_out.exs`](lib-in_out.exs.md)), D-method-criteria ([`lib/methods.exs`](lib-methods.exs.md)),
D-project-config ([`lib/project_config.exs`](lib-project_config.exs.md)), D-log-buffer ([`lib/log_buffer.exs`](lib-log_buffer.exs.md))

<a id="d-dialogue-do"></a>

## D-dialogue-do — ask for what is missing, take each answer as typed, confirm before writing

**Decided** (2026-10-12 to 2026-10-13, crux): three dialogues share one way of asking.

- **`dialogue do`**: what the starting line gave is kept; every *required* parameter it did not give (`Methods`' `params`) is asked for in
  order; optional ones are never asked (write them on the line)
- **An answer is the whole line as it is**: no words split, no quotes removed, no commas read — so a value one line of `xipe do` cannot
  carry (`[1,2,3]` as one argument, `"a b"`, a tuple) is typed unchanged
- By kind: a function by its id or its name as shown (`Calc.add/2`; a shared name lists the candidates and asks again); a row by its id; a
  value as the line; a choice or a number checked; an address as a function's name taken apart; **a list** between a line holding only
  `{` and one holding only `}`, one element a line (`args` checked against the function when it closes)
- A wrong answer asks again. The finished call is shown parameter by parameter; a method that writes the Book, or `confirm`s (a
  project's settings), waits for `y` / `n`; others run at once. The call goes to the driver as structured params, never back through a line
- **`dialogue rewrite [<table> [<row> [<column>]]]`**: one value changed **without evaluating**. The row is shown in full before the column
  is asked; a column names the method that writes it (`Tables`' `writes`: `args` → `row/set-args`, `result` → `row/set-result`, `prev` →
  `row/set-prev`, `effect` → `effect/set`), and from there it is `dialogue do` for that method with the row's id given
- **`dialogue update [<file> [<key>]]`**: one setting changed. The file is chosen by number from the latest five files the lines said named
  (D-log-buffer; the open project's `project.json` always among them); every key is shown with its value, what it may be, and where it
  comes from; the value is checked as typed. Only the open project's `project.json` is written — choosing `defaults.json` writes the
  project's own file and says so; another project's file is refused. Then `dialogue do` for `config/set`
- None of the three writes anything itself; the Book is only read

**Why**: a person should not have to fight the one-line syntax for values (crux: base evaluation stays a plain command; what is in doubt
is settled by dialogue). One asker keeps the three consistent.

**Alternatives**: more one-line syntax (escapes, JSON values); a separate confirm logic per dialogue.

**Files**: `lib/dialogue/do.exs`, `lib/dialogue/rewrite.exs`, `lib/dialogue/update.exs`, `lib/methods.exs` (`params`, `confirm`),
`lib/tables.exs` (`writes`), `lib/dispatch.exs` (`row/set-args`, `row/set-prev`, `config/set`); tests `test/dialogue_do_test.exs`,
`test/dialogue_rewrite_test.exs`, `test/dialogue_update_test.exs`, `test/serve_input_test.exs`.

**Earlier**: commits f59d4d8 (`dialogue do`), adbce04 (`dialogue rewrite`), 901166d (`dialogue update`), 44b4c9c; `document/範囲.md`.

## Notes

- `dialogue do`'s list must be one element a line: `{1, 2}` on one line is not read as a list (`範囲.md`)
- Verified: not yet verified cold (written from the code, 2026-10-19)
