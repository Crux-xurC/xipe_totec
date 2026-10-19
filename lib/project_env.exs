Code.require_file("project_config.exs", __DIR__)

defmodule XipeTotec.ProjectEnv do
  @moduledoc """
  The environment a project's own tools run in:
  one per project, used by everything xipe_totec starts for it -- the REPL
  (`Runner` → `Repl.Launch`'s `env`) and a language server it starts itself
  (`Lsp.Transport.Stdio`). A language server reached through tezcatl's
  relay gets its environment from tezcatl (its D-project-env), written the
  same way.

  How a project's environment is got is declared in xipe_totec's
  `project_env.json`, in the shape tezcatl's has (one way of writing for
  every tool, so someone without Nix adds a line):

      { "timeoutMs": 120000,
        "entries": [ { "marker": "flake.nix",
                       "command": ["nix", "print-dev-env", "--json"],
                       "format": "nix",
                       "watch": ["flake.nix", "flake.lock"] }, ... ] }

  The first entry whose `marker` is in the project's root is used; its
  `command` runs there, with xipe_totec's own environment, and prints JSON:

    * `"env"` -- `{"NAME": "value" | null}`; null unsets (direnv export
      json, mise env --json, a script of one's own). Values are taken as
      they are
    * `"nix"` -- `nix print-dev-env --json`: the exported variables as
      `nix develop` takes them, without the ones it leaves out (`HOME`,
      `TMPDIR` ...). `PATH` and `XDG_DATA_DIRS` meet xipe_totec's own as
      `env.path` says (`ProjectConfig`). `nix develop` itself is never
      started, so the `shellHook` doesn't run

  The answer is cached in `tables/project/<id>_<name>/env.json` with a hash
  of the files in `watch` (xipe_totec's own key, default the marker;
  tezcatl reads the same shape and asks again only on `env reload`) and of
  the entry itself. Later uses compare the hash; a change is resolved again
  only as the project's `env.refresh` allows. A project with no marker runs
  in xipe_totec's own environment.

  `resolve/3` returns `{env, status}`: `env` is the variables to add to the
  spawned process's environment (`%{}` for none; `false` unsets one),
  `status` what happened, JSON-safe for scan/eval reports:
  `%{"source" => <marker> | nil, "state" => "none" | "cached" | "resolved"
  | "stale" | "error", "message" => text | nil}`.
  """

  alias XipeTotec.ProjectConfig

  @config Path.expand("../project_env.json", __DIR__)
  @default_timeout 120_000
  @formats ["env", "nix"]
  @max_output 16 * 1024 * 1024

  # the variables `nix develop` doesn't carry over from the build
  # environment either (nix's own develop.cc ignoreVars)
  @ignored ~w(BASHOPTS HOME NIX_BUILD_TOP NIX_ENFORCE_PURITY NIX_LOG_FD NIX_REMOTE PPID SHELL SHELLOPTS
              SSL_CERT_FILE TEMP TEMPDIR TERM TMP TMPDIR TZ UID)
  # what `nix develop` puts before the shell's own value
  @prepended ~w(PATH XDG_DATA_DIRS)

  @type status :: %{String.t() => String.t() | nil}

  @doc """
  The environment for the project at `root` whose directory is
  `project_dir`. `opts`: `:force` resolves again even if the hash is
  unchanged or `env.refresh` is `manual` (`xipe table generate`);
  `:config` reads another `project_env.json` (tests).
  """
  @spec resolve(String.t(), Path.t() | nil, keyword()) :: {%{String.t() => String.t() | false}, status()}
  def resolve(root, project_dir, opts \\ [])

  def resolve(_root, nil, _opts), do: {%{}, status(nil, "none")}

  def resolve(root, project_dir, opts) do
    case read(Keyword.get(opts, :config, @config)) do
      {:error, message} ->
        {%{}, status(nil, "error", message <> " -- using xipe's own environment")}

      {:ok, cfg} ->
        case Enum.find(cfg.entries, &File.exists?(Path.join(root, &1.marker))) do
          nil -> {%{}, status(nil, "none")}
          entry -> resolve_entry(root, project_dir, entry, cfg.timeout_ms, opts)
        end
    end
  end

  defp resolve_entry(root, project_dir, entry, timeout_ms, opts) do
    settings = ProjectConfig.load(project_dir)["env"]
    hash = entry_hash(root, entry)
    cached = load_cache(project_dir, entry.marker)
    force = Keyword.get(opts, :force, false)

    cond do
      not force and cached != nil and cached["hash"] == hash ->
        {meet(cached["variables"], entry.format, settings), status(entry.marker, "cached")}

      force or settings["refresh"] == "auto" or cached == nil ->
        case run(entry, root, timeout_ms) do
          {:ok, variables} ->
            # a cache: one that cannot be written is only resolved again next time
            _ = File.write(cache_file(project_dir), JSON.encode!(%{"source" => entry.marker, "hash" => hash, "variables" => variables}) <> "\n")
            {meet(variables, entry.format, settings), status(entry.marker, "resolved")}

          {:error, message} ->
            fallback = if cached, do: meet(cached["variables"], entry.format, settings), else: %{}
            {fallback, status(entry.marker, "error", message <> if(cached, do: " -- using the previous environment", else: " -- using xipe's own environment"))}
        end

      true ->
        {meet(cached["variables"], entry.format, settings),
         status(entry.marker, "stale", "#{Enum.join(entry.watch, "/")} changed since the environment was resolved -- `xipe table generate` resolves it again (env.refresh=manual)")}
    end
  end

  @doc """
  Read and normalise a `project_env.json`: `{:ok, %{timeout_ms, entries}}`
  (broken entries are left out) or `{:error, message}`. No file is no
  entries.
  """
  def read(file) do
    case File.read(file) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, %{} = doc} -> normalize(doc)
          _ -> {:error, "#{file} is not a JSON object"}
        end

      {:error, :enoent} ->
        {:ok, %{timeout_ms: @default_timeout, entries: []}}

      {:error, reason} ->
        {:error, "#{file}: #{:file.format_error(reason)}"}
    end
  end

  defp normalize(doc) do
    entries = Map.get(doc, "entries", [])
    timeout = Map.get(doc, "timeoutMs", @default_timeout)

    cond do
      not is_list(entries) -> {:error, ~s(project_env.json: "entries" must be an array)}
      not (is_integer(timeout) and timeout > 0) -> {:error, ~s(project_env.json: "timeoutMs" must be a positive integer)}
      true -> {:ok, %{timeout_ms: timeout, entries: Enum.flat_map(entries, &entry/1)}}
    end
  end

  defp entry(%{"marker" => marker, "command" => [_ | _] = command} = raw) when is_binary(marker) and marker != "" do
    format = Map.get(raw, "format", "env")
    watch = Map.get(raw, "watch", [marker])

    if not String.contains?(marker, "/") and Enum.all?(command, &is_binary/1) and format in @formats and
         is_list(watch) and Enum.all?(watch, &is_binary/1),
       do: [%{marker: marker, command: command, format: format, watch: watch}],
       else: []
  end

  defp entry(_), do: []

  @doc """
  An entry's output -> `{:ok, variables}` (`false` for one to unset; for
  `nix` only the exported ones nix develop keeps) or `{:error, message}`.
  """
  def decode("env", text) do
    case JSON.decode(text) do
      {:ok, %{} = doc} ->
        case Enum.find(doc, fn {_k, v} -> not (is_binary(v) or is_nil(v)) end) do
          nil -> {:ok, Map.new(doc, fn {k, v} -> {k, if(is_nil(v), do: false, else: v)} end)}
          {k, _} -> {:error, "the value of #{k} is neither a string nor null"}
        end

      _ ->
        {:error, "the output is not a JSON object"}
    end
  end

  def decode("nix", text) do
    case JSON.decode(text) do
      {:ok, %{"variables" => %{} = variables}} ->
        exported =
          for {name, %{"type" => "exported", "value" => value}} <- variables,
              is_binary(value),
              name not in @ignored,
              into: %{},
              do: {name, value}

        {:ok, exported}

      _ ->
        {:error, "the output has no \"variables\" (is it nix print-dev-env --json?)"}
    end
  end

  @doc """
  `exe`'s full path, looked up on `env`'s `PATH` when it has one (a
  project's own tool, e.g. its `iex`), else on xipe_totec's own.
  """
  @spec find_executable(String.t(), %{String.t() => String.t() | false}) :: String.t() | nil
  def find_executable(exe, env) do
    case env do
      %{"PATH" => path} when is_binary(path) ->
        if String.contains?(exe, "/"),
          do: System.find_executable(exe),
          else: path |> String.split(":", trim: true) |> Enum.map(&Path.join(&1, exe)) |> Enum.find(&executable?/1)

      _ ->
        System.find_executable(exe)
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp status(source, state, message \\ nil), do: %{"source" => source, "state" => state, "message" => message}

  # a nix environment's PATH (and XDG_DATA_DIRS) meets xipe_totec's own as
  # env.path says; an env one is taken as it is (its tool already wrote the
  # whole value)
  defp meet(variables, "nix", settings) do
    if settings["path"] == "prepend" do
      Enum.reduce(@prepended, variables, fn name, acc ->
        case {acc, System.get_env(name)} do
          {%{^name => value}, own} when is_binary(value) and own not in [nil, ""] -> Map.put(acc, name, value <> ":" <> own)
          _ -> acc
        end
      end)
    else
      variables
    end
  end

  defp meet(variables, _format, _settings), do: variables

  defp run(%{command: [exe | args]} = entry, root, timeout_ms) do
    shown = Enum.join(entry.command, " ")

    with path when is_binary(path) <- System.find_executable(exe) || {:error, "#{exe} not found on PATH"},
         {:ok, _} <- Application.ensure_all_started(:erlexec),
         {:ok, _pid, ospid} <-
           :exec.run([path | args], [:stdout, :stderr, :monitor, {:cd, root}, {:group, 0}, :kill_group]),
         {:ok, out} <- collect(ospid, [], [], 0, System.monotonic_time(:millisecond) + timeout_ms, timeout_ms) do
      case decode(entry.format, out) do
        {:ok, variables} -> {:ok, variables}
        {:error, message} -> {:error, "#{shown}: #{message}"}
      end
    else
      {:error, message} when is_binary(message) -> {:error, "#{shown}: #{message}"}
      {:error, reason} -> {:error, "#{shown}: could not run (#{inspect(reason)})"}
    end
  end

  defp collect(ospid, out, err, size, deadline, timeout_ms) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:stdout, ^ospid, data} ->
        if size + byte_size(data) > @max_output do
          :exec.stop(ospid)
          {:error, "the output is over #{div(@max_output, 1024 * 1024)} MB"}
        else
          collect(ospid, [out, data], err, size + byte_size(data), deadline, timeout_ms)
        end

      {:stderr, ^ospid, data} ->
        collect(ospid, out, [err, data], size, deadline, timeout_ms)

      {:DOWN, ^ospid, :process, _pid, :normal} ->
        {:ok, IO.iodata_to_binary(out)}

      {:DOWN, ^ospid, :process, _pid, reason} ->
        {:error, "ended with #{ended(reason)}" <> tail(err)}
    after
      left ->
        :exec.stop(ospid)
        {:error, "no answer in #{div(timeout_ms, 1000)} s (timeoutMs of project_env.json)"}
    end
  end

  defp ended({:exit_status, st}) when is_integer(st) do
    case :exec.status(st) do
      {:status, code} -> "exit code #{code}"
      {:signal, sig, _core} -> "signal #{sig}"
    end
  end

  defp ended(reason), do: inspect(reason)

  # the last line the command said on stderr
  defp tail(err) do
    case err |> IO.iodata_to_binary() |> String.split("\n", trim: true) |> List.last() do
      nil -> ""
      line -> ": " <> String.slice(line, 0, 300)
    end
  end

  # the watched files and the entry itself: a changed declaration is
  # resolved again too
  defp entry_hash(root, entry) do
    files = for f <- entry.watch, into: "", do: f <> "\0" <> (File.read(Path.join(root, f)) |> elem_or_empty()) <> "\0"
    decl = Enum.join(entry.command, "\0") <> "\0" <> entry.format
    :crypto.hash(:sha256, files <> decl) |> Base.encode16(case: :lower)
  end

  defp elem_or_empty({:ok, text}), do: text
  defp elem_or_empty(_), do: ""

  defp cache_file(project_dir), do: Path.join(project_dir, "env.json")

  # the cache of the same marker (another marker's is not this entry's; a
  # cache from before project_env.json has no source and was a flake's)
  defp load_cache(project_dir, marker) do
    with {:ok, text} <- File.read(cache_file(project_dir)),
         {:ok, %{"hash" => _, "variables" => %{}} = cache} <- JSON.decode(text),
         true <- Map.get(cache, "source", "flake.nix") == marker do
      cache
    else
      _ -> nil
    end
  end
end
