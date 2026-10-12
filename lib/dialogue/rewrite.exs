Code.require_file("../dialogue.exs", __DIR__)
Code.require_file("../tables.exs", __DIR__)
Code.require_file("do.exs", __DIR__)

defmodule XipeTotec.Dialogue.Rewrite do
  @moduledoc """
  `dialogue rewrite [<table> [<row> [<column>]]]`: one value of a table
  changed by hand, without evaluating anything. Asked for in turn, skipping
  what the starting line gave: the table, the row, the column, the value.

    * the table -- its flag or name, as `search` and `roster` write it
      (`-e`, `eval`). Not asked when only one table has anything that can
      be rewritten (a table named on the line that isn't it is said, and
      asked for)
    * the row -- its id. The row is then shown, every column, so the
      person sees what they are about to change
    * the column -- one of the table's rewritable columns
      (`XipeTotec.Tables`' `writes`)
    * the value -- asked by `Dialogue.Do`, as that column's method takes
      it: a line as it is, a list between `{` and `}`, a choice

  This module never writes and never builds the write itself: a column
  names the method that changes it (`row/set-args`, `row/set-result`,
  `row/set-prev`, `effect/set`), and from the column on the dialogue is
  `Dialogue.Do`'s for that method, with the row's id already given -- so
  the call is shown and waits for `y` like any written one, and the
  method's own checks apply. A column whose id is not the row's own
  (`effect` is the function's) says so before the value is asked.

  The value is never read from the starting line: a line of its own is
  taken as it is, a word of a command line would not be.
  """

  @behaviour XipeTotec.Dialogue

  alias XipeTotec.Dialogue.Do
  alias XipeTotec.Tables

  @impl true
  def start(params, ctx) do
    state = %{table: nil, row: nil, column: nil, inner: nil}

    # what the line gave, read as the answers they would be -- each only
    # once the one before it was taken; a wrong one is said and asked for
    turn =
      case given(params, "table") do
        nil -> ask(state, ctx, [])
        text -> answer(state, %{"text" => text}, ctx)
      end

    turn = given_next(turn, :row, given(params, "row"), ctx)
    row_taken = match?({:hold, %{row: row, column: nil, inner: nil}, _} when row != nil, turn)

    next = given_next(turn, :column, given(params, "column"), ctx)

    # the column was taken too, so the row went by without its line being
    # said: say it with what follows
    if row_taken and moved_past_row?(turn, next), do: prepend_row(next, turn, ctx), else: next
  end

  defp given(params, key) do
    case params[key] do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  # the line's `key`, taken as the answer when the dialogue is waiting for exactly that
  defp given_next({:hold, %{inner: nil} = state, _question} = turn, key, text, ctx) when is_binary(text) do
    waiting = cond do
      state.table == nil -> :table
      state.row == nil -> :row
      state.column == nil -> :column
    end

    if waiting == key, do: answer(state, %{"text" => text}, ctx), else: turn
  end

  defp given_next(turn, _key, _text, _ctx), do: turn

  defp moved_past_row?({:hold, before, _}, {:hold, %{column: column, inner: inner}, _}), do: before.column != column or inner != nil
  defp moved_past_row?(_before, {:done, _, _}), do: true
  defp moved_past_row?(_before, _next), do: false

  defp prepend_row(next, {:hold, state, _}, ctx) do
    line = row_line(table(state), find_row(state, state.row, ctx) || %{})

    case next do
      {:hold, new_state, text} -> {:hold, new_state, line <> "\n" <> text}
      {:done, text, commands} -> {:done, line <> "\n" <> text, commands}
    end
  end

  @impl true
  def answer(%{inner: inner} = state, params, ctx) when inner != nil, do: wrap(Do.answer(inner, params, ctx), state)

  def answer(%{table: nil} = state, %{"text" => line}, ctx) do
    word = String.trim(line)

    case Tables.named(word) do
      nil -> ask(state, ctx, ["no such table: #{word}"])
      %{writes: writes} = table when map_size(writes) == 0 -> ask(state, ctx, ["nothing in #{table.summary} can be rewritten"])
      table -> ask(%{state | table: table.name}, ctx, [])
    end
  end

  def answer(%{row: nil} = state, %{"text" => line}, ctx) do
    id = String.trim(line)

    case find_row(state, id, ctx) do
      nil -> ask(state, ctx, ["no row #{id} in #{table(state).summary}"])
      row -> ask(%{state | row: id}, ctx, [row_line(table(state), row)])
    end
  end

  def answer(%{column: nil} = state, %{"text" => line}, ctx) do
    table = table(state)
    column = String.trim(line)

    cond do
      Map.has_key?(table.writes, column) -> value(%{state | column: column}, ctx)
      column in table.columns -> ask(state, ctx, ["#{column} can't be rewritten (it is what an evaluation or a scan found)"])
      true -> ask(state, ctx, ["no such column: #{column}"])
    end
  end

  def answer(state, _params, ctx), do: ask(state, ctx, ["answer in one line"])

  # -- the questions ---------------------------------------------------------------

  defp ask(%{table: nil} = state, ctx, notes) do
    case Enum.filter(Tables.all(), &(map_size(&1.writes) > 0)) do
      # only one table has anything to rewrite: no question to ask -- unless
      # a table was named and wasn't it, which is not passed over
      [only] when notes == [] -> ask(%{state | table: only.name}, ctx, notes)
      tables -> hold(state, notes, "table? (#{Enum.map_join(tables, ", ", &"#{&1.flag} #{&1.summary}")})")
    end
  end

  defp ask(%{row: nil} = state, _ctx, notes), do: hold(state, notes, "row? (its #{table(state).key} in #{table(state).summary})")

  defp ask(%{column: nil} = state, _ctx, notes),
    do: hold(state, notes, "column? (#{table(state).writes |> Map.keys() |> Enum.sort() |> Enum.join(" | ")})")

  defp hold(state, notes, question), do: {:hold, state, Enum.join(notes ++ [question], "\n")}

  # -- the value: Dialogue.Do's, for the column's method ----------------------------

  defp value(state, ctx) do
    table = table(state)
    write = table.writes[state.column]
    # read again: the id may be another column's (the row's function)
    row = find_row(state, state.row, ctx) || %{}
    id = Tables.text(row[write.id_from])

    note =
      if write.id_from == table.key,
        do: [],
        else: ["#{state.column} is not this row's alone (#{write.id_from} #{id}): every row with it is affected"]

    case Do.start(%{"method" => write.method, "given" => %{write.id => id}}, ctx) do
      {:hold, inner, text} -> {:hold, %{state | inner: inner}, Enum.join(note ++ [text], "\n")}
      {:done, text, commands} -> {:done, Enum.join(note ++ [text], "\n"), commands}
    end
  end

  defp wrap({:hold, inner, text}, state), do: {:hold, %{state | inner: inner}, text}
  defp wrap(done, _state), do: done

  # -- the table and its rows ---------------------------------------------------------

  defp table(%{table: name}), do: Tables.named(name)

  defp find_row(state, id, ctx) do
    table = table(state)
    Enum.find(Tables.rows(table, ctx), &(Tables.text(&1[table.key]) == id))
  end

  # the row as search's view shows one: every column, `column=value`
  defp row_line(table, row), do: Enum.map_join(table.columns, "  ", &"#{&1}=#{Tables.text(row[&1])}")
end
