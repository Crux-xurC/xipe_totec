# `lib/repl/language/ocaml.exs`

OCaml's declaration: extension `ml`, REPL the plain `ocaml` toplevel with `embody.ml`, build tool `dune` (`dune-project`), scanner
`Scanner.Ocaml`; `launch_opts/3` writes the toplevel's init file (embody, the project's files, and for dune the dependencies and aliases).
The adapter is `lib/repl/ocaml/launch.exs`, `lib/repl/ocaml/eval_template.exs` and the iex scan / field_drip it delegates to.

**Decisions homed here**: [D-ocaml-adapter](#d-ocaml-adapter)
**Takes part in**: D-embody ([`lib/repl/embody.exs`](lib-repl-embody.exs.md)), D-language-adapter
([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md))

<a id="d-ocaml-adapter"></a>

## D-ocaml-adapter — the toplevel's own `Toploop`, files loaded without effects, dune by its directives

**Decided** (2026-09-26 to 2026-09-27, crux; checked on OCaml 5.5.0, dune 3.23.1):

- **The plain `ocaml` toplevel**, not `utop`; `embody.ml` evaluates the text of the call through the toplevel itself
  (`Toploop.use_input`), so type and syntax errors are reported in the toplevel's own words. Loading `ocamlcommon.cma` would be a second
  copy of the compiler whose errors are not the toplevel's
- **One entry**: `Embody.run "<id>" "xt_<id>" <ms> "<let xt_<id> = M.f (a) (b);;>" <prev>;;`. The call travels as a string, so an
  unclosed argument cannot leave the toplevel waiting for more
- **`repr`**: the displayed value is evaluated again and compared with `=`: equal → `exact`, else `unsupported` (`<fun>`, `<cycle>`,
  `<abstr>`, inline records whose display does not read back). No `binary` yet; `compare` has no float tolerance
- **Time limit** by `Unix.setitimer` (SIGALRM); **no memory limit** (a wedged toplevel is killed with its group); SIGINT stops the phrase
  only → `interruptible: true`
- **Loading the project**: each `.ml` as the module its file name gives, from copies with top-level expressions and `let ()` / `let _`
  blanked (newlines kept, so lines match); files that fail are retried after the others until nothing more loads (no `ocamldep`)
- **dune**: `dune ocaml top` (run inside the toplevel, so in the project's environment) gives `#directory` / `#load` lines; those under the
  project's own root are dropped (loading its own `.cma` would run its effects) and its code is loaded from source as above. A wrapped
  library gets an alias module (`module Mylib = struct module Words = Words … end`) from its `dune` file, once its members are loaded. A
  failing `dune ocaml top` does not stop loading the sources

**Why**: borrowing the toplevel's own parser, type checker and printer gives types with values and finite displays (depth limits,
`<cycle>`) for free, with no per-target code. The project's own effects must not run (D-source-sanitize).

**Alternatives**: `utop`; ocamllsp for scanning (no `callHierarchy`, cross-file references need an index not in nixpkgs) — text scanning
is enough (D-scanners); loading the project's own `.cma`.

**Files**: `lib/repl/language/ocaml.exs` (`launch_opts/3`, `dune_aliases/2`), `lib/repl/ocaml/launch.exs`,
`lib/repl/ocaml/eval_template.exs`, `lib/scanner/ocaml.exs`, embody's `embody.ml`; tests `test/ocaml_adapter_test.exs`,
`test/live/repl_ocaml_test.exs`; fixtures `test/fixtures/ocaml_sample/`, `test/fixtures/ocaml_dune/`.

**Earlier**: `Old.md` §38, §42, §43.

## Notes

- Not supported (`範囲.md`): files needing ppx, two files of the same name, one `dune` file with several libraries (no aliases),
  `(wrapped false)` and a library's own `x.ml` (no alias needed)
- dune builds into the project (`_build/`) — a departure from "nothing is written into the target", like elixir-ls's `.elixir_ls/`
- Verified: not yet verified cold (written from the code, 2026-10-19)
