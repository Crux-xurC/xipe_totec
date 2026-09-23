defmodule XipeTotec.Repl.Launch do
  @moduledoc """
  Builds the JSON-able "please launch a REPL for me" message -- pure, no
  process spawning here. Message generation and delivery are kept as two
  separate layers on purpose: xipe_totec must keep working as a standalone
  CLI tool with no relay attached (Old.md §9's "xipe_totecは独立
  ツールとして使われるのが基本"), so the message this module builds has to
  be usable by the bundled `XipeTotec.Repl.Sender.Direct` (spawn it
  locally) just as well as by some future relay-side sender that inserts
  its own steps (e.g. "open a visible xterm for this") before actually
  running it -- neither this module nor the message format itself should
  need to know which one is in play.

  Per B2's rule (already applied in Core -- see `apply_result/3`): every
  value that crosses this boundary must be JSON-encodable as-is (string,
  number, bool, null, or a map/list of those). No atoms, no tuples.

  All language-specific knowledge lives *here* (Old.md §10.2) --
  `argv`/`env`/`cwd`/`files` plus, since 2026-09-18, `ready_pattern`
  (how to recognize the REPL finished booting), `exit_input` (what to
  type in for a graceful shutdown), and, since 2026-09-22 (Old.md
  §23, replacing the removed heartbeat mechanism), `interruptible` (can
  `Sender.interrupt/1`'s SIGINT-to-process-group actually reach and be
  handled by this REPL, or is a hang only ever recoverable by `kill/1`).
  Everything downstream of this module (`Repl.Sender`, `Repl.Session`) is
  generic: it reads these values out of the message and never branches on
  language or project_kind itself.

  Distributed-Erlang connection (node names/cookie/loopback restriction)
  was dropped here 2026-09-18 -- see Old.md §10's pivot note.
  Xipe Totec now drives the target REPL exactly the way a human would
  (type text in via stdin, read text out via stdout/PTY), which is the
  whole reason this tool exists in the first place.
  """

  @default_argv ["iex", "-S", "mix"]
  @default_ready_pattern "Interactive Elixir"
  @default_exit_input "System.halt()\n"
  # Confirmed live 2026-09-22 (Old.md §23): a SIGINT delivered to
  # iex's own process group via erlexec (Sender.Direct, plain pipe, no
  # PTY needed) reaches BEAM's own signal handler and drops it into the
  # "BREAK: (a)bort (A)bort with dump (c)ontinue ..." menu, the same as a
  # real terminal's Ctrl-C -- so `Sender.interrupt/1` is meaningful here.
  @default_interruptible true

  @doc """
  `opts`:
    * `:cwd` (required) -- the target project's root, where the REPL command runs
    * `:argv` -- command argv (default: `#{inspect(@default_argv)}`, mix-mode).
      For `project_kind: scripts` (no `mix.exs`), pass an argv without `-S mix`
      and rely on `:files` (below) to load the target project's sources instead.
    * `:env` -- extra env vars merged into the spawned process's environment
    * `:files` -- source files the target REPL needs loaded (`project_kind:
      scripts`, no `mix.exs` to do this automatically -- crux's own real
      projects, tezcatl included, are all this kind). Carried as plain data
      on `message["files"]`, untouched by this module -- turning a file
      list into actual spawn args (`-r <file>`, or whatever a given `Sender`
      needs) is that sender's job, not this template's. Keeps the message
      itself a stable, relay-agnostic shape: this module only ever decides
      *what values there are*, never *how a process gets built from them*.
    * `:ready_pattern` -- substring to watch for in the output stream that
      means "booted, ready for input" (default: `#{inspect(@default_ready_pattern)}`,
      the iex banner minus its version number, which would otherwise make
      an exact match version-fragile). A **substring**, not a regex --
      keeps the message trivially JSON-safe; upgrade to a regex-source
      string later if substring matching turns out not to be enough.
    * `:exit_input` -- text to write to the REPL's stdin for a graceful
      shutdown (default: `#{inspect(@default_exit_input)}`). Only works
      while the session is actually reading stdin -- a hung session needs
      `Sender.kill/1` instead, not this (Old.md §10.2's caveat).
    * `:interruptible` -- whether `Sender.interrupt/1` (SIGINT to this
      REPL's process group) is expected to reach a handler this REPL
      actually has, rather than just terminating it outright (default:
      `#{@default_interruptible}`). `Evaluator`'s hang handling still
      always falls back to `Sender.kill/1` regardless of this value --
      the difference is only whether it tries the gentler `interrupt/1`
      first and gives it a short grace window before that fallback.
  """
  @spec build(keyword()) :: %{String.t() => term()}
  def build(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    argv = Keyword.get(opts, :argv, @default_argv)
    env = Keyword.get(opts, :env, %{})
    files = Keyword.get(opts, :files, [])
    ready_pattern = Keyword.get(opts, :ready_pattern, @default_ready_pattern)
    exit_input = Keyword.get(opts, :exit_input, @default_exit_input)
    interruptible = Keyword.get(opts, :interruptible, @default_interruptible)

    %{
      "kind" => "repl/launch",
      "argv" => argv,
      "env" => env,
      "cwd" => cwd,
      "files" => files,
      "ready_pattern" => ready_pattern,
      "exit_input" => exit_input,
      "interruptible" => interruptible
    }
  end
end
