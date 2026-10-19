# `lib/repl/eval_template.exs`

Elixir's eval_template: builds the text typed into iex for one plan entry — the call, the safety wrapper (a child process with a heap
limit and a timeout), the judgment of `repr` and `compare`, and the marker block. Pure string building; nothing is evaluated on Xipe
Totec's side. The other languages do the same work in `embody` ([D-embody](lib-repl-embody.exs.md#d-embody)).

**Decisions homed here**: [D-repr](#d-repr), [D-compare-basis](#d-compare-basis), [D-closed-args](#d-closed-args)
**Takes part in**: D-markers ([`lib/repl/eval/scan.exs`](lib-repl-eval-scan.exs.md)), D-reference-values ([`lib/core.exs`](lib-core.exs.md))

<a id="d-repr"></a>

## D-repr — `exact` / `binary` / `unsupported`, decided inside the target

**Decided** (2026-09-18): the representation of a value is judged in the target's own REPL, by trying, in this order:

1. the value holds a pid, port, reference or function, at any depth → `unsupported` (checked first: `term_to_binary` would serialise them
   without meaning)
2. its `inspect` (no limits, no width) has no newline and evaluates back to an equal value → `exact`
3. otherwise → `binary` (`:erlang.term_to_binary/1`, carried as base64 in `bin_base64=`)

- The three words belong to Core: it embeds only `exact` results ([D-reference-values](lib-core.exs.md#d-reference-values)) and builds the
  `basis` from `exact`/`binary`. Every language's adapter must mean the same by them (embody's `ReadMe.md`)
- Every display goes through `inspect(…, limit: :infinity, printable_limit: :infinity, width: :infinity)`, and newlines in `display=` and
  `crash` reasons are written as `\n`: one field is one line
- Structs are walked as maps (`Map.to_list/1`): `Enum` on a struct raises (`Date`, `URI`) or walks its elements (`MapSet`, `Range`), and an
  exception there printed no marker

**Why**: a fixed list of types misses project structs; reading the value back is the round-trip check of spec §12.3. It has to run in the
target, since only the target knows its structs.

**Alternatives**: a list of types per `repr`; judging on Xipe Totec's own node.

**Files**: `lib/repl/eval_template.exs`; tests `test/repl_eval_template_test.exs`, `test/live/repl_iex_test.exs`.

**Earlier**: `Old.md` §28 C, §10.3, §10.5, §11.1 (newlines), §50 (structs); 899ab29 (`printable_limit` for long values).

<a id="d-compare-basis"></a>

## D-compare-basis — what a result is compared with, and how

**Decided** (2026-09-18): `compare` is `none` (nothing to compare with), `same`, `changed` or `skipped` (either side cannot be rebuilt).

- **The basis** (chosen by Core, `build_entry/3`): the `prev` a person set (`prev_source: "user"`, `row/set-prev`), else the result on record
  now (`exact` → its text, `binary` → its `bin`), else none (`unsupported` or never evaluated). Not the `prev` column itself: it lags one
  evaluation further back
- **The comparison runs in the target**: the basis is rebuilt there (`Code.eval_string` for `exact`, `Base.decode64!` + `binary_to_term`
  for `binary`), and the two values are compared as terms, recursively; floats are equal within a relative or absolute tolerance of
  `1.0e-9`, fixed in the module
- The word printed is `same`, as spec §4.6 / §6.4 name it

**Why**: strings cannot carry a tolerance, and map keys past 32 are not ordered stably in `inspect`; comparing terms avoids both. The
basis follows spec §6.4: a person's expectation, else the value before this evaluation.

**Alternatives**: comparing display strings; making the tolerance a setting (`compare.float_rel_tol`) — not done, it stays a module
attribute.

**Files**: `lib/core.exs` (`basis`), `lib/repl/eval_template.exs` (`compare_snippet/1`); tests `test/core_test.exs` (basis),
`test/repl_eval_template_test.exs`.

**Earlier**: `Old.md` §11.2, §14.4 (`unchanged` → `same`, the user's `prev`), §28 C.

<a id="d-closed-args"></a>

## D-closed-args — a call that does not parse is never sent; the call compiles in the child

**Decided** (2026-09-18, extended later): `build/1` first parses the call with `Code.string_to_quoted/1`. When it does not parse (an
unclosed bracket), the text sent is only a one-line `XT_ERROR_<id> crash invalid call expression: …` built on Xipe Totec's side — the
fragment itself is never written.

- A call that parses is passed **as a string** and compiled inside the spawned child (`Code.eval_string` with only the `xt_<id>` bindings
  it names). A compile-time error in the arguments (an undefined variable or function) is then an exit reason and takes the ordinary
  `crash` path
- The marker block is printed with one `IO.puts` (D-markers)

**Why**: an unclosed expression makes iex wait for more input and absorb everything written after it, so no marker ever comes and the
whole pass waits out its deadline. Spliced into the session's own text, a compile error stopped the statement before `spawn_monitor` ran —
the same silence.

**Alternatives**: relying on the deadline (correct, but slow and the rest of the pass is lost).

**Files**: `lib/repl/eval_template.exs` (`build/1`, `build_syntax_error/3`, `build_eval/5`); tests `test/repl_eval_template_test.exs`,
`test/live/repl_iex_test.exs`.

**Earlier**: `Old.md` §14.2; `document/repl-adapter-guide.md` ("send only closed expressions").

## Notes

- Every evaluated call is bound to `xt_<id>` at the top level of the session, whatever its `repr`: a later entry of the same pass refers to
  it (`:in_plan`)
- A heap over `max_heap_words` kills the child with `:killed`, printed as `XT_ERROR_<id> max_heap`; the session goes on
- `XT_CALLED_<id>` is printed when the child's value arrives, before judging it (D-hang-handling uses it)
- Verified: not yet verified cold (written from the code, 2026-10-19)
