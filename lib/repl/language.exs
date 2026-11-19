defmodule XipeTotec.Repl.Language do
  @moduledoc """
  A language's self-declaration: the per-language facts xipe_totec needs
  that belong to neither `eval_template` (building call expressions) nor
  `field_drip` (reading the `XT_BEGIN`/`XT_END` body).

  One module per language under `lib/repl/language/<name>.exs`; the
  file's basename is the language's name (`elixir.exs` → `"elixir"`),
  the same name `surface_table`'s `language` column carries.

  A module placed here does nothing until `xipe refresh -l`
  (`XipeTotec.Info.refresh_languages/1`) registers it in `info.json`.
  Once registered, `extensions/0` feeds `SurfaceTable`'s language
  detection, `Project` reads `scanner/0` at scan time, and `Runner` reads
  `adapter/0`/`launch_opts/3` at eval time (`XipeTotec.Info.language_module/3`):
  the language a project's surface table names picks the scanner, the REPL
  adapter and how to boot it, nothing else does.

  Each language has one REPL, fixed here (Elixir → `iex`, Haskell →
  GHCi, ...). A build tool changes how that REPL is booted
  (`launch_opts/3`), never which adapter modules read it.

  **A map-only language** declares no REPL: it leaves out `repl/0`,
  `adapter/0` and `launch_opts/3`. Its files are scanned (cards, links,
  `search`, `graph/*`) but its functions are not evaluated: `row/add`
  refuses them and `eval` leaves such rows `not_run`
  ([D-map-only-language](../../document/verification/lib-repl-language.exs.md#d-map-only-language)).
  """

  @typedoc "The four per-REPL modules `Repl.Evaluator.run_pass/3` takes (`:launch_module` etc.)."
  @type adapter :: %{launch: module(), eval_template: module(), scan: module(), field_drip: module()}

  @doc "File extensions (without the dot) whose files are written in this language."
  @callback extensions() :: [String.t()]

  @doc "This language's REPL (`\"iex\"` for Elixir), the surface table's `repl` column."
  @callback repl() :: String.t()

  @doc """
  The build tools a project in this language may use, highest priority
  first: `[%{"name" => name, "markers" => [glob]}]`. The first whose
  marker matches a file at the project's root (`Path.wildcard/1`, e.g.
  `"mix.exs"`, `"*.cabal"`) is the project's `build_tool` for this
  language (surface table); none matching is `nil`. The name is what
  `launch_opts/3` gets back. `xipe refresh -l` records this in info.json.
  """
  @callback build_tools() :: [%{String.t() => term()}]

  @doc """
  The `XipeTotec.Scanner` implementation that reads this language's files,
  or several in priority order -- `Project.scan_dir/3` uses the
  first whose `begin/3` accepts.
  """
  @callback scanner() :: module() | [module()]

  @doc "This language's REPL adapter -- see `document/repl-adapter-guide.md`."
  @callback adapter() :: adapter()

  @doc """
  How to boot this language's REPL for the project at `root`, whose
  surface table names `build_tool` for this language (`nil` when none was
  detected) and `files` (paths relative to `root`) as this language's
  source files, Mix's own files left out (`Project.sheets_in/2`). Returns `{launch_opts, cleanup}`: `launch_opts` go to the
  adapter's `launch` module, and `cleanup` (0-arity) runs once the pass is
  over (e.g. removing a temp dir the boot needed).
  """
  @callback launch_opts(root :: String.t(), build_tool :: String.t() | nil, files :: [String.t()]) :: {keyword(), (-> any())}

  @optional_callbacks repl: 0, adapter: 0, launch_opts: 3

  @doc "Whether the declaration `mod` has a REPL (`false`: a map-only language)."
  @spec evaluated?(module()) :: boolean()
  def evaluated?(mod) do
    Code.ensure_loaded(mod)
    function_exported?(mod, :repl, 0) and function_exported?(mod, :adapter, 0) and function_exported?(mod, :launch_opts, 3)
  end

  @doc "The reason a map-only language's row is not evaluated (`row/add`'s refusal, `eval`'s `not_run`)."
  @spec map_only_reason(String.t()) :: String.t()
  def map_only_reason(language),
    do: "#{language} is a map-only language: its functions are scanned (cards, links), not evaluated"
end
