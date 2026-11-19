Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)

defmodule XipeTotec.Scanner.JavaScript do
  @moduledoc """
  JavaScript's and TypeScript's scan, read from the text -- no Node or
  TypeScript toolchain needed. Both are map-only languages: their
  functions become cards and links, never calc rows
  ([D-map-only-language](../../document/verification/lib-repl-language.exs.md#d-map-only-language)).

  **Modules**: a file's module is its path without its extension
  (`lib/core/commands.js` is `lib/core/commands`, `src/a/index.ts` is
  `src/a/index`). Declaration files (`*.d.ts`) have no definitions.

  **Definitions**, at the top level (a statement starting at column 0):
  `function f`, `async function f`, `function* f`, `export (default)
  function f`, and `const` / `let` / `var` bound to a function expression
  or an arrow function (`const f = (x) => …`, `export const f = async x =>
  …`, `const f = function …`). Classes, their methods, object members and
  nested functions are not. `anykey` is `nil`. `visibility` is `"public"`
  for a function exported (`export …`, `export { f, g as h }`,
  `module.exports = { f }`, `exports.f = …`), else `"private"`.

  **Links**, from a definition's text (comments and strings blanked): a
  name of another definition in the same module, a name imported from a
  project file (`import { f, g as h } from "./m"`, `import d from "./m"`
  for `./m`'s `export default function d`, `const { f } = require("./m")`),
  and `ns.f` for a namespace (`import * as ns from "./m"`, `const ns =
  require("./m")`). Only relative specifiers (`./`, `../`) are project
  files; a specifier without its extension, or with `.js` naming a `.ts`
  file, and a directory's `index` are found on disk. Names a local
  variable shadows are taken for calls (the links are what the text
  suggests).
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.Scanner

  @extensions ~w(ts tsx mts cts js jsx mjs cjs)
  @ident "[A-Za-z_$][\\w$]*"

  @impl Scanner
  def scan_defs(book, sheet_id, %{path: path, source: source}) do
    Scanner.put_defs(book, sheet_id, definitions(source, path))
  end

  @impl Scanner
  def scan_links_report(book, node_ids, %{root: root, path: path, source: source}) do
    module = module_name(path)
    {namespaces, names} = imports(source, root, path)
    defs = definitions(source, path)
    own = for d <- defs, id = node_ids[{module, d.name, nil}], do: {d, id}
    local = MapSet.new(defs, & &1.name)

    links =
      for {d, caller} <- own,
          key <- calls(d.text, d.name, module, local, namespaces, names),
          ref = Scanner.node_for(book, node_ids, key),
          ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), []}
  end

  @doc "The module a file is: its path (relative to the project's root) without its extension."
  @spec module_name(String.t()) :: String.t()
  def module_name(path), do: path |> Path.rootname() |> Path.split() |> Enum.reject(&(&1 == ".")) |> Path.join()

  @doc """
  The top-level functions, in order: `%{module:, name:, anykey: nil,
  visibility:, span: line, body_hash:, text:}` (`text` the definition's
  lines, blanked). A name defined twice is its last definition.
  """
  @spec definitions(String.t(), String.t()) :: [map()]
  def definitions(source, path) do
    if String.ends_with?(path, ".d.ts") do
      []
    else
      module = module_name(path)
      {wrapped?, lines} = text_lines(blank(source))
      text = Enum.map_join(lines, "\n", &elem(&1, 0))
      exported = if wrapped?, do: MapSet.union(exported_names(text), published_names(lines)), else: exported_names(text)

      lines
      |> blocks()
      |> Enum.flat_map(fn {n, block} ->
        case definition(block) do
          {name, export?} ->
            hash = :crypto.hash(:sha256, String.trim(block)) |> Base.encode16(case: :lower)
            visibility = if export? or MapSet.member?(exported, name), do: "public", else: "private"
            [%{module: module, name: name, anykey: nil, visibility: visibility, span: n, body_hash: hash, text: block}]

          nil ->
            []
        end
      end)
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.name)
      |> Enum.reverse()
    end
  end

  # The lines read as the top level, numbered as in the file, and whether
  # they are a wrapper's inside. A file that is one function expression
  # called at once -- `(function (root) { … })(this);`, `(() => { … })();`,
  # `!function () { … }();`, the browser-script and UMD pattern -- has its
  # definitions one level in: that body, dedented, is the top level
  defp text_lines(text) do
    lines = text |> String.split("\n") |> Enum.with_index(1)
    blank? = fn {l, _} -> String.trim(l) == "" end
    # leading blank lines and directives (`'use strict';`, blanked to its quotes)
    {head, rest} = Enum.split_while(lines, fn {l, _} -> String.match?(l, ~r/^\s*(?:['"]\s*['"]\s*;?)?\s*$/) end)
    body = rest |> Enum.reverse() |> Enum.drop_while(blank?) |> Enum.reverse()

    with [{open, _}, _ | _] <- body,
         true <- String.match?(open, ~r/^[;!+]?\(?\s*(?:async\s+)?(?:function\b[^{]*|\([^)]*\)\s*=>\s*|[\w$]+\s*=>\s*)\{\s*$/),
         {close, _} = List.last(body),
         true <- String.match?(close, ~r/^\}/),
         inner = body |> tl() |> Enum.drop(-1),
         true <- inner != [] and Enum.all?(inner, &(blank?.(&1) or String.match?(elem(&1, 0), ~r/^\s/))) do
      indent =
        inner
        |> Enum.reject(blank?)
        |> Enum.map(fn {l, _} -> byte_size(l) - byte_size(String.trim_leading(l)) end)
        |> Enum.min(fn -> 0 end)

      {true, Enum.map(inner, fn {l, n} -> {binary_part(l, min(indent, byte_size(l)), byte_size(l) - min(indent, byte_size(l))), n} end)}
    else
      _ -> {false, head ++ rest}
    end
  end

  # inside a wrapper, what is published by assigning to a property
  # (`Tezcatl.commands = { load: load }`, `root.f = f`, `exports.g = g`):
  # every name such a statement mentions
  defp published_names(lines) do
    lines
    |> blocks()
    |> Enum.filter(fn {_, block} -> String.match?(block, ~r/\A[\w$]+(?:\.[\w$]+)+\s*=[^=]/) end)
    |> Enum.flat_map(fn {_, block} -> for [_, n] <- Regex.scan(~r/(?<![\w$.])(#{@ident})(?![\w$])/, block), do: n end)
    |> MapSet.new()
  end

  # {name, exported?} when the block defines a function
  defp definition(block) do
    function = ~r/\A(export\s+(?:default\s+)?)?(?:declare\s+)?(?:async\s+)?function\s*\*?\s*(#{@ident})\s*[<(]/
    binding = ~r/\A(export\s+)?(?:const|let|var)\s+(#{@ident})\s*(?::[^=]*)?=\s*(?:async\s+)?/

    cond do
      m = Regex.run(function, block) ->
        [_, export, name] = m
        {name, export != ""}

      m = Regex.run(binding, block, return: :index) ->
        [{0, len} | _] = m
        [_, export, name] = Regex.run(binding, block)
        if function_value?(binary_part(block, len, byte_size(block) - len)), do: {name, export != ""}

      true ->
        nil
    end
  end

  # the text after `const f = (async)`: a function expression or an arrow function
  defp function_value?(rest) do
    String.match?(rest, ~r/\Afunction\b/) or
      String.match?(rest, ~r/\A#{@ident}\s*=>/) or
      String.match?(rest, ~r/\A(?:<[^>]*>\s*)?\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)\s*(?::[^=;{]*)?=>/s)
  end

  # names exported apart from their definition: `export { f, g as h }`,
  # `module.exports = { f, g: h }`, `exports.f = …`, `module.exports.f = …`
  defp exported_names(text) do
    lists =
      for [_, list] <- Regex.scan(~r/^export\s*\{([^}]*)\}/m, text),
          item <- String.split(list, ","),
          [_, name] <- [Regex.run(~r/^\s*(?:type\s+)?(#{@ident})/, item)],
          do: name

    commonjs =
      for [_, list] <- Regex.scan(~r/^module\.exports\s*=\s*\{([^}]*)\}/m, text),
          item <- String.split(list, ","),
          # `{ f }` and `{ g: f }` both export the definition f
          [_, name] <- [Regex.run(~r/(#{@ident})\s*$/, String.trim(item))],
          do: name

    assigned =
      for [_, name] <- Regex.scan(~r/^(?:module\.)?exports\.#{@ident}\s*=\s*(#{@ident})\s*;?\s*$/m, text), do: name

    MapSet.new(lists ++ commonjs ++ assigned)
  end

  # a column-0 line and the lines after it that are indented, blank, inside
  # an open bracket, or closing one at column 0 (`}` / `})` / `];`)
  defp blocks(lines) do
    lines
    |> Enum.chunk_while(
      {nil, 0},
      fn {line, n}, {acc, depth} ->
        depth2 = depth + bracket_delta(line)
        continues? = depth > 0 or String.trim(line) == "" or String.match?(line, ~r/^\s|^[)\]}]/)

        cond do
          acc != nil and continues? -> {:cont, {{elem(acc, 0), [line | elem(acc, 1)]}, depth2}}
          acc == nil and continues? -> {:cont, {nil, depth2}}
          acc == nil -> {:cont, {{n, [line]}, depth2}}
          true -> {:cont, acc, {{n, [line]}, depth2}}
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

  defp bracket_delta(line), do: length(Regex.scan(~r/[(\[{]/, line)) - length(Regex.scan(~r/[)\]}]/, line))

  # --- imports ---------------------------------------------------------------

  # {namespaces: local -> module, names: local -> {module, name}} for the
  # project files `path` imports (relative specifiers only)
  defp imports(source, root, path) do
    # the statements are found in the blanked text (no commented-out import
    # counts); the specifier is read from the source at the same place
    text = blank(source)

    es =
      for [{start, len}] <- Regex.scan(~r/^import\s[^;'"`]*?from\s*(['"])[^\n]*?\1/ms, text, return: :index) |> Enum.map(&[hd(&1)]),
          statement = binary_part(source, start, len),
          [_, clause, spec] <- [Regex.run(~r/\Aimport\s+(?:type\s+)?(.*?)\s*from\s*['"]([^'"]+)['"]\z/s, statement)],
          module = resolve(root, path, spec),
          module != nil,
          binding <- es_bindings(strip_comments(clause), module, root),
          do: binding

    cjs =
      for [{start, len}] <- Regex.scan(~r/^(?:const|let|var)\s[^;=]*=\s*require\s*\(\s*(['"])[^\n]*?\1\s*\)/ms, text, return: :index) |> Enum.map(&[hd(&1)]),
          statement = binary_part(source, start, len),
          [_, pattern, spec] <- [Regex.run(~r/\A(?:const|let|var)\s+(.*?)\s*=\s*require\s*\(\s*['"]([^'"]+)['"]\s*\)\z/s, statement)],
          module = resolve(root, path, spec),
          module != nil,
          binding <- cjs_bindings(strip_comments(pattern), module),
          do: binding

    bindings = es ++ cjs
    {for({:ns, local, mod} <- bindings, into: %{}, do: {local, mod}), for({:name, local, key} <- bindings, into: %{}, do: {local, key})}
  end

  defp strip_comments(text), do: text |> String.replace(~r{//[^\n]*}, "") |> String.replace(~r{/\*.*?\*/}s, "")

  # `d`, `d, { a, b as c }`, `{ a }`, `* as ns`, `d, * as ns`
  defp es_bindings(clause, module, root) do
    named =
      case Regex.run(~r/\{([^}]*)\}/s, clause) do
        [_, list] ->
          for item <- String.split(list, ","),
              [_, name, as] <- [Regex.run(~r/^\s*(?:type\s+)?(#{@ident})(?:\s+as\s+(#{@ident}))?\s*$/, item) |> pad()],
              do: {:name, if(as == "", do: name, else: as), {module, name}}

        nil ->
          []
      end

    ns = for [_, local] <- Regex.scan(~r/\*\s*as\s+(#{@ident})/, clause), do: {:ns, local, module}

    default =
      with [_, local] <- Regex.run(~r/\A\s*(#{@ident})\s*(?:,|\z)/, clause),
           name when name != nil <- default_export(root, module) do
        [{:name, local, {module, name}}]
      else
        _ -> []
      end

    named ++ ns ++ default
  end

  # `ns` or `{ a, b: c }`
  defp cjs_bindings(pattern, module) do
    case Regex.run(~r/\A\{(.*)\}\z/s, String.trim(pattern)) do
      [_, list] ->
        for item <- String.split(list, ","),
            [_, name, as] <- [Regex.run(~r/^\s*(#{@ident})(?:\s*:\s*(#{@ident}))?\s*$/, item) |> pad()],
            do: {:name, if(as == "", do: name, else: as), {module, name}}

      nil ->
        if String.match?(String.trim(pattern), ~r/\A#{@ident}\z/), do: [{:ns, String.trim(pattern), module}], else: []
    end
  end

  defp pad(nil), do: nil
  defp pad(list), do: list ++ List.duplicate("", 3 - length(list))

  # the name of the function `module`'s file exports as default, if any
  defp default_export(root, module) do
    with file when file != nil <- Enum.find(Enum.map(@extensions, &"#{module}.#{&1}"), &File.regular?(Path.join(root, &1))),
         {:ok, source} <- File.read(Path.join(root, file)),
         [_, name] <- Regex.run(~r/^export\s+default\s+(?:async\s+)?function\s*\*?\s*(#{@ident})/m, blank(source)) do
      name
    else
      _ -> nil
    end
  end

  # a relative specifier from the file `path` -> the module it names (a
  # file on disk), or nil (a package, or nothing there)
  @doc false
  def resolve(root, path, "." <> _ = spec) do
    joined = Path.join(Path.dirname(path), spec)
    rel = root |> Path.join(joined) |> Path.expand() |> Path.relative_to(Path.expand(root))
    bare = if Path.extname(rel) in Enum.map(@extensions, &("." <> &1)), do: Path.rootname(rel), else: rel

    candidates = Enum.map(@extensions, &"#{bare}.#{&1}") ++ Enum.map(@extensions, &"#{rel}/index.#{&1}")

    case Enum.find(candidates, &File.regular?(Path.join(root, &1))) do
      nil -> nil
      file -> module_name(file)
    end
  end

  def resolve(_root, _path, _spec), do: nil

  # --- calls -------------------------------------------------------------------

  defp calls(text, self, module, local, namespaces, names) do
    # the definition's own name and parameters' head left out
    body = Regex.replace(~r/\A.*?#{Regex.escape(self)}/s, text, "", global: false)

    dotted =
      for [_, ns, f] <- Regex.scan(~r/(?<![\w$.])(#{@ident})\s*\.\s*(#{@ident})/, body),
          mod = Map.get(namespaces, ns),
          mod != nil,
          do: {mod, f, nil}

    bare =
      for([_, n] <- Regex.scan(~r/(?<![\w$.])(#{@ident})(?![\w$])/, body), n != self, uniq: true, do: n)
      |> Enum.flat_map(fn n ->
        cond do
          MapSet.member?(local, n) -> [{module, n, nil}]
          Map.has_key?(names, n) -> [names |> Map.fetch!(n) |> then(fn {m, f} -> {m, f, nil} end)]
          true -> []
        end
      end)

    dotted ++ bare
  end

  # --- blanking ---------------------------------------------------------------

  @doc """
  `source` with comments (`//`, `/* */`) and string literals (`'…'`, `"…"`,
  template literals with their `${…}`) replaced by spaces; quotes and
  newlines kept, so offsets and lines match the source. Regular-expression
  literals are not recognised.
  """
  @spec blank(String.t()) :: String.t()
  def blank(source), do: source |> String.graphemes() |> blank(:code, nil, []) |> IO.iodata_to_binary()

  defp blank([], _mode, _q, acc), do: Enum.reverse(acc)
  defp blank(["/", "/" | rest], :code, q, acc), do: blank(rest, :line_comment, q, ["  " | acc])
  defp blank(["/", "*" | rest], :code, q, acc), do: blank(rest, :block_comment, q, ["  " | acc])
  defp blank(["\n" | rest], :line_comment, q, acc), do: blank(rest, :code, q, ["\n" | acc])
  defp blank(["*", "/" | rest], :block_comment, q, acc), do: blank(rest, :code, q, ["  " | acc])
  defp blank([q | rest], :code, _q, acc) when q in ["\"", "'", "`"], do: blank(rest, :string, q, [q | acc])
  defp blank(["\\", c | rest], :string, q, acc), do: blank(rest, :string, q, [keep(c), " " | acc])
  defp blank([q | rest], :string, q, acc), do: blank(rest, :code, nil, [q | acc])
  # an unterminated one-line string ends at the line's end (a template literal spans lines)
  defp blank(["\n" | rest], :string, q, acc) when q != "`", do: blank(rest, :code, nil, ["\n" | acc])
  defp blank([c | rest], :code, q, acc), do: blank(rest, :code, q, [c | acc])
  defp blank([c | rest], mode, q, acc), do: blank(rest, mode, q, [keep(c) | acc])

  defp keep("\n"), do: "\n"
  defp keep(c), do: String.duplicate(" ", byte_size(c))
end
