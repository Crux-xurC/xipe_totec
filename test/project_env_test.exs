ExUnit.start()

Code.require_file(Path.expand("../lib/project_env.exs", __DIR__))

defmodule ProjectEnvTest do
  use ExUnit.Case

  alias XipeTotec.{ProjectConfig, ProjectEnv}

  setup do
    base = Path.join(System.tmp_dir!(), "xipe_totec_project_env_test_#{System.unique_integer([:positive])}")
    root = Path.join(base, "target")
    project_dir = Path.join(base, "tables/001_target")
    File.mkdir_p!(root)
    File.mkdir_p!(project_dir)
    File.write!(Path.join(project_dir, "project.json"), JSON.encode!(%{"path" => root}))

    # stands in for `nix print-dev-env --json <root>`: prints a fixed
    # environment, and counts its runs in <base>/runs
    fake = Path.join(base, "fake-print-dev-env")

    File.write!(fake, """
    #!/bin/sh
    echo run >> #{base}/runs
    cat <<'JSON'
    {"variables": {
      "PATH": {"type": "exported", "value": "/nix/store/x-elixir/bin"},
      "ERL_LIBS": {"type": "exported", "value": "/nix/store/x-cowboy/lib"},
      "HOME": {"type": "exported", "value": "/homeless-shelter"},
      "TMPDIR": {"type": "exported", "value": "/build"},
      "shellHook": {"type": "var", "value": "echo hi"},
      "arr": {"type": "array", "value": ["a"]}
    }, "bashFunctions": {}}
    JSON
    """)

    File.chmod!(fake, 0o755)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, root: root, project_dir: project_dir, opts: [command: [fake]]}
  end

  # how many times the fake command ran
  defp runs(base) do
    case File.read(Path.join(base, "runs")) do
      {:ok, text} -> length(String.split(text, "\n", trim: true))
      _ -> 0
    end
  end

  test "no flake.nix: no environment of its own", %{root: root, project_dir: project_dir, opts: opts} do
    assert {%{}, %{"state" => "none", "source" => nil}} = ProjectEnv.resolve(root, project_dir, opts)
    assert {%{}, %{"state" => "none"}} = ProjectEnv.resolve(root, nil, opts)
  end

  test "a flake is resolved once, exported variables only (minus nix develop's ignored ones), then cached",
       %{base: base, root: root, project_dir: project_dir, opts: opts} do
    File.write!(Path.join(root, "flake.nix"), "{ }")

    assert {env, %{"state" => "resolved", "source" => "flake.nix"}} = ProjectEnv.resolve(root, project_dir, opts)
    assert env["ERL_LIBS"] == "/nix/store/x-cowboy/lib"
    refute Map.has_key?(env, "HOME")
    refute Map.has_key?(env, "TMPDIR")
    refute Map.has_key?(env, "shellHook")
    # env.path=prepend (default): the flake's PATH in front of xipe's own
    assert env["PATH"] == "/nix/store/x-elixir/bin:" <> System.get_env("PATH", "")

    assert {^env, %{"state" => "cached"}} = ProjectEnv.resolve(root, project_dir, opts)
    assert runs(base) == 1
  end

  test "env.path=replace uses the flake's PATH alone", %{root: root, project_dir: project_dir, opts: opts} do
    File.write!(Path.join(root, "flake.nix"), "{ }")
    :ok = ProjectConfig.put(project_dir, "env.path", "replace")
    assert {%{"PATH" => "/nix/store/x-elixir/bin"}, _} = ProjectEnv.resolve(root, project_dir, opts)
  end

  test "a changed flake: auto resolves again, manual keeps the old one and says stale; force always resolves",
       %{base: base, root: root, project_dir: project_dir, opts: opts} do
    File.write!(Path.join(root, "flake.nix"), "{ }")
    {_env, %{"state" => "resolved"}} = ProjectEnv.resolve(root, project_dir, opts)

    File.write!(Path.join(root, "flake.lock"), "{}")
    assert {_env, %{"state" => "resolved"}} = ProjectEnv.resolve(root, project_dir, opts)
    assert runs(base) == 2

    :ok = ProjectConfig.put(project_dir, "env.refresh", "manual")
    File.write!(Path.join(root, "flake.nix"), "{ inputs = { }; }")
    assert {env, %{"state" => "stale", "message" => message}} = ProjectEnv.resolve(root, project_dir, opts)
    assert message =~ "xipe table generate"
    assert env["ERL_LIBS"] == "/nix/store/x-cowboy/lib"
    assert runs(base) == 2

    assert {_env, %{"state" => "resolved"}} = ProjectEnv.resolve(root, project_dir, Keyword.put(opts, :force, true))
    assert {_env, %{"state" => "cached"}} = ProjectEnv.resolve(root, project_dir, opts)
    assert runs(base) == 3
  end

  test "a failing command is an error status, falling back to xipe's own environment",
       %{root: root, project_dir: project_dir} do
    File.write!(Path.join(root, "flake.nix"), "{ }")
    assert {%{}, %{"state" => "error", "message" => message}} = ProjectEnv.resolve(root, project_dir, command: ["false"])
    assert message =~ "xipe's own environment"
  end

  test "find_executable/2 looks on env's PATH first", %{base: base} do
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "mytool"), "#!/bin/sh\n")
    File.chmod!(Path.join(bin, "mytool"), 0o755)

    assert ProjectEnv.find_executable("mytool", %{"PATH" => bin}) == Path.join(bin, "mytool")
    assert ProjectEnv.find_executable("mytool", %{}) == nil
    assert ProjectEnv.find_executable("sh", %{}) == System.find_executable("sh")
  end

  describe "ProjectConfig" do
    test "defaults, put keeps path, bad key/value refused", %{project_dir: project_dir} do
      assert ProjectConfig.load(project_dir)["env"] == %{"path" => "prepend", "refresh" => "auto"}
      assert :ok = ProjectConfig.put(project_dir, "env.refresh", "manual")
      assert ProjectConfig.load(project_dir)["env"] == %{"path" => "prepend", "refresh" => "manual"}
      assert %{"path" => _} = project_dir |> Path.join("project.json") |> File.read!() |> JSON.decode!()

      assert {:error, _} = ProjectConfig.put(project_dir, "env.path", "sideways")
      assert {:error, _} = ProjectConfig.put(project_dir, "nope", "x")
      assert [{"env.path", "prepend"}, {"env.refresh", "manual"} | _] = ProjectConfig.flatten(ProjectConfig.load(project_dir))
    end
  end
end
