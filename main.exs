Code.require_file("lib/id.exs", __DIR__)
Code.require_file("lib/book.exs", __DIR__)
Code.require_file("lib/store.exs", __DIR__)
Code.require_file("lib/identity.exs", __DIR__)
Code.require_file("lib/core.exs", __DIR__)
Code.require_file("lib/scanner.exs", __DIR__)
Code.require_file("lib/project.exs", __DIR__)
Code.require_file("lib/address.exs", __DIR__)
Code.require_file("lib/protocol.exs", __DIR__)
Code.require_file("lib/dispatch.exs", __DIR__)
Code.require_file("lib/serve_project.exs", __DIR__)
Code.require_file("lib/serve_socket.exs", __DIR__)
Code.require_file("lib/repl/evaluator.exs", __DIR__)
Code.require_file("lib/runner.exs", __DIR__)
Code.require_file("lib/dialogue.exs", __DIR__)
Code.require_file("lib/in_out.exs", __DIR__)
Code.require_file("lib/dialogue/depends.exs", __DIR__)

defmodule XipeTotec.CLI do
  @moduledoc false

  alias XipeTotec.{Book, Core, InOut, Runner, Store}
  alias XipeTotec.Serve.Project, as: ServeProject

  @store_file "book.jsonl"
  @default_serve_port 4200
  @all_tables [:sheets, :nodes, :calls, :links, :runs, :providers]

  def main(args) do
    case args do
      [] -> help()
      ["help"] -> help()
      ["version"] -> IO.puts("xipe 0.1.0-dev")
      ["scan", dir] -> scan(dir)
      ["scan"] -> scan(".")
      ["show"] -> show()
      ["serve" | rest] -> serve(rest)
      ["eval" | rest] -> eval(rest)
      ["do" | rest] -> do_cmd(rest)
      ["dialogue", "depends" | rest] -> dialogue_depends(rest)
      [cmd | _] -> unknown(cmd)
    end
  end

  defp help do
    IO.puts("""
    xipe -- Xipe Totec CLI (scaffold; most of §15 is not implemented yet)

      xipe scan [<dir>]        scan every .ex/.exs file under <dir> (default: .), update ./#{@store_file}
      xipe show                print a summary of the current book (from ./#{@store_file})
      xipe serve [<dir>] [--port N]
                                §16.1 WebSocket (localhost) entry over <dir>'s ./#{@store_file}
                                (default port #{@default_serve_port}, or $XIPE_TOTEC_PORT)
      xipe eval [<dir>] [id...] [--mix] [--include-writes]
                                launch <dir>'s REPL and (re)evaluate the given calc-row ids
                                (default: every call in ./#{@store_file}); persists results back
                                and prints an outcome line per call. --mix launches via `iex -S
                                mix` instead of the default scripts-mode (`iex`, loading every
                                scanned .ex/.exs file under <dir> via -r). --include-writes also
                                schedules writes/unknown-effect rows (still requires each one's
                                node to have an explicit `effect/set` first)
      xipe do [--dir <dir>] <method> [key=value...] [-- <method> [key=value...]]...
                                run one or more §16.3 Dispatch methods (row/add, effect/set,
                                cell/resolve, graph/neighbors, row/depends, scan/run, ...) or the
                                "eval" pseudo-method (params include_writes=true opts in
                                writes/unknown-effect rows), chained in one command list -- see
                                XipeTotec.Runner's moduledoc. A later command can reference an
                                earlier one's result with "$<index>.<path>", e.g.:
                                  xipe do row/add node=n1 args=1,2 \\
                                       -- effect/set id=$0.id effect=pure \\
                                       -- eval call_ids=$0.id
                                (values containing a comma become a list; everything else stays
                                a plain string)
      xipe dialogue depends [<dir>] <call_id>
                                §16.4 interactive dependency-chain negotiation: walks <call_id>'s
                                upstream ⟦id⟧ chain deepest-first, asking at each step whether to
                                hand-supply that step's value (skipping real evaluation for it and
                                everything deeper) and run everything from there up through
                                <call_id> for real. At a prompt, answer "y <literal>" (target-
                                language source text) or "n"; declining every step does nothing.
      xipe version              show version
      xipe help                 show this message
    """)
  end

  defp scan(dir), do: run_commands(dir, [%{"method" => "scan/run", "params" => %{}}])

  defp show do
    book = Store.load(@store_file)

    for {id, row} <- book.sheets do
      IO.puts("sheet #{id}  #{row.path}")
    end

    for {id, row} <- book.nodes do
      IO.puts("node  #{id}  #{row.module}.#{row.name}/#{row.arity}  effect=#{row.effect}")
    end

    for {_id, row} <- book.links do
      IO.puts("link  #{row.node} --#{row.role}--> #{row.ref}")
    end

    if book == Book.new() do
      IO.puts("(empty -- run `xipe scan` first)")
    end
  end

  defp serve(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [port: :integer])
    root = Path.expand(List.first(positional) || ".")
    store_file = Path.join(root, @store_file)
    port = opts[:port] || String.to_integer(System.get_env("XIPE_TOTEC_PORT") || Integer.to_string(@default_serve_port))

    {:ok, _} = Application.ensure_all_started(:cowboy)
    {:ok, _} = ServeProject.start_link(%{root: root, store_file: store_file})

    dispatch = :cowboy_router.compile([{:_, [{"/", XipeTotec.Serve.Socket, []}]}])

    case :cowboy.start_clear(
           :xipe_totec_serve,
           %{socket_opts: [{:ip, {127, 0, 0, 1}}, {:port, port}]},
           %{env: %{dispatch: dispatch}}
         ) do
      {:ok, _} ->
        IO.puts("xipe serve: ws://127.0.0.1:#{port}/  root=#{root}  store=#{store_file}")
        Process.sleep(:infinity)

      {:error, :eaddrinuse} ->
        IO.puts(:stderr, "xipe serve: 127.0.0.1:#{port} は使用中です (--port か $XIPE_TOTEC_PORT で変更可)")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "xipe serve: リスナ起動に失敗: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Synchronous one-shot, same shape as scan/1 and show/1 (prebuild.md's own
  # framing: "xipe eval can be scoped the same synchronous one-shot way
  # xipe scan/xipe show already are"). Store.load/persist_diff stay relative
  # to CWD, matching scan/show's own convention (unlike serve/1, which joins
  # <dir> in -- eval's <dir> is only where the REPL itself launches/scans
  # from, same role as scan's own <dir> argument).
  defp eval(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [mix: :boolean, include_writes: :boolean])
    dir = List.first(positional) || "."
    ids = Enum.drop(positional, 1)

    old_book = Store.load(@store_file)
    target_ids = if ids == [], do: Map.keys(old_book.calls), else: ids

    if target_ids == [] do
      IO.puts("xipe eval: nothing to evaluate (book has no calls -- add some with `xipe do row/add ...` first)")
    else
      # --mix forces Runner's own scripts-vs-mix auto-detection
      # (default_launch_opts/1) off in favor of the mix-mode default;
      # otherwise leave :launch_opts unset and let Runner decide from
      # whether <dir>/mix.exs exists.
      evaluator_opts = if opts[:mix], do: [launch_opts: []], else: []
      # --include-writes (prebuild.md §16.2/§16.4, 2026-09-21): the dedicated
      # `xipe eval` command's own equivalent of `xipe do ... eval
      # include_writes=true` -- Runner.run_one/4's "eval" case is what
      # actually reads this out of the command's params.
      params = %{"call_ids" => target_ids, "include_writes" => opts[:include_writes] || false}
      command = %{"method" => "eval", "params" => params}
      run_commands(dir, [command], Keyword.put(evaluator_opts, :ctx, git_ctx(dir)))
    end
  end

  # `xipe dialogue depends [<dir>] <call_id>` -- the real §16.4 dependency-
  # chain negotiation (prebuild.md §19), the first real `Dialogue` program
  # to ride on `InOut.run_to_completion/7` (previously only proven by a
  # throwaway toy program, now removed). Resolves <call_id>'s upstream
  # chain via `Core.upstream_chain/2` + `Core.call_label/2` *before*
  # starting the dialogue and hands the fully-resolved chain in as plain
  # params -- `XipeTotec.Dialogue.Depends` itself never touches `book` (see
  # its own moduledoc for why).
  defp dialogue_depends(args) do
    {dir, call_id} =
      case args do
        [d, id] -> {d, id}
        [id] -> {".", id}
        _ -> usage_error("xipe dialogue depends: usage: xipe dialogue depends [<dir>] <call_id>")
      end

    old_book = Store.load(@store_file)

    if Book.get(old_book, :calls, call_id) == nil do
      IO.puts(:stderr, "xipe dialogue depends: unknown call id #{call_id}")
      System.halt(1)
    else
      chain =
        old_book
        |> Core.upstream_chain([call_id])
        |> Enum.map(fn id -> %{"id" => id, "label" => Core.call_label(old_book, id) || id} end)

      programs = %{"dialogue/depends" => XipeTotec.Dialogue.Depends}
      first = %{"method" => "dialogue/depends", "params" => %{"chain" => chain}}

      # "y <literal>" -> %{"answer"=>"y","value"=>"<literal>"} (value may
      # itself contain spaces, e.g. "y %{a: 1, b: 2}"); anything else is
      # passed through verbatim as "answer" and left for
      # Dialogue.Depends.answer/2's own catch-all (re-asks) to handle.
      next_answer = fn ->
        case (IO.gets("> ") || "") |> String.trim() |> String.split(" ", parts: 2) do
          ["y", value] -> %{"answer" => "y", "value" => value}
          [other] -> %{"answer" => other}
        end
      end

      {new_book, outcome} =
        InOut.run_to_completion(old_book, dir, first, [ctx: git_ctx(dir)], programs, next_answer, &IO.puts/1)

      Store.persist_diff(@store_file, old_book, new_book, @all_tables)

      case outcome.result do
        %{"outcomes" => outcomes} -> print_outcomes(outcomes)
        _ -> :ok
      end

      unless outcome.ok?, do: System.halt(1)
    end
  end

  defp usage_error(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  # crux's 2026-09-18 co-design call: split the CLI into an "input" half
  # (argv/subcommand-specific parsing, above) that only ever builds a
  # command list -- a plain `[%{"method" =>, "params" =>}, ...]`, the same
  # shape §16.3's own wire messages use -- and hand it to `Runner.run/4`
  # (the "action" half, shared with a future external front end, crux's
  # target being tezcatl, not yet designed) rather than mutating the book
  # directly here. `scan`/`eval` above are now both one-command lists built
  # this same way; `do_cmd/1` below is the general form for any number of
  # chained commands.
  defp run_commands(dir, commands, evaluator_opts \\ []) do
    old_book = Store.load(@store_file)
    {new_book, outcomes} = Runner.run(old_book, dir, commands, evaluator_opts)
    Store.persist_diff(@store_file, old_book, new_book, @all_tables)
    print_outcomes(outcomes)
    unless Enum.all?(outcomes, & &1.ok?), do: System.halt(1)
  end

  defp print_outcomes(outcomes) do
    Enum.each(outcomes, &print_outcome/1)
    IO.puts("xipe: #{length(outcomes)} command(s), #{Enum.count(outcomes, & &1.ok?)} ok")
  end

  defp print_outcome(%{method: "eval", ok?: true, result: %{"results" => results}}) do
    for r <- results, do: IO.puts("  eval call #{r.call_id}  #{format_eval_call_outcome(r.outcome)}  compare=#{r.compare}")
  end

  defp print_outcome(%{method: method, ok?: true, result: result}), do: IO.puts("#{method}  ok  #{inspect(result)}")

  defp print_outcome(%{method: method, ok?: false, error: error}),
    do: IO.puts(:stderr, "#{method}  error  #{error["code"]}: #{error["message"]}")

  defp format_eval_call_outcome({:ok, %{repr: repr, display: display}}), do: "ok       repr=#{repr}  #{display}"
  defp format_eval_call_outcome(:timeout), do: "timeout"
  defp format_eval_call_outcome(:max_heap), do: "max_heap"
  defp format_eval_call_outcome({:error, reason}), do: "crash    #{reason}"
  defp format_eval_call_outcome({:skipped, upstream_id}), do: "skipped  upstream #{upstream_id} did not evaluate"
  defp format_eval_call_outcome({:lost, ref}), do: "lost     missing binding for #{ref}"
  defp format_eval_call_outcome(:aborted), do: "aborted  session ended before this call ran"

  # `xipe do [--dir <dir>] <method> [key=value...] [-- <method> [key=value...]]...`
  # -- the general "input" front end onto Runner, per XipeTotec.Runner's own
  # moduledoc. Deliberately hand-rolled rather than OptionParser for the
  # `--`-separated command groups: OptionParser's own `--` handling is about
  # ending *its* option parsing, not a repeatable general-purpose separator,
  # and every token after the method name here is a plain `key=value` pair,
  # not a `--flag`.
  defp do_cmd(args) do
    {dir, rest} =
      case args do
        ["--dir", d | rest] -> {d, rest}
        rest -> {".", rest}
      end

    commands = rest |> split_on_dashdash() |> Enum.map(&parse_command_group/1)

    if commands == [] do
      IO.puts(:stderr, "xipe do: no command given (xipe help for the syntax)")
      System.halt(1)
    else
      # Same git_ctx/1 `eval/1` passes -- without it, an "eval" step inside
      # `xipe do ...` silently persisted commit/commit_at/dirty as nil
      # instead of the real git provenance the dedicated `xipe eval`
      # command records for the identical underlying operation (2026-09-19
      # review finding).
      run_commands(dir, commands, ctx: git_ctx(dir))
    end
  end

  defp split_on_dashdash(args) do
    args
    |> Enum.chunk_while(
      [],
      fn
        "--", acc -> {:cont, Enum.reverse(acc), []}
        token, acc -> {:cont, [token | acc]}
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp parse_command_group([method | kvs]), do: %{"method" => method, "params" => Map.new(kvs, &parse_kv/1)}

  defp parse_kv(kv) do
    case String.split(kv, "=", parts: 2) do
      [k, v] -> {k, coerce_value(v)}
      [k] -> {k, ""}
    end
  end

  # a comma-containing value becomes a list (row/add's "args", eval's
  # "call_ids", ...); everything else stays the plain string Dispatch's
  # own params already tolerate (e.g. graph/export's "depth" normalizes a
  # string itself). Not meant to be a general type system -- a value that
  # legitimately needs a literal comma has no escape hatch here.
  defp coerce_value(v), do: if(String.contains?(v, ","), do: String.split(v, ","), else: v)

  # git info for apply_results/3's ctx (prebuild.md §4.4: "git読み取りは
  # GenServer側で行い、ここに渡すだけ" -- reading git is this shell's job,
  # not Core's/Evaluator's). `dir` need not be a git repo at all (or `git`
  # need not be installed) -- every field just stays nil rather than raise,
  # same "don't crash a whole eval over an optional annotation" spirit as
  # Dispatch's own error handling elsewhere.
  defp git_ctx(dir) do
    with {sha, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: dir, stderr_to_stdout: true),
         {commit_at, 0} <- System.cmd("git", ["show", "-s", "--format=%cI", "HEAD"], cd: dir, stderr_to_stdout: true),
         {status, 0} <- System.cmd("git", ["status", "--porcelain"], cd: dir, stderr_to_stdout: true) do
      %{commit: String.trim(sha), commit_at: String.trim(commit_at), dirty: status != ""}
    else
      _ -> %{commit: nil, commit_at: nil, dirty: nil}
    end
  end

  defp unknown(cmd) do
    IO.puts(:stderr, "xipe: unknown command #{inspect(cmd)}")
    System.halt(1)
  end
end

XipeTotec.CLI.main(System.argv())
