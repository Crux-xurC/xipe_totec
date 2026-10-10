Code.require_file("../embody.exs", __DIR__)

defmodule XipeTotec.Repl.Ocaml.Launch do
  @moduledoc """
  OCaml's `launch` (the plain `ocaml` toplevel): the same
  JSON-able message `Repl.Launch` builds, with OCaml's values.

  The toplevel is started as `ocaml -init <init file>`. The init file
  (`init_file/3`, written by `Repl.Language.Ocaml.launch_opts/3`) loads
  `embody.ml` -- the fixed module that evaluates and prints for every entry
  (`Repl.Ocaml.EvalTemplate`), kept in its own repository (`embody_path/0`,
  its ReadMe.md) -- and the project's files, each
  as the module its name gives and without its top-level side effects
  (`Embody.load_all`). So `message["files"]` stays empty: `Sender.Direct`
  turns files into `iex`'s `-r`, which means nothing here.

    * no banner to wait for (`ready_pattern: nil`); `ready_probe` makes the
      toplevel print `XT_READY` once the init file is done
    * `exit_input` is `#quit;;`
    * interruptible: SIGINT stops the running phrase ("Interrupted.") and
      the toplevel goes on reading (seen with OCaml 5.5.0)
  """


  @doc "`opts`: `:cwd` (required), `:init` (the init file), `:argv` (default `[\"ocaml\"]`), `:env`."
  @spec build(keyword()) :: %{String.t() => term()}
  def build(opts) do
    argv = Keyword.get(opts, :argv, ["ocaml"])
    argv = if init = opts[:init], do: argv ++ ["-init", init], else: argv

    %{
      "kind" => "repl/launch",
      "argv" => argv,
      "env" => Keyword.get(opts, :env, %{}),
      "cwd" => Keyword.fetch!(opts, :cwd),
      "files" => [],
      "ready_pattern" => nil,
      # the marker split so the toplevel echoing the phrase can't be taken for it
      "ready_probe" => ~s|print_endline ("XT_" ^ "READY");;\n|,
      "exit_input" => "#quit;;\n",
      "interruptible" => true
    }
  end

  @doc """
  `embody.ml`'s path: in `$XIPE_TOTEC_EMBODY_DIR`, else the `embody`
  directory next to this xipe_totec checkout (`~/my_app/embody`). embody is
  its own repository; when it isn't there, every entry is a crash saying
  `Unbound module Embody`.
  """
  @spec embody_path() :: String.t()
  def embody_path, do: XipeTotec.Repl.Embody.path("embody.ml")

  @doc """
  The init file's text: the toplevel's libraries `embody.ml` needs, then
  `embody.ml`, then every file in `paths` (absolute) loaded through it with
  its sanitized copies in `dir`. `opts` (a dune project):

    * `:dune_root` -- first load the libraries the project depends on, as
      `dune ocaml top` in that directory gives them (`Embody.dune_deps`)
    * `:aliases` -- `[{"Library", ["Member", ...]}]`, a wrapped dune
      library's alias module, defined once its members are loaded
  """
  @spec init_file(String.t(), [String.t()], keyword()) :: String.t()
  def init_file(dir, paths, opts \\ []) do
    deps = if root = opts[:dune_root], do: "Embody.dune_deps #{string(root)};;\n", else: ""

    aliases =
      Enum.map_join(Keyword.get(opts, :aliases, []), "; ", fn {lib, members} ->
        "(#{string(lib)}, [#{Enum.map_join(members, "; ", &string/1)}])"
      end)

    """
    #directory "+compiler-libs";;
    #directory "+unix";;
    #load "unix.cma";;
    #mod_use #{string(embody_path())};;
    #{deps}Embody.load_all ~aliases:[#{aliases}] #{string(dir)} [#{Enum.map_join(paths, "; ", &string/1)}];;
    """
  end

  @doc "An OCaml string literal for `text`."
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
