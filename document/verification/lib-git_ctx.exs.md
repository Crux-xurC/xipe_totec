# `lib/git_ctx.exs`

The git provenance recorded on every evaluated row: `commit`, `commit_at`, `dirty`, read by the caller (the CLI, or the server at the start
of a pass) and handed to `Core.apply_results/3`. Core and the Evaluator never run git.

**Decisions homed here**: [D-git-provenance](#d-git-provenance)
**Takes part in**: D-plan-run-apply ([`lib/core.exs`](lib-core.exs.md))

<a id="d-git-provenance"></a>

## D-git-provenance — each evaluated row records where its code came from

**Decided** (2026-09-18, fixed for `xipe do` 2026-09-19): `git rev-parse HEAD`, `git show -s --format=%cI HEAD` and
`git status --porcelain` give the commit, its time and whether the tree is dirty. A directory that is not a repository, or no `git`, gives
`nil` for all three, and evaluation goes on.

- Every entrance that evaluates passes it (`xipe eval`, `xipe do … -- eval`, the server's passes) — `xipe do` used to drop it

**Why**: P2 — reproducibility first: a value means little without the code it came from.

**Alternatives**: none recorded.

**Files**: `lib/git_ctx.exs`, `main.exs`, `lib/serve_project.exs`, `lib/core.exs`.

**Earlier**: `Old.md` §11.6, §16.5 (2); README P2.

## Notes

- `dirty` says the tree differs from the commit, not which files; the evaluated code is the disk's
- Verified: not yet verified cold (written from the code, 2026-10-19)
