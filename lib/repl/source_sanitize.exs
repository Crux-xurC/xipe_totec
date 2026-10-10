defmodule XipeTotec.Repl.SourceSanitize do
  @moduledoc """
  Loads a scripts-mode project's files without running their top-level
  code. Scripts mode hands every source file to the REPL as `-r <file>`,
  and `-r` is a real `Code.require_file/1`: it runs a script's whole top
  level, not just its `defmodule` forms. A project whose root has an
  entry-point script (a `main.exs` that starts a server as its last
  statement) would start that server just by booting the REPL session.

  `sanitize/2` writes, per file, a small *loader* script to a fresh temp
  directory and returns those loader paths in place of the originals. Each
  loader, when `-r`'d, parses the original file, keeps only its top-level
  `defmodule` forms (the same filter as `Scanner.only_defmodules/1`) and
  compiles them with `Code.compile_quoted(forms, original_path)` -- so a
  script's top-level side effects never run, yet line numbers,
  `__ENV__.file` and `__DIR__` all stay the original file's.

  The loader defines no module of its own (its filter is inlined, not a call
  into `Scanner`), so the REPL under evaluation holds only the project's own
  modules.

  **Limitations**:
  - Cross-file compile-time dependencies (structs, macros, `import`) need
    the referencing file's `-r` to come *after* the referenced file's; the
    files come in plain alphabetical order.
  - The original is read again when the REPL boots (right after `sanitize/2`),
    not snapshotted -- an edit landing in between is what gets loaded.
  - Temp files are not cleaned up automatically by this module -- see
    `Language.Elixir.launch_opts/3`'s cleanup for what its caller removes.
  """

  @doc """
  For each of `relative_paths` (relative to `dir`, as `Project.find_sheets/1`
  returns them), writes a loader script to a fresh temp directory. Returns
  `{tmp_dir, loader_absolute_paths}` in the same order as the input -- the
  caller owns `tmp_dir` and is responsible for removing it once the launched
  session is done with it (`File.rm_rf!/1`). A file that doesn't parse
  raises here, before any REPL is launched.
  """
  @spec sanitize(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def sanitize(dir, relative_paths) do
    sources = Enum.map(relative_paths, &Path.expand(&1, dir))

    # fail at launch, in xipe_totec, on a file that doesn't parse -- before
    # the temp dir exists, so a raise here leaves nothing behind
    for source_path <- sources, do: Code.string_to_quoted!(File.read!(source_path), file: source_path)

    tmp_dir = Path.join(System.tmp_dir!(), "xipe_totec_eval_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    paths =
      sources
      |> Enum.with_index()
      |> Enum.map(fn {source_path, index} ->
        out_path = Path.join(tmp_dir, "#{index}_#{Path.basename(source_path)}")
        File.write!(out_path, loader(source_path))
        out_path
      end)

    {tmp_dir, paths}
  end

  @doc """
  The loader script for `source_path` (absolute). Its top-level filter must
  keep exactly what `Scanner.only_defmodules/1` keeps -- the test suite
  checks the two against each other.
  """
  @spec loader(String.t()) :: String.t()
  def loader(source_path) do
    """
    # xipe_totec loader (Repl.SourceSanitize): compiles only the defmodule
    # forms of #{source_path}, under its own path and line numbers
    xt_path = #{inspect(source_path)}

    xt_forms =
      case Code.string_to_quoted!(File.read!(xt_path), file: xt_path, columns: true) do
        {:__block__, _, stmts} -> stmts
        form -> [form]
      end

    Code.compile_quoted({:__block__, [], Enum.filter(xt_forms, &match?({:defmodule, _, _}, &1))}, xt_path)
    """
  end
end
