defmodule XipeTotec.ProjectRegistry do
  @moduledoc """
  `tables/project/<id>_<name>/`: resolves an arbitrary
  target-project path to a stable 3-digit `id`, and back. The directory's
  `<id>_<name>` suffix is for human legibility only, never the match key:
  two different paths can share a basename. The match key is
  `project.json`'s `path` field, always `Path.expand/1`-normalized before
  it is written or compared, so `.`/`~`/relative variants of one directory
  never register twice.

  `id`s are 3-digit, zero-padded strings (`"001"`, not `1`) -- a human-
  facing selection token, not a Book-table row id (those stay ULID,
  `Id.ulid/1`). `"000"` is reserved ("not registered yet") and never
  assigned here. `next_id/1` never reuses a deleted project's old id either --
  taking the max existing id + 1, not the first gap -- so a stale
  reference to a removed project can never silently resolve to a
  different, newer one.

  `register/2` only creates the id, the directory and `project.json`; it
  never touches `table` (the `SurfaceTable` file).
  """

  @default_root Path.expand("../tables/project", __DIR__)

  @type id :: String.t()

  @doc "Returns `path`'s existing id (after `Path.expand/1` normalization), or `nil` if no registered project matches."
  @spec find(String.t(), Path.t()) :: id() | nil
  def find(path, root \\ @default_root) do
    target = Path.expand(path)

    root
    |> entries()
    |> Enum.find_value(fn {id, dir} ->
      if read_path(dir) == target, do: id
    end)
  end

  @doc "The next id to assign: the highest existing id under `root` (default `0`, i.e. `\"000\"` is never assigned) + 1, zero-padded to 3 digits."
  @spec next_id(Path.t()) :: id()
  def next_id(root \\ @default_root) do
    max_id =
      case root |> entries() |> Enum.map(fn {id, _dir} -> String.to_integer(id) end) do
        [] -> 0
        ids -> Enum.max(ids)
      end

    (max_id + 1) |> Integer.to_string() |> String.pad_leading(3, "0")
  end

  @doc """
  Idempotent find-or-create: returns `path`'s existing id if `find/2`
  already finds one, otherwise assigns the next id (`next_id/1`),
  creates `tables/project/<id>_<basename>/`, and writes `project.json`
  (`%{"path" => Path.expand(path)}`) into it before returning the new id.
  """
  @spec register(String.t(), Path.t()) :: id()
  def register(path, root \\ @default_root) do
    case find(path, root) do
      nil ->
        target = Path.expand(path)
        id = next_id(root)
        dir = Path.join(root, "#{id}_#{Path.basename(target)}")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "project.json"), JSON.encode!(%{"path" => target}) <> "\n")
        id

      existing_id ->
        existing_id
    end
  end

  @doc "The reverse of `find/2`: `{dir, path}` for a registered `id` (`dir` being its `tables/project/<id>_<name>/` directory, `path` the target project's own absolute path from `project.json`), or `nil` if no such id is registered."
  @spec lookup(id(), Path.t()) :: {Path.t(), String.t()} | nil
  def lookup(id, root \\ @default_root) do
    root
    |> entries()
    |> Enum.find_value(fn {entry_id, dir} ->
      if entry_id == id, do: {dir, read_path(dir)}
    end)
  end

  # `{id, dir}` for every `tables/project/<id>_<name>/` entry whose name
  # starts with a 3-digit prefix (an unrelated stray directory under
  # `tables/project/` is silently skipped rather than raising -- this
  # scan has no way to tell a foreign directory from a corrupt one, and
  # neither is this module's problem to fix).
  defp entries(root) do
    case File.ls(root) do
      {:ok, names} -> names |> Enum.map(&{id_prefix(&1), Path.join(root, &1)}) |> Enum.reject(&(elem(&1, 0) == nil))
      {:error, :enoent} -> []
    end
  end

  defp id_prefix(name) do
    case Regex.run(~r/^(\d{3})_/, name) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp read_path(dir) do
    case File.read(Path.join(dir, "project.json")) do
      {:ok, content} -> Map.get(JSON.decode!(content), "path")
      {:error, _} -> nil
    end
  end
end
