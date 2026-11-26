ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/dispatch.exs", __DIR__))

defmodule MethodsTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Dispatch, Methods}

  @dispatch_source Path.expand("../lib/dispatch.exs", __DIR__)

  # the method names Dispatch.handle/4's clauses are written for
  defp dispatch_clause_names do
    source = File.read!(@dispatch_source)
    single = Regex.scan(~r/def handle\(book, "([^"]+)"/, source, capture: :all_but_first)
    listed = Regex.scan(~r/def handle\(book, method, [^)]*\) when method in \[([^\]]+)\]/, source, capture: :all_but_first)
    listed = Enum.flat_map(listed, fn [names] -> Regex.scan(~r/"([^"]+)"/, names, capture: :all_but_first) end)
    (single ++ listed) |> List.flatten() |> Enum.uniq() |> Enum.sort()
  end

  test "every :dispatch method is handled by Dispatch, not unknown_method or not_implemented" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_methods_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for name <- Methods.names([:dispatch]) do
      case Dispatch.handle(Book.new(), name, %{}, %{root: dir}) do
        {:error, _, %{"code" => code}} -> assert code not in ["unknown_method", "not_implemented"], name
        {:ok, _, _} -> :ok
      end
    end
  end

  test "every method Dispatch has a clause for is declared as :dispatch" do
    assert dispatch_clause_names() -- Methods.names([:dispatch]) == []
  end

  test ":pipeline and :not_implemented methods are Dispatch's not_implemented" do
    for name <- Methods.names([:pipeline, :not_implemented]) do
      assert {:error, _, %{"code" => "not_implemented"}} = Dispatch.handle(Book.new(), name, %{}, %{}), name
    end
  end

  test "read_only?/1 and repl?/1" do
    assert Methods.read_only?("card/get")
    assert Methods.read_only?("row/list")
    refute Methods.read_only?("row/add")
    refute Methods.read_only?("not/a/method")
    assert Methods.repl?("eval")
    assert Methods.repl?("eval/run")
    refute Methods.repl?("scan/run")
  end

  test "project/list: the registry beside this project's directory, the selected and the open one marked" do
    base = Path.join(System.tmp_dir!(), "xipe_totec_project_list_#{System.unique_integer([:positive])}")
    registry = Path.join(base, "project")
    on_exit(fn -> File.rm_rf!(base) end)
    a = XipeTotec.ProjectRegistry.register("/abs/calc", registry)
    b = XipeTotec.ProjectRegistry.register("/abs/shop", registry)
    File.write!(Path.join(base, "selection.json"), ~s({"project": "#{a}"}))

    {:ok, _, %{"projects" => ps}} = Dispatch.handle(Book.new(), "project/list", %{}, %{project_dir: Path.join(registry, "#{b}_shop")})
    assert [%{"id" => ^a, "name" => "calc", "path" => "/abs/calc", "selected" => true, "open" => false},
            %{"id" => ^b, "name" => "shop", "path" => "/abs/shop", "selected" => false, "open" => true}] = ps
  end

  test "method/list: every implemented method as declared, so a client can tell the ones that change nothing" do
    {:ok, _, %{"methods" => ms}} = Dispatch.handle(Book.new(), "method/list", %{}, %{})
    by = Map.new(ms, &{&1["name"], &1})
    assert %{"writes" => false, "confirm" => false, "repl" => false, "route" => "dispatch"} = by["card/list"]
    assert %{"writes" => true} = by["row/add"]
    assert %{"confirm" => true} = by["config/set"]
    assert %{"repl" => true} = by["eval"]
    refute Map.has_key?(by, "cell/complete")
  end
end
