Code.require_file("../dialogue.exs", __DIR__)
Code.require_file("../methods.exs", __DIR__)
Code.require_file("../address.exs", __DIR__)
Code.require_file("../core.exs", __DIR__)
Code.require_file("../dispatch.exs", __DIR__)

defmodule XipeTotec.Dialogue.Do do
  @moduledoc """
  `dialogue do <method> [key=value...]`: a method call put together by
  asking. What the starting line gave is kept; every required parameter it
  didn't give (`XipeTotec.Methods`' `params`) is asked for, one at a time,
  and the finished call is run as the one command it is. An optional
  parameter is never asked for -- write it on the starting line.

  An answer is the whole line as it is: no splitting into words, no quotes
  removed, no commas read. That is the point -- a value the one-line form
  can't carry (`[1,2,3]` as one argument, `"a b"`, a tuple) is typed here
  unchanged.

  How each kind is asked (`Methods.kind()`):

    * a function (`:node`) -- its id, or its name the way it is shown:
      `Calc.add/2`, or `Module.name` where the language has no argument
      count. A name several functions share lists them and asks again
    * a calc row (`:call`) -- its id
    * a value (`:value`) -- the line
    * a choice, a number -- checked, asked again when it isn't one
    * an address -- a function's name (`Calc.add/2`), taken apart into
      `module`/`name`/`arity`
    * a list -- a line holding only `{` opens it, then one element per
      line, and a line holding only `}` closes it. Only whole lines count,
      so an element may itself be `{1, 2}` or `%{a: 1}`. `{` then `}` is
      the empty list. A calc row's `args` are checked when the list closes
      (`Dispatch.check_args/5`: how many the function takes) and asked for
      again if they don't fit

  A wrong answer asks the same question again. When everything is there
  the call is shown, parameter by parameter; a method that writes the Book
  (or a project's settings: `Methods`' `confirm`) then waits for `y` (run
  it) or `n` (drop it), any other runs at once.
  The command goes to whoever drives the dialogue as structured params
  (`:done` with commands), never back through a line.

  Nothing is changed here: the Book is only read (to find a function, to
  count its arguments).
  """

  @behaviour XipeTotec.Dialogue

  alias XipeTotec.{Address, Book, Core, Dispatch, Methods}

  @usage "write dialogue do <method> [key=value...] (help lists the methods)"

  @impl true
  def start(params, ctx) do
    method = params["method"]
    given = if is_map(params["given"]), do: params["given"], else: %{}

    case is_binary(method) && Methods.get(method) do
      %{route: :not_implemented} ->
        {:done, "dialogue do: #{method} is not implemented", []}

      %{} = spec ->
        {given, notes} = settle_given(spec.params, given, ctx)
        pending = Enum.filter(spec.params, &(&1.required and not given?(&1, given)))
        step(%{method: method, writes: spec.writes or spec.confirm, params: given, pending: pending, list: nil, confirm: false}, ctx, notes)

      _ ->
        {:done, "dialogue do: no such method: #{method || ""} -- #{@usage}", []}
    end
  end

  @impl true
  def answer(%{confirm: true} = state, %{"text" => line}, _ctx) do
    case String.trim(line) do
      "y" -> {:done, "Running #{state.method}.", [command(state)]}
      "n" -> {:done, "Nothing was run.", []}
      _ -> {:hold, state, "Answer y or n.\nRun it? (y/n)"}
    end
  end

  def answer(%{pending: [param | rest]} = state, %{"text" => line}, ctx), do: take(param, String.trim(line), state, rest, ctx)
  def answer(state, _params, ctx), do: step(state, ctx, ["answer in one line"])

  # -- the next question, or the finished call ---------------------------------

  defp step(state, ctx, notes \\ [])

  defp step(%{pending: []} = state, ctx, notes) do
    shown = Enum.join(notes ++ [summary(state, ctx)], "\n")

    if state.writes,
      do: {:hold, %{state | confirm: true}, shown <> "\nRun it? (y/n)"},
      else: {:done, shown, [command(state)]}
  end

  defp step(%{pending: [param | _]} = state, ctx, notes),
    do: {:hold, state, Enum.join(notes ++ [question(param, state, ctx)], "\n")}

  defp command(state), do: %{"method" => state.method, "params" => state.params}

  # -- one answer -----------------------------------------------------------------

  # a list: `{` alone opens it, `}` alone closes it, a line between is an element
  defp take(%{list: true} = param, line, %{list: nil} = state, _rest, ctx) do
    if line == "{",
      do: {:hold, %{state | list: []}, "#{param.name}: open -- one per line, } alone to close"},
      else: {:hold, state, "#{param.name} is a list: a line holding only { opens it\n" <> question(param, state, ctx)}
  end

  defp take(%{list: true} = param, "}", %{list: items} = state, rest, ctx) do
    items = Enum.reverse(items)

    case check_list(param, items, state, ctx) do
      :ok -> step(%{state | params: Map.put(state.params, param.name, items), pending: rest, list: nil}, ctx)
      {:error, message} -> {:hold, %{state | list: nil}, message <> "\n" <> question(param, state, ctx)}
    end
  end

  defp take(%{list: true} = param, line, %{list: items} = state, _rest, ctx) do
    case element(param, line, ctx) do
      {:ok, value} -> {:hold, %{state | list: [value | items]}, "  #{length(items) + 1}: #{line}"}
      {:error, message} -> {:hold, state, message <> " (} alone closes the list)"}
    end
  end

  defp take(param, line, state, rest, ctx) do
    case element(param, line, ctx) do
      {:ok, value} -> step(%{state | params: put(param, value, state.params), pending: rest}, ctx)
      {:error, message} -> {:hold, state, message <> "\n" <> question(param, state, ctx)}
    end
  end

  defp put(%{kind: :address, flat: true}, address, params), do: Map.merge(params, address)
  defp put(param, value, params), do: Map.put(params, param.name, value)

  # one typed value of `param`'s kind, in the form a command list carries it
  defp element(_param, "", _ctx), do: {:error, "an empty line"}
  defp element(%{kind: :node}, text, ctx), do: resolve_node(ctx.book, text)
  defp element(%{kind: :value}, text, _ctx), do: {:ok, text}
  defp element(%{kind: :address}, text, _ctx), do: {:ok, address_of(text)}

  defp element(%{kind: :call}, text, ctx),
    do: if(Book.get(ctx.book, :calls, text), do: {:ok, text}, else: {:error, "no calc row #{text}"})

  defp element(%{kind: :choice, values: values}, text, _ctx),
    do: if(text in values, do: {:ok, text}, else: {:error, "#{text} is not one of #{Enum.join(values, " | ")}"})

  defp element(%{kind: :number}, text, _ctx) do
    case Integer.parse(text) do
      {_n, ""} -> {:ok, text}
      _ -> {:error, "#{text} is not a whole number"}
    end
  end

  defp element(%{kind: :flag}, text, _ctx) do
    case text do
      "y" -> {:ok, "true"}
      "n" -> {:ok, "false"}
      _ -> {:error, "answer y or n"}
    end
  end

  # a calc row's args against the function they are for, as row/add checks them
  defp check_list(%{name: "args"}, items, state, ctx) do
    with node_id when is_binary(node_id) <- args_node(state.params, ctx.book),
         {:error, %{"message" => message}} <- Dispatch.check_args(ctx.book, node_id, items, state.method, ctx[:root]) do
      {:error, message}
    else
      _ -> :ok
    end
  end

  defp check_list(_param, _items, _state, _ctx), do: :ok

  # the function `args` are for: row/add's `node`, or the row's own (row/update's `id`)
  defp args_node(%{"node" => node_id}, _book) when is_binary(node_id), do: node_id

  defp args_node(%{"id" => call_id}, book) when is_binary(call_id) do
    case Book.get(book, :calls, call_id) do
      %{node: node_id} -> node_id
      _ -> nil
    end
  end

  defp args_node(_params, _book), do: nil

  # -- what the starting line gave -------------------------------------------------

  # a function given by name on the starting line (node=Calc.add/2) is
  # looked up as an answer would be; one that names nothing is asked for
  defp settle_given(params, given, ctx) do
    Enum.reduce(params, {given, []}, fn
      %{kind: :node, list: false, name: name}, {given, notes} ->
        case Map.get(given, name) do
          text when is_binary(text) ->
            case resolve_node(ctx.book, text) do
              {:ok, id} -> {Map.put(given, name, id), notes}
              {:error, message} -> {Map.delete(given, name), notes ++ [message]}
            end

          _ ->
            {given, notes}
        end

      _param, acc ->
        acc
    end)
  end

  defp given?(%{kind: :address, flat: true}, given), do: Enum.any?(Methods.address_columns(), &Map.has_key?(given, &1))
  defp given?(param, given), do: Map.has_key?(given, param.name)

  # -- a function by id or by name --------------------------------------------------

  defp resolve_node(book, text) do
    if Book.get(book, :nodes, text) do
      {:ok, text}
    else
      address = address_of(text)

      case Address.resolve(book, address) do
        {:ok, [{:nodes, id, _row}]} -> {:ok, id}
        {:ok, []} -> by_declared_arity(book, address, text)
        {:ok, matches} -> {:error, candidates(book, text, matches)}
        {:error, _} -> {:error, "no function #{text}"}
      end
    end
  end

  # `Calc.scale/1` for a function defined with 2 arguments and declared
  # callable with 1 (arity/set): the count is one it accepts, not its own
  defp by_declared_arity(book, %{"arity" => arity} = address, text) do
    n = String.to_integer(arity)

    case Address.resolve(book, Map.delete(address, "arity")) do
      {:ok, matches} ->
        case Enum.filter(matches, fn {:nodes, _id, row} -> n in (Core.accepted_arities(row) || []) end) do
          [{:nodes, id, _row}] -> {:ok, id}
          [] -> {:error, "no function #{text}"}
          several -> {:error, candidates(book, text, several)}
        end

      _ ->
        {:error, "no function #{text}"}
    end
  end

  defp by_declared_arity(_book, _address, text), do: {:error, "no function #{text}"}

  defp candidates(book, text, matches) do
    lines =
      for {:nodes, id, row} <- Enum.sort_by(matches, &elem(&1, 1)) do
        path = (Book.get(book, :sheets, row[:sheet]) || %{})[:path]
        "  #{id}  #{Core.node_label(row)}#{if path, do: "  #{path}", else: ""}"
      end

    Enum.join(["#{text} names #{length(matches)} functions -- answer with the id of one:" | lines], "\n")
  end

  # "Calc.add/2" -> module Calc, name add, arity 2; "Data.List.sum" ->
  # module Data.List, name sum; "main" -> name main
  defp address_of(text) do
    {rest, arity} =
      case Regex.run(~r/^(.*)\/(\d+)$/, text) do
        [_, rest, n] -> {rest, n}
        nil -> {text, nil}
      end

    {module, name} =
      case String.split(rest, ".") do
        [name] -> {nil, name}
        parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
      end

    for {key, value} <- [{"module", module}, {"name", name}, {"arity", arity}], value != nil, into: %{}, do: {key, value}
  end

  # -- what is said -------------------------------------------------------------------

  defp question(%{list: true} = param, state, ctx),
    do: "#{param.name}? (a list#{how_many(param, state, ctx)}: { alone to open, one per line, } alone to close)"

  defp question(%{kind: :node, name: name}, _state, _ctx), do: "#{name}? (a function: its id, or its name as Calc.add/2)"
  defp question(%{kind: :call, name: name}, _state, _ctx), do: "#{name}? (a calc row's id)"
  defp question(%{kind: :value, name: name}, _state, _ctx), do: "#{name}? (the line is taken as it is)"
  defp question(%{kind: :choice, name: name, values: values}, _state, _ctx), do: "#{name}? (#{Enum.join(values, " | ")})"
  defp question(%{kind: :number, name: name}, _state, _ctx), do: "#{name}? (a whole number)"
  defp question(%{kind: :flag, name: name}, _state, _ctx), do: "#{name}? (y/n)"
  defp question(%{kind: :address, flat: true}, _state, _ctx), do: "which function? (its name as Calc.add/2, or Module.name)"
  defp question(%{kind: :address, name: name}, _state, _ctx), do: "#{name}? (a function's name as Calc.add/2, or Module.name)"

  # " of 2" for a calc row's args, when the function says how many it takes
  defp how_many(%{name: "args"}, state, ctx) do
    with node_id when is_binary(node_id) <- args_node(state.params, ctx.book),
         %{} = node <- Book.get(ctx.book, :nodes, node_id),
         [_ | _] = arities <- Core.accepted_arities(node) do
      " of #{Core.arities_text(arities)}"
    else
      _ -> ""
    end
  end

  defp how_many(_param, _state, _ctx), do: ""

  # the call as it will be sent: the method, then `name = value` per
  # parameter (a list as it was typed, between { and })
  defp summary(state, ctx) do
    kinds = for p <- Methods.get(state.method).params, into: %{}, do: {p.name, p.kind}

    lines =
      for {name, value} <- Enum.sort(state.params) do
        case value do
          list when is_list(list) -> Enum.join(["  #{name} = {" | Enum.map(list, &"    #{&1}")] ++ ["  }"], "\n")
          # an address object: its columns, as an address is written
          %{} = map -> "  #{name} = " <> Enum.map_join(Enum.sort(map), " ", fn {k, v} -> "#{k}=#{v}" end)
          value -> "  #{name} = #{value}#{label(kinds[name], value, ctx.book)}"
        end
      end

    Enum.join([state.method | lines], "\n")
  end

  defp label(:node, id, book) do
    case Book.get(book, :nodes, id) do
      nil -> ""
      node -> "  (#{Core.node_label(node)})"
    end
  end

  defp label(:call, id, book) do
    case Core.call_label(book, id) do
      nil -> ""
      text -> "  (#{text})"
    end
  end

  defp label(_kind, _value, _book), do: ""
end
