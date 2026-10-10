Code.require_file("../field_drip.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.Elixir do
  @moduledoc """
  Elixir's `FieldDrip`: parses the `repr=`/`type=`/`display=`/
  `bin_base64=` key=value body `eval_template` writes between the
  `XT_BEGIN_<id>`/`XT_END_<id>` markers.

  The body format is xipe_totec's own, the same for every language: one
  `key=value` per line, split on the first `=`.
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
