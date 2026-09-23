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

  `repl`/`build_tool` are filled in **only for `language: "elixir"`
  rows, and only the one build tool this codebase already knew how to
  detect** (§26's co-design, following on from §25.5's placeholder
  version): `build_tool` is `"mix"` when `mix.exs` exists at `dir`'s
  root, `nil` otherwise (the exact check `Runner.launch_opts_for/2` used
  to make inline -- moved here, not duplicated, `launch_opts_for/2` now
  reads it off these rows instead); `repl` is always `"iex"` for Elixir,
  since Elixir has exactly one REPL regardless of build tool. Every
  *other* language, and every other build tool (Haskell's `stack.yaml`/
  `*.cabal`, a project's own `flake.nix`/`shell.nix` needing a `nix
  develop <root> --command <argv>` wrap, §25.2/§25.6) is still
  undetected -- those rows keep `repl`/`build_tool` as `nil`, same as an
  unrecognized `language`. This is deliberately the minimal real slice,
  not the general priority-table design (§25.4: per-language
  self-declared marker→launch-recipe tables) -- that stays future work;
  this pass only had one build tool to detect that wasn't already a
  ~5-line inline check duplicated across two modules.

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
  to `:sheets`. `extensions` (default: `info.json`'s, see moduledoc) is
  the extension → languages map; tests pass their own.
  """
  @spec generate(String.t(), t(), %{String.t() => [String.t()]} | nil) :: t()
  def generate(dir, old_rows \\ [], extensions \\ nil) do
    extensions = extensions || XipeTotec.Info.load()["extensions"] || %{}
    id_by_path = Map.new(old_rows, &{&1["path"], &1["id"]})
    elixir_build_tool = if File.exists?(Path.join(dir, "mix.exs")), do: "mix"

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
        "repl" => if(language == "elixir", do: "iex"),
        "build_tool" => if(language == "elixir", do: elixir_build_tool)
      }
    end)
  end

  defp language_for(path, extensions) do
    ext = path |> Path.extname() |> String.trim_leading(".")
    case Map.get(extensions, ext) do
      [language] -> language
      _ -> nil
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
