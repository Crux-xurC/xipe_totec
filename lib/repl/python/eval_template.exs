Code.require_file("launch.exs", __DIR__)

defmodule XipeTotec.Repl.Python.EvalTemplate do
  @moduledoc """
  Python's `eval_template`: one line per entry,
  `_xt_embody.run("<id>", "xt_<id>", <timeout ms>, "<module>", "<call>", <basis>)`.

  Every entry is wrapped in `embody.py`'s `run`. The call travels as a
  string compiled inside `run`, so the line written to the REPL is always
  one complete statement whatever the arguments hold -- an argument that
  doesn't parse is that entry's `crash` (`SyntaxError`), never a REPL left
  waiting for more input.

  The call is `module.f((a), (b))`: each argument in parentheses, so a
  value embedded from another row keeps its meaning (`(1, 2)` stays one
  tuple argument only when written `((1, 2))`, as the user writes it).
  `run` imports the module and binds its top-level package name in
  `__main__` first. A reference to a row evaluated earlier in the same pass
  is the variable `xt_<id>` (Core's `:in_plan`), which `run` binds whatever
  the value's repr.

  Limits: `timeout` is SIGALRM inside `embody.py` (the call only; judging
  the value is under the Evaluator's deadline). There is no per-entry
  memory limit (`max_heap_words` is ignored): Python can only limit the
  whole process. A previous value is compared as text (`{:exact, text}`,
  `ast.literal_eval`) or as a pickle (`{:binary, base64}`).
  """

  alias XipeTotec.Repl.Python.Launch

  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args}),
    do: "#{module}.#{name}(" <> Enum.map_join(args, ", ", &"(#{&1})") <> ")"

  @spec build(map()) :: String.t()
  def build(%{call_id: call_id, module: module, limits: %{timeout: timeout_ms}} = entry) do
    # Core's own binding name (`binding_name/1`): what other rows' :in_plan
    # references to this one say
    var = "xt_" <> String.replace(call_id, ~r/[^A-Za-z0-9_]/, "_")

    basis =
      case Map.get(entry, :basis, :none) do
        {:exact, text} -> "(\"exact\", #{Launch.string(text)})"
        {:binary, b64} -> "(\"binary\", #{Launch.string(b64)})"
        _ -> "None"
      end

    "_xt_embody.run(#{Launch.string(call_id)}, #{Launch.string(var)}, #{timeout_ms}, #{Launch.string(module)}, " <>
      "#{Launch.string(call_expression(entry))}, #{basis})\n"
  end
end
