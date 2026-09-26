Code.require_file("book.exs", __DIR__)
Code.require_file("store.exs", __DIR__)
Code.require_file("dispatch.exs", __DIR__)
Code.require_file("pipeline.exs", __DIR__)
Code.require_file("protocol.exs", __DIR__)
Code.require_file("in_out.exs", __DIR__)
Code.require_file("core.exs", __DIR__)
Code.require_file("runner.exs", __DIR__)
Code.require_file("git_ctx.exs", __DIR__)

defmodule XipeTotec.Serve.Project do
  @moduledoc """
  "1プロジェクト1GenServer" (Old.md §3, §9 2026-09-17): the one place
  in the §16 server that holds mutable state (`Book`). Everything else
  (`Dispatch`, `Address`, `Core`, ...) stays a pure function over a `Book`
  it's handed.

  Runs a `Dispatch.handle/4` call (or, for any method `Pipeline.handles?/1`
  says yes to -- `eval/run`/`row/update` today, 2026-09-18 -- a
  `Pipeline.run/4` call instead, checked first: see `Pipeline`'s own
  moduledoc for why these can't be plain `Dispatch` clauses), diffs the `Book` before/after with
  `Store.persist_diff/4` (generalized from `Project.persist_scan`'s
  sheets/nodes/links-only diff to all six tables -- a scan never touches
  `calls`, but other methods will), and broadcasts `notify/rowChanged` /
  `notify/nodeChanged` for whatever changed to every attached session.
  There is no per-consumer id-rewriting here the way tezcatl's `LspServer`
  has for `/lsp` -- Xipe Totec is the id-space owner for its own
  request/response pairs (nothing upstream to protect from collisions), and
  §16.2 already specifies the server broadcasts to every attached client
  and leaves picking-what-you-need to each one.

  One `xipe serve <root>` process = one project = one of these, registered
  under its own module name (no `{root, ...}` registry key needed the way
  tezcatl's `LspRegistry` has one, since a second project just means a
  second OS process on a second port).

  ## Evaluation runs off this process

  `"eval"` and `"eval/run"` (the same operation here) never evaluate
  inside a `handle_call`: a pass can take as long as its REPL boot plus
  every entry's timeout, and holding this GenServer for that long blocked
  every other request from every session and, past `GenServer.call`'s 5s,
  crashed the caller. Instead the request is answered at once with a
  `pass_id` (`"status"` `"started"` or `"queued"`), the pass runs in a
  separate process via `Runner.run/4` over a snapshot of the book, and on
  completion its results are folded into the book *as it is then* (not
  the snapshot -- other requests may have changed it meanwhile; a result
  for a row removed during the pass is dropped), persisted, and broadcast
  as the usual `notify/rowChanged` plus one `notify/passCompleted`
  (`pass_id`, `ok`, and the wire-form `result` or `error`) -- this
  server's own addition, the spec has no pass-level notify. One pass runs
  at a time; later requests queue in arrival order.

  ## So does scanning

  `"scan/run"` also runs off this process: with a language server behind
  it (`Scanner.Lsp`, possibly starting elixir-ls itself) a scan easily
  outlasts `GenServer.call`'s 5s, which used to crash the caller and hold
  every other request meanwhile. Unlike eval, the caller still gets the
  scan's own result as its reply -- the reply is just deferred until the
  scan process reports. The scan reads a snapshot of the book; its sheets,
  nodes and links are then folded into the book *as it is then*, keeping
  each surviving node's `effect`/`effect_source` from the current book (an
  `effect/set` made during the scan wins). A scan requested while one runs
  waits for it and then runs once more for every such waiter together.
  """

  use GenServer

  alias XipeTotec.{Core, Dispatch, GitCtx, InOut, Pipeline, Protocol, Runner, Store}

  @type opts :: %{
          optional(:programs) => InOut.programs(),
          optional(:eval_opts) => keyword(),
          optional(:project_id) => String.t(),
          optional(:project_dir) => Path.t(),
          root: String.t(),
          store_file: Path.t()
        }

  # the methods run as an asynchronous pass (XipeTotec.Methods' `repl`)
  @eval_methods for {name, %{repl: true}} <- XipeTotec.Methods.all(), do: name
  @all_tables [:sheets, :nodes, :calls, :links, :runs, :providers]

  @spec start_link(opts) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Register `session_pid` (a Serve.Socket, or any process wanting notify/* pushes) as attached. Idempotent."
  @spec attach(GenServer.server(), pid()) :: :ok
  def attach(pid \\ __MODULE__, session_pid), do: GenServer.call(pid, {:attach, session_pid})

  @doc """
  Which project this server has open, `%{"id" => id | nil, "root" => root}`
  -- xipe_totec picks it (`xipe choice project`), so a client such as
  tezcatl learns it from here (`initialize`'s result) rather than deciding it.
  """
  @spec info(GenServer.server()) :: map()
  def info(pid \\ __MODULE__), do: GenServer.call(pid, :info)

  @spec detach(GenServer.server(), pid()) :: :ok
  def detach(pid \\ __MODULE__, session_pid), do: GenServer.cast(pid, {:detach, session_pid})

  @doc "Run one §16.3 method call. `{:ok, result} | {:error, reason}` (both plain maps, ready for `Protocol.encode_response/2`)."
  @spec request(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  # :infinity -- a scan/run reply waits for the scan itself (see moduledoc)
  def request(pid \\ __MODULE__, method, params), do: GenServer.call(pid, {:request, method, params}, :infinity)

  @doc """
  `InOut`-routed variant of `request/3` (Old.md §17, 2026-09-20):
  threads a per-connection `dialogue` (`InOut.dialogue()`, `nil` if none
  held) through `InOut.handle/6` instead of calling `Dispatch`/`Pipeline`
  directly. `Book` mutation still happens exactly once, inside this
  GenServer's own serialized `handle_call` (same invariant `request/3` has
  -- `InOut.handle/6` itself is pure, it's only ever called from in here),
  so persisting the diff and broadcasting `notify/*` afterward works
  identically to `request/3`'s own branch, just unconditionally (an
  `InOut` outcome with `ok?: false` still leaves `Book` byte-identical, so
  diffing/broadcasting against it is a harmless no-op rather than a
  branch worth special-casing).

  `dialogue` itself is NOT this GenServer's state -- the caller
  (`Serve.Socket`, one process per connection) holds it and passes the
  updated value back on its next call, same reasoning Old.md §17
  already gave for keeping dialogue state connection-local rather than
  project-wide.
  """
  @spec request_dialogue(GenServer.server(), InOut.dialogue(), String.t(), map(), keyword()) ::
          {InOut.dialogue(), InOut.outcome()}
  def request_dialogue(pid \\ __MODULE__, dialogue, method, params, opts \\ []),
    do: GenServer.call(pid, {:request_dialogue, dialogue, method, params, opts}, :infinity)

  # ---------------------------------------------------------------------

  @impl true
  def init(%{root: root, store_file: store_file} = opts) do
    # `:programs` (InOut.programs(), default `%{}` -- no real dialogue
    # program exists yet, Old.md §16.4 step 4) is settable at
    # start_link/1 only so tests can inject a toy one (test/serve_project_test.exs);
    # a real deployment never needs to pass it.
    programs = Map.get(opts, :programs, InOut.programs())

    # `:eval_opts` goes to `Runner.run/4` for every pass (tests inject a
    # fake `:sender` here; a real deployment passes nothing).
    {:ok,
     %{
       book: Store.load(store_file),
       root: root,
       project_id: Map.get(opts, :project_id),
       # tables/project/<id>_<name>/: its saved surface table (課題 ④) and
       # environment (ProjectEnv); nil -> generated per call, xipe's own env
       project_dir: Map.get(opts, :project_dir),
       store_file: store_file,
       sessions: %{},
       programs: programs,
       eval_opts: Map.get(opts, :eval_opts, []),
       running: nil,
       queue: :queue.new(),
       scan: nil,
       scan_waiting: []
     }}
  end

  @impl true
  def handle_call({:attach, session_pid}, _from, state) do
    if Map.has_key?(state.sessions, session_pid) do
      {:reply, :ok, state}
    else
      mon = Process.monitor(session_pid)
      {:reply, :ok, put_in(state.sessions[session_pid], mon)}
    end
  end

  def handle_call(:info, _from, state), do: {:reply, %{"id" => state.project_id, "root" => state.root}, state}

  def handle_call({:request, method, params}, _from, state) when method in @eval_methods do
    case start_repl_method(method, params, state) do
      {:ok, reply, state} -> {:reply, {:ok, reply}, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:request, "scan/run", _params}, from, state),
    do: {:noreply, request_scan({from, :plain}, state)}

  def handle_call({:request, method, params}, _from, state) do
    # Pipeline-routed methods checked first, never falling through to
    # Dispatch's own @not_implemented for them (2026-09-18) -- same
    # handles?/1-then-run/4 shape Runner.run_one/4 uses for the CLI side,
    # both reading the same pipelines.json.
    result =
      if Pipeline.handles?(method) do
        Pipeline.run(method, state.book, params, %{root: state.root, project_dir: state.project_dir})
      else
        Dispatch.handle(state.book, method, params, %{root: state.root, project_dir: state.project_dir})
      end

    case result do
      {:ok, new_book, result} ->
        Store.persist_diff(state.store_file, state.book, new_book, [
          :sheets,
          :nodes,
          :calls,
          :links,
          :runs,
          :providers
        ])

        broadcast_changes(state.book, new_book, state.sessions)
        {:reply, {:ok, result}, %{state | book: new_book}}

      {:error, _book, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:request_dialogue, dialogue, method, params, _opts}, _from, state) when method in @eval_methods do
    outcome =
      case start_repl_method(method, params, state) do
        {:ok, reply, state} -> {%{hold: false, via_repl: true, text: nil, ok?: true, result: reply, error: nil}, state}
        {:error, error, state} -> {%{hold: false, via_repl: true, text: nil, ok?: false, result: nil, error: error}, state}
      end

    {outcome, state} = outcome
    {:reply, {dialogue, outcome}, state}
  end

  def handle_call({:request_dialogue, dialogue, "scan/run", _params, _opts}, from, state),
    do: {:noreply, request_scan({from, {:dialogue, dialogue}}, state)}

  def handle_call({:request_dialogue, dialogue, method, params, opts}, _from, state) do
    {new_dialogue, new_book, outcome} =
      InOut.handle(dialogue, state.book, state.root, %{"method" => method, "params" => params}, Keyword.put_new(opts, :project_dir, state.project_dir), state.programs)

    Store.persist_diff(state.store_file, state.book, new_book, [
      :sheets,
      :nodes,
      :calls,
      :links,
      :runs,
      :providers
    ])

    broadcast_changes(state.book, new_book, state.sessions)
    {:reply, {new_dialogue, outcome}, %{state | book: new_book}}
  end

  @impl true
  def handle_cast({:detach, session_pid}, state) do
    {:noreply, drop_session(session_pid, state)}
  end

  @impl true
  def handle_info({:pass_done, pass_id, outcome, ctx}, %{running: %{pass_id: pass_id, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      if outcome.ok? do
        results = Enum.filter(outcome.result["results"], &Map.has_key?(state.book.calls, &1.call_id))
        new_book = Core.apply_results(state.book, ctx, results)
        Store.persist_diff(state.store_file, state.book, new_book, [:calls])
        broadcast_changes(state.book, new_book, state.sessions)

        push(state.sessions, "notify/passCompleted", %{
          "pass_id" => pass_id,
          "ok" => true,
          "result" => Protocol.wire_result(%{outcome.result | "results" => results})
        })

        %{state | book: new_book}
      else
        push(state.sessions, "notify/passCompleted", %{"pass_id" => pass_id, "ok" => false, "error" => outcome.error})
        state
      end

    {:noreply, start_next_pass(%{state | running: nil})}
  end

  def handle_info({:scan_done, token, result}, %{scan: %{token: token, mon: mon, waiters: waiters}} = state) do
    Process.demonitor(mon, [:flush])

    state =
      case result do
        {:ok, scanned, reply} ->
          new_book = fold_scan(state.book, scanned)
          Store.persist_diff(state.store_file, state.book, new_book, @all_tables)
          broadcast_changes(state.book, new_book, state.sessions)
          reply_scan(waiters, {:ok, reply})
          %{state | book: new_book}

        {:error, _book, error} ->
          reply_scan(waiters, {:error, error})
          state
      end

    {:noreply, start_waiting_scan(%{state | scan: nil})}
  end

  # the scan process died without reporting (e.g. no scanner could start)
  def handle_info({:DOWN, mon, :process, _pid, reason}, %{scan: %{mon: mon, waiters: waiters}} = state) do
    reply_scan(waiters, {:error, %{"code" => "scan_failed", "message" => inspect(reason)}})
    {:noreply, start_waiting_scan(%{state | scan: nil})}
  end

  # the pass process died without reporting (a crash inside Runner/Evaluator)
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref, pass_id: pass_id}} = state) do
    push(state.sessions, "notify/passCompleted", %{
      "pass_id" => pass_id,
      "ok" => false,
      "error" => %{"code" => "eval_failed", "message" => inspect(reason)}
    })

    {:noreply, start_next_pass(%{state | running: nil})}
  end

  def handle_info({:DOWN, mon, :process, session_pid, _reason}, state) do
    if Map.get(state.sessions, session_pid) == mon do
      {:noreply, drop_session(session_pid, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop_session(session_pid, state), do: %{state | sessions: Map.delete(state.sessions, session_pid)}

  # A REPL method (XipeTotec.Methods' `repl`): a pipelines.json method's
  # stages before "eval" run here at once, their changes persisted and
  # broadcast like any request's; the "eval" stage -- or a plain "eval" --
  # goes to the pass queue (Old.md §37). The reply merges both: e.g.
  # row/update's edited row plus the pass id.
  defp start_repl_method(method, params, state) do
    prepared =
      if Pipeline.handles?(method),
        do: Pipeline.prepare(method, state.book, params, %{root: state.root, project_dir: state.project_dir}),
        else: {:ok, state.book, %{}, params}

    case prepared do
      {:ok, new_book, result, eval_params} ->
        if new_book != state.book do
          Store.persist_diff(state.store_file, state.book, new_book, @all_tables)
          broadcast_changes(state.book, new_book, state.sessions)
        end

        state = %{state | book: new_book}

        case eval_params do
          nil ->
            {:ok, result, state}

          eval_params ->
            {reply, state} = enqueue_pass(eval_params, state)
            {:ok, Map.merge(result, reply), state}
        end

      {:error, _book, error} ->
        {:error, error, state}
    end
  end

  defp enqueue_pass(params, state) do
    pass_id = XipeTotec.Id.ulid()
    status = if state.running, do: "queued", else: "started"
    state = start_next_pass(%{state | queue: :queue.in({pass_id, params}, state.queue)})
    {%{"pass_id" => pass_id, "status" => status}, state}
  end

  defp start_next_pass(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {pass_id, params}}, rest} ->
        server = self()
        %{book: book, root: root, eval_opts: eval_opts} = state
        eval_opts = Keyword.put_new(eval_opts, :project_dir, state.project_dir)

        {pid, ref} =
          spawn_monitor(fn ->
            # read per pass: the working tree may have moved since the server started
            ctx = Keyword.get_lazy(eval_opts, :ctx, fn -> GitCtx.read(root) end)
            {_book, [outcome]} = Runner.run(book, root, [%{"method" => "eval", "params" => params}], Keyword.put(eval_opts, :ctx, ctx))
            send(server, {:pass_done, pass_id, outcome, ctx})
          end)

        %{state | queue: rest, running: %{pass_id: pass_id, pid: pid, ref: ref}}

      {:empty, _} ->
        state
    end
  end

  defp start_next_pass(state), do: state

  defp request_scan(waiter, %{scan: nil} = state), do: start_scan([waiter], state)
  defp request_scan(waiter, state), do: %{state | scan_waiting: state.scan_waiting ++ [waiter]}

  defp start_waiting_scan(%{scan_waiting: []} = state), do: state
  defp start_waiting_scan(state), do: start_scan(state.scan_waiting, %{state | scan_waiting: []})

  defp start_scan(waiters, state) do
    server = self()
    %{book: book, root: root, project_dir: project_dir} = state

    token = make_ref()
    ctx = %{root: root, project_dir: project_dir}
    {_pid, mon} = spawn_monitor(fn -> send(server, {:scan_done, token, Dispatch.handle(book, "scan/run", %{}, ctx)}) end)
    %{state | scan: %{token: token, mon: mon, waiters: waiters}}
  end

  # the scan owns sheets/nodes/links; everything else is the current book's
  defp fold_scan(book, scanned) do
    nodes =
      Map.new(scanned.nodes, fn {id, row} ->
        case Map.get(book.nodes, id) do
          nil -> {id, row}
          current -> {id, Map.merge(row, Map.take(current, [:effect, :effect_source]))}
        end
      end)

    %{book | sheets: scanned.sheets, nodes: nodes, links: scanned.links}
  end

  defp reply_scan(waiters, reply) do
    for {from, kind} <- waiters do
      case {kind, reply} do
        {:plain, _} ->
          GenServer.reply(from, reply)

        {{:dialogue, dialogue}, {:ok, result}} ->
          GenServer.reply(from, {dialogue, %{hold: false, via_repl: false, text: nil, ok?: true, result: result, error: nil}})

        {{:dialogue, dialogue}, {:error, error}} ->
          GenServer.reply(from, {dialogue, %{hold: false, via_repl: false, text: nil, ok?: false, result: nil, error: error}})
      end
    end
  end

  # notify/rowChanged and notify/nodeChanged only -- the spec has no
  # "removed" notify method, so a tombstoned id (row/remove, or a rescan
  # dropping a node) is persisted (above) but not itself pushed as a
  # notification in this v0 (Old.md §9 known gap, not yet designed).
  defp broadcast_changes(old_book, new_book, sessions) do
    for {id, row} <- new_book.nodes, Map.get(old_book.nodes, id) != row do
      push(sessions, "notify/nodeChanged", %{"id" => id, "row" => row})
    end

    for {id, row} <- new_book.calls, Map.get(old_book.calls, id) != row do
      old_row = Map.get(old_book.calls, id)
      push(sessions, "notify/rowChanged", %{"id" => id, "columns" => changed_columns(old_row, row), "row" => row})
    end
  end

  defp changed_columns(nil, new_row), do: Map.keys(new_row)

  defp changed_columns(old_row, new_row),
    do: Enum.filter(Map.keys(new_row), fn k -> Map.get(old_row, k) != Map.get(new_row, k) end)

  defp push(sessions, method, params) do
    text = Protocol.encode_notify(method, params)
    for {session_pid, _mon} <- sessions, do: send(session_pid, {:xipe_out, text})
  end
end
