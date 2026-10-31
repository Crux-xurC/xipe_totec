# `lib/repl/sender.exs`

The behaviour of the delivery layer: a `Sender` takes the message `Repl.Launch` built and makes it happen — starts the REPL, writes
text to it, interrupts or kills it. `Repl.Sender.Direct` is the one bundled.

**Decisions homed here**: [D-text-repl](#d-text-repl)
**Takes part in**: D-sender-contract ([`lib/repl/sender_direct.exs`](lib-repl-sender_direct.exs.md))

<a id="d-text-repl"></a>

## D-text-repl — evaluation is what a person does at a REPL's terminal

**Decided** (2026-09-18, crux): Xipe Totec started as a shortcut for typing expressions into the target's REPL by hand, so evaluation
automates exactly that: start the target project's own REPL, write the call to its standard input as text, read the result it prints
on its standard output. Xipe Totec's own BEAM does not connect to the target's.

- No distributed Erlang: no node names, cookies, `epmd`, `Node.connect`, `:erpc.call`
- No PTY: a plain pipe has no echo and no ANSI (confirmed with iex), so the output needs no cleaning beyond the markers
- The session's own variable bindings carry values within a pass, as they would for a person (`xt_<id>`); nothing in the target holds
  bindings for Xipe Totec
- Readiness, results and the end of the process all arrive as text on the same stream, as markers (D-markers)

**Why**: the same path a person uses works for every language with a REPL; a distributed connection works for BEAM languages only, and
would have needed a binding-holding process inside the target and node-down monitoring.

**Alternatives**: distributed Erlang with a loopback-only `epmd` and a per-project cookie, and a process in the target keeping
bindings (designed 2026-09-17, withdrawn 2026-09-18); a PTY (brings echo and ANSI; a `Scan.Pty.*` slot stays empty for it).

**Files**: `lib/repl/sender.exs`, `lib/repl/sender_direct.exs`, `lib/repl/launch.exs`, `lib/repl/session.exs`, `lib/repl/eval/scan/`.

## Notes

- The handle contract (push only, one message shape, exit as `XT_EXIT <status>`) is written in the moduledoc; its reasons are under
  D-sender-contract
- Verified: not yet verified cold (written from the code, 2026-10-19)
