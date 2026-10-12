defmodule XipeTotec.Methods do
  @moduledoc """
  Every method a command list (`Runner`) or the WebSocket server
  (`Serve.Project`) accepts, declared once. Read from here: `Dispatch`'s
  not-implemented set, `Serve.Project`'s asynchronous eval methods, and the
  CLI's read-only check (a command list made only of read-only methods
  doesn't warn about a running session).

  Per method:

    * `route` -- where it is handled:
      * `:dispatch` -- `Dispatch.handle/4` (pure, Book in, Book out;
        `scan/run` also reads files)
      * `:repl` -- `Runner`'s `"eval"`, which drives the target's REPL
      * `:pipeline` -- `pipelines.json`/`Pipeline`, a list of stages whose
        last may be `"eval"`
      * `:not_implemented` -- a reserved method name, answered `not_implemented`
    * `writes` -- whether it can change the Book
    * `confirm` -- changes something that isn't the Book (a project's
      settings): `Dialogue.Do` shows the call and waits for `y`, as it does
      for one that `writes`
    * `repl` -- whether the server runs it as an asynchronous eval pass
      (`Serve.Project`: `{"status": "started"}` then `notify/passCompleted`;
      a `:pipeline` method's stages before `"eval"` run at once)

    * `params` -- its parameters as data, in the order they are written
      and asked for (`Dialogue.Do` asks for the required ones a line didn't
      give). Each is `%{name:, kind:, required:, list:}` plus, by kind,
      `values:` (the choices) or `flat:`; `hint:` replaces how its value is
      shown in `args`. The kinds:
      * `:node` -- a function's (node's) id
      * `:call` -- a calc row's id
      * `:value` -- text taken as it is (a value in the target language, a reference, an id of another sort)
      * `:choice` -- one of `values`
      * `:number` -- a whole number
      * `:flag` -- `true` or left out
      * `:address` -- the columns naming a function (`module`/`name`/`arity`/`file`/`row`): one object, or with `flat: true` the method's own params
      `list: true` is a list of that kind (`args`, `call_ids`, `arities`).
    * `args`/`summary` -- how its params are written in a command list
      (`xipe do`, the dialogue window's `input`) and what it does, one line
      each: `help` prints them (`XipeTotec.Help`). `args` is made from
      `params` (`args_text/1`), not written by hand. A `:not_implemented`
      method has none and isn't printed

  Not listed: session bookkeeping `Serve.Socket` handles itself
  (`initialize`, `subscribe`, `input`) and dialogue methods (`InOut`).

  A `:dispatch` method added to `Dispatch.handle/4` must be added here too;
  `test/methods_test.exs` checks both directions.
  """

  @type route :: :dispatch | :repl | :pipeline | :not_implemented
  @type kind :: :node | :call | :value | :choice | :number | :flag | :address
  @type param :: %{
          required(:name) => String.t(),
          required(:kind) => kind(),
          required(:required) => boolean(),
          required(:list) => boolean(),
          optional(:values) => [String.t()],
          optional(:flat) => boolean(),
          optional(:hint) => String.t()
        }
  @type spec :: %{route: route(), writes: boolean(), repl: boolean(), params: [param()], args: String.t(), summary: String.t() | nil}

  # the address columns as a method's own params (card/get, node/resolve)
  @flat_address %{name: "address", kind: :address, required: true, list: false, flat: true}
  @call_ids %{name: "call_ids", kind: :call, required: false, list: true}
  @include_writes %{name: "include_writes", kind: :flag, required: false, list: false}

  @methods %{
    "scan/run" => %{route: :dispatch, writes: true, summary: "read the sources and update the cards and links"},
    "row/add" => %{
      route: :dispatch,
      writes: true,
      params: [%{name: "node", kind: :node, required: true, list: false}, %{name: "args", kind: :value, required: true, list: true}],
      summary: "make a calc row"
    },
    "row/remove" => %{route: :dispatch, writes: true, params: [%{name: "id", kind: :call, required: true, list: false}], summary: "remove a calc row"},
    "row/set-result" => %{
      route: :dispatch,
      writes: true,
      params: [%{name: "id", kind: :call, required: true, list: false}, %{name: "result", kind: :value, required: true, list: false}],
      summary: "set a result value by hand, without evaluating"
    },
    "row/set-prev" => %{
      route: :dispatch,
      writes: true,
      params: [%{name: "id", kind: :call, required: true, list: false}, %{name: "prev", kind: :value, required: true, list: false}],
      summary: "set by hand the value the next evaluation is compared with (an expectation), without evaluating"
    },
    "row/set-args" => %{
      route: :dispatch,
      writes: true,
      params: [%{name: "id", kind: :call, required: true, list: false}, %{name: "args", kind: :value, required: true, list: true}],
      summary: "change a row's arguments without evaluating it (its result stays the old arguments' until eval)"
    },
    "effect/set" => %{
      route: :dispatch,
      writes: true,
      params: [
        %{name: "id", kind: :node, required: true, list: false},
        %{name: "effect", kind: :choice, required: true, list: false, values: ~w(pure reads writes)}
      ],
      summary: "classify a function's side effects (an unclassified function is never evaluated)"
    },
    "arity/set" => %{
      route: :dispatch,
      writes: true,
      params: [%{name: "id", kind: :node, required: true, list: false}, %{name: "arities", kind: :number, required: true, list: true, hint: "[1,2]"}],
      summary: "declare the argument counts default arguments allow (used for calc rows and links; arities=[<the node's own count>] resets it)"
    },
    "card/get" => %{route: :dispatch, writes: false, params: [@flat_address], summary: "get the card (function, calc rows, links) an address names"},
    "card/search" => %{route: :dispatch, writes: false, params: [@flat_address], summary: "find the cards matching an address"},
    "cell/resolve" => %{
      route: :dispatch,
      writes: false,
      params: [%{name: "ref", kind: :value, required: true, list: false, hint: "⟦<call id>⟧"}],
      summary: "look up a reference's current value"
    },
    "graph/neighbors" => %{
      route: :dispatch,
      writes: false,
      params: [
        %{name: "address", kind: :address, required: true, list: false},
        %{name: "depth", kind: :number, required: false, list: false},
        %{name: "direction", kind: :choice, required: false, list: false, values: ~w(in out both)}
      ],
      summary: "the neighbours in the call graph"
    },
    "graph/export" => %{
      route: :dispatch,
      writes: false,
      params: [
        %{name: "address", kind: :address, required: true, list: false},
        %{name: "format", kind: :choice, required: true, list: false, values: ~w(mermaid dot json doctest)},
        %{name: "depth", kind: :number, required: false, list: false}
      ],
      summary: "export the call graph"
    },
    "row/depends" => %{route: :dispatch, writes: false, params: [%{@call_ids | required: true}], summary: "walk calc rows' upstream dependencies (⟦id⟧)"},
    "row/list" => %{route: :dispatch, writes: false, params: [@call_ids], summary: "list the calc rows"},
    "eval/status" => %{route: :dispatch, writes: false, summary: "the passes being evaluated now (rows, phase, elapsed time); a row being evaluated cannot be changed"},
    "eval/cancel" => %{
      route: :dispatch,
      writes: false,
      params: [%{name: "pass_id", kind: :value, required: false, list: false, hint: "<pass id>"}],
      summary: "stop a running pass (its REPL is killed, nothing is recorded), or take a queued one out; pass_id may be left out while one pass runs"
    },
    "config/set" => %{
      route: :dispatch,
      writes: false,
      confirm: true,
      params: [%{name: "key", kind: :value, required: true, list: false, hint: "<setting>"}, %{name: "value", kind: :value, required: true, list: false}],
      summary: "set one of the open project's settings (env.path, env.refresh, eval.timeout, eval.boot_timeout); written to its own project.json"
    },
    "roster" => %{route: :dispatch, writes: false, summary: "the tables search reads: each one's name, flag (-s, -e), columns, and the columns dialogue rewrite can change"},
    "row/check" => %{
      route: :dispatch,
      writes: false,
      params: [%{name: "on", kind: :choice, required: false, list: true, values: ~w(error changed unevaluated)}, @call_ids],
      summary: "fail if any calc row meets the conditions"
    },
    "node/resolve" => %{route: :dispatch, writes: false, params: [@flat_address], summary: "look up a function's (node's) id from an address"},
    "eval" => %{route: :repl, writes: true, repl: true, params: [@call_ids, @include_writes], summary: "evaluate the given calc rows in the REPL"},
    "eval/run" => %{route: :pipeline, writes: true, repl: true, params: [@call_ids, @include_writes], summary: "evaluate the given calc rows in the REPL"},
    "row/update" => %{
      route: :pipeline,
      writes: true,
      repl: true,
      params: [%{name: "id", kind: :call, required: true, list: false}, %{name: "args", kind: :value, required: true, list: true}],
      summary: "change a row's arguments and evaluate that row only"
    },
    "cell/complete" => %{route: :not_implemented, writes: false},
    "edit/propose" => %{route: :not_implemented, writes: false},
    "edit/apply" => %{route: :not_implemented, writes: true},
    "trace/start" => %{route: :not_implemented, writes: true},
    "trace/stop" => %{route: :not_implemented, writes: true},
    "trace/get" => %{route: :not_implemented, writes: false},
    "trace/import" => %{route: :not_implemented, writes: true},
    "provider/recheck" => %{route: :not_implemented, writes: true}
  }

  @spec all() :: %{String.t() => spec()}
  def all do
    Map.new(@methods, fn {name, spec} ->
      spec = spec |> Map.put_new(:repl, false) |> Map.put_new(:confirm, false) |> Map.put_new(:params, []) |> Map.put_new(:summary, nil)
      {name, Map.put(spec, :args, args_text(spec.params))}
    end)
  end

  @doc """
  How `params` are written in a command list, as `help` shows them:
  `name=<value>` each, an optional one in `[...]`.
  """
  @spec args_text([param()]) :: String.t()
  def args_text(params), do: Enum.map_join(params, " ", &param_text/1)

  @doc "The address columns a `flat` address param stands for."
  @spec address_columns() :: [String.t()]
  def address_columns, do: ~w(module name arity file row)

  defp param_text(%{kind: :address, flat: true}), do: Enum.map_join(address_columns(), " ", &(&1 <> "="))

  defp param_text(%{name: name, required: required} = param) do
    text = "#{name}=#{value_text(param)}"
    if required, do: text, else: "[#{text}]"
  end

  defp value_text(%{hint: hint}), do: hint
  defp value_text(%{kind: :choice, list: true, values: values}), do: Enum.join(values, ",")
  defp value_text(%{list: true}), do: "[...]"
  defp value_text(%{kind: :node}), do: "<node id>"
  defp value_text(%{kind: :call}), do: "<call id>"
  defp value_text(%{kind: :value}), do: "<value>"
  defp value_text(%{kind: :choice, values: values}), do: Enum.join(values, "|")
  defp value_text(%{kind: :number}), do: "N"
  defp value_text(%{kind: :flag}), do: "true"
  defp value_text(%{kind: :address}), do: "<address>"

  @spec get(String.t()) :: spec() | nil
  def get(name), do: Map.get(all(), name)

  @doc "The names whose `route` is one of `routes`, sorted."
  @spec names([route()]) :: [String.t()]
  def names(routes), do: for({name, %{route: r}} <- all(), r in routes, do: name) |> Enum.sort()

  @doc "Known and never changes the Book. An unknown method is not read-only."
  @spec read_only?(String.t()) :: boolean()
  def read_only?(name), do: match?(%{writes: false}, get(name))

  @doc "The server runs it as an asynchronous eval pass."
  @spec repl?(String.t()) :: boolean()
  def repl?(name), do: match?(%{repl: true}, get(name))
end
