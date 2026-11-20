# `lib/identity.exs`

The rescan identity rule: an existing id is reused only on an exact natural-key match — a sheet by its path, a node by its module, name
and anykey.

**Decisions homed here**: [D-identity](#d-identity), [D-anykey-shape](#d-anykey-shape), [D-node-marks](#d-node-marks)
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

<a id="d-anykey-shape"></a>

## D-anykey-shape — `anykey` tells overloads apart; a node's shape is its argument count

**Decided** (2026-11-20, crux; in since 2026-11-20 for Scala ([D-scala-adapter](lib-repl-language-scala.exs.md#d-scala-adapter)) and
Elixir; C#'s and Java's come with their adapters):

- **In C#, Java and Scala, `anykey` is always the sequence of the parameters' types**, Scala's with the separations between its
  parameter lists kept: `add(a: Int, b: Int)` and `curried(a: Int)(b: Int)` have different `anykey`s. So overloads of one name in one
  type are different nodes, each keeping its id across rescans (D-identity), even when they share a parameter count
- **The number of arguments is a node's *shape***, held apart from `anykey`: a list with one count per parameter list — Elixir's
  `add/2` is `[2]`, Scala's `curried(a)(b)` is `[1, 1]`, `f(a, b)(c)` is `[2, 1]`
- **`row/add` checks a row's arguments against the shape**, no longer against an integer `anykey`
- **Elixir's `anykey` stays the arity (an integer)**, and its shape is filled too (`[arity]`); its ids are unchanged

**Why**: an overload is another function, and a person must be able to address each one; a count alone cannot tell apart overloads with
the same number of parameters (the first C# attempt made them one node, the first). Taking the count out of `anykey` keeps one meaning
per field: `anykey` is identity, the shape is what a call needs.

**Alternatives**: the parameter count as `anykey` (the first C# attempt: overloads sharing a count collapse into one node); the count
plus a disambiguating index (changes with the order in the file, so an id would move to another overload after an edit).

- **How it is held**: a scanner's def carries `shape`; `Scanner.put_defs/3` stores it on the node; `Core.accepted_arities/1` is the
  counts declared with `arity/set`, else the shape's sum, else an integer `anykey`; `row/add`'s refusal names the counts per list
  (`takes 3 (2 + 1, one count per parameter list)`); an entry carries the shape to the adapter (Scala splits the args with it); a node
  whose `anykey` is a sequence of types is labelled with it (`sample.Calc.add(Int, Int)`) and addressed by it (`anykey=(String)`)
- **Scala** writes the types out again from the parser's tree in one form (`List[ Int ]` is `List[Int]`; `(Int)(using Ordering[Int])`;
  `""` for a `def` without lists, shape `[]`), so spacing does not move an id; `Int` and `scala.Int` stay two texts (resolving them needs
  the type checker). The `using` lists are in `anykey`, not in the shape
- **F#'s static members** (2026-11-20) are on this form: the types written out again from F#'s syntax tree (`List< int >` is
  `List<int>`; `int list` and `List<int>` stay two texts), one parenthesized group per curried group (`(float)(Point)`, `()` with shape
  `[0]`); the adapter splits the args into the groups with the shape (`Scale((2.0))((p))`). F#'s module functions keep the count
- **C#'s scanner** (2026-11-20, `lib/scanner/csharp.exs`, on main ahead of C#'s adapter) is on this form: the types written out again
  from the text's tokens in one form (`List< int >` is `List<int>`, `Dictionary<string,int>` is `Dictionary<string, int>`, a tuple's
  element names dropped), with the modifiers C# tells overloads apart by (`(string, out int)`, `(ref double)`; `params` kept to be read);
  `int` and `System.Int32` stay two texts. The shape is one list: `out` parameters left out, optional ones counted, a `params` array one.
  A link from a call picks the overloads of the call's argument count, all of them when several share it
- **Java's scanner** (2026-11-20, `lib/scanner/java.exs`) is on this form: the types written out from the JDK's parser's tree in one
  form (`List< Integer >` is `List<Integer>`, annotations dropped, varargs `int...`), as written (`List` and `java.util.List` stay two
  texts); the shape is the parameter count, a varargs parameter one

**Not decided**: the shape
of the other languages' nodes (OCaml, Haskell, Python, F#'s module functions: no shape, their `anykey` the count or `nil` as before); how `arity/set`
(D-arity-set) reads with a shape of several lists (one list: as an integer anykey, 2026-11-20); type arguments of a generic method whose type appears in no parameter.

**Files**: `lib/scanner.exs` (`put_defs/3`), `lib/scanner/elixir.exs`, `lib/scanner/lsp/elixir.exs`, `lib/scanner/scala.exs`, `lib/scanner/fsharp.exs`, `lib/scanner/csharp.exs` (filling
the shape), `lib/core.exs` (`accepted_arities/1`, `node_label/1`, the entry's `shape`), `lib/dispatch.exs` (`check_args/5`); tests
`test/core_test.exs`, `test/dispatch_test.exs`, `test/scanner_test.exs`, `test/scanner_lsp_test.exs`, `test/scala_adapter_test.exs`, `test/fsharp_adapter_test.exs`, `test/scanner_csharp_test.exs`.

<a id="d-node-marks"></a>

## D-node-marks — what a scanner tells about calling a node: marks for the adapter, a refusal for `row/add`

**Decided** (2026-11-20, from C#'s rules 3 and 5 in `evolving.md` §4.4):

- **A def may carry `marks`**, a list of words the language adapter reads when it writes the call, and the entry carries them to it
  (`[]` when none). C#'s scanner marks a method returning `Task`, `Task<T>`, `ValueTask` or `ValueTask<T>` `"async"`: its call is
  awaited (C#'s adapter, through the seam); and an overload whose argument count another overload shares `"typed"`: its call gives each
  argument its parameter's type, so the window picks this overload (`Over((null) : string)`, Java's `over(((null): String))`); and Java's
  `"varargs"`: the last argument, an array, passed as `(…)*`
- **A def may carry `refusal`**, the reason a calc row cannot be made for it: `row/add` (and `row/update`'s check) refuses with it
  (`row/add: N.T.Make() can't be a row: its type parameter T appears in no parameter: …`). C#'s scanner gives one to a method whose type
  parameter appears in no parameter (`Make<T>()`): fsi would call it as `Make<obj>()`, a wrong value without an error (P9), until type
  arguments are decided
- Both are stored on the node by `Scanner.put_defs/3` (`nil` where the scanner gives none) and replaced at every scan, as the shape is

**Why**: the scanner is what reads the declaration (the return type, the type parameters); the generic layer only carries the words
and the reason, so it knows nothing of C#. A refusal at `row/add` says why before anything runs; a `private` visibility would hide the
reason, and letting the row crash later would come after a wrong value.

**Alternatives**: deciding `async` in the adapter from the value (a `Task` is awaited when one comes back: no mark needed, but the later
row's type would be `Task<T>`'s, not `T`'s — the call must be typed at compile time); marking the refused method `private` (no reason
given); a field per language (`async: true`) on the node.

**Files**: `lib/scanner.exs` (`put_defs/3`), `lib/dispatch.exs` (`check_args/5`), `lib/core.exs` (the entry's `marks`),
`lib/scanner/csharp.exs`; tests `test/dispatch_test.exs`, `test/core_test.exs`, `test/scanner_csharp_test.exs`.

## Notes

- Difference from earlier designs: the first design named the key as (path, module, name, arity); the code's node key has no path —
  `(module, name, anykey)`
- Verified: not yet verified cold (written from the code, 2026-10-19)
