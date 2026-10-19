# `lib/session.exs`

The record a running `xipe start` leaves: `tables/session.json` — its OS pid and start time, port, project, root, tezcatl's `/lsp` URL and
file root. Written once it listens, removed on a normal stop. `owner/0` (pid + start time) is also what `passes/` and the Book's lock
record.

**Decisions homed here**: [D-session-record](#d-session-record)
**Takes part in**: D-workspace ([`lib/workspace.exs`](lib-workspace.exs.md)), D-passes ([`lib/passes.exs`](lib-passes.exs.md)), D-store
([`lib/store.exs`](lib-store.exs.md))

<a id="d-session-record"></a>

## D-session-record — a session is a record whose process is still the same process

**Decided** (2026-09-24, revised 2026-10-06):

- A command without `<dir>` targets **the session's project** when a session runs, else the chosen project (an explicit `<dir>` > the
  session > the chosen one)
- **Alive is judged by the start time as well as the pid**: `os_started` (`ps -o lstart=`, C locale) must match the pid's. After a reboot or
  a long while a pid may belong to another program, which would otherwise pass for the session and send commands to the wrong project.
  An old record without `os_started` is judged by the pid alone
- A record whose process is gone is simply absent: a stale file never needs cleaning by hand
- A session that cannot write its record runs anyway and says so; other commands then do not know it (`scope.md`)

**Why**: the CLI is short-lived and the server long-lived; a file both read is how a CLI command learns which project the running server
serves.

**Alternatives**: `kill -0` only (the pid-reuse problem).

**Files**: `lib/session.exs`, `lib/workspace.exs` (`resolve/2`), `main.exs`; tests `test/session_test.exs`.

**Earlier**: `Old.md` §31.2 (the resolution order), §49.

## Notes

- A CLI command that writes the session's project's Book says that it writes `book.jsonl` directly; the server takes it in on its next
  request (D-store)
- Verified: not yet verified cold (written from the code, 2026-10-19)
