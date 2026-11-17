Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)

defmodule XipeTotec.Scanner.Python do
  @moduledoc """
  Python's scan, read from the text -- no Python toolchain needed, as for
  OCaml and Haskell ([D-python-adapter](../../document/verification/lib-repl-language-python.exs.md#d-python-adapter)).

  **Modules**: a file's module is its path (`module_name/2`): `geo/shape.py`
  is `geo.shape`, `geo/__init__.py` is `geo`, and a leading `src/` without
  an `__init__.py` of its own (the src layout) is left out. `embody.py`
  imports the files under the same names.

  **Definitions**: a top-level `def` / `async def` (a line at column 0).
  Methods, nested functions and lambdas are not. `anykey` is `nil` (default
  and keyword arguments leave no fixed arity), every node `public` (a
  leading `_` is a convention; the REPL calls it all the same).

  **Links**, from a definition's text (comments and strings blanked):
  `m.f` / `m.sub.f` where `m` is an imported project module (`import geo.shape`,
  `import geo.shape as gs`, `from geo import shape`), a bare name of another
  definition in the same module, and a bare name imported from a project
  module (`from .units import scale`, relative imports resolved). Local
  names that shadow those are taken for calls (the links are what the text
  suggests).
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.Scanner

  @keywords ~w(False None True and as assert async await break class continue def del elif else except finally
               for from global if import in is lambda nonlocal not or pass raise return try while with yield)

  @impl Scanner
  def scan_defs(book, sheet_id, %{root: root, path: path, source: source}) do
    Scanner.put_defs(book, sheet_id, definitions(source, module_name(root, path)))
  end

  @impl Scanner
  def scan_links_report(book, node_ids, %{root: root, path: path, source: source}) do
    module = module_name(root, path)
    text = blank(source)
    package = if Path.basename(path) == "__init__.py", do: module, else: parent(module)
    {modules, names} = imports(text, package)
    defs = definitions(source, module)
    own = for d <- defs, id = node_ids[{module, d.name, nil}], do: {d, id}
    local = MapSet.new(defs, & &1.name)

    links =
      for {d, caller} <- own,
          key <- calls(d.text, d.name, module, local, modules, names),
          ref = Scanner.node_for(book, node_ids, key),
          ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), []}
  end

  @doc """
  The module a file is, from its path relative to the project `root`:
  `geo/shape.py` -> `geo.shape`, `geo/__init__.py` -> `geo`,
  `src/geo/shape.py` -> `geo.shape` unless `src/__init__.py` exists.
  """
  @spec module_name(String.t(), String.t()) :: String.t()
  def module_name(root, path) do
    parts = path |> Path.rootname(".py") |> Path.split() |> Enum.reject(&(&1 == "."))

    parts =
      case parts do
        ["src" | rest] when rest != [] -> if File.exists?(Path.join([root, "src", "__init__.py"])), do: parts, else: rest
        _ -> parts
      end

    parts = if List.last(parts) == "__init__" and length(parts) > 1, do: Enum.drop(parts, -1), else: parts
    Enum.join(parts, ".")
  end

  defp parent(module), do: module |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

  @doc """
  The top-level functions, in order: `%{module:, name:, anykey: nil,
  visibility: "public", span: line, body_hash:, text:}` (`text` is the
  function's lines, blanked; the decorators above it are not part of it).
  A name defined twice is its last definition, as Python binds it.
  """
  @spec definitions(String.t(), String.t()) :: [map()]
  def definitions(source, module) do
    source
    |> blank()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> blocks()
    |> Enum.flat_map(fn {n, block} ->
      case Regex.run(~r/^(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(/, block) do
        [_, name] ->
          hash = :crypto.hash(:sha256, String.trim(block)) |> Base.encode16(case: :lower)
          [%{module: module, name: name, anykey: nil, visibility: "public", span: n, body_hash: hash, text: block}]

        nil ->
          []
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.name)
    |> Enum.reverse()
  end

  # a column-0 line and the indented (or blank) lines after it; a line
  # inside an open bracket (a def's parameters over several lines) stays
  # with its block -- the text is blanked, so brackets in strings don't count
  defp blocks(lines) do
    lines
    |> Enum.chunk_while(
      {nil, 0},
      fn {line, n}, {acc, depth} ->
        depth2 = depth + bracket_delta(line)

        cond do
          acc != nil and (depth > 0 or String.trim(line) == "" or String.match?(line, ~r/^\s/)) ->
            {:cont, {{elem(acc, 0), [line | elem(acc, 1)]}, depth2}}

          acc == nil and (String.trim(line) == "" or String.match?(line, ~r/^\s/)) ->
            {:cont, {nil, depth2}}

          acc == nil ->
            {:cont, {{n, [line]}, depth2}}

          true ->
            {:cont, acc, {{n, [line]}, depth2}}
        end
      end,
      fn
        {nil, _} -> {:cont, nil}
        {acc, _} -> {:cont, acc, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {n, ls} -> {n, ls |> Enum.reverse() |> Enum.join("\n")} end)
  end

  defp bracket_delta(line) do
    opens = length(Regex.scan(~r/[(\[{]/, line))
    closes = length(Regex.scan(~r/[)\]}]/, line))
    opens - closes
  end

  # {modules: local name -> module, names: local name -> {module, name}},
  # for the module-level imports of a file whose package is `package`
  defp imports(text, package) do
    # `from m import (a, b,\n    c)` made one line first: its continuation lines are indented
    text =
      Regex.replace(~r/^(from\s+\.*[\w.]*\s+import\s*)\(([^)]*)\)/m, text, fn _, head, inner ->
        head <> (inner |> String.replace(~r/#[^\n]*/, "") |> String.replace(~r/\s+/, " ") |> String.trim())
      end)

    top = text |> String.split("\n") |> Enum.reject(&String.match?(&1, ~r/^\s/)) |> Enum.join("\n")

    plain =
      for [_, list] <- Regex.scan(~r/^import\s+([^\n#]+)/m, top),
          item <- String.split(list, ","),
          [_, mod, as] <- [Regex.run(~r/^\s*([\w.]+)(?:\s+as\s+(\w+))?\s*$/, item) |> pad(3)],
          reduce: %{} do
        acc ->
          # `import a.b` binds `a` (a.b.f is then written out); `import a.b as x` binds x
          if as == "", do: Map.put(acc, mod |> String.split(".") |> hd(), :package_root), else: Map.put(acc, as, mod)
      end

    from =
      for [_, dots, mod, list] <- Regex.scan(~r/^from\s+(\.*)([\w.]*)\s+import\s+\(?([^\n#)]+)/m, top),
          base = resolve_from(dots, mod, package),
          base != nil,
          item <- String.split(list, ","),
          [_, name, as] <- [Regex.run(~r/^\s*(\w+)(?:\s+as\s+(\w+))?\s*$/, item) |> pad(3)],
          name != "*",
          do: {if(as == "", do: name, else: as), base, name}

    modules = Map.new(plain, fn {k, v} -> {k, v} end)
    # `from geo import shape` may bind a module (geo.shape) or a function (geo's shape): both kept
    modules = Enum.reduce(from, modules, fn {local, base, name}, acc -> Map.put_new(acc, local, join(base, name)) end)
    names = Map.new(from, fn {local, base, name} -> {local, {base, name}} end)
    {modules, names}
  end

  defp pad(nil, _n), do: nil
  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  defp resolve_from("", mod, _package), do: mod

  defp resolve_from(dots, mod, package) do
    parts = if package == "", do: [], else: String.split(package, ".")
    up = String.length(dots) - 1

    if up > length(parts),
      do: nil,
      else: parts |> Enum.drop(-up) |> Enum.join(".") |> join(mod)
  end

  defp join("", b), do: b
  defp join(a, ""), do: a
  defp join(a, b), do: a <> "." <> b

  # {module, name, nil} keys a definition's text may call
  defp calls(text, self, module, local, modules, names) do
    body = Regex.replace(~r/^(?:async\s+)?def\s+\w+/, text, "")

    dotted =
      for [_, chain] <- Regex.scan(~r/(?<![\w.])([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+)/, body),
          [head | rest] = String.split(chain, "."),
          key <- dotted_key(head, rest, modules),
          do: key

    bare =
      for([_, n] <- Regex.scan(~r/(?<![\w.])([A-Za-z_]\w*)(?!\s*\.)/, body), n != self and n not in @keywords, uniq: true, do: n)
      |> Enum.flat_map(&bare_key(&1, module, local, names))

    dotted ++ bare
  end

  defp dotted_key(head, rest, modules) do
    case Map.get(modules, head) do
      nil -> []
      # `import a.b` then `a.b.f`: the module is the chain without its last name
      :package_root -> [{Enum.join([head | Enum.drop(rest, -1)], "."), List.last(rest), nil}]
      mod -> [{Enum.join([mod | Enum.drop(rest, -1)], "."), List.last(rest), nil}]
    end
  end

  defp bare_key(n, module, local, names) do
    cond do
      MapSet.member?(local, n) -> [{module, n, nil}]
      Map.has_key?(names, n) -> [names |> Map.fetch!(n) |> then(fn {m, f} -> {m, f, nil} end)]
      true -> []
    end
  end

  @doc """
  `source` with comments and string literals (single, double, triple-quoted,
  with prefixes such as `r`, `b`, `f`) replaced by spaces, newlines kept.
  An f-string's expressions are blanked with it.
  """
  @spec blank(String.t()) :: String.t()
  def blank(source), do: source |> String.graphemes() |> blank(:code, nil, []) |> IO.iodata_to_binary()

  defp blank([], _mode, _q, acc), do: Enum.reverse(acc)
  defp blank(["#" | rest], :code, q, acc), do: blank(rest, :comment, q, [" " | acc])
  defp blank(["\n" | rest], :comment, q, acc), do: blank(rest, :code, q, ["\n" | acc])
  defp blank([q, q, q | rest], :code, _q, acc) when q in ["\"", "'"], do: blank(rest, :string, q <> q <> q, [q <> q <> q | acc])
  defp blank([q | rest], :code, _q, acc) when q in ["\"", "'"], do: blank(rest, :string, q, [q | acc])
  defp blank(["\\", c | rest], :string, q, acc), do: blank(rest, :string, q, [keep(c), " " | acc])

  defp blank([c | rest] = all, :string, q, acc) do
    cond do
      String.length(q) == 3 and Enum.take(all, 3) == String.graphemes(q) ->
        blank(Enum.drop(all, 3), :code, nil, [q | acc])

      String.length(q) == 1 and c == q ->
        blank(rest, :code, nil, [q | acc])

      # an unterminated one-line string ends at the line's end
      String.length(q) == 1 and c == "\n" ->
        blank(rest, :code, nil, ["\n" | acc])

      true ->
        blank(rest, :string, q, [keep(c) | acc])
    end
  end

  defp blank([c | rest], :code, q, acc), do: blank(rest, :code, q, [c | acc])
  defp blank([c | rest], mode, q, acc), do: blank(rest, mode, q, [keep(c) | acc])

  defp keep("\n"), do: "\n"
  defp keep(_), do: " "
end
