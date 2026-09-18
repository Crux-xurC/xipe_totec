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

  @doc """
  Builds the full evaluation source text for `entry` (prebuild.md §10.3):
  call-expression assembly + the safety wrapper (spawn_monitor/max_heap/
  timeout) + repr judgment (prebuild.md §10.3's a -> b -> c) + marker-
  wrapped printing, all as target-language text to be typed into the
  running REPL session (never executed locally -- xipe_totec's own BEAM
  can't necessarily `inspect`/reconstruct the target project's own types).

  Always binds the result to `xt_<call_id>` as a top-level statement,
  regardless of `entry.bind_as` -- decided 2026-09-18: structurally
  required for any later `:in_plan` reference regardless of purity, and
  separately useful for tezcatl-side integration (crux: a live, inspectable
  session variable per evaluated call). `entry.bind_as` itself is not
  read here.

  `entry.call_id` doubles as the marker/variable-name suffix -- already
  unique (a ULID in production), no separate id generator needed.
  """
  @spec build(map()) :: String.t()
  def build(%{call_id: call_id, limits: %{timeout: timeout_ms, max_heap_words: max_heap_words}} = entry) do
    call_expr = call_expression(entry)
    suffix = sanitize(call_id)
    bind_var = "xt_#{suffix}"

    """
    xt_parent_#{suffix} = self()
    {xt_pid_#{suffix}, xt_ref_#{suffix}} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, #{max_heap_words})
        xt_val = (#{call_expr})
        send(xt_parent_#{suffix}, {:xt_result, self(), xt_val})
      end)

    #{bind_var} =
      receive do
        {:xt_result, ^xt_pid_#{suffix}, xt_val} ->
          Process.demonitor(xt_ref_#{suffix}, [:flush])

          xt_unsupported? = fn f, v ->
            case v do
              p when is_pid(p) or is_port(p) or is_reference(p) or is_function(p) -> true
              l when is_list(l) -> Enum.any?(l, &f.(f, &1))
              t when is_tuple(t) -> t |> Tuple.to_list() |> Enum.any?(&f.(f, &1))
              m when is_map(m) -> Enum.any?(m, fn {k, mv} -> f.(f, k) or f.(f, mv) end)
              _ -> false
            end
          end

          xt_type_name = fn v ->
            cond do
              is_integer(v) -> "integer"
              is_float(v) -> "float"
              is_boolean(v) -> "boolean"
              is_atom(v) -> "atom"
              is_binary(v) -> "binary"
              is_list(v) -> "list"
              is_tuple(v) -> "tuple"
              is_map(v) and Map.has_key?(v, :__struct__) -> inspect(v.__struct__)
              is_map(v) -> "map"
              is_pid(v) -> "pid"
              is_port(v) -> "port"
              is_reference(v) -> "reference"
              is_function(v) -> "function"
              true -> "term"
            end
          end

          cond do
            xt_unsupported?.(xt_unsupported?, xt_val) ->
              IO.puts("XT_BEGIN_#{call_id}")
              IO.puts("repr=unsupported")
              IO.puts("type=" <> xt_type_name.(xt_val))
              IO.puts("display=" <> inspect(xt_val, limit: :infinity, printable_limit: :infinity, width: :infinity))
              IO.puts("XT_END_#{call_id}")

            (xt_str = inspect(xt_val, limit: :infinity, printable_limit: :infinity, width: :infinity)) &&
              (try do
                {xt_ev, _} = Code.eval_string(xt_str)
                xt_ev == xt_val
              rescue
                _ -> false
              end) ->
              IO.puts("XT_BEGIN_#{call_id}")
              IO.puts("repr=exact")
              IO.puts("type=" <> xt_type_name.(xt_val))
              IO.puts("display=" <> xt_str)
              IO.puts("XT_END_#{call_id}")

            true ->
              IO.puts("XT_BEGIN_#{call_id}")
              IO.puts("repr=binary")
              IO.puts("type=" <> xt_type_name.(xt_val))
              IO.puts("display=" <> inspect(xt_val, limit: :infinity, printable_limit: :infinity, width: :infinity))
              IO.puts("bin_base64=" <> Base.encode64(:erlang.term_to_binary(xt_val)))
              IO.puts("XT_END_#{call_id}")
          end

          xt_val

        {:DOWN, ^xt_ref_#{suffix}, :process, ^xt_pid_#{suffix}, xt_reason} ->
          IO.puts("XT_ERROR_#{call_id} crash " <> inspect(xt_reason))
          nil
      after
        #{timeout_ms} ->
          Process.exit(xt_pid_#{suffix}, :kill)
          IO.puts("XT_ERROR_#{call_id} timeout")
          nil
      end
    """
  end

  # Matches Core's own `binding_name/1` exactly (core.exs) -- variable
  # names derived from this must agree with what Core already embedded
  # into other entries' args as :in_plan/:binding placeholder text.
  defp sanitize(call_id), do: String.replace(call_id, ~r/[^A-Za-z0-9_]/, "_")

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
