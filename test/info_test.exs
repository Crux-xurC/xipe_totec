ExUnit.start()

Code.require_file(Path.expand("../lib/info.exs", __DIR__))

defmodule InfoTest do
  use ExUnit.Case

  alias XipeTotec.Info

  setup do
    path = Path.join(System.tmp_dir!(), "xipe_totec_info_test_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "load/1 on a missing file returns the empty scaffold", %{path: path} do
    assert Info.load(path) == %{"languages" => [], "repls" => [], "project" => nil}
  end

  test "save/2 then load/1 round-trips", %{path: path} do
    info = %{"languages" => ["elixir"], "repls" => [], "project" => nil}
    Info.save(info, path)
    assert Info.load(path) == info
  end

  test "refresh_languages/1 lists lib/repl/eval/field_drip/*.exs basenames, leaving other keys untouched" do
    info = %{"languages" => [], "repls" => ["placeholder"], "project" => nil}
    refreshed = Info.refresh_languages(info)

    assert refreshed["languages"] == ["elixir"]
    assert refreshed["repls"] == ["placeholder"]
  end

  test "refresh_repls/1 lists lib/repl/eval/scan/<transport>/*.exs as transport+repl pairs, leaving other keys untouched" do
    info = %{"languages" => ["placeholder"], "repls" => [], "project" => nil}
    refreshed = Info.refresh_repls(info)

    assert refreshed["repls"] == [%{"transport" => "direct", "repl" => "iex"}]
    assert refreshed["languages"] == ["placeholder"]
  end
end
