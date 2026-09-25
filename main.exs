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
Code.require_file("lib/info.exs", __DIR__)
Code.require_file("lib/workspace.exs", __DIR__)
Code.require_file("lib/command_line.exs", __DIR__)
Code.require_file("lib/session.exs", __DIR__)

defmodule XipeTotec.CLI do
  @moduledoc false

  alias XipeTotec.{Book, CommandLine, Core, Info, InOut, Runner, Session, Store, Workspace}
  alias XipeTotec.Serve.Project, as: ServeProject

  @default_serve_port 4200
  @all_tables [:sheets, :nodes, :calls, :links, :runs, :providers]
  @read_only_methods ~w(card/get card/search graph/neighbors graph/export cell/resolve row/depends)

  def main(args) do
    case args do
      [] -> help()
      ["help"] -> help()
      ["version"] -> IO.puts("xipe 0.1.0-dev")
      ["choice", "project", path] -> choice_project(path)
      ["table", "generate" | rest] -> table_generate(rest)
      ["scan", dir] -> scan(dir)
      ["scan"] -> scan(nil)
      ["show", dir] -> show(dir)
      ["show"] -> show(nil)
      ["start" | rest] -> start(rest)
      # spec §15's name for the same server; kept as an alias of `start`
      ["serve" | rest] -> start(rest)
      ["eval" | rest] -> eval(rest)
      ["do" | rest] -> do_cmd(rest)
      ["dialogue", "depends" | rest] -> dialogue_depends(rest)
      ["refresh" | rest] -> refresh(rest)
      [cmd | _] -> unknown(cmd)
    end
  end

  defp help do
    IO.puts("""
    xipe -- Xipe Totec CLI (scaffold; most of §15 is not implemented yet)

    Every command below that takes an optional <dir> acts on the selected project
    (`xipe choice project`) when <dir> is omitted; a given <dir> must already be
    registered. Each project's book lives in tables/project/<id>_<name>/book.jsonl.

      xipe choice project <path>
                                register <path> if new (generating its surface table) and make
                                it the selected project (info.json's "project")
      xipe table generate [<path>]
                                regenerate <path>'s surface table (registering it if new) and save
                                it to tables/project/<id>_<name>/table
      xipe scan [<dir>]        scan the project's .ex/.exs files and update its book
      xipe show [<dir>]        print a summary of the project's book
      xipe start [<dir>] [--port N] [--lsp <url>] [--fs-root <dir>]
                                run the §16.1 WebSocket (localhost) server over the project's book
                                (default port #{@default_serve_port}, or $XIPE_TOTEC_PORT) and record it
                                as the running session (tables/session.json): while it runs, every
                                other command without a <dir> acts on its project instead of the
                                selected one. An unregistered <dir> is registered (the selection is
                                left alone). --lsp is tezcatl's /lsp relay URL and --fs-root the
                                directory tezcatl's paths are relative to; both are optional
                                ($XIPE_TOTEC_LSP_RELAY / $XIPE_TOTEC_LSP_FS_ROOT, else derived from
                                the TEZCATL_RELAY_PORT / TEZCATL_FS_ROOT a tezcatl-spawned xipe
                                inherits) -- tezcatl itself passes only --port
      xipe serve ...           same as xipe start (spec §15's name)
      xipe eval [<dir>] [id...] [--mix] [--include-writes]
                                launch <dir>'s REPL and (re)evaluate the given calc-row ids
                                (default: every call in the book); persists results back
                                and prints an outcome line per call. --mix launches via `iex -S
                                mix` instead of the default scripts-mode (`iex`, loading every
                                scanned .ex/.exs file via -r). --include-writes also
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
                                       -- effect/set id=n1 effect=pure \\
                                       -- eval call_ids=$0.id
                                Values: [..] is always a list ([] empty, [10] one element,
                                [1,2] two); any other value containing a comma is a list too
                                (args=1,2); everything else stays a plain string
      xipe dialogue depends [<dir>] <call_id>
                                §16.4 interactive dependency-chain negotiation: walks <call_id>'s
                                upstream ⟦id⟧ chain deepest-first, asking at each step whether to
                                hand-supply that step's value (skipping real evaluation for it and
                                everything deeper) and run everything from there up through
                                <call_id> for real. At a prompt, answer "y <literal>" (target-
                                language source text) or "n"; declining every step does nothing.
      xipe refresh -l|-r|-a     re-scan xipe_totec's own adapter modules and update ./info.json:
                                -l (--languages) lib/repl/language/*.exs (names + extensions), -r (--repls)
                                lib/repl/eval/scan/<transport>/*.exs, -a (--all) both. A file being
                                present is not proof it works (§24) -- this only records what's
                                there, run it after adding/removing an adapter module yourself.
      xipe version              show version
      xipe help                 show this message
    """)
  end

  defp choice_project(path) do
    unless File.dir?(path), do: usage_error("xipe choice project: #{path} is not a directory")
    {project, status} = Workspace.choose(path)
    IO.puts("xipe choice project: #{project.id}  #{project.path}  (#{status})")
  end

  defp table_generate(args) do
    path =
      case args do
        [p] -> p
        [] -> project!(nil).path
        _ -> usage_error("xipe table generate: usage: xipe table generate [<path>]")
      end

    unless File.dir?(path), do: usage_error("xipe table generate: #{path} is not a directory")
    {project, rows} = Workspace.generate_table(path)
    counts = rows |> Enum.frequencies_by(&(&1["language"] || "-")) |> Enum.sort() |> Enum.map_join("  ", fn {l, n} -> "#{l}=#{n}" end)
    IO.puts("xipe table generate: #{project.id}  #{project.path}  #{length(rows)} files  #{counts}")
  end

  defp scan(dir), do: run_commands(project!(dir), [%{"method" => "scan/run", "params" => %{}}])

  defp show(dir) do
    project = project!(dir)
    book = Store.load(project.store_file)
    IO.puts("project #{project.id}  #{project.path}")

    for {id, row} <- book.sheets do
      IO.puts("sheet #{id}  #{row.path}")
    end

    for {id, row} <- book.nodes do
      IO.puts("node  #{id}  #{Core.node_label(row)}  effect=#{row.effect}")
    end

    for {_id, row} <- book.links do
      IO.puts("link  #{row.node} --#{row.role}--> #{row.ref}")
    end

    if book == Book.new() do
      IO.puts("(empty -- run `xipe scan` first)")
    end
  end

  # The project a command acts on (XipeTotec.Workspace.resolve/2): the
  # given <dir> if registered, else info.json's selected project. Halts
  # with the resolver's own message otherwise.
  defp project!(dir) do
    case Workspace.resolve(dir) do
      {:ok, project} -> project
      {:error, message} -> usage_error("xipe: #{message}")
    end
  end

  defp start(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [port: :integer, lsp: :string, fs_root: :string])

    case Workspace.session() do
      {:ok, running} ->
        usage_error(
          "xipe start: a session is already running (pid #{running["os_pid"]}, port #{running["port"]}, #{running["root"]})"
        )

      :none ->
        :ok
    end

    # Starting on a <dir> is itself the deliberate "use this project" step,
    # so an unregistered one is registered here (same as `xipe choice
    # project`, surface table included) -- tezcatl starts xipe on a project
    # root it may never have been pointed at before. The stored selection
    # is left alone: the session outranks it only while it runs.
    project =
      case positional do
        [] ->
          project!(nil)

        [dir | _] ->
          unless File.dir?(dir), do: usage_error("xipe start: #{dir} is not a directory")
          {project, _rows} = Workspace.generate_table(dir)
          project
      end

    root = project.path
    store_file = project.store_file
    port = opts[:port] || String.to_integer(System.get_env("XIPE_TOTEC_PORT") || Integer.to_string(@default_serve_port))

    # tezcatl passes only --port: the rest comes from the environment a
    # tezcatl-spawned xipe inherits (TEZCATL_RELAY_PORT/TEZCATL_FS_ROOT,
    # tezcatl's own settings). The relay URL is a guess outside tezcatl --
    # harmless, a scanner that can't reach it falls through to the next
    # provider (spec §11.3).
    lsp =
      opts[:lsp] || System.get_env("XIPE_TOTEC_LSP_RELAY") ||
        "ws://127.0.0.1:#{System.get_env("TEZCATL_RELAY_PORT") || "4100"}/lsp"

    fs_root = opts[:fs_root] || System.get_env("XIPE_TOTEC_LSP_FS_ROOT") || System.get_env("TEZCATL_FS_ROOT")

    {:ok, _} = Application.ensure_all_started(:cowboy)
    {:ok, _} = ServeProject.start_link(%{root: root, store_file: store_file})

    dispatch = :cowboy_router.compile([{:_, [{"/", XipeTotec.Serve.Socket, []}]}])

    case :cowboy.start_clear(
           :xipe_totec_serve,
           %{socket_opts: [{:ip, {127, 0, 0, 1}}, {:port, port}]},
           %{env: %{dispatch: dispatch}}
         ) do
      {:ok, _} ->
        # written only once the port is actually listening; removed on a
        # normal shutdown (SIGTERM -- how tezcatl stops it). A kill -9 or
        # Ctrl-C leaves the file behind, which Session.read/1 then ignores
        # because the pid is gone.
        Session.write(%{"port" => port, "project" => project.id, "root" => root, "lsp" => lsp, "fs_root" => fs_root})
        System.trap_signal(:sigterm, fn -> Session.clear() end)

        IO.puts("xipe start: ws://127.0.0.1:#{port}/  root=#{root}  store=#{store_file}")
        if lsp, do: IO.puts("xipe start: lsp relay #{lsp}  fs_root=#{fs_root || "-"}")
        Process.sleep(:infinity)

      {:error, :eaddrinuse} ->
        IO.puts(:stderr, "xipe start: 127.0.0.1:#{port} は使用中です (--port か $XIPE_TOTEC_PORT で変更可)")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "xipe start: リスナ起動に失敗: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Until CLI writes are routed through a running server (課題.md §2), a CLI
  # command that changes the book of the project a session is serving
  # writes the same book.jsonl behind the server's back: the server keeps
  # its in-memory book and never sees the change. Say so rather than stay
  # silent.
  defp warn_if_session_project(project) do
    case Workspace.session() do
      {:ok, %{"project" => id, "port" => port}} when id == project.id ->
        IO.puts(
          :stderr,
          "xipe: warning: xipe start (port #{port}) is serving this project -- this change goes to book.jsonl directly and the running server won't see it until it restarts"
        )

      _ ->
        :ok
    end
  end

  # Synchronous one-shot, same shape as scan/1 and show/1 (Old.md's own
  # framing: "xipe eval can be scoped the same synchronous one-shot way
  # xipe scan/xipe show already are"). The leading <dir> is optional: a
  # first positional that is an existing directory is <dir>, anything else
  # is already a call id (ULIDs never collide with a real directory name
  # in practice).
  defp eval(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [mix: :boolean, include_writes: :boolean])

    {dir, ids} =
      case positional do
        [first | rest] -> if File.dir?(first), do: {first, rest}, else: {nil, positional}
        [] -> {nil, []}
      end

    project = project!(dir)
    old_book = Store.load(project.store_file)
    target_ids = if ids == [], do: Map.keys(old_book.calls), else: ids

    if target_ids == [] do
      IO.puts("xipe eval: nothing to evaluate (book has no calls -- add some with `xipe do row/add ...` first)")
    else
      # --mix forces Runner's own scripts-vs-mix auto-detection (the
      # language's Repl.Language.launch_opts/2) off in favor of the
      # mix-mode default;
      # otherwise leave :launch_opts unset and let Runner decide from
      # the project's surface table.
      evaluator_opts = if opts[:mix], do: [launch_opts: []], else: []
      # --include-writes (Old.md §16.2/§16.4, 2026-09-21): the dedicated
      # `xipe eval` command's own equivalent of `xipe do ... eval
      # include_writes=true` -- Runner.run_one/4's "eval" case is what
      # actually reads this out of the command's params.
      params = %{"call_ids" => target_ids, "include_writes" => opts[:include_writes] || false}
      command = %{"method" => "eval", "params" => params}
      run_commands(project, [command], Keyword.put(evaluator_opts, :ctx, git_ctx(project.path)))
    end
  end

  # `xipe dialogue depends [<dir>] <call_id>` -- the real §16.4 dependency-
  # chain negotiation (Old.md §19), the first real `Dialogue` program
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
        [id] -> {nil, id}
        _ -> usage_error("xipe dialogue depends: usage: xipe dialogue depends [<dir>] <call_id>")
      end

    project = project!(dir)
    warn_if_session_project(project)
    dir = project.path
    old_book = Store.load(project.store_file)

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

      Store.persist_diff(project.store_file, old_book, new_book, @all_tables)

      case outcome.result do
        %{"outcomes" => outcomes} -> print_outcomes(outcomes)
        _ -> :ok
      end

      unless outcome.ok?, do: System.halt(1)
    end
  end

  # `xipe refresh -l|-r|-a` (Old.md §24): a deliberate registration
  # step, not something every command silently re-derives -- see
  # `XipeTotec.Info`'s own moduledoc for why. Flags are independent
  # (`-a` is just `-l` + `-r` together, not a distinct third code path) so
  # a future `-l`-only or `-r`-only re-run never clobbers the other half.
  defp refresh(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args, strict: [languages: :boolean, repls: :boolean, all: :boolean], aliases: [l: :languages, r: :repls, a: :all])

    do_languages = opts[:languages] || opts[:all] || false
    do_repls = opts[:repls] || opts[:all] || false

    if not do_languages and not do_repls do
      usage_error("xipe refresh: usage: xipe refresh -l|--languages | -r|--repls | -a|--all (at least one)")
    end

    info = Info.load()
    info = if do_languages, do: Info.refresh_languages(info), else: info
    info = if do_repls, do: Info.refresh_repls(info), else: info
    Info.save(info)

    if do_languages, do: IO.puts("xipe refresh: languages = #{inspect(info["languages"])}  extensions = #{inspect(info["extensions"])}")
    if do_repls, do: IO.puts("xipe refresh: repls = #{inspect(info["repls"])}")
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
  defp run_commands(project, commands, evaluator_opts \\ []) do
    unless Enum.all?(commands, &(&1["method"] in @read_only_methods)), do: warn_if_session_project(project)
    old_book = Store.load(project.store_file)
    {new_book, outcomes} = Runner.run(old_book, project.path, commands, evaluator_opts)
    Store.persist_diff(project.store_file, old_book, new_book, @all_tables)
    print_outcomes(outcomes)
    unless Enum.all?(outcomes, & &1.ok?), do: System.halt(1)
  end

  defp print_outcomes(outcomes) do
    Enum.each(outcomes, &print_outcome/1)
    IO.puts("xipe: #{length(outcomes)} command(s), #{Enum.count(outcomes, & &1.ok?)} ok")
  end

  defp print_outcome(%{method: "eval", ok?: true, result: %{"results" => results} = result}) do
    for r <- results, do: IO.puts("  eval call #{r.call_id}  #{format_eval_call_outcome(r.outcome)}  compare=#{r.compare}")
    for n <- Map.get(result, "not_run", []), do: IO.puts("  eval call #{n["id"]}  not run  #{n["reason"]}")
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
  # moduledoc. The argv → command-list parsing itself (value rules
  # included) lives in XipeTotec.CommandLine.
  defp do_cmd(args) do
    {dir, rest} =
      case args do
        ["--dir", d | rest] -> {d, rest}
        rest -> {nil, rest}
      end

    commands = CommandLine.parse(rest)

    if commands == [] do
      IO.puts(:stderr, "xipe do: no command given (xipe help for the syntax)")
      System.halt(1)
    else
      # Same git_ctx/1 `eval/1` passes -- without it, an "eval" step inside
      # `xipe do ...` silently persisted commit/commit_at/dirty as nil
      # instead of the real git provenance the dedicated `xipe eval`
      # command records for the identical underlying operation (2026-09-19
      # review finding).
      project = project!(dir)
      run_commands(project, commands, ctx: git_ctx(project.path))
    end
  end

  # git info for apply_results/3's ctx (Old.md §4.4: "git読み取りは
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
