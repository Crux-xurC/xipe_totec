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

  ## Failures are results

  A write that cannot be done is an answer, never an exception: the lock
  another process keeps past the wait (`{:lock_busy, lock, holder}`), a
  lock that cannot be made (`{:lock, lock, reason}`), a file that cannot be
  written (`{:not_written, path, reason}`). The writers return
  `{:error, reason}`; `describe/1` is the line a person reads. (A raise
  here took the whole `xipe start` down when it came from a pass or a scan
  ending, and printed a stack trace in the CLI.)
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
  @lock_wait_ms 10_000

  @type reason ::
          {:lock_busy, Path.t(), String.t()} | {:lock, Path.t(), term()} | {:not_written, Path.t(), term()}

  @doc "Append one row (atom-keyed map, must include `:type` and `:id`) to the log at `path`."
  @spec append(Path.t(), map()) :: :ok | {:error, reason()}
  def append(path, row) when is_map(row) do
    with_lock(path, fn -> write_lines(path, line(row)) end)
  end

  @doc "The line a person reads for a write that could not be done."
  @spec describe(reason()) :: String.t()
  def describe({:lock_busy, lock, holder}),
    do: "#{lock} is held by another process (#{holder}) -- waited #{div(@lock_wait_ms, 1000)} s"

  def describe({:lock, lock, why}), do: "cannot take #{lock}: #{format_error(why)}"
  def describe({:not_written, path, why}), do: "#{path} could not be written: #{format_error(why)}"

  defp format_error(why) when is_atom(why), do: why |> :file.format_error() |> to_string()
  defp format_error(why), do: inspect(why)

  # under the lock: after a newline, whatever the last write left. A write
  # that fails part way (a full disk) is cut back to where the file ended,
  # so "nothing was written" stays true and no half of a change is read later
  defp write_lines(path, lines) do
    with :ok <- ensure_newline(path) do
      size = case File.stat(path) do
        {:ok, %File.Stat{size: n}} -> n
        _ -> 0
      end

      case File.write(path, lines, [:append]) do
        :ok ->
          :ok

        {:error, why} ->
          cut_back(path, size)
          {:error, {:not_written, path, why}}
      end
    else
      {:error, why} -> {:error, {:not_written, path, why}}
    end
  end

  defp cut_back(path, size) do
    with {:ok, io} <- :file.open(path, [:read, :write, :binary]) do
      _ = :file.position(io, size)
      _ = :file.truncate(io)
      :file.close(io)
    end
  end

  # a file whose last line was cut off (a crash mid-write) gets its newline,
  # so what is appended next starts a line of its own
  defp ensure_newline(path) do
    with {:ok, %File.Stat{size: n}} when n > 0 <- File.stat(path),
         {:ok, io} <- :file.open(path, [:read, :binary]) do
      last = :file.pread(io, n - 1, 1)
      :file.close(io)
      if last != {:ok, "\n"}, do: File.write(path, "\n", [:append]), else: :ok
    else
      {:ok, %File.Stat{}} -> :ok
      {:error, :enoent} -> :ok
      {:error, why} -> {:error, why}
    end
  end

  @doc """
  Run `fun` holding the write lock of `path` (`<path>.lock`, holding this
  OS process's `os_pid` + `os_started`). Waits up to `wait_ms` for another
  owner; a lock whose owner is gone is taken over. -> what `fun` returns, or
  `{:error, {:lock_busy, lock, holder}}` / `{:error, {:lock, lock, reason}}`
  when the lock was not had (`fun` did not run)
  """
  def with_lock(path, fun, wait_ms \\ @lock_wait_ms) do
    lock = path <> ".lock"

    case acquire(lock, System.monotonic_time(:millisecond) + wait_ms) do
      :ok ->
        try do
          fun.()
        after
          File.rm(lock)
        end

      {:error, _} = e ->
        e
    end
  end

  defp acquire(lock, deadline) do
    case File.write(lock, JSON.encode!(owner()), [:exclusive]) do
      :ok ->
        :ok

      {:error, :enoent} ->
        case File.mkdir_p(Path.dirname(lock)) do
          :ok -> acquire(lock, deadline)
          {:error, why} -> {:error, {:lock, lock, why}}
        end

      {:error, :eexist} ->
        held = File.read(lock)

        cond do
          stale?(held) ->
            take_over(lock, held)
            acquire(lock, deadline)

          System.monotonic_time(:millisecond) > deadline ->
            {:error, {:lock_busy, lock, holder(held)}}

          true ->
            Process.sleep(10)
            acquire(lock, deadline)
        end

      {:error, why} ->
        {:error, {:lock, lock, why}}
    end
  end

  # A gone owner's lock is removed by one taker at a time: `<lock>.takeover`
  # (made exclusively) is held while the lock is read again and removed,
  # so a second taker that saw the same stale lock cannot remove the lock
  # the first one has just made. A takeover mark left by a taker that died
  # in those few instructions goes after a second.
  @takeover_stale_ms 1_000

  defp take_over(lock, held) do
    mark = lock <> ".takeover"

    case File.write(mark, "", [:exclusive]) do
      :ok ->
        if File.read(lock) == held, do: File.rm(lock)
        File.rm(mark)

      {:error, :eexist} ->
        case File.stat(mark, time: :posix) do
          {:ok, %File.Stat{mtime: m}} ->
            if System.os_time(:second) - m > div(@takeover_stale_ms, 1000), do: File.rm(mark), else: Process.sleep(10)

          _ ->
            :ok
        end

      _ ->
        Process.sleep(10)
    end
  end

  defp holder({:ok, text}) do
    case JSON.decode(text) do
      {:ok, %{"os_pid" => pid}} -> "pid #{pid}"
      _ -> String.slice(text, 0, 80)
    end
  end

  defp holder(_), do: "unknown"

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
        case read_range(path, pos, n - pos) do
          {:ok, bytes} ->
            case :binary.matches(bytes, "\n") do
              [] ->
                {book, pos}

              ms ->
                {last, 1} = List.last(ms)
                whole = binary_part(bytes, 0, last + 1)
                {whole |> String.split("\n") |> Enum.reduce(book, &fold_line/2), pos + last + 1}
            end

          # cannot be read now: nothing new is taken, the next read tries again
          :error ->
            {book, pos}
        end

      _ ->
        {book, pos}
    end
  end

  defp read_range(path, pos, n) do
    with {:ok, io} <- :file.open(path, [:read, :binary]) do
      result = :file.pread(io, pos, n)
      :file.close(io)

      case result do
        {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
        _ -> :error
      end
    else
      _ -> :error
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
  @spec persist_diff(Path.t(), Book.t(), Book.t(), [Book.table()]) :: :ok | {:error, reason()}
  def persist_diff(path, old_book, new_book, tables) do
    # all the changed rows in one append (a scan can change hundreds), in a
    # fixed order
    case diff_lines(old_book, new_book, tables) do
      [] -> :ok
      lines -> with_lock(path, fn -> write_lines(path, lines) end)
    end
  end

  @doc """
  `persist_diff/4` for a writer that keeps the book in memory (the server):
  under the lock, the lines others appended since `pos` are folded in first,
  then this diff is written -- and wins where both changed the same row.
  -> {:ok, the book as the file now has it, the new pos} | {:error, reason}
  (nothing written: the caller keeps the book it had)
  """
  def persist_diff_since(path, pos, old_book, new_book, tables) do
    lines = diff_lines(old_book, new_book, tables)

    with_lock(path, fn ->
      {caught, at} = catch_up(path, pos, new_book)
      # ours over theirs: this diff folded again on top of what came in
      merged = lines |> Enum.map(&String.trim_trailing/1) |> Enum.reduce(caught, &fold_line/2)

      if lines == [] do
        {:ok, merged, at}
      else
        case write_lines(path, lines) do
          :ok ->
            # what was just written (and anything before it) is read: past it
            {_, end_pos} = catch_up(path, at, Book.new())
            {:ok, merged, end_pos}

          {:error, _} = e ->
            e
        end
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
  @spec compact(Path.t()) :: :ok | {:error, reason()}
  def compact(path), do: with_lock(path, fn -> compact_now(path) end)

  defp compact_now(path) do
    book = load(path)
    tmp = path <> ".compact-tmp"

    text =
      for {type, table} <- @tables, {id, row} <- Map.fetch!(book, table) do
        row |> Map.put(:type, type) |> Map.put(:id, id) |> line()
      end

    with :ok <- File.write(tmp, text),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, why} ->
        File.rm(tmp)
        {:error, {:not_written, path, why}}
    end
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
