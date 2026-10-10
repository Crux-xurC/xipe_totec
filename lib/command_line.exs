defmodule XipeTotec.CommandLine do
  @moduledoc """
  `xipe do`'s argv → command-list parsing.

      xipe do <method> [key=value...] [-- <method> [key=value...]]...

  Deliberately hand-rolled rather than OptionParser for the `--`-separated
  command groups: OptionParser's own `--` handling is about ending *its*
  option parsing, not a repeatable general-purpose separator, and every
  token after the method name is a plain `key=value` pair, not a `--flag`.

  Value rules (`parse_value/1`), in order:

    * `[...]` -- always a list: `[]` is empty, `[10]` is one element,
      `[1,2]` two. The only way to write a zero- or one-element list
      (`row/add`'s `args` for a 0/1-arity function, `eval`'s `call_ids`
      for a single call).
    * anything else containing a comma -- a list (`args=1,2`)
    * anything else -- the plain string

  Not a general type system: an element that itself needs a literal comma
  (e.g. an Elixir list literal as one argument, `[1,2]`) cannot be written.
  """

  @type command :: %{String.t() => term()}

  @doc "`xipe do`'s argv (after the optional `--dir <dir>`) to a command list."
  @spec parse([String.t()]) :: [command()]
  def parse(args), do: args |> groups() |> Enum.map(&parse_command_group/1)

  @doc "argv split on `--` into the command groups (empty groups dropped)."
  @spec groups([String.t()]) :: [[String.t()]]
  def groups(args) do
    args
    |> Enum.chunk_while(
      [],
      fn
        "--", acc -> {:cont, Enum.reverse(acc), []}
        token, acc -> {:cont, [token | acc]}
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.reject(&(&1 == []))
  end

  @spec parse_value(String.t()) :: String.t() | [String.t()]
  def parse_value("[" <> rest = v) do
    case String.split_at(rest, -1) do
      {"", "]"} -> []
      {inner, "]"} -> String.split(inner, ",")
      _ -> split_commas(v)
    end
  end

  def parse_value(v), do: split_commas(v)

  defp split_commas(v), do: if(String.contains?(v, ","), do: String.split(v, ","), else: v)

  defp parse_command_group([method | kvs]), do: %{"method" => method, "params" => Map.new(kvs, &parse_kv/1)}

  defp parse_kv(kv) do
    case String.split(kv, "=", parts: 2) do
      [k, v] -> {k, parse_value(v)}
      [k] -> {k, ""}
    end
  end
end
