Code.require_file("launch.exs", __DIR__)

defmodule XipeTotec.Repl.Ocaml.EvalTemplate do
  @moduledoc """
  OCaml's `eval_template` (Old.md §38/§42): one toplevel phrase per entry,
  `Embody.run "<id>" "xt_<id>" <timeout ms> "<let xt_<id> = <call>;;>" <prev>;;`.

  Every entry is wrapped in `embody` (next_step §2.5: the adapter wraps
  each call, the user never does). The call itself travels as a string, so
  the phrase written to the toplevel is always complete whatever the
  arguments hold -- an argument that doesn't parse is `embody`'s syntax
  error for that entry (`crash`), never a toplevel left waiting for more
  input (the hang `Repl.EvalTemplate` guards Elixir against).

  The call is `M.f (a) (b)`: each argument in parentheses, so a value
  embedded from another row (`-1`, `Some 2`) keeps its meaning. No
  arguments is `M.f`, the value itself (a function taking unit is called
  with the argument `()`). A reference to a row evaluated earlier in the
  same pass is the toplevel variable `xt_<id>` (Core's `:in_plan`), bound
  by that row's own phrase.

  Limits: `timeout` is SIGALRM inside `embody`. There is no per-entry
  memory limit (`max_heap_words` is ignored): a runaway entry is ended with
  the whole toplevel by the Evaluator's hang handling. A previous value is
  compared only as text that evaluates (`{:exact, text}`); OCaml has no
  `binary` repr yet, so a `{:binary, _}` basis compares as none.
  """

  alias XipeTotec.Repl.Ocaml.Launch

  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args}),
    do: Enum.join(["#{module}.#{name}" | Enum.map(args, &"(#{&1})")], " ")

  @spec build(map()) :: String.t()
  def build(%{call_id: call_id, limits: %{timeout: timeout_ms}} = entry) do
    # Core's own binding name (`binding_name/1`): what other rows' :in_plan
    # references to this one say
    var = "xt_" <> String.replace(call_id, ~r/[^A-Za-z0-9_]/, "_")
    phrase = "let #{var} = #{call_expression(entry)};;"

    prev =
      case Map.get(entry, :basis, :none) do
        {:exact, text} -> "(Some #{Launch.string(text)})"
        _ -> "None"
      end

    "Embody.run #{Launch.string(call_id)} #{Launch.string(var)} #{timeout_ms} #{Launch.string(phrase)} #{prev};;\n"
  end
end
