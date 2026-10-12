ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/in_out.exs", __DIR__))
Code.require_file(Path.expand("../lib/input.exs", __DIR__))

defmodule DialogueDoTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core, InOut, Input, Methods}
  alias XipeTotec.Dialogue.Do

  setup do
    book =
      Book.new()
      |> Core.put_sheet("s1", %{path: "lib/calc.ex"})
      |> Core.put_node("n_add", %{sheet: "s1", module: "Calc", name: "add", anykey: 2, effect: "pure"})
      |> Core.put_node("n_sq", %{sheet: "s1", module: "Calc", name: "square", anykey: 1, effect: "unknown"})
      |> Core.put_node("n_sq2", %{sheet: "s1", module: "Other", name: "square", anykey: 1, effect: "unknown"})
      |> Core.put_node("n_hs", %{sheet: "s1", module: "Data.List", name: "total", anykey: nil, effect: "pure"})
      |> Core.add_call("c1", %{node: "n_add", args: ["1", "2"]})

    %{ctx: %{book: book, root: "/nonexistent", project_dir: nil}}
  end

  # the turns of one dialogue: start with `params`, then each line as an answer
  defp turns(ctx, params, lines) do
    Enum.reduce(lines, Do.start(params, ctx), fn line, turn ->
      {:hold, state, _text} = turn
      Do.answer(state, %{"text" => line}, ctx)
    end)
  end

  defp start(method, given \\ %{}), do: %{"method" => method, "given" => given}

  describe "what is asked" do
    test "every required parameter the line didn't give, in order; then the call is shown and y runs it", %{ctx: ctx} do
      assert {:hold, _, "node? (a function: its id, or its name as Calc.add/2)"} = Do.start(start("row/add"), ctx)

      assert {:hold, _, "args? (a list of 2: { alone to open, one per line, } alone to close)"} = turns(ctx, start("row/add"), ["Calc.add/2"])

      assert {:hold, %{confirm: true}, shown} = turns(ctx, start("row/add"), ["Calc.add/2", "{", "[1,2,3]", ~s({:ok, "a b"}), "}"])
      assert shown == "row/add\n  args = {\n    [1,2,3]\n    {:ok, \"a b\"}\n  }\n  node = n_add  (Calc.add/2)\nRun it? (y/n)"

      assert {:done, "Running row/add.", [command]} = turns(ctx, start("row/add"), ["Calc.add/2", "{", "[1,2,3]", ~s({:ok, "a b"}), "}", "y"])
      assert command == %{"method" => "row/add", "params" => %{"node" => "n_add", "args" => ["[1,2,3]", ~s({:ok, "a b"})]}}
    end

    test "n drops the call; anything else asks again", %{ctx: ctx} do
      lines = ["n_sq", "{", "3", "}"]
      assert {:done, "Nothing was run.", []} = turns(ctx, start("row/add"), lines ++ ["n"])
      assert {:hold, %{confirm: true}, "Answer y or n.\nRun it? (y/n)"} = turns(ctx, start("row/add"), lines ++ ["maybe"])
    end

    test "what the starting line gave is not asked for", %{ctx: ctx} do
      assert {:hold, _, "effect? (pure | reads | writes)"} = Do.start(start("effect/set", %{"id" => "n_sq"}), ctx)
      assert {:done, _, [%{"params" => %{"id" => "n_sq", "effect" => "pure"}}]} = turns(ctx, start("effect/set", %{"id" => "n_sq"}), ["pure", "y"])
    end

    test "an optional parameter is never asked for: a method with none required runs at once (a read) or is shown (a write)", %{ctx: ctx} do
      assert {:done, "row/list", [%{"method" => "row/list", "params" => %{}}]} = Do.start(start("row/list"), ctx)
      assert {:done, "roster", [%{"method" => "roster"}]} = Do.start(start("roster"), ctx)

      assert {:hold, %{confirm: true}, "eval\n  call_ids = {\n    c1\n  }\nRun it? (y/n)"} = Do.start(start("eval", %{"call_ids" => ["c1"]}), ctx)
    end

    test "a method that isn't one ends the dialogue saying so", %{ctx: ctx} do
      assert {:done, "dialogue do: no such method: nope" <> _, []} = Do.start(start("nope"), ctx)
      assert {:done, "dialogue do: trace/get is not implemented", []} = Do.start(start("trace/get"), ctx)
      assert {:done, "dialogue do: no such method: " <> _, []} = Do.start(%{}, ctx)
    end
  end

  describe "a function" do
    test "by id, by name with its argument count, and by name alone where the language has none", %{ctx: ctx} do
      assert {:hold, %{params: %{"id" => "n_add"}}, _} = turns(ctx, start("effect/set"), ["n_add"])
      assert {:hold, %{params: %{"id" => "n_add"}}, _} = turns(ctx, start("effect/set"), ["Calc.add/2"])
      assert {:hold, %{params: %{"id" => "n_hs"}}, _} = turns(ctx, start("effect/set"), ["Data.List.total"])
    end

    test "a name that names nothing asks again; one several share lists them", %{ctx: ctx} do
      assert {:hold, %{params: params}, "no function Calc.nope/1\nid? (a function" <> _} = turns(ctx, start("effect/set"), ["Calc.nope/1"])
      assert params == %{}

      assert {:hold, _, text} = turns(ctx, start("effect/set"), ["square/1"])
      assert text =~ "square/1 names 2 functions -- answer with the id of one:"
      assert text =~ "  n_sq  Calc.square/1  lib/calc.ex"
      assert text =~ "  n_sq2  Other.square/1  lib/calc.ex"
    end

    test "a count a person declared with arity/set names the function too", %{ctx: ctx} do
      ctx = %{ctx | book: Core.set_arities(ctx.book, "n_add", [1, 2])}
      assert {:hold, %{params: %{"id" => "n_add"}}, _} = turns(ctx, start("effect/set"), ["Calc.add/1"])
      assert {:hold, %{params: params}, "no function Calc.add/3" <> _} = turns(ctx, start("effect/set"), ["Calc.add/3"])
      assert params == %{}
    end

    test "given by name on the starting line it is looked up the same way; one that names nothing is asked for", %{ctx: ctx} do
      assert {:hold, %{params: %{"node" => "n_add"}}, "args?" <> _} = Do.start(start("row/add", %{"node" => "Calc.add/2"}), ctx)
      assert {:hold, %{params: params}, "no function Calc.nope\nnode?" <> _} = Do.start(start("row/add", %{"node" => "Calc.nope"}), ctx)
      assert params == %{}
    end
  end

  describe "a list" do
    test "only a line holding { opens it; an element may itself be in braces", %{ctx: ctx} do
      assert {:hold, %{list: nil}, "args is a list: a line holding only { opens it\nargs?" <> _} = turns(ctx, start("row/add"), ["n_sq", "1"])
      assert {:hold, %{list: []}, "args: open -- one per line, } alone to close"} = turns(ctx, start("row/add"), ["n_sq", "{"])
      assert {:hold, %{list: ["{1, 2}"]}, "  1: {1, 2}"} = turns(ctx, start("row/add"), ["n_sq", "{", "{1, 2}"])
      assert {:hold, %{confirm: true, params: %{"args" => ["%{a: 1}"]}}, _} = turns(ctx, start("row/add"), ["n_sq", "{", "%{a: 1}", "}"])
    end

    test "{ then } is the empty list", %{ctx: ctx} do
      ctx = %{ctx | book: Core.put_node(ctx.book, "n0", %{sheet: "s1", module: "Calc", name: "zero", anykey: 0, effect: "pure"})}
      assert {:hold, %{confirm: true, params: %{"args" => []}}, _} = turns(ctx, start("row/add"), ["n0", "{", "}"])
    end

    test "args that don't fit the function are asked for again, from the start", %{ctx: ctx} do
      assert {:hold, %{list: nil, pending: [%{name: "args"}]}, text} = turns(ctx, start("row/add"), ["Calc.add/2", "{", "1", "}"])
      assert text =~ "Calc.add/2 takes 2 arg(s), got 1"
      assert text =~ "args? (a list of 2:"
    end

    test "row/update's args are counted against the row's own function", %{ctx: ctx} do
      assert {:hold, _, "args? (a list of 2:" <> _} = turns(ctx, start("row/update"), ["c1"])
      assert {:hold, %{params: params}, "no calc row c9\nid? (a calc row's id)"} = turns(ctx, start("row/update"), ["c9"])
      assert params == %{}
    end

    test "a list of numbers checks each element as it comes", %{ctx: ctx} do
      assert {:hold, %{list: ["1"]}, "x is not a whole number (} alone closes the list)"} = turns(ctx, start("arity/set"), ["n_add", "{", "1", "x"])
      assert {:hold, %{confirm: true, params: %{"arities" => ["1", "2"]}}, _} = turns(ctx, start("arity/set"), ["n_add", "{", "1", "2", "}"])
    end
  end

  describe "other kinds" do
    test "a choice not among the values asks again", %{ctx: ctx} do
      assert {:hold, _, "safe is not one of pure | reads | writes\neffect? (pure | reads | writes)"} = turns(ctx, start("effect/set"), ["n_sq", "safe"])
    end

    test "a value is the line as it is", %{ctx: ctx} do
      assert {:hold, %{confirm: true, params: %{"id" => "c1", "result" => ~s("a, b"  [1,2])}}, _} =
               turns(ctx, start("row/set-result"), ["c1", ~s(  "a, b"  [1,2]  )])
    end

    test "an address is a function's name taken apart: flat for card/get, an object for graph/*", %{ctx: ctx} do
      assert {:done, _, [%{"method" => "card/get", "params" => %{"module" => "Calc", "name" => "add", "arity" => "2"}}]} =
               turns(ctx, start("card/get"), ["Calc.add/2"])

      # a column on the starting line is the address already
      assert {:done, _, [%{"params" => %{"name" => "add"}}]} = Do.start(start("card/get", %{"name" => "add"}), ctx)

      assert {:hold, _, "format? (mermaid | dot | json | doctest)"} = turns(ctx, start("graph/export"), ["Calc.add/2"])

      assert {:done, _, [%{"params" => %{"address" => %{"module" => "Calc", "name" => "add", "arity" => "2"}, "format" => "dot"}}]} =
               turns(ctx, start("graph/export"), ["Calc.add/2", "dot"])
    end
  end

  describe "wired in" do
    test "InOut starts it by its method, holds it, and runs the finished call", %{ctx: ctx} do
      first = %{"method" => "dialogue/do", "params" => start("row/add")}
      {dialogue, book, %{hold: true, text: "node?" <> _}} = InOut.handle(nil, ctx.book, ctx.root, first)

      {dialogue, book, _} =
        Enum.reduce(["Calc.add/2", "{", "[1,2]", "3", "}"], {dialogue, book, nil}, fn line, {dialogue, book, _} ->
          InOut.handle(dialogue, book, ctx.root, %{"method" => "dialogue/answer", "params" => %{"text" => line}})
        end)

      {nil, new_book, %{hold: false, ok?: true, result: %{"outcomes" => [%{method: "row/add", ok?: true, result: %{"id" => id}}]}}} =
        InOut.handle(dialogue, book, ctx.root, %{"method" => "dialogue/answer", "params" => %{"text" => "y"}})

      assert Book.get(new_book, :calls, id).args == ["[1,2]", "3"]
    end

    test "the window's line: dialogue do <method> [key=value...]" do
      assert {:commands, [%{"method" => "dialogue/do", "params" => %{"method" => "row/add", "given" => %{}}}]} = Input.parse("dialogue do row/add")

      assert {:commands, [%{"method" => "dialogue/do", "params" => %{"method" => "effect/set", "given" => %{"id" => "Calc.add/2"}}}]} =
               Input.parse("dialogue do effect/set id=Calc.add/2")

      assert {:error, "dialogue do: write dialogue do <method>" <> _} = Input.parse("dialogue do")
    end
  end

  describe "Methods' params" do
    test "args is made from them, as help has always shown it" do
      assert Methods.get("row/add").args == "node=<node id> args=[...]"
      assert Methods.get("effect/set").args == "id=<node id> effect=pure|reads|writes"
      assert Methods.get("arity/set").args == "id=<node id> arities=[1,2]"
      assert Methods.get("card/get").args == "module= name= arity= file= row="
      assert Methods.get("graph/export").args == "address=<address> format=mermaid|dot|json|doctest [depth=N]"
      assert Methods.get("row/check").args == "[on=error,changed,unevaluated] [call_ids=[...]]"
      assert Methods.get("eval").args == "[call_ids=[...]] [include_writes=true]"
      assert Methods.get("cell/resolve").args == "ref=⟦<call id>⟧"
      assert Methods.get("eval/status").args == ""
    end

    test "every param is fully declared" do
      for {name, spec} <- Methods.all(), param <- spec.params do
        assert %{name: n, kind: kind, required: r, list: l} = param, name
        assert is_binary(n) and is_boolean(r) and is_boolean(l)
        assert kind in [:node, :call, :value, :choice, :number, :flag, :address]
        if kind == :choice, do: assert(is_list(param.values))
      end
    end
  end
end
