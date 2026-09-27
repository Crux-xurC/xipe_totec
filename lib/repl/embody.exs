defmodule XipeTotec.Repl.Embody do
  @moduledoc """
  Where embody is (Old.md §44): the per-language fixed modules evaluated
  rows are wrapped in (`embody.ml`, `embody.hs`), kept in their own
  repository (git@github.com:Crux-xurC/embody.git). `$XIPE_TOTEC_EMBODY_DIR`,
  else the `embody` directory next to this xipe_totec checkout
  (`~/my_app/embody`).
  """

  @default_dir Path.expand("../../../embody", __DIR__)

  @spec dir() :: String.t()
  def dir, do: Path.expand(System.get_env("XIPE_TOTEC_EMBODY_DIR") || @default_dir)

  @doc "A file in it (`\"embody.ml\"`, `\"embody.hs\"`)."
  @spec path(String.t()) :: String.t()
  def path(file), do: Path.join(dir(), file)
end
