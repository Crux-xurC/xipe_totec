Code.require_file("../embody.exs", __DIR__)

defmodule XipeTotec.Repl.Haskell.Launch do
  @moduledoc """
  Haskell's `launch` (GHCi): the same JSON-able message
  `Repl.Launch` builds, with GHCi's values.

  GHCi is started as

      ghci -v0 -w -fdefer-type-errors -i<dirs> -ghci-script <script>

  and the script (`script/2`, written by `Repl.Language.Haskell.launch_opts/3`)
  `:load`s `embody.hs` with the project's files and brings the project's
  modules into scope with `:module + *M ...` -- so a function a module
  doesn't export is still `M.f`. Loading runs nothing (no `main`), so there
  is nothing to sanitize. `message["files"]` stays empty (`Sender.Direct`
  would turn it into `iex`'s `-r`).

    * `-v0`: no banner, no prompt; `-w`: no warnings in the output
    * `-fdefer-type-errors`: a `let` binding with a missing instance or a
      type error becomes a runtime TypeError, which is how `embody.hs` tells
      exact / shown / typed apart
    * `ready_probe` makes GHCi print `XT_READY` once the script is done
    * interruptible: SIGINT stops the running evaluation ("Interrupted.") and
      GHCi goes on reading (confirmed with GHC 9.10.3)
  """

  @flags ~w(-v0 -w -fdefer-type-errors -Wno-deferred-type-errors -Wno-deferred-out-of-scope-variables)

  @doc "`opts`: `:cwd` (required), `:script`, `:include` (the `-i` dirs), `:argv` (default `[\"ghci\"]`), `:env`."
  @spec build(keyword()) :: %{String.t() => term()}
  def build(opts) do
    argv =
      Keyword.get(opts, :argv, ["ghci"]) ++
        @flags ++
        Enum.map(Keyword.get(opts, :include, []), &("-i" <> &1)) ++
        if(script = opts[:script], do: ["-ghci-script", script], else: [])

    %{
      "kind" => "repl/launch",
      "argv" => argv,
      "env" => Keyword.get(opts, :env, %{}),
      "cwd" => Keyword.fetch!(opts, :cwd),
      "files" => [],
      "ready_pattern" => nil,
      # the marker split so an echo of the line can't be taken for it
      "ready_probe" => ~s|putStrLn ("XT_" ++ "READY")\n|,
      "exit_input" => ":quit\n",
      "interruptible" => true
    }
  end

  @doc "`embody.hs`'s path (`Repl.Embody`)."
  @spec embody_path() :: String.t()
  def embody_path, do: XipeTotec.Repl.Embody.path("embody.hs")

  @doc "The GHCi script: load embody and `paths` (absolute), then `modules` into scope."
  @spec script([String.t()], [String.t()]) :: String.t()
  def script(paths, modules) do
    ":load #{Enum.map_join([embody_path() | paths], " ", &quote_path/1)}\n" <>
      if(modules == [], do: "", else: ":module + #{Enum.map_join(modules, " ", &("*" <> &1))}\n")
  end

  # GHCi splits :load's arguments on spaces; a path with one is quoted
  defp quote_path(path), do: if(String.contains?(path, " "), do: ~s|"#{path}"|, else: path)

  @doc "A Haskell string literal for `text`."
  @spec string(String.t()) :: String.t()
  def string(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end
end
