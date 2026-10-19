# `lib/dispatch.exs`

The table of methods that work on the Book alone: as pure as Core (`handle/4` takes a Book and returns one), except `scan/run`, which reads
the source files. It never touches the Store; the caller saves what changed. Reserved, unbuilt methods answer `not_implemented`.
`lib/card_table.exs` is the read-only view `card/list` gives out.

**Decisions homed here**: [D-card-shape](#d-card-shape)
**Takes part in**: D-cli-values ([`lib/command_line.exs`](lib-command_line.exs.md)), D-arity-set ([`lib/core.exs`](lib-core.exs.md)),
D-passes ([`lib/passes.exs`](lib-passes.exs.md)), D-method-criteria ([`lib/methods.exs`](lib-methods.exs.md)), D-address
([`lib/address.exs`](lib-address.exs.md))

<a id="d-card-shape"></a>

## D-card-shape — a card is node + calc rows + links, whatever names it; `card/list` is every function

**Decided** (2026-09-22; `card/list` 2026-10-13):

- `card/get` / `card/search` return each match as a **card** (`compose_card/3`: the node, its calc rows, its links) — for an address naming
  a function and for one naming a calc row (`row=<id>`, which returns that row's card) alike. Before, `row=` returned a bare row: one method,
  two answer shapes
- **`card/list`** gives every function whole (`CardTable`): id, label, module, name, anykey, effect, visibility, `path` (from the project's
  root), `line` (1-based, where the definition starts on disk, as scanned), and the number of calc rows; in file order. `row/list` rows carry
  their function's `path` and `line` too (empty when the function is gone)
- Picking, sorting and following are the reader's (D-method-criteria)
- Shaping cards for people on the CLI is not done here (P7)

**Why**: spec §16.3 says `card/get` returns a card by address; a client should not need to know which kind of address it sent. tezcatl's
table jumps to definitions by `path` and `line`.

**Alternatives**: formatting cards for people in the CLI (written once, withdrawn by crux, 2026-09-22).

**Files**: `lib/dispatch.exs` (`render_match/2`, `compose_card/3`, `card/list`, `row/list`), `lib/card_table.exs`, `lib/methods.exs`; tests
`test/dispatch_test.exs`.

**Earlier**: `Old.md` §20; commit e70e1d1.

## Notes

- `row/add`'s checks (the node exists, the argument count fits — D-cli-values, D-arity-set) and the `row_in_pass` refusals (D-passes) are here
- `line` is from the scan: it drifts when the source changes until the next scan (`範囲.md`)
- Verified: not yet verified cold (written from the code, 2026-10-19)
