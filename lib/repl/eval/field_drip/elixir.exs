Code.require_file("../field_drip.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.Elixir do
  @moduledoc """
  Elixir's `FieldDrip`: parses the `repr=`/`type=`/`display=`/
  `bin_base64=` key=value body `eval_template` (Elixir's `eval_template`,
  `lib/repl/eval_template.exs`) writes between the `XT_BEGIN_<id>`/
  `XT_END_<id>` markers.

  This body format is a xipe_totec-wide protocol decision (not derived
  from Elixir's own syntax -- WE chose it, and every `eval_template` we
  write is expected to conform to it), so this parser ends up genuinely
  simple: split lines, split each on the first `=`. Kept as its own
  module (rather than folded into the generic `FieldDrip` behaviour)
  because a future language whose `eval_template` can't cleanly produce
  this exact shape would need its own override here -- the behaviour
  seam exists for that, even though today's Elixir implementation and a
  hypothetical fully-generic default would look identical.
  """

  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  def parse(body) do
    body
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {key, value}
    end)
  end
end
