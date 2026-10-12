Code.require_file("eval_table.exs", __DIR__)
Code.require_file("surface_table.exs", __DIR__)

defmodule XipeTotec.Tables do
  @moduledoc """
  The tables a person can look into, declared once: each one's name, the
  flag that names it in a `search` turn (`-s`, `-e`), its columns, and how
  its rows are read.

  Read from here: `Dialogue.Search` (which tables a turn may name, their
  columns and rows) and the `roster` method (the same list, for a
  client or a person who wants to know what there is to look at). A table
  added here is searchable and listed without touching either.

  Rows are read afresh on every call from a read-only `ctx`
  (`Dialogue.ctx()`: the book, the root, the project dir). Nothing here
  writes.
  """

  alias XipeTotec.{EvalTable, SurfaceTable}

  @type table :: %{name: String.t(), flag: String.t(), summary: String.t(), columns: [String.t()]}

  @surface_columns ~w(id path depth language repl build_tool)

  @doc "Every table, in the order `search -h` and `roster` show them."
  @spec all() :: [table()]
  def all do
    [
      %{name: "surface", flag: "-s", summary: "the surface table", columns: @surface_columns},
      %{name: "eval", flag: "-e", summary: "the eval_table", columns: EvalTable.columns()}
    ]
  end

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
