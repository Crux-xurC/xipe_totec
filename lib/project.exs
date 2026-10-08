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

  The surface table is `table_file`'s saved one when given
  (`SurfaceTable.rows/3`: regenerated and saved first only if it is empty
  or names a path that is gone), otherwise generated on the spot.

  Mix's own files are left out: `mix.exs` (build configuration, not project
  code -- its `use Mix.Project` can't even compile outside a running Mix)
  and everything under `deps/` and `_build/` (third-party sources and build
  output). Only the top level of `dir` is checked for these.
  """
  @spec sheets(String.t(), Info.t(), Path.t() | nil) :: [%{path: String.t(), language: String.t()}]
  def sheets(dir, info \\ Info.load(), table_file \\ nil),
    do: dir |> SurfaceTable.rows(table_file, info) |> sheets_in(info)

  @doc "`sheets/3` over surface-table `rows` already in hand."
  @spec sheets_in(SurfaceTable.t(), Info.t()) :: [%{path: String.t(), language: String.t()}]
  def sheets_in(rows, info \\ Info.load()) do
    registered = info["languages"] || []

    for row <- rows,
        row["language"] in registered,
        not mix_own_file?(row["path"]),
        do: %{path: row["path"], language: row["language"]}
  end

  @doc "`sheets/3`'s paths (surface table generated on the spot), optionally only `language`'s."
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
    report = scan_dir_report(book, dir, opts)
    {report.book, report.paths, report.link_failures}
  end

  @doc """
  `scan_dir/3` plus, per language, which scanner read its files and why the
  ones declared ahead of it didn't (spec §11.2): `%{book:, paths:,
  link_failures:, scanners: %{language => %{"scanner" => name, "skipped" =>
  [%{"scanner" => name, "reason" => text}]}}}`.

  A language's scanners are tried in its declared order (spec §11.3): the
  first whose `begin/3` accepts reads every file of that language. `opts`
  also takes `:scanner_opts`, handed to every `begin/3` (with `:files`, the
  language's paths, and `:next`, the scanners declared after it, added).
  A scanner that handed some files to the next one (`Scanner.fallbacks/1`)
  adds `"fallbacks" => [%{"path" =>, "reason" =>}]` to its language's entry.
  `:table_file` is the project's saved surface table (`sheets/3`).
  """
  @spec scan_dir_report(XipeTotec.Book.t(), String.t(), keyword()) :: map()
  def scan_dir_report(book, dir, opts \\ []) do
    info = Keyword.get_lazy(opts, :info, &Info.load/0)
    sheets = sheets(dir, info, Keyword.get(opts, :table_file))
    paths = Enum.map(sheets, & &1.path)
    scanner_opts = Keyword.get(opts, :scanner_opts, [])

    picked =
      sheets
      |> Enum.map(& &1.language)
      |> Enum.uniq()
      |> Map.new(fn language ->
        files = for %{path: path, language: ^language} <- sheets, do: path
        {language, pick_scanner(scanners_for(language, info, opts), dir, language, Keyword.put(scanner_opts, :files, files))}
      end)

    files =
      for %{path: path, language: language} <- sheets do
        %{scanner: scanner, ctx: ctx} = picked[language]
        {scanner, %{root: dir, path: path, source: File.read!(Path.join(dir, path)), ctx: ctx}}
      end

    try do
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

      scanners =
        Map.new(picked, fn {language, p} ->
          entry = %{"scanner" => inspect(p.scanner), "skipped" => p.skipped}
          entry = if function_exported?(p.scanner, :describe, 1), do: Map.put(entry, "via", p.scanner.describe(p.ctx)), else: entry

          entry =
            case function_exported?(p.scanner, :fallbacks, 1) && p.scanner.fallbacks(p.ctx) do
              [_ | _] = notes -> Map.put(entry, "fallbacks", notes)
              _ -> entry
            end
          {language, entry}
        end)

      # a scanner reports the calls that missed only by arity (Scanner.arity_miss/3) with its failures
      {misses, failures} = Enum.split_with(failures, &Map.has_key?(&1, :called))
      %{book: book, paths: paths, link_failures: failures, arity_misses: Enum.uniq(misses), scanners: scanners}
    after
      for {_language, %{scanner: scanner, ctx: ctx}} <- picked, function_exported?(scanner, :finish, 1), do: scanner.finish(ctx)
    end
  end

  # The first of `candidates` whose begin/3 accepts (one without begin/3
  # always does); each refusal is kept as `skipped`. The last candidate is
  # used even if it refuses -- a language with no working scanner at all
  # would otherwise silently lose every card on rescan.
  defp pick_scanner(candidates, dir, language, scanner_opts) do
    candidates
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {scanner, rest_at}, skipped ->
      Code.ensure_loaded(scanner)

      result =
        if function_exported?(scanner, :begin, 3),
          do: scanner.begin(dir, language, Keyword.put(scanner_opts, :next, Enum.drop(candidates, rest_at))),
          else: {:ok, nil}

      case result do
        {:ok, ctx} ->
          {:halt, %{scanner: scanner, ctx: ctx, skipped: Enum.reverse(skipped)}}

        {:error, reason} ->
          {:cont, [%{"scanner" => inspect(scanner), "reason" => reason} | skipped]}
      end
    end)
    |> case do
      %{} = picked -> picked
      skipped -> raise "no scanner for #{language} could start: #{inspect(Enum.reverse(skipped))}"
    end
  end

  defp scanners_for(language, info, opts) do
    {:ok, mod} =
      case Keyword.fetch(opts, :language_dir) do
        {:ok, dir} -> Info.language_module(language, info, dir)
        :error -> Info.language_module(language, info)
      end

    List.wrap(mod.scanner())
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
