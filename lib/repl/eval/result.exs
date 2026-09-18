defmodule XipeTotec.Repl.Eval.Result do
  @moduledoc """
  Converts a parsed eval-result (from `Scan`/`Scan.Direct.Iex` + a future
  `field_drip`) into the `Evaluator.Result` shape `Core.apply_results/3`
  already expects (prebuild.md §4.4, `core.exs`'s `apply_result/3`).

  Built ahead of `scan.exs`/`field_drip.exs` on purpose (2026-09-18,
  crux's call): its own scope has nothing left undecided, so it doesn't
  need to wait for the rest of the parser pipeline to settle -- only the
  already-verified `eval_template` output shape (repr/type/display/
  bin_base64, prebuild.md §10.5) as its input contract.

  Scope is deliberately narrow: only the two outcomes `eval_template`
  actually produces today (a completed evaluation, or `timeout`/`crash`).
  `Core.apply_result/3` also handles `:max_heap`, `{:skipped, id}`,
  `{:lost, ref}`, `:aborted` -- none of those are built here.
  `{:skipped, _}`/`{:lost, _}`/`:aborted` are pass-level orchestration
  decisions (was an upstream call in this same pass skipped/lost/the
  session restarted?), not something derivable from a single eval's own
  marker output -- that's future orchestrator work, not this module's.
  `:max_heap` is a known gap, not orchestration: `eval_template`'s
  `spawn_monitor` branch can't currently tell a max_heap-triggered kill
  apart from any other crash (both surface as a `:killed`-reason `:DOWN`),
  so every non-timeout failure lands in `error/3`'s "crash" case and maps
  to the generic `{:error, reason}` outcome instead of `:max_heap`
  specifically -- fixing that needs a change in `eval_template`, not here.
  """

  @doc """
  `fields` (from field_drip's success parse): a map with string keys
  `"repr"` (`"exact"` | `"binary"` | `"unsupported"`), `"type"`,
  `"display"`, and optionally `"bin_base64"` (only for `repr: binary`).
  """
  @spec success(String.t(), map(), non_neg_integer()) :: map()
  def success(call_id, fields, session_gen) do
    %{
      call_id: call_id,
      outcome:
        {:ok,
         %{
           repr: repr_atom(fields["repr"]),
           display: fields["display"],
           type: fields["type"],
           bin: decode_bin(fields["bin_base64"])
         }},
      compare: :none,
      evaluated_at: now_iso8601(),
      session_gen: session_gen
    }
  end

  @doc """
  `detail` is the text after `"XT_ERROR_<id> "` in the marker line, as
  `eval_template` writes it: either the literal string `"timeout"`, or
  `"crash <reason>"`.
  """
  @spec error(String.t(), String.t(), non_neg_integer()) :: map()
  def error(call_id, "timeout", session_gen) do
    %{call_id: call_id, outcome: :timeout, compare: :none, evaluated_at: now_iso8601(), session_gen: session_gen}
  end

  def error(call_id, "crash " <> reason, session_gen) do
    %{call_id: call_id, outcome: {:error, reason}, compare: :none, evaluated_at: now_iso8601(), session_gen: session_gen}
  end

  defp repr_atom("exact"), do: :exact
  defp repr_atom("binary"), do: :binary
  defp repr_atom("unsupported"), do: :unsupported

  defp decode_bin(nil), do: nil
  defp decode_bin(b64), do: Base.decode64!(b64)

  # Local capture at conversion time, not the target node's own clock --
  # keeps this module free of any dependency on the target session.
  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
