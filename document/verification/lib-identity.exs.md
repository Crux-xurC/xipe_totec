# `lib/identity.exs`

The rescan identity rule: an existing id is reused only on an exact natural-key match — a sheet by its path, a node by its module, name
and anykey.

**Decisions homed here**: [D-identity](#d-identity)
**Takes part in**: D-store ([`lib/store.exs`](lib-store.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md))

<a id="d-identity"></a>

## D-identity — surrogate ids, exact natural keys, no revival

**Decided** (2026-09-16, the minimal rule of rev.2's fix E):

- **IDs are surrogate keys** (ULIDs, `lib/id.exs`), names are natural keys (P3). A project's id in the registry is something else: a
  3-digit number a person types back (D-workspace)
- **A rescan keeps an id only on an exact match**: a sheet by `path`; a node by `module`, `name` and `anykey` (Elixir's arity). Without
  this, every rescan gave every node a new id and every calc row became a reference error
- **What is not found in a scan is removed**: its node, sheet and links are deleted from the Book (the Store appends `deleted: true`); calc
  rows stay, pointing at a node that is gone (`show`: `(node gone)`, `row/list`: `linked: false`, evaluation: not run)
- **No revival**: a function that comes back — after a half-typed save, a commented-out block, a branch switch — gets a new id, and its
  effect is `unknown` again. A row is made again (D-referential-transparency: it gives the same value)
- A renamed or moved function, or one whose arity changed, is another function

**Why**: identity must be predictable; a fuzzy match (body hashes, `needs_review`) was out of scope, and a guess would silently attach old
rows to a different function.

**Alternatives**: the first design's full matching (body hash, review states) — not implemented.

**Files**: `lib/identity.exs`, `lib/book.exs` (`find_node_by_natural_key/4`), `lib/scanner.exs` (`put_defs`, carrying `effect` and
`arities` over), `lib/project.exs` (removing what is gone); tests `test/scanner_test.exs`, `test/project_test.exs`.

**Earlier**: `document/scope.md` ("Source and table drifting apart").

## Notes

- Difference from earlier designs: the first design named the key as (path, module, name, arity); the code's node key has no path —
  `(module, name, anykey)`
- Verified: not yet verified cold (written from the code, 2026-10-19)
