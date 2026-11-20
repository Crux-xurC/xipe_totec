Code.require_file("launch.exs", __DIR__)

defmodule XipeTotec.Repl.FSharp.EvalTemplate do
  @moduledoc """
  F#'s `eval_template` (F# Interactive): three fsi submissions per entry,
  every call wrapped in `embody.fsx`:

      Embody.start "<id>" <timeout ms> <None | (Some ("exact", "…")) | (Some ("binary", "…"))>;;
      let xt_<id> = Embody.call (fun () -> Ns.Module.f (a) (b));;
      Embody.finish "<id>" "Ns.Module" "f" <number of arguments>;;

  fsi has no way to evaluate a string from inside a script, so the call is
  compiled by fsi itself, and `;;` ends each submission: a call that does
  not compile (a type error, a private function, a script that did not
  load) leaves `xt_<id>` unbound and fsi's diagnostic on the output outside
  the markers, and `finish` reports the entry as a `crash` with what
  reflection can tell (no such module, a private function, a value, how
  many arguments it takes, its signature). `;;` does not end a string, a
  comment or an open bracket, so the arguments are checked here first
  (`check/1`): one that would leave fsi reading on is not sent;
  `Embody.fail` reports it instead
  ([D-fsharp-adapter](../../../document/verification/lib-repl-language-fsharp.exs.md#d-fsharp-adapter)).

  The call applies the function to each argument in turn, each in
  parentheses (`Sample.Calc.add (1) (2)`, `Sample.Calc.addPair ((1, 2))`),
  so an embedded value keeps its meaning: an argument is one of the
  function's curried arguments. A static member (a node with a shape,
  D-anykey-shape) is called as a method, the arguments split into its
  curried groups by the shape (`Sample.Conv.Show((1.5), (2))`,
  `Sample.Conv.Scale((2.0))((p))`, `Sample.Conv.Origin()`); fsi picks
  among overloads by the arguments' types. A module or function name that is not an
  identifier is written in double backticks (a script `my-tool.fsx` is
  ``` ``My-tool`` ```). A reference to a row evaluated earlier in the same
  session is the binding `xt_<id>` (Core's `:in_plan`). Limits: `timeout`
  is `embody.fsx`'s own (`ControlledExecution` on a thread of its own);
  there is no per-entry memory limit (`max_heap_words` is ignored).
  """

  alias XipeTotec.Repl.FSharp.Launch

  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args} = entry) do
    path = module |> String.split(".") |> Enum.map_join(".", &ident/1)

    case Map.get(entry, :shape) do
      # a static member: one parenthesized group per curried group
      [_ | _] = shape ->
        "#{path}.#{ident(name)}" <> Enum.map_join(groups(args, shape), "", fn g -> "(" <> Enum.map_join(g, ", ", &"(#{&1})") <> ")" end)

      _ ->
        Enum.join(["#{path}.#{ident(name)}" | Enum.map(args, &"(#{&1})")], " ")
    end
  end

  # the args split by the shape; one group when the shape does not fit them
  defp groups(args, shape) do
    if Enum.sum(shape) == length(args) do
      {groups, []} = Enum.map_reduce(shape, args, fn n, rest -> Enum.split(rest, n) end)
      groups
    else
      [args]
    end
  end

  # an F# name as written in a call: an identifier as it is, an active
  # pattern's `(|A|B|)` as it is, anything else in double backticks
  defp ident(name) do
    if name =~ ~r/\A[A-Za-z_][A-Za-z0-9_']*\z/ or name =~ ~r/\A\(\|.*\|\)\z/, do: name, else: "``#{name}``"
  end

  @doc """
  The three submissions for `entry`. `call` writes the call expression
  from the entry (its args already kept on one line): `call_expression/1`
  for F#, C#'s own for C# (the same window, `Repl.CSharp.EvalTemplate`).
  """
  @spec build(map(), (map() -> String.t())) :: String.t()
  def build(%{call_id: call_id, module: module, name: name, args: args, limits: %{timeout: timeout_ms}} = entry, call \\ &call_expression/1) do
    # Core's own binding name (`binding_name/1`)
    var = "xt_" <> String.replace(call_id, ~r/[^A-Za-z0-9_]/, "_")
    # a newline inside an argument would only be part of the submission,
    # but keeps the entry on three lines
    args = Enum.map(args, &String.replace(&1, ~r/\r?\n/, " "))
    id = Launch.string(call_id)

    case Enum.find_value(args, &check/1) do
      nil ->
        basis =
          case Map.get(entry, :basis, :none) do
            {:exact, text} -> "(Some (\"exact\", #{Launch.string(text)}))"
            {:binary, b64} -> "(Some (\"binary\", #{Launch.string(b64)}))"
            _ -> "None"
          end

        call = call.(%{entry | args: args})

        """
        Embody.start #{id} #{timeout_ms} #{basis};;
        let #{var} = Embody.call (fun () -> #{call});;
        Embody.finish #{id} #{Launch.string(module)} #{Launch.string(name)} #{length(args)};;
        """

      reason ->
        "Embody.fail #{id} #{Launch.string("the call was not sent: " <> reason)};;\n"
    end
  end

  @doc """
  Why the argument `text` would leave fsi reading on after `;;`, or `nil`:
  an unclosed string (`"…"`, `@"…"`, `\"\"\"…\"\"\"`), an unclosed or
  mismatched bracket, a `;;` or a `//` / `(*` comment outside strings.
  """
  @spec check(String.t()) :: String.t() | nil
  def check(text), do: scan(text, [])

  defp scan(<<>>, []), do: nil
  defp scan(<<>>, [open | _]), do: "an unclosed #{open}"
  defp scan(<<"\"\"\"", rest::binary>>, stack), do: close(rest, "\"\"\"", stack)
  defp scan(<<"@\"", rest::binary>>, stack), do: verbatim(rest, stack)
  defp scan(<<"$@\"", rest::binary>>, stack), do: verbatim(rest, stack)
  defp scan(<<"@$\"", rest::binary>>, stack), do: verbatim(rest, stack)
  defp scan(<<"\"", rest::binary>>, stack), do: string(rest, stack)
  defp scan(<<";;", _::binary>>, _stack), do: "a ;; outside a string"
  defp scan(<<"//", _::binary>>, _stack), do: "a // comment"
  defp scan(<<"(*)", rest::binary>>, stack), do: scan(rest, stack)
  defp scan(<<"(*", _::binary>>, _stack), do: "a (* comment"

  defp scan(<<"'", rest::binary>> = text, stack) do
    # a char literal ('a', '\n', '\u0041'); any other ' is a type variable or a name's
    case Regex.run(~r/\A'(?:\\u[0-9A-Fa-f]{4}|\\.|[^'\\])'/u, text) do
      [lit] -> scan(binary_part(text, byte_size(lit), byte_size(text) - byte_size(lit)), stack)
      nil -> scan(rest, stack)
    end
  end

  defp scan(<<c, rest::binary>>, stack) when c in ~c"([{", do: scan(rest, [<<c>> | stack])

  defp scan(<<c, rest::binary>>, stack) when c in ~c")]}" do
    want = %{")" => "(", "]" => "[", "}" => "{"}[<<c>>]

    case stack do
      [^want | more] -> scan(rest, more)
      [open | _] -> "#{<<c>>} closing #{open}"
      [] -> "#{<<c>>} without its opening"
    end
  end

  defp scan(<<_, rest::binary>>, stack), do: scan(rest, stack)

  defp string(<<"\\", _, rest::binary>>, stack), do: string(rest, stack)
  defp string(<<"\"", rest::binary>>, stack), do: scan(rest, stack)
  defp string(<<_, rest::binary>>, stack), do: string(rest, stack)
  defp string(<<>>, _stack), do: "an unclosed string"

  defp verbatim(<<"\"\"", rest::binary>>, stack), do: verbatim(rest, stack)
  defp verbatim(<<"\"", rest::binary>>, stack), do: scan(rest, stack)
  defp verbatim(<<_, rest::binary>>, stack), do: verbatim(rest, stack)
  defp verbatim(<<>>, _stack), do: "an unclosed string"

  defp close(text, quote, stack) do
    case :binary.split(text, quote) do
      [_, rest] -> scan(rest, stack)
      [_] -> "an unclosed string"
    end
  end
end
