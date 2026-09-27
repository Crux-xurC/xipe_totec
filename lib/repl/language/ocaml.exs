Code.require_file("../language.exs", __DIR__)
Code.require_file("../ocaml/launch.exs", __DIR__)
Code.require_file("../ocaml/eval_template.exs", __DIR__)
Code.require_file("../eval/scan/direct/ocaml.exs", __DIR__)
Code.require_file("../eval/field_drip/ocaml.exs", __DIR__)
Code.require_file("../../scanner/ocaml.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Ocaml do
  @moduledoc """
  OCaml's `Repl.Language` self-declaration (Old.md §38/§42). REPL: the
  plain `ocaml` toplevel (not `utop`, crux 2026-09-26) with xipe_totec's
  `embody.ml` loaded into it.

  Only `.ml` files are OCaml sources here (`.mli` are interfaces, nothing
  to scan or load). Every project's own code is loaded the same way: each
  `.ml` as the module its file name gives, without its top-level side
  effects (`Embody.load_all`), in an order their dependencies allow.

  A dune project (`dune-project`, the build tool) adds two things (Old.md
  §43):

    * the libraries it depends on -- `dune ocaml top`'s directives, run
      inside the toplevel (the project's environment: its `OCAMLPATH`, its
      dune), without the lines for the project's own libraries, whose
      top-level effects loading them would run. dune builds the project
      for this (`_build/` in the project)
    * a wrapped library's name: code outside a library says
      `Mylib.Words`, so `module Mylib = struct module Words = Words ... end`
      is defined from the `dune` file's `(library (name mylib))` and the
      library directory's files -- not for `(wrapped false)`, nor when the
      library has its own `mylib.ml`
  """
  @behaviour XipeTotec.Repl.Language

  alias XipeTotec.Repl.Ocaml.Launch

  @impl true
  def extensions, do: ["ml"]

  @impl true
  def repl, do: "ocaml"

  @impl true
  def build_tools, do: [%{"name" => "dune", "markers" => ["dune-project"]}]

  @impl true
  def scanner, do: [XipeTotec.Scanner.Ocaml]

  @impl true
  def adapter do
    %{
      launch: XipeTotec.Repl.Ocaml.Launch,
      eval_template: XipeTotec.Repl.Ocaml.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Ocaml,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.Ocaml
    }
  end

  # the init file, and the sanitized copies embody writes, in one temp dir
  # removed after the pass
  @impl true
  def launch_opts(root, build_tool, files) do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_ocaml_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "src"))
    init = Path.join(dir, "init.ml")

    extra = if build_tool == "dune", do: [dune_root: Path.expand(root), aliases: dune_aliases(root, files)], else: []
    File.write!(init, Launch.init_file(Path.join(dir, "src"), Enum.map(files, &Path.join(root, &1)), extra))
    {[init: init], fn -> File.rm_rf!(dir) end}
  end

  @doc """
  The alias modules a dune project's wrapped libraries need:
  `[{"Mylib", ["Stats", "Words"]}]` for a directory whose `dune` file says
  `(library (name mylib))`, its members the modules of that directory's
  files among `files`. None for `(wrapped false)`, for a library with its
  own main module (`mylib.ml`), or for a `dune` file with several libraries.
  """
  @spec dune_aliases(String.t(), [String.t()]) :: [{String.t(), [String.t()]}]
  def dune_aliases(root, files) do
    files
    |> Enum.group_by(&Path.dirname/1)
    |> Enum.sort()
    |> Enum.flat_map(fn {dir, in_dir} ->
      members = in_dir |> Enum.map(&XipeTotec.Scanner.Ocaml.module_name/1) |> Enum.sort()

      case library(Path.join([root, dir, "dune"])) do
        {:ok, name} ->
          lib = XipeTotec.Scanner.Ocaml.module_name(name <> ".ml")
          if lib in members, do: [], else: [{lib, members}]

        :none ->
          []
      end
    end)
  end

  # the one wrapped library a dune file declares
  defp library(path) do
    with {:ok, text} <- File.read(path),
         text = Regex.replace(~r/;[^\n]*/, text, ""),
         [_one] <- Regex.scan(~r/\(library\b/, text),
         [_, name] <- Regex.run(~r/\(library\b.*?\(name\s+([A-Za-z_][A-Za-z0-9_']*)\s*\)/s, text),
         false <- Regex.match?(~r/\(wrapped\s+false\s*\)/, text) do
      {:ok, name}
    else
      _ -> :none
    end
  end
end
