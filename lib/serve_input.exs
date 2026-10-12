Code.require_file("serve_project.exs", __DIR__)
Code.require_file("input.exs", __DIR__)
Code.require_file("outcome_text.exs", __DIR__)
Code.require_file("show.exs", __DIR__)
Code.require_file("dialogue.exs", __DIR__)
Code.require_file("protocol.exs", __DIR__)
Code.require_file("methods.exs", __DIR__)
Code.require_file("runner.exs", __DIR__)

defmodule XipeTotec.Serve.Input do
  @moduledoc """
  The `input` method: one line typed into tezcatl's dialogue
  window, `{"text": <line>}`. tezcatl sends every line this way and never
  interprets it; what the line means is decided
  here, the way emacs-vent's `kind:"input"` leaves it to Emacs.

    * a dialogue is held on this connection -> the line is its answer
      (`Dialogue.answer_params/2`, e.g. `Dialogue.Depends`'s `y <value>`/`n`)
    * otherwise the line is read as the CLI reads it (`XipeTotec.Input`)

  The reply is `Serve.Socket`'s usual envelope with the human-facing text
  in `dialogue.text` -- the same lines the CLI prints (`OutcomeText`,
  `Help`, `Show`) -- and, for commands, `result.outcomes` (per command:
  `method`, `ok`, `result`, `error`, in wire form). A line that can't be
  read is an `input_error`.

  ## A command list runs like the CLI's

  The commands of one line run in order, each through `Serve.Project` as
  an ordinary request, with `$<n>.<path>` references resolved from the
  earlier ones' results (`Runner.substitute_command/2`). An evaluation
  (`eval`, `eval/run`, `row/update`) goes to the server's pass queue as
  any client's would, and this line waits for that pass to end before
  going on -- so `... -- eval ... -- row/check` sees the evaluated values,
  as in a terminal. Like `Runner.run/4` a failed command doesn't stop the
  rest.

  Because of that wait, a command list runs in a process of its own
  (`start/3` returns `{:later, ref}`): the connection keeps answering other
  frames meanwhile, and the reply comes as
  `{:xipe_input_done, ref, dialogue, outcome}` to the caller. Everything
  else (help, show, a dialogue answer, a line that can't be read) is
  answered at once (`{:now, dialogue, outcome}`).

  A command that starts a dialogue (a method registered as a dialogue
  program) ends the line there: its question is the reply and the
  dialogue is held for the next `input`. One that finishes at once with
  commands of its own (`dialogue do` given everything on its line) has them
  run next, in its place, and what it said comes first in the reply.
  """

  alias XipeTotec.{Dialogue, Input, Methods, OutcomeText, Protocol, Runner, Show}
  alias XipeTotec.Serve.Project

  @type outcome :: XipeTotec.InOut.outcome()

  @doc """
  Handles one line for a connection holding `dialogue`. `project` is the
  `Serve.Project` server (its registered name by default).

  `{:now, dialogue, outcome}` is the reply and the connection's dialogue
  from now on. `{:later, ref, dialogue}`: the dialogue is `dialogue` from
  now on, and the reply comes as `{:xipe_input_done, ref, change, outcome}`
  -- `change` is `:keep` or `{:set, dialogue}` (a line that started or
  ended a dialogue while it ran).
  """
  @spec start(String.t(), XipeTotec.InOut.dialogue(), GenServer.server()) ::
          {:now, XipeTotec.InOut.dialogue(), outcome()} | {:later, reference(), XipeTotec.InOut.dialogue()}
  def start(line, dialogue, project \\ Project)

  # held: the line is the dialogue's (its answer, or `quit dialogue`); a
  # turn may leave a line or commands for us to run (InOut's `:run`)
  def start(line, {mod, _state} = dialogue, project) do
    %{"method" => method, "params" => params} = Dialogue.line_request(mod, line)
    {dialogue, outcome} = Project.request_dialogue(project, dialogue, method, params, defer_commands: true)
    outcome = from_dialogue(outcome)

    case Map.get(outcome, :run) do
      nil ->
        {:now, dialogue, outcome}

      {:line, line} ->
        case Input.parse(line) do
          {:commands, commands} -> later(dialogue, fn -> after_text(outcome, dialogue, run(commands, project)) end)
          other -> {:now, dialogue, %{ok(show_text(other, project), %{}, false) | hold: dialogue != nil}}
        end

      {:commands, commands} ->
        later(dialogue, fn -> after_text(outcome, dialogue, run(commands, project)) end)
    end
  end

  def start(line, nil, project) do
    case Input.parse(line) do
      {:commands, commands} -> later(nil, fn -> run(commands, project) end)
      {:error, message} -> {:now, nil, failed("input_error", message)}
      other -> {:now, nil, ok(show_text(other, project), %{}, false)}
    end
  end

  # help/version text, or show; a line that can't be read, inside a
  # dialogue, is just said (the dialogue goes on)
  defp show_text({:text, text}, _project), do: text
  defp show_text({:error, message}, _project), do: message <> "\n"

  defp show_text(:show, project) do
    info = Project.info(project)
    Enum.map_join(Show.lines(info["id"], info["root"], Project.book(project)), "", &(&1 <> "\n"))
  end

  # `fun` (-> {dialogue | :keep, outcome}) off this process
  defp later(dialogue, fun) do
    caller = self()
    ref = make_ref()

    spawn(fn ->
      {change, outcome} =
        try do
          case fun.() do
            {:keep, outcome} -> {:keep, outcome}
            {dialogue, outcome} -> {{:set, dialogue}, outcome}
          end
        catch
          kind, reason -> {:keep, failed("input_failed", Exception.format_banner(kind, reason, __STACKTRACE__))}
        end

      send(caller, {:xipe_input_done, ref, change, outcome})
    end)

    {:later, ref, dialogue}
  end

  # the dialogue's own text first, then what its line or commands did; the
  # dialogue is the one held after the turn unless running the line started
  # another
  defp after_text(turn, dialogue, {change, outcome}) do
    dialogue = if change == :keep, do: dialogue, else: change
    text = text_line(turn.text) <> (outcome.text || "")
    {dialogue, %{outcome | text: text, hold: dialogue != nil}}
  end

  # the commands in order, each waiting for the pass it started; a
  # dialogue started on the way ends the line (see moduledoc)
  defp run(commands, project) do
    mon = Process.monitor(GenServer.whereis(project))
    {outcomes, held, said} = run_each(commands, [], project, mon, "")
    Process.demonitor(mon, [:flush])

    via_repl = Enum.any?(outcomes, &Methods.repl?(&1.method))
    result = %{"outcomes" => Enum.map(outcomes, &wire/1)}
    lines = said <> if(outcomes == [], do: "", else: OutcomeText.text(outcomes))

    case held do
      nil -> {:keep, ok(lines, result, via_repl)}
      {dialogue, text} -> {dialogue, %{ok(lines <> text_line(text), result, via_repl) | hold: true}}
    end
  end

  # `said`: the text of dialogues that finished at once on the way
  defp run_each([], done, _project, _mon, said), do: {Enum.reverse(done), nil, said}

  defp run_each([command | rest], done, project, mon, said) do
    %{"method" => method, "params" => params} = Runner.substitute_command(command, Enum.reverse(done))
    {dialogue, out} = Project.request_dialogue(project, nil, method, params, watch: self(), defer_commands: true)

    case {out.hold, Map.get(out, :run)} do
      # a dialogue started here: its question ends the line (a line it
      # asks to run on start is not run -- answer it in the next line)
      {true, _} ->
        {Enum.reverse(done), {dialogue, out.text}, said}

      # a dialogue that finished at once: its commands run here, in its
      # place, like any others (an evaluation through the pass queue)
      {false, {:commands, commands}} ->
        run_each(commands ++ rest, done, project, mon, said <> text_line(out.text))

      # ... or finished with nothing to run: only what it said
      {false, nil} when is_binary(out.text) ->
        run_each(rest, done, project, mon, said <> text_line(out.text))

      {false, _} ->
        outcome = await_pass(%{method: method, ok?: out.ok?, result: out.result, error: out.error}, mon)
        run_each(rest, [outcome | done], project, mon, said)
    end
  end

  # an evaluation's reply is its pass id: wait for the pass and report
  # its results in the command's place (row/update's edited row kept)
  defp await_pass(%{method: method, ok?: true, result: %{"pass_id" => pass_id} = started} = outcome, mon) do
    if Methods.repl?(method) do
      receive do
        {:xipe_pass_done, ^pass_id, %{ok?: true, result: result}} ->
          %{outcome | result: started |> Map.delete("status") |> Map.merge(result)}

        {:xipe_pass_done, ^pass_id, %{error: error}} ->
          %{outcome | ok?: false, result: nil, error: error}

        {:DOWN, ^mon, :process, _pid, reason} ->
          %{outcome | ok?: false, result: nil, error: %{"code" => "server_gone", "message" => inspect(reason)}}
      end
    else
      outcome
    end
  end

  defp await_pass(outcome, _mon), do: outcome

  # a dialogue answer's outcome (InOut's): its text, then the lines of
  # the commands it ran when it finished
  defp from_dialogue(%{result: %{"outcomes" => outcomes}} = outcome) do
    %{outcome | text: text_line(outcome.text) <> OutcomeText.text(outcomes), result: %{"outcomes" => Enum.map(outcomes, &wire/1)}}
  end

  defp from_dialogue(outcome), do: outcome

  defp wire(outcome) do
    %{
      "method" => outcome.method,
      "ok" => outcome.ok?,
      "result" => outcome.result && Protocol.wire_result(outcome.result),
      "error" => outcome.error
    }
  end

  defp failed(code, message),
    do: %{hold: false, via_repl: false, text: nil, ok?: false, result: nil, error: %{"code" => code, "message" => message}}

  defp ok(text, result, via_repl), do: %{hold: false, via_repl: via_repl, text: text, ok?: true, result: result, error: nil}

  defp text_line(nil), do: ""
  defp text_line(text), do: String.trim_trailing(text) <> "\n"
end
