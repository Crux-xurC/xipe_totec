# `lib/project_config.exs`

A project's own settings, in its `tables/project/<id>_<name>/project.json` beside the registry's `path`, over Xipe Totec's `defaults.json`
and, under that, values built in: `env.path`, `env.refresh`, `eval.timeout`, `eval.boot_timeout`. Read and written by `xipe config`,
`config/set` and `dialogue update`.

**Decisions homed here**: [D-project-config](#d-project-config)
**Takes part in**: D-project-env ([`lib/project_env.exs`](lib-project_env.exs.md)), D-dialogue-do ([`lib/dialogue/do.exs`](lib-dialogue-do.exs.md)),
D-hang-handling ([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md))

<a id="d-project-config"></a>

## D-project-config — settings per project, over defaults that are never rewritten from a dialogue

**Decided** (2026-10-13, crux; the limits as settings were planned in rev.2 §5):

| Key | May be | Default | Means |
|---|---|---|---|
| `eval.timeout` | 100–600000 ms | 5000 | how long one calc row may run; over it the row is `timeout` |
| `eval.boot_timeout` | 1000–1800000 ms | 15000 | how long a pass waits for its REPL (a build included); over it `boot_failed` |
| `env.path` | `prepend` \| `replace` | `prepend` | how a `nix` environment's `PATH` meets Xipe Totec's own (D-project-env) |
| `env.refresh` | `auto` \| `manual` | `auto` | resolve a changed environment on the next scan or eval, or only on `xipe table generate` |

- **Read at the start of a pass**: a change applies from the next pass. Each pass says its limits and the file each came from
  (`eval: limit 5s per row (eval.timeout, <file>), …`) — the line D-log-buffer reads back
- **Only the project's own file is written**: choosing `defaults.json` in `dialogue update` writes the value to the project's file and says
  so; `defaults.json` is every project's, edited by hand only (unknown keys and values out of range are skipped, falling back to the built-in
  values)
- **Values are checked as stored**: a number written as a string (`"7000"`) is read as the number
- **A `project.json` that does not read as JSON, or whose groups are not objects, is not written** (writing back what could be read would
  lose the registry's `path` and the other settings); reading it gives the defaults
- Writing a setting confirms first (`Methods`' `confirm`)

**Why**: the time limits were fixed in code; projects differ (a large Mix project's boot, a slow function). Writing defaults from a dialogue
would change every project behind the person's back.

**Alternatives**: settings in `info.json` (it is about Xipe Totec itself); per-request limits only.

**Files**: `lib/project_config.exs`, `defaults.json`, `lib/runner.exs` (reading at the start of a pass), `lib/outcome_text.exs` (the limits
line), `lib/dispatch.exs` (`config/set`), `main.exs` (`xipe config`); tests `test/project_env_test.exs` (ProjectConfig),
`test/dialogue_update_test.exs`.

**Earlier**: `Old.md` §5; commits 901166d, 44b4c9c.

## Notes

- `eval.max_heap` / `eval.max_per_pass` of rev.2 §5 are not settings (the heap limit is fixed per entry)
- Verified: not yet verified cold (written from the code, 2026-10-19)
