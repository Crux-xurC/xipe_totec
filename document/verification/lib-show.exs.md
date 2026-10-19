# `lib/show.exs`

`show`'s lines: the Book's sheets, nodes, links and calc rows, one a line — from the Book on disk for the CLI, from the running server's
Book for the window. Calc rows come through the same `row/list` a client uses.

**Decisions homed here**: [D-show-failed](#d-show-failed)

<a id="d-show-failed"></a>

## D-show-failed — a failed row shows the failure; the old value is kept, apart

**Decided** (2026-10-07, crux): `Core.apply_result` keeps the previous `result` of a row whose evaluation failed (the Book is a record and
is not rewritten). `show` used to print it in the value's place, so `0  compare=same  state=eval_error` read as a current value. Now a
failed row prints `(error: <reason>)  previous=<previous value>  state=eval_error` — `previous=` only when there was one, and no `compare`
(it belongs to the earlier evaluation).

**Why**: values are not erased, but what is shown must not mislead. tezcatl's table already showed failed rows as `→ (error)` with
`state` and `error` columns; `show` matches it.

**Alternatives**: clearing `result` on failure (loses the record).

**Files**: `lib/show.exs`, `lib/core.exs` (`apply_result/3`); tests `test/show_test.exs`.

**Earlier**: `Old.md` §52 (tezcatl's field check S-2).

## Notes

- Verified: not yet verified cold (written from the code, 2026-10-19)
