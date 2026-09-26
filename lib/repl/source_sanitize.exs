defmodule XipeTotec.Repl.SourceSanitize do
  @moduledoc """
  Closes a real gap found by review (2026-09-18): §11.5's `Project.find_sheets/1`
  was extended to also find `.exs` files, and scripts-mode's default
  `:launch_opts` (`Runner.default_launch_opts/1`) feeds that list straight
  into `message["files"]`, which `Sender.Direct.with_files/2` turns into one
  `-r <file>` per file. `-r` is a *real* `Code.require_file/1` -- it runs a
  script's entire top-level, not just its `defmodule` forms. For a project
  like xipe_totec's own or tezcatl's, whose root has an entry-point script
  (`main.exs`) that starts a server as its last top-level statement, `xipe
  eval` on that project would launch a whole nested server as a side effect
  of just booting the REPL session. This is exactly the hazard `Scanner`'s
  Fix F already closed for *scanning* (`Code.compile_quoted` over only the
  `defmodule` forms) -- it had reopened one layer up, on the *loading* path,
  which never went through `Scanner` at all.

  `sanitize/2` writes, per file, a small *loader* script to a fresh temp
  directory and returns those loader paths in place of the originals. Each
  loader, when `-r`'d, parses the original file, keeps only its top-level
  `defmodule` forms (the same filter as `Scanner.only_defmodules/1`) and
  compiles them with `Code.compile_quoted(forms, original_path)` -- so a
  script's own top-level side effects are never run, yet line numbers,
  `__ENV__.file` and `__DIR__` all stay the original file's (2026-09-26: the
  earlier version wrote `Macro.to_string/1` of the filtered AST to the temp
  file, which reflowed the code -- stack traces pointed at lines of a deleted
  temp copy, and compile-time `__DIR__` pointed at the temp dir, changing
  what code built from it evaluated to).

  The loader defines no module of its own (its filter is inlined, not a call
  into `Scanner`), so the REPL under evaluation holds only the project's own
  modules.

  **Known limitations** (flagged rather than solved here):
  - Cross-file compile-time dependencies (structs, macros, `import`) still
    need the referencing file's `-r` to come *after* the referenced file's
    -- this was already true of `find_sheets/1`'s plain alphabetical order
    and isn't introduced by this module.
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
