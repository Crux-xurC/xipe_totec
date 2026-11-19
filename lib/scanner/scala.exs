Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)
Code.require_file("../project_env.exs", __DIR__)
Code.require_file("../repl/scala/build_tool.exs", __DIR__)

defmodule XipeTotec.Scanner.Scala do
  @moduledoc """
  Scala's scan, read by the Scala 3 compiler's own parser: `begin/3` runs
  `scan.scala` (next to this file) once with `scala` over every Scala file
  of the project (the runner's class path carries the compiler); the two
  passes read its answer
  ([D-scala-adapter](../../document/verification/lib-repl-language-scala.exs.md#d-scala-adapter)).

  **Whose parser**: the project's own Scala version's (P10), had from its
  build tool without building (`Repl.Scala.BuildTool.*.compiler_script/3`:
  sbt's temporary tasks, scala-cli's `export --json`), offline; `scan.scala`
  is compiled once per compiler and kept in a temp dir. When the build tool
  cannot give it (no build tool, an sbt server running on the build, a
  tool that fails or is missing), the `scala` on the project environment's
  `PATH` reads it -- the pinned one -- and `describe/1` says why.

  **Definitions**: a `def` in an `object` (nested ones too) or directly in
  a package (a top-level `def`). `module` is the object's full name
  (`calc.Calc`, `calc.Uses.Inner`), or the package for a top-level `def`
  (`calc`; `""` in the empty package); in a script (`.sc`), its file's
  name (`tool.sc` is `tool`), as scala-cli names a script's object.
  `anykey` is the parameters' types as written, with the parameter lists
  kept apart (`(Int, Int)`, `(Int)(Int)`, `(Int)(using Ordering[Int])`,
  `""` for a `def` without parameter lists), so overloads are nodes of
  their own; `shape` is the number of parameters per list a call gives, the
  `using` lists left out (`[2]`, `[1, 1]`, `[]`)
  ([D-anykey-shape](../../document/verification/lib-identity.exs.md#d-anykey-shape)).
  `visibility` is `"private"` for a `private` or `protected` `def`, or one
  in such an object. Methods of classes and traits, extension methods,
  `val`s and local functions are not nodes. A script's module is its path
  without `.sc` (`scripts/tool`, nested `scripts/tool.Text`), so scripts of
  one file name in different directories stay apart.

  **One key, two definitions** (the same `(module, name, anykey)` in two
  places -- an object of one name in two sbt projects, an overload written
  twice): they would be one card, its rows and effect shared. They are not
  merged silently: each file's scan reports them (`link_failures`, with
  both places), and the card is the first one's.

  **Links**, from a `def`'s body (and its default arguments): every name
  or chain of names it uses (`f`, `Calc.f`, `calc.Calc.f`) that is a node,
  found the way Scala looks a name up -- the enclosing objects and packages,
  innermost first, then the `import`s before it, latest first, then the
  name as written. Every overload of the name is linked (the text does not
  tell which one a call picks).
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.{ProjectEnv, Scanner}

  @script Path.expand("scala/scan.scala", __DIR__)

  @impl Scanner
  def begin(root, _language, opts) do
    env = Keyword.get(opts, :env, %{})
    files = Keyword.get(opts, :files, [])
    cmd_env = Enum.map(env, fn {k, v} -> {k, if(v == false, do: nil, else: v)} end) ++ [{"COURSIER_MODE", "offline"}]

    {run, parser} =
      case project_compiler(root, cmd_env) do
        {:ok, java, jars, scanner_dir} ->
          version = jars |> String.split(":") |> Enum.find("", &(&1 =~ "scala3-compiler")) |> Path.basename(".jar")

          {fn -> System.cmd(java, ["-cp", jars <> ":" <> scanner_dir, "XtScan", root | files], cd: root, env: cmd_env, stderr_to_stdout: true) end,
           "the project's own compiler (#{version})"}

        {:fallback, why} ->
          case ProjectEnv.find_executable("scala", env) do
            nil -> {nil, why}
            scala -> {fn -> System.cmd(scala, [@script, root | files], cd: root, env: cmd_env, stderr_to_stdout: true) end, "the scala on PATH (#{why})"}
          end
      end

    case run do
      nil ->
        {:error, "no scala on the project environment's PATH, and #{parser} (Scala is read by its compiler's parser)"}

      run ->
        case run.() do
          {out, 0} ->
            answer = read_answer(out)
            {:ok, %{files: answer, parser: parser, collisions: collisions(answer)}}

          {out, status} ->
            {:error, "scan.scala exited #{status}: #{out |> String.trim() |> String.slice(0, 500)}"}
        end
    end
  end

  @impl Scanner
  def describe(%{parser: parser}), do: "Scala's parser: #{parser}"
  def describe(_ctx), do: "Scala's parser (the Scala 3 compiler's)"

  @cache Path.join(System.tmp_dir!(), "xipe_totec_scala_scan")

  # the project's compiler, had from its build tool without building, and
  # scan.scala compiled with it; both kept under the temp dir (the jars per
  # project and the times of its build files, the compiled scanner per
  # compiler)
  defp project_compiler(root, cmd_env) do
    alias XipeTotec.Repl.Scala.BuildTool

    tool =
      cond do
        File.exists?(Path.join(root, "build.sbt")) -> BuildTool.Sbt
        File.exists?(Path.join(root, "project.scala")) -> BuildTool.ScalaCli
        true -> nil
      end

    refusal = if tool == BuildTool.Sbt, do: BuildTool.Sbt.server(root)

    cond do
      tool == nil -> {:fallback, "no build tool"}
      refusal -> {:fallback, refusal}
      true -> from_tool(tool, root, cmd_env)
    end
  end

  defp from_tool(tool, root, cmd_env) do
    stamp =
      for f <- ~w(build.sbt project.scala project/build.properties project/plugins.sbt) do
        case File.stat(Path.join(root, f), time: :posix) do
          {:ok, st} -> {f, st.mtime}
          _ -> {f, nil}
        end
      end

    dir = Path.join(@cache, hash({root, stamp}))
    File.mkdir_p!(dir)
    read = fn name -> case File.read(Path.join(dir, name)), do: ({:ok, t} -> String.trim(t); _ -> "") end

    if read.("jars") == "" do
      log = Path.join(dir, "log")
      File.write!(log, "")
      System.cmd("sh", ["-c", tool.compiler_script(root, dir, log)], cd: root, env: cmd_env, stderr_to_stdout: true)
    end

    jars = read.("jars")
    java = if read.("java") == "", do: System.find_executable("java"), else: read.("java")

    cond do
      jars == "" -> {:fallback, "#{if tool == XipeTotec.Repl.Scala.BuildTool.Sbt, do: "sbt", else: "scala-cli"} gave no compiler"}
      java == nil -> {:fallback, "no java"}
      true -> compiled_scanner(java, jars)
    end
  end

  defp compiled_scanner(java, jars) do
    out = Path.join(@cache, "scanner-" <> hash({jars, File.read!(@script)}))

    if File.exists?(Path.join(out, "XtScan.class")) do
      {:ok, java, jars, out}
    else
      tmp = out <> ".#{System.unique_integer([:positive])}"
      File.mkdir_p!(tmp)

      case System.cmd(java, ["-cp", jars, "dotty.tools.dotc.Main", "-classpath", jars, "-d", tmp, @script], stderr_to_stdout: true) do
        {_, 0} ->
          File.rename(tmp, out)
          File.rm_rf(tmp)
          if File.exists?(Path.join(out, "XtScan.class")), do: {:ok, java, jars, out}, else: {:fallback, "scan.scala did not compile"}

        {msg, _} ->
          File.rm_rf(tmp)
          {:fallback, "scan.scala did not compile with the project's compiler: #{msg |> String.trim() |> String.slice(0, 200)}"}
      end
    end
  end

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  @doc """
  The keys defined more than once across `answer` (every file's defs):
  `%{path => [%{module:, reason:}]}`, each file told of its own.
  """
  @spec collisions(map()) :: %{String.t() => [map()]}
  def collisions(answer) do
    answer
    |> Enum.flat_map(fn
      {path, %{"defs" => defs}} -> Enum.map(defs, &{{&1["module_"], &1["name"], &1["anykey"]}, path, &1["line"]})
      _ -> []
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.filter(fn {_, places} -> length(places) > 1 end)
    |> Enum.sort()
    |> Enum.flat_map(fn {{module, name, anykey}, places} ->
      where = Enum.map_join(places, ", ", fn {_, p, l} -> "#{p}:#{l}" end)
      reason = "#{module}.#{name}#{anykey} is defined more than once (#{where}): one card for all of them, its rows and effect shared -- rename one, or tell them apart"
      for path <- places |> Enum.map(&elem(&1, 1)) |> Enum.uniq(), do: {path, %{module: module, reason: reason}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

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
    Scanner.put_defs(book, sheet_id, Enum.map(defs(file), &Map.take(&1, [:module, :name, :anykey, :shape, :visibility, :span, :body_hash])))
  end

  @impl Scanner
  def scan_links_report(book, node_ids, file) do
    defs = defs(file)
    index = node_ids |> Map.keys() |> Enum.group_by(fn {m, n, _} -> {m, n} end)
    own = for d <- defs, id = node_ids[{d.module, d.name, d.anykey}], do: {d, id}

    links =
      for {d, caller} <- own,
          name <- d.refs,
          key <- resolve(name, d.scopes, d.opens, index),
          ref = Scanner.node_for(book, node_ids, key),
          ref != nil and ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), Map.get(Map.get(file.ctx, :collisions, %{}), file.path, [])}
  end

  @doc """
  The definitions `begin/3`'s answer holds for `file` (`%{module:, name:,
  anykey:, shape:, visibility:, span:, body_hash:, scopes:, opens:,
  refs:}`). Raises with the parser's first error for a file that does not
  parse (the scan's `scan_failed`).
  """
  @spec defs(map()) :: [map()]
  def defs(%{path: path, ctx: %{files: files}}) do
    case files[path] do
      nil -> raise "not read by scan.scala"
      %{"error" => error} when is_binary(error) -> raise error
      %{"defs" => defs} -> Enum.map(defs, &definition/1) |> Enum.uniq_by(&{&1.module, &1.name, &1.anykey})
    end
  end

  defp definition(d) do
    %{
      module: d["module_"],
      name: d["name"],
      anykey: d["anykey"],
      shape: d["shape"],
      visibility: if(d["public"], do: "public", else: "private"),
      span: d["line"],
      body_hash: d["hash"],
      scopes: d["scopes"],
      opens: d["opens"],
      refs: d["refs"]
    }
  end

  @doc """
  The node keys `name` (`f`, `Calc.f`) can mean from a `def` in `scopes`
  (its object and the enclosing objects and packages, innermost first) with
  `opens` (the `import`s' prefixes, latest first): every overload under the
  first prefix where the name is a node. `index`: `{module, name} => [key]`.
  """
  @spec resolve(String.t(), [String.t()], [String.t()], map()) :: [{String.t(), String.t(), term()}]
  def resolve(name, scopes, opens, index) do
    {qualifier, fun} =
      case String.split(name, ".") do
        [fun] -> {[], fun}
        parts -> {Enum.drop(parts, -1), List.last(parts)}
      end

    (scopes ++ opens ++ [""])
    |> Enum.find_value([], fn prefix ->
      module = Enum.join(Enum.reject([prefix | qualifier], &(&1 == "")), ".")
      index[{module, fun}]
    end)
  end
end
