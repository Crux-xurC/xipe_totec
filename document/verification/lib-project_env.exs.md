# `lib/project_env.exs`

The environment a project's own tools run in — its REPL and a language server Xipe Totec starts itself — got by the command
`project_env.json` declares for the marker at the project's root, cached in the project's `env.json`.

**Decisions homed here**: [D-project-env](#d-project-env)
**Takes part in**: D-project-config ([`lib/project_config.exs`](lib-project_config.exs.md)), D-sender-contract
([`lib/repl/sender_direct.exs`](lib-repl-sender_direct.exs.md))

<a id="d-project-env"></a>

## D-project-env — a project's environment from a declared command, written as tezcatl's

**Decided** (2026-09-23 design; 2026-10-19 rewritten to tezcatl's form, crux): P10 — evaluation runs in the target's environment. How that
environment is got is declared, one entry per tool, in the same shape as tezcatl's `project_env.json` (its D-project-env), so someone without
Nix adds a line:

```json
{ "timeoutMs": 120000,
  "entries": [
    { "marker": "flake.nix", "command": ["nix", "print-dev-env", "--json"], "format": "nix", "watch": ["flake.nix", "flake.lock"] },
    { "marker": ".envrc",    "command": ["direnv", "export", "json"],       "format": "env" },
    { "marker": "mise.toml", "command": ["mise", "env", "--json"],          "format": "env" } ] }
```

- **The first entry whose marker is at the project's root** is used; its command runs there with Xipe Totec's own environment. Only the
  root is looked at (tezcatl walks up to its FS root; here the root is the one a person registered)
- **Two formats, both JSON**: `env` — `{"NAME": "value" | null}`, values as they are, null unsets; `nix` — `nix print-dev-env --json`'s
  exported variables as `nix develop` takes them (without `HOME`, `TMPDIR`, `TERM` …), `PATH` and `XDG_DATA_DIRS` meeting Xipe Totec's own
  as `env.path` says. `nix develop` itself never runs, so the `shellHook` does not either
- **Cached** in `env.json` with the marker and a hash of the `watch` files (default: the marker) and of the entry itself: a changed file or a
  changed declaration is resolved again — at once with `env.refresh=auto`, else only on `xipe table generate`, with a `stale` warning
  meanwhile. Registration and `xipe table generate` always resolve
- **A failure** (an exit code with its last stderr line, no answer within `timeoutMs`, output not the format) is `env error`; the previous
  environment, else Xipe Totec's own, is used. A cache that cannot be written is only resolved again next time
- The result is a map to add to the spawned process's environment (`false` unsets); the REPL's and the language server's executables are
  looked up on its `PATH` first. A language server reached through tezcatl's relay gets its environment from tezcatl, written the same way
- `watch` is Xipe Totec's own key; tezcatl reads the same shape, ignores it, and asks again only on its `env reload`

**Why**: starting each REPL inside `nix develop` cost 0.3–1.8 s every time and ran shell hooks that print banners; a flake-only
implementation could not serve a version without Nix. Declaring the command keeps Xipe Totec ignorant of the tools, and reading only JSON keeps
to "never parse text for people".

**Alternatives**: wrapping the REPL's argv in `nix develop <root> --command`; the flake as the only source (the form until
2026-10-19); walking up for a marker.

**Files**: `lib/project_env.exs`, `project_env.json`, `lib/project_config.exs`, `lib/runner.exs`, `lib/dispatch.exs` (`scan/run`),
`lib/repl/sender_direct.exs`, `lib/lsp/transport/stdio.exs`, `main.exs` (`resolve_env`); tests `test/project_env_test.exs`.

**Earlier**: commit 0bb3e88.

## Notes

- A cache from before `project_env.json` has no `source` and is read as a flake's; its hash differs, so it is resolved once again
- Verified: not yet verified cold (written from the code, 2026-10-19)
