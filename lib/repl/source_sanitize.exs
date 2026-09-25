Code.require_file("../scanner/elixir.exs", __DIR__)

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

  `sanitize/2` re-applies the same filter (`Scanner.only_defmodules/1`) to
  each file, writes the filtered form out as text to a fresh temp
  directory, and returns those temp paths in place of the originals --
  `-r`ing a sanitized copy can define modules but can never execute a
  script's own top-level side effects, because those statements were never
  written to the copy in the first place.

  **Known limitations** (flagged rather than solved here):
  - `Macro.to_string/1` does not perfectly round-trip 100% of Elixir syntax
    (some sigils/literals can come out different-but-equivalent, or, rarely,
    fail to recompile). Plain `defmodule`/`def`/`defp` bodies -- the common
    case `Project.find_sheets/1` is scanning for -- round-trip fine.
  - Cross-file compile-time dependencies (structs, macros, `import`) still
    need the referencing file's `-r` to come *after* the referenced file's
    -- this was already true of `find_sheets/1`'s plain alphabetical order
    before this change and isn't newly introduced by it.
  - Temp files are not cleaned up automatically by this module -- see
    `Runner`'s call site for the cleanup this module leaves to its caller.
  """

  alias XipeTotec.Scanner.Elixir, as: Scanner

  @doc """
  For each of `relative_paths` (relative to `dir`, as `Project.find_sheets/1`
  returns them), writes a `defmodule`-only copy to a fresh temp directory.
  Returns `{tmp_dir, sanitized_absolute_paths}` in the same order as the
  input -- the caller owns `tmp_dir` and is responsible for removing it
  once the launched session is done with it (`File.rm_rf!/1`).
  """
  @spec sanitize(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def sanitize(dir, relative_paths) do
    tmp_dir = Path.join(System.tmp_dir!(), "xipe_totec_eval_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    paths =
      relative_paths
      |> Enum.with_index()
      |> Enum.map(fn {path, index} -> sanitize_one(dir, path, tmp_dir, index) end)

    {tmp_dir, paths}
  end

  defp sanitize_one(dir, relative_path, tmp_dir, index) do
    source = File.read!(Path.join(dir, relative_path))
    quoted = Code.string_to_quoted!(source, columns: true)
    filtered = {:__block__, [], Scanner.only_defmodules(quoted)}
    text = Macro.to_string(filtered)

    out_path = Path.join(tmp_dir, "#{index}_#{Path.basename(relative_path)}")
    File.write!(out_path, text)
    out_path
  end
end
