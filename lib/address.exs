Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Address do
  @moduledoc """
  spec §6.1 住所: an address is a set of columns (never a delimiter string),
  every column an optional condition, combined to narrow down. A unique
  match returns that target; several return candidates. Server-interface
  example (§6.1, reused by §16.3 card/get): `{"file": "lib/shop/price.ex",
  "name": "add_tax", "arity": 2}`.

  Shared by `card/get`/`card/search`/`graph/export`'s range selection
  (Old.md §9, 2026-09-17) -- one resolver, several callers.

  v0 scope: matches `:nodes` (optionally joined through `sheet` to the
  owning sheet's `path`, for the spec's `file` column) and, directly, a
  single `:calls` row by id (`row`). `type`/`hier` from the CLI's
  address-option list (spec §15) are deliberately **not** silently ignored
  -- `resolve/2` returns `{:error, {:unsupported_column, name}}` for them
  rather than matching everything, since a silently-too-broad candidate set
  would be a worse failure than a loud one. `hier` has no home yet because
  node rows don't carry a hierarchy code (Old.md §8, still deferred);
  `type` (restricting which table an address can hit) has no caller needing
  it yet since v0's own callers are all node/call oriented.
  """

  alias XipeTotec.Book

  @type address :: %{optional(String.t()) => String.t() | integer()}
  @type match :: {Book.table(), String.t(), Book.row()}

  # `arity` (spec §6.1's own column name, and what tezcatl sends) is kept
  # as an alias of `anykey`, the node column it now matches
  @known_columns ~w(file module name anykey arity row)

  @doc """
  Resolve `address` against `book`. `{:ok, matches}` -- empty means no
  match, one means a unique target, more than one means candidates (spec
  §6.1); the caller decides what "unique" vs "candidates" means for its own
  response shape. `{:error, {:unsupported_column, name}}` if `address` uses
  a column this module doesn't implement yet.
  """
  @spec resolve(Book.t(), address) :: {:ok, [match]} | {:error, {:unsupported_column, String.t()}}
  def resolve(_book, address) when map_size(address) == 0, do: {:ok, []}

  def resolve(book, %{"row" => call_id} = address) when map_size(address) == 1 do
    case Book.get(book, :calls, call_id) do
      nil -> {:ok, []}
      row -> {:ok, [{:calls, call_id, row}]}
    end
  end

  def resolve(book, address) when is_map(address) do
    case Enum.find(Map.keys(address), &(&1 not in @known_columns)) do
      nil ->
        matches =
          for {id, row} <- book.nodes, node_matches?(book, row, address) do
            {:nodes, id, row}
          end

        {:ok, matches}

      unknown ->
        {:error, {:unsupported_column, unknown}}
    end
  end

  defp node_matches?(book, row, address) do
    Enum.all?(address, fn
      {"file", path} -> sheet_path(book, row.sheet) == path
      {"module", v} -> row.module == v
      {"name", v} -> row.name == v
      {col, v} when col in ["anykey", "arity"] -> anykey_eq?(row.anykey, v)
      {"row", _} -> true
    end)
  end

  defp sheet_path(book, sheet_id) do
    case Book.get(book, :sheets, sheet_id) do
      nil -> nil
      sheet -> sheet.path
    end
  end

  defp anykey_eq?(row_key, v) when is_integer(v), do: row_key == v

  defp anykey_eq?(row_key, v) when is_binary(v) do
    # a CLI/URL value is always a string: "2" matches Elixir's integer
    # anykey 2, and any string matches a string anykey as-is
    case Integer.parse(v) do
      {n, ""} -> row_key == n or row_key == v
      _ -> row_key == v
    end
  end
end
