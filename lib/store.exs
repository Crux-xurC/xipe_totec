Code.require_file("book.exs", __DIR__)
Code.require_file("session.exs", __DIR__)

defmodule XipeTotec.Store do
  @moduledoc """
  Append-only JSON Lines persistence. One row per
  line, tagged by `type`; the same logical entity may appear on many lines
  over time (an evaluation, an edit, a removal each append a fresh line) --
  the *last* line for a given `{type, id}` pair wins when folding into a
  `Book` (append-log / event-sourcing style, not in-place rewrite).

  A row with `deleted: true` removes that id from the table on fold (the
  tombstone convention used for `row/remove` and for a link edge that
  disappeared on rescan). This is a Store-level convention, separate from a
  node/sheet row's own `status: tombstone`.

  `compact/1` (rewrite the file to hold just the current folded state) is
  the one sanctioned exception to "never rewrite".

  Writers: every write holds `<path>.lock` (`with_lock/3`), so the CLI and a running
  server never interleave their lines. The lock names its owner by
  `os_pid` + `os_started` (`XipeTotec.Session.owner/0`), as `passes/` and
  `session.json` do; a lock whose owner is gone is taken over. A writer
  that keeps the book in memory (the server) catches up with what others
  appended since it last read (`persist_diff_since/5`) before it writes.
  And a write never follows a line cut off by a crash: the file is made to
  end in a newline first, so the cut line stays one bad line (skipped on
  load) instead of swallowing the next.
  """

  alias XipeTotec.Book

  @tables %{
    "sheet" => :sheets,
    "node" => :nodes,
    "call" => :calls,
    "link" => :links,
    "run" => :runs,
    "provider" => :providers
  }
  @table_types Map.new(@tables, fn {type, table} -> {table, type} end)

  @doc "Append one row (atom-keyed map, must include `:type` and `:id`) to the log at `path`."
  @spec append(Path.t(), map()) :: :ok
  def append(path, row) when is_map(row) do
    with_lock(path, fn -> write_lines(path, line(row)) end)
  end

  # under the lock: after a newline, whatever the last write left
  defp write_lines(path, lines) do
    ensure_newline(path)
    File.write!(path, lines, [:append])
    :ok
  end

  # a file whose last line was cut off (a crash mid-write) gets its newline,
  # so what is appended next starts a line of its own
  defp ensure_newline(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: n}} when n > 0 ->
        {:ok, io} = :file.open(path, [:read, :binary])
        last = :file.pread(io, n - 1, 1)
        :file.close(io)
        if last != {:ok, "\n"}, do: File.write!(path, "\n", [:append])

      _ ->
        :ok
    end
  end

  @lock_wait_ms 10_000

  @doc """
  Run `fun` holding the write lock of `path` (`<path>.lock`, holding this
  OS process's `os_pid` + `os_started`). Waits up to `wait_ms` for another
  owner; a lock whose owner is gone is taken over. -> what `fun` returns
  """
  def with_lock(path, fun, wait_ms \\ @lock_wait_ms) do
    lock = path <> ".lock"
    acquire(lock, System.monotonic_time(:millisecond) + wait_ms)

    try do
      fun.()
    after
      File.rm(lock)
    end
  end

  defp acquire(lock, deadline) do
    case File.write(lock, JSON.encode!(owner()), [:exclusive]) do
      :ok ->
        :ok

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(lock))
        acquire(lock, deadline)

      {:error, :eexist} ->
        held = File.read(lock)

        cond do
          stale?(held) ->
            # gone owner: taken over -- unless it changed meanwhile (another took it first)
            if File.read(lock) == held, do: File.rm(lock)
            acquire(lock, deadline)

          System.monotonic_time(:millisecond) > deadline ->
            raise "xipe: #{lock} is held by another process (#{inspect(held)}) -- waited #{@lock_wait_ms} ms"

          true ->
            Process.sleep(10)
            acquire(lock, deadline)
        end

      {:error, reason} ->
        raise "xipe: cannot take #{lock}: #{inspect(reason)}"
    end
  end

  # a lock whose owner is no longer running (an empty one is being written: not stale)
  defp stale?({:ok, ""}), do: false

  defp stale?({:ok, text}) do
    case JSON.decode(text) do
      {:ok, rec} when is_map(rec) -> not XipeTotec.Session.same_process?(rec)
      _ -> true
    end
  end

  defp stale?(_), do: false

  # this OS process as an owner: asked once (it runs ps)
  defp owner do
    case :persistent_term.get({__MODULE__, :owner}, nil) do
      nil ->
        o = XipeTotec.Session.owner()
        :persistent_term.put({__MODULE__, :owner}, o)
        o

      o ->
        o
    end
  end

  defp line(row), do: (row |> stringify_keys() |> JSON.encode!()) <> "\n"

  @doc """
  Load `path` into a fresh `Book`, folding rows in file order. Ignores
  blank lines, unrecognized `type`s, and a truncated/corrupt line (e.g. from
  a crash mid-write) rather than raising.
  """
  @spec load(Path.t()) :: Book.t()
  def load(path) do
    if File.exists?(path) do
      path |> File.stream!() |> Enum.reduce(Book.new(), &fold_line/2)
    else
      Book.new()
    end
  end

  @doc """
  `load/1` and the byte position after the last whole line read -- where a
  later `persist_diff_since/5` goes on reading what others appended (a line
  still being written is left for then). -> {book, pos}
  """
  def load_with_pos(path), do: catch_up(path, 0, Book.new())

  @doc """
  What others appended to `path` since `pos`, folded into `book` -- for a
  writer that keeps the book in memory (the server) to catch up before it
  *uses* the book, not only before it writes. No lock: only
  whole lines are read, so a line still being written is left for the next
  time. -> {book, the new pos} (the same `pos` when nothing came)
  """
  def read_since(path, pos, book), do: catch_up(path, pos, book)

  # the whole lines from `pos` on, folded into `book` -> {book, pos after them}.
  # A file shorter than `pos` was rewritten (compact): read from the start, afresh.
  defp catch_up(path, pos, book) do
    case File.stat(path) do
      {:ok, %File.Stat{size: n}} when n < pos ->
        catch_up(path, 0, Book.new())

      {:ok, %File.Stat{size: n}} when n > pos ->
        {:ok, io} = :file.open(path, [:read, :binary])
        {:ok, bytes} = :file.pread(io, pos, n - pos)
        :file.close(io)

        case :binary.matches(bytes, "\n") do
          [] ->
            {book, pos}

          ms ->
            {last, 1} = List.last(ms)
            whole = binary_part(bytes, 0, last + 1)
            {whole |> String.split("\n") |> Enum.reduce(book, &fold_line/2), pos + last + 1}
        end

      _ ->
        {book, pos}
    end
  end

  defp fold_line(line, book) do
    line = String.trim(line)

    with true <- line != "",
         {:ok, %{"type" => type, "id" => id} = decoded} <- JSON.decode(line),
         {:ok, table} <- Map.fetch(@tables, type) do
      row = decoded |> Map.drop(["type", "id"]) |> atomize_keys() |> upgrade(table)

      if row[:deleted] do
        Book.delete(book, table, id)
      else
        Book.put(book, table, id, row)
      end
    else
      _ -> book
    end
  end

  @doc """
  Append to the Store at `path` only the rows in `tables` that are new or
  changed between `old_book` and `new_book`, and tombstone (`deleted: true`)
  any that disappeared. Used for a scan (`Project.persist_scan/3`) and for
  the effect of any `Dispatch.handle/4` call in `Serve.Project`.
  """
  @spec persist_diff(Path.t(), Book.t(), Book.t(), [Book.table()]) :: :ok
  def persist_diff(path, old_book, new_book, tables) do
    # all the changed rows in one append (a scan can change hundreds), in a
    # fixed order
    lines = diff_lines(old_book, new_book, tables)
    if lines != [], do: with_lock(path, fn -> write_lines(path, lines) end)
    :ok
  end

  @doc """
  `persist_diff/4` for a writer that keeps the book in memory (the server):
  under the lock, the lines others appended since `pos` are folded in first,
  then this diff is written -- and wins where both changed the same row.
  -> {the book as the file now has it, the new pos}
  """
  def persist_diff_since(path, pos, old_book, new_book, tables) do
    lines = diff_lines(old_book, new_book, tables)

    with_lock(path, fn ->
      {caught, at} = catch_up(path, pos, new_book)
      # ours over theirs: this diff folded again on top of what came in
      merged = lines |> Enum.map(&String.trim_trailing/1) |> Enum.reduce(caught, &fold_line/2)

      if lines == [] do
        {merged, at}
      else
        write_lines(path, lines)
        # what was just written (and anything before it) is read: past it
        {_, end_pos} = catch_up(path, at, Book.new())
        {merged, end_pos}
      end
    end)
  end

  defp diff_lines(old_book, new_book, tables) do
      for table <- tables,
          old_table = Map.fetch!(old_book, table),
          new_table = Map.fetch!(new_book, table),
          type = Map.fetch!(@table_types, table),
          row <-
            (for {id, row} <- new_table, Map.get(old_table, id) != row, do: row |> Map.put(:type, type) |> Map.put(:id, id)) ++
              (for {id, _row} <- old_table, not Map.has_key?(new_table, id), do: %{type: type, id: id, deleted: true}) do
        line(row)
      end
  end

  @doc "Rewrite `path` to hold only the current folded state."
  @spec compact(Path.t()) :: :ok
  def compact(path), do: with_lock(path, fn -> compact_now(path) end)

  defp compact_now(path) do
    book = load(path)
    tmp = path <> ".compact-tmp"

    File.open!(tmp, [:write], fn io ->
      for {type, table} <- @tables, {id, row} <- Map.fetch!(book, table) do
        line =
          row
          |> Map.put(:type, type)
          |> Map.put(:id, id)
          |> stringify_keys()
          |> JSON.encode!()

        IO.write(io, line <> "\n")
      end
    end)

    File.rename!(tmp, path)
    :ok
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp atomize_keys(map), do: Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)

  # A node row written before the natural key's third column was renamed
  # `arity` -> `anykey` still matches on rescan -- without this
  # every such node would be re-minted and its calc rows orphaned.
  defp upgrade(%{arity: arity} = row, :nodes) when not is_map_key(row, :anykey),
    do: row |> Map.delete(:arity) |> Map.put(:anykey, arity)

  defp upgrade(row, _table), do: row
end
