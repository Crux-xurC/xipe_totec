# `lib/protocol.exs`

The wire shape, encode and decode only: a request (`id` + `method`), a notify (`method`, no `id`), a response (`id` + `result`/`error`),
each one self-contained JSON object, told apart by shape alone — so a relay passes them through untouched. The reply envelope is built
by `lib/serve_socket.exs`.

**Decisions homed here**: [D-envelope](#d-envelope)
**Takes part in**: D-dialogue-core ([`lib/in_out.exs`](lib-in_out.exs.md))

<a id="d-envelope"></a>

## D-envelope — answers carry `from` and `dialogue`; text for people is not for parsing

**Decided** (2026-09-20, crux): besides JSON-RPC's `result` / `error`, every WebSocket answer has two top-level fields:

- **`from`** — reserved, always `null`: room for telling the windows of one connection apart (the relay broadcasts, so all tabs' messages
  arrive on one connection)
- **`dialogue`** — `{"hold": bool, "via_repl": bool, "text": string | null}`, the dialogue core's tag ([D-dialogue-core](lib-in_out.exs.md#d-dialogue-core));
  `via_repl: true` means the answer involved the REPL (the opposite direction of `Old.md` §17's bit 2)
- **I/O is not for parsing** (crux): `dialogue.text` and strings for people inside `result` are to be shown, never parsed for meaning — unlike
  the REPL markers, which are an internal protocol. tezcatl shows `dialogue.text`; clients hide `id`, `from`, `dialogue` by default and show
  the raw envelope only in a debug or verbose mode
- `notify/*` messages go to every attached session, and are typed like any one-shot reply; who triggered them is not carried (deferred)

**Why**: the same structured answer drives both the CLI's lines and tezcatl's window; a client never has to reverse-engineer human text, and
Xipe Totec may reword it freely.

**Alternatives**: only `result`/`error` (no place for the dialogue state); clients parsing `text`.

**Files**: `lib/protocol.exs`, `lib/serve_socket.exs` (`reply/2`), `lib/in_out.exs`; tests `test/protocol_test.exs`,
`test/serve_socket_test.exs`. tezcatl's side: its D-xipe-dialogue.

**Earlier**: `Old.md` §9 (the wire shape), §17.1 (`notify/*`), §17.2.

## Notes

- Verified: not yet verified cold (written from the code, 2026-10-19)
