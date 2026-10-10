ExUnit.start()

Code.require_file(Path.expand("../lib/help.exs", __DIR__))

defmodule HelpTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Help, Methods}

  # tezcatl's dictionary stores a yanked line as word (before the first
  # ":") and note (the rest), and never parses anything else
  defp word(line), do: line |> String.split(":", parts: 2) |> hd()

  test "every line is one command: `<command>: <text>`, the command without a colon" do
    for where <- [:cli, :window], line <- Help.lines(where) do
      assert [name, note] = String.split(line, ": ", parts: 2), "not `word: note`: #{inspect(line)}"
      assert name == word(line)
      assert String.trim(name) == name and name != ""
      assert String.trim(note) != ""
      refute String.contains?(line, "\n")
    end
  end

  test "no command is listed twice" do
    for where <- [:cli, :window] do
      words = Enum.map(Help.lines(where), &word/1)
      assert words == Enum.uniq(words)
    end
  end

  test "every implemented method is listed with a summary, none of the unimplemented ones" do
    words = Help.lines(:cli) |> Enum.map(&word/1) |> MapSet.new()

    for {name, spec} <- Methods.all(), name != "eval" do
      if spec.route == :not_implemented do
        refute name in words
      else
        assert name in words
        assert is_binary(spec.summary) and spec.summary != "", "#{name} has no summary"
      end
    end
  end

  test "the window lists only what it runs: no command that needs a terminal" do
    window = Help.lines(:window) |> Enum.map(&word/1)
    cli = Help.lines(:cli) |> Enum.map(&word/1)

    assert Enum.all?(window, &(&1 in cli))
    for name <- Help.cli_only_commands(), do: refute(name in window)
    assert "scan" in window and "row/add" in window and "help" in window
    assert "choice project" in cli and "start" in cli
  end

  test "`help <command>` gives a command's usage and a method's params" do
    assert {:ok, "xipe eval " <> _} = Help.detail("eval", :cli)
    assert {:ok, "eval " <> _} = Help.detail("eval", :window)
    assert {:ok, "row/add node=<node id> args=[...]\nmake a calc row  (write)\n"} = Help.detail("row/add", :cli)
    assert {:ok, text} = Help.detail("start", :window)
    assert text =~ "a terminal command, run as xipe start"
    assert {:ok, "trace/get: not implemented\n"} = Help.detail("trace/get", :cli)
    assert :error = Help.detail("nope", :cli)
  end
end
