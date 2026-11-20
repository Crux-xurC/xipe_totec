Code.require_file("../scala/eval_template.exs", __DIR__)

defmodule XipeTotec.Repl.Java.EvalTemplate do
  @moduledoc """
  Java's `eval_template`, on Scala's (Scala 3's REPL is the window): the
  same three REPL inputs per entry, every call wrapped in `embody.scala`,

      Embody.start("<id>", <timeout ms>, <basis>)
      val xt_<id> = Embody.call(() => pkg.Type.method((a), (b)))
      Embody.finish("<id>", "pkg.Type", "method", List(2))

  with Java's call: the static method with its arguments, Scala
  expressions, each in parentheses. A call that does not compile is told in
  Java's terms by the seam (`embody.java`'s `diagnose`); an argument that
  would leave the REPL reading on is not sent (Scala's `check/1`)
  ([D-java-adapter](../../../document/verification/lib-repl-language-java.exs.md#d-java-adapter)).

  The node's marks (D-node-marks) shape the call (`evolving.md` §4.6):

    * `"async"` (a `CompletableFuture`, `CompletionStage` or `Future` comes
      back): the call inside `embodyjava.embody.await(…)`, so the entry's
      value is the `T` (rule 5)
    * `"varargs"`: the last argument, an array (`Array(1, 2)`), passed as
      `(…)*` (rule 4)
    * `"typed"` (another overload has the same argument count): each
      argument given its parameter's Scala type, from `anykey`, where Java's
      type has one without doubt -- `((null): String)`, `int` `Int`, `long`
      `Long`, `int[]` `Array[Int]`, `Integer` `java.lang.Integer`,
      `List<Integer>` `java.util.List[java.lang.Integer]`. A project's type
      or a type parameter is left to Scala (rule 2)
  """

  alias XipeTotec.Repl.Scala.EvalTemplate, as: Scala

  @primitives %{
    "int" => "Int", "long" => "Long", "short" => "Short", "byte" => "Byte", "double" => "Double", "float" => "Float",
    "boolean" => "Boolean", "char" => "Char"
  }

  @boxed ~w(Integer Long Short Byte Double Float Boolean Character Object Number)

  @collections ~w(List ArrayList LinkedList Set HashSet LinkedHashSet TreeSet Map HashMap LinkedHashMap TreeMap Collection Optional)

  @spec build(map()) :: String.t()
  def build(entry), do: Scala.build(entry, &call_expression/1)

  @doc "The call as Scala's REPL compiles it: `pkg.Type.method((a), (b))`, typed, spread and awaited by the node's marks."
  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args} = entry) do
    marks = Map.get(entry, :marks) || []
    types = if "typed" in marks, do: argument_types(Map.get(entry, :anykey)), else: []
    last = length(args) - 1

    written =
      args
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {arg, k} ->
        cond do
          "varargs" in marks and k == last -> "(#{arg})*"
          type = Enum.at(types, k) -> "((#{arg}): #{type})"
          true -> "(#{arg})"
        end
      end)

    call = "#{Scala.head(module, name)}(#{written})"
    if "async" in marks, do: "embodyjava.embody.await(#{call})", else: call
  end

  defp argument_types("(" <> _ = key), do: key |> String.slice(1..-2//1) |> split_top() |> Enum.map(&scala_type(String.trim(&1)))
  defp argument_types(_), do: []

  @doc "Java's type text (as `anykey` writes it) as Scala writes it, or nil when it is not sure (a project's type, a type parameter)."
  @spec scala_type(String.t()) :: String.t() | nil
  def scala_type(type) do
    bare = type |> String.replace_prefix("java.lang.", "") |> String.replace_prefix("java.util.", "")

    cond do
      Map.has_key?(@primitives, bare) ->
        @primitives[bare]

      bare == "String" ->
        "String"

      bare in @boxed ->
        "java.lang.#{bare}"

      String.ends_with?(bare, "...") ->
        nil

      String.ends_with?(bare, "[]") ->
        with inner when inner != nil <- scala_type(String.slice(bare, 0..-3//1)), do: "Array[#{inner}]"

      match = Regex.run(~r/\A(\w+)<(.*)>\z/, bare) ->
        [_, head, inner] = match
        # a type argument is a reference type: `Integer`, `String`, another collection
        args = inner |> split_top() |> Enum.map(&reference(String.trim(&1)))

        if head in @collections and Enum.all?(args, & &1),
          do: "java.util.#{head}[#{Enum.join(args, ", ")}]",
          else: nil

      true ->
        nil
    end
  end

  defp reference(type) do
    case scala_type(type) do
      t when t in [nil] -> nil
      t -> if Map.has_key?(@primitives, type), do: nil, else: t
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

  defdelegate check(text), to: Scala
end
