# `lib/repl/session.exs`

The life of a REPL session, built only from the Sender's primitives and the values the language's launch computes: wait until it is
ready, close it (`exit_input`, then a kill if it does not end). Nothing here knows a language.

**Decisions homed here**: [D-ready-probe](#d-ready-probe)
**Takes part in**: D-one-pass-one-repl ([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md))

<a id="d-ready-probe"></a>

## D-ready-probe — ready means: the banner, then `XT_READY` in answer to a probe

**Decided** (2026-09-26, crux): `await_ready/5` waits in two steps, within one timeout for both:

1. `ready_pattern` — the REPL's own banner (Elixir: `Interactive Elixir`, without the version) appears; skipped when `nil`
2. `ready_probe` is written (Elixir: `IO.puts("XT_" <> "READY")`) and `XT_READY` appears; skipped when `nil`

- The marker is split inside the probe, so a REPL echoing its input cannot be mistaken for the answer
- A process that exits before it is ready fails with its status and the last 30 lines it printed (where a compile error says what and
  where); `cancelled?` is asked every 200 ms (`eval/cancel` during a long boot)

**Why**: banners change with versions, and a project's shell hook can print before the REPL starts; a REPL may have no banner at all
(GHCi with `-v0`). Waiting for an answer to an expression proves the REPL is evaluating input. Measured: banner → `XT_READY` ≈ 30 ms.

**Alternatives**: the banner alone (unstable, absent in some REPLs); an `echo` before starting the REPL.

**Files**: `lib/repl/session.exs`, each language's launch (`ready_pattern`, `ready_probe`, `exit_input`); tests `test/repl_session_test.exs`.

## Notes

- `exit_input` ends a REPL only when it can still read; a hung one is killed (D-hang-handling)
- Verified: not yet verified cold (written from the code, 2026-10-19)
