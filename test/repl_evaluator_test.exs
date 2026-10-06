ExUnit.start()

Code.require_file(Path.expand("../lib/id.exs", __DIR__))
Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/core.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/evaluator.exs", __DIR__))

defmodule ReplEvaluatorTest.EchoSender do
  # Answers every write/2 immediately with a canned exact-repr success for
  # whatever call_id it's asked to evaluate -- lets run_pass/3's real
  # wiring (plan -> launch -> per-entry write/collect -> apply_results) be
  # exercised without a real iex process. `handle` is just the calling
  # process's own pid (send/1 runs synchronously in it) -- messages queued
  # to self() sit in the mailbox until the same process's own `receive`
  # (inside Session.await_ready/Evaluator.wait_result) picks them up.
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(handle, text) do
    cond do
      # eval_template's OWN GENERATED SOURCE TEXT contains the literal
      # `IO.puts("XT_BEGIN_c1")` -- note no whitespace between the id and
      # the closing quote, so `\S+` (stops only at whitespace) over-
      # captures the trailing `")`. Stop at a `"` too.
      match = Regex.run(~r/XT_BEGIN_([^"\s]+)/, text) ->
        [_, call_id] = match
        body = "XT_BEGIN_#{call_id}\nrepr=exact\ntype=integer\ncompare=none\ndisplay=1\nXT_END_#{call_id}\n"
        Kernel.send(handle, {handle, {:data, body}})

      # exit_input (Session.close's graceful write) -- answer with XT_EXIT.
      text == "System.halt()\n" ->
        Kernel.send(handle, {handle, {:data, "XT_EXIT 0\n"}})

      true ->
        :ok
    end

    :ok
  end

  def kill(_handle), do: :ok
  def interrupt(_handle), do: :ok
end

defmodule ReplEvaluatorTest.SilentSender do
  # Boots successfully (so Session.await_ready passes) but never answers a
  # single write/2 -- simulates the session itself wedging solid, the one
  # thing an individual entry's own spawn_monitor/timeout safety wrapper
  # can't catch (moduledoc's "Hang detection" section). `kill/1` records
  # that it was called by messaging the caller back (this all runs
  # synchronously in one process, so the message is already in the test's
  # own mailbox by the time run_pass/3 returns).
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(_handle, _text), do: :ok

  def kill(handle) do
    Kernel.send(handle, :fake_kill_called)
    :ok
  end

  # A no-op, same as write/2 -- this fake's whole premise is that nothing
  # it's asked to do produces any reaction, interrupt/1 included, so
  # end_hung_session/4 always falls through to kill/1 after waiting out
  # interrupt_grace_ms.
  def interrupt(_handle), do: :ok
end

defmodule ReplEvaluatorTest.CalledThenSilentSender do
  # The call returns (XT_CALLED_<id>) and then nothing more: judging the
  # value never finishes -- the case eval/status names (Old.md §51)
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(handle, text) do
    case Regex.run(~r/XT_CALLED_([^"\s]+)/, text) do
      [_, call_id] -> Kernel.send(handle, {handle, {:data, "XT_CALLED_#{call_id}\n"}})
      nil -> :ok
    end

    :ok
  end

  def kill(_handle), do: :ok
  def interrupt(_handle), do: :ok
end

defmodule ReplEvaluatorTest.RefusingSender do
  @behaviour XipeTotec.Repl.Sender
  def send(_message), do: {:error, {:executable_not_found, "nope"}}
  def write(_handle, _text), do: :ok
  def kill(_handle), do: :ok
  def interrupt(_handle), do: :ok
end

# A deliberately non-Elixir "language" -- none of these four modules touch
# anything from lib/repl/{launch,eval_template}.exs or
# lib/repl/eval/{scan/direct/iex,field_drip/elixir}.exs. Exists only to
# prove Evaluator.run_pass/3's :launch_module/:eval_template_module/
# :scan_module/:field_drip_module options genuinely swap out the whole
# adapter set (2026-09-18, crux's review: don't hardcode Elixir into
# Evaluator, follow Parser.step/5's own "caller passes the modules"
# pattern) rather than the defaults just happening to still work.
defmodule ReplEvaluatorTest.ToyLanguage do
  defmodule Launch do
    def build(opts) do
      %{
        "kind" => "repl/launch",
        "argv" => ["true"],
        "env" => %{},
        "cwd" => Keyword.fetch!(opts, :cwd),
        "files" => [],
        "ready_pattern" => "TOY_READY",
        "exit_input" => "bye\n"
      }
    end
  end

  defmodule EvalTemplate do
    def build(entry), do: "TOY_EVAL #{entry.call_id}\n"
  end

  defmodule Scan do
    def clean(buffer), do: %{buffer: buffer, exit_status: nil}
  end

  defmodule FieldDrip do
    @behaviour XipeTotec.Repl.Eval.FieldDrip
    # not the real repl-adapter-guide.md key=value body format on purpose --
    # this only needs to prove Evaluator hands the module it's given
    # whatever's between the markers, not that FieldDrip's own wire
    # contract is followed (that's field_drip_elixir_test.exs's job)
    @impl true
    def parse(body), do: %{"repr" => "exact", "type" => "toy", "display" => body, "compare" => "none"}
  end

  defmodule Sender do
    @behaviour XipeTotec.Repl.Sender

    @impl true
    def send(message) do
      handle = self()
      Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
      {:ok, handle}
    end

    @impl true
    def write(handle, "TOY_EVAL " <> call_id) do
      call_id = String.trim(call_id)
      Kernel.send(handle, {handle, {:data, "XT_BEGIN_#{call_id}\nHELLO\nXT_END_#{call_id}\n"}})
      :ok
    end

    def write(handle, "bye\n") do
      Kernel.send(handle, {handle, {:data, "XT_EXIT 0\n"}})
      :ok
    end

    def write(_handle, _text), do: :ok

    @impl true
    def kill(_handle), do: :ok

    @impl true
    def interrupt(_handle), do: :ok
  end
end

defmodule ReplEvaluatorTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.Evaluator
  alias ReplEvaluatorTest.{EchoSender, RefusingSender, SilentSender}

  defp pure_node(name), do: %{module: "M", name: name, anykey: 1, effect: "pure", effect_source: "user"}

  test "an empty plan short-circuits without ever calling the sender" do
    book = Book.new()
    assert {:ok, ^book, []} = Evaluator.run_pass(book, "pass1", cwd: ".", call_ids: [], sender: RefusingSender)
  end

  test "a launch failure is reported without touching the book" do
    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    assert {:error, {:launch_failed, {:executable_not_found, "nope"}}} =
             Evaluator.run_pass(book, "pass1", cwd: ".", call_ids: ["c1"], sender: RefusingSender)
  end

  test "a plan runs end to end through a fake session and apply_results folds the outcomes in" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    assert {:ok, new_book, [result]} =
             Evaluator.run_pass(book, "pass1", cwd: ".", call_ids: ["c1"], sender: EchoSender)

    assert result.call_id == "c1"
    assert result.outcome == {:ok, %{repr: "exact", type: "integer", display: "1", bin: nil}}

    row = Book.get(new_book, :calls, "c1")
    assert row.result == "1"
    assert row.state == "ok"
    assert row.eval_count == 1
    # one pass is one session: its id is the session a row was evaluated in
    assert result.session_gen == "pass1"
    assert row.session == "pass1"
  end

  test "a session that never answers is treated as hung: killed, the stuck entry errors, the rest abort" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      |> Core.add_call("c2", %{node: "n1", args: ["2"]})

    assert {:ok, new_book, [r1, r2]} =
             Evaluator.run_pass(book, "pass1",
               cwd: ".",
               call_ids: ["c1", "c2"],
               sender: SilentSender,
               # a real entry's timeout defaults to 5s (core.exs's
               # build_entry/3, not caller-overridable) -- hang_grace_ms/
               # interrupt_grace_ms let this test exercise the hang +
               # interrupt-then-kill path without waiting out either
               # timeout for real
               hang_grace_ms: 30,
               interrupt_grace_ms: 10,
               launch_opts: [ready_pattern: "READY"]
             )

    assert r1.call_id == "c1"
    assert r1.outcome == {:error, "session_hung"}
    assert r2.call_id == "c2"
    assert r2.outcome == :aborted

    row1 = Book.get(new_book, :calls, "c1")
    assert row1.state == "eval_error"
    # :aborted is a pure no-op on the book (core.exs's apply_result/3)
    assert Book.get(new_book, :calls, "c2") == Book.get(book, :calls, "c2")

    assert_received :fake_kill_called
  end

  test ":progress hears each entry's phase; a hang after XT_CALLED says the call returned" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      |> Core.add_call("c2", %{node: "n1", args: ["2"]})

    me = self()
    progress = fn id, phase -> Kernel.send(me, {:progress, id, phase}) end

    assert {:ok, _book, [r1, r2]} =
             Evaluator.run_pass(book, "pass1",
               cwd: ".",
               call_ids: ["c1", "c2"],
               sender: ReplEvaluatorTest.CalledThenSilentSender,
               hang_grace_ms: 50,
               interrupt_grace_ms: 10,
               launch_opts: [ready_pattern: "READY"],
               progress: progress
             )

    assert {:error, "session_hung (the call returned; judging its value -- repr, compare -- did not finish)"} = r1.outcome
    assert r2.outcome == :aborted
    assert_received {:progress, "c1", "calling"}
    assert_received {:progress, "c1", "classifying"}
    refute_received {:progress, "c1", "classifying"}
    refute_received {:progress, "c2", _}
  end

  test ":progress on an ordinary pass: calling for each entry, in order" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      |> Core.add_call("c2", %{node: "n1", args: ["2"]})

    me = self()

    assert {:ok, _book, [_, _]} =
             Evaluator.run_pass(book, "pass1",
               cwd: ".",
               call_ids: ["c1", "c2"],
               sender: EchoSender,
               launch_opts: [ready_pattern: "READY"],
               progress: fn id, phase -> Kernel.send(me, {:progress, id, phase}) end
             )

    assert_received {:progress, "c1", "calling"}
    assert_received {:progress, "c2", "calling"}
  end

  test "swapping all four :*_module opts routes through a non-Elixir adapter set entirely" do
    alias ReplEvaluatorTest.ToyLanguage

    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    assert {:ok, new_book, [result]} =
             Evaluator.run_pass(book, "pass1",
               cwd: ".",
               call_ids: ["c1"],
               sender: ToyLanguage.Sender,
               launch_module: ToyLanguage.Launch,
               eval_template_module: ToyLanguage.EvalTemplate,
               scan_module: ToyLanguage.Scan,
               field_drip_module: ToyLanguage.FieldDrip
             )

    assert result.outcome == {:ok, %{repr: "exact", type: "toy", display: "HELLO", bin: nil}}
    assert Book.get(new_book, :calls, "c1").result == "HELLO"
  end
end
