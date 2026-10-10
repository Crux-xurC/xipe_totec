Code.require_file("book.exs", __DIR__)
Code.require_file("dispatch.exs", __DIR__)
Code.require_file("project.exs", __DIR__)
Code.require_file("surface_table.exs", __DIR__)
Code.require_file("pipeline.exs", __DIR__)
Code.require_file("repl/evaluator.exs", __DIR__)
Code.require_file("info.exs", __DIR__)
Code.require_file("project_env.exs", __DIR__)
Code.require_file("passes.exs", __DIR__)

defmodule XipeTotec.Runner do
  @moduledoc """
  Runs a command list: a plain, JSON-encodable `[%{"method" =>, "params"
  =>}, ...]`, shaped like the wire messages (`Protocol`/`Dispatch`'s
  `method`/`params` pair), so the CLI and the server's `input` hand this
  module the same thing. `run/4` is the one entry point.

  Three kinds of command, dispatched by method name:

    * every method `Dispatch` knows (`"row/add"`, `"effect/set"`,
      `"scan/run"`, `"cell/resolve"`, `"graph/neighbors"`, ...) is handed
      to `Dispatch.handle/4` unchanged.
    * `"eval"` is not a `Dispatch` method: it needs live REPL I/O, which
      `Dispatch`'s synchronous Book-in-Book-out contract doesn't
      accommodate. It goes to `Repl.Evaluator.run_pass/3`. It is the one
      primitive that evaluates anything: `"eval/run"`/`"row/update"` reach
      it through `Pipeline`'s `"eval"` stage, and `Serve.Project`'s pass
      queue runs it for every asynchronous evaluation.
    * any method `Pipeline.handles?/1` says yes to (`pipelines.json`'s
      entries) is routed to `Pipeline.run/4`, with this module's `"eval"`
      handed in as the `"eval"` stage (`ctx.eval`). Checked *before* the
      plain-`Dispatch` case.

  ## Cross-command references

  A command built before an earlier one's result exists (e.g. "add this
  row, then mark it pure, then evaluate it" -- the row's id doesn't exist
  until `"row/add"` actually runs) can reference that earlier result with
  a plain string `"$<index>.<dotted.path>"` (`index` is 0-based position
  in this call's own `commands` list): e.g. `%{"id" => "$0.id"}` pulls
  `result["id"]` out of command 0's own result map. Resolved at *run*
  time, one command before it executes -- until then the command list is
  inert data (unresolved `$0.id` strings and all). Walks into lists and
  maps too, so `"args" => ["$0.id", "5"]` works. A reference to a command
  that failed (no result), or a path that isn't there, resolves to `nil`.

  A path segment that is a number indexes a list (`$0.matches.0.id`), and a
  segment names a map's string key or, failing that, its atom key (Book
  rows, e.g. `$0.row.args`).

  Inside a larger string the reference is replaced only as a whole `⟦⟧`
  cell reference: `"⟦$0.id⟧"` becomes `"⟦<id>⟧"`, so a row can
  reference a row added earlier in the same list. One that doesn't resolve
  to a string is left as written.
  """

  alias XipeTotec.{Book, Core, Dispatch, Info, Passes, Pipeline, Project, ProjectEnv, SurfaceTable}
  alias XipeTotec.Repl.Evaluator

  @type command :: %{String.t() => term()}
  @type outcome :: %{method: String.t(), ok?: boolean(), result: map() | nil, error: map() | nil}

  @doc """
  Runs `commands` against `book` in order, threading the book through
  every step (so command 2 sees command 1's effect) and substituting
  `$n.path` references before each one runs. `root` is passed to
  `Dispatch.handle/4` as `ctx.root` (needed by `"scan/run"`) and to
  `Evaluator.run_pass/3` as `:cwd`. `opts` are extra `Evaluator.run_pass/3`
  options (`:launch_opts`, `:ctx`, `:sender`, ...), used only for `"eval"`
  commands, plus `:language` (a registered language name) to skip
  detecting it from `root`'s surface table (tests: `:info` replaces
  info.json and `:language_modules` maps a language name to its module),
  and `:project_dir` (the
  project's `tables/project/<id>_<name>/`): `"scan/run"` and `"eval"` read
  its saved surface table (`SurfaceTable.rows/3`) instead of generating one
  on every call, and start the project's tools in its environment
  (`ProjectEnv`). An `"eval"` result then carries that environment's
  status as `"env"`. With `:project_dir`, every language group of a pass is
  also recorded as running while it runs (`XipeTotec.Passes`: what
  `eval/status` shows, and what refuses a change to one of its rows);
  `:pass_id` names the pass (`Serve.Project` passes its own), else one is
  made.

  Does not halt on a failing command -- every command in the list runs
  (a reference into a failed command's result just resolves to `nil`,
  and whatever `Dispatch`/`Evaluator` does with a `nil` it didn't expect
  is that command's own error to report, same as any other bad input).
  Returns `{book, outcomes}`, `outcomes` in the same order as `commands`.
  """
  @spec run(Book.t(), String.t(), [command()], keyword()) :: {Book.t(), [outcome()]}
  def run(book, root, commands, opts \\ []) do
    {book, outcomes} =
      Enum.reduce(commands, {book, []}, fn command, {book, outcomes} ->
        resolved = substitute(command, Enum.reverse(outcomes))
        {book, outcome} = run_one(book, root, resolved, opts)
        {book, [outcome | outcomes]}
      end)

    {book, Enum.reverse(outcomes)}
  end

  defp run_one(book, root, %{"method" => "eval", "params" => params}, opts) do
    case given_call_ids(params) do
      {:ok, given_ids} -> run_eval(book, root, params, given_ids, opts)
      {:error, error} -> {book, %{method: "eval", ok?: false, result: nil, error: error}}
    end
  end

  # Any method `pipelines.json` lists (`eval/run`/`row/update` today) is
  # checked *before* the generic `Dispatch` clause below and routed around
  # `Dispatch` entirely, not through it (see `Pipeline`'s own moduledoc for
  # why -- same reasoning as `"eval"` above). Deliberately consults
  # `Pipeline.handles?/1` for every method rather than hardcoding the
  # current two names here: the whole point of the registry file is that
  # this call site doesn't need editing when a third method is added to it.
  defp run_one(book, root, %{"method" => method, "params" => params}, opts) do
    ctx = %{root: root, project_dir: Keyword.get(opts, :project_dir)}

    if Pipeline.handles?(method) do
      # the "eval" stage comes back into this module's own "eval" with these opts
      eval = fn book, eval_params ->
        {book, [outcome]} = run(book, root, [%{"method" => "eval", "params" => eval_params}], opts)
        {book, outcome}
      end

      case Pipeline.run(method, book, params, Map.put(ctx, :eval, eval)) do
        {:ok, new_book, result} -> {new_book, %{method: method, ok?: true, result: result, error: nil}}
        {:error, unchanged_book, error} -> {unchanged_book, %{method: method, ok?: false, result: nil, error: error}}
      end
    else
      case Dispatch.handle(book, method, params, ctx) do
        {:ok, new_book, result} -> {new_book, %{method: method, ok?: true, result: result, error: nil}}
        {:error, unchanged_book, error} -> {unchanged_book, %{method: method, ok?: false, result: nil, error: error}}
      end
    end
  end

  # `call_ids` written but empty-handed -- `nil`, or a list holding `nil`:
  # a `$n.path` into a command that failed (or has no such key) resolves to
  # `nil` (see run/4). Refused rather than read as "omitted": omitted means
  # every call in the book, and `row/add ... -- eval call_ids=$0.id` after a
  # failed row/add must not evaluate the whole book.
  defp given_call_ids(params) do
    ids = params |> Map.get("call_ids", []) |> List.wrap()

    if Map.has_key?(params, "call_ids") and (params["call_ids"] == nil or Enum.any?(ids, &is_nil/1)),
      do: {:error, %{"code" => "invalid_params", "message" => "eval: call_ids is empty (a $n.… reference names nothing -- the earlier command failed, or it has no such key). Nothing was evaluated. To evaluate every row, leave call_ids out"}},
      else: {:ok, ids}
  end

  defp run_eval(book, root, params, given_ids, opts) do
    # Omitted/empty call_ids means "every call in the book", as for the
    # `xipe eval` command.
    call_ids = if given_ids == [], do: Map.keys(book.calls), else: given_ids

    # "include_writes": Core.plan_recalc/3
    # (via Repl.Evaluator.run_pass/3, both already wired -- see the moduledoc
    # note this fixes) has always accepted :include_writes, but nothing on the
    # CLI side ever read it out of a command's own params, so writes-effect
    # calc rows could never actually be opted into from here. truthy?/1 tolerates
    # both a real JSON boolean (a direct Runner.run/4 caller) and the plain
    # string "true" `xipe do ... include_writes=true` produces (parse_kv/1's
    # generic key=value parsing never coerces to boolean).
    include_writes = params |> Map.get("include_writes", false) |> truthy?()

    case eval_groups(book, root, call_ids, opts) do
      {:ok, groups, surface_rows, unplaced} ->
        run_groups(book, root, groups, surface_rows, unplaced, call_ids, include_writes, opts)

      {:error, error} ->
        {book, %{method: "eval", ok?: false, result: nil, error: error}}
    end
  end

  # --- "eval": one REPL per language ------------
  #
  # A pass evaluates the requested rows grouped by their language -- the
  # surface-table `language` of the file their function is in. Each group
  # gets its own REPL (its language's adapter, boot and environment); with
  # more than one group they run side by side, each in its own process,
  # since no value crosses between them: a row referencing a row of another
  # language is left out (`not_run`), because a value's text is written in
  # its own language and nothing converts it yet. With a single language
  # (every project before mixed-language support) this is exactly the old
  # one-REPL pass, run in the calling process.

  # `{:ok, [{language, ids}], surface_rows, unplaced}` -- `unplaced` being
  # `not_run` entries for rows that can't go into any group
  defp eval_groups(book, root, call_ids, opts) do
    project_dir = Keyword.get(opts, :project_dir)
    info = Keyword.get_lazy(opts, :info, &Info.load/0)
    rows = SurfaceTable.rows(root, project_dir && Path.join(project_dir, "table"), info)
    registered = info["languages"] || []
    languages = rows |> Enum.map(& &1["language"]) |> Enum.filter(&(&1 in registered)) |> Enum.uniq() |> Enum.sort()

    case {Keyword.fetch(opts, :language), languages} do
      {{:ok, name}, _} ->
        {:ok, if(call_ids == [], do: [], else: [{name, call_ids}]), rows, []}

      {:error, []} ->
        {:error,
         %{"code" => "no_language", "message" => "no file of a registered language (#{Enum.join(registered, ", ")}) under #{root}"}}

      {:error, languages} ->
        by_path = for r <- rows, r["language"] in registered, into: %{}, do: {r["path"], r["language"]}
        # a single-language project: every row is that language, however
        # its file is recorded
        fallback = if match?([_], languages), do: hd(languages)
        language_of = fn id -> row_language(book, id, by_path) || fallback end

        {placed, unplaced} =
          Enum.reduce(call_ids, {[], []}, fn id, {placed, unplaced} ->
            case place(book, id, language_of) do
              {:ok, language} -> {[{language, id} | placed], unplaced}
              {:not_run, reason} -> {placed, [%{"id" => id, "reason" => reason} | unplaced]}
            end
          end)

        # in the order each language first appears among the requested rows
        placed = Enum.reverse(placed)
        order = placed |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        groups = for language <- order, do: {language, for({^language, id} <- placed, do: id)}

        {:ok, groups, rows, Enum.reverse(unplaced)}
    end
  end

  defp place(book, id, language_of) do
    case language_of.(id) do
      nil ->
        {:not_run, Core.exclusion_reason(book, id) || "its language can't be told (no file of a registered language holds its function)"}

      language ->
        refs = case Book.get(book, :calls, id) do
          nil -> []
          call -> Core.refs_in_args(call.args)
        end

        case Enum.find_value(refs, fn ref -> (l = language_of.(ref)) && l != language && {ref, l} end) do
          nil -> {:ok, language}
          {ref, other} -> {:not_run, "⟦#{ref}⟧ is a #{other} row -- a reference across languages isn't supported yet"}
        end
    end
  end

  # call -> node -> sheet -> path -> the surface table's language
  defp row_language(book, id, by_path) do
    with %{node: node_id} <- Book.get(book, :calls, id),
         %{sheet: sheet_id} <- Book.get(book, :nodes, node_id),
         %{path: path} <- Book.get(book, :sheets, sheet_id) do
      Map.get(by_path, path)
    else
      _ -> nil
    end
  end

  defp run_groups(book, root, groups, rows, unplaced, call_ids, include_writes, opts) do
    pass_id = Keyword.get_lazy(opts, :pass_id, &XipeTotec.Id.ulid/0)
    run = fn {language, ids} -> {language, ids, run_group(book, root, rows, language, ids, include_writes, pass_id, opts)} end

    ran =
      case groups do
        [one] -> [run.(one)]
        _ -> groups |> Enum.map(&Task.async(fn -> run.(&1) end)) |> Task.await_many(:infinity)
      end

    failed = for {language, ids, {:error, error}} <- ran, do: {language, ids, error}
    succeeded = for {_language, _ids, {:ok, results, env_status}} <- ran, do: {results, env_status}

    cond do
      # a single language that failed: its own error, as it is
      match?([_], ran) and match?([_], failed) ->
        [{_, _, error}] = failed
        {book, %{method: "eval", ok?: false, result: nil, error: error}}

      ran != [] and length(failed) == length(ran) ->
        message = Enum.map_join(failed, "; ", fn {language, _, error} -> "#{language}: #{error["message"]}" end)
        {book, %{method: "eval", ok?: false, result: nil, error: %{"code" => "eval_failed", "message" => message}}}

      true ->
        results = Enum.flat_map(succeeded, &elem(&1, 0))
        ctx = Keyword.get(opts, :ctx, %{commit: nil, commit_at: nil, dirty: nil})
        new_book = Core.apply_results(book, ctx, results)

        failed_not_run =
          for {language, ids, error} <- failed, id <- ids, do: %{"id" => id, "reason" => "the #{language} REPL: #{error["message"]}"}

        # requested ids the plan never reached a REPL with, and why
        accounted = MapSet.new(Enum.map(results, & &1.call_id) ++ Enum.map(unplaced ++ failed_not_run, & &1["id"]))

        not_run =
          unplaced ++
            failed_not_run ++
            for id <- call_ids, id not in accounted do
              %{"id" => id, "reason" => Core.exclusion_reason(book, id, include_writes: include_writes) || "not scheduled"}
            end

        result = %{"results" => results, "not_run" => not_run}

        result =
          case {Keyword.get(opts, :project_dir), succeeded} do
            {nil, _} -> result
            {_, [{_, env_status} | _]} -> Map.put(result, "env", env_status)
            _ -> result
          end

        {new_book, %{method: "eval", ok?: true, result: result, error: nil}}
    end
  end

  # one language's REPL over `ids`: `{:ok, results, env_status}` (results
  # not yet folded into the book) or `{:error, error}`
  defp run_group(book, root, rows, language, ids, include_writes, pass_id, opts) do
    case repl_opts(root, rows, language, opts) do
      {:ok, repl_opts, cleanup, env_status} ->
        # recorded as running for as long as the group's REPL works on `ids`
        handle = Passes.start(Keyword.get(opts, :project_dir), pass_id, language, ids)
        progress = fn call_id, phase -> Passes.progress(handle, call_id, phase) end
        eval_opts = Keyword.merge(repl_opts, cwd: root, call_ids: ids, include_writes: include_writes, progress: progress)

        result =
          try do
            Evaluator.run_pass(book, pass_id, eval_opts)
          after
            Passes.finish(handle)
          end

        cleanup.()

        case result do
          {:ok, _book, results} -> {:ok, results, env_status}
          {:error, reason} -> {:error, %{"code" => "eval_failed", "message" => failure_message(reason)}}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # A REPL that exited while booting -- most often the project's own code
  # failing to compile -- is reported with what it printed (Session.await_ready/4),
  # so the message says which file and line instead of only an exit status.
  @doc false
  def failure_message({:boot_failed, {:exited_before_ready, status, ""}}),
    do: "boot_failed: the REPL exited before it was ready (exit status #{status}), printing nothing"

  def failure_message({:boot_failed, {:exited_before_ready, status, output}}) do
    "boot_failed: the REPL exited before it was ready (exit status #{status}). Its last output:\n" <>
      Enum.map_join(String.split(output, "\n"), "\n", &("    " <> &1))
  end

  def failure_message(reason), do: inspect(reason)

  # The REPL side of one language's pass: the
  # language must be registered in info.json, and its `Repl.Language`
  # module supplies both the four adapter modules and how to boot the REPL
  # for the build tool the surface table found. Adapter modules or
  # `:launch_opts` a caller already put in `opts` win (the CLI's `--mix`
  # passes `launch_opts: []`; tests pass a fake `:sender` the same way).
  # Returns `{:ok, opts, cleanup, env_status}` -- `cleanup` removes whatever
  # the boot needed (scripts-mode's sanitized temp dir) once the pass is
  # over; `env_status` is ProjectEnv's for the project's environment, which
  # the REPL is started in (added to launch_opts' :env).
  defp repl_opts(root, rows, name, opts) do
    project_dir = Keyword.get(opts, :project_dir)

    with {:ok, mod} <- language_module(name, opts) do
      build_tool = Enum.find_value(rows, &(&1["language"] == name && &1["build_tool"]))

      {launch_opts, cleanup} =
        if Keyword.has_key?(opts, :launch_opts) do
          {Keyword.fetch!(opts, :launch_opts), fn -> :ok end}
        else
          files = for sheet <- Project.sheets_in(rows), sheet.language == name, do: sheet.path
          mod.launch_opts(root, build_tool, files)
        end

      adapter = mod.adapter()
      {env, env_status} = ProjectEnv.resolve(root, project_dir)
      launch_opts = Keyword.update(launch_opts, :env, env, &Map.merge(env, &1))

      opts =
        opts
        |> Keyword.drop([:language, :project_dir, :info, :language_modules, :pass_id])
        |> Keyword.put(:launch_opts, launch_opts)
        |> Keyword.put_new(:launch_module, adapter.launch)
        |> Keyword.put_new(:eval_template_module, adapter.eval_template)
        |> Keyword.put_new(:scan_module, adapter.scan)
        |> Keyword.put_new(:field_drip_module, adapter.field_drip)

      {:ok, opts, cleanup, env_status}
    end
  end

  # `:language_modules` (tests) maps a language name straight to its module
  defp language_module(name, opts) do
    case Map.fetch(Keyword.get(opts, :language_modules, %{}), name) do
      {:ok, mod} -> {:ok, mod}
      :error -> registered_language_module(name, opts)
    end
  end

  defp registered_language_module(name, opts) do
    info = Keyword.get_lazy(opts, :info, &Info.load/0)

    case Info.language_module(name, info) do
      {:ok, mod} ->
        {:ok, mod}

      {:error, :not_registered} ->
        {:error, %{"code" => "language_not_registered", "message" => "#{name} is not registered (xipe refresh -l)"}}
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # --- $n.path substitution -------------------------------------------

  @doc """
  `command`'s `$<n>.<path>` references resolved against `prior_outcomes`
  (the outcomes of the commands before it, in order) -- what `run/4` does
  before each command, for a caller that runs a command list one command
  at a time itself (`Serve.Input`, whose eval steps are asynchronous).
  """
  @spec substitute_command(command(), [outcome()]) :: command()
  def substitute_command(command, prior_outcomes), do: substitute(command, prior_outcomes)

  defp substitute(%{"params" => params} = command, prior_outcomes),
    do: %{command | "params" => substitute(params, prior_outcomes)}

  defp substitute(text, prior_outcomes) when is_binary(text) do
    case Regex.run(~r/^\$(\d+)\.(.+)$/, text) do
      [_, index, path] ->
        lookup(prior_outcomes, index, path)

      nil ->
        Regex.replace(~r/⟦\$(\d+)\.([^⟧]+)⟧/u, text, fn whole, index, path ->
          case lookup(prior_outcomes, index, path) do
            id when is_binary(id) -> "⟦#{id}⟧"
            _ -> whole
          end
        end)
    end
  end

  defp substitute(list, prior_outcomes) when is_list(list), do: Enum.map(list, &substitute(&1, prior_outcomes))
  defp substitute(map, prior_outcomes) when is_map(map), do: Map.new(map, fn {k, v} -> {k, substitute(v, prior_outcomes)} end)
  defp substitute(other, _prior_outcomes), do: other

  defp lookup(prior_outcomes, index, path) do
    case Enum.at(prior_outcomes, String.to_integer(index)) do
      %{result: result} when is_map(result) -> dig(result, String.split(path, "."))
      _ -> nil
    end
  end

  defp dig(value, []), do: value

  defp dig(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> dig(value, rest)
      :error -> map |> Map.get(existing_atom(key)) |> dig_present(rest)
    end
  end

  defp dig(list, [key | rest]) when is_list(list) do
    case Integer.parse(key) do
      {i, ""} when i >= 0 -> list |> Enum.at(i) |> dig_present(rest)
      _ -> nil
    end
  end

  defp dig(_other, _path), do: nil

  defp dig_present(nil, _rest), do: nil
  defp dig_present(value, rest), do: dig(value, rest)

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
