defmodule XipeTotec.OutcomeText do
  @moduledoc """
  A command list's outcomes (`Runner.run/4`'s) as the lines a person
  reads: the CLI prints them, and the
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
    env = env ++ limits_lines(result["limits"])
    calls = for r <- results, do: {:out, "  eval call #{r.call_id}  #{eval_call(r.outcome, r.call_id)}  compare=#{r.compare}"}
    not_run = for n <- Map.get(result, "not_run", []), do: {:out, "  eval call #{n["id"]}  not run  #{n["reason"]}"}
    head ++ env ++ calls ++ not_run
  end

  # what is being evaluated now (XipeTotec.Passes), and a server's queue
  defp outcome(%{method: "eval/status", ok?: true, result: %{"running" => running} = result}) do
    queued = Map.get(result, "queued", [])

    head =
      if running == [] and queued == [],
        do: [{:out, "eval/status  ok  nothing is being evaluated"}],
        else: [{:out, "eval/status  ok"}]

    passes =
      Enum.flat_map(running, fn p ->
        [{:out, "  running  pass #{p["pass_id"]}  #{p["language"]}  #{p["seconds"]}s  #{length(p["call_ids"])} row(s) (not changeable until it ends)"}] ++
          case p["current"] do
            %{"call_id" => id, "label" => label, "phase" => phase, "seconds" => s} ->
              [{:out, "    now  #{id}  #{label}  #{phase}  #{s}s"}]

            _ ->
              [{:out, "    now  (starting the REPL)"}]
          end
      end)

    waiting = for q <- queued, do: {:out, "  queued   pass #{q["pass_id"]}  #{describe_ids(q["call_ids"])}"}
    head ++ passes ++ waiting
  end

  # the tables there are to look into (XipeTotec.Tables), one line each
  defp outcome(%{method: "roster", ok?: true, result: %{"tables" => tables}}) do
    [{:out, "roster  ok"}] ++
      for t <- tables do
        rewritable = t |> Map.get("writes", %{}) |> Map.keys() |> Enum.sort()
        tail = if rewritable == [], do: "", else: "  rewritable: #{Enum.join(rewritable, " ")}"
        {:out, "  #{t["flag"]}  #{t["name"]}  #{t["summary"]}  columns: #{Enum.join(t["columns"], " ")}#{tail}"}
      end
  end

  defp outcome(%{method: "config/set", ok?: true, result: %{"key" => key, "value" => value, "file" => file}}),
    do: [{:out, "config/set  ok  #{key}=#{value} (#{key}, #{file})"}]

  defp outcome(%{method: "eval/cancel", ok?: true, result: %{"pass_id" => id, "status" => "dequeued"}}),
    do: [{:out, "eval/cancel  ok  pass #{id} taken out of the queue"}]

  defp outcome(%{method: "eval/cancel", ok?: true, result: %{"pass_id" => id}}),
    do: [{:out, "eval/cancel  ok  pass #{id} is being stopped (nothing of it is recorded)"}]

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

  # the time limits a pass ran under, once per pass, each with the setting
  # and the file it came from last in parentheses (XipeTotec.LogBuffer reads
  # that back: `dialogue update` offers the file)
  defp limits_lines(%{"timeout" => row} = limits) do
    boot = if b = limits["boot_timeout"], do: ", #{seconds(b["ms"])} to boot #{source(b)}", else: ""
    [{:out, "  eval: limit #{seconds(row["ms"])} per row #{source(row)}#{boot}"}]
  end

  defp limits_lines(_limits), do: []

  defp source(%{"key" => key, "file" => nil}), do: "(#{key}, built in)"
  defp source(%{"key" => key, "file" => file}), do: "(#{key}, #{file})"

  # 5000 -> "5s", 1500 -> "1.5s"
  defp seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp seconds(ms), do: "#{ms / 1000}s"

  defp eval_call({:ok, %{repr: repr, display: display}}, _id), do: "ok       repr=#{repr}  #{display}"
  defp eval_call(:timeout, _id), do: "timeout"
  defp eval_call(:max_heap, _id), do: "max_heap"
  defp eval_call({:error, reason}, _id), do: "crash    #{reason}"

  # not evaluated, not recorded: the upstream value can't be written into
  # the call (never evaluated, or repr binary/unsupported)
  defp eval_call({:skipped, upstream_id}, id),
    do:
      "skipped  upstream #{upstream_id} has no value that can be written into the call -- evaluate it in the same command, " <>
        "or give a value in its place with `dialogue depends #{id}` (not recorded)"

  defp eval_call(:aborted, _id), do: "aborted  session ended before this call ran"

  defp describe_ids(ids) when is_list(ids) and ids != [], do: "#{length(ids)} row(s)"
  defp describe_ids(_ids), do: "every row"
end
