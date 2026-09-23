Code.require_file("id.exs", __DIR__)
Code.require_file("book.exs", __DIR__)
Code.require_file("identity.exs", __DIR__)
Code.require_file("core.exs", __DIR__)
Code.require_file("scanner.exs", __DIR__)
Code.require_file("store.exs", __DIR__)
Code.require_file("surface_table.exs", __DIR__)

defmodule XipeTotec.Project do
  @moduledoc """
  Orchestrates a directory scan (spec §14.1): the two-pass
  `Scanner.scan_defs/3` then `Scanner.scan_links/3` sequencing a single
  file cannot do alone (a cross-file callee must already be registered
  before links are resolved -- see `XipeTotec.Scanner`'s moduledoc).

  Kept separate from `XipeTotec.Core`: this module does real I/O (reading
  source files, appending to the Store), so it is deliberately *not* part
  of the pure Core.
  """

  alias XipeTotec.{Core, Id, Identity, Scanner, Store, SurfaceTable}

  @doc """
  Every Elixir-language file under `dir` (recursively, `.ex`/`.exs` -- both
  extensions, revised 2026-09-18, wiring `xipe eval`'s scripts-mode file
  list -- see `document/repl-adapter-guide.md`'s `files` section: a
  `.exs`-only project, crux's own real projects/tezcatl included, has
  nothing under `.ex` at all, and both `find_sheets/1`'s two callers
  (`scan_dir/2`'s indexing and, via `main.exs`'s `xipe eval`, the REPL's
  `-r` file list) need those files to do anything useful for such a
  project), as paths relative to `dir`, sorted.

  Delegates to `SurfaceTable.generate/2` and filters on `language ==
  "elixir"` (§26's co-design) rather than hardcoding the extension list
  itself a second time -- `SurfaceTable`'s own `@extension_language` is
  now the one place that fact lives. `scan_dir/2` was already safe to
  point at `.exs` sources even before this -- fix F (`Scanner`'s
  compiler-tracer pass) only ever compiles `defmodule` forms, never a
  script's other top-level statements -- this was purely an
  indexing-signal call (entry-point scripts vs. library code), not a
  safety one.
  """
  @spec find_sheets(String.t()) :: [String.t()]
  def find_sheets(dir) do
    dir
    |> SurfaceTable.generate()
    |> Enum.filter(&(&1["language"] == "elixir"))
    |> Enum.map(& &1["path"])
  end

  @doc "Scan every `.ex`/`.exs` file under `dir` into `book`. Returns `{book, paths}`."
  @spec scan_dir(XipeTotec.Book.t(), String.t()) :: {XipeTotec.Book.t(), [String.t()]}
  def scan_dir(book, dir) do
    paths = find_sheets(dir)

    {book, node_ids, sources} =
      Enum.reduce(paths, {book, %{}, %{}}, fn path, {book, node_ids, sources} ->
        source = File.read!(Path.join(dir, path))
        sheet_id = Identity.sheet_id(book, path) || Id.ulid()
        book = Core.put_sheet(book, sheet_id, %{path: path, source_hash: content_hash(source)})
        {book, these_ids} = Scanner.scan_defs(book, sheet_id, source)
        {book, Map.merge(node_ids, these_ids), Map.put(sources, path, source)}
      end)

    book = Enum.reduce(sources, book, fn {_path, source}, book -> Scanner.scan_links(book, node_ids, source) end)

    {book, paths}
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
