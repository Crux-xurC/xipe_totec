Code.require_file("project_config.exs", __DIR__)

defmodule XipeTotec.ProjectEnv do
  @moduledoc """
  The environment a project's own tools run in (Old.md §25.6, 2026-09-26):
  one per project, used by everything xipe_totec starts for it -- the REPL
  (`Runner` → `Repl.Launch`'s `env`) and a language server it starts itself
  (`Lsp.Transport.Stdio`). A language server reached through tezcatl's
  relay runs in tezcatl's environment, outside this.

  A project with a `flake.nix` at its root gets its dev shell's variables
  from `nix print-dev-env --json <root>`, resolved once and cached in
  `tables/project/<id>_<name>/env.json` together with a hash of
  `flake.nix`/`flake.lock`. Later uses compare the hash; a changed flake
  is resolved again only as the project's `env.refresh` setting
  (`ProjectConfig`) allows. `nix develop` itself is never started, so the
  flake's `shellHook` doesn't run: variables it exports are not part of
  the environment. A project without a `flake.nix` (`shell.nix` included,
  課題.md) runs in xipe_totec's own environment, as before.

  `resolve/3` returns `{env, status}`: `env` is the variables to add to the
  spawned process's environment (`%{}` for none), `status` what happened,
  JSON-safe for scan/eval reports: `%{"source" => "flake.nix" | nil,
  "state" => "none" | "cached" | "resolved" | "stale" | "error",
  "message" => text | nil}`.
  """

  alias XipeTotec.ProjectConfig

  # the variables `nix develop` doesn't carry over from the build
  # environment either (nix's own develop.cc ignoreVars)
  @ignored ~w(BASHOPTS HOME NIX_BUILD_TOP NIX_ENFORCE_PURITY NIX_LOG_FD NIX_REMOTE PPID SHELL SHELLOPTS
              SSL_CERT_FILE TEMP TEMPDIR TERM TMP TMPDIR TZ UID)

  @type status :: %{String.t() => String.t() | nil}

  @doc """
  The environment for the project at `root` whose directory is
  `project_dir`. `opts`: `:force` resolves the flake again even if its hash
  is unchanged or `env.refresh` is `manual` (`xipe table generate`);
  `:command` replaces `nix print-dev-env --json` (tests: `[exe | args]`,
  run with `root` appended).
  """
  @spec resolve(String.t(), Path.t() | nil, keyword()) :: {%{String.t() => String.t()}, status()}
  def resolve(root, project_dir, opts \\ [])

  def resolve(_root, nil, _opts), do: {%{}, status(nil, "none")}

  def resolve(root, project_dir, opts) do
    flake = Path.join(root, "flake.nix")

    if File.exists?(flake) do
      settings = ProjectConfig.load(project_dir)["env"]
      hash = flake_hash(root)
      cached = load_cache(project_dir)
      force = Keyword.get(opts, :force, false)

      cond do
        not force and cached != nil and cached["hash"] == hash ->
          {apply_path(cached["variables"], settings), status("flake.nix", "cached")}

        force or settings["refresh"] == "auto" or cached == nil ->
          case print_dev_env(root, opts) do
            {:ok, variables} ->
              File.write!(cache_file(project_dir), JSON.encode!(%{"source" => "flake.nix", "hash" => hash, "variables" => variables}) <> "\n")
              {apply_path(variables, settings), status("flake.nix", "resolved")}

            {:error, message} ->
              fallback = if cached, do: apply_path(cached["variables"], settings), else: %{}
              {fallback, status("flake.nix", "error", message <> if(cached, do: " -- using the previous environment", else: " -- using xipe's own environment"))}
          end

        true ->
          {apply_path(cached["variables"], settings),
           status("flake.nix", "stale", "flake.nix/flake.lock changed since the environment was resolved -- `xipe table generate` resolves it again (env.refresh=manual)")}
      end
    else
      {%{}, status(nil, "none")}
    end
  end

  @doc """
  `exe`'s full path, looked up on `env`'s `PATH` when it has one (a
  project's own tool, e.g. its `iex`), else on xipe_totec's own.
  """
  @spec find_executable(String.t(), %{String.t() => String.t()}) :: String.t() | nil
  def find_executable(exe, env) do
    case env do
      %{"PATH" => path} ->
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

  defp apply_path(variables, settings) do
    case {variables, settings["path"]} do
      {%{"PATH" => path}, "prepend"} -> Map.put(variables, "PATH", Enum.join([path, System.get_env("PATH", "")], ":"))
      _ -> variables
    end
  end

  defp print_dev_env(root, opts) do
    [exe | args] = Keyword.get(opts, :command, ["nix", "print-dev-env", "--json"])

    case System.find_executable(exe) do
      nil ->
        {:error, "#{exe} not found on PATH"}

      path ->
        case System.cmd(path, args ++ [root], stderr_to_stdout: false) do
          {out, 0} ->
            case JSON.decode(out) do
              {:ok, %{"variables" => variables}} -> {:ok, exported(variables)}
              _ -> {:error, "#{Enum.join([exe | args], " ")}: unexpected output"}
            end

          {_out, code} ->
            {:error, "#{Enum.join([exe | args], " ")} #{root} exited with #{code}"}
        end
    end
  end

  defp exported(variables) do
    for {name, %{"type" => "exported", "value" => value}} <- variables,
        is_binary(value),
        name not in @ignored,
        into: %{},
        do: {name, value}
  end

  defp flake_hash(root) do
    content = for f <- ["flake.nix", "flake.lock"], into: "", do: f <> "\0" <> (File.read(Path.join(root, f)) |> elem_or_empty())
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp elem_or_empty({:ok, text}), do: text
  defp elem_or_empty(_), do: ""

  defp cache_file(project_dir), do: Path.join(project_dir, "env.json")

  defp load_cache(project_dir) do
    with {:ok, text} <- File.read(cache_file(project_dir)),
         {:ok, %{"hash" => _, "variables" => %{}} = cache} <- JSON.decode(text) do
      cache
    else
      _ -> nil
    end
  end
end
