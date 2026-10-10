defmodule XipeTotec.Id do
  @moduledoc """
  ULID generation: a time-sortable, unique value that is never derived
  from a name or path -- the ID is the entity's actual identity.

  Every module here is namespaced under `XipeTotec.*`: the scanner compiles
  the *target* project's modules into this same BEAM to trace them, so an
  unnamespaced `Book` or `Id` could be silently redefined by a target that
  defines one itself.
  """

  import Bitwise

  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @crockford_chars @crockford |> Enum.map(&<<&1>>) |> List.to_tuple()

  @doc """
  A 26-character Crockford-base32 ULID: 48-bit millisecond timestamp
  (10 chars) followed by 80 bits of randomness (16 chars). Same-millisecond
  IDs are not made monotonic against each other -- only the millisecond
  timestamp orders them.
  """
  def ulid(now_ms \\ System.system_time(:millisecond)) do
    encode(now_ms, 10) <> encode(random_80(), 16)
  end

  defp random_80, do: :rand.uniform(1 <<< 80) - 1

  defp encode(n, len) do
    for i <- (len - 1)..0//-1, into: "" do
      elem(@crockford_chars, n |> bsr(i * 5) |> band(0x1F))
    end
  end
end
