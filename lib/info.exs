defmodule XipeTotec.Info do
  @moduledoc """
  `info.json` (xipe_totec's own root, Old.md §24): xipe_totec's
  bookkeeping about itself, not about any scanned target project's Book --
  which languages/REPLs it currently has adapter modules for (`languages`/
  `repls`), and which target project is currently selected (`project`,
  still unused until a future `xipe choice project` command writes it --
  §24's co-design deferred that command and its ID-assignment past this
  pass).

  Deliberately **not** CWD-relative like `book.jsonl` (`main.exs`'s
  `@store_file`) -- `book.jsonl`'s own convention (`Store.load/persist_diff`
  read/write wherever the process's CWD happens to be) only works today
  because the nix devShell's `xipe` wrapper always `cd`s to
  `$XIPE_TOTEC_DIR` first (`flake.nix`'s shellHook). `info.json` instead
  resolves its own path from `__DIR__` (this file's location under
  `lib/`), so it finds xipe_totec's own root the same way regardless of
  CWD -- this file's existence doesn't depend on that shellHook detail
  continuing to hold.

  `languages`/`repls` are refreshed by listing `lib/repl/eval/field_drip/`
  and `lib/repl/eval/scan/<transport>/` (`xipe reflesh`, `main.exs`), not
  auto-run on every CLI invocation -- a deliberate registration step
  (P4: "外部提供元は『提案』のみ、受け入れ検査を通ったものだけ採用"), same
  spirit as the file itself, not silent inference. A `.exs` file present
  under either directory is not proof it actually works (`document/
  repl-adapter-guide.md`'s own 4-candidate-language chapter is full of
  "要検証" caveats even once a file exists) -- `xipe reflesh` just records
  what's *present*; a crux confirming it live is what makes an entry
  trustworthy, same as every other "実機確認済み" note in Old.md.
  """

  @default_path Path.expand("../info.json", __DIR__)
  @field_drip_dir Path.expand("repl/eval/field_drip", __DIR__)
  @scan_dir Path.expand("repl/eval/scan", __DIR__)

  @type t :: %{String.t() => term()}

  @doc """
  Loads `path` (default: xipe_totec's own `info.json`) into a plain
  string-keyed map. A missing file is not an error -- returns the same
  empty scaffold `xipe reflesh` would start filling in
  (`%{"languages" => [], "repls" => [], "project" => nil}`), so a fresh
  checkout works before anyone has ever run `xipe reflesh`.
  """
  @spec load(Path.t()) :: t()
  def load(path \\ @default_path) do
    case File.read(path) do
      {:ok, content} -> JSON.decode!(content)
      {:error, :enoent} -> %{"languages" => [], "repls" => [], "project" => nil}
    end
  end

  @doc "Writes `info` (a plain string-keyed map, JSON-safe values only, same B2 rule `Repl.Launch` follows) to `path` (default: xipe_totec's own `info.json`)."
  @spec save(t(), Path.t()) :: :ok
  def save(info, path \\ @default_path) when is_map(info) do
    File.write!(path, JSON.encode!(info) <> "\n")
  end

  @doc """
  Re-lists `lib/repl/eval/field_drip/*.exs` and sets `info["languages"]`
  to the sorted basenames (today: `["elixir"]`). Does not touch `repls`
  or `project`.
  """
  @spec refresh_languages(t()) :: t()
  def refresh_languages(info) when is_map(info), do: Map.put(info, "languages", list_languages())

  @doc """
  Re-lists `lib/repl/eval/scan/<transport>/*.exs` (the two-axis layout
  `document/repl-adapter-guide.md` documents) and sets `info["repls"]` to
  `[%{"transport" => ..., "repl" => ...}, ...]`, sorted (today: a single
  `%{"transport" => "direct", "repl" => "iex"}`). Does not touch
  `languages` or `project`.
  """
  @spec refresh_repls(t()) :: t()
  def refresh_repls(info) when is_map(info), do: Map.put(info, "repls", list_repls())

  defp list_languages do
    @field_drip_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.map(&Path.basename(&1, ".exs"))
    |> Enum.sort()
  end

  defp list_repls do
    @scan_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@scan_dir, &1)))
    |> Enum.flat_map(fn transport ->
      @scan_dir
      |> Path.join(transport)
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.map(&%{"transport" => transport, "repl" => Path.basename(&1, ".exs")})
    end)
    |> Enum.sort_by(&{&1["transport"], &1["repl"]})
  end
end
