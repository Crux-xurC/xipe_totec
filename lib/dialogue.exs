defmodule XipeTotec.Dialogue do
  @moduledoc """
  The contract a multi-turn dialogue program implements to plug into
  `InOut` (this file's sibling, prebuild.md §17, 2026-09-20 co-design).

  A program never encodes the wire-level 2-bit message type itself --
  `InOut` infers it mechanically from which of the two return shapes below
  comes back:

    * `:hold` -- bit1 (保持)=1. `InOut` keeps `{module, state}` around and
      waits for the next `"dialogue/answer"` input before calling this
      program again.
    * `:done` with `commands == []` -- bit1=0, bit2=1 (`01`, xipe_totec内
      で完結). Nothing further happens; `text` is the whole result.
    * `:done` with a non-empty `commands` -- bit1=0, bit2=0 (`00`, REPLへ
      投下). `InOut` immediately hands `commands` to `Runner.run/4` and
      folds its outcomes into the reply, in the same turn.

  `text` in both shapes is the human-readable line `InOut` appends to the
  `:out` side of the dialogue log (prebuild.md §17's `{:in, text} | {:out,
  text}` entries) -- a question ("Xに値を入れて評価しますか？(y/n)") while
  holding, a closing remark ("以上の内容で評価を行います" and similar)
  when done. The program owns its own `state` shape entirely; `InOut`
  never inspects it, only threads it back on the next `answer/2` call.

  No program exists yet that implements this (prebuild.md §16.4's
  dependency-chain negotiation is designed but not built -- it's step 4 of
  §16.4's agreed order, this behaviour and `InOut` are step 3).
  `test/in_out_test.exs`'s `ToyDialogue` is the only implementation today,
  proving the wiring independent of any real program (same reasoning as
  `Repl.Evaluator`'s `ToyLanguage` test).
  """

  @doc "Starts a dialogue from the method name that named this program in `InOut`'s registry. `params` is that request's own params, unexamined by InOut."
  @callback start(params :: map()) ::
              {:hold, state :: term(), text :: String.t()}
              | {:done, text :: String.t(), commands :: [map()]}

  @doc "Continues a held dialogue with the next \"dialogue/answer\" input's params."
  @callback answer(state :: term(), params :: map()) ::
              {:hold, state :: term(), text :: String.t()}
              | {:done, text :: String.t(), commands :: [map()]}
end
