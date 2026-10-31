# `lib/dialogue/depends.exs`

`dialogue depends <call_id>`: walks the target row's upstream `⟦id⟧` chain from the deepest step, asking at each whether to put a value
there by hand and evaluate from there up to the target.

**Decisions homed here**: [D-depends](#d-depends)
**Takes part in**: D-dialogue-core ([`lib/in_out.exs`](lib-in_out.exs.md)), D-reference-values ([`lib/core.exs`](lib-core.exs.md))

<a id="d-depends"></a>

## D-depends — negotiate a dependency chain from the deepest step

**Decided** (2026-09-19 design by crux, 2026-09-22 implementation):

- The chain is `Core.upstream_chain/2` (deepest first, the target last), each step labelled `Module.name/arity` (`Core.call_label/2`), shown as
  `;; wN <label>`. Given a `call_id` alone, the chain is built from the read-only Book; the program itself never changes the Book
- The target itself is never asked about; from the deepest dependency:
  - **`y <value>`** (a literal in the target's language): two commands — `row/set-result` writes the value on that step (no evaluation,
    `result_source: "user"`, `repr: "exact"`), then `eval` with `include_writes: true` of every step above it, the target included. Done
  - **`n`**: that step is left as it is (not evaluated), ask about the next one up
  - anything else, or `y` without a value: the same question again
- **The chain used up** (every step declined, or no dependency at all): done, nothing runs. It does **not** fall back to evaluating the
  target — that is the plain `eval`
- The rows evaluated are named explicitly (D-named-rows-only); the skipped-row message of the plan points here for values that cannot be
  passed (`binary` …)

**Why**: to try `w1(w2(w3(…)))` when the deep part is unwritten or must not run (writes). One dialogue covers what were three separate
needs: getting the chain, putting in a stand-in value, opting into writes.

**Alternatives**: a `stub_result` in Core (unneeded: an evaluated `exact` value already embeds); falling back to direct evaluation when
there is no chain (crux: a direct evaluation is its own command).

**Files**: `lib/dialogue/depends.exs`, `lib/core.exs` (`upstream_chain/2`, `set_result/3`, `call_label/2`), `lib/dispatch.exs`
(`row/depends`, `row/set-result`); tests `test/dialogue_depends_test.exs`.

## Notes

- `parse_answer/1` reads `y <value>` / `n`, for the CLI prompt and the window alike
- Verified: not yet verified cold (written from the code, 2026-10-19)
