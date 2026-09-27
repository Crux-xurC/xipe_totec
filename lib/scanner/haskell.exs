Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)

defmodule XipeTotec.Scanner.Haskell do
  @moduledoc """
  Haskell's scan (Old.md §46), read from the text -- nothing but
  xipe_totec needed (P8), and, as for OCaml (Old.md §42.4), the links
  wanted are the dependencies between the functions a file defines, which
  the text shows.

  **Definitions**: the module is the file's `module X` header (`Main`
  without one). A top-level definition is a line starting at column 0 with
  a lowercase name (`f x = ...`, `f (x:xs) | ...`), several clauses of one
  name being one definition; type signatures, operators, pattern bindings
  and declarations (`data`, `class`, `instance`, ...) are not. `anykey` is
  `nil` (a module can't define a name twice, and currying leaves no arity to
  check), every node `public` (GHCi loads the source with `*M` in scope, so
  what the export list hides is still callable).

  **Links**, from a definition's text (comments and strings blanked):
  `M.f` (an `import ... as N` alias resolved), a bare name of another
  definition in the same module, and a bare name some unqualified import of
  a project module defines. Local bindings that shadow those names are
  taken for calls (P9: what the text suggests).
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.Scanner

  @keywords ~w(module import where data type newtype class instance deriving infix infixl infixr
               foreign default let in if then else case of do pattern)

  @impl Scanner
  def scan_defs(book, sheet_id, %{source: source}) do
    Scanner.put_defs(book, sheet_id, definitions(source))
  end

  @impl Scanner
  def scan_links_report(book, node_ids, %{source: source}) do
    text = blank(source)
    module = module_name(text)
    imports = imports(text)
    aliases = Map.new(imports, &{&1.alias || &1.module, &1.module})
    unqualified = for i <- imports, not i.qualified, do: i.module
    defs = definitions(source)
    own = for d <- defs, id = node_ids[{module, d.name, nil}], do: {d, id}
    names = MapSet.new(defs, & &1.name)

    links =
      for {d, caller} <- own,
          key <- calls(d.text, d.name, module, names, aliases, unqualified),
          ref = resolve(book, node_ids, key),
          ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), []}
  end

  @doc "The file's module: its `module X` header, else `Main`."
  @spec module_name(String.t()) :: String.t()
  def module_name(source) do
    case Regex.run(~r/^module\s+([A-Z][\w.']*)/m, blank(source)) do
      [_, name] -> name
      nil -> "Main"
    end
  end

  @doc """
  The top-level definitions, in order: `%{module:, name:, anykey: nil,
  visibility: "public", span: line, body_hash:, text:}` (`text` is every
  clause's lines, blanked).
  """
  @spec definitions(String.t()) :: [map()]
  def definitions(source) do
    text = blank(source)
    module = module_name(source)
    lines = String.split(text, "\n")

    # blocks: a column-0 line and the indented (or blank) lines after it
    blocks =
      lines
      |> Enum.with_index(1)
      |> Enum.chunk_while(
        nil,
        fn {line, n}, acc ->
          cond do
            String.trim(line) == "" or String.match?(line, ~r/^\s/) ->
              {:cont, if(acc, do: {elem(acc, 0), [line | elem(acc, 1)]}, else: acc)}

            acc == nil ->
              {:cont, {n, [line]}}

            true ->
              {:cont, acc, {n, [line]}}
          end
        end,
        fn acc -> if acc, do: {:cont, acc, nil}, else: {:cont, nil} end
      )
      |> Enum.map(fn {n, ls} -> {n, ls |> Enum.reverse() |> Enum.join("\n")} end)

    blocks
    |> Enum.flat_map(fn {n, block} ->
      case definition_name(block) do
        nil -> []
        name -> [{name, n, block}]
      end
    end)
    |> Enum.chunk_by(fn {name, _, _} -> name end)
    |> Enum.map(fn [{name, n, _} | _] = clauses ->
      body = Enum.map_join(clauses, "\n", &elem(&1, 2))
      hash = :crypto.hash(:sha256, String.trim(body)) |> Base.encode16(case: :lower)
      %{module: module, name: name, anykey: nil, visibility: "public", span: n, body_hash: hash, text: body}
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.name)
    |> Enum.reverse()
  end

  # `f x = ...` / `f (x:xs) | ...` -- not a signature (`f :: ...`,
  # `f, g :: ...`), not a keyword, not an operator or pattern binding, not
  # an infix definition (`x <.> y = ...`, `` x `op` y = ... ``)
  defp definition_name(block) do
    with [_, name] <- Regex.run(~r/^([a-z_][\w']*)\b/, block),
         false <- name in @keywords,
         false <- infix?(block),
         false <- Regex.match?(~r/^[a-z_][\w']*\s*(,\s*[a-z_][\w']*\s*)*::/, block),
         true <- Regex.match?(~r/(?<![=<>\/!:])=(?![=>])|^\s*\|/m, block) do
      name
    else
      _ -> nil
    end
  end

  defp infix?(block) do
    case Regex.run(~r/^[a-z_][\w']*\s+(`[^`]+`|[!#$%&*+.\/<=>?@\\^|~:-]+)/, block) do
      [_, op] -> op not in ["=", "|"]
      nil -> false
    end
  end

  # `import [qualified] M [qualified] [as N] ...`
  defp imports(text) do
    for [_, q1, module, q2, alias] <-
          Regex.scan(~r/^import\s+(qualified\s+)?([A-Z][\w.']*)(\s+qualified)?(?:\s+as\s+([A-Z][\w.']*))?/m, text,
            capture: :all
          )
          |> Enum.map(&pad(&1, 5)) do
      %{module: module, qualified: q1 != "" or q2 != "", alias: if(alias == "", do: nil, else: alias)}
    end
  end

  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  # {:qualified, M, n} or {:bare, n}
  defp calls(text, self, module, names, aliases, unqualified) do
    body = Regex.replace(~r/^[a-z_][\w']*/m, text, "")

    qualified =
      for [_, q, n] <- Regex.scan(~r/(?<![\w'.])([A-Z][\w']*(?:\.[A-Z][\w']*)*)\.([a-z_][\w']*)/, body),
          do: {:qualified, Map.get(aliases, q, q), n}

    bare =
      for [_, n] <- Regex.scan(~r/(?<![\w'.])([a-z_][\w']*)/, body),
          n != self and n not in @keywords,
          uniq: true,
          do: if(MapSet.member?(names, n), do: {:qualified, module, n}, else: {:imported, n, unqualified})

    qualified ++ bare
  end

  defp resolve(book, node_ids, {:qualified, m, n}), do: Scanner.node_for(book, node_ids, {m, n, nil})

  defp resolve(book, node_ids, {:imported, n, modules}),
    do: Enum.find_value(modules, &Scanner.node_for(book, node_ids, {&1, n, nil}))

  @doc """
  `source` with comments (`--`, nested `{- -}`, pragmas), string literals
  and character literals replaced by spaces, newlines kept.
  """
  @spec blank(String.t()) :: String.t()
  def blank(source), do: source |> String.graphemes() |> blank(:code, 0, nil, []) |> IO.iodata_to_binary()

  @symbols String.graphemes("!#$%&*+./<=>?@\\^|-~:")

  defp blank([], _mode, _depth, _prev, acc), do: Enum.reverse(acc)
  defp blank(["{", "-" | rest], mode, depth, _p, acc) when mode in [:code, :block], do: blank(rest, :block, depth + 1, "-", ["  " | acc])
  defp blank(["-", "}" | rest], :block, 1, _p, acc), do: blank(rest, :code, 0, "}", ["  " | acc])
  defp blank(["-", "}" | rest], :block, depth, _p, acc), do: blank(rest, :block, depth - 1, "}", ["  " | acc])

  # `--` starts a comment unless it is part of an operator (`-->`, `<--`)
  defp blank(["-", "-" | rest], :code, depth, prev, acc) do
    {dashes, after_dashes} = Enum.split_while(rest, &(&1 == "-"))
    operator? = prev in @symbols or match?([c | _] when c in @symbols, after_dashes)

    if operator?,
      do: blank(after_dashes, :code, depth, "-", [List.duplicate("-", length(dashes) + 2) | acc]),
      else: blank(after_dashes, :line, depth, "-", [List.duplicate(" ", length(dashes) + 2) | acc])
  end

  defp blank(["\n" | rest], :line, depth, _p, acc), do: blank(rest, :code, depth, "\n", ["\n" | acc])
  defp blank(["\"" | rest], :code, depth, _p, acc), do: blank(rest, :string, depth, "\"", ["\"" | acc])
  defp blank(["\\", c | rest], :string, depth, _p, acc), do: blank(rest, :string, depth, c, [keep(c), " " | acc])
  defp blank(["\"" | rest], :string, depth, _p, acc), do: blank(rest, :code, depth, "\"", ["\"" | acc])

  # a character literal ('x', '\n') -- not a prime in a name (x', f'')
  defp blank(["'" | rest], :code, depth, prev, acc) do
    cond do
      ident?(prev) -> blank(rest, :code, depth, "'", ["'" | acc])
      match?(["\\", _, "'" | _], rest) -> blank(Enum.drop(rest, 3), :code, depth, "'", ["'  '" | acc])
      match?([c, "'" | _] when c != "\\", rest) -> blank(Enum.drop(rest, 2), :code, depth, "'", ["' '" | acc])
      true -> blank(rest, :code, depth, "'", ["'" | acc])
    end
  end

  defp blank([c | rest], :code, depth, _p, acc), do: blank(rest, :code, depth, c, [c | acc])
  defp blank([c | rest], mode, depth, _p, acc), do: blank(rest, mode, depth, c, [keep(c) | acc])

  defp ident?(nil), do: false
  defp ident?(c), do: String.match?(c, ~r/^[\w']$/u)

  defp keep("\n"), do: "\n"
  defp keep(_), do: " "
end
