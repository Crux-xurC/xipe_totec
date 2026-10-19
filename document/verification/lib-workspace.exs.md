# `lib/workspace.exs`

Which project a command acts on, and where its files live: choosing a project (`xipe choice project`), making its table again
(`xipe table generate`), resolving the target of every other command. `lib/project_registry.exs` is the registry under it (3-digit ids
matched by `project.json`).

**Decisions homed here**: [D-workspace](#d-workspace)
**Takes part in**: D-session-record ([`lib/session.exs`](lib-session.exs.md)), D-surface-table ([`lib/surface_table.exs`](lib-surface_table.exs.md)),
D-project-env ([`lib/project_env.exs`](lib-project_env.exs.md))

<a id="d-workspace"></a>

## D-workspace — per-project data in Xipe Totec's own `tables/`, nothing in the target

**Decided** (2026-09-23 design, 2026-09-24 implementation, crux):

- **Every per-project file is under `tables/project/<id>_<name>/`**: `project.json` (the match key and the project's settings), `table`
  (the surface table), `book.jsonl` (the Book), `env.json` (the environment's cache), `passes/`. **Nothing is written into the target
  project**, and nothing is relative to the working directory
- **Each project has its own Book**: scanning one never touches another's nodes, rows or classifications
- **The id**: 3 digits (`"001"` …), a token a person types back, not a Book row id (those are ULIDs). `000` is reserved and never assigned.
  The next id is the largest + 1, **never a gap**, so a stale reference to a removed project never resolves to a newer one
- **The match key is `project.json`'s `path`**, `Path.expand/1`-normalized; `<name>` in the directory is for people only (two paths can share
  a basename). A `project.json` that is not readable JSON is refused by name, and the path is not registered again under a new id
- **Choosing is its own act**: `choice project <path>` registers if new (and makes the table), then selects it (`tables/selection.json`).
  Every other command resolves: an explicit `<dir>` (which must be registered — `scan` and `eval` never register silently) > the running
  session's project > the selected one; none selected is an error pointing at `choice project`
- `tables/` is per-machine data with absolute paths: git-ignored

**Why**: a Book relative to the working directory was shared by every project — scanning B tombstoned A's nodes and their classifications
(found 2026-09-24). Keeping data on Xipe Totec's side also avoids dirtying the target and needs no write permission there to remove it.

**Alternatives**: `book.jsonl` in the working directory or the target; a `:files` table inside the Book (§21.3); an index file of projects
(the directory walk is enough); the selection in `info.json` (it is machine-local).

**Files**: `lib/workspace.exs`, `lib/project_registry.exs`, `main.exs`, `.gitignore`; tests `test/workspace_test.exs`,
`test/project_registry_test.exs`.

**Earlier**: `Old.md` §24.1, §24.2, §24.6, §27-5, §31.

## Notes

- Difference from the documents: `Old.md` §24 / §31 keep the selection in `info.json`'s `project`; the code keeps it in
  `tables/selection.json`
- Two CLIs registering two new projects at the same moment may take the same id (no lock; a known issue in `work_history/課題.md` §4)
- Verified: not yet verified cold (written from the code, 2026-10-19)
