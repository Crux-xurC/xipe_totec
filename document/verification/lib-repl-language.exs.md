# `lib/repl/language.exs`

The behaviour of a language's self-declaration (`lib/repl/language/<name>.exs`, the file name is the language's name): its extensions,
its REPL, its build tools, its scanners, its REPL adapter, and how to boot the REPL for a project.

**Decisions homed here**: [D-language-adapter](#d-language-adapter), [D-map-only-language](#d-map-only-language)
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

**Alternatives**: extensions declared by FieldDrip (`extensions/0` there, the first plan) — its role has nothing to do with
files; a table of extensions inside `SurfaceTable` (the stopgap it replaced).

**Files**: `lib/repl/language.exs`, `lib/repl/language/{elixir,ocaml,haskell}.exs`, `lib/info.exs` (`refresh_languages`,
`language_module`), `lib/repl/evaluator.exs`; tests `test/repl_evaluator_test.exs` (a toy language), `test/info_test.exs`.

<a id="d-map-only-language"></a>

## D-map-only-language — a language declared without a REPL is scanned, never evaluated

**Decided** (2026-11-17, crux; JavaScript and TypeScript the first; Go and PHP 2026-11-20):

- **The declaration leaves out `repl/0`, `adapter/0` and `launch_opts/3`** (optional callbacks; `Repl.Language.evaluated?/1`).
  `xipe refresh -l` records its REPL as `null` in `info.json`'s `language_repls`; `Info.map_only?/2` reads that
- **Its files are scanned** like any other's: cards, links, `search`, `graph/*`, the surface table (`repl` empty)
- **`row/add` refuses its functions** (`invalid_params`, "… is a map-only language: its functions are scanned (cards, links), not
  evaluated"): the language is the file's extension's, and the row is refused only when every language declaring that extension is
  map-only. **`eval` leaves a row of it `not_run`** with the same reason (a row made before its language became map-only), and the other
  languages of the project evaluate as usual. `Runner` also refuses to boot a REPL for such a language (`map_only`)
- JavaScript and TypeScript (`lib/repl/language/{javascript,typescript}.exs`) share `Scanner.JavaScript`, a text scanner: modules are
  paths without their extension; top-level `function`s and functions bound to `const` / `let` / `var`; a file that is one function
  expression called at once (`(function (root) { … })(this);`, the browser-script pattern) has its body read as the top level; links
  from same-module names, relative ES imports (named, aliased, default, namespace) and `require`. Build tools pnpm, yarn, bun, npm
- **Go and PHP** (2026-11-20, crux: their maps complete Xipe Totec's languages for now; their drivers are left to the users,
  `evolving.md` §8) are read by **their own parsers**, run from the target's toolchain once per scan (P10): Go's by `go run`
  (`lib/scanner/go/scan.go`, `go/parser` from the standard library, from its own directory: no module, nothing fetched; `GOFLAGS`,
  `GOWORK`, `GOPROXY` neutralised), PHP's by `php` (`lib/scanner/php/scan.php`, `token_get_all` with `TOKEN_PARSE`: PHP's parser checks
  the file, nothing of it runs). Go: a package by its import path (the nearest `go.mod`'s `module` and the directory), functions and
  methods `T.M`, `vendor/`, `testdata/`, `init`, `_` left out; links through the own package, an import's name or alias, the receiver.
  PHP: a class's methods by the class's full name, functions by the namespace (`\` the global one), closures and anonymous classes left
  out, `vendor/` left out; links as PHP resolves names, without case (`use`, `use function`, the namespace and the global fallback,
  `self::`, `static::`, `parent::`, `$this->`). Both: `anykey` `nil` (no overloads); a name two files define (Go's build-tag variants, PHP's
  guarded helpers) is one card, the first file's, and each file is told in the scan's `link_failures`. Build tools go (`go.mod`) and
  composer (`composer.json`) only say what the project is

**Why**: `document/evolving.md` §2.4 — the map is worth having on its own, and for JavaScript / TypeScript evaluation is set aside
(§4.1, §6): loading a module without its top level would need TypeScript's compiler API taken from the target, a special case on Xipe
Totec's side for the language of the surface. Refusing at `row/add` says it when the row is made, not at evaluation.

**Alternatives**: `repl/0` returning `nil` with stub adapters (a language would look evaluable until a pass failed); refusing only at
`eval` (rows that can never run would pile up); a separate list of map-only languages in `info.json` (a second place for what the
declaration already says); typescript-language-server as the scanner (kept for later as a `Scanner.Lsp` dialect, D-scanners: the text
scanner needs nothing installed). For Go and PHP: gopls and phpactor (servers to install; phpactor has no call hierarchy), and text
scanners (the languages' own parsers come with their toolchains, as F#'s, Scala's and Java's do; JavaScript's has no parser in Node).

**Files**: `lib/repl/language.exs`, `lib/info.exs` (`map_only?/2`), `lib/dispatch.exs` (`row/add`), `lib/runner.exs` (`place`,
`repl_opts`), `lib/repl/language/{javascript,typescript,go,php}.exs`, `lib/scanner/javascript.exs`, `lib/scanner/go.exs` with `go/scan.go`,
`lib/scanner/php.exs` with `php/scan.php`; tests `test/map_only_language_test.exs`, `test/javascript_scanner_test.exs`,
`test/scanner_go_test.exs`, `test/scanner_php_test.exs`, `test/live/scan_map_test.exs` (the real parsers), `test/info_test.exs`; fixtures
`test/fixtures/js_sample/`, `test/fixtures/go_sample/`, `test/fixtures/php_sample/`.

**Seen on tezcatl's own code** (2026-11-17, a copy of its tree, a copy of Xipe Totec with its own `tables/`): 1664 nodes, 1218 links
(Elixir and JavaScript; Elixir alone was 496 and 533). Before the wrapper rule, `lib/` (141 files wrapped in one function) gave
nothing. Calls between wrapped files go through globals (`Tezcatl.config.load(…)`) and are not links.

## Notes

- Elixir: build tool `mix` (`mix.exs`) → `iex -S mix`; otherwise scripts-mode, `iex` with sanitized copies `-r`'d (D-source-sanitize);
  scanners `Scanner.Lsp.Elixir` then `Scanner.Elixir`
- Verified: not yet verified cold (written from the code, 2026-10-19)
