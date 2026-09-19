Code.require_file("book.exs", __DIR__)
Code.require_file("dispatch.exs", __DIR__)
Code.require_file("project.exs", __DIR__)
Code.require_file("pipeline.exs", __DIR__)
Code.require_file("repl/evaluator.exs", __DIR__)
Code.require_file("repl/source_sanitize.exs", __DIR__)

defmodule XipeTotec.Runner do
  @moduledoc """
  The "action" half of crux's 2026-09-18 input -> command list -> action
  split: `main.exs`'s CLI is the first "input" front end onto this, but the
  command list itself (a plain, JSON-encodable `[%{"method" =>, "params"
  =>}, ...]`) is deliberately shaped like §16.3's own wire messages
  (`Protocol`/`Dispatch`'s own `method`/`params` pair) rather than
  something CLI-specific, so a second front end -- crux's stated target is
  a future tezcatl integration, not yet designed -- can hand this module
  the same list without needing a translation layer. `run/4` is this
  module's one entry point; everything else here is private.

Three kinds of command, dispatched by method name:

    * every method `Dispatch` already knows (`"row/add"`, `"effect/set"`,
      `"scan/run"`, `"cell/resolve"`, `"graph/neighbors"`, ...) is handed
      to `Dispatch.handle/4` unchanged -- this module adds nothing on top
      of what §16 already specifies for those.
    * `"eval"` is NOT a `Dispatch` method and never will be one here: it
      needs live REPL I/O/timing `Dispatch`'s synchronous
      Book-in-Book-out contract doesn't accommodate (the same reason the
      real, *async*, `notify/rowChanged`-streaming §16 method `"eval/run"`
      stays `Dispatch`'s own `@not_implemented` -- deliberately a
      different name, not a synonym: `"eval"` here is the synchronous
      one-shot CLI/batch variant, a different operation with a different
      result shape, not a stand-in for the eventual async server method).
      Routed straight to `Repl.Evaluator.run_pass/3` instead.
    * any method `Pipeline.handles?/1` says yes to (`pipelines.json`'s own
      entries -- `"eval/run"`/`"row/update"` today, 2026-09-18) is routed
      to `Pipeline.run/4`, checked *before* the plain-`Dispatch` case so it
      never falls through to `Dispatch`'s own `@not_implemented` for these.
      See `Pipeline`'s moduledoc for why these can't just be bigger
      `Dispatch` clauses (same I/O-doesn't-fit-the-pure-contract reasoning
      as `"eval"` above) and why `row/update` is "edit then eval" as a
      composition rather than its own bespoke implementation.

  ## Cross-command references

  A command built before an earlier one's result exists (e.g. "add this
  row, then mark it pure, then evaluate it" -- the row's id doesn't exist
  until `"row/add"` actually runs) can reference that earlier result with
  a plain string `"$<index>.<dotted.path>"` (`index` is 0-based position
  in this call's own `commands` list): e.g. `%{"id" => "$0.id"}` pulls
  `result["id"]` out of command 0's own result map. Resolved at *run*
  time, one command before it executes -- the command list itself, before
  that, is still inert data (unresolved `$0.id` strings and all), matching
  the "コマンドリスト is just data" half of the split. Walks into lists and
  maps too, so `"args" => ["$0.id", "5"]` works. A reference to a command
  that failed (no result) resolves to `nil`.
  """

  alias XipeTotec.{Book, Dispatch, Pipeline, Project}
  alias XipeTotec.Repl.{Evaluator, SourceSanitize}

  @type command :: %{String.t() => term()}
  @type outcome :: %{method: String.t(), ok?: boolean(), result: map() | nil, error: map() | nil}

  @doc """
  Runs `commands` against `book` in order, threading the book through
  every step (so command 2 sees command 1's effect) and substituting
  `$n.path` references before each one runs. `root` is passed to
  `Dispatch.handle/4` as `ctx.root` (needed by `"scan/run"`) and to
  `Evaluator.run_pass/3` as `:cwd`. `opts` are extra `Evaluator.run_pass/3`
  options (`:launch_opts`, `:ctx`, `:sender`, ...), used only for `"eval"`
  commands.

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
    given_ids = params |> Map.get("call_ids", []) |> List.wrap()
    # Omitted/empty call_ids means "every call in the book", matching the
    # dedicated `xipe eval` CLI command's own default (main.exs's `eval/1`)
    # -- without this, `xipe do ... -- eval` silently evaluates nothing
    # instead of the whole book (2026-09-19 review finding).
    call_ids = if given_ids == [], do: Map.keys(book.calls), else: given_ids
    {launch_opts, cleanup} = launch_opts_for(root, opts)

    eval_opts = opts |> Keyword.put(:launch_opts, launch_opts) |> Keyword.merge(cwd: root, call_ids: call_ids)

    result = Evaluator.run_pass(book, XipeTotec.Id.ulid(), eval_opts)
    cleanup.()

    case result do
      {:ok, new_book, results} ->
        {new_book, %{method: "eval", ok?: true, result: %{"results" => results}, error: nil}}

      {:error, reason} ->
        {book, %{method: "eval", ok?: false, result: nil, error: %{"code" => "eval_failed", "message" => inspect(reason)}}}
    end
  end

  # Any method `pipelines.json` lists (`eval/run`/`row/update` today) is
  # checked *before* the generic `Dispatch` clause below and routed around
  # `Dispatch` entirely, not through it (see `Pipeline`'s own moduledoc for
  # why -- same reasoning as `"eval"` above). Deliberately consults
  # `Pipeline.handles?/1` for every method rather than hardcoding the
  # current two names here: the whole point of the registry file is that
  # this call site doesn't need editing when a third method is added to it.
  defp run_one(book, root, %{"method" => method, "params" => params}, _opts) do
    if Pipeline.handles?(method) do
      case Pipeline.run(method, book, params, %{root: root}) do
        {:ok, new_book, result} -> {new_book, %{method: method, ok?: true, result: result, error: nil}}
        {:error, unchanged_book, error} -> {unchanged_book, %{method: method, ok?: false, result: nil, error: error}}
      end
    else
      case Dispatch.handle(book, method, params, %{root: root}) do
        {:ok, new_book, result} -> {new_book, %{method: method, ok?: true, result: result, error: nil}}
        {:error, unchanged_book, error} -> {unchanged_book, %{method: method, ok?: false, result: nil, error: error}}
      end
    end
  end

  # An "eval" command with no explicit `:launch_opts` in `opts` (found via a
  # real crash, 2026-09-18: `xipe do eval ...` had no equivalent of the old
  # dedicated `eval` subcommand's `--mix`-or-scripts-mode default, so it
  # fell through to `Repl.Launch.build/1`'s bare `iex -S mix` default and
  # tried to boot that in a `mix.exs`-less directory -- an instant boot
  # failure, not a hang) gets one inferred from `root` itself: mix-mode
  # (empty `launch_opts`, `Launch`'s own `["iex", "-S", "mix"]` default) if
  # `root/mix.exs` exists, scripts-mode (`argv: ["iex"]` + every `.ex`/
  # `.exs` file `Project.find_sheets/1` finds, loaded via `-r`) otherwise --
  # crux's own real projects (tezcatl included) are all the latter. A
  # caller that already knows better (the CLI's `--mix` override, or a
  # future tezcatl caller with its own opinion) passes `:launch_opts`
  # itself, and neither this inference nor the sanitize step below runs.
  #
  # Returns `{launch_opts, cleanup}` -- scripts-mode's file list is never
  # the *original* project files (review finding, 2026-09-18): `-r`ing them
  # directly would reopen Fix F's hazard one layer up (`-r` runs a script's
  # whole top-level, not just its `defmodule` forms -- a project whose root
  # has an entry-point script, xipe_totec's/tezcatl's own `main.exs`
  # included, would launch that script's side effects just from booting the
  # eval session). `SourceSanitize.sanitize/2` writes defmodule-only copies
  # to a temp dir instead; `cleanup` removes that temp dir once the caller
  # is done with the session (a no-op for the mix-mode / caller-supplied
  # cases, which never create one).
  defp launch_opts_for(root, opts) do
    if Keyword.has_key?(opts, :launch_opts) do
      {Keyword.fetch!(opts, :launch_opts), fn -> :ok end}
    else
      if File.exists?(Path.join(root, "mix.exs")) do
        {[], fn -> :ok end}
      else
        {tmp_dir, files} = SourceSanitize.sanitize(root, Project.find_sheets(root))
        {[argv: ["iex"], files: files], fn -> File.rm_rf!(tmp_dir) end}
      end
    end
  end

  # --- $n.path substitution -------------------------------------------

  defp substitute(%{"params" => params} = command, prior_outcomes),
    do: %{command | "params" => substitute(params, prior_outcomes)}

  defp substitute(text, prior_outcomes) when is_binary(text) do
    case Regex.run(~r/^\$(\d+)\.(.+)$/, text) do
      [_, index, path] ->
        prior_outcomes
        |> Enum.at(String.to_integer(index))
        |> case do
          %{result: result} when is_map(result) -> get_in(result, String.split(path, "."))
          _ -> nil
        end

      nil ->
        text
    end
  end

  defp substitute(list, prior_outcomes) when is_list(list), do: Enum.map(list, &substitute(&1, prior_outcomes))
  defp substitute(map, prior_outcomes) when is_map(map), do: Map.new(map, fn {k, v} -> {k, substitute(v, prior_outcomes)} end)
  defp substitute(other, _prior_outcomes), do: other
end
