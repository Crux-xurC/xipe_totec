Code.require_file("../book.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)
Code.require_file("../project_env.exs", __DIR__)

defmodule XipeTotec.Scanner.Go do
  @moduledoc """
  Go's scan, read by Go's own parser: `begin/3` runs `scan.go` (next to
  this file; `go/parser` and `go/ast` from the standard library) once with
  `go run` over every Go file of the project -- nothing of the project is
  compiled, nothing fetched. Go is a **map-only** language: its functions
  become cards and links, never calc rows
  ([D-map-only-language](../../document/verification/lib-repl-language.exs.md#d-map-only-language);
  why: `document/evolving.md` §4.3). It needs `go` on the project
  environment's `PATH` (P10: a Go project has it).

  **Modules**: a package by its import path -- the nearest `go.mod`'s
  `module` and the directory under it (`example.com/calc/geo`); without a
  `go.mod`, the directory (`geo`, `.` at the root). Files under `vendor/`
  (third-party sources) and `testdata/` are read for nothing.

  **Definitions**: every top-level function (`Add`) and method (`T.M`,
  the receiver's type without `*` or type parameters: `Point.Scale`),
  `_test.go` files' too; `init` and `_` are not. `anykey` is `nil` (Go has
  no overloads). `visibility` `"public"` for an exported name (a capital
  first letter of the function's or the method's own name), else
  `"private"`. One package defining a name in two files (build-tag
  variants: `name_linux.go`, `name_windows.go`) is one card, the first
  file's; each file is told (the scan's `link_failures`).

  **Links**, from a function's body: a call of a name of its own package
  (`f(…)`), of an imported package's name (`pkg.F(…)`, by its alias or the
  package's own name), and of a method on the receiver (`p.norm()` in a
  method of `Point`). Calls on other values (`x.M()`) are not links: the
  scan does not know a variable's type.
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.{ProjectEnv, Scanner}

  @script_dir Path.expand("go", __DIR__)

  @impl Scanner
  def begin(root, _language, opts) do
    env = Keyword.get(opts, :env, %{})
    files = opts |> Keyword.get(:files, []) |> Enum.reject(&skipped?/1)

    case ProjectEnv.find_executable("go", env) do
      nil ->
        {:error, "no go on the project environment's PATH (Go is read by its own parser)"}

      go ->
        # scan.go is run from its own directory (no module there): the project's own settings do not apply
        cmd_env =
          Enum.map(env, fn {k, v} -> {k, if(v == false, do: nil, else: v)} end) ++
            [{"GOFLAGS", nil}, {"GOWORK", "off"}, {"GO111MODULE", nil}, {"GOTOOLCHAIN", "local"}, {"GOPROXY", "off"}]

        case files do
          [] ->
            {:ok, %{files: %{}, modules: %{}, collisions: %{}}}

          _ ->
            case System.cmd(go, ["run", "scan.go", Path.expand(root) | files], cd: @script_dir, env: cmd_env, stderr_to_stdout: true) do
              {out, 0} ->
                answer = read_answer(out)
                modules = Map.new(files, &{&1, module_name(root, &1)})
                {:ok, %{files: answer, modules: modules, collisions: collisions(answer, modules)}}

              {out, status} ->
                {:error, "go run scan.go exited #{status}: #{out |> String.trim() |> String.slice(0, 500)}"}
            end
        end
    end
  end

  @impl Scanner
  def describe(_ctx), do: "Go's parser (go/parser)"

  @impl Scanner
  def finish(_ctx), do: :ok

  @doc "Whether `path` is third-party or test data (`vendor/`, `testdata/`): read for nothing."
  @spec skipped?(String.t()) :: boolean()
  def skipped?(path), do: path |> Path.split() |> Enum.any?(&(&1 in ["vendor", "testdata"]))

  # one JSON line per file; anything else on the output (go's own messages) is not ours
  defp read_answer(out) do
    for line <- String.split(out, "\n"), String.starts_with?(line, "{"), {:ok, %{"path" => path} = file} <- [JSON.decode(line)], into: %{} do
      {path, file}
    end
  end

  @doc """
  The package a file belongs to, by its import path: the nearest `go.mod`
  (in the file's directory or above, up to `root`) gives the module path,
  the directory under it the rest; without one, the directory relative to
  `root` (`.` at the root).
  """
  @spec module_name(String.t(), String.t()) :: String.t()
  def module_name(root, path) do
    dir = Path.dirname(path)

    dir
    |> ancestors()
    |> Enum.find_value(fn d ->
      with {:ok, text} <- File.read(Path.join([root, d, "go.mod"])),
           [_, module] <- Regex.run(~r/^module\s+"?([^\s"]+)"?/m, text) do
        rest = if d == ".", do: dir, else: Path.relative_to(dir, d)
        if rest == ".", do: module, else: module <> "/" <> rest
      else
        _ -> nil
      end
    end) || dir
  end

  # `a/b` -> ["a/b", "a", "."]
  defp ancestors("."), do: ["."]
  defp ancestors(dir), do: [dir | ancestors(Path.dirname(dir))]

  # a name a package defines in two files: one card, the first file's; each file told
  defp collisions(answer, modules) do
    answer
    |> Enum.flat_map(fn
      {path, %{"defs" => defs}} when is_list(defs) -> Enum.map(defs, &{{modules[path], &1["name"]}, path, &1["line"]})
      _ -> []
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.filter(fn {_, places} -> length(places) > 1 end)
    |> Enum.flat_map(fn {{module, name}, places} ->
      places = Enum.sort(places)
      where = Enum.map_join(places, ", ", fn {_, p, l} -> "#{p}:#{l}" end)
      reason = "#{module}.#{name} is defined in more than one file (#{where}; build-tag variants?): one card, the first file's"
      for {_, path, _} <- places, do: {path, %{module: module, name: name, reason: reason, first: elem(hd(places), 1)}}
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
    ctx = file.ctx
    own = for d <- defs, id = node_ids[{d.module, d.name, nil}], do: {d, id}
    # the package name of every scanned package, by import path (an import without an alias is named by it)
    names = for {p, %{"package" => pkg}} when is_binary(pkg) and pkg != "" <- ctx.files, into: %{}, do: {ctx.modules[p], pkg}
    imports = imports(ctx.files[path], names)

    links =
      for {d, caller} <- own,
          call <- d.calls,
          key <- resolve(call, d, imports),
          ref = Scanner.node_for(book, node_ids, key),
          ref != nil and ref != caller,
          uniq: true,
          do: %{node: caller, ref: ref}

    reports = for c <- Map.get(ctx.collisions, path, []), do: Map.take(c, [:module, :reason])
    {Scanner.put_links(book, links, Enum.map(own, &elem(&1, 1))), reports}
  end

  # an import's name in the file -> its import path
  defp imports(%{"imports" => imports}, names) when is_list(imports) do
    Map.new(imports, fn %{"path" => p, "name" => alias} ->
      default = Map.get(names, p) || p |> String.split("/") |> Enum.reject(&(&1 =~ ~r/\Av\d+\z/)) |> List.last()
      {if(alias in [nil, ""], do: default, else: alias), p}
    end)
  end

  defp imports(_, _), do: %{}

  @doc """
  The definitions `begin/3`'s answer holds for `file` (`%{module:, name:,
  anykey: nil, visibility:, span:, body_hash:, calls:, recv:}`); none for a
  file under `vendor/` or `testdata/`, and a name another file of the
  package defined first is left to it. Raises with the parser's first error
  for a file that does not parse (the scan's `scan_failed`).
  """
  @spec defs(map()) :: [map()]
  def defs(%{path: path, ctx: ctx}) do
    cond do
      skipped?(path) ->
        []

      true ->
        case ctx.files[path] do
          nil ->
            raise "not read by scan.go"

          %{"error" => error} when is_binary(error) and error != "" ->
            raise error

          %{"defs" => defs} ->
            module = ctx.modules[path]
            # names another file of the package defined first
            taken = for c <- Map.get(ctx.collisions, path, []), c.first != path, into: MapSet.new(), do: c.name

            defs
            |> Enum.map(&definition(&1, module))
            |> Enum.reject(&MapSet.member?(taken, &1.name))
            |> Enum.uniq_by(& &1.name)
        end
    end
  end

  defp definition(d, module) do
    %{
      module: module,
      name: d["name"],
      anykey: nil,
      visibility: if(d["exported"], do: "public", else: "private"),
      span: d["line"],
      body_hash: d["hash"],
      calls: d["calls"] || [],
      recv: d["recv"] || ""
    }
  end

  @doc """
  The node keys a call `call` (`f`, `pkg.F`, `r.M`) can mean from
  definition `d` in its package, with `imports` (a name in the file -> an
  import path).
  """
  @spec resolve(String.t(), map(), map()) :: [{String.t(), String.t(), nil}]
  def resolve(call, d, imports) do
    case String.split(call, ".") do
      [f] ->
        [{d.module, f, nil}]

      [r, m] when r == d.recv and r != "" ->
        [type | _] = String.split(d.name, ".")
        [{d.module, "#{type}.#{m}", nil}]

      [q, f] ->
        case imports[q] do
          nil -> []
          path -> [{path, f, nil}]
        end

      _ ->
        []
    end
  end
end
