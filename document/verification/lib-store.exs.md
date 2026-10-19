# `lib/store.exs`

The Book on disk: append-only JSON Lines (`tables/project/<id>_<name>/book.jsonl`), one row a line tagged by `type`, the last line of a
`{type, id}` winning when folded. Writes hold a lock; the server catches up with what others appended; a failure is an answer, not an
exception.

**Decisions homed here**: [D-store](#d-store)
**Takes part in**: D-serve-project ([`lib/serve_project.exs`](lib-serve_project.exs.md)), D-session-record ([`lib/session.exs`](lib-session.exs.md))

<a id="d-store"></a>

## D-store — append only, locked, caught up, never thrown

**Decided** (2026-09-16, hardened 2026-10-06 to 2026-10-16):

- **Append only**: an evaluation, an edit, a removal each append a line; a row with `deleted: true` removes the id on fold. `compact/1`
  (rewrite to the current state) is the one sanctioned rewrite. The differences of a change are appended in one write (a scan of a large
  project used to open the file hundreds of times)
- **A torn line stays one bad line**: on load a truncated or corrupt line is skipped; before appending, a file not ending in a newline gets
  one, so the next line is not swallowed; an append that fails midway is cut back to the length before it
- **Every write holds `book.jsonl.lock`**, which records its owner (`os_pid` + `os_started`, as `session.json` and `passes/`). A lock whose
  owner is gone is taken over, one taker at a time (`<lock>.takeover`); a living owner is waited for up to 10 s
- **The server catches up**: it keeps the byte position it has read to (after the last newline). **Before each request** it reads what
  was appended since (no lock: only whole lines are read; a line being written waits for the next time) and broadcasts it; **before writing**,
  inside the lock, it takes in the rest and lays its own changes over them (its own line wins for the same row). A file shorter than the
  position (`compact`) is read again from the start. The CLI is short-lived and needs only the lock
- **Failures are results**: a lock kept past the wait (`{:lock_busy, …}`), a lock that cannot be made, a file that cannot be written
  (`{:not_written, …}`) come back as `{:error, reason}` with a line for people (`describe/1`). The server answers `book_not_written`; the
  CLI prints the results, then says nothing was recorded, and exits 1

**Why**: the CLI and a running server write the same file (routing CLI writes through the server is not done); without the lock and the
catching up, lines interleaved, the server never saw the CLI's changes, and a CLI scan followed by a server scan gave one function two ids. A
raise from a write at the end of a pass took the whole server down.

**Alternatives**: ETS or a database; the CLI writing through the server (decided in 2026-09, still not wired); reading a torn line as the end
of the file.

**Files**: `lib/store.exs`, `lib/serve_project.exs` (`store_pos`, `caught_up`), `lib/session.exs` (`owner/0`), `main.exs`; tests
`test/store_test.exs`, `test/serve_project_test.exs`.

**Earlier**: `Old.md` §2, §8.1 (the unwired "CLI through the server"), §49, §55, §56.2; commit 3b39709.

## Notes

- A Store-level tombstone (`deleted: true`) is not a node's `status`; scanned-away nodes are removed this way (D-identity)
- Two writers of `logging_buffer.txt` are not locked (best effort, D-log-buffer)
- Verified: not yet verified cold (written from the code, 2026-10-19)
