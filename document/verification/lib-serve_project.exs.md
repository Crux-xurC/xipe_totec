# `lib/serve_project.exs`

One project, one GenServer — the only place in the server with mutable state (the Book). It runs requests (`Dispatch`, or `Pipeline`
first), saves the difference, and broadcasts `notify/rowChanged` / `notify/nodeChanged` to every attached session; evaluations and scans
run in processes of their own and are folded back when they end. `lib/serve_socket.exs` is the WebSocket in front of it (one dialogue slot
per connection, the reply envelope).

**Decisions homed here**: [D-serve-project](#d-serve-project)
**Takes part in**: D-store ([`lib/store.exs`](lib-store.exs.md)), D-passes ([`lib/passes.exs`](lib-passes.exs.md)), D-pipeline
([`lib/pipeline.exs`](lib-pipeline.exs.md)), D-input-line ([`lib/serve_input.exs`](lib-serve_input.exs.md))

<a id="d-serve-project"></a>

## D-serve-project — one GenServer per project; passes beside it, in order; a raising request does not take it down

**Decided** (2026-09-17, extended to 2026-10-16):

- **One `xipe start` process, one project, one GenServer** (a second project is a second process on another port). Request ids are not
  rewritten: every attached client sees every broadcast and takes what it needs (the relay in front holds no state)
- **Evaluation runs off this process**: `eval`, `eval/run`, `row/update` are answered at once with a `pass_id` (`"started"` / `"queued"`);
  the pass runs `Runner.run/4` over a snapshot of the Book; on completion its results are folded into the Book **as it is then** (a row
  removed meanwhile drops its result), saved, broadcast, and `notify/passCompleted` (`pass_id`, `ok`, `result` or `error`) is sent. **One
  pass at a time per project, in arrival order**
- `row/update`'s edit runs at once (saved and broadcast) before its evaluation is queued (D-pipeline)
- **Scanning runs off it too** (a language server easily outlasts a 5-second call); the caller's reply waits for the scan; the result is
  folded into the Book as it is then, keeping each node's effect from the current Book (an `effect/set` during the scan wins)
- **`eval/cancel`** takes a queued pass out (reported as ended, `cancelled`) or asks the running one to stop (D-passes)
- **A request that raises is answered `internal_error`** (method and the exception's first line; the stack to the server's stderr); the
  Book and the held dialogue stay as they were. This process is linked to `xipe start` itself: before, one bad line took the whole server
  down — every window's connection, the queue, the dialogue — and tezcatl's `connect` does not restart it
- **Catching up with the CLI** before each request and before writing (D-store); a save that fails answers `book_not_written` (a request) or
  `notify/passCompleted` `ok: false` (a pass or scan), and the server goes on

**Why**: a GenServer call is synchronous and a pass can take its REPL's boot plus every entry's timeout; holding every other request for
that long would freeze every window. Serial passes keep two evaluations of one project from overlapping.

**Alternatives**: evaluating inside `handle_call`; parallel passes; a supervisor restarting the server (state would still be lost).

**Files**: `lib/serve_project.exs`, `lib/serve_socket.exs`, `lib/runner.exs`, `lib/store.exs`, `main.exs` (`xipe start`); tests
`test/serve_project_test.exs`, `test/serve_socket_test.exs`.

**Earlier**: `Old.md` §9 (the server's modules), §28 E, §37.2, §56.1; commit 3b39709 (failures as results).

## Notes

- The connection-local state (`initialized?`, declared capabilities, the dialogue slot) lives in `Serve.Socket`, not here: each entrance
  (stdio, WebSocket …) would naturally have its own session
- `Serve.Socket` refuses browser connections by `Origin` (`XIPE_TOTEC_ALLOWED_ORIGINS`): only localhost programs, such as tezcatl's relay,
  connect (`範囲.md`)
- Verified: not yet verified cold (written from the code, 2026-10-19)
