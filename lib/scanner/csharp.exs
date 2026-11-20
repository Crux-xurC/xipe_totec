Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)

defmodule XipeTotec.Scanner.CSharp do
  @moduledoc """
  C#'s scan, read from the text -- no SDK or language server needed
  ([D-csharp-adapter](../../document/verification/lib-repl-language-csharp.exs.md#d-csharp-adapter)).

  **Structure**: the text with comments, strings, chars and preprocessor
  lines blanked is read by its braces: namespaces (`namespace A.B { … }`
  and the file-scoped `namespace A.B;`), types (`class`, `struct`,
  `record`, `record struct`, `interface`, `enum`, nested ones too) and,
  directly in a type's body, methods -- a block body (`{ … }`) or an
  expression body (`=> …;`). Constructors, properties, indexers, operators,
  local functions and lambdas are not methods here.

  **Definitions**: every method is a node. `module` is the namespace and
  the type chain (`Sample.Geo.Shapes`, `Sample.Geo.Outer.Inner`), `name`
  the method's, `anykey` the sequence of its parameters' types
  (`(int, int)`, `(string, out int)`, `(params int[])`; `parameters/1`
  says how they are written), so every overload is a node of its own; the
  shape is the number of arguments a caller writes, one list (`out`
  parameters left out, optional ones counted, a `params` array one)
  ([D-anykey-shape](../../document/verification/lib-identity.exs.md#d-anykey-shape)).
  `marks` is `["async"]` for a method returning `Task`, `Task<T>`,
  `ValueTask` or `ValueTask<T>` (the call is awaited); `refusal` the
  reason `row/add` refuses a method whose type parameter appears in no
  parameter (`Make<T>()`: without a type argument it would run as `obj`)
  ([D-node-marks](../../document/verification/lib-identity.exs.md#d-node-marks)). `visibility`
  is `"public"` only for what F# Interactive can call with literal
  arguments: a `public static` method of a type that is public all the way
  out and not generic. Instance methods, `internal` and `private` ones are
  `"private"`: on the map, not calc rows.

  **Links**, from a method's body: a call `Name(…)` to a method of its own
  type or an enclosing one, or of a type named by `using static`;
  `Type.Name(…)` and `Ns.Type.Name(…)` to a project type, found the way C#
  looks a type up (the enclosing namespaces, nested types, `using`
  namespaces, then the name as written); `this.Name(…)`. The arguments are
  counted to pick the overloads of that count (all of them when several
  share it: the arguments' types are not known); with none of that count,
  every overload of the name (default and `params` parameters). Calls
  on a value (`list.Add(…)`, `shape.Area()`) are not links: the scan does
  not know a variable's type.
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.Scanner

  @ident "@?[A-Za-z_][A-Za-z0-9_]*"
  @modifiers ~w(public private protected internal static async unsafe extern new virtual override abstract sealed partial readonly file required volatile)

  @impl Scanner
  def scan_defs(book, sheet_id, %{path: path, source: source}) do
    defs = definitions(source, path)
    Scanner.put_defs(book, sheet_id, Enum.map(defs, &Map.drop(&1, [:body, :scope])))
  end

  @impl Scanner
  def scan_links_report(book, node_ids, %{source: source, path: path}) do
    defs = definitions(source, path)
    usings = usings(blank(source))
    index = Enum.group_by(Map.keys(node_ids), fn {m, n, _} -> {m, n} end)
    modules = node_ids |> Map.keys() |> MapSet.new(&elem(&1, 0))
    own = for d <- defs, id = node_ids[{d.module, d.name, d.anykey}], do: {d, id}

    links =
      for {d, caller} <- own,
          key <- calls(d, usings, modules, index),
          ref = Scanner.node_for(book, node_ids, key),
          ref != nil and ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), []}
  end

  # --- definitions ---------------------------------------------------------------

  @doc """
  The methods, in order: `%{module:, name:, anykey:, visibility:, span:
  line, body_hash:, body:, scope:}` -- `body` the method's body, blanked;
  `scope` `%{namespace:, types:}` (the type chain as written).
  """
  @spec definitions(String.t(), String.t()) :: [map()]
  def definitions(source, _path) do
    text = blank(source)

    text
    |> walk(0, 0, [], nil, [])
    |> Enum.reverse()
    |> Enum.map(fn m ->
      member = binary_part(source, m.start, m.stop - m.start) |> String.trim()
      hash = :crypto.hash(:sha256, member) |> Base.encode16(case: :lower)
      line = text |> binary_part(0, m.name_at) |> String.split("\n") |> length()
      module = Enum.join(Enum.reject([m.namespace | Enum.map(m.types, & &1.name)], &(&1 in [nil, ""])), ".")

      public? =
        m.types != [] and Enum.all?(m.types, &(&1.public? and not &1.generic?)) and
          "public" in m.modifiers and "static" in m.modifiers

      params = parameters(m.params)

      %{
        module: module,
        name: m.name,
        anykey: "(" <> Enum.map_join(params, ", ", & &1.text) <> ")",
        # an `out` parameter is not written by the caller; `params` counts as one (§4.4 rule 4)
        shape: [Enum.count(params, &(&1.mod != "out"))],
        marks: if(task?(m.return), do: ["async"], else: []),
        refusal: unbound_type_parameter(m.generics, params),
        visibility: if(public?, do: "public", else: "private"),
        span: line,
        body_hash: hash,
        body: binary_part(text, m.body_at, m.stop - m.body_at),
        scope: %{namespace: m.namespace, types: Enum.map(m.types, & &1.name)}
      }
    end)
    |> Enum.uniq_by(&{&1.module, &1.name, &1.anykey})
  end

  # Walk the blanked text by its braces and semicolons. `seg` is where the
  # current member's text began (meaningful at the top level, in a
  # namespace or directly in a type); `stack` holds the open braces'
  # frames; `file_ns` a file-scoped namespace.
  defp walk(text, pos, _seg, _stack, _file_ns, acc) when pos >= byte_size(text), do: acc

  defp walk(text, pos, seg, stack, file_ns, acc) do
    case :binary.at(text, pos) do
      ?{ ->
        frame = open_frame(binary_part(text, seg, pos - seg), seg, pos, stack, file_ns)
        walk(text, pos + 1, pos + 1, [frame | stack], file_ns, acc)

      ?} ->
        case stack do
          [] ->
            walk(text, pos + 1, pos + 1, stack, file_ns, acc)

          [%{kind: :method} = f | rest] ->
            walk(text, pos + 1, pos + 1, rest, file_ns, [Map.put(f.method, :stop, pos + 1) | acc])

          [%{kind: kind} | rest] when kind in [:namespace, :type, :other] ->
            walk(text, pos + 1, pos + 1, rest, file_ns, acc)

          # a brace inside a member's expression (`=> new List<T> { x, x };`):
          # the member goes on from where it began
          [%{kind: :expr, seg: start} | rest] ->
            walk(text, pos + 1, start, rest, file_ns, acc)

          # the end of a brace inside a member's expression: the member goes on
          [_ | rest] ->
            walk(text, pos + 1, seg, rest, file_ns, acc)
        end

      ?; ->
        header = binary_part(text, seg, pos - seg)

        case stack do
          [%{kind: :type} | _] ->
            acc =
              case expression_method(header, seg, pos, stack, file_ns) do
                nil -> acc
                m -> [m | acc]
              end

            walk(text, pos + 1, pos + 1, stack, file_ns, acc)

          [%{kind: :namespace} | _] ->
            walk(text, pos + 1, pos + 1, stack, file_ns, acc)

          [] ->
            file_ns =
              case Regex.run(~r/\A\s*namespace\s+([\w.]+)\s*\z/, header) do
                [_, ns] -> ns
                nil -> file_ns
              end

            walk(text, pos + 1, pos + 1, stack, file_ns, acc)

          _ ->
            walk(text, pos + 1, seg, stack, file_ns, acc)
        end

      _ ->
        walk(text, pos + 1, seg, stack, file_ns, acc)
    end
  end

  defp open_frame(header, seg, pos, stack, file_ns) do
    level = stack |> List.first() |> then(&(&1 && &1.kind))
    head = strip_attributes(header)

    cond do
      level in [nil, :namespace] ->
        cond do
          m = Regex.run(~r/\A\s*namespace\s+([\w.]+)\s*\z/, head) -> %{kind: :namespace, name: Enum.at(m, 1)}
          t = type_header(head) -> Map.put(t, :kind, :type)
          true -> %{kind: :other}
        end

      level == :type ->
        cond do
          t = type_header(head) ->
            Map.put(t, :kind, :type)

          expression?(head) ->
            %{kind: :expr, seg: seg}

          m = method_header(head) ->
            %{kind: :method, method: method(m, header, seg, pos + 1, stack, file_ns)}

          true ->
            %{kind: :other}
        end

      true ->
        %{kind: :block}
    end
  end

  # `int F(int x) => x + 1;` directly in a type
  defp expression_method(header, seg, stop, stack, file_ns) do
    head = strip_attributes(header)

    with [before, _after] <- String.split(head, "=>", parts: 2),
         false <- String.contains?(strip_parens(before), "="),
         m when m != nil <- method_header(before) do
      arrow = seg + byte_size(header) - byte_size(head) + byte_size(before) + 2
      method(m, header, seg, arrow, stack, file_ns) |> Map.put(:stop, stop + 1)
    else
      _ -> nil
    end
  end

  defp method(m, header, seg, body_at, stack, file_ns) do
    lead = byte_size(header) - byte_size(String.trim_leading(header))

    %{
      name: m.name,
      params: m.params,
      generics: m.generics,
      return: m.return,
      modifiers: m.modifiers,
      start: seg + lead,
      name_at: seg + name_offset(header, m.name),
      body_at: body_at,
      namespace: namespace(stack, file_ns),
      types: stack |> Enum.filter(&(&1.kind == :type)) |> Enum.reverse()
    }
  end

  defp name_offset(header, name) do
    case Regex.run(~r/(?<![\w@])@?#{Regex.escape(name)}\s*(?:<[^()]*>)?\s*\(/, header, return: :index) do
      [{at, _} | _] -> at
      nil -> byte_size(header) - byte_size(String.trim_leading(header))
    end
  end

  defp namespace(stack, file_ns) do
    names = for %{kind: :namespace, name: n} <- Enum.reverse(stack), do: n
    Enum.join(Enum.reject([file_ns | names], &is_nil/1), ".")
  end

  defp strip_attributes(header) do
    case Regex.run(~r/\A\s*\[[^\[\]]*(?:\[[^\[\]]*\][^\[\]]*)*\]/, header) do
      [attr] -> strip_attributes(binary_part(header, byte_size(attr), byte_size(header) - byte_size(attr)))
      nil -> header
    end
  end

  # a type's header: `public static class Ops`, `record Point(double X)`, `struct Box<T> : I`
  defp type_header(head) do
    pre = head |> String.split("(", parts: 2) |> hd()

    case Regex.run(~r/(?:\A|\s)(?:class|struct|interface|enum|record(?:\s+(?:struct|class))?)\s+(#{@ident})\s*(<)?/, pre) do
      [whole, name | generic] ->
        mods = pre |> String.split(whole, parts: 2) |> hd()
        %{name: String.trim_leading(name, "@"), public?: Regex.match?(~r/\bpublic\b/, mods), generic?: generic != []}

      nil ->
        nil
    end
  end

  # a field or property initializer, an expression-bodied property: `=` outside parentheses
  defp expression?(head), do: head |> strip_parens() |> String.contains?("=")

  defp strip_parens(text) do
    case Regex.replace(~r/\([^()]*\)/, text, "") do
      ^text -> text
      fewer -> strip_parens(fewer)
    end
  end

  # `mods ret Name<T>(params) where …`: %{name:, params:, generics:, return:,
  # modifiers:}, or nil for a constructor, an operator, a property, an
  # explicit interface member
  defp method_header(head) do
    main = head |> String.split(~r/\swhere\s/, parts: 2) |> hd() |> String.trim_trailing()

    with {pre, params} <- last_parens(main),
         {pre, generics} = pre |> String.trim() |> strip_generic(),
         [_, before, name] <- Regex.run(~r/\A(.*?)\s*(#{@ident})\z/s, pre),
         false <- String.ends_with?(before, "."),
         {modifiers, return} = split_modifiers(before),
         true <- return != "" and not Regex.match?(~r/\b(?:operator|delegate|event)\b/, return),
         false <- name in ["if", "while", "for", "foreach", "switch", "using", "lock", "catch", "return", "new"] do
      %{name: String.trim_leading(name, "@"), params: params, generics: generics, return: type_text(tokens(return)), modifiers: modifiers}
    else
      _ -> nil
    end
  end

  # --- parameters, as anykey writes them (D-anykey-shape) ----------------------------

  @doc """
  A parameter list's parameters, in order: `%{text:, mod:, type:,
  optional?:}`. `text` is what `anykey` holds -- the modifier C# tells
  overloads apart by (`ref`, `out`, `in`; `params` kept to be read) and the
  type, written out again from its tokens in one form: spacing does not
  matter (`List< int >` is `List<int>`, `Dictionary<string,int>` is
  `Dictionary<string, int>`), a tuple's element names are dropped
  (`(int a, string b)` is `(int, string)`), and what only the compiler
  could tell (`int` against `System.Int32`) stays as written. Attributes,
  `this`, `scoped` and a default value are not part of it; a default
  value makes the parameter `optional?`.
  """
  @spec parameters(String.t()) :: [map()]
  def parameters(text) do
    for item <- split_top(text), item = String.trim(strip_attributes(item)), item != "" do
      {decl, default} =
        case split_default(item) do
          {d, nil} -> {d, false}
          {d, _} -> {d, true}
        end

      toks = tokens(decl)
      {mods, rest} = Enum.split_while(toks, &(&1 in ~w(this params ref out in scoped readonly)))
      # the last identifier is the parameter's name
      type = if length(rest) > 1, do: Enum.drop(rest, -1), else: rest
      kept = Enum.filter(mods, &(&1 in ~w(params ref out in readonly)))
      mod = Enum.find(kept, &(&1 in ~w(ref out in)))
      type = type_text(type)
      %{text: Enum.join(kept ++ [type], " "), mod: mod, type: type, optional?: default}
    end
  end

  # a type's tokens: identifiers (with `@`), `::`, single punctuation
  defp tokens(text), do: Regex.scan(~r/@?[A-Za-z_][A-Za-z0-9_]*|::|[^\s\w]/, text) |> List.flatten()

  # tokens joined in one form: `, ` after a comma, nothing elsewhere; an
  # identifier right after a type (a tuple element's name) dropped
  defp type_text(toks) do
    {out, _} =
      Enum.reduce(toks, {[], nil}, fn t, {acc, prev} ->
        ident? = Regex.match?(~r/\A@?[A-Za-z_]/, t)
        ends_type? = prev != nil and (Regex.match?(~r/\A@?[A-Za-z_]/, prev) or prev in [">", "]", "?", ")", "*"])

        cond do
          ident? and ends_type? and prev not in ["::"] -> {acc, prev}
          t == "," -> {[", " | acc], t}
          true -> {[t | acc], t}
        end
      end)

    # `int[,]`: no space before another comma or a closing bracket
    out |> Enum.reverse() |> Enum.join() |> String.replace(~r/, (?=[,\]])/, ",")
  end

  # `int b = 2` -> {"int b", "2"}; the first `=` outside brackets, not `=>`
  defp split_default(item), do: split_default(item, 0, 0)

  defp split_default(item, at, _depth) when at >= byte_size(item), do: {item, nil}

  defp split_default(item, at, depth) do
    case :binary.at(item, at) do
      c when c in ~c"([{<" -> split_default(item, at + 1, depth + 1)
      c when c in ~c")]}>" -> split_default(item, at + 1, max(depth - 1, 0))
      ?= when depth == 0 and binary_part(item, at, min(2, byte_size(item) - at)) != "=>" ->
        {binary_part(item, 0, at), binary_part(item, at + 1, byte_size(item) - at - 1)}
      _ -> split_default(item, at + 1, depth)
    end
  end

  # the comma-separated items at the top level of `text` (`()` `[]` `{}` `<>` nest)
  defp split_top(text) do
    {items, cur, _} =
      for <<c <- text>>, reduce: {[], [], 0} do
        {items, cur, depth} ->
          cond do
            c in ~c"([{<" -> {items, [c | cur], depth + 1}
            c in ~c")]}>" -> {items, [c | cur], max(depth - 1, 0)}
            c == ?, and depth == 0 -> {[cur |> Enum.reverse() |> List.to_string() | items], [], depth}
            true -> {items, [c | cur], depth}
          end
      end

    last = cur |> Enum.reverse() |> List.to_string()
    if String.trim(last) == "" and items == [], do: [], else: Enum.reverse([last | items])
  end

  # `Task`, `Task<T>`, `ValueTask`, `ValueTask<T>` (§4.4 rule 5: the call is awaited)
  defp task?(return), do: Regex.match?(~r/\A(?:System\.Threading\.Tasks\.)?(?:Task|ValueTask)(?:<.*>)?\z/, return)

  # §4.4 rule 3: a type parameter that appears in no parameter cannot be
  # inferred; called without a type argument it would silently be `obj`
  defp unbound_type_parameter(generics, params) do
    used = params |> Enum.flat_map(&tokens(&1.type)) |> MapSet.new()

    case Enum.reject(generics, &MapSet.member?(used, &1)) do
      [] ->
        nil

      free ->
        "its type parameter #{Enum.join(free, ", ")} appears in no parameter: called without a type argument it would run as obj " <>
          "(type arguments are not decided)"
    end
  end

  @doc "The number of arguments a call gives a method whose anykey is `key`: its parameters but `out` ones."
  @spec key_arity(String.t()) :: non_neg_integer()
  def key_arity("(" <> _ = key) do
    key |> String.slice(1..-2//1) |> split_top() |> Enum.reject(&String.starts_with?(String.trim(&1), "out ")) |> length()
  end

  # `pre(params)` split at the parenthesized group `text` ends with
  defp last_parens(text) do
    if String.ends_with?(text, ")") do
      bytes = :binary.bin_to_list(text) |> Enum.reverse() |> tl()

      result =
        Enum.reduce_while(bytes, {1, byte_size(text) - 1}, fn c, {depth, at} ->
          depth = depth + if(c == ?), do: 1, else: if(c == ?(, do: -1, else: 0))
          if depth == 0, do: {:halt, {:open, at - 1}}, else: {:cont, {depth, at - 1}}
        end)

      case result do
        {:open, at} -> {binary_part(text, 0, at), binary_part(text, at + 1, byte_size(text) - at - 2)}
        _ -> nil
      end
    end
  end

  # `Name<T, U>` -> {`Name`, ["T", "U"]}
  defp strip_generic(pre) do
    if String.ends_with?(pre, ">") do
      case Regex.run(~r/\A(.*#{@ident})\s*<([^<>()]*(?:<[^<>()]*>[^<>()]*)*)>\z/s, pre) do
        [_, bare, params] -> {bare, params |> split_top() |> Enum.map(&(&1 |> tokens() |> List.last()))}
        nil -> {pre, []}
      end
    else
      {pre, []}
    end
  end

  defp split_modifiers(before) do
    words = String.split(before)
    {mods, rest} = Enum.split_while(words, &(&1 in @modifiers))
    {mods, Enum.join(rest, " ")}
  end

  @doc "The number of comma-separated items at the top level of `text` (`()` `[]` `{}` `<>` nest)."
  @spec count_args(String.t(), boolean()) :: non_neg_integer()
  def count_args(text, angles \\ true) do
    if String.trim(text) == "" do
      0
    else
      opens = if angles, do: ~c"([{<", else: ~c"([{"
      closes = if angles, do: ~c")]}>", else: ~c")]}"

      {_, commas} =
        for <<c <- text>>, reduce: {0, 0} do
          {depth, n} ->
            cond do
              c in opens -> {depth + 1, n}
              c in closes -> {max(depth - 1, 0), n}
              c == ?, and depth == 0 -> {depth, n + 1}
              true -> {depth, n}
            end
        end

      commas + 1
    end
  end

  # --- links -----------------------------------------------------------------------

  # `using A.B;` and `using static A.B.C;` (aliases left out)
  defp usings(text) do
    for [_, static, name] <- Regex.scan(~r/^\s*(?:global\s+)?using\s+(static\s+)?([\w.]+)\s*;/m, text),
        reduce: %{namespaces: [], static: []} do
      acc ->
        if static == "",
          do: %{acc | namespaces: acc.namespaces ++ [name]},
          else: %{acc | static: acc.static ++ [name]}
    end
  end

  defp calls(d, usings, modules, index) do
    # the enclosing types, innermost first: Ns.Outer.Inner, Ns.Outer
    enclosing =
      for k <- length(d.scope.types)..1//-1,
          do: Enum.join(Enum.reject([d.scope.namespace | Enum.take(d.scope.types, k)], &(&1 in [nil, ""])), ".")

    for [{at, len}, {qs, ql}, {ns, nl}] <- Regex.scan(~r/(?<![\w.@])((?:#{@ident}\s*\.\s*)*)(#{@ident})\s*(?:<[^<>()]*>)?\s*\(/, d.body, return: :index),
        not new?(d.body, at),
        qualifier = binary_part(d.body, qs, ql) |> String.replace(~r/\s/, "") |> String.trim_trailing("."),
        name = binary_part(d.body, ns, nl) |> String.trim_leading("@"),
        argc = d.body |> args_after(at + len) |> count_args(false),
        module <- targets(qualifier, name, d, enclosing, usings, modules, index),
        key <- overloads(index, module, name, argc),
        uniq: true,
        do: key
  end

  defp new?(body, at), do: Regex.match?(~r/\bnew\s*\z/, binary_part(body, 0, at))

  # the text inside the parentheses that open just before `from`
  defp args_after(body, from) do
    rest = binary_part(body, from, byte_size(body) - from)

    {inside, _} =
      Enum.reduce_while(:binary.bin_to_list(rest), {[], 1}, fn c, {acc, depth} ->
        depth = depth + if(c in ~c"([{", do: 1, else: if(c in ~c")]}", do: -1, else: 0))
        if depth == 0, do: {:halt, {acc, 0}}, else: {:cont, {[c | acc], depth}}
      end)

    inside |> Enum.reverse() |> List.to_string()
  end

  # the project modules a call with this qualifier may mean
  defp targets("", name, _d, enclosing, usings, _modules, index) do
    Enum.filter(enclosing ++ usings.static, &Map.has_key?(index, {&1, name}))
    |> Enum.take(1)
  end

  defp targets(q, name, d, enclosing, usings, modules, index) when q in ["this"] do
    targets("", name, d, enclosing, usings, modules, index)
  end

  defp targets(q, _name, d, enclosing, usings, modules, _index) do
    ns_parts = if d.scope.namespace in [nil, ""], do: [], else: String.split(d.scope.namespace, ".")
    namespaces = for k <- length(ns_parts)..1//-1, do: Enum.join(Enum.take(ns_parts, k), ".")

    candidates =
      Enum.map(enclosing, &"#{&1}.#{q}") ++
        Enum.map(namespaces, &"#{&1}.#{q}") ++ Enum.map(usings.namespaces, &"#{&1}.#{q}") ++ [q]

    candidates |> Enum.filter(&MapSet.member?(modules, &1)) |> Enum.take(1)
  end

  defp overloads(index, module, name, argc) do
    keys = Map.get(index, {module, name}, [])

    case Enum.filter(keys, fn {_, _, key} -> key_arity(key) == argc end) do
      [] -> keys
      exact -> exact
    end
  end

  # --- blanking ---------------------------------------------------------------------

  @doc """
  `source` with comments (`//`, `/* */`), string literals (`"…"`, `@"…"`,
  raw `\"\"\"…\"\"\"`), char literals, preprocessor lines (`#region`,
  `#if` …) and a UTF-8 byte order mark replaced by spaces; newlines kept, so
  offsets and lines match the source. An interpolated string's holes
  (`$"…{x}…"`, `$@"…"`) stay code, their own strings blanked in turn; a
  raw interpolated string is blanked whole. Of each `#if` … `#endif`, only
  the first branch is read: the `#elif` / `#else` branches are blanked, so
  branches that open a brace each stay balanced.
  """
  @spec blank(String.t()) :: String.t()
  def blank(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: "   " <> blank(rest)
  def blank(source), do: source |> blank(:line_start, [], []) |> IO.iodata_to_binary()

  # `pp`: the open `#if`s, innermost first -- :taken (reading its first
  # branch), :skip (in a later branch), :dead (inside a skipped branch)
  defp blank(<<>>, _mode, _pp, acc), do: Enum.reverse(acc)

  # at a line's start: a preprocessor line, or a line of a skipped branch
  defp blank(text, :line_start, pp, acc) do
    case Regex.run(~r/\A[ \t]*#[ \t]*([a-z]*)[^\n]*/, text) do
      [line, directive] ->
        blank(drop(text, line), :code, directive(directive, pp), [spaces(line) | acc])

      nil ->
        if Enum.any?(pp, &(&1 != :taken)) do
          [line | _] = :binary.split(text, "\n")
          blank(drop(text, line), :code, pp, [spaces(line) | acc])
        else
          blank(text, :code, pp, acc)
        end
    end
  end

  defp blank(<<"\n", rest::binary>>, :code, pp, acc), do: blank(rest, :line_start, pp, ["\n" | acc])
  defp blank(<<"//", rest::binary>>, :code, pp, acc), do: skip_to(rest, "\n", pp, ["  " | acc], :keep_end)
  defp blank(<<"/*", rest::binary>>, :code, pp, acc), do: skip_to(rest, "*/", pp, ["  " | acc], :blank_end)

  defp blank(<<c, _::binary>> = text, :code, pp, acc) when c in [?$, ?@, ?", ?'] do
    case literal(text, acc) do
      {:unclosed, acc} -> Enum.reverse(acc)
      {rest, acc} -> blank(rest, :code, pp, acc)
      :none -> blank(drop(text, 1), :code, pp, [<<c>> | acc])
    end
  end

  defp blank(<<c::utf8, rest::binary>>, :code, pp, acc), do: blank(rest, :code, pp, [<<c::utf8>> | acc])
  defp blank(<<c, rest::binary>>, :code, pp, acc), do: blank(rest, :code, pp, [<<c>> | acc])

  defp directive("if", pp), do: [if(Enum.any?(pp, &(&1 != :taken)), do: :dead, else: :taken) | pp]
  defp directive(d, [:taken | pp]) when d in ["elif", "else"], do: [:skip | pp]
  defp directive("endif", [_ | pp]), do: pp
  defp directive(_, pp), do: pp

  defp skip_to(text, stop, pp, acc, mode) do
    case :binary.split(text, stop) do
      [inside, rest] when mode == :keep_end -> blank(rest, :line_start, pp, ["\n", spaces(inside) | acc])
      [inside, rest] -> blank(rest, :code, pp, [spaces(stop), spaces(inside) | acc])
      [inside] -> Enum.reverse([spaces(inside) | acc])
    end
  end

  # A string or char literal at the start of `text`: `{rest, acc}` with it
  # blanked (an interpolated string's holes kept), `{:unclosed, acc}` when
  # it runs to the end of the source, `:none` when `text` starts none.
  defp literal(<<"'", _::binary>> = text, acc) do
    case Regex.run(~r/\A'(?:\\u[0-9A-Fa-f]{4}|\\x[0-9A-Fa-f]{1,4}|\\.|[^'\\\n])'/u, text) do
      [lit] -> {drop(text, lit), [spaces(lit) | acc]}
      nil -> :none
    end
  end

  defp literal(text, acc) do
    case Regex.run(~r/\A(\$*)(@?)(\$*)("+)/, text) do
      [prefix, d1, at, d2, quotes] ->
        rest = drop(text, prefix)
        acc = [spaces(prefix) | acc]
        interp? = d1 <> d2 != ""

        cond do
          # raw: """…""" (also $"""…""", $$"""…""")
          byte_size(quotes) >= 3 ->
            case :binary.split(rest, quotes) do
              [inside, rest] -> {rest, [spaces(quotes), spaces(inside) | acc]}
              [inside] -> {:unclosed, [spaces(inside) | acc]}
            end

          # "", @"", $"": an empty string
          byte_size(quotes) == 2 ->
            {rest, acc}

          true ->
            string(rest, if(at != "", do: :verbatim, else: :regular), interp?, acc)
        end

      nil ->
        :none
    end
  end

  # inside a string, after its opening quote; a regular one ends at the line's end too
  defp string(<<>>, _kind, _interp?, acc), do: {:unclosed, acc}
  defp string(<<"\"\"", rest::binary>>, :verbatim, i, acc), do: string(rest, :verbatim, i, ["  " | acc])
  defp string(<<"\"", rest::binary>>, _kind, _i, acc), do: {rest, [" " | acc]}
  defp string(<<"\\", c, rest::binary>>, :regular, i, acc) when c != ?\n, do: string(rest, :regular, i, ["  " | acc])
  defp string(<<"\n", _::binary>> = text, :regular, _i, acc), do: {text, acc}
  defp string(<<"\n", rest::binary>>, kind, i, acc), do: string(rest, kind, i, ["\n" | acc])
  defp string(<<"{{", rest::binary>>, kind, true, acc), do: string(rest, kind, true, ["  " | acc])

  defp string(<<"{", rest::binary>>, kind, true, acc) do
    case hole(rest, 0, [" " | acc]) do
      {:unclosed, acc} -> {:unclosed, acc}
      {rest, acc} -> string(rest, kind, true, acc)
    end
  end

  defp string(<<_, rest::binary>>, kind, i, acc), do: string(rest, kind, i, [" " | acc])

  # an interpolation hole: code up to its own closing brace, which is blanked
  defp hole(<<>>, _depth, acc), do: {:unclosed, acc}
  defp hole(<<"}", rest::binary>>, 0, acc), do: {rest, [" " | acc]}
  defp hole(<<"}", rest::binary>>, depth, acc), do: hole(rest, depth - 1, ["}" | acc])
  defp hole(<<"{", rest::binary>>, depth, acc), do: hole(rest, depth + 1, ["{" | acc])

  defp hole(<<c, _::binary>> = text, depth, acc) when c in [?$, ?@, ?", ?'] do
    case literal(text, acc) do
      {:unclosed, acc} -> {:unclosed, acc}
      {rest, acc} -> hole(rest, depth, acc)
      :none -> hole(drop(text, 1), depth, [<<c>> | acc])
    end
  end

  defp hole(<<c, rest::binary>>, depth, acc), do: hole(rest, depth, [<<c>> | acc])

  defp drop(text, n) when is_integer(n), do: binary_part(text, n, byte_size(text) - n)
  defp drop(text, prefix), do: drop(text, byte_size(prefix))

  # spaces for `text`'s bytes, its newlines kept
  defp spaces(text), do: text |> String.split("\n") |> Enum.map_join("\n", &String.duplicate(" ", byte_size(&1)))
end
