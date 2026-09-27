Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.EvalTable do
  @moduledoc """
  `eval_table` (2026-09-27, `next_step.md` §1.1): the calc rows (`calls`)
  with their function (`module`/`name`/`anykey`/`effect`/`visibility`) and
  file (`path`) alongside, as one flat table. A read-only view of the Book,
  not a store of its own -- `課題.md` §1-5's question ("does it overlap
  `calls`?") answered: it is `calls`, joined once, here.

  In the Book a calc row reaches its file only through its node
  (`calls.node` -> `nodes.sheet` -> `sheets.path`); this fixes that walk in
  one place, so the search (`Dialogue.Search`'s `-e`) can go from a surface
  table path straight to rows (`-e path list id`). A row whose node a
  rescan removed has those joined columns empty.

  Columns are the Book's own names (`result`, not `row/list`'s `value`).
  """

  alias XipeTotec.Book

  @columns ~w(id node module name anykey effect visibility path args result repr result_type state compare error
              eval_count prev prev_source result_source result_at commit dirty)

  @doc "The column names, in display order."
  @spec columns() :: [String.t()]
  def columns, do: @columns

  @doc "One map per calc row (string keys, `columns/0`), oldest first."
  @spec rows(Book.t()) :: [map()]
  def rows(book) do
    book.calls
    |> Enum.sort_by(fn {id, _row} -> id end)
    |> Enum.map(fn {id, call} -> row(book, id, call) end)
  end

  defp row(book, id, call) do
    node = Book.get(book, :nodes, call.node) || %{}
    sheet = (node[:sheet] && Book.get(book, :sheets, node[:sheet])) || %{}

    %{
      "id" => id,
      "node" => call.node,
      "module" => node[:module],
      "name" => node[:name],
      "anykey" => node[:anykey],
      "effect" => node[:effect],
      "visibility" => node[:visibility],
      "path" => sheet[:path],
      "args" => call.args,
      "result" => call[:result],
      "repr" => call[:repr],
      "result_type" => call[:result_type],
      "state" => call[:state],
      "compare" => call[:compare],
      "error" => call[:error],
      "eval_count" => call[:eval_count] || 0,
      "prev" => call[:prev],
      "prev_source" => call[:prev_source],
      "result_source" => call[:result_source],
      "result_at" => call[:result_at],
      "commit" => call[:commit],
      "dirty" => call[:dirty]
    }
  end
end
