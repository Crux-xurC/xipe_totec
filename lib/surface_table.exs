Code.require_file("id.exs", __DIR__)
Code.require_file("info.exs", __DIR__)

defmodule XipeTotec.SurfaceTable do
  @moduledoc """
  `surface_table` (Old.md §24): a project's file tree, flattened to
  one row per file -- `id`/`path`/`depth`/`language`/`repl`/`build_tool`.
  Deliberately shallow (no code-level parsing, unlike `Scanner`) -- it
  exists so a future multi-language `xipe table generate`/`xipe choice
  project` can tell which files belong to which language *before*
  deciding which `Scanner`/REPL adapter to run over them, not to replace
  `Scanner` itself.

  `repl`/`build_tool` come from each language's own declaration
  (`Repl.Language.repl/0`/`build_tools/0`, recorded in info.json's
  `language_repls`/`build_tools` by `xipe refresh -l`, Old.md §25.4,
  2026-09-26): a row's `repl` is its language's REPL, and its `build_tool`
  the first of its language's build tools with a marker matching at
  `dir`'s root (`nil` when none does, or for a row with no language). The
  check runs when the table is generated, not on every use -- a build tool
  added later is picked up by `xipe table generate`. Rows of different
  languages in one project can carry different build tools.

  `language` comes from `info.json`'s `extensions` map (extension → the
  languages declaring it), which `xipe refresh -l` builds from each
  `Repl.Language` module's own `extensions/0` (Old.md §34). An extension
  exactly one language declares gets that language; one no language
  declares, or one two or more languages both declare (`.h`, `.pl`,
  `.cljc`, ...), gets `nil` -- an undecidable file is shown as undecided
  (P9), not guessed at. Settling such a file by hand is a separate,
  planned surface-table update command (課題.md).

  Regeneration is a **full overwrite**, not an append-log (`generate/2`'s
  `old_rows` is read once, upfront, purely to keep `id`s stable across
  reruns -- same `Identity`-module spirit `:sheets`/`:nodes` already use,
  reused here directly rather than through `Identity` itself since this
  table doesn't live in `Book`/`book.jsonl`, §24.1's storage-location
  decision) -- deliberately not an incremental diff, per §21.1's own
  conclusion that a full `scan/run`-style re-derivation sidesteps the
  staleness/consistency problems an incremental design would otherwise
  have to solve.
  """

  alias XipeTotec.Id

  @type row :: %{String.t() => term()}
  @type t :: [row()]

  @doc """
  Walks every file (not just source files -- an unrecognized extension
  gets `language: nil`, not excluded) under `dir`, returning fresh rows
  sorted by path. `old_rows` (default `[]`, the previous `generate/2`
  result or `load/1`'s output) is consulted only to reuse an existing
  row's `id` for the same `path` -- a path with no match in `old_rows`
  gets a brand new `Id.ulid()`, same rule `Identity.sheet_id/2` applies
  to `:sheets`. `info` (default: xipe_totec's info.json) supplies
  `extensions`, `language_repls` and `build_tools` (see moduledoc); tests
  pass their own.
  """
  @spec generate(String.t(), t(), map() | nil) :: t()
  def generate(dir, old_rows \\ [], info \\ nil) do
    info = info || XipeTotec.Info.load()
    extensions = info["extensions"] || %{}
    repls = info["language_repls"] || %{}
    id_by_path = Map.new(old_rows, &{&1["path"], &1["id"]})
    build_tools = Map.new(info["build_tools"] || %{}, fn {language, tools} -> {language, detect_build_tool(dir, tools)} end)

    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
    |> Enum.map(fn path ->
      language = language_for(path, extensions)

      %{
        "id" => Map.get(id_by_path, path) || Id.ulid(),
        "path" => path,
        "depth" => path |> Path.split() |> length(),
        "language" => language,
        "repl" => Map.get(repls, language),
        "build_tool" => Map.get(build_tools, language)
      }
    end)
  end

  # the first declared build tool with a marker matching at dir's root
  defp detect_build_tool(dir, tools) do
    Enum.find_value(tools, fn %{"name" => name} = tool ->
      if Enum.any?(tool["markers"] || [], &(dir |> Path.join(&1) |> Path.wildcard() |> Enum.any?(fn p -> not File.dir?(p) end))),
        do: name
    end)
  end

  defp language_for(path, extensions) do
    ext = path |> Path.extname() |> String.trim_leading(".")
    case Map.get(extensions, ext) do
      [language] -> language
      _ -> nil
    end
  end

  @doc """
  The rows a scan or an eval pass works from (課題 ④). With a saved
  `table_file`, its rows as they are -- unless the table is empty (never
  generated) or one of its paths no longer exists under `dir`, in which
  case the table is regenerated (`generate/3`, reusing ids) and saved
  first. Only a missing path triggers this: a file added to `dir` after
  the table was generated stays out until `xipe table generate` is run.

  Without a `table_file` (a caller that has no registered project, e.g. a
  test calling `Project.scan_dir/3` on a temp dir), rows are generated on
  the spot and not saved -- the pre-④ behavior.
  """
  @spec rows(String.t(), Path.t() | nil, map() | nil) :: t()
  def rows(dir, table_file, info \\ nil)

  def rows(dir, nil, info), do: generate(dir, [], info)

  def rows(dir, table_file, info) do
    saved = load(table_file)

    if saved == [] or Enum.any?(saved, &(not File.exists?(Path.join(dir, &1["path"])))) do
      fresh = generate(dir, saved, info)
      save(fresh, table_file)
      fresh
    else
      saved
    end
  end

  @doc "Loads `path`'s rows (`[]` if the file doesn't exist yet -- no `surface_table` has ever been generated for this project)."
  @spec load(Path.t()) :: t()
  def load(path) do
    case File.read(path) do
      {:ok, content} -> JSON.decode!(content)
      {:error, :enoent} -> []
    end
  end

  @doc "Writes `rows` to `path` as a full JSON array -- see moduledoc, this always replaces the whole file."
  @spec save(t(), Path.t()) :: :ok
  def save(rows, path) when is_list(rows) do
    File.write!(path, JSON.encode!(rows) <> "\n")
  end
end
