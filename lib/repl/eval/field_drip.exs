defmodule XipeTotec.Repl.Eval.FieldDrip do
  @moduledoc """
  Per-language parsing of the `XT_BEGIN`/`XT_END` body (the `repr=`/
  `type=`/`display=`/`bin_base64=` key=value lines `eval_template`
  writes) into the plain map `Repl.Eval.Result.success/3` expects.

  Same shape as `Repl.Sender`/`Repl.Eval.Scan.Direct.Iex`: a behaviour,
  with the caller (`Repl.Eval.Parser`) picking the concrete module
  explicitly (`FieldDrip.Elixir`) -- the language is already known from
  context, same as the REPL/transport choice for `Scan.<transport>.
  <repl>`, so there's no separate language-detection step here.
  """

  @callback parse(body :: String.t()) :: map()
end
