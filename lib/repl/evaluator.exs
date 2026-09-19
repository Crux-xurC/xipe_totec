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
  The orchestration piece prebuild.md's status paragraph (2026-09-18) flags
  as still missing: wires `Repl.Eval.Parser`'s output into
  `Core.apply_results/3`, and drives a whole `Core.plan_recalc/3` Plan
  through one launched REPL session, entry by entry, the same synchronous
  one-shot shape `Project.scan_dir/2` already has (launch -> await_ready ->
  write/collect per entry -> apply_results -> return). Scoped for the CLI's
  `xipe eval` (main.exs) first, per prebuild.md's own note that this can be
  built "thin" ahead of the async, notify/rowChanged-streaming `eval/run`
  §16 server method (still `@not_implemented` in `Dispatch` on purpose --
  that one needs a persistent per-project Evaluator process, pass_id
  tracking across requests, `eval/cancel`, none of which a one-shot CLI
  command needs).

  `Core.plan_recalc/3`'s `restart_session` field is not read here: it exists
  for a *persistent* server-side session that might outlive one pass (should
  the next pass reuse the live session, or force a fresh one?) -- this
  module always launches a brand-new session per `run_pass/3` call, so
  there's never a live one to decide whether to reuse.

  ## Language independence (fixed 2026-09-18, crux's own review)

  This module used to hardcode `alias`es straight to the Elixir adapter
  modules (`Repl.Launch`, `Repl.EvalTemplate`, `Repl.Eval.Scan.Direct.Iex`,
  `Repl.Eval.FieldDrip.Elixir`) -- fine while Elixir was the only language,
  but it broke the "caller picks the concrete module explicitly, no
  internal language-detection switch" idiom `document/repl-adapter-guide.md`
  already establishes for `Repl.Eval.Parser.step/5`'s own `scan_module`/
  `field_drip_module` arguments (its own moduledoc: "the caller already
  knows the language from context"). Those four are now `run_pass/3` options
  (`:launch_module`/`:eval_template_module`/`:scan_module`/
  `:field_drip_module`), defaulting to the Elixir ones so every existing
  caller keeps working unchanged. **This does not add multi-language
  *dispatch*** (something that looks at a node/project and decides which
  language's modules to use) -- there is nothing to dispatch *to* yet, since
  no second language adapter exists. It only removes the hardcoding, so
  that whenever such a dispatcher is eventually built (or a caller that
  already knows the target language, same as `Parser.step/5`'s own caller
  today), it can hand this module a different four-module set without
  editing `Evaluator` itself.

  ## Hang detection (課題.mkd's heartbeat design, now applied post-pivot)

  Each entry's own `EvalTemplate`-generated code is already
  self-terminating within `entry.limits.timeout` (its `spawn_monitor` +
  `receive ... after` safety wrapper always emits a marker) -- **provided
  the generated text actually gets submitted as a complete expression in
  the first place.** Two distinct ways that can fail to happen, both
  found by review (2026-09-18):

  1. The *session itself* wedges solid enough that it stops scheduling
     entirely (a busy NIF hogging the one OS thread running it, for
     instance) -- then not even the heartbeat ticker's `IO.puts` gets to
     run, and nothing at all arrives on `handle` ever again.
  2. A malformed argument (an unclosed bracket, say) makes the *call
     expression itself* fail to parse as a complete Elixir form. A REPL
     doesn't error on this -- it just waits for more input (iex's
     `...(N)>` continuation prompt), silently absorbing everything
     written afterward into the same still-open expression instead of
     treating it as separate statements. The heartbeat ticker is a
     *separate* process and keeps ticking the whole time, so this looks
     identical to "alive and well" from here. `EvalTemplate.build/1` now
     catches this specific case itself before ever emitting text that
     could trigger it (`build_syntax_error/3`), but a hang-detection
     design that only defends against (1) would still wait forever on
     (2) if some future language's adapter doesn't have an equivalent
     guard.

  `run_entries/6`/`wait_result/6` treat total silence (no `:data` chunk of
  ANY kind -- heartbeat, partial marker text, whatever) for longer than
  `entry.limits.timeout + 3 * heartbeat_interval_ms` as a hang -- but,
  since (2) above means heartbeats alone don't prove progress, this is
  enforced as a **fixed wall-clock deadline computed once when an entry
  starts waiting**, not a per-chunk-reset silence window: incoming data
  (heartbeats included) no longer pushes the deadline back, so an entry
  that's absorbing endless input into one open expression still times out
  at the same total ceiling an entirely-silent session would. It kills the
  session and reports the stuck entry as a plain crash plus every
  remaining entry as `:aborted` (Core's `apply_result/3` treats `:aborted`
  as a pure no-op on the book -- same "node down -> abort the rest of the
  pass" shape 課題.mkd D originally
  designed for distributed-node death, now reused for this instead).
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

  @default_heartbeat_interval_ms 5_000
  @default_boot_timeout_ms 15_000

  @doc """
  Runs one recalc pass end-to-end: `Core.plan_recalc/3` (same `opts` keys:
  `:call_ids`/`:changed_node_ids`/`:include_writes`), launch a REPL session,
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
    * `:heartbeat_interval_ms` (default #{@default_heartbeat_interval_ms})
    * `:boot_timeout_ms` (default #{@default_boot_timeout_ms})
    * `:hang_grace_ms` -- override for the "declare the session hung"
      silence window (default: computed per entry as `entry.limits.timeout
      + 3 * heartbeat_interval_ms`, see moduledoc). Exposed mainly so a
      test can exercise the hang path without waiting out a real entry's
      5s default timeout.
    * `:launch_module`/`:eval_template_module`/`:scan_module`/
      `:field_drip_module` -- the per-language adapter set (moduledoc's
      "Language independence" section); default to Elixir's own
      (`Repl.Launch`/`Repl.EvalTemplate`/`Repl.Eval.Scan.Direct.Iex`/
      `Repl.Eval.FieldDrip.Elixir`).

  An empty plan (nothing to do) short-circuits to `{:ok, book, []}` without
  ever launching a session. Returns `{:error, {:launch_failed, reason}}` /
  `{:error, {:boot_failed, reason}}` if the session itself never came up --
  the book is untouched in either case (nothing was evaluated, so there's
  nothing for `apply_results/3` to fold in; unlike a mid-pass hang, a
  boot failure has no partial results to report as `:aborted` either).
  """
  @spec run_pass(Book.t(), String.t(), keyword()) :: {:ok, Book.t(), [map()]} | {:error, term()}
  def run_pass(book, pass_id, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    ctx = Keyword.get(opts, :ctx, %{commit: nil, commit_at: nil, dirty: nil})
    sender = Keyword.get(opts, :sender, XipeTotec.Repl.Sender.Direct)
    hb_ms = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)
    boot_timeout_ms = Keyword.get(opts, :boot_timeout_ms, @default_boot_timeout_ms)
    hang_grace_ms = Keyword.get(opts, :hang_grace_ms)
    launch_opts = Keyword.get(opts, :launch_opts, [])
    adapter = adapter_from(opts)

    plan_opts = Keyword.take(opts, [:call_ids, :changed_node_ids, :include_writes])
    plan = Core.plan_recalc(book, pass_id, plan_opts)

    case plan.entries do
      [] -> {:ok, book, []}
      entries -> run_plan(book, ctx, entries, cwd, sender, adapter, hb_ms, boot_timeout_ms, hang_grace_ms, launch_opts)
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

  defp run_plan(book, ctx, entries, cwd, sender, adapter, hb_ms, boot_timeout_ms, hang_grace_ms, launch_opts) do
    message = adapter.launch.build([{:cwd, cwd}, {:heartbeat_interval_ms, hb_ms} | launch_opts])

    case sender.send(message) do
      {:ok, handle} ->
        case Session.await_ready(handle, message["ready_pattern"], boot_timeout_ms) do
          :ok ->
            sender.write(handle, message["heartbeat_input"])

            {status, results} = run_entries(entries, handle, sender, adapter, hb_ms, hang_grace_ms)

            # a hung session was already forced down (run_entries' :hung
            # branch calls sender.kill/1 itself): calling Session.close/4
            # again here would re-send exit_input / re-wait for XT_EXIT
            # against a handle that -- for a real Sender.Direct -- is
            # racing its own async {:exit_status,...} -> {:stop, :normal}
            # shutdown, so a second `write/2` could hit a dead GenServer
            # (`:noproc`) instead of the intended no-op.
            if status == :ok, do: Session.close(sender, handle, message["exit_input"])

            {:ok, Core.apply_results(book, ctx, results), results}

          {:error, reason} ->
            sender.kill(handle)
            {:error, {:boot_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:launch_failed, reason}}
    end
  end

  defp run_entries([], _handle, _sender, _adapter, _hb_ms, _hang_grace_ms), do: {:ok, []}

  defp run_entries([entry | rest], handle, sender, adapter, hb_ms, hang_grace_ms) do
    sender.write(handle, adapter.eval_template.build(entry))
    grace_ms = hang_grace_ms || entry.limits.timeout + 3 * hb_ms
    # a fixed wall-clock deadline, not a per-chunk silence window -- see
    # wait_result/6's comment for why this changed (2026-09-18 review
    # finding).
    deadline = System.monotonic_time(:millisecond) + grace_ms

    case wait_result(handle, entry.call_id, "", 1, adapter, deadline) do
      {:ok, result} ->
        {status, rest_results} = run_entries(rest, handle, sender, adapter, hb_ms, hang_grace_ms)
        {status, [result | rest_results]}

      :hung ->
        sender.kill(handle)
        hung = %{call_id: entry.call_id, outcome: {:error, "session_hung"}, compare: "skipped", evaluated_at: nil, session_gen: nil}
        aborted = for e <- rest, do: %{call_id: e.call_id, outcome: :aborted, compare: "skipped", evaluated_at: nil, session_gen: nil}
        {:hung, [hung | aborted]}
    end
  end

  # `deadline` is an absolute `System.monotonic_time(:millisecond)` value,
  # fixed once per entry in run_entries/6 -- NOT reset on every received
  # chunk the way it used to be. Review finding, 2026-09-18: an unclosed
  # arg expression (now caught before this ever runs, by
  # `EvalTemplate.build/1`'s own `build_syntax_error/3` path -- but a
  # future language's `eval_template`-equivalent might not always catch
  # every such case, and a session can get stuck for other reasons too)
  # puts iex into its `...(N)>` continuation prompt, silently absorbing
  # everything written afterward into the same still-open expression. The
  # heartbeat ticker is a *separate* process and keeps ticking the whole
  # time regardless, so a per-chunk-reset "silence since the last message"
  # window (the old behavior) never elapses -- this entry would wait
  # forever, heartbeats and all. A fixed deadline computed once and never
  # pushed back by incoming data closes that: no matter how much keeps
  # arriving, this entry gives up at `grace_ms` total, same ceiling as
  # before for the ordinary "truly silent" hang case.
  defp wait_result(handle, call_id, buffer, session_gen, adapter, deadline) do
    case Parser.step(buffer, call_id, adapter.scan, adapter.field_drip, session_gen) do
      {:ok, result, _cleaned} ->
        {:ok, result}

      {:pending, cleaned} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          :hung
        else
          receive do
            {^handle, {:data, chunk}} ->
              wait_result(handle, call_id, cleaned.buffer <> chunk, session_gen, adapter, deadline)
          after
            remaining -> :hung
          end
        end
    end
  end
end
