# `lib/pipeline.exs`

Methods made of stages: `pipelines.json` (at Xipe Totec's root) maps a method to its stages, and this module runs them in order, the Book
threaded through. `eval/run` = `["eval"]`, `row/update` = `["edit", "eval"]`.

**Decisions homed here**: [D-pipeline](#d-pipeline)
**Takes part in**: D-command-list ([`lib/runner.exs`](lib-runner.exs.md)), D-serve-project ([`lib/serve_project.exs`](lib-serve_project.exs.md))

<a id="d-pipeline"></a>

## D-pipeline — combinations of commands are data

**Decided** (2026-09-18, crux; stages made real 2026-09-26, "plan B"): a method that combines steps is a list of stage names in
`pipelines.json`, not code of its own. The CLI (`Runner`) and the server (`Serve.Project`) read the same file.

- **`edit`** — pure: sets row `params["id"]`'s `args` (checked as `row/add` checks, `Dispatch.check_args/4`)
- **`eval`** — the Runner's own `eval`, handed in as `ctx.eval` (this module does not depend on the Runner: it depends on this one). It
  evaluates exactly what `eval_params/1` says: `call_ids` as given (a `nil` stays `nil`, so D-command-list refuses it), or the one row `id`
- **`row/update` evaluates that row only** — changing a row's arguments does not evaluate its downstream (D-named-rows-only)
- Stages run in order; the first error stops the rest. Each stage's result is merged into the next, so `row/update` answers with the edited
  row and the evaluation
- **`eval` is last**: the server runs the stages before it at once (`prepare/4`: the edit is saved and broadcast), then queues the
  evaluation. Doing the edit inside the queued pass would lose it — the server folds only the results into the Book of that moment
- Called *around* `Dispatch` (`handles?/1` first): a REPL pass is I/O and seconds long, and `Dispatch` and the server's `GenServer.call`
  are synchronous. `Dispatch` answers `not_implemented` if reached directly

**Why**: `eval/run` and `row/update` are the same evaluation; with the combination as data, the one REPL primitive is reused and a third
combination needs no code at the call sites.

**Alternatives**: plan A — `eval/run` as an alias of `eval`, `row/update` written into the Runner; evaluation inside `Dispatch`.

**Files**: `lib/pipeline.exs`, `pipelines.json`, `lib/runner.exs`, `lib/serve_project.exs`; tests `test/pipeline_test.exs`,
`test/runner_test.exs`, `test/serve_project_test.exs`.

**Earlier**: `Old.md` §15, §37.1–37.2, §54 (`eval_params` keeps `nil`).

## Notes

- `pipelines.json` is read relative to the code (`__DIR__`), not the working directory: the server may run from anywhere
- Rows being evaluated cannot be edited (`row_in_pass`, D-passes): the `edit` stage refuses them
- Verified: not yet verified cold (written from the code, 2026-10-19)
