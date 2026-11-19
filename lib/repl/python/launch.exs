Code.require_file("../embody.exs", __DIR__)

defmodule XipeTotec.Repl.Python.Launch do
  @moduledoc """
  Python's `launch` (`python -i`): the same JSON-able message
  `Repl.Launch` builds, with Python's values.

  The REPL is started as `python -i -q -u <init file>`. The init file
  (`init_file/1`, written by `Repl.Language.Python.launch_opts/3`) imports
  `embody.py` -- the fixed module that evaluates and prints for every entry
  (`Repl.Python.EvalTemplate`), kept in its own repository -- and installs
  its import hook for the project's modules, so importing one runs only
  its definitions, imports and literal constants
  ([D-python-adapter](../../../document/verification/lib-repl-language-python.exs.md#d-python-adapter)).
  `message["files"]` stays empty (`Sender.Direct` would turn it into `iex`'s `-r`).

    * `-q`: no banner; `-u`: unbuffered; the `>>> ` / `... ` prompts go to
      stderr and stay in the buffer, inert to `Repl.Eval.Scan`
    * `PYTHONDONTWRITEBYTECODE=1`: nothing (`__pycache__`) is written into
      the project
    * no banner to wait for (`ready_pattern: nil`); `ready_probe` makes the
      REPL print `XT_READY` once the init file is done
    * interruptible: SIGINT stops the running statement (`KeyboardInterrupt`)
      and the REPL goes on reading (checked with Python 3.13.12). A loop
      inside C code (`sum(itertools.count())`) is stopped by neither SIGALRM
      nor SIGINT -- the Evaluator's deadline kills it
    * `restart_after_timeout`: SIGALRM raises inside whatever the call was
      doing, so a module's state may be left half changed; after a
      `timeout` the rest of the pass runs in a new session (`Evaluator`'s
      "A timeout and a new session")
  """

  @doc "`opts`: `:cwd` (required), `:init` (the init file), `:argv` (default `[\"python3\"]`), `:env`."
  @spec build(keyword()) :: %{String.t() => term()}
  def build(opts) do
    argv = Keyword.get(opts, :argv, ["python3"]) ++ ["-i", "-q", "-u"]
    argv = if init = opts[:init], do: argv ++ [init], else: argv

    %{
      "kind" => "repl/launch",
      "argv" => argv,
      "env" => Map.merge(%{"PYTHONDONTWRITEBYTECODE" => "1"}, Keyword.get(opts, :env, %{})),
      "cwd" => Keyword.fetch!(opts, :cwd),
      "files" => [],
      "ready_pattern" => nil,
      # the marker split so an echo of the line can't be taken for it
      "ready_probe" => ~s|print("XT_" + "READY")\n|,
      "exit_input" => "quit()\n",
      "interruptible" => true,
      "restart_after_timeout" => true
    }
  end

  @doc "The directory holding `embody.py` (`Repl.Embody`)."
  @spec embody_dir() :: String.t()
  def embody_dir, do: XipeTotec.Repl.Embody.dir()

  @doc """
  The init file's text: import `embody.py` (from `embody_dir/0`, taken off
  `sys.path` again) as `_xt_embody`, and install its import hook for
  `modules` (`[{name, absolute path}]`).
  """
  @spec init_file([{String.t(), String.t()}]) :: String.t()
  def init_file(modules) do
    map = Enum.map_join(modules, ", ", fn {name, path} -> "#{string(name)}: #{string(path)}" end)

    """
    import sys
    sys.path.insert(0, #{string(embody_dir())})
    import embody as _xt_embody
    del sys.path[0]
    _xt_embody.install({#{map}})
    """
  end

  @doc "A Python string literal for `text` (double-quoted, escapes for `\\\\`, `\"` and control characters)."
  @spec string(String.t()) :: String.t()
  def string(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end
end
