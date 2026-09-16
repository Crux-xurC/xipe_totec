Code.require_file("id.exs", __DIR__)
Code.require_file("book.exs", __DIR__)
Code.require_file("identity.exs", __DIR__)
Code.require_file("core.exs", __DIR__)
Code.require_file("scanner.exs", __DIR__)
Code.require_file("store.exs", __DIR__)

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

  alias XipeTotec.{Core, Id, Identity, Scanner, Store}

  @doc "Every .ex file under `dir` (recursively), as paths relative to `dir`, sorted."
  @spec find_sheets(String.t()) :: [String.t()]
  def find_sheets(dir) do
    dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  @doc """
  Scan every `.ex` file under `dir` into `book`. Returns `{book, paths}`.
  Only `.ex` files are scanned (not `.exs`) for this first pass -- a
  project's build-script-shaped `.exs` files still parse safely (fix F:
  only their `defmodule` forms are ever compiled) but are more likely to be
  entry-point scripts than library code worth indexing; revisit once a real
  project's layout demands it.
  """
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
