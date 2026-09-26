defmodule XipeTotec.Info do
  @moduledoc """
  `info.json` (xipe_totec's own root, Old.md §24): xipe_totec's
  bookkeeping about itself, not about any scanned target project's Book --
  which languages/REPLs it currently has adapter modules for (`languages`/
  `repls`), and which target project is currently selected (`project`,
  still unused until a future `xipe choice project` command writes it --
  §24's co-design deferred that command and its ID-assignment past this
  pass).

  Deliberately **not** CWD-relative like `book.jsonl` (`main.exs`'s
  `@store_file`) -- `book.jsonl`'s own convention (`Store.load/persist_diff`
  read/write wherever the process's CWD happens to be) only works today
  because the nix devShell's `xipe` wrapper always `cd`s to
  `$XIPE_TOTEC_DIR` first (`flake.nix`'s shellHook). `info.json` instead
  resolves its own path from `__DIR__` (this file's location under
  `lib/`), so it finds xipe_totec's own root the same way regardless of
  CWD -- this file's existence doesn't depend on that shellHook detail
  continuing to hold.

  `languages`/`extensions`/`repls` are refreshed from `lib/repl/language/`
  and `lib/repl/eval/scan/<transport>/` (`xipe refresh`, `main.exs`), not
  auto-run on every CLI invocation -- a deliberate registration step
  (P4: "外部提供元は『提案』のみ、受け入れ検査を通ったものだけ採用"), same
  spirit as the file itself, not silent inference. A `.exs` file present
  under either directory is not proof it actually works (`document/
  repl-adapter-guide.md`'s own 4-candidate-language chapter is full of
  "要検証" caveats even once a file exists) -- `xipe refresh` just records
  what's *present*; a crux confirming it live is what makes an entry
  trustworthy, same as every other "実機確認済み" note in Old.md.
  """

  @default_path Path.expand("../info.json", __DIR__)
  @language_dir Path.expand("repl/language", __DIR__)
  @scan_dir Path.expand("repl/eval/scan", __DIR__)

  @type t :: %{String.t() => term()}

  @doc """
  Loads `path` (default: xipe_totec's own `info.json`) into a plain
  string-keyed map. A missing file is not an error -- returns the same
  empty scaffold `xipe refresh` would start filling in
  (`%{"languages" => [], "extensions" => %{}, "repls" => [], "project" =>
  nil}`), so a fresh checkout works before anyone has ever run `xipe
  refresh`.
  """
  @spec load(Path.t()) :: t()
  def load(path \\ @default_path) do
    case File.read(path) do
      {:ok, content} -> JSON.decode!(content)
      {:error, :enoent} -> %{"languages" => [], "extensions" => %{}, "repls" => [], "project" => nil}
    end
  end

  @doc "Writes `info` (a plain string-keyed map, JSON-safe values only, same B2 rule `Repl.Launch` follows) to `path` (default: xipe_totec's own `info.json`)."
  @spec save(t(), Path.t()) :: :ok
  def save(info, path \\ @default_path) when is_map(info) do
    File.write!(path, JSON.encode!(info) <> "\n")
  end

  @doc """
  Loads every `Repl.Language` module under `dir` (default
  `lib/repl/language/`, Old.md §34) and sets:

    * `info["languages"]` -- the sorted language names (file basenames,
      today `["elixir"]`)
    * `info["extensions"]` -- extension → the sorted list of languages
      declaring it (`%{"ex" => ["elixir"], "exs" => ["elixir"]}`). A list,
      not a single name, so a clash (`.h`, `.pl`, `.cljc`, ...) is kept as
      data rather than resolved here; `SurfaceTable` leaves such files'
      `language` as `nil` (P9)
    * `info["language_repls"]` -- language → its `repl/0` (`%{"elixir" =>
      "iex"}`), the surface table's `repl` column
    * `info["build_tools"]` -- language → its `build_tools/0` priority list,
      which `SurfaceTable` matches against a project's root to fill the
      `build_tool` column

  A module without `repl/0`/`build_tools/0` records `nil`/`[]`.
  Does not touch `repls` or `project`.
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
  `languages` or `project`.
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
