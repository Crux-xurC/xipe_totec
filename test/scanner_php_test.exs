ExUnit.start()

Code.require_file(Path.expand("../lib/scanner/php.exs", __DIR__))

# Scanner.Php's name resolution (no PHP needed); the real parse is in test/live/scan_map_test.exs
defmodule ScannerPhpTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Scanner

  defp d(opts) do
    Map.merge(
      %{namespace: "App\\Geo", uses: %{"calc" => "App\\Calc", "util" => "App\\Util"}, functions: %{"twice" => "App\\Util\\twice"}, class: "App\\Geo\\Shapes", parent: "Base"},
      Map.new(opts)
    )
  end

  test "functions: use function, then the namespace, then the global one; qualified through use; fully qualified as written" do
    assert Scanner.Php.resolve("twice", d([])) == [{"app\\util", "twice"}, {"app\\geo", "twice"}, {"\\", "twice"}]
    assert Scanner.Php.resolve("strlen", d([])) == [{"app\\geo", "strlen"}, {"\\", "strlen"}]
    assert Scanner.Php.resolve("Util\\thrice", d([])) == [{"app\\util", "thrice"}]
    assert Scanner.Php.resolve("Sub\\f", d([])) == [{"app\\geo\\sub", "f"}]
    assert Scanner.Php.resolve("\\App\\Util\\thrice", d([])) == [{"app\\util", "thrice"}]
    # the global namespace
    assert Scanner.Php.resolve("helper", d(namespace: "", functions: %{})) == [{"\\", "helper"}, {"\\", "helper"}]
  end

  test "static calls: a class through use, the namespace or as written; self, static, parent; $this" do
    assert Scanner.Php.resolve("Calc::add", d([])) == [{"app\\calc", "add"}]
    assert Scanner.Php.resolve("Other::m", d([])) == [{"app\\geo\\other", "m"}]
    assert Scanner.Php.resolve("\\App\\Calc::add", d([])) == [{"app\\calc", "add"}]
    assert Scanner.Php.resolve("self::tag", d([])) == [{"app\\geo\\shapes", "tag"}, {"app\\geo\\base", "tag"}]
    assert Scanner.Php.resolve("static::tag", d(parent: nil)) == [{"app\\geo\\shapes", "tag"}]
    assert Scanner.Php.resolve("parent::unit", d(uses: %{"base" => "App\\Base"})) == [{"app\\base", "unit"}]
    assert Scanner.Php.resolve("$this->name", d(parent: nil)) == [{"app\\geo\\shapes", "name"}]
    # a function, not a method: no class
    assert Scanner.Php.resolve("$this->x", d(class: nil)) == []
  end

  test "vendor/ is read for nothing" do
    assert Scanner.Php.skipped?("vendor/acme/lib/Lib.php")
    refute Scanner.Php.skipped?("src/Calc.php")
    assert Scanner.Php.defs(%{path: "vendor/a.php", ctx: %{files: %{}, collisions: %{}}}) == []
  end
end
