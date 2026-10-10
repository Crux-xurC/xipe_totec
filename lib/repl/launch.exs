defmodule XipeTotec.Repl.Launch do
  @moduledoc """
  Builds the JSON-able "please launch a REPL for me" message -- pure, no
  process spawning here. Building the message and delivering it are two
  layers: the bundled `XipeTotec.Repl.Sender.Direct` spawns the process
  locally, and another `Sender` could deliver the same message some other
  way without this module or the message format knowing.

  Every value in the message is JSON-encodable as-is (string, number, bool,
  null, or a map/list of those). No atoms, no tuples.

  All language-specific knowledge lives *here*: `argv`/`env`/`cwd`/`files`,
  `ready_pattern` (how to recognize the REPL finished booting),
  `exit_input` (what to type for a graceful shutdown), and `interruptible`
  (whether `Sender.interrupt/1`'s SIGINT reaches a handler in this REPL, or
  a hang is only recoverable by `kill/1`). Everything downstream
  (`Repl.Sender`, `Repl.Session`) is generic: it reads these values out of
  the message and never branches on language or project kind.

  The target REPL is driven the way a person would: text in on stdin, text
  out on stdout.
  """

  @default_argv ["iex", "-S", "mix"]
  @default_ready_pattern "Interactive Elixir"
  # written once the banner is seen; the REPL answers with the XT_READY
  # marker only once it is actually evaluating input. The
  # marker is split in the source so a REPL echoing its input (a PTY)
  # can't be mistaken for the answer.
  @default_ready_probe ~s|IO.puts("XT_" <> "READY")\n|
  @default_exit_input "System.halt()\n"
  # A SIGINT delivered to iex's process group (Sender.Direct, plain pipe, no
  # PTY) reaches BEAM's signal handler and drops it into the
  # "BREAK: (a)bort (A)bort with dump (c)ontinue ..." menu, as a terminal's
  # Ctrl-C does -- so `Sender.interrupt/1` is meaningful here.
  @default_interruptible true

  @doc """
  `opts`:
    * `:cwd` (required) -- the target project's root, where the REPL command runs
    * `:argv` -- command argv (default: `#{inspect(@default_argv)}`, mix-mode).
      For `project_kind: scripts` (no `mix.exs`), pass an argv without `-S mix`
      and rely on `:files` (below) to load the target project's sources instead.
    * `:env` -- extra env vars merged into the spawned process's environment
    * `:files` -- source files the target REPL needs loaded (`project_kind:
      scripts`, where no `mix.exs` does this). Carried as plain data on
      `message["files"]`; turning the list into spawn args (`-r <file>`, or
      whatever a given `Sender` needs) is that sender's job.
    * `:ready_pattern` -- substring to watch for in the output stream that
      means "booted, ready for input" (default: `#{inspect(@default_ready_pattern)}`,
      the iex banner minus its version number, which would otherwise make
      an exact match version-fragile). A substring, not a regex.
      `nil` skips this stage (a REPL with no banner of its own).
    * `:ready_probe` -- text written to the REPL once the banner (if any)
      has been seen, which must make it print `XT_READY` (default:
      `#{inspect(@default_ready_probe)}`). Seeing `XT_READY` is what proves the
      REPL is reading and evaluating input, not just started. `nil` skips
      this stage.
    * `:exit_input` -- text to write to the REPL's stdin for a graceful
      shutdown (default: `#{inspect(@default_exit_input)}`). Only works
      while the session is actually reading stdin -- a hung session needs
      `Sender.kill/1` instead.
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
    ready_probe = Keyword.get(opts, :ready_probe, @default_ready_probe)
    exit_input = Keyword.get(opts, :exit_input, @default_exit_input)
    interruptible = Keyword.get(opts, :interruptible, @default_interruptible)

    %{
      "kind" => "repl/launch",
      "argv" => argv,
      "env" => env,
      "cwd" => cwd,
      "files" => files,
      "ready_pattern" => ready_pattern,
      "ready_probe" => ready_probe,
      "exit_input" => exit_input,
      "interruptible" => interruptible
    }
  end
end
