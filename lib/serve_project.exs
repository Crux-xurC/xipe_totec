Code.require_file("book.exs", __DIR__)
Code.require_file("store.exs", __DIR__)
Code.require_file("dispatch.exs", __DIR__)
Code.require_file("pipeline.exs", __DIR__)
Code.require_file("protocol.exs", __DIR__)
Code.require_file("in_out.exs", __DIR__)

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
  """

  use GenServer

  alias XipeTotec.{Dispatch, InOut, Pipeline, Protocol, Store}

  @type opts :: %{optional(:programs) => InOut.programs(), root: String.t(), store_file: Path.t()}

  @spec start_link(opts) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Register `session_pid` (a Serve.Socket, or any process wanting notify/* pushes) as attached. Idempotent."
  @spec attach(GenServer.server(), pid()) :: :ok
  def attach(pid \\ __MODULE__, session_pid), do: GenServer.call(pid, {:attach, session_pid})

  @spec detach(GenServer.server(), pid()) :: :ok
  def detach(pid \\ __MODULE__, session_pid), do: GenServer.cast(pid, {:detach, session_pid})

  @doc "Run one §16.3 method call. `{:ok, result} | {:error, reason}` (both plain maps, ready for `Protocol.encode_response/2`)."
  @spec request(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  def request(pid \\ __MODULE__, method, params), do: GenServer.call(pid, {:request, method, params})

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
    do: GenServer.call(pid, {:request_dialogue, dialogue, method, params, opts})

  # ---------------------------------------------------------------------

  @impl true
  def init(%{root: root, store_file: store_file} = opts) do
    # `:programs` (InOut.programs(), default `%{}` -- no real dialogue
    # program exists yet, Old.md §16.4 step 4) is settable at
    # start_link/1 only so tests can inject a toy one (test/serve_project_test.exs);
    # a real deployment never needs to pass it.
    programs = Map.get(opts, :programs, InOut.programs())
    {:ok, %{book: Store.load(store_file), root: root, store_file: store_file, sessions: %{}, programs: programs}}
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

  def handle_call({:request, method, params}, _from, state) do
    # Pipeline-routed methods checked first, never falling through to
    # Dispatch's own @not_implemented for them (2026-09-18) -- same
    # handles?/1-then-run/4 shape Runner.run_one/4 uses for the CLI side,
    # both reading the same pipelines.json.
    result =
      if Pipeline.handles?(method) do
        Pipeline.run(method, state.book, params, %{root: state.root})
      else
        Dispatch.handle(state.book, method, params, %{root: state.root})
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

  def handle_call({:request_dialogue, dialogue, method, params, opts}, _from, state) do
    {new_dialogue, new_book, outcome} =
      InOut.handle(dialogue, state.book, state.root, %{"method" => method, "params" => params}, opts, state.programs)

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
  def handle_info({:DOWN, mon, :process, session_pid, _reason}, state) do
    if Map.get(state.sessions, session_pid) == mon do
      {:noreply, drop_session(session_pid, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop_session(session_pid, state), do: %{state | sessions: Map.delete(state.sessions, session_pid)}

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
