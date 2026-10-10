Code.require_file("project_registry.exs", __DIR__)
Code.require_file("surface_table.exs", __DIR__)
Code.require_file("info.exs", __DIR__)
Code.require_file("session.exs", __DIR__)

defmodule XipeTotec.Workspace do
  @moduledoc """
  Which target project a CLI command acts on, and where that project's
  own files live.

  Every per-project file sits under the project's own
  `tables/project/<id>_<name>/` directory (`ProjectRegistry`), never in
  the target project and never CWD-relative:

    * `project.json` -- the registry's own match key (`ProjectRegistry`)
    * `table`        -- the `SurfaceTable` rows (`xipe table generate`)
    * `book.jsonl`   -- the project's Book (`Store`)

  Each project has its own Book: scanning one project never touches
  another's nodes, rows or `effect/set` classifications.

  The currently selected project is `tables/selection.json`'s `project`
  field (an id), written only by `choose/3` -- machine-local and git-ignored
  like the rest of `tables/`. `resolve/3` is what every
  other command goes through: an explicit `<dir>` must already be
  registered (`scan`/`eval` never register a project silently), and
  no `<dir>` means the running `xipe start` session's project if there is
  one (`XipeTotec.Session`), else the selected project -- an explicit
  `<dir>` beats a session, and a session beats the stored selection.

  `roots` (the last argument everywhere) is `%{registry: ..., info: ...}`,
  defaulting to xipe_totec's own `tables/project/` and `info.json`, so
  tests can point both at a temp directory. The selection file is the
  registry's sibling (`selection_path/1`).
  """

  alias XipeTotec.{ProjectRegistry, Session, SurfaceTable}

  @type project :: %{id: String.t(), path: String.t(), dir: Path.t(), store_file: Path.t(), table_file: Path.t()}
  @type roots :: %{required(:registry) => Path.t(), required(:info) => Path.t(), optional(:session) => Path.t()}

  @spec default_roots() :: roots()
  def default_roots,
    do: %{
      registry: Path.expand("../tables/project", __DIR__),
      info: Path.expand("../info.json", __DIR__),
      session: Session.default_path()
    }

  @doc """
  The live `xipe start` session's record, or `:none` -- also `:none` when
  `roots` has no `:session` path (tests that don't care about sessions).
  """
  @spec session(roots()) :: {:ok, Session.record()} | :none
  def session(roots \\ default_roots()) do
    case Map.get(roots, :session) do
      nil -> :none
      path -> Session.read(path)
    end
  end

  @doc "The full `project` map for a registered `id`, or `nil`."
  @spec project(String.t(), roots()) :: project() | nil
  def project(id, roots \\ default_roots()) do
    case ProjectRegistry.lookup(id, roots.registry) do
      nil -> nil
      {dir, path} -> %{id: id, path: path, dir: dir, store_file: Path.join(dir, "book.jsonl"), table_file: Path.join(dir, "table")}
    end
  end

  @doc """
  `xipe table generate <path>`: registers `path` if it isn't yet
  (`ProjectRegistry.register/2` is idempotent), regenerates its surface
  table from scratch (no incremental tracking),
  reusing the previous table's row ids by path, and saves it.
  """
  @spec generate_table(String.t(), roots()) :: {project(), SurfaceTable.t()}
  def generate_table(path, roots \\ default_roots()) do
    unless File.dir?(path), do: raise(ArgumentError, "#{path} is not a directory")
    id = ProjectRegistry.register(path, roots.registry)
    project = project(id, roots)
    rows = SurfaceTable.generate(project.path, SurfaceTable.load(project.table_file))
    SurfaceTable.save(rows, project.table_file)
    {project, rows}
  end

  @doc """
  `xipe choice project <path>`: makes `path` the selected project. If no
  surface table exists for it yet (including when it isn't registered at
  all), runs `generate_table/2` first; an already-registered
  project with a table keeps its table as is. Returns `{project, :new |
  :existing}`.
  """
  @spec choose(String.t(), roots()) :: {project(), :new | :existing}
  def choose(path, roots \\ default_roots()) do
    {project, status} =
      case ProjectRegistry.find(path, roots.registry) do
        nil ->
          {project, _rows} = generate_table(path, roots)
          {project, :new}

        id ->
          project = project(id, roots)
          unless File.exists?(project.table_file), do: generate_table(path, roots)
          {project, :existing}
      end

    write_selection(roots, project.id)
    {project, status}
  end

  @doc "Where the selected project's id is kept: `selection.json` beside the registry directory."
  @spec selection_path(roots()) :: Path.t()
  def selection_path(roots), do: Path.join(Path.dirname(roots.registry), "selection.json")

  @doc "The selected project's id, or `nil`."
  @spec selected(roots()) :: String.t() | nil
  def selected(roots \\ default_roots()) do
    with {:ok, text} <- File.read(selection_path(roots)),
         {:ok, %{"project" => id}} when is_binary(id) <- JSON.decode(text) do
      id
    else
      _ -> nil
    end
  end

  defp write_selection(roots, id) do
    path = selection_path(roots)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"project" => id}) <> "\n")
  end

  @doc """
  The project a command acts on: `dir` (must already be registered) when
  given, otherwise the selected project (`selected/1`).
  """
  @spec resolve(String.t() | nil, roots()) :: {:ok, project()} | {:error, String.t()}
  def resolve(dir, roots \\ default_roots())

  def resolve(nil, roots) do
    case session(roots) do
      {:ok, %{"project" => id}} ->
        case project(id, roots) do
          nil -> {:error, "the running session's project #{id} is not registered under #{roots.registry}"}
          project -> {:ok, project}
        end

      :none ->
        resolve_selected(roots)
    end
  end

  def resolve(dir, roots) do
    case ProjectRegistry.find(dir, roots.registry) do
      nil -> {:error, "#{Path.expand(dir)} is not a registered project -- run `xipe choice project #{dir}` first"}
      id -> {:ok, project(id, roots)}
    end
  end

  defp resolve_selected(roots) do
    case selected(roots) do
      nil ->
        {:error, "no project selected -- run `xipe choice project <path>` first"}

      id ->
        case project(id, roots) do
          nil -> {:error, "selected project #{id} is not registered under #{roots.registry} -- run `xipe choice project <path>` again"}
          project -> {:ok, project}
        end
    end
  end
end
