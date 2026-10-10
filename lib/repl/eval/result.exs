defmodule XipeTotec.Repl.Eval.Result do
  @moduledoc """
  Converts a parsed eval-result (from `Scan` and a `FieldDrip`) into the
  `Evaluator.Result` shape `Core.apply_results/3` expects.

  `repr`/`compare` are passed through as the plain strings `eval_template`
  prints, never converted to atoms: `Core` compares them as strings
  (`repr in ["exact", "binary"]`), and every value stored in a row must be
  JSON-encodable as-is.
  """

  @doc """
  `fields` (from field_drip's success parse): a map with string keys
  `"repr"` (`"exact"` | `"binary"` | `"unsupported"`), `"type"`,
  `"compare"` (`"none"` | `"skipped"` | `"changed"` | `"same"`),
  `"display"`, and optionally `"bin_base64"` (only for `repr: binary`).
  The base64 text is kept as-is, never decoded here: every column is
  JSON-encoded by `Store`, and raw `:erlang.term_to_binary/1` output is not
  valid JSON text. Decoding it back to a term is `EvalTemplate`'s job, on
  the REPL side.
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
  string `"max_heap"` (the entry's process was killed by its own
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
