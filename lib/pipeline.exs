Code.require_file("book.exs", __DIR__)
Code.require_file("dispatch.exs", __DIR__)

defmodule XipeTotec.Pipeline do
  @moduledoc """
  Methods that combine steps: such a method is a list of stages in
  `pipelines.json`, not code of its own. `eval/run` and `row/update` go
  through it, on the CLI and the server alike.

  ## Why not a `Dispatch` clause

  `eval/run`/`row/update` need a live REPL evaluation pass, which is I/O
  and can take seconds. `Dispatch.handle/4` is pure (Book in, Book out, no
  I/O beyond `scan/run`'s file reads), and `Serve.Project`'s
  `GenServer.call` is synchronous, so evaluating inside either would hold
  every other request for the duration. So this module is called *around*
  `Dispatch`: `Runner.run_one/4` (CLI) and `Serve.Project` check
  `handles?/1` first and call `run/4` (`prepare/4` on the server) instead
  of `Dispatch.handle/4`. `Dispatch` answers `not_implemented` for these
  two if reached directly.

  ## The registry

  `pipelines.json` (at xipe_totec's own root, `__DIR__`-relative) maps a
  method name to an ordered list of stage names:

      {"eval/run": ["eval"], "row/update": ["edit", "eval"]}

  `row/update` is "edit (pure, `Core.edit_args`) then eval (of that row
  only)": one small pure stage followed by the same "eval" stage `eval/run`
  is.

  Stages run in order, threading the book forward; the first stage to
  return `{:error, ...}` stops the pipeline right there (a later stage
  never runs against a book an earlier stage refused to produce).

  ## Stages

  * `"edit"` -- pure: sets the calc row `params["id"]`'s `args` to
    `params["args"]` (checked like `row/add`, `Dispatch.check_args/4`)
  * `"eval"` -- the REPL: `Runner`'s own `"eval"`, the one primitive that
    evaluates anything, handed in as `ctx.eval` (`fn book, eval_params ->
    {book, outcome} end`). It evaluates exactly the rows `eval_params/1`
    derives from the method's params -- `params["call_ids"]` (none: every
    row), or the one row `params["id"]` -- never any other

  Each stage's result map is merged into the next, so `row/update` answers
  with both the edited row and the evaluation. `"eval"` must be the last
  stage: `Serve.Project` runs the stages before it at once (`prepare/4`)
  and hands `"eval"` to its asynchronous pass queue, the same queue a plain
  `"eval"` goes through; the CLI (`Runner`) runs every stage in order
  (`run/4`).

  `run/5`'s last argument overrides the stage table, so tests can inject
  fake stages to check the sequencing itself (`test/pipeline_test.exs`).
  """

  alias XipeTotec.Book

  # `__DIR__`-relative: `pipelines.json` belongs to this xipe_totec
  # checkout, not to the target project or to wherever the process was
  # started from.
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

  @doc """
  For a caller that runs the `"eval"` stage itself (`Serve.Project`'s pass
  queue): runs `method`'s stages before `"eval"` and returns
  `{:ok, book, result, eval_params}` -- `eval_params` being what to
  evaluate (`eval_params/1`), or `nil` if the method has no `"eval"` stage.
  """
  @spec prepare(String.t(), Book.t(), map(), map()) :: {:ok, Book.t(), map(), map() | nil} | {:error, Book.t(), map()}
  def prepare(method, book, params, ctx) do
    case Map.fetch(load_registry(), method) do
      {:ok, stages} ->
        {before, rest} = Enum.split_while(stages, &(&1 != "eval"))

        with {:ok, new_book, result} <- run_stages(before, book, params, ctx, stage_handlers(), %{}) do
          {:ok, new_book, result, if(rest == [], do: nil, else: eval_params(params))}
        end

      :error ->
        {:error, book, %{"code" => "unknown_method", "message" => method}}
    end
  end

  @doc """
  The `"eval"` stage's own params for a method's `params`: `call_ids` as
  given (none: every row), else the single row `id`, and `include_writes`.
  A `call_ids` given as `nil` (a `$n.path` that found nothing) stays `nil`,
  for the `"eval"` to refuse -- never read as "every row" (`Runner`).
  """
  @spec eval_params(map()) :: map()
  def eval_params(params) do
    call_ids =
      cond do
        Map.has_key?(params, "call_ids") -> if(params["call_ids"] == nil, do: nil, else: List.wrap(params["call_ids"]))
        is_binary(params["id"]) -> [params["id"]]
        true -> []
      end

    %{"call_ids" => call_ids, "include_writes" => Map.get(params, "include_writes", false)}
  end

  defp run_stages(stages, book, params, ctx, stage_handlers), do: run_stages(stages, book, params, ctx, stage_handlers, %{})

  defp run_stages([], book, _params, _ctx, _stage_handlers, acc), do: {:ok, book, acc}

  defp run_stages([stage | rest], book, params, ctx, stage_handlers, acc) do
    handler = Map.get(stage_handlers, stage, &unknown_stage/3)

    case handler.(book, params, ctx) do
      {:ok, new_book, result} -> run_stages(rest, new_book, params, ctx, stage_handlers, Map.merge(acc, result))
      {:error, _book, _error} = error -> error
    end
  end

  defp unknown_stage(book, _params, _ctx),
    do: {:error, book, %{"code" => "unknown_stage", "message" => "no handler registered for this pipeline stage"}}

  # --- stages -- see moduledoc ------------------------------------------

  defp stage_handlers, do: %{"edit" => &edit_stage/3, "eval" => &eval_stage/3}

  defp edit_stage(book, %{"id" => id, "args" => args}, ctx) when is_binary(id) do
    # a row a running pass is evaluating keeps its args until the pass
    # ends (XipeTotec.Passes)
    refused = XipeTotec.Passes.refuse(ctx[:project_dir], id)

    case Book.get(book, :calls, id) do
      nil ->
        {:error, book, %{"code" => "not_found", "message" => "unknown call id: #{id}"}}

      _row when refused != nil ->
        {:error, book, refused}

      row ->
        case XipeTotec.Dispatch.check_args(book, row.node, args, "row/update") do
          :ok ->
            new_book = XipeTotec.Core.edit_args(book, id, args)
            {:ok, new_book, %{"id" => id, "row" => Book.get(new_book, :calls, id)}}

          {:error, error} ->
            {:error, book, error}
        end
    end
  end

  defp edit_stage(book, _params, _ctx),
    do: {:error, book, %{"code" => "invalid_params", "message" => "row/update needs id (string) and args ([string])"}}

  # the REPL primitive, handed in by the caller as `ctx.eval` (Runner's own
  # "eval") -- this module doesn't depend on Runner, which depends on it
  defp eval_stage(book, params, ctx) do
    case Map.fetch(ctx, :eval) do
      {:ok, eval} ->
        {new_book, outcome} = eval.(book, eval_params(params))
        if outcome.ok?, do: {:ok, new_book, outcome.result}, else: {:error, book, outcome.error}

      :error ->
        {:error, book, %{"code" => "no_repl", "message" => "the eval stage needs a REPL (ctx.eval), which this caller doesn't provide"}}
    end
  end
end
