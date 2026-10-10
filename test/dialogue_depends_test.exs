ExUnit.start()

Code.require_file(Path.expand("../lib/dialogue/depends.exs", __DIR__))

defmodule DialogueDependsTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Dialogue.Depends

  # Deepest-first chain a real Core.upstream_chain/2 + Core.call_label/2
  # call would produce for w1(w2(w3)) -- w3 is the target's deepest
  # dependency, w1 the target itself. Depends never touches Book (see its
  # own moduledoc), so every test here builds this plain data directly.
  @chain [
    %{"id" => "w3", "label" => "M.w3/0"},
    %{"id" => "w2", "label" => "M.w2/1"},
    %{"id" => "w1", "label" => "M.w1/1"}
  ]

  test "start/1 asks about the deepest dependency first, holding" do
    assert {:hold, state, text} = Depends.start(%{"chain" => @chain})
    assert state == %{chain: @chain, position: 0}
    assert text =~ "w3"
    assert text =~ "M.w3/0"
  end

  test "start/1 with no upstream dependencies (chain is just the target) does nothing immediately" do
    assert {:done, text, []} = Depends.start(%{"chain" => [%{"id" => "w1", "label" => "M.w1/1"}]})
    assert text =~ "No upstream dependency is left"
  end

  test "\"n\" climbs one level and asks about the next-shallower dependency" do
    {:hold, state, _} = Depends.start(%{"chain" => @chain})
    assert {:hold, state2, text} = Depends.answer(state, %{"answer" => "n"})
    assert state2 == %{chain: @chain, position: 1}
    assert text =~ "w2"
  end

  test "\"n\" all the way through does nothing, no commands" do
    {:hold, state, _} = Depends.start(%{"chain" => @chain})
    {:hold, state, _} = Depends.answer(state, %{"answer" => "n"})
    assert {:done, text, []} = Depends.answer(state, %{"answer" => "n"})
    assert text =~ "Nothing is run"
  end

  test "\"y\" with a value at the deepest step stubs it and evaluates everything above, target included" do
    {:hold, state, _} = Depends.start(%{"chain" => @chain})
    assert {:done, text, commands} = Depends.answer(state, %{"answer" => "y", "value" => "42"})

    assert text =~ "w3"
    assert commands == [
             %{"method" => "row/set-result", "params" => %{"id" => "w3", "result" => "42"}},
             %{"method" => "eval", "params" => %{"call_ids" => ["w2", "w1"], "include_writes" => true}}
           ]
  end

  test "\"y\" at a middle step only evaluates what's shallower than it -- the declined deepest step is dropped, not touched" do
    {:hold, state, _} = Depends.start(%{"chain" => @chain})
    {:hold, state, _} = Depends.answer(state, %{"answer" => "n"})
    assert {:done, _text, commands} = Depends.answer(state, %{"answer" => "y", "value" => "%{a: 1}"})

    assert commands == [
             %{"method" => "row/set-result", "params" => %{"id" => "w2", "result" => "%{a: 1}"}},
             %{"method" => "eval", "params" => %{"call_ids" => ["w1"], "include_writes" => true}}
           ]
  end

  test "an unrecognized answer re-asks the same question instead of guessing" do
    {:hold, state, _} = Depends.start(%{"chain" => @chain})
    assert {:hold, state2, text} = Depends.answer(state, %{"answer" => "maybe"})
    assert state2 == state
    assert text =~ "Answer y (with a value) or n"
    assert text =~ "w3"
  end

  test "\"y\" with no value re-asks rather than crashing" do
    {:hold, state, _} = Depends.start(%{"chain" => @chain})
    assert {:hold, ^state, text} = Depends.answer(state, %{"answer" => "y"})
    assert text =~ "w3"
  end

  test "a typed line (the CLI prompt, the dialogue window) reads as y <value> / n" do
    assert %{"answer" => "y", "value" => "%{a: 1, b: 2}"} = XipeTotec.Dialogue.answer_params(Depends, "y %{a: 1, b: 2}\n")
    assert %{"answer" => "n"} = XipeTotec.Dialogue.answer_params(Depends, " n ")
    assert %{"answer" => "maybe"} = Depends.parse_answer("maybe")
  end
end
