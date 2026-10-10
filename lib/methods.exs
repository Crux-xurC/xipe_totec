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
    * `repl` -- whether the server runs it as an asynchronous eval pass
      (`Serve.Project`: `{"status": "started"}` then `notify/passCompleted`;
      a `:pipeline` method's stages before `"eval"` run at once)

    * `args`/`summary` -- how its params are written in a command list
      (`xipe do`, the dialogue window's `input`) and what it does, one line
      each: `help` prints them (`XipeTotec.Help`). A `:not_implemented`
      method has none and isn't printed

  Not listed: session bookkeeping `Serve.Socket` handles itself
  (`initialize`, `subscribe`, `input`) and dialogue methods (`InOut`).

  A `:dispatch` method added to `Dispatch.handle/4` must be added here too;
  `test/methods_test.exs` checks both directions.
  """

  @type route :: :dispatch | :repl | :pipeline | :not_implemented
  @type spec :: %{route: route(), writes: boolean(), repl: boolean(), args: String.t(), summary: String.t() | nil}

  @methods %{
    "scan/run" => %{route: :dispatch, writes: true, summary: "read the sources and update the cards and links"},
    "row/add" => %{route: :dispatch, writes: true, args: "node=<node id> args=[...]", summary: "make a calc row"},
    "row/remove" => %{route: :dispatch, writes: true, args: "id=<call id>", summary: "remove a calc row"},
    "row/set-result" => %{route: :dispatch, writes: true, args: "id=<call id> result=<value>", summary: "set a result value by hand, without evaluating"},
    "effect/set" => %{route: :dispatch, writes: true, args: "id=<node id> effect=pure|reads|writes", summary: "classify a function's side effects (an unclassified function is never evaluated)"},
    "arity/set" => %{route: :dispatch, writes: true, args: "id=<node id> arities=[1,2]", summary: "declare the argument counts default arguments allow (used for calc rows and links; arities=[<the node's own count>] resets it)"},
    "card/get" => %{route: :dispatch, writes: false, args: "module= name= arity= file= row=", summary: "get the card (function, calc rows, links) an address names"},
    "card/search" => %{route: :dispatch, writes: false, args: "module= name= arity= file= row=", summary: "find the cards matching an address"},
    "cell/resolve" => %{route: :dispatch, writes: false, args: "ref=⟦<call id>⟧", summary: "look up a reference's current value"},
    "graph/neighbors" => %{route: :dispatch, writes: false, args: "address=<address> [depth=N] [direction=in|out|both]", summary: "the neighbours in the call graph"},
    "graph/export" => %{route: :dispatch, writes: false, args: "address=<address> format=mermaid|dot|json|doctest [depth=N]", summary: "export the call graph"},
    "row/depends" => %{route: :dispatch, writes: false, args: "call_ids=[...]", summary: "walk calc rows' upstream dependencies (⟦id⟧)"},
    "row/list" => %{route: :dispatch, writes: false, args: "[call_ids=[...]]", summary: "list the calc rows"},
    "eval/status" => %{route: :dispatch, writes: false, args: "", summary: "the passes being evaluated now (rows, phase, elapsed time); a row being evaluated cannot be changed"},
    "row/check" => %{route: :dispatch, writes: false, args: "[on=error,changed,unevaluated] [call_ids=[...]]", summary: "fail if any calc row meets the conditions"},
    "node/resolve" => %{route: :dispatch, writes: false, args: "module= name= arity= file= row=", summary: "look up a function's (node's) id from an address"},
    "eval" => %{route: :repl, writes: true, repl: true, args: "[call_ids=[...]] [include_writes=true]", summary: "evaluate the given calc rows in the REPL"},
    "eval/run" => %{route: :pipeline, writes: true, repl: true, args: "[call_ids=[...]] [include_writes=true]", summary: "evaluate the given calc rows in the REPL"},
    "row/update" => %{route: :pipeline, writes: true, repl: true, args: "id=<call id> args=[...]", summary: "change a row's arguments and evaluate that row only"},
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
  def all,
    do: Map.new(@methods, fn {name, spec} -> {name, spec |> Map.put_new(:repl, false) |> Map.put_new(:args, "") |> Map.put_new(:summary, nil)} end)

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
