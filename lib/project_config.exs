defmodule XipeTotec.ProjectConfig do
  @moduledoc """
  A project's own settings, kept in its
  `tables/project/<id>_<name>/project.json` next to the registry's match
  key `path` (`ProjectRegistry` reads only that key). Settings are per
  project only -- there is no machine-wide default to override; a key a
  project hasn't set has the built-in default below. `xipe config` reads
  and writes them.

  Keys (dotted, as `xipe config` takes them):

    * `env.path` -- how the project's resolved environment's `PATH`
      (`ProjectEnv`) meets xipe_totec's own: `prepend` (default) puts it
      in front, `replace` uses it alone
    * `env.refresh` -- when a changed `flake.nix`/`flake.lock` is resolved
      again: `auto` (default) on the next scan/eval that needs it, `manual`
      only on `xipe table generate` (until then the old environment is used,
      with a warning)
  """

  @defaults %{"env" => %{"path" => "prepend", "refresh" => "auto"}}
  @allowed %{"env.path" => ["prepend", "replace"], "env.refresh" => ["auto", "manual"]}

  @type t :: %{String.t() => term()}

  @doc "The settings of the project whose directory is `project_dir`, defaults filled in."
  @spec load(Path.t()) :: t()
  def load(project_dir) do
    stored = project_dir |> read() |> Map.delete("path")
    deep_merge(@defaults, stored)
  end

  @doc "The dotted keys `put/3` accepts, with their allowed values."
  @spec allowed() :: %{String.t() => [String.t()]}
  def allowed, do: @allowed

  @doc "Set dotted `key` to `value` in `project_dir`'s project.json, keeping everything else."
  @spec put(Path.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def put(project_dir, key, value) do
    case Map.fetch(@allowed, key) do
      :error ->
        {:error, "unknown setting #{key} (#{@allowed |> Map.keys() |> Enum.sort() |> Enum.join(", ")})"}

      {:ok, values} ->
        if value in values do
          path = String.split(key, ".")
          stored = read(project_dir)
          File.write!(file(project_dir), JSON.encode!(put_in(stored, Enum.map(path, &Access.key(&1, %{})), value)) <> "\n")
        else
          {:error, "#{key} must be one of #{Enum.join(values, "|")}, got #{inspect(value)}"}
        end
    end
  end

  @doc "Every setting as `{dotted_key, value}`, sorted."
  @spec flatten(t()) :: [{String.t(), term()}]
  def flatten(settings, prefix \\ "") do
    settings
    |> Enum.flat_map(fn
      {k, v} when is_map(v) -> flatten(v, prefix <> k <> ".")
      {k, v} -> [{prefix <> k, v}]
    end)
    |> Enum.sort()
  end

  defp file(project_dir), do: Path.join(project_dir, "project.json")

  defp read(project_dir) do
    case File.read(file(project_dir)) do
      {:ok, text} -> JSON.decode!(text)
      {:error, :enoent} -> %{}
    end
  end

  defp deep_merge(a, b) do
    Map.merge(a, b, fn
      _k, x, y when is_map(x) and is_map(y) -> deep_merge(x, y)
      _k, _x, y -> y
    end)
  end
end
