Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)
Code.require_file("../project_env.exs", __DIR__)

defmodule XipeTotec.Scanner.Java do
  @moduledoc """
  Java's scan, read by the JDK's own parser: `begin/3` runs `scan.java`
  (next to this file) once with `java` as a single-file program over every
  Java file of the project (`com.sun.source` through `javax.tools`: nothing
  compiled, nothing written); the two passes read its answer
  ([D-java-adapter](../../document/verification/lib-repl-language-java.exs.md#d-java-adapter)).
  It needs `java` (a JDK) on the project environment's `PATH`, as building
  does (P10).

  **Definitions**: every method of a class, interface, enum or record,
  nested ones too. `module` is the package and the type chain
  (`sample.geo.Shapes.Inner`), `name` the method's, `anykey` its
  parameters' types written out from the tree in one form (`(int, int)`,
  `(List<Integer>)`, `(int...)`), so overloads are nodes of their own; the
  shape is the parameter count, a varargs parameter one (an array)
  ([D-anykey-shape](../../document/verification/lib-identity.exs.md#d-anykey-shape)).
  `visibility` is `"public"` only for a `public static` method of a type
  public all the way out (an interface's members and nested types are
  public). Marks ([D-node-marks](../../document/verification/lib-identity.exs.md#d-node-marks)):
  `async` for a method returning `CompletableFuture`, `CompletionStage` or
  `Future` (awaited), `varargs` (its last argument is passed as `(…)*`),
  `typed` for an overload whose argument count another one shares (the
  call writes the arguments' types); a refusal for a method whose type
  parameter appears in no parameter (`<T> T make()`: Scala would call it
  as `make[Nothing]()`).

  **Links**, from a method's body: every call whose name is a chain of
  names (`f(…)`, `Calc.f(…)`, `sample.Calc.f(…)`, `this.f(…)`), found as
  Java looks it up -- a bare name in the enclosing types, innermost first,
  then the static imports; a qualified one by its type: nested in an
  enclosing type, in the same package, a single-type import, an on-demand
  import, then as written. The overloads of the call's argument count (all
  of them when several share it), else every overload of the name. Calls on
  a value (`list.add(…)`) are not links: the scan does not know a
  variable's type.
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.{ProjectEnv, Scanner}

  @script Path.expand("java/scan.java", __DIR__)

  @impl Scanner
  def begin(root, _language, opts) do
    env = Keyword.get(opts, :env, %{})
    files = Keyword.get(opts, :files, [])

    case ProjectEnv.find_executable("java", env) do
      nil ->
        {:error, "no java on the project environment's PATH (Java is read by the JDK's own parser)"}

      java ->
        cmd_env = Enum.map(env, fn {k, v} -> {k, if(v == false, do: nil, else: v)} end)

        case System.cmd(java, [@script, root | files], cd: root, env: cmd_env, stderr_to_stdout: true) do
          {out, 0} -> {:ok, %{files: read_answer(out)}}
          {out, status} -> {:error, "java scan.java exited #{status}: #{out |> String.trim() |> String.slice(0, 500)}"}
        end
    end
  end

  @impl Scanner
  def describe(_ctx), do: "the JDK's parser (com.sun.source)"

  @impl Scanner
  def finish(_ctx), do: :ok

  # one JSON line per file; anything else on the output (a JVM warning) is not ours
  defp read_answer(out) do
    for line <- String.split(out, "\n"), String.starts_with?(line, "{"), {:ok, %{"path" => path} = file} <- [JSON.decode(line)], into: %{} do
      {path, file}
    end
  end

  @impl Scanner
  def scan_defs(book, sheet_id, file) do
    keep = [:module, :name, :anykey, :shape, :marks, :refusal, :visibility, :span, :body_hash]
    Scanner.put_defs(book, sheet_id, Enum.map(defs(file), &Map.take(&1, keep)))
  end

  @impl Scanner
  def scan_links_report(book, node_ids, file) do
    defs = defs(file)
    index = node_ids |> Map.keys() |> Enum.group_by(fn {m, n, _} -> {m, n} end)
    modules = node_ids |> Map.keys() |> MapSet.new(&elem(&1, 0))
    own = for d <- defs, id = node_ids[{d.module, d.name, d.anykey}], do: {d, id}

    links =
      for {d, caller} <- own,
          %{"name" => name, "argc" => argc} <- d.refs,
          key <- resolve(name, argc, d, modules, index),
          ref = Scanner.node_for(book, node_ids, key),
          ref != nil and ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), []}
  end

  @doc """
  The definitions `begin/3`'s answer holds for `file` (`%{module:, name:,
  anykey:, shape:, marks:, refusal:, visibility:, span:, body_hash:, …}`
  with what `resolve/5` needs). Raises with the parser's first error for a
  file that does not parse (the scan's `scan_failed`).
  """
  @spec defs(map()) :: [map()]
  def defs(%{path: path, ctx: %{files: files}}) do
    case files[path] do
      nil -> raise "not read by scan.java"
      %{"error" => error} when is_binary(error) -> raise error
      %{"defs" => defs} -> defs |> Enum.map(&definition/1) |> Enum.uniq_by(&{&1.module, &1.name, &1.anykey}) |> typed()
    end
  end

  defp definition(d) do
    %{
      module: d["module_"],
      name: d["name"],
      anykey: d["anykey"],
      shape: d["shape"],
      marks: (if(d["async"], do: ["async"], else: []) ++ if(d["varargs"], do: ["varargs"], else: [])),
      refusal:
        case d["unbound"] do
          [] ->
            nil

          free ->
            "its type parameter #{Enum.join(free, ", ")} appears in no parameter: called without a type argument Scala would call it " <>
              "with Nothing (type arguments are not decided)"
        end,
      visibility: if(d["public"], do: "public", else: "private"),
      span: d["line"],
      body_hash: d["hash"],
      scopes: d["scopes"],
      package: d["package"],
      imports: d["imports"],
      wildcards: d["wildcards"],
      statics: d["statics"],
      refs: d["refs"]
    }
  end

  # overloads sharing an argument count are marked "typed" (the call gives each argument its parameter's type)
  defp typed(defs) do
    counts = Enum.frequencies_by(defs, &{&1.module, &1.name, &1.shape})
    Enum.map(defs, fn d -> if counts[{d.module, d.name, d.shape}] > 1, do: %{d | marks: d.marks ++ ["typed"]}, else: d end)
  end

  @doc """
  The node keys a call `name` (`f`, `Calc.f`, `sample.Calc.f`, `this.f`)
  with `argc` arguments can mean from method `d` (its `scopes`, `package`,
  `imports`, `wildcards`, `statics`): the module as Java finds it, then the
  overloads of that count (all of them when none has it).
  `modules`: the modules that are nodes' (a set); `index`: `{module, name}
  => [key]`.
  """
  @spec resolve(String.t(), non_neg_integer(), map(), MapSet.t(), map()) :: [{String.t(), String.t(), term()}]
  def resolve(name, argc, d, modules, index) do
    {qualifier, fun} =
      case String.split(name, ".") do
        [fun] -> {nil, fun}
        parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
      end

    candidates =
      case qualifier do
        q when q in [nil, "this"] ->
          statics =
            for s <- d.statics, [_, type, member] <- [Regex.run(~r/\A(.+)\.([^.]+)\z/, s)], member in [fun, "*"], do: type

          d.scopes ++ statics

        q ->
          [first | rest] = String.split(q, ".")
          after_first = Enum.map(rest, &("." <> &1)) |> Enum.join()

          from_imports =
            for i <- d.imports, String.ends_with?(i, "." <> first) or i == first, do: i <> after_first

          Enum.map(d.scopes, &"#{&1}.#{q}") ++
            [Enum.join(Enum.reject([d.package, q], &(&1 in [nil, ""])), ".")] ++
            from_imports ++ Enum.map(d.wildcards, &"#{&1}.#{q}") ++ [q]
      end

    case Enum.find(candidates, &(MapSet.member?(modules, &1) and Map.has_key?(index, {&1, fun}))) do
      nil -> []
      module -> overloads(index, module, fun, argc)
    end
  end

  defp overloads(index, module, name, argc) do
    keys = Map.get(index, {module, name}, [])

    case Enum.filter(keys, fn {_, _, key} -> key_arity(key) == argc end) do
      [] -> keys
      exact -> exact
    end
  end

  @doc "The number of parameters in an anykey (`(int, Map<K, V>)` is 2)."
  @spec key_arity(String.t()) :: non_neg_integer()
  def key_arity("()"), do: 0

  def key_arity("(" <> _ = key) do
    {_, commas} =
      for <<c <- String.slice(key, 1..-2//1)>>, reduce: {0, 0} do
        {depth, n} ->
          cond do
            c in ~c"<([" -> {depth + 1, n}
            c in ~c">)]" -> {depth - 1, n}
            c == ?, and depth == 0 -> {depth, n + 1}
            true -> {depth, n}
          end
      end

    commas + 1
  end

  def key_arity(_), do: 0
end
