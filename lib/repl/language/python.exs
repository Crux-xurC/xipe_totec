Code.require_file("../language.exs", __DIR__)
Code.require_file("../python/launch.exs", __DIR__)
Code.require_file("../python/eval_template.exs", __DIR__)
Code.require_file("../eval/scan/direct/python.exs", __DIR__)
Code.require_file("../eval/field_drip/python.exs", __DIR__)
Code.require_file("../../scanner/python.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Python do
  @moduledoc """
  Python's `Repl.Language` self-declaration. REPL: `python -i`, with
  `embody.py` loaded into it
  ([D-python-adapter](../../../document/verification/lib-repl-language-python.exs.md#d-python-adapter)).

  Every project is loaded the same way: each `.py` file is importable as
  the module its path gives (`Scanner.Python.module_name/2`), through
  `embody.py`'s import hook, which runs only a module's definitions,
  imports and literal constants -- never its other top-level statements
  (`if __name__ == "__main__":` included). Packages the project imports
  that are not its own are imported as usual (their top level runs).

  The build tool doesn't change how the REPL starts: the project's
  virtual environment is used when there is one (`.venv/bin/python`, as
  uv and `python -m venv .venv` make it), else `python3` on PATH -- which
  a project's environment (`project_env.json`: Nix, a poetry environment
  ...) decides. Nothing is installed or synced while evaluating.
  """
  @behaviour XipeTotec.Repl.Language

  alias XipeTotec.Repl.Python.Launch
  alias XipeTotec.Scanner.Python, as: Scan

  @impl true
  def extensions, do: ["py"]

  @impl true
  def repl, do: "python"

  @impl true
  def build_tools,
    do: [
      %{"name" => "uv", "markers" => ["uv.lock"]},
      %{"name" => "poetry", "markers" => ["poetry.lock"]},
      %{"name" => "pip", "markers" => ["pyproject.toml", "requirements.txt", "setup.py"]}
    ]

  @impl true
  def scanner, do: [XipeTotec.Scanner.Python]

  @impl true
  def adapter do
    %{
      launch: XipeTotec.Repl.Python.Launch,
      eval_template: XipeTotec.Repl.Python.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Python,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.Python
    }
  end

  # the init file in a temp dir removed after the pass
  @impl true
  def launch_opts(root, _build_tool, files) do
    root = Path.expand(root)
    dir = Path.join(System.tmp_dir!(), "xipe_totec_python_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    init = Path.join(dir, "init.py")
    File.write!(init, Launch.init_file(modules(root, files)))
    {[argv: python(root), init: init], fn -> File.rm_rf!(dir) end}
  end

  @doc "The interpreter: the project's `.venv/bin/python` when it exists, else `python3`."
  @spec python(String.t()) :: [String.t()]
  def python(root) do
    venv = Path.join([root, ".venv", "bin", "python"])
    if File.exists?(venv), do: [venv], else: ["python3"]
  end

  @doc """
  The project's modules, `[{name, absolute path}]` in `files` order, one
  file per name (the first; two files can give one name, e.g. `geo.py` and
  `src/geo.py`).
  """
  @spec modules(String.t(), [String.t()]) :: [{String.t(), String.t()}]
  def modules(root, files) do
    files
    |> Enum.map(&{Scan.module_name(root, &1), Path.join(root, &1)})
    |> Enum.reject(fn {name, _} -> name == "" end)
    |> Enum.uniq_by(&elem(&1, 0))
  end
end
