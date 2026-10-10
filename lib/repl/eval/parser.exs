Code.require_file("scan.exs", __DIR__)
Code.require_file("result.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.Parser do
  @moduledoc """
  Combines `Scan.<repl>` (per-transport cleanup) + `Scan` (generic
  marker detection) + `FieldDrip.<language>` (per-language body parsing)
  + `Result` (Evaluator.Result conversion) into the one call a caller
  actually wants: "here's more output, is `call_id`'s result in there
  yet?"

  `scan_module` and `field_drip_module` are arguments, so this module is
  the same for every REPL and language.
  """

  alias XipeTotec.Repl.Eval.{Result, Scan}

  @type cleaned :: %{buffer: String.t(), exit_status: String.t() | nil}

  @doc """
  `buffer` is the caller's full accumulated `:data` output so far (the
  caller re-accumulates and re-calls this on every new chunk, same
  buffering style as `Repl.Session`). `scan_module` implements
  `clean/1` (e.g. `Repl.Eval.Scan.Direct.Iex`); `field_drip_module`
  implements the `Repl.Eval.FieldDrip` behaviour for the target language.

  Returns:
    * `{:pending, cleaned}` -- `call_id`'s result hasn't arrived yet.
      `cleaned` still carries this step's `exit_status` (if any) so the
      caller doesn't miss it just because the eval itself isn't done.
    * `{:ok, evaluator_result, cleaned}` -- `call_id`'s result is ready,
      already in `Core.apply_results/3`'s expected shape.
  """
  @spec step(String.t(), String.t(), module(), module(), non_neg_integer()) ::
          {:pending, cleaned()} | {:ok, map(), cleaned()}
  def step(buffer, call_id, scan_module, field_drip_module, session_gen) do
    cleaned = scan_module.clean(buffer)

    case Scan.scan(cleaned.buffer, call_id) do
      :pending ->
        {:pending, cleaned}

      {:ok, {:success, body}} ->
        fields = field_drip_module.parse(body)
        {:ok, Result.success(call_id, fields, session_gen), cleaned}

      {:ok, {:error, detail}} ->
        {:ok, Result.error(call_id, detail, session_gen), cleaned}
    end
  end
end
