Code.require_file("lib/id.exs", __DIR__)
Code.require_file("lib/book.exs", __DIR__)
Code.require_file("lib/store.exs", __DIR__)
Code.require_file("lib/identity.exs", __DIR__)
Code.require_file("lib/core.exs", __DIR__)
Code.require_file("lib/scanner.exs", __DIR__)
Code.require_file("lib/project.exs", __DIR__)
Code.require_file("lib/address.exs", __DIR__)
Code.require_file("lib/protocol.exs", __DIR__)
Code.require_file("lib/methods.exs", __DIR__)
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
Code.require_file("lib/git_ctx.exs", __DIR__)
Code.require_file("lib/project_config.exs", __DIR__)
Code.require_file("lib/project_env.exs", __DIR__)
Code.require_file("lib/help.exs", __DIR__)
Code.require_file("lib/outcome_text.exs", __DIR__)
Code.require_file("lib/show.exs", __DIR__)
Code.require_file("lib/log_buffer.exs", __DIR__)

defmodule XipeTotec.CLI do
  @moduledoc false

  alias XipeTotec.{Book, CommandLine, Core, GitCtx, Help, Info, InOut, Methods, OutcomeText, ProjectConfig, ProjectEnv, Runner, Session, Show, Store, SurfaceTable, Workspace}
  alias XipeTotec.Serve.Project, as: ServeProject

  @default_serve_port 4200
  @all_tables [:sheets, :nodes, :calls, :links, :runs, :providers]

  def main(args) do
    # info.json is read all through a command: one that is not readable is
    # said here, once, before anything runs (refresh makes it again)
    unless match?([], args) or match?([c | _] when c in ["help", "version", "refresh"], args) do
      case Info.read() do
        {:ok, _} -> :ok
        {:error, message} -> usage_error("xipe: " <> message)
      end
    end

    case args do
      [] -> help()
      ["help"] -> help()
      ["help" | name] -> help(Enum.join(name, " "))
      ["version"] -> IO.puts(Help.version())
      ["choice", "project", path] -> choice_project(path)
      ["table", "generate" | rest] -> table_generate(rest)
      ["scan", dir] -> scan(dir)
      ["scan"] -> scan(nil)
      ["show", dir] -> show(dir)
      ["show"] -> show(nil)
      ["start" | rest] -> start(rest)
      # an alias of `start`
      ["serve" | rest] -> start(rest)
      ["eval" | rest] -> eval(rest)
      ["do" | rest] -> do_cmd(rest)
      ["dialogue", "depends" | rest] -> dialogue_depends(rest)
      ["dialogue", "do" | rest] -> dialogue_do(rest)
      ["dialogue", "rewrite" | rest] -> dialogue_rewrite(rest)
      ["dialogue", "update" | rest] -> dialogue_update(rest)
      ["search" | rest] -> search(rest)
      ["refresh" | rest] -> refresh(rest)
      ["config" | rest] -> config(rest)
      [cmd | _] -> unknown(cmd)
    end
  end

  # one line per command (XipeTotec.Help, shared with the dialogue
  # window's `help`); `xipe help <command>` for the longer text
  defp help, do: IO.write(Help.text(:cli))

  defp help(name) do
    case Help.detail(name, :cli) do
      {:ok, text} -> IO.write(text)
      :error -> usage_error("xipe help: no command #{inspect(name)} (xipe help for the list)")
    end
  end

  defp choice_project(path) do
    unless File.dir?(path), do: usage_error("xipe choice project: #{path} is not a directory")
    {project, status} = ok_or_halt(Workspace.choose(path), "xipe choice project")
    IO.puts("xipe choice project: #{project.id}  #{project.path}  (#{status})")
    if status == :new, do: resolve_env(project)
  end

  # resolve the project's environment again now (the marker of
  # project_env.json at its root: nix print-dev-env ..., ProjectEnv) --
  # registration and `xipe table generate` are where it is refreshed
  # regardless of env.refresh
  defp resolve_env(project) do
    {_env, status} = ProjectEnv.resolve(project.path, project.dir, force: true)
    print_env_status("xipe", status, true)
  end

  defp print_env_status(prefix, status, verbose), do: print_lines(OutcomeText.env_lines(prefix, status, verbose))

  # printed, and added to the buffer of what was said (LogBuffer): a
  # dialogue can point back at a file a line named
  defp print_lines(lines) do
    for {stream, line} <- lines do
      if stream == :err, do: IO.puts(:stderr, line), else: IO.puts(line)
    end

    XipeTotec.LogBuffer.append(XipeTotec.LogBuffer.default_file(), Enum.map(lines, &elem(&1, 1)))
  end

  # `xipe config [<dir>] [key=value...]`: a project's own settings
  # (ProjectConfig, its project.json). No key=value prints them.
  defp config(args) do
    {dir, pairs} =
      case args do
        [first | rest] -> if String.contains?(first, "="), do: {nil, args}, else: {first, rest}
        [] -> {nil, []}
      end

    project = project!(dir)

    for pair <- pairs do
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          case ProjectConfig.put(project.dir, key, value) do
            :ok -> :ok
            {:error, message} -> usage_error("xipe config: #{message}")
          end

        _ ->
          usage_error("xipe config: expected key=value, got #{inspect(pair)}")
      end
    end

    IO.puts("project #{project.id}  #{project.path}")

    # each with what it may be and the file its value comes from
    print_lines(
      for {key, value, file} <- ProjectConfig.entries(project.dir) do
        {:out, "#{key}=#{value}  (#{ProjectConfig.allowed_text(key)}, #{file || "built in"})"}
      end
    )
  end

  defp table_generate(args) do
    path =
      case args do
        [p] -> p
        # the selected project's own, even when its table is the one to make again
        [] -> ok_or_halt(Workspace.resolve(nil), "xipe table generate") |> elem(1) |> Map.fetch!(:path)
        _ -> usage_error("xipe table generate: usage: xipe table generate [<path>]")
      end

    unless File.dir?(path), do: usage_error("xipe table generate: #{path} is not a directory")
    {project, rows} = ok_or_halt(Workspace.generate_table(path), "xipe table generate")
    counts = rows |> Enum.frequencies_by(&(&1["language"] || "-")) |> Enum.sort() |> Enum.map_join("  ", fn {l, n} -> "#{l}=#{n}" end)
    IO.puts("xipe table generate: #{project.id}  #{project.path}  #{length(rows)} files  #{counts}")

    tools =
      for(r <- rows, r["language"], uniq: true, do: "#{r["language"]}: repl=#{r["repl"] || "-"} build_tool=#{r["build_tool"] || "-"}")

    Enum.each(tools, &IO.puts("xipe table generate: " <> &1))
    resolve_env(project)
  end

  defp scan(dir), do: run_commands(project!(dir), [%{"method" => "scan/run", "params" => %{}}])

  defp show(dir) do
    project = project!(dir)
    Enum.each(Show.lines(project.id, project.path, Store.load(project.store_file)), &IO.puts/1)
  end

  # The project a command acts on (XipeTotec.Workspace.resolve/2): the
  # given <dir> if registered, else the selected project (tables/selection.json). Halts
  # with the resolver's own message otherwise.
  defp project!(dir) do
    case Workspace.resolve(dir) do
      {:ok, project} ->
        # its surface table is read all through a command: one that is not
        # readable is said here (`xipe table generate` makes it again)
        case SurfaceTable.read(project.table_file) do
          {:ok, _} -> project
          {:error, message} -> usage_error("xipe: #{message}")
        end

      {:error, message} ->
        usage_error("xipe: #{message}")
    end
  end

  # a Workspace answer: what it gives, or its message and exit 1
  defp ok_or_halt({:error, message}, who), do: usage_error("#{who}: #{message}")
  defp ok_or_halt(result, _who), do: result

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

    # Without a <dir> (how tezcatl starts it: xipe_totec picks the project,
    # tezcatl is only a window onto it) this is the selected project.
    # Starting on a <dir> by hand is itself the deliberate "use this project"
    # step, so an unregistered one is registered here (same as `xipe choice
    # project`, surface table included). The stored selection is left alone:
    # the session outranks it only while it runs.
    project =
      case positional do
        [] ->
          project!(nil)

        [dir | _] ->
          unless File.dir?(dir), do: usage_error("xipe start: #{dir} is not a directory")
          {project, _rows} = ok_or_halt(Workspace.generate_table(dir), "xipe start")
          project
      end

    root = project.path
    store_file = project.store_file
    port =
      opts[:port] ||
        case Integer.parse(System.get_env("XIPE_TOTEC_PORT") || Integer.to_string(@default_serve_port)) do
          {n, ""} when n in 1..65_535 -> n
          _ -> usage_error("xipe start: XIPE_TOTEC_PORT=#{System.get_env("XIPE_TOTEC_PORT")} is not a port number (1-65535)")
        end

    # tezcatl passes --lsp/--fs-root itself (its XipeConfig.spawn_args/3);
    # otherwise they come from the environment (TEZCATL_RELAY_PORT/
    # TEZCATL_FS_ROOT, tezcatl's own settings). The relay URL is a guess outside tezcatl --
    # harmless, a scanner that can't reach it falls through to the next
    # provider.
    lsp =
      opts[:lsp] || System.get_env("XIPE_TOTEC_LSP_RELAY") ||
        "ws://127.0.0.1:#{System.get_env("TEZCATL_RELAY_PORT") || "4100"}/lsp"

    fs_root = opts[:fs_root] || System.get_env("XIPE_TOTEC_LSP_FS_ROOT") || System.get_env("TEZCATL_FS_ROOT")

    {:ok, _} = Application.ensure_all_started(:cowboy)
    {:ok, _} =
      ServeProject.start_link(%{
        root: root,
        store_file: store_file,
        project_id: project.id,
        project_dir: project.dir,
        log_file: XipeTotec.LogBuffer.default_file()
      })

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
        # the server works without it; only the other xipe commands do not see this session
        with {:error, message} <- Session.write(%{"port" => port, "project" => project.id, "root" => root, "lsp" => lsp, "fs_root" => fs_root}) do
          IO.puts(:stderr, "xipe start: #{message} -- other xipe commands will not know this session runs")
        end
        System.trap_signal(:sigterm, fn -> Session.clear() end)

        IO.puts("xipe start: ws://127.0.0.1:#{port}/  root=#{root}  store=#{store_file}")
        if lsp, do: IO.puts("xipe start: lsp relay #{lsp}  fs_root=#{fs_root || "-"}")
        Process.sleep(:infinity)

      {:error, :eaddrinuse} ->
        IO.puts(:stderr, "xipe start: 127.0.0.1:#{port} is in use (change it with --port or $XIPE_TOTEC_PORT)")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "xipe start: could not start the listener: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Until CLI writes are routed through a running server, a CLI
  # command that changes the book of the project a session is serving
  # writes the same book.jsonl as the server. The server imports CLI writes
  # on its next request, so warn only that this command writes directly.
  defp warn_if_session_project(project) do
    case Workspace.session() do
      {:ok, %{"project" => id, "port" => port}} when id == project.id ->
        IO.puts(
          :stderr,
          "xipe: warning: xipe start (port #{port}) is serving this project -- this command writes to book.jsonl directly; the server imports it on its next request"
        )

      _ ->
        :ok
    end
  end

  # Synchronous one-shot, like scan/1 and show/1. The leading <dir> is
  # optional: a first positional that is an existing directory is <dir>,
  # anything else is a call id.
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
      # language's Repl.Language.launch_opts/3) off in favor of the
      # mix-mode default;
      # otherwise leave :launch_opts unset and let Runner decide from
      # the project's surface table.
      evaluator_opts = if opts[:mix], do: [launch_opts: []], else: []
      # --include-writes: the dedicated
      # `xipe eval` command's own equivalent of `xipe do ... eval
      # include_writes=true` -- Runner.run_one/4's "eval" case is what
      # actually reads this out of the command's params.
      params = %{"call_ids" => target_ids, "include_writes" => opts[:include_writes] || false}
      command = %{"method" => "eval", "params" => params}
      run_commands(project, [command], Keyword.put(evaluator_opts, :ctx, GitCtx.read(project.path)))
    end
  end

  # `xipe dialogue depends [<dir>] <call_id>` -- the dependency-chain
  # negotiation (`XipeTotec.Dialogue.Depends`), driven to its end by
  # `InOut.run_to_completion/7`.
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

      programs = InOut.programs()
      first = %{"method" => "dialogue/depends", "params" => %{"chain" => chain}}

      # the same "y <literal>" / "n" reading the dialogue window's input gets
      next_answer = fn -> XipeTotec.Dialogue.answer_params(XipeTotec.Dialogue.Depends, IO.gets("> ") || "") end

      {new_book, outcome} =
        InOut.run_to_completion(old_book, dir, first, [ctx: GitCtx.read(dir), project_dir: project.dir], programs, next_answer, &IO.puts/1)

      case outcome.result do
        %{"outcomes" => outcomes} -> print_outcomes(outcomes)
        _ -> :ok
      end

      record(project, old_book, new_book, "the results above were not recorded")

      unless outcome.ok?, do: System.halt(1)
    end
  end

  # `xipe search [<turn>]` (Dialogue.Search): a prompt
  # holding the search's list and `x` for as long as it runs -- one process,
  # since a shell's separate `xipe search ...` calls couldn't share them.
  # A turn the search passes on (an ordinary command line, InOut's `:run`)
  # runs here as `xipe do` would; the book is saved after every turn.
  defp search(args) do
    project = project!(nil)
    opts = [ctx: GitCtx.read(project.path), project_dir: project.dir]
    first = %{"method" => "dialogue/search", "params" => %{"line" => Enum.map_join(args, " ", &shell_word/1)}}
    book = Store.load(project.store_file)
    {dialogue, new_book, outcome} = InOut.handle(nil, book, project.path, first, opts, InOut.programs())
    dialogue_loop(project, opts, dialogue, book, new_book, outcome, "search> ")
  end

  # `xipe dialogue do <method> [key=value...]` (Dialogue.Do): asks for what
  # the line didn't give at a `do> ` prompt, then runs the call
  defp dialogue_do([]), do: usage_error("xipe dialogue do: usage: xipe dialogue do <method> [key=value...]")

  defp dialogue_do([method | given]) do
    [%{"params" => params}] = CommandLine.parse([method | given])
    dialogue_start(%{"method" => "dialogue/do", "params" => %{"method" => method, "given" => params}}, "do> ")
  end

  # `xipe dialogue rewrite [<table> [<row> [<column>]]]` (Dialogue.Rewrite):
  # one value of a table changed by hand; the new value is asked for
  defp dialogue_rewrite(words) when length(words) <= 3 do
    params = ["table", "row", "column"] |> Enum.zip(words) |> Map.new()
    dialogue_start(%{"method" => "dialogue/rewrite", "params" => params}, "rewrite> ")
  end

  defp dialogue_rewrite(_words), do: usage_error("xipe dialogue rewrite: usage: xipe dialogue rewrite [<table> [<row> [<column>]]]")

  # `xipe dialogue update [<file> [<key>]]` (Dialogue.Update): one of the
  # open project's settings changed; the new value is asked for
  defp dialogue_update(words) when length(words) <= 2 do
    params = ["file", "key"] |> Enum.zip(words) |> Map.new()
    dialogue_start(%{"method" => "dialogue/update", "params" => params}, "update> ")
  end

  defp dialogue_update(_words), do: usage_error("xipe dialogue update: usage: xipe dialogue update [<file> [<key>]]")

  # a dialogue on the open project, driven at `prompt` to its end
  defp dialogue_start(first, prompt) do
    project = project!(nil)
    opts = [ctx: GitCtx.read(project.path), project_dir: project.dir, log_file: XipeTotec.LogBuffer.default_file()]
    book = Store.load(project.store_file)
    {dialogue, new_book, outcome} = InOut.handle(nil, book, project.path, first, opts, InOut.programs())
    dialogue_loop(project, opts, dialogue, book, new_book, outcome, prompt)
  end

  defp dialogue_loop(project, opts, dialogue, old_book, book, outcome, prompt) do
    if outcome.text do
      IO.puts(outcome.text)
      XipeTotec.LogBuffer.append(XipeTotec.LogBuffer.default_file(), outcome.text)
    end

    unless outcome.ok?, do: IO.puts(:stderr, "#{outcome.error["code"]}: #{outcome.error["message"]}")
    if match?(%{"outcomes" => _}, outcome.result), do: print_outcomes(outcome.result["outcomes"])

    book =
      case Map.get(outcome, :run) do
        {:line, line} -> run_line(project, opts, book, line)
        {:commands, commands} -> run_list(project, opts, book, commands)
        nil -> book
      end

    record(project, old_book, book, "what this dialogue changed was not recorded")

    with {mod, _state} <- dialogue,
         line when is_binary(line) <- IO.gets(prompt) do
      request = XipeTotec.Dialogue.line_request(mod, String.trim(line))
      {dialogue, new_book, outcome} = InOut.handle(dialogue, book, project.path, request, opts, InOut.programs())
      dialogue_loop(project, opts, dialogue, book, new_book, outcome, prompt)
    else
      _ -> :ok
    end
  end

  # a line a dialogue passed on, read as the dialogue window reads one
  defp run_line(project, opts, book, line) do
    case XipeTotec.Input.parse(line) do
      {:commands, commands} ->
        run_list(project, opts, book, commands)

      printed ->
        case printed do
          :show -> Enum.each(Show.lines(project.id, project.path, book), &IO.puts/1)
          {:text, text} -> IO.write(text)
          {:error, message} -> IO.puts(:stderr, message)
        end

        book
    end
  end

  defp run_list(project, opts, book, commands) do
    unless Enum.all?(commands, &Methods.read_only?(&1["method"])), do: warn_if_session_project(project)
    {book, outcomes} = Runner.run(book, project.path, commands, opts)
    print_outcomes(outcomes)
    book
  end

  defp shell_word(w), do: if(w == "" or String.match?(w, ~r/\s/), do: "'#{w}'", else: w)

  # `xipe refresh -l|-r|-a`: a deliberate registration
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

    # what is refreshed is made again from lib/: an info.json that is not
    # readable is started over from the empty one (said)
    info =
      case Info.read() do
        {:ok, info} ->
          info

        {:error, message} ->
          IO.puts(:stderr, "xipe refresh: #{message} -- starting from an empty one")
          %{"languages" => [], "extensions" => %{}, "repls" => []}
      end

    info = if do_languages, do: Info.refresh_languages(info), else: info
    info = if do_repls, do: Info.refresh_repls(info), else: info
    ok_or_halt(Info.save(info), "xipe refresh")

    if do_languages, do: IO.puts("xipe refresh: languages = #{inspect(info["languages"])}  extensions = #{inspect(info["extensions"])}")

    if do_languages do
      for name <- info["languages"] do
        tools = Enum.map_join(info["build_tools"][name] || [], " > ", &"#{&1["name"]}(#{Enum.join(&1["markers"], ",")})")
        IO.puts("xipe refresh: #{name}: repl=#{info["language_repls"][name] || "-"}  build_tools = #{if tools == "", do: "-", else: tools}")
      end
    end
    if do_repls, do: IO.puts("xipe refresh: repls = #{inspect(info["repls"])}")
  end

  defp usage_error(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  # The CLI only builds a command list -- a plain
  # `[%{"method" =>, "params" =>}, ...]` -- and hands it to `Runner.run/4`
  # rather than changing the book here. `scan`/`eval` above are
  # one-command lists; `do_cmd/1` below is the general form.
  defp run_commands(project, commands, evaluator_opts \\ []) do
    unless Enum.all?(commands, &Methods.read_only?(&1["method"])), do: warn_if_session_project(project)
    old_book = Store.load(project.store_file)
    # scan/run and eval read the project's saved surface table and
    # run its tools in its own environment (ProjectEnv)
    evaluator_opts = Keyword.put(evaluator_opts, :project_dir, project.dir)
    {new_book, outcomes} = Runner.run(old_book, project.path, commands, evaluator_opts)
    print_outcomes(outcomes)
    record(project, old_book, new_book, "the results above were not recorded")
    unless Enum.all?(outcomes, & &1.ok?), do: System.halt(1)
  end

  # what a command changed, into the project's book.jsonl -- or, when it
  # cannot be written (another process keeps it locked, the disk refuses),
  # one line saying so, and exit 1
  defp record(project, old_book, new_book, what) do
    case Store.persist_diff(project.store_file, old_book, new_book, @all_tables) do
      :ok ->
        :ok

      {:error, why} ->
        IO.puts(:stderr, "xipe: " <> Store.describe(why) <> " -- " <> what)
        System.halt(1)
    end
  end

  # the same lines the dialogue window's input answers with (OutcomeText)
  defp print_outcomes(outcomes), do: print_lines(OutcomeText.lines(outcomes))

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
      # the git provenance an "eval" step records, as `xipe eval` does
      project = project!(dir)
      run_commands(project, commands, ctx: GitCtx.read(project.path))
    end
  end

  defp unknown(cmd) do
    IO.puts(:stderr, "xipe: unknown command #{inspect(cmd)}")
    System.halt(1)
  end
end

XipeTotec.CLI.main(System.argv())
