Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Address do
  @moduledoc """
  An address is a set of columns (never a delimiter string), every column
  an optional condition, combined to narrow down. A unique match returns
  that target; several return candidates. Example:
  `{"file": "lib/shop/price.ex", "name": "add_tax", "arity": 2}`.

  Shared by `card/get`/`card/search`/`graph/export`'s range selection
  -- one resolver, several callers.

  Matches `:nodes` (optionally joined through `sheet` to the owning sheet's
  `path`, for the `file` column) and, directly, a single `:calls` row by id
  (`row`). The `type` and `hier` columns are not implemented: `resolve/2`
  returns `{:error, {:unsupported_column, name}}` for them rather than
  matching everything, since a silently-too-broad candidate set would be a
  worse failure than a loud one.
  """

  alias XipeTotec.Book

  @type address :: %{optional(String.t()) => String.t() | integer()}
  @type match :: {Book.table(), String.t(), Book.row()}

  # `arity` (what clients send) is an alias of `anykey`, the node column it matches
  @known_columns ~w(file module name anykey arity row)

  @doc """
  Resolve `address` against `book`. `{:ok, matches}` -- empty means no
  match, one means a unique target, more than one means candidates;
  the caller decides what "unique" vs "candidates" means for its own
  response shape. `{:error, {:unsupported_column, name}}` if `address` uses
  a column this module doesn't implement yet; `{:error, {:bad_value, name,
  value}}` if `anykey`/`arity` is given as something that can't be one --
  neither an integer nor a string: a JSON `null` (a `$n.path` that named
  nothing, `Runner`), a list, an object. Refused rather than read as "no
  match".
  """
  @spec resolve(Book.t(), address) ::
          {:ok, [match]} | {:error, {:unsupported_column, String.t()} | {:bad_value, String.t(), term()}}
  def resolve(_book, address) when map_size(address) == 0, do: {:ok, []}

  def resolve(book, %{"row" => call_id} = address) when map_size(address) == 1 do
    case Book.get(book, :calls, call_id) do
      nil -> {:ok, []}
      row -> {:ok, [{:calls, call_id, row}]}
    end
  end

  def resolve(book, address) when is_map(address) do
    case Enum.find(Map.keys(address), &(&1 not in @known_columns)) || bad_anykey(address) do
      {:bad_value, _col, _value} = bad ->
        {:error, bad}

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

  # the `anykey`/`arity` column whose value is neither an integer nor a string, if any
  defp bad_anykey(address) do
    Enum.find_value(["anykey", "arity"], fn col ->
      case Map.fetch(address, col) do
        {:ok, v} when not (is_integer(v) or is_binary(v)) -> {:bad_value, col, v}
        _ -> nil
      end
    end)
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
