defmodule XipeTotec.Repl.EvalTemplate do
  @moduledoc """
  Assembles the Elixir call-expression text for a `Core.Plan.Entry`
  (`document/repl-adapter-guide.md`'s `eval_template`, call-expression-
  assembly half). Pure string manipulation -- no process spawning, no I/O.

  Per Old.md §28 B's division of labor: Core hands over `args` with
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

  # compare's float tolerance (Old.md §28 C: "誤差の値は設定パラメータにする").
  # No config-loading mechanism exists anywhere in this codebase yet (no
  # config.json, nothing reads one) -- introducing one just for this one
  # pair of numbers would be scope creep beyond what compare itself needs,
  # so these stay fixed module attributes until a real config system exists
  # to hang them off of. Flagged here rather than silently hardcoded inline.
  @default_float_rel_tol 1.0e-9
  @default_float_abs_tol 1.0e-9

  @doc """
  Builds the full evaluation source text for `entry` (Old.md §10.3):
  call-expression assembly + the safety wrapper (spawn_monitor/max_heap/
  timeout) + repr judgment (Old.md §10.3's a -> b -> c) + compare
  judgment against `entry.basis` (Old.md §28 C, 2026-09-18) + marker-wrapped
  printing, all as target-language text to be typed into the running REPL
  session (never executed locally -- xipe_totec's own BEAM can't
  necessarily `inspect`/reconstruct the target project's own types, and
  compare has the exact same problem one level up: the *previous* value
  may need reconstructing from text/binary too, so that reconstruction
  and the comparison itself both have to happen target-side).

  Always binds the result to `xt_<call_id>` as a top-level statement,
  regardless of `entry.bind_as` -- decided 2026-09-18: structurally
  required for any later `:in_plan` reference regardless of purity, and
  separately useful for tezcatl-side integration (crux: a live, inspectable
  session variable per evaluated call). `entry.bind_as` itself is not
  read here.

  `entry.call_id` doubles as the marker/variable-name suffix -- already
  unique (a ULID in production), no separate id generator needed.

  `entry[:basis]` (default `:none`, so hand-built entries without the key
  -- e.g. in tests -- still work): `{:exact, prev_text} | {:binary,
  prev_base64} | :none`, per `Core.build_entry/3`'s basis computation.
  """
  @spec build(map()) :: String.t()
  def build(%{call_id: call_id, limits: %{timeout: timeout_ms, max_heap_words: max_heap_words}} = entry) do
    call_expr = call_expression(entry)

    case Code.string_to_quoted(call_expr) do
      {:ok, _} -> build_eval(entry, call_id, call_expr, timeout_ms, max_heap_words)
      {:error, reason} -> build_syntax_error(call_id, call_expr, reason)
    end
  end

  # Review finding, 2026-09-18: an unclosed arg expression (`args: ["[1, 2"]`,
  # say -- a plain-string arg column has no syntax check anywhere upstream)
  # would previously get embedded into `call_expr` and written to the REPL
  # regardless. A REPL sees an incomplete expression as "more input coming"
  # (iex's own `...(N)>` continuation prompt) rather than an error -- it
  # never emits ANY marker for this entry, and everything written
  # afterward (the rest of a would-be marker-wrapped template, the *next*
  # entry's whole template) gets silently absorbed into the same still-open
  # expression instead of being parsed as separate statements. This was
  # invisible to hang detection before §5.10's absolute deadline
  # (`wait_result/6`) -- catching it here, before ever writing
  # anything to the session, is strictly better than waiting out that
  # deadline: the entry fails fast with the real reason instead of a
  # generic "session_hung", and the session is never put in the
  # continuation state in the first place.
  #
  # Deliberately does NOT touch `call_expr` in the emitted text -- a
  # fragment that doesn't parse standalone can't safely be spliced into
  # ANY larger template (that would just move the same unparseable-input
  # hazard one level up) -- this template only ever prints a diagnostic
  # string built entirely on xipe_totec's own side.
  defp build_syntax_error(call_id, call_expr, reason) do
    message = "invalid call expression: #{inspect(reason)} -- #{call_expr}" |> String.replace("\n", "\\n")
    "IO.puts(\"XT_ERROR_#{call_id} crash \" <> #{inspect(message)})\n"
  end

  defp build_eval(entry, call_id, call_expr, timeout_ms, max_heap_words) do
    basis = Map.get(entry, :basis, :none)
    suffix = sanitize(call_id)
    bind_var = "xt_#{suffix}"

    # `call_expr` travels as a string literal and is compiled inside the
    # spawned process (`Code.eval_string`), never spliced into the session's
    # own top-level text. Spliced in, a compile-time error in the arguments
    # (an undefined variable or local function -- it parses, so the
    # `Code.string_to_quoted` check above can't see it) made iex reject the
    # whole statement before `spawn_monitor` ever ran: no marker was printed,
    # the entry waited out the absolute deadline as `session_hung`, and every
    # later entry in the pass was `aborted`. Compiled in the child, the same
    # error is just an exit reason and takes the ordinary `crash` path.
    # Only the session bindings the expression actually names (`xt_<id>`
    # reference variables) are copied into the child.
    ref_vars = ~r/\bxt_[A-Za-z0-9_]+\b/ |> Regex.scan(call_expr) |> List.flatten() |> Enum.uniq()

    """
    xt_parent_#{suffix} = self()
    xt_binding_#{suffix} = Keyword.take(binding(), [#{Enum.map_join(ref_vars, ", ", &":#{&1}")}])
    xt_env_#{suffix} = __ENV__
    {xt_pid_#{suffix}, xt_ref_#{suffix}} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, #{max_heap_words})

        xt_val =
          case Code.with_diagnostics(fn ->
                 try do
                   {:ok, elem(Code.eval_string(#{inspect(call_expr)}, xt_binding_#{suffix}, xt_env_#{suffix}), 0)}
                 rescue
                   xt_e in [CompileError, SyntaxError, TokenMissingError] -> {:compile_error, xt_e}
                 end
               end) do
            {{:ok, xt_v}, _} -> xt_v
            {{:compile_error, xt_e}, []} -> exit({:compile_error, Exception.message(xt_e)})
            {{:compile_error, _}, xt_diags} -> exit({:compile_error, Enum.map_join(xt_diags, "; ", & &1.message)})
          end

        send(xt_parent_#{suffix}, {:xt_result, self(), xt_val})
      end)

    #{bind_var} =
      receive do
        {:xt_result, ^xt_pid_#{suffix}, xt_val} ->
          Process.demonitor(xt_ref_#{suffix}, [:flush])

          xt_oneline = fn s -> String.replace(s, "\\n", "\\\\n") end

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

          xt_is_unsupported = xt_unsupported?.(xt_unsupported?, xt_val)

    #{compare_snippet(basis)}
          # A single IO.puts/1 per branch, not one per field (fixed
          # 2026-09-18, review finding): several separate IO.puts calls are
          # each individually atomic at the group-leader level, but nothing
          # stops a DIFFERENT process's own output (Logger output, or
          # anything the evaluated call itself spawns and prints from) from
          # being interleaved *between* our calls, landing inside the
          # XT_BEGIN..XT_END span as a line that doesn't match the
          # key=value format and breaks FieldDrip.Elixir.parse/1. One
          # IO.puts of the whole joined block is one atomic write, so
          # nothing else can land inside it.
          cond do
            xt_is_unsupported ->
              IO.puts(
                Enum.join(
                  [
                    "XT_BEGIN_#{call_id}",
                    "repr=unsupported",
                    "type=" <> xt_type_name.(xt_val),
                    "compare=" <> xt_compare,
                    "display=" <> xt_oneline.(inspect(xt_val, limit: :infinity, printable_limit: :infinity, width: :infinity)),
                    "XT_END_#{call_id}"
                  ],
                  "\\n"
                )
              )

            (xt_str = inspect(xt_val, limit: :infinity, printable_limit: :infinity, width: :infinity)) &&
              not String.contains?(xt_str, "\\n") &&
              (try do
                {xt_ev, _} = Code.eval_string(xt_str)
                xt_ev == xt_val
              rescue
                _ -> false
              end) ->
              IO.puts(
                Enum.join(
                  [
                    "XT_BEGIN_#{call_id}",
                    "repr=exact",
                    "type=" <> xt_type_name.(xt_val),
                    "compare=" <> xt_compare,
                    "display=" <> xt_str,
                    "XT_END_#{call_id}"
                  ],
                  "\\n"
                )
              )

            true ->
              IO.puts(
                Enum.join(
                  [
                    "XT_BEGIN_#{call_id}",
                    "repr=binary",
                    "type=" <> xt_type_name.(xt_val),
                    "compare=" <> xt_compare,
                    "display=" <> xt_oneline.(inspect(xt_val, limit: :infinity, printable_limit: :infinity, width: :infinity)),
                    "bin_base64=" <> Base.encode64(:erlang.term_to_binary(xt_val)),
                    "XT_END_#{call_id}"
                  ],
                  "\\n"
                )
              )
          end

          xt_val

        {:DOWN, ^xt_ref_#{suffix}, :process, ^xt_pid_#{suffix}, xt_reason} ->
          Process.demonitor(xt_ref_#{suffix}, [:flush])

          if xt_reason == :killed do
            # the only thing that ever sends this pid a :kill while it's
            # still running its own body is Process.flag(:max_heap_size,
            # ...) above -- our own timeout kill (the `after` clause below)
            # is a separate receive branch that returns before this one
            # could ever see that DOWN, so :killed here is unambiguous.
            IO.puts("XT_ERROR_#{call_id} max_heap")
          else
            IO.puts("XT_ERROR_#{call_id} crash " <> String.replace(inspect(xt_reason, limit: :infinity, printable_limit: :infinity, width: :infinity), "\\n", "\\\\n"))
          end

          nil
      after
        #{timeout_ms} ->
          Process.demonitor(xt_ref_#{suffix}, [:flush])
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

  # Emits the statements needed to bind `xt_compare` (a plain string --
  # "none" | "skipped" | "changed" | "same", the same string-typed
  # convention `Core`/`core_test.exs` already use for repr/compare, not
  # atoms -- see Old.md §28 C and the B2 JSON-safety rule this mirrors).
  # `:none` (never evaluated before) skips reconstruction/comparison
  # machinery entirely, keeping the common "first eval of this call" case
  # cheap; `xt_is_unsupported` (computed once above, for the repr cond
  # too) makes an unsupported *new* value "skipped" regardless of basis,
  # per Old.md §28 C's "either side unsupported -> skipped".
  defp compare_snippet(:none), do: ~s(      xt_compare = "none"\n)

  defp compare_snippet({tag, prev_text}) when tag in [:exact, :binary] do
    """
          xt_float_close? = fn a, b ->
            xt_d = abs(a - b)
            xt_d <= #{inspect(@default_float_abs_tol)} or xt_d <= #{inspect(@default_float_rel_tol)} * max(abs(a), abs(b))
          end

          xt_eq = fn f, a, b ->
            cond do
              is_float(a) and is_float(b) -> xt_float_close?.(a, b)
              is_list(a) and is_list(b) and length(a) == length(b) ->
                Enum.zip(a, b) |> Enum.all?(fn {x, y} -> f.(f, x, y) end)

              is_tuple(a) and is_tuple(b) and tuple_size(a) == tuple_size(b) ->
                Enum.zip(Tuple.to_list(a), Tuple.to_list(b)) |> Enum.all?(fn {x, y} -> f.(f, x, y) end)

              is_map(a) and is_map(b) ->
                Enum.sort(Map.keys(a)) == Enum.sort(Map.keys(b)) and
                  Enum.all?(a, fn {k, v} -> f.(f, v, Map.get(b, k, :xt_missing_key)) end)

              true ->
                a == b
            end
          end

          xt_prev_result =
            try do
    #{reconstruct_snippet(tag, prev_text)}
            rescue
              _ -> :error
            end

          xt_compare =
            cond do
              xt_is_unsupported ->
                "skipped"

              true ->
                case xt_prev_result do
                  {:ok, xt_prev} -> if xt_eq.(xt_eq, xt_val, xt_prev), do: "same", else: "changed"
                  :error -> "skipped"
                end
            end
    """
  end

  defp reconstruct_snippet(:exact, prev_text) do
    """
              {xt_prev_v, _} = Code.eval_string(#{inspect(prev_text)})
              {:ok, xt_prev_v}
    """
  end

  defp reconstruct_snippet(:binary, prev_base64) do
    """
              {:ok, #{inspect(prev_base64)} |> Base.decode64!() |> :erlang.binary_to_term()}
    """
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
