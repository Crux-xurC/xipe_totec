defmodule XipeTotec.Repl.EvalTemplate do
  @moduledoc """
  Assembles the Elixir call-expression text for a `Core.Plan.Entry`
  (`document/repl-adapter-guide.md`'s `eval_template`, call-expression-
  assembly half). Pure string manipulation -- no process spawning, no I/O.

  Per 課題.mkd B's division of labor: Core hands over `args` with
  embeddable references already substituted (exact/binary) and
  non-embeddable ones left as placeholder tokens plus typed `inputs`
  (`core.exs`'s `resolve_ref/4`). This module is the "REPL adapter" side
  of that split -- it turns the remaining placeholders into real Elixir
  text.

  `in_plan`/`binding` placeholders are, per Core's own design, already
  the correct final text (`Atom.to_string(var)` -- a bare variable
  reference to a session binding that either already exists, or will by
  the time this entry runs within the same pass) -- nothing to do there.
  `inline_call` placeholders are not valid Elixir on their own; they must
  be replaced with the nested call expression Core deliberately did NOT
  build itself (building call syntax is this module's job, not Core's).

  A subtlety worth a callout: `binding_name/1` is deterministic
  (call_id-derived), so the *same* placeholder text can legitimately
  appear as an `:inline_call` target in one place and, in a deeper nested
  position, as a `:binding` fallback for the exact same call_id -- this
  happens precisely when `core.exs`'s occurs-check kicks in (a call
  reachable through more than one `inline_call` chain). A naive "replace
  every occurrence of this placeholder the same way" would silently
  reintroduce the infinite expansion Core's occurs-check exists to avoid.
  `expand/5`'s `expanding` accumulator (mirrors Core's own `visiting` set)
  is what keeps that from happening: while a placeholder's own inline
  expansion is in progress, any *further* occurrence of that same
  placeholder inside it is left as a bare reference (the binding
  fallback) instead of being expanded again.
  """

  @doc """
  Builds the call expression text for `entry` (a map shaped like
  `Core.plan_recalc/3`'s `Plan.Entry`: `%{module:, name:, args:, inputs:}`).
  """
  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args, inputs: inputs}) do
    resolved = resolve_args(args, inputs)
    "#{module}.#{name}(#{Enum.join(resolved, ", ")})"
  end

  @doc "Resolves every arg string's placeholders (see moduledoc). Exposed for direct testing."
  @spec resolve_args([String.t()], list()) :: [String.t()]
  def resolve_args(args, inputs) do
    inline_calls = for {:inline_call, m} <- inputs, into: %{}, do: {m.placeholder, m}
    bindings = for {:binding, m} <- inputs, into: %{}, do: {m.placeholder, m}

    Enum.map(args, &expand(&1, inline_calls, bindings, MapSet.new()))
  end

  defp expand(text, inline_calls, bindings, expanding) do
    placeholders = Map.keys(inline_calls) ++ Map.keys(bindings)

    placeholders
    |> Enum.uniq()
    |> Enum.reduce(text, fn placeholder, acc ->
      cond do
        not String.contains?(acc, placeholder) ->
          acc

        # already mid-expansion for this placeholder (occurs-check hit,
        # same reasoning as core.exs's `visiting`) -- must be the binding
        # fallback at this position, already valid text, leave as-is
        MapSet.member?(expanding, placeholder) ->
          acc

        Map.has_key?(inline_calls, placeholder) ->
          %{module: m, name: n, args: inner_args} = Map.fetch!(inline_calls, placeholder)
          inner = Enum.map(inner_args, &expand(&1, inline_calls, bindings, MapSet.put(expanding, placeholder)))
          String.replace(acc, placeholder, "#{m}.#{n}(#{Enum.join(inner, ", ")})")

        # a plain :binding or :in_plan placeholder -- already correct text
        true ->
          acc
      end
    end)
  end
end
