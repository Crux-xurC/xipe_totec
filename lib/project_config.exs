defmodule XipeTotec.ProjectConfig do
  @moduledoc """
  A project's own settings, kept in its
  `tables/project/<id>_<name>/project.json` next to the registry's match
  key `path` (`ProjectRegistry` reads only that key). Settings are per
  project only. A key a project hasn't set has the default: xipe_totec's
  own `defaults.json` (what every project starts from), and under that the
  values built in here, should that file be missing or lack the key.
  `dialogue update` and `xipe config` read and write them (`config/set`);
  a default is never rewritten from there -- changing a setting always
  writes the project's own file.

  Keys (dotted, as they are written):

    * `env.path` -- how the project's resolved environment's `PATH`
      (`ProjectEnv`) meets xipe_totec's own: `prepend` (default) puts it
      in front, `replace` uses it alone
    * `env.refresh` -- when a changed `flake.nix`/`flake.lock` is resolved
      again: `auto` (default) on the next scan/eval that needs it, `manual`
      only on `xipe table generate` (until then the old environment is used,
      with a warning)
    * `eval.timeout` -- how long one calc row may run, in ms (default
      5000). A row over it is recorded as `timeout`
    * `eval.boot_timeout` -- how long a pass waits for its REPL to be
      ready, a build included, in ms (default 15000). Over it the pass is
      `boot_failed`

  A changed `eval.*` applies from the next pass: `Runner` reads the
  settings when a pass starts.
  """

  @builtin %{"env" => %{"path" => "prepend", "refresh" => "auto"}, "eval" => %{"timeout" => 5_000, "boot_timeout" => 15_000}}

  # what each key may be: one of some words, or a whole number in a range
  @keys %{
    "env.path" => {:choice, ["prepend", "replace"]},
    "env.refresh" => {:choice, ["auto", "manual"]},
    "eval.timeout" => {:number, 100, 600_000, "ms"},
    "eval.boot_timeout" => {:number, 1_000, 1_800_000, "ms"}
  }

  @defaults_file Path.expand("../defaults.json", __DIR__)

  @type t :: %{String.t() => term()}

  @doc "xipe_totec's own file of defaults (`defaults.json`)."
  @spec defaults_file() :: Path.t()
  def defaults_file, do: @defaults_file

  @doc "The project's own settings file."
  @spec file(Path.t()) :: Path.t()
  def file(project_dir), do: Path.join(project_dir, "project.json")

  @doc """
  The settings of the project whose directory is `project_dir`, defaults
  filled in (`nil`: the defaults alone).
  """
  @spec load(Path.t() | nil, Path.t()) :: t()
  def load(project_dir, defaults_file \\ @defaults_file) do
    stored = if project_dir, do: project_dir |> read() |> Map.delete("path"), else: %{}
    defaults(defaults_file) |> deep_merge(known(stored))
  end

  @doc "The keys `put/3` accepts, sorted."
  @spec keys() :: [String.t()]
  def keys, do: @keys |> Map.keys() |> Enum.sort()

  @doc "What `key` may be, as shown to a person: `prepend|replace`, `100..600000 ms`. `nil` for an unknown key."
  @spec allowed_text(String.t()) :: String.t() | nil
  def allowed_text(key) do
    case Map.get(@keys, key) do
      {:choice, values} -> Enum.join(values, "|")
      {:number, min, max, unit} -> "#{min}..#{max} #{unit}"
      nil -> nil
    end
  end

  @doc "`value` (as typed) as `key` stores it, or why it can't be."
  @spec check(String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def check(key, value) do
    case Map.fetch(@keys, key) do
      :error ->
        {:error, "unknown setting #{key} (#{Enum.join(keys(), ", ")})"}

      {:ok, {:choice, values}} ->
        if value in values, do: {:ok, value}, else: {:error, "#{key} must be one of #{Enum.join(values, "|")}, got #{inspect(value)}"}

      {:ok, {:number, min, max, unit}} ->
        case Integer.parse(String.trim(value)) do
          {n, ""} when n >= min and n <= max -> {:ok, n}
          _ -> {:error, "#{key} must be a whole number of #{unit} from #{min} to #{max}, got #{inspect(value)}"}
        end
    end
  end

  @doc "Set dotted `key` to `value` in `project_dir`'s project.json, keeping everything else."
  @spec put(Path.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def put(project_dir, key, value) do
    with {:ok, stored_value} <- check(key, value) do
      path = String.split(key, ".")
      stored = read(project_dir)
      File.write!(file(project_dir), JSON.encode!(put_in(stored, Enum.map(path, &Access.key(&1, %{})), stored_value)) <> "\n")
    end
  end

  @doc """
  Every setting with where its value comes from: `{key, value, file}`,
  sorted -- `file` is the project's own when it sets the key, else the
  defaults file (`nil` when even that doesn't have it: built in).
  """
  @spec entries(Path.t() | nil, Path.t()) :: [{String.t(), term(), Path.t() | nil}]
  def entries(project_dir, defaults_file \\ @defaults_file) do
    own = if project_dir, do: project_dir |> read() |> flat(), else: %{}
    from_file = defaults_file |> read_file() |> flat()

    for {key, value} <- flatten(load(project_dir, defaults_file)) do
      file =
        cond do
          Map.has_key?(own, key) -> file(project_dir)
          Map.has_key?(from_file, key) -> defaults_file
          true -> nil
        end

      {key, value, file}
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

  defp flat(settings), do: settings |> flatten() |> Map.new()

  # the defaults file over the built-in values; only the keys known here
  defp defaults(defaults_file), do: deep_merge(@builtin, defaults_file |> read_file() |> known())

  # a settings map cut down to the known keys with values that pass check/2
  # (a hand-edited file with a typo or a wrong value falls back, per key)
  defp known(settings) do
    for {key, value} <- flatten(settings), Map.has_key?(@keys, key), match?({:ok, _}, check(key, to_string(value))), reduce: %{} do
      acc -> put_in(acc, Enum.map(String.split(key, "."), &Access.key(&1, %{})), value)
    end
  end

  defp read(project_dir), do: read_file(file(project_dir))

  defp read_file(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = map} <- JSON.decode(text) do
      map
    else
      _ -> %{}
    end
  end

  defp deep_merge(a, b) do
    Map.merge(a, b, fn
      _k, x, y when is_map(x) and is_map(y) -> deep_merge(x, y)
      _k, _x, y -> y
    end)
  end
end
