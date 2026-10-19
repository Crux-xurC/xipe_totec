# `lib/in_out.exs`

The structured dialogue core: `handle/6` takes the Book and the one dialogue slot of a connection, routes a request (continue the held
dialogue, start one, quit, or pass it through to the Runner), and returns one tagged reply. Pure; the caller (the CLI's prompt, or the
server) keeps the Book and the slot between calls. `lib/dialogue.exs` is the contract a program implements.

**Decisions homed here**: [D-dialogue-core](#d-dialogue-core)
**Takes part in**: D-envelope ([`lib/protocol.exs`](lib-protocol.exs.md)), D-input-line ([`lib/serve_input.exs`](lib-serve_input.exs.md))

<a id="d-dialogue-core"></a>

## D-dialogue-core — a dialogue is a log of turns; a program gives the next text and two bits

**Decided** (2026-09-19 to 2026-09-27, crux): multi-turn exchanges (negotiating a dependency chain, searching, asking for arguments) are a
fourth layer, beside the pure `Dispatch`, the one-shot `Pipeline` and the one-pass `Evaluator`.

- **A dialogue is a log of `:in` (what was typed) and `:out` (text Xipe Totec wrote)**. A REPL result and a program's question are both
  text for people by the time they get here, so they are not told apart; there is no separate channel for "the final result"
- **Each dialogue is a program** (`Dialogue`): `start` and `answer` return the next text and one of `{:hold, state, text}` (wait for the
  next answer) or `{:done, text, commands}`. The core knows nothing of a program's meaning, and derives two bits from the shape:

  | Returned | hold | via REPL | |
  |---|---|---|---|
  | `:hold` | yes | no | ask the next question |
  | `:done`, no commands | no | no | finished inside Xipe Totec |
  | `:done`, commands | no | yes | the commands run in the same turn (through the Runner) |
  | a request passed through | no | `eval`-like methods only | as if InOut did not exist |
- **Programs do not write the Book**; their commands do (`row/set-result`, `eval` …). A program may read it: with `start/2` / `answer/3`
  it gets a read-only `ctx` (`book`, `root`, `project_dir`, `log_file`)
- **One dialogue per connection**, in a single slot: tezcatl's windows share one connection, so an unrelated command arriving mid-dialogue
  passes through and is not taken as the answer (but a line typed in the window while it holds *is* the answer, D-input-line)
- **`{:pass, state, line}`**: run this line as an ordinary command, keep holding (`search` passing a command through). The driver runs it,
  so an evaluation does not run inside the server's GenServer
- **`defer_commands: true`** (the server): a `:done` turn's commands are returned (`outcome.run = {:commands, …}`) for the pass queue
  instead of run here; the CLI runs them at once
- **`dialogue/quit`** ends whatever is held; `parse_answer/1` (optional) turns a typed line into the answer's params
- **One registry** (`programs/0`): `dialogue/depends`, `dialogue/search`, `dialogue/do`, `dialogue/rewrite`, `dialogue/update`, the same
  for CLI and server

**Why**: a PTY-based dialogue would bring back unstructured bytes, echo and ANSI; a structured core with a text mode (the CLI) and a JSON
mode (the WebSocket) keeps both readable. With command lists in place, the core is thin: a state and "answer → next text or commands".

**Alternatives**: running dialogues over tezcatl's `/pty`; a counter of remaining turns (what was needed were two independent bits); a
channel for final results.

**Files**: `lib/in_out.exs`, `lib/dialogue.exs`, `lib/dialogue/*.exs`, `lib/serve_project.exs` (`request_dialogue/5`),
`lib/serve_socket.exs` (the slot), `main.exs` (the CLI prompt); tests `test/in_out_test.exs`.

**Earlier**: `Old.md` §16.4, §17, §17.1, §17.3, §41.3; `dialogue do` / `rewrite` / `update` from f59d4d8, adbce04, 901166d.

## Notes

- The two bits in `Old.md` §17's table and the field `via_repl` point in opposite directions for bit 2 (`via_repl: true` is the table's
  "bit2 = 0, to the REPL") — read them by value, not by name (D-envelope)
- Verified: not yet verified cold (written from the code, 2026-10-19)
