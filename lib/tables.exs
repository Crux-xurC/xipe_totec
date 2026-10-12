Code.require_file("eval_table.exs", __DIR__)
Code.require_file("surface_table.exs", __DIR__)

defmodule XipeTotec.Tables do
  @moduledoc """
  The tables a person can look into, declared once: each one's name, the
  flag that names it in a `search` turn (`-s`, `-e`), its columns, how its
  rows are read, and which columns can be rewritten by hand.

  Read from here: `Dialogue.Search` (which tables a turn may name, their
  columns and rows), `Dialogue.Rewrite` (which columns it may change, and
  with what) and the `roster` method (the same list, for a client or a
  person who wants to know what there is to look at). A table added here
  is searchable and listed without touching either.

  Rows are read afresh on every call from a read-only `ctx`
  (`Dialogue.ctx()`: the book, the root, the project dir). Nothing here
  writes: `writes` only names, per column, the method that does --

      %{method: "row/set-prev", id_from: "id", id: "id", value: "prev"}

  the method, the column of the row whose value is the id it takes
  (`id_from` -- `effect` belongs to the row's function, so `"node"`), and
  the names of its id and value params. The value's kind (a line, a list,
  a choice) is that param's in `XipeTotec.Methods`. A column not listed
  can't be rewritten: it is what an evaluation or a scan found.
  """

  alias XipeTotec.{EvalTable, SurfaceTable}

  @type write :: %{method: String.t(), id_from: String.t(), id: String.t(), value: String.t()}
  @type table :: %{
          name: String.t(),
          flag: String.t(),
          summary: String.t(),
          columns: [String.t()],
          key: String.t(),
          writes: %{String.t() => write()}
        }

  @surface_columns ~w(id path depth language repl build_tool)

  @doc "Every table, in the order `search -h` and `roster` show them."
  @spec all() :: [table()]
  def all do
    [
      %{name: "surface", flag: "-s", summary: "the surface table", columns: @surface_columns, key: "id", writes: %{}},
      %{
        name: "eval",
        flag: "-e",
        summary: "the eval_table",
        columns: EvalTable.columns(),
        key: "id",
        writes: %{
          "args" => %{method: "row/set-args", id_from: "id", id: "id", value: "args"},
          "result" => %{method: "row/set-result", id_from: "id", id: "id", value: "result"},
          "prev" => %{method: "row/set-prev", id_from: "id", id: "id", value: "prev"},
          # the row's function, not the row: every row of it is affected
          "effect" => %{method: "effect/set", id_from: "node", id: "id", value: "effect"}
        }
      }
    ]
  end

  @doc "The table a flag (`-e`) or a name (`eval`) names, or `nil`."
  @spec named(String.t()) :: table() | nil
  def named(word), do: Enum.find(all(), &(word in [&1.flag, &1.name]))

  @doc "A cell as the text it is shown and matched as: a list's elements joined with `, `, `nil` empty."
  @spec text(term()) :: String.t()
  def text(nil), do: ""
  def text(list) when is_list(list), do: Enum.map_join(list, ", ", &text/1)
  def text(value) when is_binary(value), do: value
  def text(value), do: to_string(value)

  @doc "The flags that name a table in a search turn."
  @spec flags() :: [String.t()]
  def flags, do: Enum.map(all(), & &1.flag)

  @doc "The table a flag names, or `nil`."
  @spec by_flag(String.t()) :: table() | nil
  def by_flag(flag), do: Enum.find(all(), &(&1.flag == flag))

  @doc "A table's rows now: one map per row, keyed by its columns."
  @spec rows(table(), map()) :: [map()]
  def rows(%{name: "eval"}, ctx), do: EvalTable.rows(ctx.book)

  # the saved surface table as it is (not regenerated or saved: looking
  # writes nothing); none saved yet -> generated in memory
  def rows(%{name: "surface"}, ctx) do
    file = ctx[:project_dir] && Path.join(ctx.project_dir, "table")
    if file && File.exists?(file), do: SurfaceTable.load(file), else: SurfaceTable.generate(ctx.root, [])
  end
end
