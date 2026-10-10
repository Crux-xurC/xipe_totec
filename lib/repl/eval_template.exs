defmodule XipeTotec.Repl.EvalTemplate do
  @moduledoc """
  Builds the Elixir text for a `Core.Plan.Entry`: the call expression and
  everything wrapped around it. Pure string manipulation -- no process
  spawning, no I/O.

  Core hands over `args` with embeddable references already substituted
  (exact) and the rest left as placeholder tokens plus typed `inputs`
  (`Core.resolve_ref/4`). Every placeholder is already the final text --
  `xt_<call_id>`, the session variable an earlier entry of the same pass
  binds (`:in_plan`) -- so the call expression is the args joined as they
  are.
  """

  @doc """
  Builds the call expression text for `entry` (a map shaped like
  `Core.plan_recalc/3`'s `Plan.Entry`: `%{module:, name:, args:, inputs:}`).
  """
  @spec call_expression(map()) :: String.t()
  def call_expression(%{module: module, name: name, args: args}) do
    "#{module}.#{name}(#{Enum.join(args, ", ")})"
  end

  # compare's float tolerance. Fixed here; not configurable.
  @default_float_rel_tol 1.0e-9
  @default_float_abs_tol 1.0e-9

  @doc """
  Builds the full evaluation source text for `entry`:
  call-expression assembly + the safety wrapper (spawn_monitor/max_heap/
  timeout) + repr judgment + compare judgment against `entry.basis` +
  marker-wrapped printing, all as target-language text to be typed into
  the running REPL session. Nothing is evaluated locally: xipe_totec's own
  BEAM may not know the target project's types, and the *previous* value
  may need rebuilding from text/binary too, so both the rebuilding and the
  comparison happen in the session.

  Always binds the result to `xt_<call_id>` as a top-level statement: a
  later `:in_plan` reference in the same pass needs it. The session, and so
  the binding, lasts one pass.

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

  # An unclosed arg expression (`args: ["[1, 2"]`) must never be written to
  # the REPL: it reads as "more input coming", no marker is ever printed
  # for this entry, and everything written afterward is absorbed into the
  # open expression. Caught here, the entry fails at once with the real
  # reason instead of `session_hung`.
  #
  # The emitted text does not contain `call_expr` itself -- a fragment that
  # doesn't parse can't be spliced into any template -- only a diagnostic
  # string built on this side.
  defp build_syntax_error(call_id, call_expr, reason) do
    message = "invalid call expression: #{inspect(reason)} -- #{call_expr}" |> String.replace("\n", "\\n")
    "IO.puts(\"XT_ERROR_#{call_id} crash \" <> #{inspect(message, printable_limit: :infinity)})\n"
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
                   {:ok, elem(Code.eval_string(#{inspect(call_expr, printable_limit: :infinity)}, xt_binding_#{suffix}, xt_env_#{suffix}), 0)}
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
          # the call returned; what follows is judging the value
          IO.puts("XT_CALLED_#{call_id}")

          xt_oneline = fn s -> String.replace(s, "\\n", "\\\\n") end

          xt_unsupported? = fn f, v ->
            case v do
              p when is_pid(p) or is_port(p) or is_reference(p) or is_function(p) -> true
              l when is_list(l) -> Enum.any?(l, &f.(f, &1))
              t when is_tuple(t) -> t |> Tuple.to_list() |> Enum.any?(&f.(f, &1))
              # Map.to_list, not Enum on the map itself: a struct is a map
              # too, and Enum on a struct either raises (no Enumerable --
              # Date, URI, a project's own struct) or walks its elements
              # instead of its fields (MapSet, Range). Raised here, in the
              # session rather than the child, it printed no marker: the
              # entry read as session_hung and the rest of the pass as
              # aborted.
              m when is_map(m) -> m |> Map.to_list() |> Enum.any?(fn {k, mv} -> f.(f, k) or f.(f, mv) end)
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
          # one IO.puts of the whole block: nothing else can print inside it
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

  # Emits the statements that bind `xt_compare` (a plain string: "none" |
  # "skipped" | "changed" | "same"). `:none` (never evaluated before) skips
  # the rebuilding and comparison entirely. `xt_is_unsupported` makes an
  # unsupported *new* value "skipped" regardless of basis.
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
                  (a |> Map.to_list() |> Enum.all?(fn {k, v} -> f.(f, v, Map.get(b, k, :xt_missing_key)) end))

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
              {xt_prev_v, _} = Code.eval_string(#{inspect(prev_text, printable_limit: :infinity)})
              {:ok, xt_prev_v}
    """
  end

  defp reconstruct_snippet(:binary, prev_base64) do
    """
              {:ok, #{inspect(prev_base64, printable_limit: :infinity)} |> Base.decode64!() |> :erlang.binary_to_term()}
    """
  end
end
