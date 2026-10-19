# `lib/surface_table.exs`

A project's file tree flattened to one row a file — `id`, `path`, `depth`, `language`, `repl`, `build_tool` — which decides the scanner and
the REPL adapter for each file. Made again whole by `xipe table generate` (and on registering), saved as the project's `table`.
`lib/info.exs` keeps the registered languages, their extensions, REPLs and build tools in `info.json`.

**Decisions homed here**: [D-surface-table](#d-surface-table)
**Takes part in**: D-language-adapter ([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-workspace ([`lib/workspace.exs`](lib-workspace.exs.md)),
D-languages-per-pass ([`lib/runner.exs`](lib-runner.exs.md))

<a id="d-surface-table"></a>

## D-surface-table — a table remade whole; languages declare themselves and are registered by hand

**Decided** (2026-09-23 to 2026-09-27, crux):

- **Rows**: every file under the project (not only sources); `depth` from the root; `language` by extension; `repl` the language's REPL;
  `build_tool` the first of the language's build tools whose marker matches at the root (`nil` when none). Rows of different languages may
  carry different build tools
- **Made again whole**, never diffed; the old table is read only to keep each path's `id` (a path keeps its id across reruns). A file added
  later is not scanned or evaluated until `xipe table generate` (it cannot be typed in the window)
- **Languages declare their extensions** (`Repl.Language.extensions/0`), and **only `xipe refresh -l` puts them into `info.json`** — a module
  being present does not make it a supported language (P4). The table reads `info.json`'s `extensions` (extension → the languages declaring
  it)
- **An extension two languages declare gets no language** (`nil`): undecidable is shown as undecided and the file is not read (P9)
- The build tool is decided when the table is made, not at every use
- One project is everything under the registered path (no monorepo boundaries)

**Why**: the scanner and the evaluator had extensions and `mix.exs` written into their code; a table of facts per project, filled from the
languages' own declarations, removes that and is the one place to look.

**Alternatives**: a `:files` table in the Book (§21.3); asking a language server which language a file is (needed only for monorepo
boundaries, which are not handled); extensions written in `SurfaceTable` (the stopgap); collecting declarations on every run; failing
`refresh` on a clash.

**Files**: `lib/surface_table.exs`, `lib/info.exs`, `info.json`, `lib/repl/language/*.exs`, `lib/workspace.exs`, `main.exs` (`xipe refresh`,
`xipe table generate`); tests `test/surface_table_test.exs`, `test/info_test.exs`.

**Earlier**: `Old.md` §21.3, §24.3–24.5, §25.1, §25.4, §26, §29 (the place of `repl` / `build_tool`), §34.

## Notes

- A command to set a row's language by hand (for clashing extensions, files without one) is planned (`scope.md`)
- A table that cannot be read is refused before the command, with how to make it again (commit 3b39709)
- Verified: not yet verified cold (written from the code, 2026-10-19)
