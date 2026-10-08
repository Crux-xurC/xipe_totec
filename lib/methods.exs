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
    "scan/run" => %{route: :dispatch, writes: true, summary: "ソースを読み、カードと link を更新する"},
    "row/add" => %{route: :dispatch, writes: true, args: "node=<node id> args=[...]", summary: "計算行を作る"},
    "row/remove" => %{route: :dispatch, writes: true, args: "id=<call id>", summary: "計算行を消す"},
    "row/set-result" => %{route: :dispatch, writes: true, args: "id=<call id> result=<値>", summary: "評価せずに結果の値を手で入れる"},
    "effect/set" => %{route: :dispatch, writes: true, args: "id=<node id> effect=pure|reads|writes", summary: "関数の副作用を分類する（未分類の関数は評価しない）"},
    "arity/set" => %{route: :dispatch, writes: true, args: "id=<node id> arities=[1,2]", summary: "引数の既定値で呼べる引数の数を決める（計算行と link に使う。node の数だけに戻すなら arities=[<その数>]）"},
    "card/get" => %{route: :dispatch, writes: false, args: "module= name= arity= file= row=", summary: "住所に合うカード（関数・計算行・link）を取り出す"},
    "card/search" => %{route: :dispatch, writes: false, args: "module= name= arity= file= row=", summary: "住所に合うカードを探す"},
    "cell/resolve" => %{route: :dispatch, writes: false, args: "ref=⟦<call id>⟧", summary: "参照の今の値を引く"},
    "graph/neighbors" => %{route: :dispatch, writes: false, args: "address=<住所> [depth=N] [direction=in|out|both]", summary: "呼び出し関係の近いものを引く"},
    "graph/export" => %{route: :dispatch, writes: false, args: "address=<住所> format=mermaid|dot|json|doctest [depth=N]", summary: "呼び出し関係を書き出す"},
    "row/depends" => %{route: :dispatch, writes: false, args: "call_ids=[...]", summary: "計算行の上流の依存（⟦id⟧）をたどる"},
    "row/list" => %{route: :dispatch, writes: false, args: "[call_ids=[...]]", summary: "計算行の一覧"},
    "eval/status" => %{route: :dispatch, writes: false, args: "", summary: "いま評価中のパス（行・段・経過時間）を見る。評価中の行は変えられない"},
    "row/check" => %{route: :dispatch, writes: false, args: "[on=error,changed,unevaluated] [call_ids=[...]]", summary: "条件に当たる計算行があれば失敗する"},
    "node/resolve" => %{route: :dispatch, writes: false, args: "module= name= arity= file= row=", summary: "住所から関数（node）の id を引く"},
    "eval" => %{route: :repl, writes: true, repl: true, args: "[call_ids=[...]] [include_writes=true]", summary: "指定した計算行を REPL で評価する"},
    "eval/run" => %{route: :pipeline, writes: true, repl: true, args: "[call_ids=[...]] [include_writes=true]", summary: "指定した計算行を REPL で評価する"},
    "row/update" => %{route: :pipeline, writes: true, repl: true, args: "id=<call id> args=[...]", summary: "引数を変えて、その行だけを評価する"},
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
