defmodule XipeTotec.Book do
  @moduledoc """
  The in-memory current-state view. Every table is `id => latest row` --
  Book never holds more than "current"; full history lives only in the
  append-only Store (JSON Lines) and is folded into a Book at load time.

  `link` rows are wholly derived from source and never user-edited. Each
  edge gets a deterministic id from its natural key (`node`, `role`, `ref`,
  `clause`), so `links` is an id-keyed map like every other table and uses
  the same append/tombstone machinery in Store.
  """

  defstruct sheets: %{}, nodes: %{}, calls: %{}, links: %{}, runs: %{}, providers: %{}

  @type row :: map()
  @type table :: :sheets | :nodes | :calls | :links | :runs | :providers
  @type t :: %__MODULE__{
          sheets: %{String.t() => row},
          nodes: %{String.t() => row},
          calls: %{String.t() => row},
          links: %{String.t() => row},
          runs: %{String.t() => row},
          providers: %{String.t() => row}
        }

  @tables [:sheets, :nodes, :calls, :links, :runs, :providers]

  def new, do: %__MODULE__{}

  @spec put(t, table, String.t(), row) :: t
  def put(book, table, id, row) when table in @tables,
    do: Map.update!(book, table, &Map.put(&1, id, row))

  @spec get(t, table, String.t()) :: row | nil
  def get(book, table, id) when table in @tables, do: Map.get(Map.fetch!(book, table), id)

  @spec delete(t, table, String.t()) :: t
  def delete(book, table, id) when table in @tables,
    do: Map.update!(book, table, &Map.delete(&1, id))

  @spec all(t, table) :: [row]
  def all(book, table) when table in @tables, do: Map.values(Map.fetch!(book, table))

  @doc "The sheet id whose `path` matches, if any."
  @spec find_sheet_by_path(t, String.t()) :: String.t() | nil
  def find_sheet_by_path(book, path) do
    Enum.find_value(book.sheets, fn {id, row} -> if row.path == path, do: id end)
  end

  @doc """
  The node id matching (module, name, anykey), if any. `anykey` is whatever the node's scanner put there to tell apart
  same-named functions in one module -- the arity for `Scanner.Elixir`
  (`add/2` and `add/3` are different functions), possibly `nil` for a
  language where the name alone is unique.
  """
  @spec find_node_by_natural_key(t, String.t(), String.t(), non_neg_integer()) :: String.t() | nil
  def find_node_by_natural_key(book, module, name, anykey) do
    Enum.find_value(book.nodes, fn {id, row} ->
      if row.module == module and row.name == name and row.anykey == anykey, do: id
    end)
  end

  @doc "Deterministic id for a link edge (see moduledoc)."
  @spec link_id(String.t(), String.t(), String.t(), term()) :: String.t()
  def link_id(node, role, ref, clause \\ nil) do
    :crypto.hash(:sha256, :erlang.term_to_binary({node, role, ref, clause}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
