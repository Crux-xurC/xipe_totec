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
  One project, one GenServer: the one place in the server that holds
  mutable state (`Book`). Everything else (`Dispatch`, `Address`, `Core`,
  ...) stays a pure function over a `Book` it's handed.

  Runs a `Dispatch.handle/4` call (or, for a method `Pipeline.handles?/1`
  says yes to, `Pipeline` -- checked first), persists the difference
  between the `Book` before and after (`Store`, all six tables), and
  broadcasts `notify/rowChanged` / `notify/nodeChanged` for whatever
  changed to every attached session. Request ids are not rewritten: every
  attached client sees every broadcast and picks what it needs.

  One `xipe start` process = one project = one of these, registered under
  its own module name (a second project is a second OS process on a second
  port).

  ## Evaluation runs off this process

  `"eval"` and `"eval/run"` (the same operation here) never evaluate
  inside a `handle_call`: a pass can take as long as its REPL boot plus
  every entry's timeout, which would hold every other request from every
  session and outlast `GenServer.call`'s 5s. The request is answered at
  once with a `pass_id` (`"status"` `"started"` or `"queued"`), the pass
  runs in a separate process via `Runner.run/4` over a snapshot of the
  book, and on completion its results are folded into the book *as it is
  then* (not the snapshot -- other requests may have changed it meanwhile;
  a result for a row removed during the pass is dropped), persisted, and
  broadcast as the usual `notify/rowChanged` plus one
  `notify/passCompleted` (`pass_id`, `ok`, and the wire-form `result` or
  `error`). One pass runs at a time; later requests queue in arrival
  order.

  `"eval/cancel"` stops a pass: one still in the queue is taken out here
  (and reported as any ended pass is, `notify/passCompleted` with the
  `cancelled` error); the running one is asked to stop (`XipeTotec.Passes`'
  "Stopping a pass") and ends itself a moment later, through the usual
  completion above. A pass another process runs (the CLI's `xipe eval`) is
  `Dispatch`'s to ask.

  ## So does scanning

  `"scan/run"` also runs off this process: with a language server behind
  it (`Scanner.Lsp`, possibly starting elixir-ls itself) a scan easily
  outlasts `GenServer.call`'s 5s. Unlike eval, the caller still gets the
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

  @doc "The book as it is now (the dialogue window's `show`, `Serve.Input`)."
  @spec book(GenServer.server()) :: XipeTotec.Book.t()
  def book(pid \\ __MODULE__), do: GenServer.call(pid, :book)

  @spec detach(GenServer.server(), pid()) :: :ok
  def detach(pid \\ __MODULE__, session_pid), do: GenServer.cast(pid, {:detach, session_pid})

  @doc "Run one method call. `{:ok, result} | {:error, reason}` (both plain maps, ready for `Protocol.encode_response/2`)."
  @spec request(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  # :infinity -- a scan/run reply waits for the scan itself (see moduledoc)
  def request(pid \\ __MODULE__, method, params), do: GenServer.call(pid, {:request, method, params}, :infinity)

  @doc """
  `InOut`-routed variant of `request/3`: threads a per-connection
  `dialogue` (`InOut.dialogue()`, `nil` if none held) through
  `InOut.handle/6` instead of calling `Dispatch`/`Pipeline` directly. The
  `Book` still changes only inside this GenServer's serialized
  `handle_call`; the diff is persisted and `notify/*` broadcast as for
  `request/3` (an outcome with `ok?: false` leaves the `Book` unchanged, so
  that is a no-op).

  `dialogue` is not this GenServer's state: the caller (`Serve.Socket`, one
  process per connection) holds it and passes the updated value back on
  its next call.

  `opts[:watch]` (a pid): when `method` starts an evaluation pass, that
  process is also sent `{:xipe_pass_done, pass_id, outcome}` when the pass
  ends -- `outcome` in `Runner.run/4`'s shape, its results limited to the
  rows still in the book (`Serve.Input` waits for a pass before running
  the rest of a typed line). Registered in the same
  call that queues the pass, so it can't miss a pass that ends at once.
  """
  @spec request_dialogue(GenServer.server(), InOut.dialogue(), String.t(), map(), keyword()) ::
          {InOut.dialogue(), InOut.outcome()}
  def request_dialogue(pid \\ __MODULE__, dialogue, method, params, opts \\ []),
    do: GenServer.call(pid, {:request_dialogue, dialogue, method, params, opts}, :infinity)

  # ---------------------------------------------------------------------

  @impl true
  def init(%{root: root, store_file: store_file} = opts) do
    # the book, and the byte position read up to: later writes catch up from it
    # with what the CLI appended meanwhile (Store.persist_diff_since/5)
    {book, store_pos} = Store.load_with_pos(store_file)

    # `:programs` (default InOut.programs()) is settable so tests can
    # inject a toy dialogue program.
    programs = Map.get(opts, :programs, InOut.programs())

    # `:eval_opts` goes to `Runner.run/4` for every pass (tests inject a
    # fake `:sender` here; a real deployment passes nothing).
    {:ok,
     %{
       book: book,
       store_pos: store_pos,
       root: root,
       project_id: Map.get(opts, :project_id),
       # tables/project/<id>_<name>/: its saved surface table and
       # environment (ProjectEnv); nil -> generated per call, xipe's own env
       project_dir: Map.get(opts, :project_dir),
       store_file: store_file,
       sessions: %{},
       programs: programs,
       eval_opts: Map.get(opts, :eval_opts, []),
       running: nil,
       queue: :queue.new(),
       # pass_id => the pid told when that pass ends (request_dialogue/5's :watch)
       watchers: %{},
       scan: nil,
       scan_waiting: []
     }}
  end

  # A request whose handling raises (a method given a value it has no clause
  # for, a book.jsonl lock that never came free ...) is answered with
  # `internal_error`, and the book stays as it was: this process is linked to
  # `xipe start` itself, so letting it die took the whole server -- every
  # window's connection, the pass queue, a held dialogue -- down with one
  # line. Anything else that raises is a bug in here: let it show.
  @impl true
  def handle_call(msg, from, state) do
    call(msg, from, caught_up(msg, state))
  rescue
    e -> raised(msg, Exception.format(:error, e, __STACKTRACE__), state, e, __STACKTRACE__)
  end

  defp raised({:request, method, _params}, text, state, _e, _trace) do
    IO.puts(:stderr, "xipe start: #{method} raised -- answered internal_error\n#{text}")
    {:reply, {:error, internal_error(method, text)}, state}
  end

  defp raised({:request_dialogue, dialogue, method, _params, _opts}, text, state, _e, _trace) do
    IO.puts(:stderr, "xipe start: #{method} raised -- answered internal_error\n#{text}")
    outcome = %{hold: dialogue != nil, via_repl: false, text: nil, ok?: false, result: nil, error: internal_error(method, text)}
    {:reply, {dialogue, outcome}, state}
  end

  defp raised(_msg, _text, _state, e, trace), do: reraise(e, trace)

  # the first line says what; the rest (the stack) is in the server's own output
  defp internal_error(method, text) do
    %{"code" => "internal_error", "message" => "#{method}: " <> (text |> String.split("\n") |> hd()) <> " -- an error inside xipe_totec. Nothing was changed"}
  end

  # Before a request reads the book, what the CLI appended to book.jsonl
  # since this server last read is folded in (and broadcast, as any change
  # is), so a scan or a read never works from a book that missed the CLI's
  # rows. One stat when nothing came.
  defp caught_up(msg, state) when msg == :book or (is_tuple(msg) and elem(msg, 0) in [:request, :request_dialogue]) do
    case Store.read_since(state.store_file, state.store_pos, state.book) do
      {_book, pos} when pos == state.store_pos ->
        state

      {book, pos} ->
        broadcast_changes(state.book, book, state.sessions)
        %{state | book: book, store_pos: pos}
    end
  end

  defp caught_up(_msg, state), do: state

  defp call({:attach, session_pid}, _from, state) do
    if Map.has_key?(state.sessions, session_pid) do
      {:reply, :ok, state}
    else
      mon = Process.monitor(session_pid)
      {:reply, :ok, put_in(state.sessions[session_pid], mon)}
    end
  end

  defp call(:info, _from, state), do: {:reply, %{"id" => state.project_id, "root" => state.root}, state}
  defp call(:book, _from, state), do: {:reply, state.book, state}

  defp call({:request, method, params}, _from, state) when method in @eval_methods do
    case start_repl_method(method, params, nil, state) do
      {:ok, reply, state} -> {:reply, {:ok, reply}, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  defp call({:request, "scan/run", _params}, from, state),
    do: {:noreply, request_scan({from, :plain}, state)}

  # eval/status: the running passes (files, Dispatch) plus this server's queue
  defp call({:request, "eval/status", params}, _from, state) do
    {:ok, _book, result} = Dispatch.handle(state.book, "eval/status", params, %{root: state.root, project_dir: state.project_dir})
    {:reply, {:ok, Map.put(result, "queued", queued(state))}, state}
  end

  defp call({:request, "eval/cancel", params}, _from, state) do
    {reply, state} = cancel_pass(params, state)
    {:reply, reply, state}
  end

  defp call({:request, method, params}, _from, state) do
    # Pipeline-routed methods checked first, never falling through to
    # Dispatch's own @not_implemented for them -- same
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
        {new_book, state} = persist(state, new_book, [
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

  defp call({:request_dialogue, dialogue, method, params, opts}, _from, state) when method in @eval_methods do
    outcome =
      case start_repl_method(method, params, opts[:watch], state) do
        {:ok, reply, state} -> {%{hold: false, via_repl: true, text: nil, ok?: true, result: reply, error: nil}, state}
        {:error, error, state} -> {%{hold: false, via_repl: true, text: nil, ok?: false, result: nil, error: error}, state}
      end

    {outcome, state} = outcome
    {:reply, {dialogue, outcome}, state}
  end

  defp call({:request_dialogue, dialogue, "eval/status", params, _opts}, _from, state) do
    {:ok, _book, result} = Dispatch.handle(state.book, "eval/status", params, %{root: state.root, project_dir: state.project_dir})
    result = Map.put(result, "queued", queued(state))
    {:reply, {dialogue, %{hold: false, via_repl: false, text: nil, ok?: true, result: result, error: nil}}, state}
  end

  defp call({:request_dialogue, dialogue, "eval/cancel", params, _opts}, _from, state) do
    {reply, state} = cancel_pass(params, state)

    outcome =
      case reply do
        {:ok, result} -> %{hold: false, via_repl: false, text: nil, ok?: true, result: result, error: nil}
        {:error, error} -> %{hold: false, via_repl: false, text: nil, ok?: false, result: nil, error: error}
      end

    {:reply, {dialogue, outcome}, state}
  end

  defp call({:request_dialogue, dialogue, "scan/run", _params, _opts}, from, state),
    do: {:noreply, request_scan({from, {:dialogue, dialogue}}, state)}

  defp call({:request_dialogue, dialogue, method, params, opts}, _from, state) do
    {new_dialogue, new_book, outcome} =
      InOut.handle(dialogue, state.book, state.root, %{"method" => method, "params" => params}, Keyword.put_new(opts, :project_dir, state.project_dir), state.programs)

    {new_book, state} = persist(state, new_book, [
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
    # a request to stop it that came too late to matter
    XipeTotec.Passes.cancel_done(state.project_dir, pass_id)

    state =
      if outcome.ok? do
        results = Enum.filter(outcome.result["results"], &Map.has_key?(state.book.calls, &1.call_id))
        new_book = Core.apply_results(state.book, ctx, results)
        {new_book, state} = persist(state, new_book, [:calls])
        broadcast_changes(state.book, new_book, state.sessions)

        push(state.sessions, "notify/passCompleted", %{
          "pass_id" => pass_id,
          "ok" => true,
          "result" => Protocol.wire_result(%{outcome.result | "results" => results})
        })

        tell_watcher(%{state | book: new_book}, pass_id, %{outcome | result: %{outcome.result | "results" => results}})
      else
        push(state.sessions, "notify/passCompleted", %{"pass_id" => pass_id, "ok" => false, "error" => outcome.error})
        tell_watcher(state, pass_id, outcome)
      end

    {:noreply, start_next_pass(%{state | running: nil})}
  end

  def handle_info({:scan_done, token, result}, %{scan: %{token: token, mon: mon, waiters: waiters}} = state) do
    Process.demonitor(mon, [:flush])

    state =
      case result do
        {:ok, scanned, reply} ->
          new_book = fold_scan(state.book, scanned)
          {new_book, state} = persist(state, new_book, @all_tables)
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
    # died without Runner's own cleanup: its running records would look
    # alive (this OS process lives on) and keep its rows locked
    XipeTotec.Passes.clear(state.project_dir, pass_id)
    error = %{"code" => "eval_failed", "message" => inspect(reason)}
    push(state.sessions, "notify/passCompleted", %{"pass_id" => pass_id, "ok" => false, "error" => error})
    state = tell_watcher(state, pass_id, %{method: "eval", ok?: false, result: nil, error: error})
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
  # goes to the pass queue. The reply merges both: e.g.
  # row/update's edited row plus the pass id.
  defp start_repl_method(method, params, watcher, state) do
    prepared =
      if Pipeline.handles?(method),
        do: Pipeline.prepare(method, state.book, params, %{root: state.root, project_dir: state.project_dir}),
        else: {:ok, state.book, %{}, params}

    case prepared do
      {:ok, new_book, result, eval_params} ->
        {new_book, state} =
          if new_book != state.book do
            {written, st} = persist(state, new_book, @all_tables)
            broadcast_changes(state.book, written, state.sessions)
            {written, st}
          else
            {new_book, state}
          end

        state = %{state | book: new_book}

        case eval_params do
          nil ->
            {:ok, result, state}

          eval_params ->
            {reply, state} = enqueue_pass(eval_params, watcher, state)
            {:ok, Map.merge(result, reply), state}
        end

      {:error, _book, error} ->
        {:error, error, state}
    end
  end

  defp enqueue_pass(params, watcher, state) do
    pass_id = XipeTotec.Id.ulid()
    status = if state.running, do: "queued", else: "started"
    state = if watcher, do: put_in(state.watchers[pass_id], watcher), else: state
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
            # the pass is recorded under this pass_id (XipeTotec.Passes), so
            # the DOWN handler below can clear it if this process dies
            eval_opts = eval_opts |> Keyword.put(:ctx, ctx) |> Keyword.put(:pass_id, pass_id)
            {_book, [outcome]} = Runner.run(book, root, [%{"method" => "eval", "params" => params}], eval_opts)
            send(server, {:pass_done, pass_id, outcome, ctx})
          end)

        %{state | queue: rest, running: %{pass_id: pass_id, pid: pid, ref: ref}}

      {:empty, _} ->
        state
    end
  end

  defp start_next_pass(state), do: state

  defp queued(state) do
    for {pass_id, params} <- :queue.to_list(state.queue),
        do: %{"pass_id" => pass_id, "call_ids" => List.wrap(params["call_ids"])}
  end

  # eval/cancel: this server's queue and running pass first, then whatever
  # else runs on the project (Dispatch -- a CLI's pass)
  defp cancel_pass(params, state) do
    id = if is_map(params), do: params["pass_id"]
    queued? = is_binary(id) and Enum.any?(:queue.to_list(state.queue), fn {pass_id, _} -> pass_id == id end)

    cond do
      # still waiting: out of the queue, and reported as an ended pass is
      queued? ->
        error = XipeTotec.Passes.cancelled_error()
        queue = :queue.filter(fn {pass_id, _} -> pass_id != id end, state.queue)
        push(state.sessions, "notify/passCompleted", %{"pass_id" => id, "ok" => false, "error" => error})
        state = tell_watcher(%{state | queue: queue}, id, %{method: "eval", ok?: false, result: nil, error: error})
        {{:ok, %{"pass_id" => id, "status" => "dequeued"}}, state}

      # the running one: asked here, without waiting for its record (which
      # is written only once its REPL is prepared)
      state.running != nil and state.project_dir != nil and id in [nil, state.running.pass_id] ->
        XipeTotec.Passes.request_cancel(state.project_dir, state.running.pass_id)
        {{:ok, %{"pass_id" => state.running.pass_id, "status" => "cancelling"}}, state}

      true ->
        case Dispatch.handle(state.book, "eval/cancel", params, %{root: state.root, project_dir: state.project_dir}) do
          {:ok, _book, result} -> {{:ok, result}, state}
          {:error, _book, error} -> {{:error, error}, state}
        end
    end
  end

  defp tell_watcher(state, pass_id, outcome) do
    {watcher, watchers} = Map.pop(state.watchers, pass_id)
    if watcher, do: send(watcher, {:xipe_pass_done, pass_id, outcome})
    %{state | watchers: watchers}
  end

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

  # notify/rowChanged and notify/nodeChanged only: a removed id (row/remove,
  # or a rescan dropping a node) is persisted but not pushed.
  # A change written under the Store's lock (Store.persist_diff_since/5): what
  # others -- the CLI -- appended since this server last read is folded in
  # first, so the book kept here and broadcast is the file's.
  # -> {the book to keep and broadcast, state with the new store_pos}
  defp persist(state, new_book, tables) do
    {book, pos} = Store.persist_diff_since(state.store_file, state.store_pos, state.book, new_book, tables)
    {book, %{state | store_pos: pos}}
  end

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
