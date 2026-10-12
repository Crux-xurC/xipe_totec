Code.require_file("../dialogue.exs", __DIR__)
Code.require_file("../project_config.exs", __DIR__)
Code.require_file("../log_buffer.exs", __DIR__)
Code.require_file("do.exs", __DIR__)

defmodule XipeTotec.Dialogue.Update do
  @moduledoc """
  `dialogue update [<file> [<key>]]`: one of the open project's settings
  changed (`XipeTotec.ProjectConfig`: the time limits `eval.timeout` and
  `eval.boot_timeout`, `env.path`, `env.refresh`). Asked for in turn,
  skipping what the starting line gave: the file, the key, the value.

    * the file -- one of the files xipe_totec named lately
      (`XipeTotec.LogBuffer`: the latest five distinct ones a printed line
      ended its parentheses with, as a pass's limits line does), shown
      numbered and answered by number (or by the path). What was said is
      the only memory the CLI and the server share, so it is what can be
      pointed back at. The open project's own settings file is always
      among them. Not asked when there is only one
    * the key -- every setting is shown with its value, what it may be,
      and whether the project set it or it is the default
    * the value -- checked as it is typed (`ProjectConfig.check/2`); a
      wrong one says why and is asked again

  Only two files can be chosen to any effect: the open project's
  `project.json`, and `defaults.json` its unset keys come from. Choosing
  the defaults does not rewrite them -- they are every project's -- the
  value is written to this project's own file, and that is said. Another
  project's file is refused: open that project first.

  Like `Dialogue.Rewrite`, nothing is written here: with the key and the
  value in hand the dialogue becomes `Dialogue.Do`'s for `config/set`,
  which shows the call and waits for `y`.

  The value is never read from the starting line.
  """

  @behaviour XipeTotec.Dialogue

  alias XipeTotec.Dialogue.Do
  alias XipeTotec.{LogBuffer, ProjectConfig}

  @shown 5

  @impl true
  def start(_params, %{project_dir: nil}),
    do: {:done, "dialogue update: settings are a registered project's, and none is open here", []}

  def start(params, ctx) do
    state = %{files: candidates(ctx), file: nil, key: nil, inner: nil}

    turn =
      case given(params, "file") do
        nil -> ask(state, ctx, [])
        text -> answer(state, %{"text" => text}, ctx)
      end

    # the line's key, taken only once the file is settled
    case {turn, given(params, "key")} do
      {{:hold, %{file: file, key: nil, inner: nil} = state, _question}, key} when file != nil and is_binary(key) ->
        answer(state, %{"text" => key}, ctx)

      _ ->
        turn
    end
  end

  @impl true
  def answer(%{inner: inner} = state, params, ctx) when inner != nil do
    case Do.answer(inner, params, ctx) do
      {:hold, inner, text} -> {:hold, %{state | inner: inner}, text}
      done -> done
    end
  end

  def answer(%{file: nil} = state, %{"text" => line}, ctx) do
    word = String.trim(line)

    chosen =
      case Integer.parse(word) do
        {n, ""} when n >= 1 -> Enum.at(state.files, n - 1)
        _ -> Enum.find(state.files, &(&1 == Path.expand(word)))
      end

    cond do
      chosen == nil -> ask(state, ctx, ["#{word} is not one of them"], true)
      chosen in [own(ctx), ProjectConfig.defaults_file()] -> ask(%{state | file: chosen}, ctx, [])
      true -> ask(state, ctx, ["#{chosen} is another project's: open that project to change it (xipe choice project)"], true)
    end
  end

  def answer(%{key: nil} = state, %{"text" => line}, ctx) do
    key = String.trim(line)

    if key in ProjectConfig.keys(),
      do: ask(%{state | key: key}, ctx, []),
      else: ask(state, ctx, ["no such setting: #{key}"])
  end

  def answer(%{key: key} = state, %{"text" => line}, ctx) do
    value = String.trim(line)

    case ProjectConfig.check(key, value) do
      {:ok, stored} ->
        note = "to be written to #{own(ctx)}"

        case Do.start(%{"method" => "config/set", "given" => %{"key" => key, "value" => to_string(stored)}}, ctx) do
          {:hold, inner, text} -> {:hold, %{state | inner: inner}, note <> "\n" <> text}
          {:done, text, commands} -> {:done, note <> "\n" <> text, commands}
        end

      {:error, message} ->
        ask(state, ctx, [message])
    end
  end

  def answer(state, _params, ctx), do: ask(state, ctx, ["answer in one line"])

  # -- the questions ---------------------------------------------------------------

  # `asked`: the file question is put even when there is only one file (an
  # answer was wrong: it is not passed over)
  defp ask(state, ctx, notes, asked \\ false)

  defp ask(%{file: nil, files: [only]} = state, ctx, notes, false),
    do: ask(%{state | file: only}, ctx, notes ++ ["file: #{only}"])

  defp ask(%{file: nil, files: files} = state, ctx, notes, _asked) do
    listed = files |> Enum.with_index(1) |> Enum.map(fn {file, n} -> "  #{n}  #{file}#{remark(file, ctx)}" end)
    hold(state, notes ++ listed, "file? (1-#{length(files)})")
  end

  defp ask(%{key: nil} = state, ctx, notes, _asked) do
    own = own(ctx)

    # choosing the defaults doesn't rewrite them
    notes =
      if state.file == own,
        do: notes,
        else: notes ++ ["#{state.file} holds the defaults, which are every project's: the change is written to #{own}"]

    settings =
      for {key, value, file} <- ProjectConfig.entries(ctx.project_dir) do
        "  #{key} = #{value}  (#{ProjectConfig.allowed_text(key)})  #{if file == own, do: "set here", else: "default"}"
      end

    hold(state, notes ++ settings, "key?")
  end

  defp ask(%{key: key} = state, _ctx, notes, _asked), do: hold(state, notes, "#{key}? (#{ProjectConfig.allowed_text(key)})")

  defp hold(state, notes, question), do: {:hold, state, Enum.join(notes ++ [question], "\n")}

  # -- the files ---------------------------------------------------------------------

  defp own(ctx), do: ProjectConfig.file(ctx.project_dir)

  # what was named lately, latest first; this project's own file is always
  # there to be chosen (in the last place when nothing named it)
  defp candidates(ctx) do
    own = own(ctx)
    recent = ctx[:log_file] |> LogBuffer.recent_files(@shown) |> Enum.map(&Path.expand/1) |> Enum.uniq()
    if own in recent, do: recent, else: Enum.take(recent, @shown - 1) ++ [own]
  end

  defp remark(file, ctx) do
    cond do
      file == own(ctx) -> "  (this project's settings)"
      file == ProjectConfig.defaults_file() -> "  (the defaults)"
      true -> "  (not this project's)"
    end
  end

  defp given(params, key) do
    case params[key] do
      text when is_binary(text) -> text
      _ -> nil
    end
  end
end
