defmodule XipeTotec.Repl.Eval.FieldDrip do
  @moduledoc """
  Per-language parsing of the `XT_BEGIN`/`XT_END` body (the `repr=`/
  `type=`/`display=`/`bin_base64=` key=value lines `eval_template`
  writes) into the plain map `Repl.Eval.Result.success/3` expects.

  A behaviour: the caller (`Repl.Eval.Parser`) passes the concrete module
  for the language it already knows.
  """

  @callback parse(body :: String.t()) :: map()
end
