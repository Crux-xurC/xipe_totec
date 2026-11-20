Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)
Code.require_file("../project_env.exs", __DIR__)

defmodule XipeTotec.Scanner.Php do
  @moduledoc """
  PHP's scan, read by PHP's own lexer: `begin/3` runs `scan.php` (next to
  this file) once with `php` over every PHP file of the project
  (`token_get_all` with `TOKEN_PARSE`, so PHP's parser checks each file;
  nothing of the project is loaded or run). PHP is a **map-only** language:
  its functions become cards and links, never calc rows
  ([D-map-only-language](../../document/verification/lib-repl-language.exs.md#d-map-only-language);
  why: `document/evolving.md` §4.7). It needs `php` on the project
  environment's `PATH` (P10). Files under `vendor/` (composer's
  third-party sources) are read for nothing.

  **Definitions**: every named function and every method of a class,
  interface, trait or enum. `module` is the class's full name
  (`App\\Geo\\Shapes`), or the namespace for a function (`App\\Util`; `\\` for
  the global one); `name` the function's or the method's. `anykey` is `nil`
  (PHP has no overloads). `visibility` is `"public"` for a function and a
  method not `private` / `protected`. Closures, arrow functions and an
  anonymous class's methods are not definitions; their calls are the
  enclosing function's. A function declared in two files (a guarded
  `if (!function_exists(…))` helper) is one card, the first file's; each
  file is told (the scan's `link_failures`).

  **Links**, from a function's body, found as PHP resolves a name (names
  compared without case, as PHP does): `f(…)` through `use function`, then
  the namespace, then the global one; `A\\f(…)` through a `use` of `A`, else
  under the namespace; `\\A\\f(…)` as written; `X::m(…)` with `X` through
  `use`, the namespace, or as written; `self::`, `static::` and `$this->`
  the current class (then the class it extends), `parent::` the class it
  extends. Calls on other values (`$x->m()`) are not links: the scan does
  not know a variable's type.
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.{ProjectEnv, Scanner}

  @script Path.expand("php/scan.php", __DIR__)

  @impl Scanner
  def begin(root, _language, opts) do
    env = Keyword.get(opts, :env, %{})
    files = opts |> Keyword.get(:files, []) |> Enum.reject(&skipped?/1)

    case ProjectEnv.find_executable("php", env) do
      nil ->
        {:error, "no php on the project environment's PATH (PHP is read by its own lexer)"}

      php ->
        cmd_env = Enum.map(env, fn {k, v} -> {k, if(v == false, do: nil, else: v)} end)

        case files do
          [] ->
            {:ok, %{files: %{}, collisions: %{}}}

          _ ->
            case System.cmd(php, ["-d", "memory_limit=1G", @script, Path.expand(root) | files], cd: root, env: cmd_env, stderr_to_stdout: true) do
              {out, 0} ->
                answer = read_answer(out)
                {:ok, %{files: answer, collisions: collisions(answer)}}

              {out, status} ->
                {:error, "php scan.php exited #{status}: #{out |> String.trim() |> String.slice(0, 500)}"}
            end
        end
    end
  end

  @impl Scanner
  def describe(_ctx), do: "PHP's lexer (token_get_all)"

  @impl Scanner
  def finish(_ctx), do: :ok

  @doc "Whether `path` is composer's third-party code (`vendor/`): read for nothing."
  @spec skipped?(String.t()) :: boolean()
  def skipped?(path), do: path |> Path.split() |> Enum.member?("vendor")

  defp read_answer(out) do
    for line <- String.split(out, "\n"), String.starts_with?(line, "{"), {:ok, %{"path" => path} = file} <- [JSON.decode(line)], into: %{} do
      {path, file}
    end
  end

  defp key(module, name), do: {String.downcase(module), String.downcase(name)}

  # a function or method two files define: one card, the first file's; each file told
  defp collisions(answer) do
    answer
    |> Enum.flat_map(fn
      {path, %{"defs" => defs}} when is_list(defs) -> defs |> Enum.map(&{key(&1["module"], &1["name"]), &1, path}) |> Enum.uniq_by(&elem(&1, 0))
      _ -> []
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.filter(fn {_, places} -> length(places) > 1 end)
    |> Enum.flat_map(fn {k, places} ->
      places = Enum.sort_by(places, &elem(&1, 2))
      {_, d, first} = hd(places)
      where = Enum.map_join(places, ", ", fn {_, x, p} -> "#{p}:#{x["line"]}" end)
      reason = "#{d["module"]}.#{d["name"]} is defined in more than one file (#{where}): one card, the first file's"
      for {_, _, path} <- places, do: {path, %{module: d["module"], key: k, reason: reason, first: first}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @impl Scanner
  def scan_defs(book, sheet_id, file) do
    keep = [:module, :name, :anykey, :visibility, :span, :body_hash]
    Scanner.put_defs(book, sheet_id, Enum.map(defs(file), &Map.take(&1, keep)))
  end

  @impl Scanner
  def scan_links_report(book, node_ids, %{path: path} = file) do
    defs = defs(file)
    # every node key, by its name without case
    index = node_ids |> Map.keys() |> Map.new(fn {m, n, a} -> {key(m, n), {m, n, a}} end)
    own = for d <- defs, id = node_ids[{d.module, d.name, nil}], do: {d, id}

    links =
      for {d, caller} <- own,
          call <- d.calls,
          k <- resolve(call, d),
          node_key = index[k],
          node_key != nil,
          ref = Scanner.node_for(book, node_ids, node_key),
          ref != nil and ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    reports = for c <- Map.get(file.ctx.collisions, path, []), do: Map.take(c, [:module, :reason])
    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), reports}
  end

  @doc """
  The definitions `begin/3`'s answer holds for `file` (`%{module:, name:,
  anykey: nil, visibility:, span:, body_hash:, calls:, namespace:, uses:,
  functions:, class:, parent:}`); none under `vendor/`, and one another file
  defined first is left to it. Raises with PHP's parse error for a file
  that does not parse (the scan's `scan_failed`).
  """
  @spec defs(map()) :: [map()]
  def defs(%{path: path, ctx: ctx}) do
    if skipped?(path) do
      []
    else
      case ctx.files[path] do
        nil ->
          raise "not read by scan.php"

        %{"error" => error} when is_binary(error) ->
          raise error

        %{"defs" => defs} ->
          taken = for c <- Map.get(ctx.collisions, path, []), c.first != path, into: MapSet.new(), do: c.key

          defs
          |> Enum.map(&definition/1)
          |> Enum.uniq_by(&key(&1.module, &1.name))
          |> Enum.reject(&MapSet.member?(taken, key(&1.module, &1.name)))
      end
    end
  end

  defp definition(d) do
    %{
      module: d["module"],
      name: d["name"],
      anykey: nil,
      visibility: if(d["public"], do: "public", else: "private"),
      span: d["line"],
      body_hash: d["hash"],
      calls: d["calls"] || [],
      namespace: d["namespace"] || "",
      uses: d["uses"] || %{},
      functions: d["functions"] || %{},
      class: d["class"],
      parent: d["parent"]
    }
  end

  @doc """
  The keys (`{module, name}` without case) a call can mean from definition
  `d`, in the order PHP tries them.
  """
  @spec resolve(String.t(), map()) :: [{String.t(), String.t()}]
  def resolve(call, d) do
    cond do
      String.starts_with?(call, "$this->") ->
        m = String.replace_prefix(call, "$this->", "")
        own_class(d, m)

      String.contains?(call, "::") ->
        [x, m] = String.split(call, "::", parts: 2)

        case String.downcase(x) do
          s when s in ["self", "static"] -> own_class(d, m)
          "parent" -> if d.parent, do: [key(class_name(d.parent, d), m)], else: []
          _ -> [key(class_name(x, d), m)]
        end

      true ->
        function_keys(call, d)
    end
  end

  defp own_class(%{class: nil}, _m), do: []
  defp own_class(d, m), do: [key(d.class, m)] ++ if(d.parent, do: [key(class_name(d.parent, d), m)], else: [])

  # a class name as PHP resolves it: fully qualified as written, else through `use` (its first segment), else under the namespace
  defp class_name("\\" <> full, _d), do: full

  defp class_name(name, d) do
    [first | rest] = String.split(name, "\\")

    case d.uses[String.downcase(first)] do
      nil -> join([d.namespace, name])
      full -> join([full | rest])
    end
  end

  # a function call's candidates: `use function`, then the namespace, then the global one
  defp function_keys("\\" <> full, _d), do: [split_function(full)]

  defp function_keys(name, d) do
    case String.split(name, "\\") do
      [f] ->
        aliased = for full <- [d.functions[String.downcase(f)]], full != nil, do: split_function(full)
        aliased ++ [key(if(d.namespace == "", do: "\\", else: d.namespace), f), key("\\", f)]

      [first | rest] ->
        prefix =
          case d.uses[String.downcase(first)] do
            nil -> join([d.namespace, first])
            full -> full
          end

        [split_function(join([prefix | rest]))]
    end
  end

  defp split_function(full) do
    parts = String.split(full, "\\")
    {ns, [f]} = Enum.split(parts, -1)
    key(if(ns == [], do: "\\", else: Enum.join(ns, "\\")), f)
  end

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\\")
end
