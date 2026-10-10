defmodule XipeTotec.Repl.Sender do
  @moduledoc """
  The delivery layer: `Repl.Launch` only produces a JSON-able message
  describing what should happen; a `Sender` makes it happen.

  `XipeTotec.Repl.Sender.Direct` is the bundled default -- it spawns the
  process locally. Another sender (e.g. one that runs the launch inside a
  visible terminal) can implement this same behaviour.

  `write/2` and `kill/1` are generic: neither knows what text is being
  written or why -- that's `Repl.Launch`/`Repl.Session`'s job.

  `interrupt/1` is a gentler alternative to `kill/1` for a hung entry: it
  sends SIGINT to the whole process group rather than SIGKILL. Whether the
  target REPL has a handler for it is `message["interruptible"]`
  (`Repl.Launch`). `Evaluator` always falls back to `kill/1` after a short
  grace window, so a wrong `interruptible` costs a little wait, never a
  stuck session.

  ## The handle contract

  **Push only, never pull, and exactly one message shape.** Whatever
  `handle` a `send/1` implementation returns, it MUST deliver everything
  to the calling process as:

    * `{handle, {:data, binary()}}` -- a chunk of output, as it happens

  There is no "give me whatever is buffered" callback, and none may be
  added: a PTY-backed transport has no such operation. Bytes that already
  streamed past are gone.

  **Process exit is not a separate message type -- it is a reserved text
  marker inside the same `:data` stream.** Transports report exit in
  different native shapes (a `Port`'s `{:exit_status, n}`, erlexec's
  `:DOWN`). Each `send/1` implementation turns its own into one final
  `:data` chunk when its process ends:

      "XT_EXIT <status>\n"

  This is the only place liveness information appears, so a receiver
  doesn't need to know what the underlying transport is.

  `message["files"]` is opaque data to `Launch`: how a file list becomes
  spawn args is each `send/1` implementation's decision (see
  `Sender.Direct.with_files/2`).

  ## `write/2` and `kill/1`

  * `write(handle, text)` -- best-effort: writes `text` to the running
    session's stdin. Whatever effect it has (if any) shows up later as
    ordinary `{handle, {:data, ...}}` output, same as everything else --
    `write/2` itself doesn't report the session's reaction, only whether
    the write was accepted by the transport. **Does nothing useful against
    a session that isn't reading stdin** (busy evaluating, or hung) --
    text just queues up unread. This is why `exit_input` (a graceful
    `write/2`) is not a substitute for `kill/1` on a hung session -- only
    `kill/1` is guaranteed to end it.
  * `kill(handle)` -- forceful, unconditional: ends the session regardless
    of what it's doing. Signals the *whole process group* the session was
    launched into, not just the direct child -- a REPL that
    forks its own children (an `iex -S mix` build step, say) would
    otherwise leave those orphaned. Still expected to eventually produce
    the `"XT_EXIT <status>"` marker through the normal `:data`
    channel, same as a graceful exit -- callers don't need a different
    code path to notice it happened.
  * `interrupt(handle)` -- gentler, best-effort: sends SIGINT
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
