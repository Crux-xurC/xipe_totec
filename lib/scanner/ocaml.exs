Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)

defmodule XipeTotec.Scanner.Ocaml do
  @moduledoc """
  OCaml's basic-behavior scan (Old.md §42): reads a `.ml` file as text --
  no OCaml needed, so it works with nothing but xipe_totec (P8). It is
  OCaml's only scanner: ocamllsp has no `callHierarchy`, and the links
  wanted are the dependencies between the functions a file defines, which
  the text shows (crux, Old.md §42.4).

  **Definitions**: the file is the module its name gives (`target.ml` is
  `Target`). Every top-level value definition -- a line starting at column 0
  with `let`, `let rec`, or `and` continuing one -- is a node, except
  `let ()`/`let _` (effects, not values), operators, and `and` continuing a
  `type`. Definitions inside a nested `module ... = struct` are not read
  yet. OCaml can define the same name twice (the later one shadows); the
  last one is the node. `anykey` is `nil` (the name alone is unique, and
  currying leaves no arity to check -- next_step §2.2), and every node is
  `public` (xipe loads the source itself, so what an `.mli` hides is still
  callable).

  **Links** are estimated from the text, not resolved by the compiler: in a
  definition's text (comments and strings blanked), `Mod.name` naming a
  known node, and a bare name of another definition of the same file. A
  local variable that happens to share a top-level name is taken for a
  call (P9: the links are what the text suggests).
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.Scanner

  @keywords ~w(let and type module open include exception external class val)
  @not_names ~w(open module exception rec _)

  @impl Scanner
  def scan_defs(book, sheet_id, %{path: path, source: source}) do
    Scanner.put_defs(book, sheet_id, definitions(path, source))
  end

  @impl Scanner
  def scan_links_report(book, node_ids, %{path: path, source: source}) do
    module = module_name(path)
    defs = definitions(path, source)
    own = for d <- defs, id = node_ids[{module, d.name, nil}], do: {d, id}
    names = MapSet.new(defs, & &1.name)

    links =
      for {d, caller} <- own,
          callee <- calls(d.text, d.name, names),
          ref = Scanner.node_for(book, node_ids, qualify(callee, module)),
          ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), []}
  end

  @doc "The module a file is: its base name, first letter capitalized (`my_mod.ml` is `My_mod`)."
  @spec module_name(String.t()) :: String.t()
  def module_name(path) do
    base = Path.basename(path, ".ml")
    String.upcase(String.first(base)) <> String.slice(base, 1..-1//1)
  end

  @doc """
  The file's top-level value definitions, in order, the last of a name
  kept: `%{module:, name:, anykey: nil, visibility:, span: line,
  body_hash:, text:}` (`text` is the definition's lines, blanked).
  """
  @spec definitions(String.t(), String.t()) :: [map()]
  def definitions(path, source) do
    module = module_name(path)
    lines = source |> blank() |> String.split("\n")

    starts =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> Regex.match?(~r/^(#{Enum.join(@keywords, "|")})\b/, line) end)

    ends = Enum.map(tl(starts), &elem(&1, 1)) ++ [length(lines) + 1]

    {defs, _kind} =
      starts
      |> Enum.zip(ends)
      |> Enum.reduce({[], nil}, fn {{line, n}, stop}, {defs, kind} ->
        [keyword | _] = String.split(line, ~r/\s/, parts: 2)
        kind = if keyword == "and", do: kind, else: keyword

        case kind == "let" && Regex.run(~r/^(?:let|and)\s+(?:rec\s+)?([a-z_][A-Za-z0-9_']*)/, line) do
          [_, name] when name not in @not_names ->
            text = lines |> Enum.slice((n - 1)..(stop - 2)//1) |> Enum.join("\n")
            {[definition(module, name, n, text) | defs], kind}

          _ ->
            {defs, kind}
        end
      end)

    defs |> Enum.uniq_by(& &1.name) |> Enum.reverse()
  end

  defp definition(module, name, line, text) do
    hash = :crypto.hash(:sha256, String.trim(text)) |> Base.encode16(case: :lower)
    %{module: module, name: name, anykey: nil, visibility: "public", span: line, body_hash: hash, text: text}
  end

  # the names a definition's text uses: {Mod, name} qualified, or a bare
  # name of another definition in the same file
  defp calls(text, self, names) do
    body = Regex.replace(~r/^(?:let|and)\s+(?:rec\s+)?[a-z_][A-Za-z0-9_']*/, text, "")
    qualified = for [_, m, n] <- Regex.scan(~r/\b([A-Z][A-Za-z0-9_']*)\.([a-z_][A-Za-z0-9_']*)/, body), do: {m, n}

    bare =
      for [_, n] <- Regex.scan(~r/(?<![.A-Za-z0-9_'~?])([a-z_][A-Za-z0-9_']*)\b(?!\s*:(?!:))/, body),
          n != self and MapSet.member?(names, n),
          do: {nil, n}

    qualified ++ bare
  end

  defp qualify({nil, name}, module), do: {module, name, nil}
  defp qualify({m, name}, _module), do: {m, name, nil}

  @doc """
  `source` with comments (nested), string literals and character literals
  replaced by spaces, newlines kept -- so what's left is code, line for line.
  """
  @spec blank(String.t()) :: String.t()
  def blank(source), do: source |> String.graphemes() |> blank(:code, 0, []) |> IO.iodata_to_binary()

  defp blank([], _mode, _depth, acc), do: Enum.reverse(acc)
  defp blank(["(", "*" | rest], mode, depth, acc) when mode in [:code, :comment], do: blank(rest, :comment, depth + 1, ["  " | acc])
  defp blank(["*", ")" | rest], :comment, 1, acc), do: blank(rest, :code, 0, ["  " | acc])
  defp blank(["*", ")" | rest], :comment, depth, acc), do: blank(rest, :comment, depth - 1, ["  " | acc])
  defp blank(["\"" | rest], :code, depth, acc), do: blank(rest, :string, depth, ["\"" | acc])
  defp blank(["\\", c | rest], :string, depth, acc), do: blank(rest, :string, depth, [keep_newline(c), " " | acc])
  defp blank(["\"" | rest], :string, depth, acc), do: blank(rest, :code, depth, ["\"" | acc])
  # a character literal ('x', '\n', '\''), not a type variable ('a)
  defp blank(["'", "\\", _c, "'" | rest], :code, depth, acc), do: blank(rest, :code, depth, ["'  '" | acc])
  defp blank(["'", c, "'" | rest], :code, depth, acc) when c != "\\", do: blank(rest, :code, depth, ["' '" | acc])
  defp blank([c | rest], :code, depth, acc), do: blank(rest, :code, depth, [c | acc])
  defp blank([c | rest], mode, depth, acc), do: blank(rest, mode, depth, [keep_newline(c) | acc])

  defp keep_newline("\n"), do: "\n"
  defp keep_newline(_), do: " "
end
