# `lib/dialogue/search.exs`

`search`: narrows the declared tables over the turns of one dialogue — find rows, take a column's values as the held list, look them up
in the next table, view the rows — the join is the turns, not a query language. `lib/eval_table.exs` is the `eval_table` it reads (calc
rows with their function and path beside them).

**Decisions homed here**: [D-search](#d-search)
**Takes part in**: D-dialogue-core ([`lib/in_out.exs`](lib-in_out.exs.md)), D-method-criteria ([`lib/methods.exs`](lib-methods.exs.md))

<a id="d-search"></a>

## D-search — narrowing over turns, writing nothing

**Decided** (2026-09-27, extended 2026-10-12):

- **The tables** are the ones `lib/tables.exs` declares (`roster` returns the same): `-s` the project's surface table, `-e` the
  `eval_table`. Both are read afresh every turn from the read-only `ctx`; the saved surface table is read as it is (not made again)
- **`eval_table` is a view, not a store**: `calls` with the function (`module`, `name`, `anykey`, `effect`, `visibility`) and file (`path`)
  beside each row; column names stay the Book's (`result`, not `row/list`'s `value`); a row whose function is gone has those empty
- **Turns**: `-h`; `-s|-e <column> <value> [<out>]` (the rows' `<out>` values, default `id`, become the held list); `… <column> list <out>`
  (the same for each held value); `… view <column> [<cols>]` (then "end the search? y/n"); `get id [-n]` keeps the n-th held value as
  `x`; `quit dialogue`
- **Matching**: exact; `~<value>` a substring (`-e args ~⟦<id>⟧` — who refers to a row); a number as its text; `-` an empty cell; a list
  cell as its elements joined with `, `; more than 10 hits show the first 10 and the count
- **Anything else is a command**, run while the search holds (`{:pass, …}`), with `x` replaced where it is a word, a value (`id=x`), a list
  element (`call_ids=[x]`) or a reference (`⟦x⟧`) — not inside a word. Using `x` before `get id` is said, not run
- **Nothing is evaluated or written** by the search itself

**Why**: joins written as turns stay readable on a CLI and in the window, without adding query methods (D-method-criteria); the
`eval_table` answers "doesn't it overlap `calls`?" by being a view of it.

**Alternatives**: an SQL-like query language; new turn kinds (not added); a stored `eval_table`.

**Files**: `lib/dialogue/search.exs`, `lib/eval_table.exs`, `lib/tables.exs`, `lib/surface_table.exs`; tests
`test/dialogue_search_test.exs`, `test/serve_input_test.exs`.

**Earlier**: `roster` and the tables' declaration from f59d4d8.

## Notes

- Verified: not yet verified cold (written from the code, 2026-10-19)
