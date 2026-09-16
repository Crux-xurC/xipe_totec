ExUnit.start()

Code.require_file(Path.expand("../lib/id.exs", __DIR__))

defmodule IdTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Id

  test "ulid/1 is 26 characters of Crockford base32" do
    id = Id.ulid()
    assert String.length(id) == 26
    assert id =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/
  end

  test "ulid/1 sorts lexicographically with its timestamp argument" do
    a = Id.ulid(1_000)
    b = Id.ulid(2_000)
    assert a < b
  end

  test "ulid/0 calls do not collide across many calls" do
    ids = for _ <- 1..1_000, do: Id.ulid()
    assert length(Enum.uniq(ids)) == 1_000
  end
end
