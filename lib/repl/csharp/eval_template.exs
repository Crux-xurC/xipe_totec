Code.require_file("../fsharp/eval_template.exs", __DIR__)

defmodule XipeTotec.Repl.CSharp.EvalTemplate do
  @moduledoc """
  C#'s `eval_template`, on F#'s (F# Interactive is the window): the same
  three fsi submissions per entry, every call wrapped in `embody.fsx`,

      Embody.start "<id>" <timeout ms> <basis>;;
      let xt_<id> = Embody.call (fun () -> Ns.Type.Method((a), (b)));;
      Embody.finish "<id>" "Ns.Type" "Method" <number of arguments>;;

  with C#'s call: the static method with its arguments, F# expressions,
  each in parentheses. A call that does not compile is told in C#'s terms
  by the seam (`embody.cs`'s `Diagnose`); an argument that would leave fsi
  reading on is not sent (F#'s `check/1`)
  ([D-csharp-adapter](../../../document/verification/lib-repl-language-csharp.exs.md#d-csharp-adapter)).

  The node's marks (D-node-marks) shape the call (`evolving.md` §4.4):

    * `"async"` (a `Task` / `ValueTask` comes back): the call is inside
      `EmbodyCs.Seam.Await(…)`, so the entry's value is the `T` (rule 5)
    * `"typed"` (another overload has the same argument count): each
      argument is given its parameter's type, from `anykey`, where C#'s
      type has an F# name without doubt -- `((null) : string)`, `double`
      `float`, `long` `int64`, `int[]` `int[]`, `List<int>`
      `System.Collections.Generic.List<int>`, `int?`
      `System.Nullable<int>`. A type of the project (`Point`, written as
      the source has it) or a type parameter is left to fsi (rule 2)
  """

  alias XipeTotec.Repl.FSharp.EvalTemplate, as: FSharp

  @keywords %{
    "bool" => "bool", "byte" => "byte", "sbyte" => "sbyte", "char" => "char", "short" => "int16", "ushort" => "uint16",
    "int" => "int", "uint" => "uint32", "long" => "int64", "ulong" => "uint64", "float" => "float32", "double" => "float",
    "decimal" => "decimal", "string" => "string", "object" => "obj",
    "Boolean" => "bool", "Byte" => "byte", "SByte" => "sbyte", "Char" => "char", "Int16" => "int16", "UInt16" => "uint16",
    "Int32" => "int", "UInt32" => "uint32", "Int64" => "int64", "UInt64" => "uint64", "Single" => "float32", "Double" => "float",
    "Decimal" => "decimal", "String" => "string", "Object" => "obj"
  }

  @collections ~w(List Dictionary HashSet Queue Stack SortedDictionary SortedSet LinkedList)

  @spec build(map()) :: String.t()
  def build(entry), do: FSharp.build(entry, &call_expression/1)

  @doc "The call as fsi compiles it: `Ns.Type.Method((a), (b))`, typed and awaited by the node's marks."
  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args} = entry) do
    marks = Map.get(entry, :marks) || []
    types = if "typed" in marks, do: argument_types(Map.get(entry, :anykey)), else: []

    written =
      args
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {arg, k} ->
        case Enum.at(types, k) do
          nil -> "(#{arg})"
          type -> "((#{arg}) : #{type})"
        end
      end)

    call = "#{module}.#{name}(#{written})"
    if "async" in marks, do: "EmbodyCs.Seam.Await(#{call})", else: call
  end

  # the F# types of the arguments a caller writes (out parameters are not written); nil where none is sure
  defp argument_types("(" <> _ = key) do
    key
    |> String.slice(1..-2//1)
    |> split_top()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&String.starts_with?(&1, "out "))
    |> Enum.map(fn param ->
      case String.split(param, " ", parts: 2) do
        [m, type] when m in ["params", "in"] -> fsharp_type(type)
        ["ref", _] -> nil
        _ -> fsharp_type(param)
      end
    end)
  end

  defp argument_types(_), do: []

  @doc "C#'s type text (as `anykey` writes it) as F# writes it, or nil when it is not sure (a project's type, a type parameter)."
  @spec fsharp_type(String.t()) :: String.t() | nil
  def fsharp_type(type) do
    type = String.replace_prefix(type, "System.", "")

    cond do
      Map.has_key?(@keywords, type) ->
        @keywords[type]

      String.ends_with?(type, "[]") ->
        with inner when inner != nil <- fsharp_type(String.slice(type, 0..-3//1)), do: inner <> "[]"

      String.ends_with?(type, "?") ->
        with inner when inner != nil <- fsharp_type(String.slice(type, 0..-2//1)), do: "System.Nullable<#{inner}>"

      match = Regex.run(~r/\A(?:Collections\.Generic\.)?(\w+)<(.*)>\z/, type) ->
        [_, head, inner] = match
        args = inner |> split_top() |> Enum.map(&fsharp_type(String.trim(&1)))

        if head in @collections and Enum.all?(args, & &1),
          do: "System.Collections.Generic.#{head}<#{Enum.join(args, ", ")}>",
          else: nil

      true ->
        nil
    end
  end

  # the comma-separated items at the top level (`<>` `()` `[]` nest)
  defp split_top(text) do
    {items, cur, _} =
      for <<c <- text>>, reduce: {[], [], 0} do
        {items, cur, depth} ->
          cond do
            c in ~c"<([" -> {items, [c | cur], depth + 1}
            c in ~c">)]" -> {items, [c | cur], depth - 1}
            c == ?, and depth == 0 -> {[cur |> Enum.reverse() |> List.to_string() | items], [], depth}
            true -> {items, [c | cur], depth}
          end
      end

    last = cur |> Enum.reverse() |> List.to_string()
    if String.trim(last) == "" and items == [], do: [], else: Enum.reverse([last | items])
  end

  defdelegate check(text), to: FSharp
end
