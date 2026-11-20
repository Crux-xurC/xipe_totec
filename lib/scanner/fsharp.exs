Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)
Code.require_file("../project_env.exs", __DIR__)

defmodule XipeTotec.Scanner.FSharp do
  @moduledoc """
  F#'s scan, read by F#'s own parser: `begin/3` runs `scan.fsx` (next to
  this file) once in `dotnet fsi` over every F# file of the project, with
  FSharp.Compiler.Service, which comes with the .NET SDK; the two passes
  read its answer ([D-fsharp-adapter](../../document/verification/lib-repl-language-fsharp.exs.md#d-fsharp-adapter)).
  It needs `dotnet` on the project environment's `PATH`, as evaluating does
  (P10: the target's environment parses it).

  **Definitions**: a module-level `let` with arguments, in a module of a
  `.fs` or `.fsx` file (nested modules too). `module` is the module's full
  name as F# writes it (`Sample.Geo.Inner`; a script without a `module`
  line is its file's name, `tool.fsx` is `Tool`), `name` the function's
  (an active pattern in parentheses, `(|Even|Odd|)`), `anykey` its curried
  arguments as written -- `let f a b` 2, `let f (a, b)` and `let f ()` 1 --
  which is the number of arguments a calc row gives it. `visibility`
  `"public"` unless the function or an enclosing module is `private` or
  `internal`. Values (`let x = 42`, `let addTen = add 10`, `let f = fun x
  -> …`), operators and local functions are not nodes.

  A **`static member` with arguments** of a type is a node too (overloads
  each their own): `module` is the type's full name (`Sample.Conv`),
  `anykey` its parameters' types written out from the syntax tree in one
  form, one parenthesized group per curried group (`(int)`, `(float,
  int)`, `(float)(Point)`, `()`; a parameter without a type `_`), and
  `shape` its parameter count per group (`[1]`, `[2]`, `[1, 1]`, `[0]`),
  which `row/add` checks the arguments against
  ([D-anykey-shape](../../document/verification/lib-identity.exs.md#d-anykey-shape)).
  `visibility` also takes the member's and the type's own. Static
  properties (`static member P = …`), instance members, constructors and
  operators are not nodes.

  **Links**, from a function's body: every name it uses (`f`, `M.f`,
  `A.B.f`) that is a node, found the way F# looks a name up -- the
  function's own module and the enclosing ones, innermost first, then the
  `open`s before it, latest first, then the name as written. A local name
  that shadows a function is taken for it (the links are what the text
  suggests).
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.{ProjectEnv, Scanner}

  @script Path.expand("fsharp/scan.fsx", __DIR__)

  @impl Scanner
  def begin(root, _language, opts) do
    env = Keyword.get(opts, :env, %{})
    files = Keyword.get(opts, :files, [])

    case ProjectEnv.find_executable("dotnet", env) do
      nil ->
        {:error, "no dotnet on the project environment's PATH (F# is read by the SDK's own parser)"}

      dotnet ->
        cmd_env =
          Enum.map(env, fn {k, v} -> {k, if(v == false, do: nil, else: v)} end) ++
            [{"DOTNET_CLI_TELEMETRY_OPTOUT", "1"}, {"DOTNET_NOLOGO", "1"}, {"DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1"}]

        case System.cmd(dotnet, ["fsi", "--quiet", "--exec", @script, root | files], cd: root, env: cmd_env, stderr_to_stdout: true) do
          {out, 0} -> {:ok, %{files: read_answer(out)}}
          {out, status} -> {:error, "dotnet fsi scan.fsx exited #{status}: #{out |> String.trim() |> String.slice(0, 500)}"}
        end
    end
  end

  @impl Scanner
  def describe(_ctx), do: "F#'s parser (FSharp.Compiler.Service) in dotnet fsi"

  @impl Scanner
  def finish(_ctx), do: :ok

  # one JSON line per file; anything else on the output (a warning) is not ours
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

    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), []}
  end

  @doc """
  The definitions `begin/3`'s answer holds for `file` (`%{module:, name:,
  anykey:, shape:, visibility:, span:, body_hash:, scopes:, opens:, refs:}`;
  `shape` is `nil` for a module function).
  Raises with the parser's first error for a file that does not parse
  (the scan's `scan_failed`).
  """
  @spec defs(map()) :: [map()]
  def defs(%{path: path, ctx: %{files: files}}) do
    case files[path] do
      nil -> raise "not read by scan.fsx"
      %{"error" => error} when is_binary(error) -> raise error
      %{"defs" => defs} -> Enum.map(defs, &definition/1) |> Enum.uniq_by(&{&1.module, &1.name, &1.anykey})
    end
  end

  defp definition(d) do
    %{
      module: d["module_"],
      name: d["name"],
      # a function's curried count; a static member's sequence of types (D-anykey-shape)
      anykey: d["key"] || d["args"],
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
  The node keys `name` (`f`, `M.f`) can mean from a function in `scopes`
  (its module and the enclosing ones, innermost first) with `opens`
  (latest first): the first prefix under which the name is a node, as F#
  takes the innermost. `index`: `{module, name} => [key]`.
  """
  @spec resolve(String.t(), [String.t()], [String.t()], map()) :: [{String.t(), String.t(), term()}]
  def resolve(name, scopes, opens, index) do
    {qualifier, fun} =
      case String.split(name, ".") do
        [fun] -> {[], fun}
        parts -> {Enum.drop(parts, -1), List.last(parts)}
      end

    # `open Geo` inside `namespace Sample` opens `Sample.Geo` when there is one
    opens = for o <- opens, s <- scopes ++ [""], do: Enum.join(Enum.reject([s, o], &(&1 == "")), ".")

    (scopes ++ opens ++ [""])
    |> Enum.find_value([], fn prefix ->
      module = Enum.join(Enum.reject([prefix | qualifier], &(&1 == "")), ".")
      index[{module, fun}]
    end)
  end
end
