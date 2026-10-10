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

  @doc "The book as it is now (the dialogue window's `show`, `Serve.Input`)."
  @spec book(GenServer.server()) :: XipeTotec.Book.t()
  def book(pid \\ __MODULE__), do: GenServer.call(pid, :book)

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

  `opts[:watch]` (a pid): when `method` starts an evaluation pass, that
  process is also sent `{:xipe_pass_done, pass_id, outcome}` when the pass
  ends -- `outcome` in `Runner.run/4`'s shape, its results limited to the
  rows still in the book (2026-09-27, for `Serve.Input`, which waits for
  a pass before running the rest of a typed line). Registered in the same
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
    # with what the CLI appended meanwhile (Store.persist_diff_since/5, 2026-10-09)
    {book, store_pos} = Store.load_with_pos(store_file)

    # `:programs` (InOut.programs(), default `%{}` -- no real dialogue
    # program exists yet, Old.md §16.4 step 4) is settable at
    # start_link/1 only so tests can inject a toy one (test/serve_project_test.exs);
    # a real deployment never needs to pass it.
    programs = Map.get(opts, :programs, InOut.programs())

    # `:eval_opts` goes to `Runner.run/4` for every pass (tests inject a
    # fake `:sender` here; a real deployment passes nothing).
    {:ok,
     %{
       book: book,
       store_pos: store_pos,
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
  # line (Old.md §56). Anything else that raises is a bug in here: let it show.
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
    %{"code" => "internal_error", "message" => "#{method}: " <> (text |> String.split("\n") |> hd()) <> " ── xipe_totec の中の誤りです。何も変えていません"}
  end

  # Before a request reads the book, what the CLI appended to book.jsonl
  # since this server last read is folded in (and broadcast, as any change
  # is): a scan started from a book that had not seen the CLI's scan minted
  # a second node for a function the CLI had already given an id, and the
  # first read after a CLI change answered from the old book (Old.md §56;
  # until then only a write caught up, §55). One stat when nothing came.
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

  defp call({:request, method, params}, _from, state) do
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
  # goes to the pass queue (Old.md §37). The reply merges both: e.g.
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

  # notify/rowChanged and notify/nodeChanged only -- the spec has no
  # "removed" notify method, so a tombstoned id (row/remove, or a rescan
  # dropping a node) is persisted (above) but not itself pushed as a
  # notification in this v0 (Old.md §9 known gap, not yet designed).
  # A change written under the Store's lock (Store.persist_diff_since/5): what
  # others -- the CLI -- appended since this server last read is folded in
  # first, so the book kept here and broadcast is the file's, not one that
  # missed their rows until a restart (課題 "CLIとサーバーの同時書き込み",
  # crux 2026-10-06/10-09). -> {the book to keep and broadcast, state with the new store_pos}
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
