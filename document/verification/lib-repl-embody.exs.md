# `lib/repl/embody.exs`

Where embody is: `$XIPE_TOTEC_EMBODY_DIR`, else the `embody` directory beside this checkout. embody itself is a separate repository
(git@github.com:Crux-xurC/embody.git); its `ReadMe.md` is the contract.

**Decisions homed here**: [D-embody](#d-embody)
**Takes part in**: D-ocaml-adapter ([`lib/repl/language/ocaml.exs`](lib-repl-language-ocaml.exs.md)), D-haskell-adapter
([`lib/repl/language/haskell.exs`](lib-repl-language-haskell.exs.md)), D-repr ([`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md))

<a id="d-embody"></a>

## D-embody — a fixed module that knows no target and always returns one record

**Decided** (2026-09-24, revised 2026-09-26 and 2026-09-27): values a REPL cannot show finitely or read back (Haskell's infinite lists,
values without `Show`; OCaml's `<fun>`, `<abstr>`) still have to go into the Book in some form. So for these languages every call is
wrapped, by the adapter and without the person asking, in `embody`:

- **It knows no target**: it depends only on the language's standard environment (OCaml's toplevel, Haskell's `base`). Which function to
  call is in the one line the adapter sends; the toplevel / GHCi itself interprets it
- **It always returns one marker record** (D-markers): exceptions, type and syntax errors, missing instances and loops become `crash` or
  `timeout`; a value that cannot be fully shown gets a finite display and `repr=unsupported`; `exact` only for what reads back equal
- **No new `repr` value, no change to Core**: `unsupported` + `display` is the slot for "shown but not reconstructible" (as pids are in
  Elixir). To follow such a value over time, add an observation row beside it (`Embody.cut(⟦B⟧)` in Haskell, a finite list that is
  `exact`); nothing downstream refers to an observation row
- **Previous results are bound at the top level** (`xt_<id>`), so a later entry of the same pass refers to them
- **A separate repository**, for publishing; Xipe Totec finds it as above. Missing, every row of that language crashes with
  `Unbound module Embody`

**Why**: the round trip `repr` relies on is missing in Haskell (`Read` is rare) and partial in OCaml. A fixed module keeps per-target
generated code out, and the REPL already does the job of turning a string into a call.

**Alternatives**: three files naming the target (`embody.yaml`, `write.hs`) — compiled Haskell cannot call a function by its name in a
string without the GHC API; a fourth `repr` value; a result-side template column in `calls`; generating `embody` per target; merging an
observation row back into its row (the card would show a cut value as the value).

**Files**: `lib/repl/embody.exs`, `lib/repl/ocaml/launch.exs`, `lib/repl/haskell/launch.exs`, the eval_templates; embody's `embody.ml`,
`embody.hs`, `ReadMe.md`; tests `test/ocaml_adapter_test.exs` (where embody is), `test/live/repl_ocaml_test.exs`,
`test/live/repl_haskell_test.exs`.

**Earlier**: `Old.md` §30 (the idea, the first plan and why not), §38 (OCaml), §44 (the separate repository), §45–46 (Haskell).

## Notes

- Out of embody's scope, written in its `ReadMe.md`: OCaml's `Sys_error` from `load_all`, a SIGALRM between the end of an evaluation and the
  timer stopping, types containing ` = `; Haskell's exceptions whose own message throws
- Verified: not yet verified cold (written from the code, 2026-10-19)
