defmodule XipeTotec.Repl.Sender do
  @moduledoc """
  The abstracted "input" layer (see the co-design discussion, 2026-09-18):
  `Repl.Launch` only ever produces a JSON-able message describing what
  should happen; a `Sender` is the thing that actually makes it happen.

  `XipeTotec.Repl.Sender.Direct` (this file's sibling) is the bundled
  default -- spawns the process locally, no relay needed, so xipe_totec
  keeps working standalone. A relay-backed sender (e.g. one that hands the
  message to tezcatl so the launch runs inside a visible browser terminal,
  inserting whatever steps that needs -- "open an xterm" and so on) can
  implement this same behaviour without either side needing to change.
  That relay-side piece is explicitly out of scope here: it belongs to
  tezcatl and isn't being built from this repo.

  `write/2` and `kill/1` (2026-09-18, Old.md §10.2) were added once a
  second and third real need showed up -- sending `exit_input` (or, later,
  a marker-wrapped eval request) needs a way to write to the running
  session's stdin, and a hung session (not reading stdin) needs a way to
  force it down that doesn't depend on the session cooperating. Both are
  generic: neither one knows or cares what text is being written or why --
  that's `Repl.Launch`/`Repl.Session`'s job.

  `interrupt/1` (2026-09-22, Old.md §23, replacing the removed
  heartbeat mechanism) is a gentler alternative to `kill/1` for a hung
  entry: sends SIGINT to the whole process group (not just the direct
  child) rather than SIGKILL. Whether the target REPL actually has a
  handler for it (vs. just dying, same as `kill/1` would do anyway) is
  `message["interruptible"]` (`Repl.Launch`'s own field) -- `Evaluator`
  still always falls back to `kill/1` after a short grace window
  regardless, so a `false`/wrong-guess `interruptible` costs a little
  wasted wait time, never a stuck session.

  ## The handle contract (2026-09-18, made explicit after review; revised
  ## 2026-09-18 to a single message shape after the PTY-vs-plain-pipe
  ## liveness discussion)

  **Push only, never pull, and exactly one message shape.** Whatever
  `handle` a `send/1` implementation returns, it MUST deliver everything
  to the calling process as:

    * `{handle, {:data, binary()}}` -- a chunk of output, as it happens

  There is no `receive/1`-style "give me whatever's buffered right now"
  callback in this behaviour, and there must never be one added: a
  PTY-backed transport (the whole reason this behaviour exists as an
  abstraction in the first place -- see the co-design discussion above)
  has no "go check" operation. Bytes that already streamed past are gone;
  a pull-shaped receiver would just see no data.

  **Process exit is not a separate message type -- it's a reserved text
  marker inside the same `:data` stream.** A raw `Port` reports exit via
  `{:exit_status, n}`, but an erlexec/PTY-backed transport (tezcatl's own
  `PtyFlow`, for example) reports it via a `:DOWN` monitor message
  instead -- two different native shapes an implementation would otherwise
  each have to translate into some agreed struct. Rather than push that
  translation burden onto every future implementation (and onto every
  receiver, which would need to understand both structured shapes and
  reason about their relative ordering against buffered `:data`), each
  `send/1` implementation synthesizes one final `:data` chunk when its
  process ends:

      "XT_EXIT <status>\n"

  (matching the `XT_BEGIN_<uid>`/`XT_END_<uid>` marker convention used
  elsewhere in the REPL text protocol). This is the *only* place liveness
  information ever appears -- a receiver watching for it doesn't need to
  know or care whether the underlying transport was a plain pipe or a
  PTY. `Sender.Direct` does NOT get this for free the way it got `:data`
  messages for free from a raw `Port` -- it has to explicitly catch the
  real `{:exit_status, n}` message and re-emit it as this marker itself
  (see its `forward_loop/2`), which is why `Direct`'s `handle` is a plain
  forwarding `pid()`, not the raw `Port` anymore.

  A `message["files"]` field (2026-09-18, `project_kind: scripts`) is
  deliberately left as opaque data by `Launch` -- *how* a file list turns
  into actual spawn args is a delivery-mechanism decision (a plain `Port`
  spawn wants `-r <file>` args; a future relay-backed sender might not),
  so each `send/1` implementation is responsible for interpreting it. See
  `Sender.Direct.with_files/2` for the bundled default's choice.

  ## `write/2` and `kill/1` (2026-09-18)

  * `write(handle, text)` -- best-effort: writes `text` to the running
    session's stdin. Whatever effect it has (if any) shows up later as
    ordinary `{handle, {:data, ...}}` output, same as everything else --
    `write/2` itself doesn't report the session's reaction, only whether
    the write was accepted by the transport. **Does nothing useful against
    a session that isn't reading stdin** (busy evaluating, or hung) --
    text just queues up unread. This is why `exit_input` (a graceful
    `write/2`) is not a substitute for `kill/1` on a hung session
    (Old.md §10.2's caveat) -- only `kill/1` is guaranteed to end it.
  * `kill(handle)` -- forceful, unconditional: ends the session regardless
    of what it's doing. Signals the *whole process group* the session was
    launched into (2026-09-22), not just the direct child -- a REPL that
    forks its own children (an `iex -S mix` build step, say) would
    otherwise leave those orphaned. Still expected to eventually produce
    the `"XT_EXIT <status>"` marker (§ above) through the normal `:data`
    channel, same as a graceful exit -- callers don't need a different
    code path to notice it happened.
  * `interrupt(handle)` (2026-09-22) -- gentler, best-effort: sends SIGINT
    to the same process group `kill/1` targets. Whether this actually
    interrupts the target REPL's current evaluation (vs. terminating it
    outright, vs. doing nothing it notices at all) is entirely up to that
    REPL/language -- this callback only promises the signal was sent, not
    any particular reaction. Callers that need a guaranteed end still call
    `kill/1` afterward; `interrupt/1` exists only to give a
    signal-handling REPL a chance to shut down (or recover) more
    gracefully first.
  """

  @callback send(message :: %{String.t() => term()}) :: {:ok, handle :: term()} | {:error, term()}
  @callback write(handle :: term(), text :: String.t()) :: :ok | {:error, term()}
  @callback kill(handle :: term()) :: :ok | {:error, term()}
  @callback interrupt(handle :: term()) :: :ok | {:error, term()}
end
