defmodule XipeTotec.OutcomeText do
  @moduledoc """
  A command list's outcomes (`Runner.run/4`'s) as the lines a person reads
  (2026-09-27, moved out of `main.exs`): the CLI prints them, and the
  dialogue window (`input`) sends the same lines as `dialogue.text`, so a
  command reads the same in a terminal and in tezcatl.

  Each line is tagged `:out` or `:err` -- the CLI sends an error line to
  stderr, the window just shows it.
  """

  @type line :: {:out | :err, String.t()}

  @doc "Every outcome's lines, then one `xipe: N command(s), M ok` line."
  @spec lines([map()]) :: [line()]
  def lines(outcomes) do
    Enum.flat_map(outcomes, &outcome/1) ++
      [{:out, "xipe: #{length(outcomes)} command(s), #{Enum.count(outcomes, & &1.ok?)} ok"}]
  end

  @doc "`lines/1` as one text (both streams), newline-terminated."
  @spec text([map()]) :: String.t()
  def text(outcomes), do: Enum.map_join(lines(outcomes), "", fn {_stream, line} -> line <> "\n" end)

  # "eval" and the pipelines.json methods ending in it (eval/run, row/update)
  defp outcome(%{method: method, ok?: true, result: %{"results" => results} = result}) do
    head = if method != "eval", do: [{:out, "#{method}  ok#{if result["id"], do: "  id=#{result["id"]}", else: ""}"}], else: []
    env = if status = result["env"], do: env_lines("  eval", status, false), else: []
    calls = for r <- results, do: {:out, "  eval call #{r.call_id}  #{eval_call(r.outcome)}  compare=#{r.compare}"}
    not_run = for n <- Map.get(result, "not_run", []), do: {:out, "  eval call #{n["id"]}  not run  #{n["reason"]}"}
    head ++ env ++ calls ++ not_run
  end

  defp outcome(%{method: method, ok?: true, result: result}), do: [{:out, "#{method}  ok  #{inspect(result)}"}]

  defp outcome(%{method: method, ok?: false, error: error}),
    do: [{:err, "#{method}  error  #{error["code"]}: #{error["message"]}"}]

  @doc """
  A project environment's status (`ProjectEnv`) under `prefix`: a stale or
  failed environment always (an error line), any other but `none` only
  with `verbose`.
  """
  @spec env_lines(String.t(), map(), boolean()) :: [line()]
  def env_lines(prefix, %{"state" => state} = status, verbose \\ false) do
    cond do
      state in ["stale", "error"] -> [{:err, "#{prefix}: env #{state} (#{status["source"]}): #{status["message"]}"}]
      verbose and state != "none" -> [{:out, "#{prefix}: env #{state} (#{status["source"]})"}]
      true -> []
    end
  end

  defp eval_call({:ok, %{repr: repr, display: display}}), do: "ok       repr=#{repr}  #{display}"
  defp eval_call(:timeout), do: "timeout"
  defp eval_call(:max_heap), do: "max_heap"
  defp eval_call({:error, reason}), do: "crash    #{reason}"

  defp eval_call({:skipped, upstream_id}),
    do: "skipped  upstream #{upstream_id} has no value to pass on -- evaluate it in the same command (not recorded)"

  defp eval_call(:aborted), do: "aborted  session ended before this call ran"
end
