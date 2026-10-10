Code.require_file("launch.exs", __DIR__)

defmodule XipeTotec.Repl.Haskell.EvalTemplate do
  @moduledoc """
  Haskell's `eval_template`: six GHCi lines per entry,
  every call wrapped in `embody.hs`:

      let xt_<id> = M.f (a) (b)
      let xt_<id>_w = Embody.whnf xt_<id>
      let xt_<id>_x = Embody.exact <Nothing | Just "<previous>"> xt_<id>
      let xt_<id>_s = Embody.shown xt_<id>
      let xt_<id>_t = Embody.typed xt_<id>
      Embody.run "<id>" <timeout µs> xt_<id>_w xt_<id>_x xt_<id>_s xt_<id>_t

  `-fdefer-type-errors` works on `let` bindings only, so everything that may
  lack an instance (or have a type error) is bound first, and the last line
  names only bindings that exist: every entry ends in a marker. A call that
  doesn't parse leaves `xt_<id>` unbound; the binding after it defers that
  (`Variable not in scope`) and `run` reports it as the crash. GHCi's own
  parse error goes to the output outside the markers.

  The call is `M.f (a) (b)`: each argument in parentheses, so an embedded
  value (`-1`, `Just 2`) keeps its meaning. No arguments is `M.f`, the value.
  A reference to a row evaluated earlier in the same pass is `xt_<id>`
  (Core's `:in_plan`). No per-entry memory limit (`max_heap_words` is
  ignored). A previous value is compared as text that reads back
  (`{:exact, text}`); a `{:binary, _}` basis compares as none.
  """

  alias XipeTotec.Repl.Haskell.Launch

  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args}),
    do: Enum.join(["#{module}.#{name}" | Enum.map(args, &"(#{&1})")], " ")

  @spec build(map()) :: String.t()
  def build(%{call_id: call_id, limits: %{timeout: timeout_ms}} = entry) do
    # Core's own binding name (`binding_name/1`)
    var = "xt_" <> String.replace(call_id, ~r/[^A-Za-z0-9_]/, "_")

    prev =
      case Map.get(entry, :basis, :none) do
        {:exact, text} -> "(Just #{Launch.string(text)})"
        _ -> "Nothing"
      end

    # a newline inside an argument would end the `let` line early
    call = entry |> call_expression() |> String.replace("\n", " ")

    """
    let #{var} = #{call}
    let #{var}_w = Embody.whnf #{var}
    let #{var}_x = Embody.exact #{prev} #{var}
    let #{var}_s = Embody.shown #{var}
    let #{var}_t = Embody.typed #{var}
    Embody.run #{Launch.string(call_id)} #{timeout_ms * 1000} #{var}_w #{var}_x #{var}_s #{var}_t
    """
  end
end
