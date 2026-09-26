Code.require_file("../language.exs", __DIR__)
Code.require_file("../launch.exs", __DIR__)
Code.require_file("../eval_template.exs", __DIR__)
Code.require_file("../eval/scan/direct/iex.exs", __DIR__)
Code.require_file("../eval/field_drip/elixir.exs", __DIR__)
Code.require_file("../source_sanitize.exs", __DIR__)
Code.require_file("../../project.exs", __DIR__)
Code.require_file("../../scanner/elixir.exs", __DIR__)
Code.require_file("../../scanner/lsp/elixir.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Elixir do
  @moduledoc "Elixir's `Repl.Language` self-declaration. REPL: `iex`."
  @behaviour XipeTotec.Repl.Language

  alias XipeTotec.Repl.SourceSanitize

  @impl true
  def extensions, do: ["ex", "exs"]

  @impl true
  def repl, do: "iex"

  # no match: scripts-mode (launch_opts/3's catch-all)
  @impl true
  def build_tools, do: [%{"name" => "mix", "markers" => ["mix.exs"]}]

  # elixir-ls through tezcatl's /lsp first; Elixir's own parser when no
  # language server is reachable (spec §11.3)
  @impl true
  def scanner, do: [XipeTotec.Scanner.Lsp.Elixir, XipeTotec.Scanner.Elixir]

  @impl true
  def adapter do
    %{
      launch: XipeTotec.Repl.Launch,
      eval_template: XipeTotec.Repl.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Iex,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.Elixir
    }
  end

  # mix-mode: empty launch_opts, i.e. `Launch`'s own `iex -S mix` default.
  #
  # scripts-mode: `iex` with every project file `-r`'d -- never the
  # *original* files (review finding, 2026-09-18): `-r` runs a script's whole
  # top level, so a project with an entry-point script (xipe_totec's/
  # tezcatl's own `main.exs` included) would run its side effects just from
  # booting the session. `SourceSanitize.sanitize/2` writes defmodule-only
  # copies to a temp dir instead, removed by the returned cleanup.
  @impl true
  def launch_opts(_root, "mix", _files), do: {[], fn -> :ok end}

  def launch_opts(root, _build_tool, files) do
    {tmp_dir, files} = SourceSanitize.sanitize(root, files)
    {[argv: ["iex"], files: files], fn -> File.rm_rf!(tmp_dir) end}
  end
end
