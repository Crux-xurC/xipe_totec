# `lib/repl/language.exs`

The behaviour of a language's self-declaration (`lib/repl/language/<name>.exs`, the file name is the language's name): its extensions,
its REPL, its build tools, its scanners, its REPL adapter, and how to boot the REPL for a project.

**Decisions homed here**: [D-language-adapter](#d-language-adapter)
**Takes part in**: D-surface-table ([`lib/surface_table.exs`](lib-surface_table.exs.md)), D-scanners
([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md)), D-languages-per-pass ([`lib/runner.exs`](lib-runner.exs.md))

<a id="d-language-adapter"></a>

## D-language-adapter — four swappable modules and one declaration per language

**Decided** (2026-09-18 to 2026-09-27):

- **The REPL adapter is four modules**, passed to `Repl.Evaluator.run_pass/3` and never chosen by it:
  - `launch` — the message to start the REPL: `argv`, `env`, `cwd`, `files`, `ready_pattern`, `ready_probe`, `exit_input`, `interruptible`
  - `eval_template` — the text for one entry
  - `scan` — `Scan.<transport>.<REPL>`: the noise of that transport and REPL removed (two axes, since neither name alone covers both)
  - `field_drip` — reading the `key=value` body
- **The declaration** (`Repl.Language`): `extensions/0`, `repl/0` (one REPL per language: `iex`, `ocaml`, `ghci`), `build_tools/0` (by
  priority, each with marker globs; the first matching at the project's root is the `build_tool`), `scanner/0` (one or several by
  preference), `adapter/0`, `launch_opts/3` (`{opts, cleanup}`; the build tool changes how the REPL boots, never which adapter reads it)
- **Placing a module does nothing until `xipe refresh -l` registers it in `info.json`** (P4: an implementation half-written is not a
  supported language)
- What every language must keep (the markers, `repr`'s meaning, one write per block, closed expressions, `XT_READY`) is in
  `document/repl-adapter-guide.md` and embody's `ReadMe.md`

**Why**: the Evaluator was Elixir-only by its aliases (2026-09-18, crux's review); making the four modules options and proving it with a
made-up language in the tests made the evaluation path language-neutral. Facts about a language that are neither building a call nor
reading a body (extensions, build tools, embody) needed a place of their own.

**Alternatives**: extensions declared by FieldDrip (`extensions/0` there, the first plan of §24.5) — its role has nothing to do with
files; a table of extensions inside `SurfaceTable` (the stopgap it replaced).

**Files**: `lib/repl/language.exs`, `lib/repl/language/{elixir,ocaml,haskell}.exs`, `lib/info.exs` (`refresh_languages`,
`language_module`), `lib/repl/evaluator.exs`; tests `test/repl_evaluator_test.exs` (a toy language), `test/info_test.exs`.

**Earlier**: `Old.md` §10.6–10.9, §13, §25.4, §34.1–34.2.

## Notes

- Elixir: build tool `mix` (`mix.exs`) → `iex -S mix`; otherwise scripts-mode, `iex` with sanitized copies `-r`'d (D-source-sanitize);
  scanners `Scanner.Lsp.Elixir` then `Scanner.Elixir`
- Verified: not yet verified cold (written from the code, 2026-10-19)
