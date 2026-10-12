Code.require_file("book.exs", __DIR__)
Code.require_file("core.exs", __DIR__)

defmodule XipeTotec.CardTable do
  @moduledoc """
  The cards as one flat table: every function a scan found (`nodes`), with
  its file (`path`) and the line it is defined at (`line`) alongside, and
  how many calc rows it has (`rows`). A read-only view of the Book, like
  `XipeTotec.EvalTable` -- that one has a row per calc row, so a function
  nobody made a row for is not in it; this one has every function.

  `path` is the sheet's, as the scan recorded it (from the project's root);
  `line` is the node's `span`, 1-based, where its definition starts on
  disk. A function whose sheet is gone has both empty.

  What `card/list` gives out whole. Picking, sorting and following are the
  reader's.
  """

  alias XipeTotec.{Book, Core}

  @columns ~w(id label module name anykey effect visibility path line rows)

  @doc "The column names, in display order."
  @spec columns() :: [String.t()]
  def columns, do: @columns

  @doc "One map per function (string keys, `columns/0`), in file order: by path, then line, then id. Those with no file last."
  @spec rows(Book.t()) :: [map()]
  def rows(book) do
    counts = Enum.frequencies_by(book.calls, fn {_id, call} -> call.node end)

    book.nodes
    |> Enum.map(fn {id, node} -> row(book, id, node, Map.get(counts, id, 0)) end)
    |> Enum.sort_by(&{&1["path"] == nil, &1["path"], &1["line"] || 0, &1["id"]})
  end

  @doc "Where the function `node_id` is defined: `{path, line}`, either `nil` when not known (the node or its sheet is gone)."
  @spec place(Book.t(), String.t()) :: {String.t() | nil, pos_integer() | nil}
  def place(book, node_id) do
    case Book.get(book, :nodes, node_id) do
      nil -> {nil, nil}
      node -> place_of(book, node)
    end
  end

  # a line means nothing without its file
  defp place_of(book, node) do
    case path(book, node) do
      nil -> {nil, nil}
      path -> {path, line(node)}
    end
  end

  defp row(book, id, node, count) do
    {path, line} = place_of(book, node)

    %{
      "id" => id,
      "label" => Core.node_label(node),
      "module" => node[:module],
      "name" => node[:name],
      "anykey" => node[:anykey],
      "effect" => node[:effect],
      "visibility" => node[:visibility],
      "path" => path,
      "line" => line,
      "rows" => count
    }
  end

  defp path(book, node), do: ((node[:sheet] && Book.get(book, :sheets, node[:sheet])) || %{})[:path]

  defp line(node) do
    case node[:span] do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end
end
