# `lib/project_config.exs`

A project's own settings, in its `tables/project/<id>_<name>/project.json` beside the registry's `path`, over Xipe Totec's `defaults.json`
and, under that, values built in: `env.path`, `env.refresh`, `eval.timeout`, `eval.boot_timeout`. Read and written by `xipe config`,
`config/set` and `dialogue update`.

**Decisions homed here**: [D-project-config](#d-project-config), [D-eval-wrap](#d-eval-wrap)
**Takes part in**: D-project-env ([`lib/project_env.exs`](lib-project_env.exs.md)), D-dialogue-do ([`lib/dialogue/do.exs`](lib-dialogue-do.exs.md)),
D-hang-handling ([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md))

<a id="d-project-config"></a>

## D-project-config — settings per project, over defaults that are never rewritten from a dialogue

**Decided** (2026-10-13, crux; the limits as settings had been planned):

| Key | May be | Default | Means |
|---|---|---|---|
| `eval.timeout` | 100–600000 ms | 5000 | how long one calc row may run; over it the row is `timeout` |
| `eval.boot_timeout` | 1000–1800000 ms | 15000 | how long a pass waits for its REPL (a build included); over it `boot_failed` |
| `env.path` | `prepend` \| `replace` | `prepend` | how a `nix` environment's `PATH` meets Xipe Totec's own (D-project-env) |
| `env.refresh` | `auto` \| `manual` | `auto` | resolve a changed environment on the next scan or eval, or only on `xipe table generate` |
| `eval.wrap` | a JSON list of non-empty words | `[]` | a command put in front of the REPL's ([D-eval-wrap](#d-eval-wrap)) |

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

**Earlier**: commits 901166d, 44b4c9c.

## Notes

- `eval.max_heap` / `eval.max_per_pass`, also planned, are not settings (the heap limit is fixed per entry)
- Verified: not yet verified cold (written from the code, 2026-10-19)

<a id="d-eval-wrap"></a>

## D-eval-wrap — a command put in front of the REPL's, per project

**Decided** (2026-11-25, crux): a project's `eval.wrap` — a list of words, `[]` by default — is put in front of the REPL's command, so
the REPL is started by it: `["citl", "run", "<name>", "--"]` starts it inside [forbidden](https://github.com/Crux-xurC/forbidden)'s wall
with [Citlalpol](https://github.com/Crux-xurC/Citlalpol) behind its door, `["forbidden", "run", "--"]` without any exit. Xipe Totec knows
nothing of what the words are.

- **Written as JSON text** (`xipe config 'eval.wrap=["citl","run","myapp","--"]'`, `dialogue update`); stored as a list; shown as JSON
- **Read as a pass starts**, like the limits; each pass says it after the limits: `eval: the REPL starts behind `…` (eval.wrap, <file>)`
- **Where it acts**: `Runner` puts it in the launch options, `Evaluator` sets it on the launch message as `"wrap"` (whatever language
  adapter built the message), `Sender.Direct` resolves its first word — on the project environment's `PATH`, then on Xipe Totec's own
  (a wall is this machine's tool; `env.path` `replace` would hide it) — and starts `wrap ++ [REPL | args]` in the same process group.
  Not found: the pass fails before anything starts (`executable_not_found … (eval.wrap)`)
- **Nothing else changes**: the REPL is driven over its stdin / stdout as before, and a timeout's SIGINT / SIGKILL to the process group
  reaches it through forbidden's ordinary mode (`unshare --fork` keeps the group). Not `--strict`: bubblewrap starts a new session (the
  group's signals do not reach the REPL) and clears the environment (the project's is lost)
- Tried 2026-11-25 with `forbidden run --` on the calc sample: a row reaching `1.1.1.1:80` gave its value outside the wall and failed to
  connect inside; a row over its time limit was `timeout`, nothing left running

**Why**: Xipe Totec is not a sandbox, and keeps it so (`document/scope.md`, "Not a sandbox"); what a developer wants to bound is what the
code being evaluated does — its network — not Xipe Totec itself. The REPL is the one place where that code runs, and a generic prefix keeps
Xipe Totec ignorant of Citlalpol (no dependency; any wall or wrapper fits).

**Alternatives**: putting the whole of `xipe start` inside the wall (its :4200 would be inside the wall's loopback, out of reach of
tezcatl and the CLI); a Citlalpol-specific setting (names one tool); a hook run before each row to label Citlalpol's records with the
row's id (not now: the wall works without it; it only names the row in the records).

**Files**: `lib/project_config.exs`, `defaults.json`, `lib/runner.exs`, `lib/repl/evaluator.exs`, `lib/repl/sender_direct.exs`,
`lib/outcome_text.exs`; tests `test/project_env_test.exs`, `test/repl_sender_direct_test.exs`, `test/dialogue_update_test.exs`.
