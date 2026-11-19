# `lib/repl/evaluator.exs`

Runs one evaluation pass: plans it (`Core.plan_recalc/3`), starts one REPL, waits until it is ready, sends the entries one by one, reads
each result through the parser, closes the REPL and folds the results into the Book (`Core.apply_results/3`). Synchronous; the server
runs it in a process of its own.

**Decisions homed here**: [D-one-pass-one-repl](#d-one-pass-one-repl), [D-hang-handling](#d-hang-handling),
[D-restart-after-timeout](#d-restart-after-timeout)
**Takes part in**: D-plan-run-apply, D-named-rows-only ([`lib/core.exs`](lib-core.exs.md)), D-language-adapter
([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-passes ([`lib/passes.exs`](lib-passes.exs.md))

<a id="d-one-pass-one-repl"></a>

## D-one-pass-one-repl — one pass starts its own REPL and closes it

**Decided** (2026-09-26, crux): a pass launches a REPL, evaluates its entries, and closes it (`exit_input`, or a kill when that does not
end it). Nothing — the session, its bindings — is carried to the next pass. A "resident session" means "a REPL kept for the length of one request".

- A result's `session_gen` (the row's `session` column) is the pass id; after a `timeout` in a REPL that starts again,
  `<pass>/2`, `<pass>/3` … ([D-restart-after-timeout](#d-restart-after-timeout))
- There is no `lost` state: it existed for a resident session losing its bindings, which cannot happen now. A REPL that wedges mid-pass is
  covered by `session_hung` / `:aborted` ([D-hang-handling](#d-hang-handling))
- The code evaluated is the code on disk at the start of the pass (the REPL loads it then)

**Why**: with D-referential-transparency, nothing needs to survive a pass. A fresh REPL evaluates what is on disk and leaks no state
between passes (P2). Measured on `calc` (scripts-mode): a whole `xipe eval` ≈ 2.7 s, of which the CLI's own start ≈ 1.7 s and iex's ≈ 0.6 s.

**Alternatives**: a server-held REPL restarted on change (fast only while code is unchanged; state leaks; needs `lost`); a resident REPL
reloading changes (`recompile()`) — conflicts with "cards follow the disk"; the CLI using the server's session — needs the first.

**Files**: `lib/repl/evaluator.exs`, `lib/repl/session.exs`; tests `test/repl_evaluator_test.exs`, `test/live/repl_iex_test.exs`.

<a id="d-hang-handling"></a>

## D-hang-handling — one fixed deadline per entry, then interrupt and kill the process group

**Decided** (2026-09-18, revised 2026-09-22): each entry's code ends itself within its timeout (its wrapper always prints a marker), but
two things escape that — a session that stops scheduling, and an expression the REPL takes as unfinished. So waiting for an entry has a
**fixed deadline**, computed once when the entry is sent: `timeout + 2 s` (`@default_deadline_padding_ms`). Output arriving does not push
it back.

- Past the deadline: when the adapter declares `interruptible`, SIGINT first and up to 2 s for the REPL to exit (`XT_EXIT`), then SIGKILL
  to its **whole process group** either way (`Sender.kill/1`)
- That entry is `{:error, "session_hung"}`; when its `XT_CALLED_<id>` had arrived, the reason says the call returned and judging its
  value (repr, compare) did not finish. Every later entry of the pass is `:aborted` (nothing written)
- A REPL that does not start in `boot_timeout` (the project's `eval.boot_timeout`, default 15 s) fails the pass (`boot_failed`); a REPL
  that cannot be spawned is `launch_failed`
- **Stopping a pass** (`eval/cancel`): `:cancelled?` is asked before launch, while booting, before each entry and every 200 ms while
  waiting; once yes, the process group is killed and `run_pass/3` returns `{:error, :cancelled}` — nothing of the pass is recorded, not
  even finished entries
- `:progress` tells `"calling"` when an entry is sent and `"classifying"` when `XT_CALLED_<id>` arrives (the Runner writes it for
  `eval/status`)

**Why**: a silence window reset by any output never fires on an unclosed expression (the REPL keeps absorbing the rest). A heartbeat to
tell "busy" from "stuck" needs code in every target language; a fixed deadline and signals to the process group need nothing from the
target, and the group kill also takes the REPL's children (`iex -S mix`'s build).

**Alternatives**: heartbeat markers from a process in the target (`XT_HEARTBEAT`, withdrawn 2026-09-22); killing only the REPL's own pid
(left grandchildren orphaned); continuing the same session after a successful interrupt ("option B", not taken).

**Files**: `lib/repl/evaluator.exs` (`run_entry`, `wait_result`, `end_hung_session`), `lib/repl/sender_direct.exs` (`interrupt/1`,
`kill/1`), each language's launch (`interruptible`); tests `test/repl_evaluator_test.exs` (a silent fake Sender).

**Earlier**: `eval/cancel` from f59d4d8.

<a id="d-restart-after-timeout"></a>

## D-restart-after-timeout — after a timeout, the rest of the pass in a new session

**Decided** (2026-11-20, crux, from a review of the C# adapter): a REPL that stops a call at its time limit by raising inside it
(Python's SIGALRM, .NET's `ControlledExecution`) may leave whatever the call was changing half done — a static, a module's global, a
lock — and in .NET a thread in a native wait runs on beside the next entries. A session going on after that answers, but its answers
can no longer be trusted (P2). A language whose launch message declares `"restart_after_timeout": true` (Python, F#) has the rest of
the pass evaluated in a new session after a `timeout`:

- the old session is killed (no `exit_input`: it may not answer), the next launched from the same launch message; a start script that
  did its work once (F#'s build and script copies) finds it done and only starts the REPL again
- the rows of the new session carry `session_gen` `"<pass>/2"`, `"<pass>/3"` …: every row records which session gave its value
- a reference to a row evaluated in an earlier session (Core's `:in_plan`, a binding the old session had) becomes that row's `exact`
  text, as a value from outside the pass is embedded; a row whose value cannot be handed over (not `exact`, an error, the timed-out row
  itself) makes the referring row `{:skipped, ref}`, and so on down. Nothing is evaluated again implicitly
- a `timeout` on the pass's last entry ends the pass as before (the session closes)
- a later session that does not start leaves the rest `:aborted` and keeps what was evaluated
- Elixir (a call runs in a process of its own, killed at its limit), OCaml and Haskell do not declare it

**Why**: "the REPL reads on" and "what it answers next is right" are different things. Starting again costs one REPL start per timeout
(F#: fsi only, about 3 s, the build kept), and a timeout is the exception.

**Alternatives**: a column marking rows evaluated after a timeout in the same session (P9: shows the doubt but keeps the doubtful
values); re-evaluating the earlier rows a later row refers to in the new session (runs functions not named: D-named-rows-only);
restarting after every `crash` too (an exception unwinds normally; not taken).

**Files**: `lib/repl/evaluator.exs` (`run_sessions`, `carry_over/2`), `lib/repl/python/launch.exs`, `lib/repl/fsharp/launch.exs`;
tests `test/repl_evaluator_test.exs` (`restart_after_timeout`), `test/live/repl_python_test.exs`, `test/live/repl_fsi_test.exs`.

## Notes

- The four adapter modules are options (`:launch_module` …) defaulting to Elixir's; this module never picks a language (the Runner does)
- `:hang_grace_ms` and `:interrupt_grace_ms` exist for tests
- Skipped rows from the plan come first in the results and are not folded into the Book
- A real wedge needing the interrupt path (the scheduler stopping) has no safe reproduction; the path is checked with a fake Sender only
- Difference from earlier designs: a later note of the first design gave the padding as 7 s; the code has 2 s
- Verified: not yet verified cold (written from the code, 2026-10-19)
