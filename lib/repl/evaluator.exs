Code.require_file("../core.exs", __DIR__)
Code.require_file("launch.exs", __DIR__)
Code.require_file("sender_direct.exs", __DIR__)
Code.require_file("session.exs", __DIR__)
Code.require_file("eval_template.exs", __DIR__)
Code.require_file("eval/parser.exs", __DIR__)
Code.require_file("eval/scan/direct/iex.exs", __DIR__)
Code.require_file("eval/field_drip/elixir.exs", __DIR__)

defmodule XipeTotec.Repl.Evaluator do
  @moduledoc """
  Runs one evaluation pass: drives a `Core.plan_recalc/3` Plan through one
  launched REPL session, entry by entry (launch -> await_ready ->
  write/collect per entry -> apply_results -> return), and feeds
  `Repl.Eval.Parser`'s output into `Core.apply_results/3`. Synchronous;
  `Serve.Project` runs it in a process of its own.

  One pass is one REPL session, launched here and closed at the end of the
  pass; nothing carries over to the next. The evaluated functions are
  assumed referentially transparent, so a session only has to last as long
  as the evaluation that needs it. A result's `session_gen` is the pass id,
  recorded as the row's `session`.

  ## Language independence

  The four per-language modules are `run_pass/3` options
  (`:launch_module`/`:eval_template_module`/`:scan_module`/
  `:field_drip_module`), defaulting to the Elixir ones. This module never
  looks at a node or project to pick a language; the caller (`Runner`)
  does.

  ## Hang detection

  Each entry's generated code ends itself within `entry.limits.timeout`
  (its safety wrapper always emits a marker) -- provided the text was
  taken as a complete expression. Two ways that fails:

  1. The session wedges so hard that it stops scheduling (a busy NIF, for
     instance): nothing arrives on `handle` again.
  2. A malformed argument (an unclosed bracket) leaves the call expression
     incomplete. A REPL doesn't error on that; it waits for more input and
     absorbs everything written afterward into the open expression.
     `EvalTemplate.build/1` catches this case before emitting anything
     (`build_syntax_error/3`), but another language's adapter may not.

  So `run_entries/8`/`wait_result/7` enforce a **fixed wall-clock deadline
  computed once when an entry starts waiting** (`entry.limits.timeout +
  <padding>`), not a silence window reset by each chunk: incoming data
  does not push the deadline back.

  When the deadline hits, `end_hung_session/4` tries `Sender.interrupt/1`
  first if `message["interruptible"]` says the REPL may handle SIGINT,
  gives it a short grace window to exit on its own (the `XT_EXIT` marker),
  and calls `Sender.kill/1` either way. The stuck entry is reported as
  `session_hung` and every remaining entry as `:aborted` (a no-op on the
  book in `Core.apply_result/3`).

  ## Stopping a pass

  `:cancelled?` (0-arity, `eval/cancel`) is asked before the session is
  launched, while it boots, before each entry and while an entry's result
  is awaited (every 200 ms at the latest). Once it says yes the
  session's process group is killed (`Sender.kill/1`, as for a hung
  session, without the SIGINT grace) and `run_pass/3` returns
  `{:error, :cancelled}`: nothing of the pass is recorded, not even the
  entries that had finished.
  """

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.Session
  alias XipeTotec.Repl.Eval.Parser

  # Elixir's own adapter set -- the built-in default (mirrors Repl.Launch's
  # own "keeps xipe_totec working standalone with no caller opinion needed"
  # stance), not a hardcoded requirement. See moduledoc's "Language
  # independence" section.
  @default_launch_module XipeTotec.Repl.Launch
  @default_eval_template_module XipeTotec.Repl.EvalTemplate
  @default_scan_module XipeTotec.Repl.Eval.Scan.Direct.Iex
  @default_field_drip_module XipeTotec.Repl.Eval.FieldDrip.Elixir

  @default_deadline_padding_ms 2_000
  @default_boot_timeout_ms 15_000
  @default_interrupt_grace_ms 2_000
  @cancel_poll_ms 200

  @doc """
  Runs one recalc pass end-to-end: `Core.plan_recalc/3` (same `opts` keys:
  `:call_ids`/`:include_writes`), launch a REPL session,
  drive every entry through it in order, `Core.apply_results/3` the
  outcomes. `opts` (beyond `plan_recalc/3`'s own):

    * `:cwd` (required) -- the target project's root
    * `:ctx` -- `%{commit:, commit_at:, dirty:}` for `apply_results/3`
      (default all `nil`s); git reading is the caller's job, not this
      module's (mirrors `core.exs`'s own "GenServer-side shell fetches it"
      note -- this module is that shell's REPL half, not its git half)
    * `:launch_opts` -- extra keyword opts merged into `Repl.Launch.build/1`
      (`:argv`, `:files`, `:env`, ...) -- e.g. scripts-mode
      (`argv: ["iex"], files: [...]`) vs. mix-mode defaults
    * `:sender` -- a `Repl.Sender` implementation (default `Sender.Direct`)
    * `:boot_timeout_ms` (default #{@default_boot_timeout_ms})
    * `:hang_grace_ms` -- override for the "declare the session hung"
      absolute deadline (default: computed per entry as
      `entry.limits.timeout + #{@default_deadline_padding_ms}`, see
      moduledoc). Exposed mainly so a test can exercise the hang path
      without waiting out a real entry's 5s default timeout.
    * `:interrupt_grace_ms` (default #{@default_interrupt_grace_ms}) --
      how long `end_hung_session/3` waits for `Sender.interrupt/1` to
      have actually ended the session (an `XT_EXIT` marker) before
      falling back to `Sender.kill/1` regardless. Same testability reason
      as `:hang_grace_ms`.
    * `:launch_module`/`:eval_template_module`/`:scan_module`/
      `:field_drip_module` -- the per-language adapter set (moduledoc's
      "Language independence" section); default to Elixir's own
      (`Repl.Launch`/`Repl.EvalTemplate`/`Repl.Eval.Scan.Direct.Iex`/
      `Repl.Eval.FieldDrip.Elixir`).
    * `:progress` -- `fn call_id, phase -> ... end`, told `"calling"` when
      an entry is sent and `"classifying"` when the adapter says the call
      returned (an `XT_CALLED_<id>` line, before the repr/compare
      judgment). `Runner` records it for `eval/status` (`XipeTotec.Passes`).
      An entry that hits the deadline after `XT_CALLED` is recorded as
      `session_hung` with that phase named: the call finished, judging its
      value did not.
    * `:cancelled?` -- `fn -> boolean end`, whether the pass was asked to
      stop (moduledoc's "Stopping a pass"). `Runner` passes
      `XipeTotec.Passes`' check; default never.

  `plan.skipped` (rows `Core.plan_recalc/3` left out because a referenced
  row's value couldn't be handed over) is reported first in `results` and
  never written to the book -- nothing was evaluated. An empty
  `plan.entries` short-circuits to `{:ok, book, plan.skipped}` without ever
  launching a session. Returns
  `{:error, {:launch_failed, reason}}` /
  `{:error, {:boot_failed, reason}}` if the session itself never came up --
  the book is untouched in either case (nothing was evaluated, so there's
  nothing for `apply_results/3` to fold in; unlike a mid-pass hang, a
  boot failure has no partial results to report as `:aborted` either).
  `{:error, :cancelled}` when `:cancelled?` said yes (the book untouched).
  """
  @spec run_pass(Book.t(), String.t(), keyword()) :: {:ok, Book.t(), [map()]} | {:error, term()}
  def run_pass(book, pass_id, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    ctx = Keyword.get(opts, :ctx, %{commit: nil, commit_at: nil, dirty: nil})
    sender = Keyword.get(opts, :sender, XipeTotec.Repl.Sender.Direct)
    boot_timeout_ms = Keyword.get(opts, :boot_timeout_ms, @default_boot_timeout_ms)
    hang_grace_ms = Keyword.get(opts, :hang_grace_ms)
    interrupt_grace_ms = Keyword.get(opts, :interrupt_grace_ms, @default_interrupt_grace_ms)
    launch_opts = Keyword.get(opts, :launch_opts, [])
    adapter =
      opts
      |> adapter_from()
      |> Map.put(:progress, Keyword.get(opts, :progress) || fn _call_id, _phase -> :ok end)
      |> Map.put(:cancelled?, Keyword.get(opts, :cancelled?) || fn -> false end)

    plan_opts = Keyword.take(opts, [:call_ids, :include_writes])
    plan = Core.plan_recalc(book, pass_id, plan_opts)

    case plan.entries do
      [] ->
        {:ok, book, plan.skipped}

      entries ->
        case run_plan(book, ctx, entries, pass_id, cwd, sender, adapter, boot_timeout_ms, hang_grace_ms, interrupt_grace_ms, launch_opts) do
          {:ok, new_book, results} -> {:ok, new_book, plan.skipped ++ results}
          error -> error
        end
    end
  end

  # See moduledoc's "Language independence" section -- these four are the
  # only pieces that vary per target language/REPL; everything else in this
  # module (Session, Parser, Sender) stays generic on purpose.
  defp adapter_from(opts) do
    %{
      launch: Keyword.get(opts, :launch_module, @default_launch_module),
      eval_template: Keyword.get(opts, :eval_template_module, @default_eval_template_module),
      scan: Keyword.get(opts, :scan_module, @default_scan_module),
      field_drip: Keyword.get(opts, :field_drip_module, @default_field_drip_module)
    }
  end

  defp run_plan(book, ctx, entries, pass_id, cwd, sender, adapter, boot_timeout_ms, hang_grace_ms, interrupt_grace_ms, launch_opts) do
    if adapter.cancelled?.(),
      do: {:error, :cancelled},
      else: launch_and_run(book, ctx, entries, pass_id, cwd, sender, adapter, boot_timeout_ms, hang_grace_ms, interrupt_grace_ms, launch_opts)
  end

  defp launch_and_run(book, ctx, entries, pass_id, cwd, sender, adapter, boot_timeout_ms, hang_grace_ms, interrupt_grace_ms, launch_opts) do
    message = adapter.launch.build([{:cwd, cwd} | launch_opts])

    case sender.send(message) do
      {:ok, handle} ->
        case Session.await_ready(sender, handle, message, boot_timeout_ms, adapter.cancelled?) do
          :ok ->
            interruptible = Map.get(message, "interruptible", false)
            {status, results} = run_entries(entries, pass_id, handle, sender, adapter, interruptible, hang_grace_ms, interrupt_grace_ms)

            # a hung session was already forced down (run_entries' :hung
            # branch calls end_hung_session/3, which itself always calls
            # sender.kill/1): calling Session.close/4 again here would
            # re-send exit_input / re-wait for XT_EXIT against a handle
            # that -- for a real Sender.Direct -- is racing its own async
            # {:DOWN,...} -> {:stop, :normal} shutdown, so a second
            # `write/2` could hit a dead GenServer (`:noproc`) instead of
            # the intended no-op.
            case status do
              # stopped (eval/cancel): the process group goes at once, and
              # nothing of the pass is kept
              :cancelled ->
                sender.kill(handle)
                {:error, :cancelled}

              _ ->
                if status == :ok, do: Session.close(sender, handle, message["exit_input"])
                {:ok, Core.apply_results(book, ctx, results), results}
            end

          {:error, :cancelled} ->
            sender.kill(handle)
            {:error, :cancelled}

          {:error, reason} ->
            sender.kill(handle)
            {:error, {:boot_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:launch_failed, reason}}
    end
  end

  defp run_entries([], _pass_id, _handle, _sender, _adapter, _interruptible, _hang_grace_ms, _interrupt_grace_ms), do: {:ok, []}

  defp run_entries([entry | rest], pass_id, handle, sender, adapter, interruptible, hang_grace_ms, interrupt_grace_ms) do
    if adapter.cancelled?.(),
      do: {:cancelled, []},
      else: run_entry(entry, rest, pass_id, handle, sender, adapter, interruptible, hang_grace_ms, interrupt_grace_ms)
  end

  defp run_entry(entry, rest, pass_id, handle, sender, adapter, interruptible, hang_grace_ms, interrupt_grace_ms) do
    adapter.progress.(entry.call_id, "calling")
    sender.write(handle, adapter.eval_template.build(entry))
    grace_ms = hang_grace_ms || entry.limits.timeout + @default_deadline_padding_ms
    # a fixed wall-clock deadline, not a per-chunk silence window (see
    # wait_result/7)
    deadline = System.monotonic_time(:millisecond) + grace_ms

    case wait_result(handle, entry.call_id, "", pass_id, adapter, deadline, false) do
      {:ok, result} ->
        {status, rest_results} = run_entries(rest, pass_id, handle, sender, adapter, interruptible, hang_grace_ms, interrupt_grace_ms)
        {status, [result | rest_results]}

      :cancelled ->
        {:cancelled, []}

      {:hung, called?} ->
        end_hung_session(sender, handle, interruptible, interrupt_grace_ms)
        hung = %{call_id: entry.call_id, outcome: {:error, hung_reason(called?)}, compare: "skipped", evaluated_at: nil, session_gen: nil}
        aborted = for e <- rest, do: %{call_id: e.call_id, outcome: :aborted, compare: "skipped", evaluated_at: nil, session_gen: nil}
        {:hung, [hung | aborted]}
    end
  end

  # On a hang, try the gentler Sender.interrupt/1 first when the adapter
  # says this REPL may handle it (the message's "interruptible"), and give
  # it interrupt_grace_ms to exit on its own (the XT_EXIT marker) before
  # the unconditional Sender.kill/1. This never changes the stuck entry's
  # outcome, only how cleanly the process group comes down.
  defp end_hung_session(sender, handle, interruptible, interrupt_grace_ms) do
    if interruptible do
      sender.interrupt(handle)
      deadline = System.monotonic_time(:millisecond) + interrupt_grace_ms
      wait_for_exit(handle, deadline)
    end

    sender.kill(handle)
  end

  defp wait_for_exit(handle, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {^handle, {:data, chunk}} ->
          unless String.contains?(chunk, "XT_EXIT"), do: wait_for_exit(handle, deadline)
      after
        remaining -> :timeout
      end
    end
  end

  # `deadline` is an absolute `System.monotonic_time(:millisecond)` value,
  # fixed once per entry in run_entries/8 and never pushed back by incoming
  # data: a session absorbing input into one open expression keeps
  # producing chunks, and a silence window reset by each chunk would never
  # elapse.
  #
  # `called?`: the adapter already said the call returned (`XT_CALLED_<id>`)
  # -- told to `:progress` once, and named in the hung reason.
  defp wait_result(handle, call_id, buffer, session_gen, adapter, deadline, called?) do
    called? =
      if not called? and String.contains?(buffer, "XT_CALLED_#{call_id}\n") do
        adapter.progress.(call_id, "classifying")
        true
      else
        called?
      end

    case Parser.step(buffer, call_id, adapter.scan, adapter.field_drip, session_gen) do
      {:ok, result, _cleaned} ->
        {:ok, result}

      {:pending, cleaned} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        cond do
          adapter.cancelled?.() ->
            :cancelled

          remaining <= 0 ->
            {:hung, called?}

          true ->
            receive do
              {^handle, {:data, chunk}} ->
                wait_result(handle, call_id, cleaned.buffer <> chunk, session_gen, adapter, deadline, called?)
            after
              # woken to ask `cancelled?` again; the deadline itself is checked above
              min(remaining, @cancel_poll_ms) ->
                wait_result(handle, call_id, cleaned.buffer, session_gen, adapter, deadline, called?)
            end
        end
    end
  end

  # the stored error: which side of the call the deadline caught
  defp hung_reason(false), do: "session_hung"
  defp hung_reason(true), do: "session_hung (the call returned; judging its value -- repr, compare -- did not finish)"
end
