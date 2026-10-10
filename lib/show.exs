Code.require_file("book.exs", __DIR__)
Code.require_file("core.exs", __DIR__)
Code.require_file("dispatch.exs", __DIR__)

defmodule XipeTotec.Show do
  @moduledoc """
  `show`'s lines: a book's sheets, nodes, links and calc rows, one per line. The CLI prints them from the
  book on disk, the dialogue window (`input` `show`) from the running
  server's book.
  """

  alias XipeTotec.{Book, Core, Dispatch}

  @spec lines(String.t() | nil, String.t(), Book.t()) :: [String.t()]
  def lines(project_id, root, book) do
    sheets = for {id, row} <- book.sheets, do: "sheet #{id}  #{row.path}"
    nodes = for {id, row} <- book.nodes, do: "node  #{id}  #{Core.node_label(row)}  effect=#{row.effect}"
    links = for {_id, row} <- book.links, do: "link  #{row.node} --#{row.role}--> #{row.ref}"

    # the calc rows, through the same row/list a client uses
    {:ok, _book, %{"rows" => rows}} = Dispatch.handle(book, "row/list", %{})

    calls = for r <- rows, do: "row   #{r["id"]}  #{r["label"] || "(node gone)"}  args=#{inspect(r["args"])}  #{result(r)}"

    empty = if book == Book.new(), do: ["(empty -- run `xipe scan` first)"], else: []

    ["project #{project_id}  #{root}"] ++ sheets ++ nodes ++ links ++ calls ++ empty
  end

  # A row whose last evaluation failed keeps its previous value in the Book.
  # The line says it failed and why, and names the old value as `previous=`
  # so it is not read as the current one.
  defp result(%{"state" => "ok"} = r) do
    value = if r["eval_count"] == 0, do: "-", else: r["value"] || "-"
    "#{value}  compare=#{r["compare"]}"
  end

  defp result(r) do
    previous = if r["value"] in [nil, ""], do: "", else: "  previous=#{r["value"]}"
    "(error: #{r["error"] || r["state"]})#{previous}  state=#{r["state"]}"
  end
end
