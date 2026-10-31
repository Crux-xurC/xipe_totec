# `lib/scanner/lsp.exs`

A scanner over a language server: per file, `textDocument/documentSymbol` gives the definitions, and per definition
`prepareCallHierarchy` + `callHierarchy/outgoingCalls` give what it calls; callees are matched to nodes by the natural key, not by position.
What is language-specific is a thin dialect (`Scanner.Lsp.Elixir`). The server is reached through tezcatl's `/lsp` relay, else started by
Xipe Totec itself over stdio. `lib/scanner.exs` is the behaviour every scanner implements; `lib/scanner/elixir.exs`, `ocaml.exs`,
`haskell.exs` are the others.

**Decisions homed here**: [D-scanners](#d-scanners)
**Takes part in**: D-identity ([`lib/identity.exs`](lib-identity.exs.md)), D-references-list ([`lib/graph_query.exs`](lib-graph_query.exs.md)),
D-language-adapter ([`lib/repl/language.exs`](lib-repl-language.exs.md))

<a id="d-scanners"></a>

## D-scanners — each language's scanners in order of preference; cards follow the disk

**Decided** (2026-09-22 direction, implemented by 2026-09-27; crux on OCaml and Haskell):

- **A language declares its scanners in order** (`Repl.Language.scanner/0`); `Project.scan_dir/3` uses the first whose `begin/3` accepts and
  records which one read the language's files and why the earlier ones did not (`scan/run`'s `scanners`, with `via: relay | stdio`)
- **Elixir**: elixir-ls (`Scanner.Lsp.Elixir`) — through tezcatl's `/lsp` (from the scanner options, the session's record,
  `XIPE_TOTEC_LSP_RELAY`, or the `TEZCATL_*` a tezcatl-started Xipe Totec inherits), else started by Xipe Totec — then Elixir's own parser and
  compiler tracer (`Scanner.Elixir`) when no server is reachable. `XIPE_TOTEC_LSP=off` skips the language server (the tests run so)
- **OCaml and Haskell are read as text** (top-level definitions, comments and strings blanked, calls estimated from names). ocamllsp has no
  `callHierarchy` and its cross-file references need an index not in nixpkgs; "what is needed is the dependencies between the functions a file
  defines" (crux), which the text gives. HLS is not used either
- **Cards follow the disk** (what the REPL will read): a file whose positions differ because the server holds an editor's unsaved text is
  read again by the next scanner (`fallbacks`)
- **Only functions become cards** (Elixir `def`, `defp`, `defdelegate`; not macros, guards or library functions). `defp` nodes are
  `private`: in the list of references, but `row/add` makes no row for them
- A server without `callHierarchyProvider` still gives cards; its modules are listed in `link_failures` and keep their old links

**Why**: P8 — complete alone, a language server only on top; P4 — what a server gives is taken where it answers, not trusted blindly. A
language server reads a project as its compiler does, without Xipe Totec compiling the project.

**Alternatives**: deciding languages and project boundaries through the language server (narrowed to what is needed); an ocamllsp /
HLS dialect; scanning only by compiling.

**Files**: `lib/scanner.exs`, `lib/scanner/lsp.exs`, `lib/scanner/lsp/elixir.exs`, `lib/scanner/elixir.exs`, `lib/scanner/ocaml.exs`,
`lib/scanner/haskell.exs`, `lib/lsp/transport/{relay,stdio}.exs`, `lib/project.exs`; tests `test/scanner_lsp_test.exs`,
`test/scanner_test.exs`, `test/ocaml_adapter_test.exs`, `test/haskell_adapter_test.exs`.

**Earlier**: README ("Structure").

## Notes

- Unsaved edits the server holds: a deleted last function or a change inside a body can be missed (`scope.md`)
- A scan cannot be stopped
- Verified: not yet verified cold (written from the code, 2026-10-19)
