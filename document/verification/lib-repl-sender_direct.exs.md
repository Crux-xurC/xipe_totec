# `lib/repl/sender_direct.exs`

The bundled `Repl.Sender`: starts the REPL locally with erlexec in its own process group, forwards its stdout and stderr to the caller as
`{handle, {:data, binary}}`, turns its end into `XT_EXIT <status>`, and writes, interrupts (SIGINT) or kills (SIGKILL) it. The REPL's
executable is looked up on the project environment's `PATH` first.

**Decisions homed here**: [D-sender-contract](#d-sender-contract)
**Takes part in**: D-text-repl ([`lib/repl/sender.exs`](lib-repl-sender.exs.md)), D-hang-handling
([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md)), D-project-env ([`lib/project_env.exs`](lib-project_env.exs.md))

<a id="d-sender-contract"></a>

## D-sender-contract — one message shape, exit as a marker, a process group

**Decided** (2026-09-18, revised 2026-09-22):

- **Push only, one shape**: everything reaches the caller as `{handle, {:data, binary}}`. There is no "give me what is buffered" (a PTY has
  no such operation)
- **The process's end is text in the same stream**: `XT_EXIT <status>\n`, made by the Sender from whatever its transport reports (erlexec's
  `:DOWN`: a bare `:normal` for status 0, `{:exit_status, n}` otherwise, decoded with `:exec.status/1`)
- **`write/2`, `interrupt/1`, `kill/1`** on the same handle. The handle is a GenServer that owns the OS pid; a write to a process already
  gone is `{:error, :noproc}`, a kill of it is `:ok` (the aim is already met)
- **A process group** (`{:group, 0}`): `interrupt/1` and `kill/1` reach the whole group, so a Ctrl-C on Xipe Totec's own CLI does not hit
  the REPL, and a REPL's children (`iex -S mix`'s build) do not outlive it. erlexec delivers to the group when given the positive OS pid
- **Starting cannot take the caller down**: a spawn erlexec refuses comes back as `{:error, {:spawn_failed, reason}}`; the exit signal of
  the start link is caught and dropped for the length of the start only
- The environment is passed as binaries (erlexec refuses a flake's empty values and UTF-8 text as charlists); `false` unsets a variable

**Why**: receivers (the parser, the Evaluator) then work the same over any transport; exit, results and readiness need one watcher. A raw
`Port` cannot make a process group or signal one.

**Alternatives**: a separate exit message per transport; `Port.open` with `kill -9` of one pid (left grandchildren orphaned).

**Files**: `lib/repl/sender_direct.exs`, `lib/repl/sender.exs`; tests `test/repl_sender_direct_test.exs` (it caught the `:normal` decoding).

**Earlier**: `Old.md` §10.1, §10.2, §12 (`:noproc`), §23.1–23.2, §35.4.

## Notes

- `with_files/2` turns `message["files"]` into `-r <file>` for iex; OCaml's and Haskell's launches do not use `files` for that reason
- Not supervised: a caller that dies without `kill/1` leaves the GenServer and the group behind
- Verified: not yet verified cold (written from the code, 2026-10-19)
