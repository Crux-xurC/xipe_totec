# `lib/repl/source_sanitize.exs`

Loads a scripts-mode Elixir project into iex without running its top-level code: for each file, a small loader in a temp directory
that parses the original, keeps its top-level `defmodule` forms and compiles them at the original path.

**Decisions homed here**: [D-source-sanitize](#d-source-sanitize)

<a id="d-source-sanitize"></a>

## D-source-sanitize — loading the target runs none of its top-level code

**Decided** (2026-09-16 for scanning, 2026-09-18 for evaluation): reading or loading a target never runs its scripts. A `main.exs` that
starts a server as its last statement must not start it because Xipe Totec scanned or evaluated the project.

- Scanning reads the AST (`Code.string_to_quoted`) and compiles only `defmodule` parts
- Evaluating (scripts-mode) gives iex loaders instead of the files (`-r` is a real `Code.require_file` and would run everything); each
  compiles the `defmodule` forms with `Code.compile_quoted(forms, original_path)`, so line numbers, `__ENV__.file` and `__DIR__` stay the
  original's
- The loader defines no module of its own, so the REPL holds only the project's modules
- The same rule in other languages: OCaml loads copies with top-level expressions and `let ()` / `let _` blanked (embody's `load_all`);
  GHCi's `:load` runs no `main`

**Why**: scanning or evaluating must not have the target's side effects; also, compiling into a running application's VM would replace
its code.

**Alternatives**: requiring the files as they are.

**Files**: `lib/repl/source_sanitize.exs`, `lib/repl/language/elixir.exs` (`launch_opts/3` and its cleanup), `lib/scanner.exs`
(`only_defmodules/1`); tests `test/repl_source_sanitize_test.exs`.

**Earlier**: `Old.md` §6 (Fix F), §14.1, §38.2, §42.1.

## Notes

- Files load in alphabetical order: a file whose `defmodule` needs another's struct or macro at compile time must come after it (`範囲.md`)
- The original is read when iex boots, not when the loader is written
- Verified: not yet verified cold (written from the code, 2026-10-19)
