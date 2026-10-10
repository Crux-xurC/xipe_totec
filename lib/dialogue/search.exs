Code.require_file("../dialogue.exs", __DIR__)
Code.require_file("../eval_table.exs", __DIR__)
Code.require_file("../surface_table.exs", __DIR__)
Code.require_file("../input.exs", __DIR__)

defmodule XipeTotec.Dialogue.Search do
  @moduledoc """
  `xipe search`: narrowing things down over several turns of one dialogue --
  find rows in a table, take a column's values as a list, look those
  values up in the next table, and finally view the rows. The join is not
  in a query language; it is the turns.

  Two tables: `-s` the project's surface table (`SurfaceTable`), `-e` the
  `eval_table` (`EvalTable`, calc rows with their function and path). Both
  are read afresh on every turn from the read-only `ctx` `InOut` hands in.
  Nothing is evaluated or written.

  A turn (a leading `xipe` / `search` is ignored):

    * `-h` -- usage and both tables' columns
    * `-s|-e <column> <value> [<out>]` -- the rows whose `<column>` is
      `<value>`; their `<out>` values (default `id`) become the held list
    * `-s|-e <column> list <out>` -- the same for every value in the held
      list (each matched exactly); the result replaces the list
    * `-s|-e view <column> [<col>...]` -- the rows whose `<column>` is one
      of the held list's values, shown with those columns (default: all);
      then asks whether to end the search (`y` ends it, `n` goes on)
    * `get id [-n]` -- the held list's n-th value (from 1, default 1) is
      kept as `x`
    * `quit dialogue` -- ends it (any dialogue, `InOut`)
    * anything else -- an ordinary command line, run while the search
      stays held (`{:pass, ...}`); `x` as a word, a value (`id=x`), a list
      element (`call_ids=[x]`) or a reference (`⟦x⟧`) is replaced by the
      kept id first, e.g. `row/update id=x args=[3]`

  Matching: exact by default; `~<value>` is a substring
  match (`-e args ~⟦<id>⟧ id` -- the rows referring to a row); a number
  compares as its text (`anykey` `2` is `"2"`). `-` matches an empty cell
  (e.g. `-e module -`, rows whose function is gone). A list cell (`args`)
  reads as its elements joined with `, `. More than 10 hits show the first
  10 and the count.

  Every turn holds the dialogue except `quit dialogue` and `y` after a
  view.
  """

  @behaviour XipeTotec.Dialogue

  alias XipeTotec.{EvalTable, Input, SurfaceTable}

  @shown 10
  @surface_columns ~w(id path depth language repl build_tool)

  @impl true
  def start(params, ctx) do
    state = %{list: nil, x: nil, confirm: false}

    case String.trim(Map.get(params, "line") || "") do
      "" -> {:hold, state, "Search started (-h for usage, quit dialogue to end)"}
      line -> answer(state, %{"text" => line}, ctx)
    end
  end

  @impl true
  def answer(state, %{"text" => line}, ctx) do
    case Input.words(line) do
      {:ok, words} -> turn(strip(words), line, state, ctx)
      {:error, message} -> {:hold, state, message}
    end
  end

  def answer(state, _params, _ctx), do: {:hold, state, "answer in one line (-h for usage)"}

  defp strip(["xipe" | rest]), do: strip(rest)
  defp strip(["search" | rest]), do: rest
  defp strip(words), do: words

  # -- turns ---------------------------------------------------------------

  defp turn(["y"], _line, %{confirm: true}, _ctx), do: {:done, "Search ended.", []}
  defp turn(["n"], _line, %{confirm: true} = state, _ctx), do: {:hold, %{state | confirm: false}, "Search continues."}
  defp turn(words, line, %{confirm: true} = state, ctx), do: turn(words, line, %{state | confirm: false}, ctx)

  defp turn([], _line, state, _ctx), do: {:hold, state, "-h for usage, quit dialogue to end"}
  defp turn(["-h"], _line, state, _ctx), do: {:hold, state, usage()}

  defp turn([flag, "view", column | columns], _line, state, ctx) when flag in ["-s", "-e"] do
    with {:ok, rows, all} <- table(flag, ctx),
         :ok <- known(all, [column | columns]),
         {:ok, list} <- held(state) do
      wanted = MapSet.new(list, &text/1)
      hits = Enum.filter(rows, &(text(&1[column]) in wanted))
      shown = if columns == [], do: all, else: columns
      lines = hits |> Enum.take(@shown) |> Enum.map(fn row -> Enum.map_join(shown, "  ", &"#{&1}=#{text(row[&1])}") end)
      {:hold, %{state | confirm: true}, Enum.join(["#{count(hits)}" | lines] ++ ["End the search? y/n"], "\n")}
    else
      {:error, message} -> {:hold, state, message}
    end
  end

  defp turn([flag, column, "list", out], _line, state, ctx) when flag in ["-s", "-e"] do
    with {:ok, rows, all} <- table(flag, ctx),
         :ok <- known(all, [column, out]),
         {:ok, list} <- held(state) do
      wanted = MapSet.new(list, &text/1)
      found(Enum.filter(rows, &(text(&1[column]) in wanted)), out, state)
    else
      {:error, message} -> {:hold, state, message}
    end
  end

  defp turn([flag, column, value | out], _line, state, ctx) when flag in ["-s", "-e"] and length(out) <= 1 do
    out = List.first(out) || "id"

    with {:ok, rows, all} <- table(flag, ctx),
         :ok <- known(all, [column, out]) do
      found(Enum.filter(rows, &matches?(&1[column], value)), out, state)
    else
      {:error, message} -> {:hold, state, message}
    end
  end

  defp turn(["get", "id" | n], _line, state, _ctx) when length(n) <= 1 do
    with {:ok, index} <- position(n),
         {:ok, list} <- held(state),
         value when value != nil <- Enum.at(list, index - 1) do
      x = text(value)
      {:hold, %{state | x: x}, "took the id of element #{index} of the result: #{x} (write x for it from now on)"}
    else
      _ -> {:hold, state, "No match data"}
    end
  end

  defp turn(words, _line, state, _ctx) do
    case with_x(words, state.x) do
      {:ok, words} -> {:pass, state, Enum.map_join(words, " ", &quote_word/1)}
      :no_x -> {:hold, state, "there is no x yet (take one with get id)"}
    end
  end

  # -- tables ----------------------------------------------------------------

  defp table("-e", ctx), do: {:ok, EvalTable.rows(ctx.book), EvalTable.columns()}
  defp table("-s", ctx), do: {:ok, surface_rows(ctx), @surface_columns}

  # the saved surface table as it is (not regenerated or saved: a search
  # writes nothing); none saved yet -> generated in memory
  defp surface_rows(ctx) do
    file = ctx[:project_dir] && Path.join(ctx.project_dir, "table")
    if file && File.exists?(file), do: SurfaceTable.load(file), else: SurfaceTable.generate(ctx.root, [])
  end

  defp known(all, columns) do
    case Enum.reject(columns, &(&1 in all)) do
      [] -> :ok
      [c | _] -> {:error, "no such column: #{c} (-h lists the columns)"}
    end
  end

  defp held(%{list: nil}), do: {:error, "no list is held (search with -s or -e first)"}
  defp held(%{list: list}), do: {:ok, list}

  defp found(hits, out, state) do
    list = hits |> Enum.map(& &1[out]) |> Enum.reject(&(text(&1) == "")) |> Enum.uniq_by(&text/1)
    shown = list |> Enum.take(@shown) |> Enum.map_join(", ", &text/1)
    more = if length(list) > @shown, do: " (#{length(list) - @shown} more)", else: ""
    {:hold, %{state | list: list}, "#{count(hits)} (#{out}: [#{shown}]#{more})"}
  end

  defp count(hits), do: "#{length(hits)} hit(s)."

  defp position([]), do: {:ok, 1}

  defp position(["-" <> n]) do
    case Integer.parse(n) do
      {i, ""} when i >= 1 -> {:ok, i}
      _ -> :error
    end
  end

  defp position(_), do: :error

  # -- matching -----------------------------------------------------------------

  defp matches?(cell, "~" <> part), do: String.contains?(text(cell), part)
  defp matches?(cell, "-"), do: text(cell) == ""
  defp matches?(cell, value), do: text(cell) == value

  defp text(nil), do: ""
  defp text(list) when is_list(list), do: Enum.map_join(list, ", ", &text/1)
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)

  # -- passing a line on ---------------------------------------------------------

  defp with_x(words, x) do
    uses = Enum.any?(words, &x_word?/1)

    cond do
      not uses -> {:ok, words}
      x == nil -> :no_x
      true -> {:ok, Enum.map(words, &replace_x(&1, x))}
    end
  end

  # x as a whole word, a whole value (id=x), a list element ([x], [a,x]),
  # or a cell reference (⟦x⟧)
  @x ~r/(?<=^|[=\[,])x(?=$|[\],])|⟦x⟧/u

  defp x_word?(w), do: Regex.match?(@x, w)

  defp replace_x(w, x), do: Regex.replace(@x, w, fn m -> if m == "x", do: x, else: "⟦#{x}⟧" end)

  defp quote_word(w), do: if(w == "" or String.match?(w, ~r/\s/), do: "'#{w}'", else: w)

  defp usage do
    """
    -s|-e <column> <value> [<out>]   rows whose <column> is <value>; their <out> (default id) become the list
    -s|-e <column> list <out>        the same for every value in the held list (replaces the list)
    -s|-e view <column> [<col>...]   show the rows matching the held list's values
    get id [-n]                      keep the list's n-th value (from 1, default 1) as x
    quit dialogue                    end the search
    any other line runs as an ordinary command (x is replaced by the kept id)
    values: exact by default, ~<value> is a substring match, - is empty. -s is the surface table, -e the eval_table
    -s columns: #{Enum.join(@surface_columns, " ")}
    -e columns: #{Enum.join(EvalTable.columns(), " ")}\
    """
  end
end
