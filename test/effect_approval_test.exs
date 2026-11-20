ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/dispatch.exs", __DIR__))

# D-effect-approval and D-mcp-effects: a person's class holds for the body
# it was given for (a rescan finding another body takes it back to
# "changed"); an agent only proposes a class, with its reason, and nothing
# is evaluated until a person approves it; rows tell whose they are.
defmodule EffectApprovalTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core, Dispatch}

  @source """
  defmodule ApprA do
    def double(x), do: x * 2
    def triple(x), do: x * 3
  end
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_effect_approval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), @source)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, book, _} = Dispatch.handle(Book.new(), "scan/run", %{}, %{root: dir})
    {:ok, dir: dir, book: book, double: node_id(book, "double"), triple: node_id(book, "triple")}
  end

  defp node_id(book, name), do: Enum.find_value(book.nodes, fn {id, n} -> n.name == name && id end)

  defp rescan(book, dir), do: elem(Dispatch.handle(book, "scan/run", %{}, %{root: dir}), 1)

  defp add_row(book, node, opts \\ %{}) do
    {:ok, book, %{"id" => id}} = Dispatch.handle(book, "row/add", Map.merge(%{"node" => node, "args" => ["2"]}, opts), %{})
    {book, id}
  end

  test "effect/set records the body it approved; a rescan with the same body keeps it", %{book: book, dir: dir, double: d} do
    {:ok, book, _} = Dispatch.handle(book, "effect/set", %{"id" => d, "effect" => "pure"}, %{})
    node = Book.get(book, :nodes, d)
    assert node.effect_source == "user"
    assert node.effect_hash == node.body_hash

    book = rescan(book, dir)
    assert Book.get(book, :nodes, d).effect_source == "user"
  end

  test "a changed body takes the approval back to \"changed\"; it is not evaluated until approved again",
       %{book: book, dir: dir, double: d, triple: t} do
    {:ok, book, _} = Dispatch.handle(book, "effect/set", %{"id" => d, "effect" => "pure"}, %{})
    {:ok, book, _} = Dispatch.handle(book, "effect/set", %{"id" => t, "effect" => "pure"}, %{})
    {book, row} = add_row(book, d)

    File.write!(Path.join(dir, "lib/a.ex"), String.replace(@source, "x * 2", "File.write!(\"/tmp/x\", \"\") && x * 2"))
    book = rescan(book, dir)

    node = Book.get(book, :nodes, d)
    assert node.effect == "pure"
    assert node.effect_source == "changed"
    # triple's body is the same: still approved
    assert Book.get(book, :nodes, t).effect_source == "user"

    assert Core.filter_by_effect(book, [row]) == []
    assert Core.exclusion_reason(book, row) =~ "body changed"

    {:ok, book, %{"approved" => [%{"id" => ^d, "effect" => "pure"}]}} =
      Dispatch.handle(book, "effect/approve", %{"ids" => [d]}, %{})

    node = Book.get(book, :nodes, d)
    assert node.effect_source == "user"
    assert node.effect_hash == node.body_hash
    assert Core.filter_by_effect(book, [row]) == [row]
  end

  test "moving a function (other lines above it) keeps its approval", %{book: book, dir: dir, double: d} do
    {:ok, book, _} = Dispatch.handle(book, "effect/set", %{"id" => d, "effect" => "pure"}, %{})
    File.write!(Path.join(dir, "lib/a.ex"), String.replace(@source, "defmodule ApprA do\n", "defmodule ApprA do\n  @moduledoc false\n\n"))
    book = rescan(book, dir)
    assert Book.get(book, :nodes, d).effect_source == "user"
  end

  test "an approval from before effect_hash was recorded is taken for the body found now", %{book: book, dir: dir, double: d} do
    node = Book.get(book, :nodes, d) |> Map.merge(%{effect: "pure", effect_source: "user"}) |> Map.delete(:effect_hash)
    book = Book.put(book, :nodes, d, node)

    book = rescan(book, dir)
    node = Book.get(book, :nodes, d)
    assert node.effect_source == "user"
    assert node.effect_hash == node.body_hash
  end

  test "a proposal is recorded with its reason and evaluates nothing; approving it trusts it", %{book: book, double: d} do
    {book, row} = add_row(book, d, %{"origin" => "agent"})
    assert Book.get(book, :calls, row).origin == "agent"

    {:ok, book, %{"effect_source" => "agent"}} =
      Dispatch.handle(book, "effect/propose", %{"id" => d, "effect" => "pure", "reason" => "arithmetic on\n its argument only"}, %{})

    node = Book.get(book, :nodes, d)
    assert {node.effect, node.effect_source, node.effect_reason} == {"pure", "agent", "arithmetic on its argument only"}
    assert Core.filter_by_effect(book, [row]) == []
    assert Core.exclusion_reason(book, row) =~ "proposed by an agent"

    {:ok, book, _} = Dispatch.handle(book, "effect/approve", %{"ids" => [d]}, %{})
    assert Core.filter_by_effect(book, [row]) == [row]
  end

  test "a proposal is refused over a person's class, without a reason, or for unknown", %{book: book, double: d} do
    assert {:error, _, %{"code" => "invalid_params"}} =
             Dispatch.handle(book, "effect/propose", %{"id" => d, "effect" => "pure", "reason" => "  "}, %{})

    assert {:error, _, %{"code" => "invalid_params"}} =
             Dispatch.handle(book, "effect/propose", %{"id" => d, "effect" => "unknown", "reason" => "x"}, %{})

    assert {:error, _, %{"code" => "not_found"}} =
             Dispatch.handle(book, "effect/propose", %{"id" => "nope", "effect" => "pure", "reason" => "x"}, %{})

    {:ok, book, _} = Dispatch.handle(book, "effect/set", %{"id" => d, "effect" => "reads"}, %{})

    assert {:error, _, %{"message" => m}} =
             Dispatch.handle(book, "effect/propose", %{"id" => d, "effect" => "pure", "reason" => "x"}, %{})

    assert m =~ "already classified by a person"
    assert Book.get(book, :nodes, d).effect == "reads"
  end

  test "effect/approve is all or none", %{book: book, double: d, triple: t} do
    {:ok, book, _} = Dispatch.handle(book, "effect/propose", %{"id" => d, "effect" => "pure", "reason" => "r"}, %{})

    # triple is unclassified: nothing to approve, so double stays a proposal too
    assert {:error, ^book, %{"message" => m}} = Dispatch.handle(book, "effect/approve", %{"ids" => [d, t]}, %{})
    assert m =~ t
    assert Book.get(book, :nodes, d).effect_source == "agent"

    assert {:error, _, _} = Dispatch.handle(book, "effect/approve", %{"ids" => []}, %{})
  end

  test "row/add's origin is manual by default and only manual or agent", %{book: book, double: d} do
    {book, row} = add_row(book, d)
    assert Book.get(book, :calls, row).origin == "manual"

    assert {:error, _, %{"code" => "invalid_params"}} =
             Dispatch.handle(book, "row/add", %{"node" => d, "args" => ["2"], "origin" => "robot"}, %{})
  end
end
