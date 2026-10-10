Code.require_file("../dialogue.exs", __DIR__)
Code.require_file("../core.exs", __DIR__)

defmodule XipeTotec.Dialogue.Depends do
  @moduledoc """
  The dependency-chain negotiation: walk a target call's upstream `⟦id⟧`
  chain (`w1(w2(w3(...)))`) from deepest to shallowest, and at each step
  ask whether to hand-supply that step's value (skipping evaluation for it
  and everything deeper) and run everything from there up through the
  target.

  ## The chain is plain data

  This module never changes a `Book`. The chain it works on is plain data,
  either passed in already resolved and labelled:

      params = %{"chain" => [%{"id" => call_id, "label" => "M.f/1"}, ...]}

  (`Core.upstream_chain/2`'s output, deepest first, the target last, each
  entry with its display label), or built from the read-only book `InOut`
  hands in when started with just a `call_id`.

  ## Negotiation

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
      dependencies -- just the target alone): `:done` with no commands. It
      does not fall back to evaluating the target directly; that is the
      ordinary `"eval"` command.
    * Anything else as an answer (missing/unrecognized `"answer"`, or
      `"y"` with no `"value"`): re-asks the same question rather than
      guessing, `:hold` with the identical state.
  """

  @behaviour XipeTotec.Dialogue

  @impl true
  def start(%{"chain" => chain}) when is_list(chain), do: ask_or_finish(chain, 0)

  # Started with just a `call_id` (the server, the dialogue window): the
  # chain is built from the read-only book InOut hands in, the way the CLI
  # builds it.
  @impl true
  def start(%{"chain" => _} = params, _ctx), do: start(params)

  def start(%{"call_id" => call_id}, %{book: book}) when is_binary(call_id) do
    if XipeTotec.Book.get(book, :calls, call_id) do
      start(%{"chain" => chain(book, call_id)})
    else
      {:done, "There is no calc row #{call_id}.", []}
    end
  end

  def start(_params, _ctx), do: {:done, "dialogue depends needs a call_id (dialogue depends <call_id>).", []}

  @doc "`call_id`'s upstream chain, deepest first, each with its label -- `start/1`'s `chain`."
  @spec chain(XipeTotec.Book.t(), String.t()) :: [map()]
  def chain(book, call_id) do
    book
    |> XipeTotec.Core.upstream_chain([call_id])
    |> Enum.map(fn id -> %{"id" => id, "label" => XipeTotec.Core.call_label(book, id) || id} end)
  end

  @impl true
  def answer(%{chain: chain, position: position}, %{"answer" => "y", "value" => value})
      when is_binary(value) do
    current = Enum.at(chain, position)
    above = chain |> Enum.drop(position + 1) |> Enum.map(& &1["id"])

    commands = [
      %{"method" => "row/set-result", "params" => %{"id" => current["id"], "result" => value}},
      %{"method" => "eval", "params" => %{"call_ids" => above, "include_writes" => true}}
    ]

    {:done, "Supplying a value for #{current["id"]} (#{current["label"]}) and evaluating from there up to the given row.", commands}
  end

  def answer(%{chain: chain, position: position}, %{"answer" => "n"}),
    do: ask_or_finish(chain, position + 1)

  def answer(state, _params),
    do: {:hold, state, "Answer y (with a value) or n.\n" <> question(state.chain, state.position)}

  # "y <literal>" -> %{"answer"=>"y","value"=>"<literal>"} (value may itself
  # contain spaces, e.g. "y %{a: 1, b: 2}"); anything else is passed
  # through verbatim as "answer" and left for answer/2's own catch-all
  # (re-asks) to handle.
  @impl true
  def parse_answer(line) do
    case line |> String.trim() |> String.split(" ", parts: 2) do
      ["y", value] -> %{"answer" => "y", "value" => value}
      [other] -> %{"answer" => other}
    end
  end

  # position >= length(chain) - 1 means either the chain is down to just
  # the target itself (nothing left to ask about) or every dependency has
  # already been declined -- both end the negotiation the same way, doing
  # nothing (see moduledoc's "deliberately does not fall back" note).
  defp ask_or_finish(chain, position) when position >= length(chain) - 1,
    do: {:done, "No upstream dependency is left. Nothing is run.", []}

  defp ask_or_finish(chain, position),
    do: {:hold, %{chain: chain, position: position}, question(chain, position)}

  defp question(chain, position) do
    current = Enum.at(chain, position)
    ";; w#{position + 1} #{current["label"]}\nSupply a value for #{current["id"]} and evaluate? (y/n)"
  end
end
