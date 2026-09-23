Code.require_file("../dialogue.exs", __DIR__)

defmodule XipeTotec.Dialogue.Depends do
  @moduledoc """
  The dependency-chain negotiation (Old.md §16.4/§19, crux's design,
  step 4 of §16.4's agreed build order -- steps 1-3, the `include_writes`
  wiring, `Core.upstream_chain/2`, and this `Dialogue`/`InOut` layer
  itself, were already built in earlier sessions). The concrete
  `w1(w2(w3(...)))` scenario from §16.4: walk a target call's upstream
  `⟦id⟧` chain from deepest to shallowest, and at each step ask whether to
  hand-supply that step's value (skipping real evaluation for it and
  everything deeper) and actually run everything from there up through the
  target for real.

  ## Deliberately Book-free (§19 co-design decision)

  `Dialogue.start/1`'s callback only receives `params`, never `book` --
  `InOut.handle/6` never threads `book` into a dialogue program (see
  `Dialogue`'s own moduledoc). Rather than changing that established §17
  contract, the caller (`main.exs`'s CLI today, a future WS adapter later)
  is expected to resolve the chain *before* starting this dialogue, via
  the already-built `Core.upstream_chain/2` + `Core.call_label/2`, and
  pass the fully-resolved, already-labelled chain in as plain data:

      params = %{"chain" => [%{"id" => call_id, "label" => "M.f/1"}, ...]}

  `chain` is `Core.upstream_chain/2`'s own output shape (deepest-first,
  the target itself last), each entry paired with its display label. This
  module never touches a `Book` at all -- it only ever reads/writes this
  one plain data structure, exactly the "extremely thin" shape crux's
  original design sketch expected once the command-list foundation
  (`Runner`'s `$n.path` refs, `row/set-result`, `include_writes`) already
  existed.

  ## Negotiation semantics (§16.4, confirmed 2026-09-22)

  The target itself (`chain`'s last entry) is never asked about -- only
  its upstream dependencies (`chain`'s every entry *except* the last).
  Walking from `position` 0 (deepest):

    * `"y"` with a `"value"` (already target-language literal source
      text): commits. Two commands are built -- `row/set-result` stamps
      `value` straight onto the current step (no evaluation), then `eval`
      (`include_writes: true`) runs every step *shallower* than the
      current one, target included. Negotiation ends (`:done`).
    * `"n"`: climbs one level (drops the current step without touching
      it -- it is simply never evaluated, same as everything deeper than
      it that was already declined) and asks about the next-shallower
      step.
    * The chain exhausted (every dependency declined, or `chain` had no
      dependencies to begin with -- just the target alone): `:done` with
      no commands at all. **Deliberately does not fall back to evaluating
      the target directly** -- confirmed with crux 2026-09-22: a plain
      direct evaluation is a different, already-existing operation (the
      ordinary `"eval"` command), reachable on its own; this negotiation
      only ever produces the stub+eval-from-here shape, never a bare eval.
    * Anything else as an answer (missing/unrecognized `"answer"`, or
      `"y"` with no `"value"`): re-asks the same question rather than
      guessing, `:hold` with the identical state.
  """

  @behaviour XipeTotec.Dialogue

  @impl true
  def start(%{"chain" => chain}) when is_list(chain), do: ask_or_finish(chain, 0)

  @impl true
  def answer(%{chain: chain, position: position}, %{"answer" => "y", "value" => value})
      when is_binary(value) do
    current = Enum.at(chain, position)
    above = chain |> Enum.drop(position + 1) |> Enum.map(& &1["id"])

    commands = [
      %{"method" => "row/set-result", "params" => %{"id" => current["id"], "result" => value}},
      %{"method" => "eval", "params" => %{"call_ids" => above, "include_writes" => true}}
    ]

    {:done, "#{current["id"]} (#{current["label"]}) に値を注入し、その上流を評価します。", commands}
  end

  def answer(%{chain: chain, position: position}, %{"answer" => "n"}),
    do: ask_or_finish(chain, position + 1)

  def answer(state, _params),
    do: {:hold, state, "y (と value) または n で答えてください。\n" <> question(state.chain, state.position)}

  # position >= length(chain) - 1 means either the chain is down to just
  # the target itself (nothing left to ask about) or every dependency has
  # already been declined -- both end the negotiation the same way, doing
  # nothing (see moduledoc's "deliberately does not fall back" note).
  defp ask_or_finish(chain, position) when position >= length(chain) - 1,
    do: {:done, "上流依存を使い切りました。何も実行しません。", []}

  defp ask_or_finish(chain, position),
    do: {:hold, %{chain: chain, position: position}, question(chain, position)}

  defp question(chain, position) do
    current = Enum.at(chain, position)
    ";; w#{position + 1} #{current["label"]}\n#{current["id"]} に値を入れて評価しますか？(y/n)"
  end
end
