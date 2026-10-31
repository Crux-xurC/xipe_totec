# `lib/passes.exs`

The passes being evaluated now, as files: one per pass and language group in `<project_dir>/passes/<pass_id>-<language>.json` (owner's OS
pid and start time, the rows, the current row and its phase), written by the process that runs it and removed when it ends. What
`eval/status` shows, what keeps a row in a pass from being changed, and where `eval/cancel` leaves its request.

**Decisions homed here**: [D-passes](#d-passes)
**Takes part in**: D-hang-handling ([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md)), D-serve-project
([`lib/serve_project.exs`](lib-serve_project.exs.md))

<a id="d-passes"></a>

## D-passes — a running pass is a file; its rows cannot change; it can be stopped from anywhere

**Decided** (2026-10-06, crux: base evaluation stays a plain command, and a change to a row being evaluated is **refused by structure**, not
merely avoided; `eval/cancel` 2026-10-12):

- **Refused while it runs**: `row/update`, `row/set-result` and `row/remove` on a row of a running pass answer `row_in_pass` — the only
  three ways a row changes, and CLI, server and dialogues all go through them. Otherwise a result would be recorded against arguments it was
  never computed from (the server folds results into the Book as it is when the pass ends)
- **A file, not the server's memory**: the CLI writes `book.jsonl` itself even while a server runs, so both must see the record
- **Alive means the owner is alive**: a record whose process is gone (by pid and OS start time, as `Session`) is not a running pass and is
  dropped when read; the server also clears it when its pass process dies without cleaning up
- **A group whose record cannot be written does not run** (`eval_failed`): the record is what locks its rows
- **`eval/status`** (read-only): each running pass's language, elapsed time, rows, the current row and its phase — `calling` from when it
  is sent, `classifying` once `XT_CALLED_<id>` says it returned; on the server also the queued passes
- **`eval/cancel`**: a file `<project_dir>/passes/<pass_id>.cancel`, so the CLI can stop a server's pass and the other way round. The pass
  sees it while waiting on its REPL (also during boot), kills the REPL's group and ends with the `cancelled` error, recording nothing; a
  request that cannot be written is `not_cancelled`
- Without a `project_dir` (tests, a bare Runner) nothing is written or locked

**Why**: the server's snapshot-then-fold made it possible to record a value against changed arguments (X-3); the same happened between two
CLIs. A judging step that never ends looked the same as a hung call; the phase tells them apart.

**Alternatives**: detecting the mismatch afterwards; the server's memory as the record.

**Files**: `lib/passes.exs`, `lib/runner.exs`, `lib/repl/evaluator.exs` (`:progress`, `:cancelled?`), `lib/dispatch.exs`, `lib/pipeline.exs`,
`lib/serve_project.exs`; tests `test/passes_test.exs`, `test/serve_project_test.exs`.

**Earlier**: commit f59d4d8 (`eval/cancel`).

## Notes

- `eval/cancel` does not undo what a `writes` function already did (`scope.md`)
- A scan cannot be stopped (`scan/cancel` is only an idea)
- OCaml and Haskell do not print `XT_CALLED` yet, so their phase stays `calling`
- Verified: not yet verified cold (written from the code, 2026-10-19)
