Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Store do
  @moduledoc """
  Append-only JSON Lines persistence (spec §17, Old.md §2). One row per
  line, tagged by `type`; the same logical entity may appear on many lines
  over time (an evaluation, an edit, a removal each append a fresh line) --
  the *last* line for a given `{type, id}` pair wins when folding into a
  `Book` (append-log / event-sourcing style, not in-place rewrite).

  A row with `deleted: true` removes that id from the table on fold (the
  tombstone convention used for `row/remove` and for a link edge that
  disappeared on rescan). This is a Store-level convention layered on top of
  spec's own node/sheet `status: tombstone`, which keeps its separate
  spec'd meaning.

  `compact/1` (rewrite the file to hold just the current folded state) is
  the one sanctioned exception to "never rewrite".
  """

  alias XipeTotec.Book

  @tables %{
    "sheet" => :sheets,
    "node" => :nodes,
    "call" => :calls,
    "link" => :links,
    "run" => :runs,
    "provider" => :providers
  }
  @table_types Map.new(@tables, fn {type, table} -> {table, type} end)

  @doc "Append one row (atom-keyed map, must include `:type` and `:id`) to the log at `path`."
  @spec append(Path.t(), map()) :: :ok
  def append(path, row) when is_map(row) do
    line = row |> stringify_keys() |> JSON.encode!()
    File.write!(path, line <> "\n", [:append])
    :ok
  end

  @doc """
  Load `path` into a fresh `Book`, folding rows in file order. Ignores
  blank lines, unrecognized `type`s, and a truncated/corrupt line (e.g. from
  a crash mid-write) rather than raising.
  """
  @spec load(Path.t()) :: Book.t()
  def load(path) do
    if File.exists?(path) do
      path |> File.stream!() |> Enum.reduce(Book.new(), &fold_line/2)
    else
      Book.new()
    end
  end

  defp fold_line(line, book) do
    line = String.trim(line)

    with true <- line != "",
         {:ok, %{"type" => type, "id" => id} = decoded} <- JSON.decode(line),
         {:ok, table} <- Map.fetch(@tables, type) do
      row = decoded |> Map.drop(["type", "id"]) |> atomize_keys() |> upgrade(table)

      if row[:deleted] do
        Book.delete(book, table, id)
      else
        Book.put(book, table, id, row)
      end
    else
      _ -> book
    end
  end

  @doc """
  Append to the Store at `path` only the rows in `tables` that are new or
  changed between `old_book` and `new_book`, and tombstone (`deleted: true`)
  any that disappeared -- the diff `XipeTotec.Project.persist_scan/3` used
  to do inline for `[:sheets, :nodes, :links]` only, generalized (Old.md
  §9, 2026-09-17) so `Serve.Project` can persist the effect of *any*
  `Dispatch.handle/4` call across all six tables the same way.
  """
  @spec persist_diff(Path.t(), Book.t(), Book.t(), [Book.table()]) :: :ok
  def persist_diff(path, old_book, new_book, tables) do
    for table <- tables do
      old_table = Map.fetch!(old_book, table)
      new_table = Map.fetch!(new_book, table)
      type = Map.fetch!(@table_types, table)

      for {id, row} <- new_table, Map.get(old_table, id) != row do
        append(path, row |> Map.put(:type, type) |> Map.put(:id, id))
      end

      for {id, _row} <- old_table, not Map.has_key?(new_table, id) do
        append(path, %{type: type, id: id, deleted: true})
      end
    end

    :ok
  end

  @doc "Rewrite `path` to hold only the current folded state."
  @spec compact(Path.t()) :: :ok
  def compact(path) do
    book = load(path)
    tmp = path <> ".compact-tmp"

    File.open!(tmp, [:write], fn io ->
      for {type, table} <- @tables, {id, row} <- Map.fetch!(book, table) do
        line =
          row
          |> Map.put(:type, type)
          |> Map.put(:id, id)
          |> stringify_keys()
          |> JSON.encode!()

        IO.write(io, line <> "\n")
      end
    end)

    File.rename!(tmp, path)
    :ok
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp atomize_keys(map), do: Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)

  # A node row written before the natural key's third column was renamed
  # `arity` -> `anykey` (2026-09-25) still matches on rescan -- without this
  # every such node would be re-minted and its calc rows orphaned.
  defp upgrade(%{arity: arity} = row, :nodes) when not is_map_key(row, :anykey),
    do: row |> Map.delete(:arity) |> Map.put(:anykey, arity)

  defp upgrade(row, _table), do: row
end
