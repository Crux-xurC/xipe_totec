# `lib/runner.exs`

Runs a command list: each command in turn against the Book, `$<n>.<path>` references resolved just before it runs. A method `Dispatch`
knows goes there; one `pipelines.json` names goes to `Pipeline`; the pseudo-method `eval` evaluates — grouped by language, one REPL per
language, in the project's environment and under its time limits, recorded in `passes/` while it runs.

**Decisions homed here**: [D-command-list](#d-command-list), [D-languages-per-pass](#d-languages-per-pass)
**Takes part in**: D-pipeline ([`lib/pipeline.exs`](lib-pipeline.exs.md)), D-effect-classes ([`lib/core.exs`](lib-core.exs.md)), D-passes
([`lib/passes.exs`](lib-passes.exs.md)), D-project-env ([`lib/project_env.exs`](lib-project_env.exs.md)), D-project-config
([`lib/project_config.exs`](lib-project_config.exs.md))

<a id="d-command-list"></a>

## D-command-list — input → command list → action

**Decided** (2026-09-18, crux; extended to 2026-10-09): input is not turned into actions directly. Every entrance (the CLI's `xipe do`,
the window's `input`, the server's pass queue, a dialogue's finished answer) builds a **command list** — `[%{"method", "params"}]`, the
wire shape, JSON-safe — and `run/4` is the one action.

- **References between commands**: a string `"$<index>.<path>"` (0-based, into an earlier command's result) is resolved at run time,
  just before its command; until then the list is plain data. A number segment indexes a list; a segment names a string key, else an
  atom key (Book rows). Inside a larger string only a whole `⟦$0.id⟧` is replaced. A reference into a failed command, or a missing path,
  is `nil`
- **A failing command does not stop the list**; each reports its own error
- **`eval` is the one primitive that uses a REPL** (not a `Dispatch` method: `Dispatch` is synchronous Book-in-Book-out). `eval/run` and
  `row/update` reach it through `Pipeline`'s `eval` stage; the server's pass queue runs it too
- **`call_ids`**: left out or `[]` means every row of the Book; **written but empty** (`nil`, or a list holding `nil` — a `$n` into a
  failed command) is refused (`invalid_params`), nothing evaluated
- `include_writes` accepts `true` and the string `"true"` (`xipe do`'s values are strings)
- Rows not reaching the plan come back as `not_run` with their reason (`Core.exclusion_reason/3`)

**Why**: one action layer used by the CLI, the server and the dialogues; references let one list say "add a row, classify it, evaluate
it" before the row's id exists. The empty `call_ids` case was found when a failed `row/add … -- eval call_ids=$0.id` evaluated the whole
Book, writes included with `include_writes`.

**Alternatives**: the CLI turning arguments straight into calls (the state before); stopping the list at the first failure — not
changed.

**Files**: `lib/runner.exs` (`run/4`, `substitute_command/2`), `lib/command_line.exs` (the CLI's lists), `lib/input.exs` (the window's),
`lib/dispatch.exs`; tests `test/runner_test.exs`.

<a id="d-languages-per-pass"></a>

## D-languages-per-pass — the rows of a request are evaluated by language, side by side

**Decided** (2026-09-26, crux): the requested rows are grouped by the language of their function's file (call → node → sheet → path →
the surface table's `language`). Each group gets its own REPL — its adapter, boot and environment — and with two groups or more they run
in parallel (`Task`); the results are folded once at the end, all under one pass id.

- A single-language project: every row is that language, however its file is recorded (the old one-REPL pass, in the calling process)
- **A reference across languages is not evaluated**: `not_run` "⟦id⟧ is a <language> row -- a reference across languages isn't supported
  yet". Values are stored as their REPL printed them, and nothing converts them
- One language's REPL failing to start makes that language's rows `not_run`; the others' results come back; all failing is `eval_failed`
- Each group reads the project's `eval.timeout` / `eval.boot_timeout` at its start and reports them once (`limits`), and starts in the
  project's environment (`env` status)

**Why**: a project mixing languages (Elixir calling an OCaml executable) was refused as a whole, even for rows of one language
(`multiple_languages`); BEAM runs several REPLs side by side easily.

**Alternatives**: one language per pass (the earlier temporary limit); converting values across languages now — designed only
(a conversion step chosen by the referenced row's `result_type`).

**Files**: `lib/runner.exs` (`eval_groups/4`, `run_groups/8`, `run_group/8`, `repl_opts/4`); tests `test/runner_test.exs` (Elixir with a
made-up `.toy` language).

## Notes

- `:language`, `:info` and `:language_modules` are options for tests
- `failure_message/1` turns `boot_failed` into a line with the REPL's last output
- Verified: not yet verified cold (written from the code, 2026-10-19)
