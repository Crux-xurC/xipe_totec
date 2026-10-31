# `lib/graph_query.exs`

`graph/neighbors` (a breadth-first walk of the static call graph to a depth, in, out or both) and `graph/export` (the same as `mermaid`,
`dot`, `json` or `doctest`). Built on the `:links` rows (`node --to--> ref`); "incoming" is a reverse lookup over `ref`. Not the `⟦id⟧`
graph of calc rows.

**Decisions homed here**: [D-references-list](#d-references-list)
**Takes part in**: D-address ([`lib/address.exs`](lib-address.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md))

<a id="d-references-list"></a>

## D-references-list — who calls a function comes from the links; rewriting is the editor's

**Decided** (2026-09-22, crux): the second pillar of the README was **linked editing** — writing a rename made on a card back to the source
(`edit/propose`, `edit/apply`). It is withdrawn. Xipe Totec goes as far as **the list of references**; the actual rewriting (a rename) is
the editor's, through its language server.

- The list is a plain query: `graph/neighbors` with `direction: "in"`, `depth: 1` over `:links`
- **A full scan before asking** keeps it consistent: nothing unscanned is missing and nothing stale from old Book lines is used — so no
  special dialogue, diff tracking or labelling is needed
- `edit/propose` / `edit/apply` stay reserved names answered `not_implemented`
- `graph/export --format doctest` writes from the values in the table; it does not evaluate again nor look at existing files

**Why**: P7 — the input experience is the client's; editors already rename well. With links extracted by every scanner, the list costs
nothing extra.

**Alternatives**: linked editing; a trace-based list (the trace table is frozen); a three-step dialogue with diff ranges and `A`/`B` labels
(unneeded once a full scan precedes the query).

**Files**: `lib/graph_query.exs`, `lib/address.exs`, `lib/dispatch.exs`; tests `test/graph_query_test.exs`.

## Notes

- Not decided: the doctest export's fresh path (evaluate each row alone, then write) and how it ranks against an existing doctest file
- A function called through its default arguments links only once `arity/set` declares it (D-arity-set)
- Verified: not yet verified cold (written from the code, 2026-10-19)
