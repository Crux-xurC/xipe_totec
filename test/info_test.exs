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
    assert Info.load(path) == %{"languages" => [], "extensions" => %{}, "repls" => [], "project" => nil}
  end

  test "save/2 then load/1 round-trips", %{path: path} do
    info = %{"languages" => ["elixir"], "repls" => [], "project" => nil}
    Info.save(info, path)
    assert Info.load(path) == info
  end

  test "refresh_languages/1 records lib/repl/language/*.exs names and their extensions, leaving other keys untouched" do
    info = %{"languages" => [], "repls" => ["placeholder"], "project" => nil}
    refreshed = Info.refresh_languages(info)

    assert refreshed["languages"] == ["elixir"]
    assert refreshed["extensions"] == %{"ex" => ["elixir"], "exs" => ["elixir"]}
    assert refreshed["repls"] == ["placeholder"]
  end

  test "refresh_languages/2 keeps a clashing extension as a list of every declaring language (Old.md §34)" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_info_lang_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    suffix = System.unique_integer([:positive])
    File.write!(Path.join(dir, "c.exs"), "defmodule InfoTestLangC#{suffix} do\n  def extensions, do: [\"c\", \"h\"]\nend\n")
    File.write!(Path.join(dir, "cpp.exs"), "defmodule InfoTestLangCpp#{suffix} do\n  def extensions, do: [\"cpp\", \"h\"]\nend\n")

    refreshed = Info.refresh_languages(%{}, dir)

    assert refreshed["languages"] == ["c", "cpp"]
    assert refreshed["extensions"] == %{"c" => ["c"], "cpp" => ["cpp"], "h" => ["c", "cpp"]}
  end

  test "refresh_repls/1 lists lib/repl/eval/scan/<transport>/*.exs as transport+repl pairs, leaving other keys untouched" do
    info = %{"languages" => ["placeholder"], "repls" => [], "project" => nil}
    refreshed = Info.refresh_repls(info)

    assert refreshed["repls"] == [%{"transport" => "direct", "repl" => "iex"}]
    assert refreshed["languages"] == ["placeholder"]
  end
end
