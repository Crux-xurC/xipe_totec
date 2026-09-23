Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Pipeline do
  @moduledoc """
  The data-driven "command input -> reference list -> actual operation"
  routing crux asked for (2026-09-18 co-design), scoped for today to just
  the plumbing: `eval/run` and `row/update` are the first two methods
  wired through it, both with empty/stub stage bodies -- the stage bodies
  themselves are tomorrow's work, one at a time.

  ## Why this exists, not just a bigger `Dispatch` clause

  `eval/run`/`row/update` both need a live REPL evaluation pass
  (`row/update`'s spec text explicitly promises a recalc result back), which
  is I/O and can take seconds -- `Dispatch.handle/4` is deliberately kept
  pure (Book-in-Book-out, no I/O beyond `scan/run`'s file reads), and
  `Serve.Project`'s `GenServer.call` is synchronous, so blocking either of
  those on a live eval pass would freeze the whole project's request
  handling for the duration (Old.md §28 E, never retracted post-pivot -- see
  `document/Old.md` §10's intro). So this module is
  deliberately called *around* `Dispatch`, not from inside it -- both
  `Runner.run_one/4` (CLI) and `Serve.Project.handle_call/3` (§16 WS
  server) check `handles?/1` first and call `run/4` instead of
  `Dispatch.handle/4` when it does. `Dispatch`'s own `@not_implemented`
  entries for these two stay as-is, as a fallback for any caller that
  reaches `Dispatch.handle/4` directly without going through this module
  first.

  ## The registry

  `pipelines.json` (xipe_totec's own checkout root -- `__DIR__`-relative,
  not CWD-relative; see `load_registry/0`'s own comment for why) maps a
  method name to an ordered list of stage names:

      {"eval/run": ["eval"], "row/update": ["edit", "eval"]}

  `row/update` is "edit (pure, `Core.edit_args`/`set_prev`) then eval (a
  recalc pass)" -- not two independently-invented implementations, but one
  small pure stage followed by literally the same "eval" stage `eval/run`
  itself is. This is the "shared root" crux pointed at: once the `"eval"`
  stage has a real body (tomorrow+), `row/update` gets its recalc half for
  free by composition, the same way the CLI's `xipe do row/add -- eval`
  composes two already-built pieces rather than a bespoke third one.

  Stages run in order, threading the book forward; the first stage to
  return `{:error, ...}` stops the pipeline right there (a later stage
  never runs against a book an earlier stage refused to produce).

  ## Stage bodies (today: all stubs)

  A stage name resolves to a handler via `stage_handlers/0`'s table
  (`%{"edit" => fun, "eval" => fun}`, both stubs returning a clean
  `not_implemented` today). `run/4` takes an optional 5th arg overriding
  this table -- exists so tests can inject fake succeeding stages to prove
  the sequencing/threading logic itself, independent of any real stage
  ever being implemented (`test/pipeline_test.exs`).
  """

  alias XipeTotec.Book

  # `__DIR__`-relative (this file's own compile-time directory, `lib/`, so
  # `../pipelines.json` is the xipe_totec checkout's root), NOT CWD-relative
  # like `book.jsonl` -- `pipelines.json` is xipe_totec's own installation
  # config (which methods this build knows how to pipeline), not something
  # tied to whatever target project is being scanned/evaluated or to
  # wherever the process happened to be launched from. `xipe serve` in
  # particular is commonly spawned with CWD set to the *target* project's
  # own root or some other directory entirely (tezcatl's `XipeConn` spawns
  # it with `cd: install_dir`, which only happens to be xipe_totec's own
  # checkout by convention, not by contract) -- a CWD-relative path would
  # silently fall back to "no pipeline entries" the moment that convention
  # doesn't hold.
  @registry_file Path.expand("../pipelines.json", __DIR__)

  @type result :: {:ok, Book.t(), map()} | {:error, Book.t(), map()}

  @doc "Loads and parses `pipelines.json` (xipe_totec's own checkout root, not CWD-relative -- see the module attribute above). An absent or unparseable file yields an empty registry, never a crash."
  @spec load_registry() :: %{String.t() => [String.t()]}
  def load_registry do
    with {:ok, bytes} <- File.read(@registry_file),
         {:ok, decoded} <- JSON.decode(bytes),
         true <- is_map(decoded) do
      decoded
    else
      _ -> %{}
    end
  end

  @doc "Whether `method` has a pipeline entry -- callers (`Runner`, `Serve.Project`) use this to decide whether to route here instead of `Dispatch.handle/4`."
  @spec handles?(String.t()) :: boolean()
  def handles?(method), do: Map.has_key?(load_registry(), method)

  @doc """
  Runs `method`'s pipeline against `book`. `{:error, book, %{"code" =>
  "unknown_method", ...}}` if `method` has no registry entry (mirrors
  `Dispatch.handle/4`'s own unknown-vs-not-implemented distinction --
  callers are expected to have already checked `handles?/1`, this is the
  defensive fallback for callers that don't).
  """
  @spec run(String.t(), Book.t(), map(), map(), %{String.t() => (Book.t(), map(), map() -> result())}) :: result()
  def run(method, book, params, ctx, stage_handlers \\ stage_handlers()) do
    case Map.fetch(load_registry(), method) do
      {:ok, stages} -> run_stages(stages, book, params, ctx, stage_handlers)
      :error -> {:error, book, %{"code" => "unknown_method", "message" => method}}
    end
  end

  defp run_stages([], book, _params, _ctx, _stage_handlers), do: {:ok, book, %{}}

  defp run_stages([stage | rest], book, params, ctx, stage_handlers) do
    handler = Map.get(stage_handlers, stage, &unknown_stage/3)

    case handler.(book, params, ctx) do
      {:ok, new_book, result} ->
        case rest do
          [] -> {:ok, new_book, result}
          _ -> run_stages(rest, new_book, params, ctx, stage_handlers)
        end

      {:error, _book, _error} = error ->
        error
    end
  end

  defp unknown_stage(book, _params, _ctx),
    do: {:error, book, %{"code" => "unknown_stage", "message" => "no handler registered for this pipeline stage"}}

  # --- stage stubs (today) -- see moduledoc's "Stage bodies" section -----

  defp stage_handlers, do: %{"edit" => &stub_stage("edit", &1, &2, &3), "eval" => &stub_stage("eval", &1, &2, &3)}

  defp stub_stage(name, book, _params, _ctx),
    do: {:error, book, %{"code" => "not_implemented", "message" => "pipeline stage \"#{name}\" not implemented yet"}}
end
