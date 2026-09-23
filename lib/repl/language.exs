defmodule XipeTotec.Repl.Language do
  @moduledoc """
  A language's self-declaration: the per-language facts xipe_totec needs
  that belong to neither `eval_template` (building call expressions) nor
  `field_drip` (reading the `XT_BEGIN`/`XT_END` body) -- Old.md §34.

  One module per language under `lib/repl/language/<name>.exs`; the
  file's basename is the language's name (`elixir.exs` → `"elixir"`),
  the same name `surface_table`'s `language` column carries.

  Nothing reads these modules at runtime. `xipe refresh -l`
  (`XipeTotec.Info.refresh_languages/1`) loads them once and records
  what they declare in `info.json` -- a module placed here does nothing
  until that deliberate registration step (P4), same as the rest of
  `info.json`.

  Only `extensions/0` for now. Planned additions, each a per-language
  fact that would otherwise end up hardcoded somewhere language-neutral:
  the build-tool priority table (課題 ②, Old.md §25.4) and whether the
  language needs an `embody` module (Old.md §30).
  """

  @doc "File extensions (without the dot) whose files are written in this language."
  @callback extensions() :: [String.t()]
end
