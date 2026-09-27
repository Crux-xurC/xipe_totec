Code.require_file("../dialogue.exs", __DIR__)
Code.require_file("../eval_table.exs", __DIR__)
Code.require_file("../surface_table.exs", __DIR__)
Code.require_file("../input.exs", __DIR__)

defmodule XipeTotec.Dialogue.Search do
  @moduledoc """
  `xipe search` (2026-09-27, `next_step.md` §1.1, crux's design of
  2026-09-26): narrowing things down over several turns of one dialogue --
  find rows in a table, take a column's values as a list, look those
  values up in the next table, and finally view the rows. The join is not
  in a query language; it is the turns.

  Two tables: `-s` the project's surface table (`SurfaceTable`), `-e` the
  `eval_table` (`EvalTable`, calc rows with their function and path). Both
  are read afresh on every turn from the read-only `ctx` `InOut` hands in.
  Nothing is evaluated or written (Old.md §36).

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

  Matching (crux, 2026-09-26): exact by default; `~<value>` is a substring
  match (`-e args ~⟦<id>⟧ id` -- the rows referring to a row); a number
  compares as its text (`anykey` `2` is `"2"`). `-` matches an empty cell
  (e.g. `-e module -`, rows whose function is gone). A list cell (`args`)
  reads as its elements joined with `, `. More than 10 hits show the first
  10 and the count.

  Every turn holds the dialogue except `quit dialogue` and `y` after a
  view (§17's `11`, then `01`).
  """

  @behaviour XipeTotec.Dialogue

  alias XipeTotec.{EvalTable, Input, SurfaceTable}

  @shown 10
  @surface_columns ~w(id path depth language repl build_tool)

  @impl true
  def start(params, ctx) do
    state = %{list: nil, x: nil, confirm: false}

    case String.trim(Map.get(params, "line") || "") do
      "" -> {:hold, state, "検索を始めます（-h で使い方、quit dialogue で終了）"}
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

  def answer(state, _params, _ctx), do: {:hold, state, "1行で答えてください（-h で使い方）"}

  defp strip(["xipe" | rest]), do: strip(rest)
  defp strip(["search" | rest]), do: rest
  defp strip(words), do: words

  # -- turns ---------------------------------------------------------------

  defp turn(["y"], _line, %{confirm: true}, _ctx), do: {:done, "検索を終了しました。", []}
  defp turn(["n"], _line, %{confirm: true} = state, _ctx), do: {:hold, %{state | confirm: false}, "検索を続けます。"}
  defp turn(words, line, %{confirm: true} = state, ctx), do: turn(words, line, %{state | confirm: false}, ctx)

  defp turn([], _line, state, _ctx), do: {:hold, state, "-h で使い方、quit dialogue で終了"}
  defp turn(["-h"], _line, state, _ctx), do: {:hold, state, usage()}

  defp turn([flag, "view", column | columns], _line, state, ctx) when flag in ["-s", "-e"] do
    with {:ok, rows, all} <- table(flag, ctx),
         :ok <- known(all, [column | columns]),
         {:ok, list} <- held(state) do
      wanted = MapSet.new(list, &text/1)
      hits = Enum.filter(rows, &(text(&1[column]) in wanted))
      shown = if columns == [], do: all, else: columns
      lines = hits |> Enum.take(@shown) |> Enum.map(fn row -> Enum.map_join(shown, "  ", &"#{&1}=#{text(row[&1])}") end)
      {:hold, %{state | confirm: true}, Enum.join(["#{count(hits)}" | lines] ++ ["検索を終了しますか？y/n"], "\n")}
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
      {:hold, %{state | x: x}, "検索結果の#{index}番目の要素のIDを取得しました: #{x}（以降 x と書けます）"}
    else
      _ -> {:hold, state, "No match data"}
    end
  end

  defp turn(words, _line, state, _ctx) do
    case with_x(words, state.x) do
      {:ok, words} -> {:pass, state, Enum.map_join(words, " ", &quote_word/1)}
      :no_x -> {:hold, state, "x がまだありません（get id で取り出してください）"}
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
      [c | _] -> {:error, "列 #{c} はありません（-h で列の一覧）"}
    end
  end

  defp held(%{list: nil}), do: {:error, "保持しているリストがありません（先に -s か -e で探してください）"}
  defp held(%{list: list}), do: {:ok, list}

  defp found(hits, out, state) do
    list = hits |> Enum.map(& &1[out]) |> Enum.reject(&(text(&1) == "")) |> Enum.uniq_by(&text/1)
    shown = list |> Enum.take(@shown) |> Enum.map_join(", ", &text/1)
    more = if length(list) > @shown, do: "（ほか #{length(list) - @shown} 件）", else: ""
    {:hold, %{state | list: list}, "#{count(hits)}（#{out}: [#{shown}]#{more}）"}
  end

  defp count(hits), do: "#{length(hits)}件ヒットしました。"

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
    -s|-e <列> <値> [<取り出す列>]   <列> が <値> の行の <取り出す列>（既定 id）をリストにする
    -s|-e <列> list <取り出す列>     保持中のリストの値ごとに <列> を探す（リストを置き換える）
    -s|-e view <列> [<表示する列>...]  保持中のリストの値に合う行を表示する
    get id [-n]                      リストの n 番目（1から、既定 1）を x として保持する
    quit dialogue                    検索を終える
    それ以外の行は普通のコマンドとして実行する（x は取り出した id に置き換える）
    値: 既定は完全一致、~<値> は部分一致、- は空。-s は surface table、-e は eval_table
    -s の列: #{Enum.join(@surface_columns, " ")}
    -e の列: #{Enum.join(EvalTable.columns(), " ")}\
    """
  end
end
