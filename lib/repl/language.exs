defmodule XipeTotec.Repl.Language do
  @moduledoc """
  A language's self-declaration: the per-language facts xipe_totec needs
  that belong to neither `eval_template` (building call expressions) nor
  `field_drip` (reading the `XT_BEGIN`/`XT_END` body) -- Old.md §34.

  One module per language under `lib/repl/language/<name>.exs`; the
  file's basename is the language's name (`elixir.exs` → `"elixir"`),
  the same name `surface_table`'s `language` column carries.

  A module placed here does nothing until `xipe refresh -l`
  (`XipeTotec.Info.refresh_languages/1`) registers it in `info.json`
  (P4). Once registered, `extensions/0` feeds `SurfaceTable`'s language
  detection, `Project` reads `scanner/0` at scan time, and `Runner` reads
  `adapter/0`/`launch_opts/2` at eval time (`XipeTotec.Info.language_module/3`):
  the language a project's surface table names picks the scanner, the REPL
  adapter and how to boot it, nothing else does.

  Each language has one REPL, fixed here (Elixir → `iex`, Haskell →
  GHCi, ...). A build tool changes how that REPL is booted
  (`launch_opts/2`), never which adapter modules read it.

  Planned additions: the build-tool priority table (課題 ②, Old.md §25.4)
  and whether the language needs an `embody` module (Old.md §30).
  """

  @typedoc "The four per-REPL modules `Repl.Evaluator.run_pass/3` takes (`:launch_module` etc.)."
  @type adapter :: %{launch: module(), eval_template: module(), scan: module(), field_drip: module()}

  @doc "File extensions (without the dot) whose files are written in this language."
  @callback extensions() :: [String.t()]

  @doc """
  The `XipeTotec.Scanner` implementation that reads this language's files,
  or several in priority order (spec §11.3) -- `Project.scan_dir/3` uses the
  first whose `begin/3` accepts.
  """
  @callback scanner() :: module() | [module()]

  @doc "This language's REPL adapter -- see `document/repl-adapter-guide.md`."
  @callback adapter() :: adapter()

  @doc """
  How to boot this language's REPL for the project at `root`, whose
  surface table names `build_tool` for this language (`nil` when none was
  detected). Returns `{launch_opts, cleanup}`: `launch_opts` go to the
  adapter's `launch` module, and `cleanup` (0-arity) runs once the pass is
  over (e.g. removing a temp dir the boot needed).
  """
  @callback launch_opts(root :: String.t(), build_tool :: String.t() | nil) :: {keyword(), (-> any())}
end
