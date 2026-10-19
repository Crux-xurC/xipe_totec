# `lib/core.exs`

Pure functions over the `Book`: the basic changes of rows (nodes, calls, effects, arities, a value or expectation set by hand), the
reference graph of `⟦id⟧`, the plan of an evaluation and folding its results back. No I/O, no clock, no randomness — ids and times come
from the caller.

**Decisions homed here**: [D-referential-transparency](#d-referential-transparency), [D-named-rows-only](#d-named-rows-only),
[D-plan-run-apply](#d-plan-run-apply), [D-reference-values](#d-reference-values), [D-effect-classes](#d-effect-classes),
[D-arity-set](#d-arity-set)

<a id="d-referential-transparency"></a>

## D-referential-transparency — the function evaluated is taken as referentially transparent

**Decided** (2026-09-26, crux): Xipe Totec checks functions one at a time, and sees a chain of dependencies by evaluating calc rows in
turn. Referential transparency is asked of **the function evaluated**, not of where its arguments came from: if row A (`f(⟦B⟧)`) calls
a referentially transparent `f`, its record is valid for the value passed, even when B is not. A row made again gives the same value,
so a row that lost its function after a rescan is simply made again.

- No sandbox, no transaction, no undoing of side effects: a misclassified side effect really happens (README, "What it is not")
- What makes this safe enough is [D-effect-classes](#d-effect-classes): nothing unclassified runs

**Why**: the tool started as a shortcut for trying functions in a REPL by hand; what is recorded is "this function, given this value,
gave that". Asking more (a whole chain to be pure) would forbid exactly the use it was made for — feeding a function the output of
something impure.

**Alternatives**: forbidding references to rows that are not reproducible — it stops the normal case, a function fed an impure value.

**Files**: `lib/core.exs`; the consequences are in [D-named-rows-only](#d-named-rows-only) and D-one-pass-one-repl
([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md)).

**Earlier**: `Old.md` §35.1 (1–3); README P1.

<a id="d-named-rows-only"></a>

## D-named-rows-only — only the calc rows a request names are evaluated

**Decided** (2026-09-26, crux): the Book is a record in time, and each evaluation in it is one a command asked for. `plan_recalc/3`
plans exactly the rows given in `:call_ids` that exist and are not in a reference cycle — nothing else.

- **No downstream**: rows referencing an evaluated row are not evaluated with it. To evaluate a chain, name its rows together
- **No upstream**: a row whose referenced row has no value to pass on is not evaluated, and the referenced row is not added
- **No embedded calls**: the call of a referenced function is never put inside another row's expression
- **A row not evaluated is not written**: `{:skipped, ref}` and `:aborted` change nothing in the Book; the reason is reported with the
  results only
- What is evaluated together hands values over in the session (see [D-reference-values](#d-reference-values))

**Why**: evaluating rows nobody named records evaluations no command asked for, which breaks "the Book is what was asked, in order". It
also made results depend on what happened to be downstream.

**Alternatives**: the affected set of spec v0.4 §6.6 (everything downstream of a change, by `dep_hash`) — withdrawn here; evaluating the
upstream rows that cannot pass a value (2026-09-26 §35.1-5, withdrawn the same day); embedding the call of a pure `unsupported` reference
(`:inline_call`) — it ran the referenced function without recording it; a `--downstream` option — not made: naming the rows does it.

**Files**: `lib/core.exs` (`plan_recalc/3`, `apply_result/3`), `lib/repl/evaluator.exs` (skipped rows reported, not folded),
`lib/runner.exs`; tests `test/core_test.exs`.

**Earlier**: `Old.md` §36 (replaces §4.1, §35.1-5); §37.3 removed the downstream query functions (`affected_set/3` …).

<a id="d-plan-run-apply"></a>

## D-plan-run-apply — plan (pure), run (the only impure step), apply (pure)

**Decided** (2026-09-16, revised to 2026-09-26): Core does not evaluate. `plan_recalc/3` makes a plan, the Evaluator runs it, and
`apply_results/3` folds the results into the Book.

- A plan is `%{pass_id, entries, skipped, cyclic_ids}`; entries in topological order. An entry carries `call_id`, `node_id`, `module`,
  `name`, `anykey`, `args` (text, references already replaced or left as placeholders), `inputs` (what each placeholder is), `basis`
  (what the result is compared with, see D-compare-basis in [`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md)) and `limits`
  (`timeout`, `max_heap_words`; the Evaluator replaces `timeout` with the project's `eval.timeout`)
- **Core knows no language syntax**: it moves identifiers and text; building the call expression is the REPL adapter's
- **Values entering Core are JSON-safe**: times are ISO 8601 strings, `repr` and `compare` are strings (never atoms), `bin` is base64.
  The Store encodes every column, and Core compares `repr` as a string
- A result is `%{call_id, outcome, compare, evaluated_at, session_gen}`; `outcome` is `{:ok, %{repr, display, type, bin}}`,
  `{:error, reason}`, `:timeout`, `:max_heap`, `{:skipped, ref}` or `:aborted`. `eval_count` grows only for the first four
- `apply_results/3` takes `ctx = %{commit, commit_at, dirty}` from the caller (Core never reads git); on success `prev` becomes the
  result before it (`prev_source: "auto"`); a failure keeps the previous `result` and sets `state: "eval_error"` and `error`

**Why**: evaluation is the only part with side effects and timing; keeping it out of Core leaves planning and folding testable with
plain ExUnit, with a fake Evaluator.

**Alternatives**: Core building the call expression (`expr`) — it is language syntax, and nested calls would be too.

**Files**: `lib/core.exs`, `lib/repl/evaluator.exs`, `lib/repl/eval/result.exs`; tests `test/core_test.exs`,
`test/repl_evaluator_test.exs`.

**Earlier**: `Old.md` §4.4, §28 B (B1, B2), §11.1 (repr as strings), §35.3 (`restart_session`, `bind_as`, `lost` removed).

<a id="d-reference-values"></a>

## D-reference-values — what a `⟦id⟧` becomes

**Decided** (2026-09-22, 2026-10-06): references are found by a text scan of `args` for `⟦id⟧` (no parsing of the target language).
For each reference, `resolve_ref/3` decides:

| The referenced row | It becomes |
|---|---|
| evaluated earlier in the same pass | its session variable `xt_<id>` (every evaluated call is bound to it) |
| outside the pass, `repr` = `exact` | its `result` text, as it is |
| outside the pass and anything else — never evaluated, `binary`, `unsupported`, unknown | cannot be passed: the row is `{:skipped, ref}` |

- `drop_unresolvable/2` removes such rows before the plan is made, and repeats until nothing more falls (a skip cascades)
- A `binary` value is not passed: its `result` is only its display and does not read back as source; rebuilding it from `bin` would bring
  per-language work into the plain command. The person settles it: evaluate the referenced row in the same command, or put a value in its
  place (`dialogue depends`, which writes it with `row/set-result`)
- The skipped row's reason points at `dialogue depends <id>`

**Why**: a reference that resolves to an unbound variable used to reach the REPL, fail to compile before any marker was printed, and wait
until the deadline as `session_hung` (2026-09-22). A REPL lasts one pass, so a binding from another pass can never exist.

**Alternatives**: rebuilding a `binary` value from `bin` in the REPL (per-language, in the plain path); a special dialogue for values in
doubt — left for when tezcatl's end-to-end tests need it.

**Files**: `lib/core.exs` (`resolve_refs/3`, `resolve_ref/3`, `drop_unresolvable/2`), `lib/repl/eval_template.exs` (binding every result
to `xt_<id>`); tests `test/core_test.exs`.

**Earlier**: `Old.md` §4.4, §22 (the `session_hung` it fixed), §51 (X-2, `binary` not passed).

<a id="d-effect-classes"></a>

## D-effect-classes — only side effects a person classified are trusted

**Decided** (2026-09-16, extended to 2026-09-24): a node's `effect` is `pure`, `reads`, `writes` or `unknown`, and is trusted only when a
person set it with `effect/set` (`effect_source: "user"`). It is never inferred.

- `filter_by_effect/3`: an unclassified node never runs (not even as `pure` by default); `pure` and `reads` run; `writes` and `unknown`
  run only with `include_writes` (`--include-writes`, `include_writes=true`; the string `"true"` counts)
- `exclusion_reason/3` says why a named row did not reach the plan, in the order the plan checks (unknown id → circular reference → node
  gone → not classified, with the `effect/set` to type → `writes` without `include_writes`); the Runner returns them as `not_run`
- A rescan keeps a node's effect (the scanner carries it over)

**Why**: P1 — a function's side effects cannot be known from outside reliably, and a wrong guess writes for real. A row that silently does
nothing was the next problem (2026-09-24), hence the reasons.

**Alternatives**: inferring effects (spec v0.4 §8.2) — out of scope; treating unclassified as pure — unsafe.

**Files**: `lib/core.exs` (`set_effect/3`, `filter_by_effect/3`, `exclusion_reason/3`), `lib/runner.exs` (`not_run`), `main.exs`
(`--include-writes`); tests `test/core_test.exs`, `test/runner_test.exs`.

**Earlier**: `Old.md` §4.2, §16.2, §18, §33; README P1.

<a id="d-arity-set"></a>

## D-arity-set — a person decides the argument counts of a function with default arguments

**Decided** (2026-10-08, crux): `def scale(x, k \\ 2)` is one card, `scale/2` (anykey 2). How many arguments it can be called with is
declared by a person with `arity/set id=<node> arities=[1,2]`, as with `effect/set`; the scanner never writes it.

- `arities` must include the anykey (the defined arity) and nothing above it; just the anykey clears it; nodes whose anykey is not a number
  (OCaml, Haskell) are refused. The anykey and the id do not change, so rows and the Book stay as they are; a rescan carries it over
- Used by: `row/add` and `row/update`'s check (`accepted_arities/1`), link matching (`Scanner.node_for` finds a node of the same module and
  name whose `arities` contain the call's arity), labels (`M.scale/1..2` for the node, `M.scale/1` for a row)
- Shown when it is needed: when `row/add` refuses for the arity, Elixir's own parser reads the file and says "has default arguments,
  callable as 1..2: `arity/set …` first"; `scan/run` lists calls that missed only by arity as `arity_misses` (apart from
  `link_failures`, since they were read)

**Why**: P1, P4, P9 — what can be decided automatically only sometimes is shown, and a person decides. Filling the defaults into the row to
match the node's arity fails when a default refers to something inside the module (`@default`, `helper()`), and does not fix the links.

**Alternatives**: the scanner writing the arities it counted; filling default values into the stored call.

**Files**: `lib/core.exs` (`accepted_arities/1`, `set_arities/3`, `node_label/1`, `call_label/2`), `lib/dispatch.exs` (`arity/set`, the
check), `lib/scanner.exs` (`node_for`), `lib/scanner/elixir.exs` (`default_arities/4`), `lib/methods.exs`; tests `test/arity_set_test.exs`.

**Earlier**: `Old.md` §53.

## Notes

- `build_entry/3` puts `limits: %{timeout: 5_000, max_heap_words: 50_000_000}`; the per-project `eval.timeout` reaches the entries in the
  Evaluator (`run_pass/3` replaces `timeout`), not here
- `upstream_chain/2` (used by `row/depends` and `dialogue depends`) is the one remaining walk of the reference graph; the downstream ones
  were removed with D-named-rows-only
- `set_result/3` writes a person's literal as `result` with `repr: "exact"` and `result_source: "user"`; nothing in Core reads
  `result_source` back (it is for showing)
- Difference from the documents: `Old.md` §4.4's entry shape (with `bind_as`, `restart_session`, `:inline_call`) is history; the shape
  above is the code's
- Verified: not yet verified cold (written from the code, 2026-10-19)
