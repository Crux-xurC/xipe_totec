# `lib/address.exs`

An address: a set of columns (`file`, `module`, `name`, `anykey` / `arity`, `row`), each an optional condition, combined to narrow down.
Shared by `card/get`, `card/search`, `node/resolve` and the graph methods.

**Decisions homed here**: [D-address](#d-address)
**Takes part in**: D-card-shape ([`lib/dispatch.exs`](lib-dispatch.exs.md)), D-references-list ([`lib/graph_query.exs`](lib-graph_query.exs.md))

<a id="d-address"></a>

## D-address — columns as filters, never a delimited string

**Decided** (2026-09-17, spec §6.1; hardened 2026-10-10):

- An address is an object of columns, never a delimiter string: `{"file": "lib/shop/price.ex", "name": "add_tax", "arity": 2}`. It matches
  nodes (joined through their sheet for `file`) or one calc row by id (`row`). One match is the target, several are candidates — the caller
  decides what that means for its answer
- `arity` is another name for `anykey`
- **Columns not implemented are refused** (`type`, `hier`: `unsupported_column`) rather than matching everything
- **A value that cannot be a key is refused** (`anykey` / `arity` neither integer nor string — `null` from a `$n` that named nothing, a list,
  an object): `bad_value`, answered `invalid_params`, nothing searched. It used to raise and take the server down
- `graph/neighbors` / `graph/export` take the address nested (`{"address": …, "depth", "direction"}`); `card/get` takes it flat

**Why**: one resolver for every method that names a function; a loud refusal is better than a silently broad set of candidates (the same
reasoning as an empty `call_ids`, D-command-list).

**Alternatives**: `{table, id}` addresses; delimited strings.

**Files**: `lib/address.exs`, `lib/dispatch.exs`, `lib/graph_query.exs`; tests `test/address_test.exs`.

**Earlier**: `Old.md` §9, §56.1.

## Notes

- Verified: not yet verified cold (written from the code, 2026-10-19)
