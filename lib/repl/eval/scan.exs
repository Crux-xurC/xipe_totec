defmodule XipeTotec.Repl.Eval.Scan do
  @moduledoc """
  Generic (REPL/transport-independent) detection of the fixed eval-result
  marker pair/line for one `call_id`, in a buffer that's already been
  cleaned of REPL/transport-specific noise (heartbeat/exit occurrences,
  any PTY echo/ANSI) by the matching `Scan.<Sender>` module --
  `lib/repl/eval/scan/direct/iex.exs` for an `iex` session reached over
  `Repl.Sender.Direct`'s plain pipe.

  Only ever looks for `call_id`'s own markers -- anything else left in
  the buffer (a foreign call_id's leftovers, stray text) is inert noise
  to this module, never matched.
  """

  @type outcome :: {:success, String.t()} | {:error, String.t()}

  @doc """
  Looks for `call_id`'s `XT_BEGIN_<id>`/`XT_END_<id>` pair or
  `XT_ERROR_<id>` line in `buffer`. Returns:

    * `{:ok, {:success, body}}` -- `body` is the raw text between the
      `XT_BEGIN_<id>` and `XT_END_<id>` lines (field_drip's input)
    * `{:ok, {:error, detail}}` -- `detail` is the text after
      `"XT_ERROR_<id> "` (either `"timeout"` or `"crash <reason>"`,
      `Repl.Eval.Result.error/3`'s input)
    * `:pending` -- neither found yet; caller should keep accumulating
      `:data` chunks and try again
  """
  @spec scan(String.t(), String.t()) :: {:ok, outcome()} | :pending
  def scan(buffer, call_id) do
    begin_marker = "XT_BEGIN_#{call_id}\n"
    end_marker = "\nXT_END_#{call_id}"

    cond do
      String.contains?(buffer, begin_marker) and String.contains?(buffer, end_marker) ->
        [_, after_begin] = String.split(buffer, begin_marker, parts: 2)
        [body, _] = String.split(after_begin, end_marker, parts: 2)
        {:ok, {:success, body}}

      match = Regex.run(~r/XT_ERROR_#{Regex.escape(call_id)} (.*)\n/, buffer) ->
        [_, detail] = match
        {:ok, {:error, detail}}

      true ->
        :pending
    end
  end
end
