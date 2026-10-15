defmodule XipeTotec.Info do
  @moduledoc """
  `info.json` (at xipe_totec's own root): xipe_totec's bookkeeping about
  itself, not about any target project's Book -- which languages/REPLs it
  has adapter modules for (`languages`/`repls`). Which target project is
  selected is not kept here (it is machine-local: `Workspace.selected/1`,
  `tables/selection.json`).

  Its path is resolved from `__DIR__`, so it is found regardless of the
  process's working directory.

  `languages`/`extensions`/`repls` are refreshed from `lib/repl/language/`
  and `lib/repl/eval/scan/<transport>/` by `xipe refresh`, not on every CLI
  invocation: registering an adapter is a deliberate step. `xipe refresh`
  records what is *present*; a file being there does not prove the adapter
  works.
  """

  @default_path Path.expand("../info.json", __DIR__)
  @language_dir Path.expand("repl/language", __DIR__)
  @scan_dir Path.expand("repl/eval/scan", __DIR__)

  @type t :: %{String.t() => term()}

  @doc """
  Loads `path` (default: xipe_totec's own `info.json`) into a plain
  string-keyed map. A missing file is not an error -- returns the same
  empty scaffold `xipe refresh` would start filling in
  (`%{"languages" => [], "extensions" => %{}, "repls" => []}`), so a fresh checkout works before anyone has ever run `xipe
  refresh`.
  """
  @spec load(Path.t()) :: t()
  def load(path \\ @default_path) do
    case read(path) do
      {:ok, info} -> info
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  `{:ok, info}` (the empty scaffold when there is no file), or
  `{:error, message}` when `path` is not readable JSON (a hand edit) or
  cannot be read. The CLI checks it before a command (`xipe refresh -a`
  makes it again), so `load/1` past that point reads a sound file.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path \\ @default_path) do
    case File.read(path) do
      {:ok, content} ->
        case JSON.decode(content) do
          {:ok, %{} = info} -> {:ok, info}
          _ -> {:error, "#{path} is not readable JSON (a hand edit?) -- `xipe refresh -a` makes it again"}
        end

      {:error, :enoent} ->
        {:ok, %{"languages" => [], "extensions" => %{}, "repls" => []}}

      {:error, why} ->
        {:error, "#{path} cannot be read: #{:file.format_error(why)}"}
    end
  end

  @doc "Writes `info` (a plain string-keyed map, JSON-safe values only, same B2 rule `Repl.Launch` follows) to `path` (default: xipe_totec's own `info.json`). -> :ok | {:error, message}"
  @spec save(t(), Path.t()) :: :ok | {:error, String.t()}
  def save(info, path \\ @default_path) when is_map(info) do
    case File.write(path, JSON.encode!(info) <> "\n") do
      :ok -> :ok
      {:error, why} -> {:error, "#{path} could not be written: #{:file.format_error(why)}"}
    end
  end

  @doc """
  Loads every `Repl.Language` module under `dir` (default
  `lib/repl/language/`) and sets:

    * `info["languages"]` -- the sorted language names (file basenames)
    * `info["extensions"]` -- extension → the sorted list of languages
      declaring it (`%{"ex" => ["elixir"], "exs" => ["elixir"]}`). A list,
      not a single name, so a clash (`.h`, `.pl`, `.cljc`, ...) is kept as
      data rather than resolved here; `SurfaceTable` leaves such files'
      `language` as `nil`
    * `info["language_repls"]` -- language → its `repl/0` (`%{"elixir" =>
      "iex"}`), the surface table's `repl` column
    * `info["build_tools"]` -- language → its `build_tools/0` priority list,
      which `SurfaceTable` matches against a project's root to fill the
      `build_tool` column

  A module without `repl/0`/`build_tools/0` records `nil`/`[]`.
  Does not touch `repls`.
  """
  @spec refresh_languages(t(), Path.t()) :: t()
  def refresh_languages(info, dir \\ @language_dir) when is_map(info) do
    declared = list_languages(dir)

    extensions =
      declared
      |> Enum.flat_map(fn {name, mod} -> Enum.map(mod.extensions(), &{&1, name}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {ext, names} -> {ext, Enum.sort(names)} end)

    info
    |> Map.put("languages", declared |> Enum.map(&elem(&1, 0)) |> Enum.sort())
    |> Map.put("extensions", extensions)
    |> Map.put("language_repls", Map.new(declared, fn {name, mod} -> {name, declared_or(mod, :repl, nil)} end))
    |> Map.put("build_tools", Map.new(declared, fn {name, mod} -> {name, declared_or(mod, :build_tools, [])} end))
  end

  defp declared_or(mod, fun, default), do: if(function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: default)

  @doc """
  Re-lists `lib/repl/eval/scan/<transport>/*.exs` (the two-axis layout
  `document/repl-adapter-guide.md` documents) and sets `info["repls"]` to
  `[%{"transport" => ..., "repl" => ...}, ...]`, sorted (today: a single
  `%{"transport" => "direct", "repl" => "iex"}`). Does not touch
  `languages`.
  """
  @spec refresh_repls(t()) :: t()
  def refresh_repls(info) when is_map(info), do: Map.put(info, "repls", list_repls())

  @doc """
  The `Repl.Language` module declaring language `name`, for use at run
  time (`Runner` picks a pass's REPL adapter from it). Only a language
  `xipe refresh -l` has registered in `info["languages"]` resolves --
  the same P4 registration gate as everything else in `info.json`; a
  module merely present under `dir` is `{:error, :not_registered}`.
  """
  @spec language_module(String.t(), t(), Path.t()) :: {:ok, module()} | {:error, :not_registered}
  def language_module(name, info \\ load(), dir \\ @language_dir) do
    if name in (info["languages"] || []),
      do: {:ok, load_language_module(dir, name <> ".exs")},
      else: {:error, :not_registered}
  end

  # `{name, module}` per `<name>.exs` under `dir`.
  defp list_languages(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.sort()
    |> Enum.map(fn file -> {Path.basename(file, ".exs"), load_language_module(dir, file)} end)
  end

  # Require `file` and return whichever module it defines that exports
  # extensions/0 (every `Repl.Language` does).
  defp load_language_module(dir, file) do
    modules = dir |> Path.join(file) |> Code.require_file() |> List.wrap() |> Enum.map(&elem(&1, 0))
    modules = if modules == [], do: loaded_modules_from(Path.join(dir, file)), else: modules
    mod = Enum.find(modules, &function_exported?(&1, :extensions, 0))
    unless mod, do: raise(ArgumentError, "#{file}: no module exporting extensions/0 (see XipeTotec.Repl.Language)")
    mod
  end

  # Code.require_file/1 returns nil for a file already required in this VM
  # (e.g. a test that loaded it first); fall back to the loaded modules
  # whose source is that file.
  defp loaded_modules_from(path) do
    path = Path.expand(path)
    for {mod, _} <- :code.all_loaded(), source = mod.module_info(:compile)[:source], to_string(source) == path, do: mod
  end

  defp list_repls do
    @scan_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@scan_dir, &1)))
    |> Enum.flat_map(fn transport ->
      @scan_dir
      |> Path.join(transport)
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.map(&%{"transport" => transport, "repl" => Path.basename(&1, ".exs")})
    end)
    |> Enum.sort_by(&{&1["transport"], &1["repl"]})
  end
end
