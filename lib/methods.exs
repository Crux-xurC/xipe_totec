defmodule XipeTotec.Methods do
  @moduledoc """
  Every method a command list (`Runner`) or the WebSocket server
  (`Serve.Project`) accepts, declared once (2026-09-26). Everything that used
  to keep its own list of method names reads it from here: `Dispatch`'s
  not-implemented set, `Serve.Project`'s asynchronous eval methods, and the
  CLI's read-only check (a command list made only of read-only methods
  doesn't warn about a running session).

  Per method:

    * `route` -- where it is handled:
      * `:dispatch` -- `Dispatch.handle/4` (pure, Book in, Book out;
        `scan/run` also reads files)
      * `:repl` -- `Runner`'s `"eval"`, which drives the target's REPL
      * `:pipeline` -- `pipelines.json`/`Pipeline`, a list of stages whose
        last may be `"eval"` (Old.md §37)
      * `:not_implemented` -- a spec §16.3 method not built yet
    * `writes` -- whether it can change the Book
    * `repl` -- whether the server runs it as an asynchronous eval pass
      (`Serve.Project`: `{"status": "started"}` then `notify/passCompleted`;
      a `:pipeline` method's stages before `"eval"` run at once)

  Not listed: session bookkeeping `Serve.Socket` handles itself
  (`initialize`, `subscribe`) and dialogue methods (`InOut`).

  A `:dispatch` method added to `Dispatch.handle/4` must be added here too;
  `test/methods_test.exs` checks both directions.
  """

  @type route :: :dispatch | :repl | :pipeline | :not_implemented
  @type spec :: %{route: route(), writes: boolean(), repl: boolean()}

  @methods %{
    "scan/run" => %{route: :dispatch, writes: true},
    "row/add" => %{route: :dispatch, writes: true},
    "row/remove" => %{route: :dispatch, writes: true},
    "row/set-result" => %{route: :dispatch, writes: true},
    "effect/set" => %{route: :dispatch, writes: true},
    "card/get" => %{route: :dispatch, writes: false},
    "card/search" => %{route: :dispatch, writes: false},
    "cell/resolve" => %{route: :dispatch, writes: false},
    "graph/neighbors" => %{route: :dispatch, writes: false},
    "graph/export" => %{route: :dispatch, writes: false},
    "row/depends" => %{route: :dispatch, writes: false},
    "row/list" => %{route: :dispatch, writes: false},
    "row/check" => %{route: :dispatch, writes: false},
    "node/resolve" => %{route: :dispatch, writes: false},
    "eval" => %{route: :repl, writes: true, repl: true},
    "eval/run" => %{route: :pipeline, writes: true, repl: true},
    "row/update" => %{route: :pipeline, writes: true, repl: true},
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
  def all, do: Map.new(@methods, fn {name, spec} -> {name, Map.put_new(spec, :repl, false)} end)

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
