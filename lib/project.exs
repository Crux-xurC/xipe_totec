Code.require_file("id.exs", __DIR__)
Code.require_file("book.exs", __DIR__)
Code.require_file("identity.exs", __DIR__)
Code.require_file("core.exs", __DIR__)
Code.require_file("scanner.exs", __DIR__)
Code.require_file("store.exs", __DIR__)
Code.require_file("surface_table.exs", __DIR__)
Code.require_file("info.exs", __DIR__)

defmodule XipeTotec.Project do
  @moduledoc """
  Orchestrates a directory scan (spec §14.1): the two-pass
  `scan_defs/3` then `scan_links_report/3` sequencing a single file cannot
  do alone (a cross-file callee must already be registered before links
  are resolved -- see `XipeTotec.Scanner`'s moduledoc), with each file read
  by its own language's scanner.

  Kept separate from `XipeTotec.Core`: this module does real I/O (reading
  source files, appending to the Store), so it is deliberately *not* part
  of the pure Core.
  """

  alias XipeTotec.{Book, Core, Id, Identity, Info, Store, SurfaceTable}

  @doc """
  Every file under `dir` that a scan reads, as `%{path:, language:}` sorted
  by path: the files whose surface-table `language` is registered in
  info.json (`xipe refresh -l`). Each language's own `Repl.Language.scanner/0`
  reads them (`scan_dir/2`) -- nothing here knows which languages exist.

  Mix's own files are left out: `mix.exs` (build configuration, not project
  code -- its `use Mix.Project` can't even compile outside a running Mix)
  and everything under `deps/` and `_build/` (third-party sources and build
  output). Only the top level of `dir` is checked for these.
  """
  @spec sheets(String.t(), Info.t()) :: [%{path: String.t(), language: String.t()}]
  def sheets(dir, info \\ Info.load()) do
    registered = info["languages"] || []

    for row <- SurfaceTable.generate(dir, [], info["extensions"] || %{}),
        row["language"] in registered,
        not mix_own_file?(row["path"]),
        do: %{path: row["path"], language: row["language"]}
  end

  @doc """
  `sheets/1`'s paths, optionally only `language`'s. Elixir's scripts-mode
  REPL boot `-r`s `find_sheets(root, "elixir")` (via `SourceSanitize`).
  """
  @spec find_sheets(String.t(), String.t() | nil) :: [String.t()]
  def find_sheets(dir, language \\ nil) do
    for sheet <- sheets(dir), language in [nil, sheet.language], do: sheet.path
  end

  defp mix_own_file?(path) do
    case Path.split(path) do
      ["mix.exs"] -> true
      [top | _] -> top in ["deps", "_build"]
    end
  end

  @doc """
  Scan every file `sheets/1` lists into `book`, each with its language's
  scanner. Returns `{book, paths, link_failures}` -- `link_failures` is
  every module whose links couldn't be extracted
  (`XipeTotec.Scanner.scan_links_report/3`), each as `%{path:, module:, reason:}`.

  `opts` (tests): `:info` (default: xipe_totec's own info.json) and
  `:language_dir` (default: `lib/repl/language/`), which languages are
  registered and where their `Repl.Language` modules live.
  """
  @spec scan_dir(XipeTotec.Book.t(), String.t(), keyword()) ::
          {XipeTotec.Book.t(), [String.t()], [%{path: String.t(), module: String.t(), reason: String.t()}]}
  def scan_dir(book, dir, opts \\ []) do
    info = Keyword.get_lazy(opts, :info, &Info.load/0)
    sheets = sheets(dir, info)
    paths = Enum.map(sheets, & &1.path)

    scanners =
      sheets
      |> Enum.map(& &1.language)
      |> Enum.uniq()
      |> Map.new(&{&1, scanner_for(&1, info, opts)})

    files =
      for %{path: path, language: language} <- sheets do
        {scanners[language], %{root: dir, path: path, source: File.read!(Path.join(dir, path))}}
      end

    {book, node_ids} =
      Enum.reduce(files, {book, %{}}, fn {scanner, file}, {book, node_ids} ->
        sheet_id = Identity.sheet_id(book, file.path) || Id.ulid()
        book = Core.put_sheet(book, sheet_id, %{path: file.path, source_hash: content_hash(file.source)})
        {book, these_ids} = scanner.scan_defs(book, sheet_id, file)
        {book, Map.merge(node_ids, these_ids)}
      end)

    book = sweep_gone_sheets(book, paths)

    {book, failures} =
      Enum.reduce(files, {book, []}, fn {scanner, file}, {book, failures} ->
        {book, these} = scanner.scan_links_report(book, node_ids, file)
        {book, failures ++ Enum.map(these, &Map.put(&1, :path, file.path))}
      end)

    {book, paths, failures}
  end

  defp scanner_for(language, info, opts) do
    {:ok, mod} =
      case Keyword.fetch(opts, :language_dir) do
        {:ok, dir} -> Info.language_module(language, info, dir)
        :error -> Info.language_module(language, info)
      end

    mod.scanner()
  end

  # A sheet whose file is no longer among `paths` (deleted, renamed, or now
  # excluded) goes, and so does every node still on it -- the same removal
  # `scan_defs/3` does for a function that vanished from a file that
  # is still here, links touching those nodes included. Runs after every
  # file's `scan_defs/3`: a function whose file was merely renamed was
  # already found by its natural key and moved onto the new sheet, keeping
  # its id; only what's left on a gone sheet is really gone. Runs before the
  # link pass, so no link resolves to a node that is about to disappear.
  defp sweep_gone_sheets(book, paths) do
    present = MapSet.new(paths)
    gone_sheets = for {id, row} <- book.sheets, not MapSet.member?(present, row.path), into: MapSet.new(), do: id
    gone_nodes = for {id, row} <- book.nodes, MapSet.member?(gone_sheets, row.sheet), into: MapSet.new(), do: id

    gone_links =
      for {id, row} <- book.links,
          MapSet.member?(gone_nodes, row.node) or MapSet.member?(gone_nodes, row.ref),
          do: id

    book = Enum.reduce(gone_sheets, book, &Book.delete(&2, :sheets, &1))
    book = Enum.reduce(gone_nodes, book, &Book.delete(&2, :nodes, &1))
    Enum.reduce(gone_links, book, &Book.delete(&2, :links, &1))
  end

  @doc """
  Append to the Store at `store_path` only the sheet/node/link rows that
  are new or changed between `old_book` and `new_book`, and tombstone
  (`deleted: true`) any that disappeared. Never touches `calls`/`runs`/
  `providers` -- a scan does not evaluate anything.
  """
  @spec persist_scan(Path.t(), XipeTotec.Book.t(), XipeTotec.Book.t()) :: :ok
  def persist_scan(store_path, old_book, new_book),
    do: Store.persist_diff(store_path, old_book, new_book, [:sheets, :nodes, :links])

  defp content_hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
