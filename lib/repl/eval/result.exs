defmodule XipeTotec.Repl.Eval.Result do
  @moduledoc """
  Converts a parsed eval-result (from `Scan`/`Scan.Direct.Iex` + a future
  `field_drip`) into the `Evaluator.Result` shape `Core.apply_results/3`
  already expects (Old.md §4.4, `core.exs`'s `apply_result/3`).

  Built ahead of `scan.exs`/`field_drip.exs` on purpose (2026-09-18,
  crux's call): its own scope has nothing left undecided, so it doesn't
  need to wait for the rest of the parser pipeline to settle -- only the
  already-verified `eval_template` output shape (repr/type/display/
  compare/bin_base64, Old.md §10.5/§10.11) as its input contract.

  **`repr`/`compare` are passed through as the plain strings
  `eval_template` already prints, never converted to atoms** (fixed
  2026-09-18, wiring review): an earlier version of this module converted
  `repr` to an atom (`:exact`/`:binary`/`:unsupported`) via a private
  `repr_atom/1`. That was a real, previously-undetected bug on two counts
  -- `core.exs`'s own `resolve_ref/4` compares `ref_call.repr in ["exact",
  "binary"]` (string literals), so an atom-valued `repr` stored in the
  book could never match and the "embed a plan-external exact/binary
  value as literal text" path would silently never fire once a real
  Evaluator started feeding it; and Old.md §28 B2's own rule ("Core に入る
  行の値は JSON にそのまま載る型... に限ります") already rules atoms out
  at this exact boundary. `Core.apply_result/3` stores whatever `repr`/
  `compare` it's handed verbatim (`Map.merge`, no conversion), and
  `core_test.exs`'s own fixtures already use plain strings -- so the fix
  is here, not there.
  """

  @doc """
  `fields` (from field_drip's success parse): a map with string keys
  `"repr"` (`"exact"` | `"binary"` | `"unsupported"`), `"type"`,
  `"compare"` (`"none"` | `"skipped"` | `"changed"` | `"same"`,
  Old.md §10.11), `"display"`, and optionally `"bin_base64"` (only
  for `repr: binary`, itself already base64 text -- kept as-is, never
  decoded to raw bytes here: `Store.persist_diff/4` -> `Store.append/2`
  JSON-encodes every column, and arbitrary `:erlang.term_to_binary/1`
  output is not valid JSON text, so the *only* JSON-safe form to carry
  this column in is the base64 string eval_template already produced --
  decoding it back to a term is `EvalTemplate`'s own `reconstruct_snippet`
  job, target-side, not this module's).
  """
  @spec success(String.t(), map(), non_neg_integer()) :: map()
  def success(call_id, fields, session_gen) do
    %{
      call_id: call_id,
      outcome:
        {:ok,
         %{
           repr: fields["repr"],
           display: fields["display"],
           type: fields["type"],
           bin: fields["bin_base64"]
         }},
      compare: fields["compare"] || "none",
      evaluated_at: now_iso8601(),
      session_gen: session_gen
    }
  end

  @doc """
  `detail` is the text after `"XT_ERROR_<id> "` in the marker line, as
  `eval_template` writes it: the literal string `"timeout"`, the literal
  string `"max_heap"` (eval_template distinguishes this from a generic
  crash by checking for the `:killed` `:DOWN` reason -- 2026-09-18, the
  only thing that can send that specific pid that specific reason while
  it's still running its own spawned body is its own
  `Process.flag(:max_heap_size, ...)`), or `"crash <reason>"`.
  """
  @spec error(String.t(), String.t(), non_neg_integer()) :: map()
  def error(call_id, "timeout", session_gen) do
    %{call_id: call_id, outcome: :timeout, compare: "skipped", evaluated_at: now_iso8601(), session_gen: session_gen}
  end

  def error(call_id, "max_heap", session_gen) do
    %{call_id: call_id, outcome: :max_heap, compare: "skipped", evaluated_at: now_iso8601(), session_gen: session_gen}
  end

  def error(call_id, "crash " <> reason, session_gen) do
    %{call_id: call_id, outcome: {:error, reason}, compare: "skipped", evaluated_at: now_iso8601(), session_gen: session_gen}
  end

  # Local capture at conversion time, not the target node's own clock --
  # keeps this module free of any dependency on the target session.
  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
