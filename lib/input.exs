Code.require_file("command_line.exs", __DIR__)
Code.require_file("help.exs", __DIR__)
Code.require_file("methods.exs", __DIR__)

defmodule XipeTotec.Input do
  @moduledoc """
  One line typed into tezcatl's dialogue window (the `input` method,
  `{"text": <line>}`) -- what it means is decided here, never by tezcatl.
  Pure: `parse/1` only says what the line asks for; `Serve.Input` does it.

  A line is written the way the CLI is: what follows `xipe` in a terminal
  (a leading `xipe` is allowed too). Words split on spaces; `'...'` and
  `"..."` keep spaces and are removed, as a shell would, so a line copied
  from a terminal (`'id=$0.id'`) reads the same.

    * `help` / `help <command>` -- `XipeTotec.Help`'s lines (`:window`)
    * `version`
    * `show` -- the running server's book (`XipeTotec.Show`)
    * `scan` -- `scan/run`
    * `eval [id...] [--include-writes]` -- the `"eval"` command
    * `search [<turn>]`, `dialogue depends <call_id>`, `dialogue do
      <method> [key=value...]` -- start those dialogues (`Dialogue.Search`,
      `Dialogue.Depends`, `Dialogue.Do`); `quit dialogue` ends one (said
      here only when none is held)
    * `do <method> [key=value...] [-- <method> ...]` -- a command list
      (`XipeTotec.CommandLine`, the same parsing as `xipe do`)
    * `<method> ...` -- the same without `do`: a first word that names a
      method (any word with a `/`, or one of `XipeTotec.Methods`)
    * without `do`, a step of a `--` list may also be `scan` or `eval
      [id...] [--include-writes]` (`scan -- row/list`, `row/add ... --
      eval`): the window's shorthands, read as above. With `do` the line
      is exactly `xipe do`'s
    * the CLI commands that select or start projects or rewrite
      xipe_totec's own files (`choice project`, `start`, ...) need a
      terminal: an error saying so

  A held dialogue takes the line as its answer before any of this -- that
  is `Serve.Input`'s choice, not a line form.
  """

  alias XipeTotec.{CommandLine, Help, Methods}

  @type parsed ::
          {:text, String.t()}
          | :show
          | {:commands, [map()]}
          | {:error, String.t()}

  @spec parse(String.t()) :: parsed()
  def parse(line) do
    case words(line) do
      {:ok, ["xipe" | rest]} -> command(rest)
      {:ok, words} -> command(words)
      {:error, message} -> {:error, message}
    end
  end

  defp command([]), do: {:error, "an empty line (help lists the commands)"}
  defp command(["help"]), do: {:text, Help.text(:window)}

  defp command(["help" | name]) do
    case Help.detail(Enum.join(name, " "), :window) do
      {:ok, text} -> {:text, text}
      :error -> {:error, "help: no such command: #{Enum.join(name, " ")} (help lists the commands)"}
    end
  end

  defp command(["version"]), do: {:text, Help.version() <> "\n"}
  defp command(["show"]), do: :show
  defp command(["scan"]), do: {:commands, [%{"method" => "scan/run", "params" => %{}}]}
  defp command(["scan", "--" | _] = words), do: command_list(words)
  defp command([cmd, _ | _]) when cmd in ["show", "scan"], do: {:error, "#{cmd}: takes no arguments in the dialogue window (it acts on the open project)"}

  defp command(["eval" | rest] = words) do
    if "--" in rest, do: command_list(words), else: eval_alone(rest)
  end

  defp command(["search" | turn]),
    do: {:commands, [%{"method" => "dialogue/search", "params" => %{"line" => Enum.map_join(turn, " ", &quote_word/1)}}]}

  defp command(["dialogue", "depends", call_id]),
    do: {:commands, [%{"method" => "dialogue/depends", "params" => %{"call_id" => call_id}}]}

  defp command(["dialogue", "depends" | _]), do: {:error, "dialogue depends: in the dialogue window, write dialogue depends <call_id>"}
  # what the line gives is read as `do`'s (key=value); the rest is asked for
  defp command(["dialogue", "do", method | given]) do
    [%{"params" => params}] = CommandLine.parse([method | given])
    {:commands, [%{"method" => "dialogue/do", "params" => %{"method" => method, "given" => params}}]}
  end

  defp command(["dialogue", "do"]), do: {:error, "dialogue do: write dialogue do <method> [key=value...] (help lists the methods)"}
  defp command(["quit", "dialogue"]), do: {:error, "no dialogue is held"}

  defp command(["do", "--dir" | _]), do: {:error, "do: takes no --dir in the dialogue window (it acts on the open project)"}
  defp command(["do"]), do: {:error, "do: no method given (help lists them)"}
  defp command(["do" | rest]), do: {:commands, CommandLine.parse(rest)}

  defp command([first | rest] = words) do
    two = Enum.join([first | Enum.take(rest, 1)], " ")

    cond do
      two in Help.cli_only_commands() -> cli_only(two)
      first in Help.cli_only_commands() or first == "serve" -> cli_only(first)
      method?(first) -> command_list(words)
      true -> {:error, "no such command: #{first} (help lists the commands)"}
    end
  end

  # `eval [id...] [--include-writes]` on its own, as the CLI's `xipe eval`
  defp eval_alone(rest) do
    case OptionParser.parse(rest, strict: [include_writes: :boolean]) do
      {opts, ids, []} ->
        {:commands, [%{"method" => "eval", "params" => %{"call_ids" => ids, "include_writes" => opts[:include_writes] || false}}]}

      {_opts, _ids, invalid} ->
        {:error, "eval: not available in the dialogue window: #{Enum.map_join(invalid, " ", &elem(&1, 0))} (ids and --include-writes only)"}
    end
  end

  defp method?(word), do: String.contains?(word, "/") or Methods.get(word) != nil

  # a `--` list without `do`: each step a method call, or a shorthand that
  # makes sense inside a list (`scan`, `eval [id...]`)
  defp command_list(words) do
    Enum.reduce_while(CommandLine.groups(words), {:commands, []}, fn group, {:commands, done} ->
      case step(group) do
        {:ok, command} -> {:cont, {:commands, done ++ [command]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp step(["scan"]), do: {:ok, %{"method" => "scan/run", "params" => %{}}}
  defp step(["scan" | _]), do: {:error, "scan: takes no arguments (it acts on the open project)"}

  # `eval` as the method (`call_ids=[...]`) or as the shorthand (bare ids,
  # `--include-writes`), mixed freely
  defp step(["eval" | rest]) do
    case OptionParser.parse(rest, strict: [include_writes: :boolean]) do
      {opts, words, []} ->
        {pairs, ids} = Enum.split_with(words, &String.contains?(&1, "="))
        [%{"params" => params}] = CommandLine.parse(["eval" | pairs])
        params = if ids == [], do: params, else: Map.update(params, "call_ids", ids, &(List.wrap(&1) ++ ids))
        params = if opts[:include_writes], do: Map.put(params, "include_writes", true), else: params
        {:ok, %{"method" => "eval", "params" => params}}

      {_opts, _words, invalid} ->
        {:error, "eval: not available in the dialogue window: #{Enum.map_join(invalid, " ", &elem(&1, 0))} (ids and --include-writes only)"}
    end
  end

  defp step([first | _] = group) do
    if method?(first),
      do: {:ok, hd(CommandLine.parse(group))},
      else: {:error, "#{first}: in a command list (--), write a method name, scan or eval (help lists them)"}
  end

  defp quote_word(w), do: if(w == "" or String.match?(w, ~r/\s/), do: "'#{w}'", else: w)

  defp cli_only(name), do: {:error, "#{name} is a terminal command, run as xipe #{name} (not available in the dialogue window)"}

  @doc """
  The line's words: split on whitespace, `'...'`/`"..."` quoted runs kept
  whole (quotes removed; no escapes inside). `{:error, _}` for an
  unclosed quote.
  """
  @spec words(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def words(line), do: words(String.graphemes(line), nil, nil, [])

  # current: the word being built (nil between words); quote: the open quote char
  defp words([], _current, q, _acc) when q != nil, do: {:error, "unclosed quote #{q}"}
  defp words([], nil, nil, acc), do: {:ok, Enum.reverse(acc)}
  defp words([], current, nil, acc), do: {:ok, Enum.reverse([current | acc])}

  defp words([q | rest], current, q, acc), do: words(rest, current, nil, acc)
  defp words([c | rest], current, q, acc) when q != nil, do: words(rest, (current || "") <> c, q, acc)
  defp words([c | rest], current, nil, acc) when c in ["'", "\""], do: words(rest, current || "", c, acc)

  defp words([c | rest], current, nil, acc) do
    if String.trim(c) == "" do
      words(rest, nil, nil, if(current == nil, do: acc, else: [current | acc]))
    else
      words(rest, (current || "") <> c, nil, acc)
    end
  end
end
