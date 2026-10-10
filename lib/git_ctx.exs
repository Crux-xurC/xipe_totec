defmodule XipeTotec.GitCtx do
  @moduledoc """
  The git provenance `Core.apply_results/3` records on every evaluated row.
  Read by the caller (the CLI, or `Serve.Project` at the start of every
  pass) and handed in; `Core` and `Evaluator` never run git themselves.
  """

  @doc """
  `%{commit:, commit_at:, dirty:}` for the repository `dir` is in. `dir`
  need not be a git repo at all (or `git` need not be installed) -- every
  field just stays nil rather than raise.
  """
  @spec read(String.t()) :: %{commit: String.t() | nil, commit_at: String.t() | nil, dirty: boolean() | nil}
  def read(dir) do
    with {sha, 0} <- git(dir, ["rev-parse", "HEAD"]),
         {commit_at, 0} <- git(dir, ["show", "-s", "--format=%cI", "HEAD"]),
         {status, 0} <- git(dir, ["status", "--porcelain"]) do
      %{commit: String.trim(sha), commit_at: String.trim(commit_at), dirty: status != ""}
    else
      _ -> %{commit: nil, commit_at: nil, dirty: nil}
    end
  end

  defp git(dir, args) do
    System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  rescue
    # no git on PATH, or dir gone
    _ -> {"", 1}
  end
end
