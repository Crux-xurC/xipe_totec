Code.require_file("launch.exs", __DIR__)

defmodule XipeTotec.Repl.Scala.EvalTemplate do
  @moduledoc """
  Scala's `eval_template` (Scala 3's REPL): three REPL inputs per entry,
  each a complete line, every call wrapped in `embody.scala`:

      Embody.start("<id>", <timeout ms>, <None | Some(("exact", "…")) | Some(("binary", "…"))>)
      val xt_<id> = Embody.call(() => pkg.Obj.f((a), (b))((c)))
      Embody.finish("<id>", "pkg.Obj", "f", List(2, 1))

  The call is compiled by the REPL itself: one that does not compile (a
  type error, a `private` function, a script that did not load) leaves
  `xt_<id>` unbound and the compiler's message on the output outside the
  markers, and `finish` reports the entry as a `crash` with what reflection
  can tell. The REPL waits silently for the rest of an unclosed bracket,
  string or comment, so the arguments are checked here first (`check/1`):
  one that would leave it reading on is not sent; `Embody.fail` reports it
  instead
  ([D-scala-adapter](../../../document/verification/lib-repl-language-scala.exs.md#d-scala-adapter)).

  The arguments are split into the node's parameter lists by its shape
  (`[2, 1]`: `f((a), (b))((c))`; `[]`: `f`, a `def` without parameter
  lists; none known: one list), each in parentheses, so an embedded value
  keeps its meaning. A name that is not an identifier is written in
  backticks. A reference to a row evaluated earlier in the same session is
  the binding `xt_<id>` (Core's `:in_plan`). Limits: `timeout` is
  `embody.scala`'s own (a thread of its own, left running at the limit;
  the session is then thrown away); there is no per-entry memory limit
  (`max_heap_words` is ignored).
  """

  alias XipeTotec.Repl.Scala.Launch

  @keywords ~w(abstract case catch class def do else enum export extends false final finally for forSome given if implicit
               import lazy match new null object override package private protected return sealed super then throw trait
               true try type val var while with yield)

  @doc """
  The call as Scala writes it: `pkg.Obj.f((a), (b))((c))`. A script's
  module is its path without `.sc`, then its nested objects
  (`scripts/tool.Text`): the script's object is named by the path, in
  backticks (`` `scripts/tool`.Text.shout(…) ``), as `embody.scala`'s
  `Load` writes it.
  """
  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args} = entry) do
    path =
      case String.split(module, "/") do
        [_] ->
          module |> String.split(".", trim: true) |> Enum.map(&ident/1)

        parts ->
          {dirs, [last]} = Enum.split(parts, -1)
          [object | inner] = String.split(last, ".")
          [ident(Enum.join(dirs ++ [object], "/")) | Enum.map(inner, &ident/1)]
      end

    head = Enum.join(path ++ [ident(name)], ".")
    head <> Enum.map_join(lists(args, Map.get(entry, :shape)), "", fn list -> "(" <> Enum.map_join(list, ", ", &"(#{&1})") <> ")" end)
  end

  # the args split by the shape; one list when the shape does not fit them
  defp lists(args, shape) when is_list(shape) do
    if Enum.sum(shape) == length(args) do
      {lists, []} = Enum.map_reduce(shape, args, fn n, rest -> Enum.split(rest, n) end)
      lists
    else
      [args]
    end
  end

  defp lists(args, _), do: [args]

  # a Scala name as written in a call: an identifier as it is, anything else (an operator, a keyword) in backticks
  defp ident(name) do
    if name =~ ~r/\A[A-Za-z_$][A-Za-z0-9_$]*\z/ and name not in @keywords, do: name, else: "`#{name}`"
  end

  @spec build(map()) :: String.t()
  def build(%{call_id: call_id, module: module, name: name, args: args, limits: %{timeout: timeout_ms}} = entry) do
    # Core's own binding name (`binding_name/1`)
    var = "xt_" <> String.replace(call_id, ~r/[^A-Za-z0-9_]/, "_")
    # each input must be one line: the REPL reads a line as one input once it is complete
    args = Enum.map(args, &String.replace(&1, ~r/\r?\n/, " "))
    id = Launch.string(call_id)

    case Enum.find_value(args, &check/1) do
      nil ->
        basis =
          case Map.get(entry, :basis, :none) do
            {:exact, text} -> "Some((\"exact\", #{Launch.string(text)}))"
            {:binary, b64} -> "Some((\"binary\", #{Launch.string(b64)}))"
            _ -> "None"
          end

        shape = Map.get(entry, :shape) || [length(args)]
        call = call_expression(%{entry | args: args})

        """
        Embody.start(#{id}, #{timeout_ms}, #{basis})
        val #{var} = Embody.call(() => #{call})
        Embody.finish(#{id}, #{Launch.string(module)}, #{Launch.string(name)}, List(#{Enum.join(shape, ", ")}))
        """

      reason ->
        "Embody.fail(#{id}, #{Launch.string("the call was not sent: " <> reason)})\n"
    end
  end

  @doc """
  Why the argument `text` would leave Scala's REPL reading on, or `nil`: an
  unclosed string (`"…"`, `\"\"\"…\"\"\"`, an interpolation's `${…}`), char
  or backquoted name, an unclosed or mismatched bracket, or a `//` or `/*`
  comment.
  """
  @spec check(String.t()) :: String.t() | nil
  def check(text), do: scan(text, [])

  defp scan(<<>>, []), do: nil
  defp scan(<<>>, [open | _]), do: "an unclosed #{open}"
  defp scan(<<"//", _::binary>>, _stack), do: "a // comment"
  defp scan(<<"/*", _::binary>>, _stack), do: "a /* comment"
  # an interpolated string (`s"…"`, `f"…"`, `raw"…"`: a name right before the quote) reads `${…}` as code
  defp scan(<<c, "\"\"\"", rest::binary>>, stack) when c in ?a..?z or c in ?A..?Z or c == ?_, do: triple(rest, stack, true)
  defp scan(<<c, "\"", rest::binary>>, stack) when c in ?a..?z or c in ?A..?Z or c == ?_, do: string(rest, stack, true)
  defp scan(<<"\"\"\"", rest::binary>>, stack), do: triple(rest, stack, false)
  defp scan(<<"\"", rest::binary>>, stack), do: string(rest, stack, false)
  defp scan(<<"`", rest::binary>>, stack), do: backquoted(rest, stack)

  defp scan(<<"'", rest::binary>> = text, stack) do
    # a char literal ('a', '\n', 'A'); any other ' (a quote in a macro) passes
    case Regex.run(~r/\A'(?:\\u[0-9A-Fa-f]{4}|\\.|[^'\\\n])'/u, text) do
      [lit] -> scan(binary_part(text, byte_size(lit), byte_size(text) - byte_size(lit)), stack)
      nil -> scan(rest, stack)
    end
  end

  defp scan(<<c, rest::binary>>, stack) when c in ~c"([{", do: scan(rest, [<<c>> | stack])

  # the `}` closing an interpolation's `${` goes back into its string
  defp scan(<<"}", rest::binary>>, [{:interp, kind} | more]), do: resume(kind, rest, more)

  defp scan(<<c, rest::binary>>, stack) when c in ~c")]}" do
    want = %{")" => "(", "]" => "[", "}" => "{"}[<<c>>]

    case stack do
      [^want | more] -> scan(rest, more)
      [{:interp, _} | _] -> "#{<<c>>} inside an interpolation's ${"
      [open | _] -> "#{<<c>>} closing #{open}"
      [] -> "#{<<c>>} without its opening"
    end
  end

  defp scan(<<_, rest::binary>>, stack), do: scan(rest, stack)

  defp resume(:string, rest, stack), do: string(rest, stack, true)
  defp resume(:triple, rest, stack), do: triple(rest, stack, true)

  defp string(<<"\\", _, rest::binary>>, stack, i), do: string(rest, stack, i)
  defp string(<<"$$", rest::binary>>, stack, true), do: string(rest, stack, true)
  defp string(<<"${", rest::binary>>, stack, true), do: scan(rest, [{:interp, :string} | stack])
  defp string(<<"\"", rest::binary>>, stack, _i), do: scan(rest, stack)
  defp string(<<_, rest::binary>>, stack, i), do: string(rest, stack, i)
  defp string(<<>>, _stack, _i), do: "an unclosed string"

  defp triple(<<"$$", rest::binary>>, stack, true), do: triple(rest, stack, true)
  defp triple(<<"${", rest::binary>>, stack, true), do: scan(rest, [{:interp, :triple} | stack])
  # a closing """ may have more quotes before it (""""a"""" ends after the last three)
  defp triple(<<"\"\"\"", rest::binary>>, stack, _i), do: scan(String.trim_leading(rest, "\""), stack)
  defp triple(<<_, rest::binary>>, stack, i), do: triple(rest, stack, i)
  defp triple(<<>>, _stack, _i), do: "an unclosed string"

  defp backquoted(<<"`", rest::binary>>, stack), do: scan(rest, stack)
  defp backquoted(<<_, rest::binary>>, stack), do: backquoted(rest, stack)
  defp backquoted(<<>>, _stack), do: "an unclosed `name`"
end
