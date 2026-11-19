ExUnit.start()

Code.require_file(Path.expand("../lib/runner.exs", __DIR__))

# answers every eval write with a canned exact success (runner_test.exs's)
defmodule MapOnlyLanguageTest.EchoSender do
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(handle, text) do
    case Regex.run(~r/XT_BEGIN_([^"\s]+)/, text) do
      [_, call_id] ->
        body = "XT_BEGIN_#{call_id}\nrepr=exact\ntype=integer\ncompare=none\ndisplay=1\nXT_END_#{call_id}\n"
        Kernel.send(handle, {handle, {:data, body}})

      nil ->
        if text == "System.halt()\n", do: Kernel.send(handle, {handle, {:data, "XT_EXIT 0\n"}})
    end

    :ok
  end

  def kill(_handle), do: :ok
  def interrupt(_handle), do: :ok
end

# D-map-only-language: a language declared without a REPL is scanned but
# never evaluated -- row/add refuses its functions, eval leaves its rows
# not_run, and the other languages of the project are untouched
defmodule MapOnlyLanguageTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core, Info, Runner}
  alias MapOnlyLanguageTest.EchoSender

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_map_only_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.js"), "export function f(x) { return x }\n")
    File.write!(Path.join(dir, "lib/b.ex"), "defmodule M do\n  def g(x), do: x\nend\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    info = %{
      "languages" => ["elixir", "javascript"],
      "extensions" => %{"ex" => ["elixir"], "exs" => ["elixir"], "js" => ["javascript"]},
      "language_repls" => %{"elixir" => "iex", "javascript" => nil},
      "build_tools" => %{"elixir" => [], "javascript" => []}
    }

    node = fn module, name, sheet -> %{module: module, name: name, anykey: 1, effect: "pure", effect_source: "user", sheet: sheet} end

    book =
      Book.new()
      |> Core.put_sheet("s1", %{path: "lib/a.js"})
      |> Core.put_sheet("s2", %{path: "lib/b.ex"})
      |> Core.put_node("nj", node.("lib/a", "f", "s1"))
      |> Core.put_node("ne", node.("M", "g", "s2"))

    {:ok, dir: dir, book: book, info: info}
  end

  test "Info.map_only?: a registered language whose REPL is null" do
    info = %{"languages" => ["elixir", "javascript"], "language_repls" => %{"elixir" => "iex", "javascript" => nil}}
    assert Info.map_only?("javascript", info)
    refute Info.map_only?("elixir", info)
    # not registered: not a map-only language, just unknown
    refute Info.map_only?("go", info)
  end

  test "row/add refuses a map-only language's function, with why; another language's is added", %{dir: dir, book: book, info: info} do
    commands = [
      %{"method" => "row/add", "params" => %{"node" => "nj", "args" => ["1"]}},
      %{"method" => "row/add", "params" => %{"node" => "ne", "args" => ["1"]}}
    ]

    {new_book, [js, ex]} = Runner.run(book, dir, commands, info: info)

    refute js.ok?
    assert js.error["code"] == "invalid_params"
    assert js.error["message"] =~ "javascript is a map-only language"
    assert ex.ok?
    assert map_size(new_book.calls) == 1
  end

  test "eval leaves a map-only language's row not_run (made before), and evaluates the rest", %{dir: dir, book: book, info: info} do
    book = book |> Core.add_call("cj", %{node: "nj", args: ["1"]}) |> Core.add_call("ce", %{node: "ne", args: ["1"]})
    command = %{"method" => "eval", "params" => %{}}

    {new_book, [outcome]} = Runner.run(book, dir, [command], info: info, sender: EchoSender, launch_opts: [])

    assert outcome.ok?
    assert [%{"id" => "cj", "reason" => reason}] = outcome.result["not_run"]
    assert reason =~ "javascript is a map-only language"
    assert Enum.map(outcome.result["results"], & &1.call_id) == ["ce"]
    assert Book.get(new_book, :calls, "cj").eval_count == 0
  end
end
