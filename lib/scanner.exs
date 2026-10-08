Code.require_file("book.exs", __DIR__)
Code.require_file("id.exs", __DIR__)

defmodule XipeTotec.Scanner do
  @moduledoc """
  The scan-side counterpart of the REPL adapter (Old.md §21.3): turns one
  project file into `node` rows (the cards) and `link` rows (static calls
  between them). Which implementation reads a file is the language's
  choice -- the language its surface-table row names declares one in
  `Repl.Language.scanner/0`, and `Project.scan_dir/2` uses it.

  Implementations: `Scanner.Lsp.Elixir` (elixir-ls through tezcatl's `/lsp`
  relay -- spec §11.1's main path, `XipeTotec.Scanner.Lsp`) and
  `Scanner.Elixir` (Elixir's own parser and compiler tracer -- spec §11.1's
  basic behavior, the fallback when no language server is reachable).

  A language may declare several, in priority order (spec §11.3):
  `Project.scan_dir/3` calls each one's `begin/3` until one accepts, and
  records which one read the language's files, and why the ones before it
  didn't (§11.2). A scanner without `begin/3` always accepts.

  `put_defs/3` and `put_links/3` are the book-keeping every implementation
  shares: what a scanner itself contributes is only *which* definitions and
  calls a file has.

  Scanning is two passes over the whole project, so a call into a file not
  yet read still resolves: `scan_defs/3` over every file first, then
  `scan_links_report/3` over every file with every file's `node_ids`
  merged.
  """

  alias XipeTotec.Book

  @typedoc "One project file: `root` is the project directory, `path` is relative to it."
  @type file :: %{root: String.t(), path: String.t(), source: String.t()}

  @typedoc """
  `{module, name, anykey}` => node id, for the nodes a pass registered.
  `anykey` is the scanner's own tie-breaker between same-named functions in
  one module (the node row's `anykey` column): the arity for Elixir, where
  `add/2` and `add/3` are different functions; whatever suits another
  language, or `nil` where the name alone is unique. An integer `anykey` is
  also taken as the argument count (`row/add` checks it); any other value
  is not.
  """
  @type node_ids :: %{{String.t(), String.t(), non_neg_integer()} => String.t()}

  @typedoc "A module whose links couldn't be extracted, and why."
  @type failure :: %{module: String.t(), reason: String.t()}

  @doc """
  Pass 1: register `file`'s definitions as node rows on sheet `sheet_id`,
  reusing an existing node's id on a (module, name, anykey) match (spec
  §7.3), and drop the sheet's nodes that no longer appear.
  """
  @callback scan_defs(Book.t(), sheet_id :: String.t(), file()) :: {Book.t(), node_ids()}

  @doc """
  Pass 2: record link rows for `file`'s calls into any known node (`node_ids`,
  every file's pass-1 result merged, or one already in the book), drop this
  file's links that disappeared, and report what couldn't be looked at --
  a module in `failures` keeps the links it had.
  """
  @callback scan_links_report(Book.t(), node_ids(), file()) :: {Book.t(), [failure()]}

  @doc """
  Get ready to read `language`'s files under `root` (e.g. connect to a
  language server). `{:ok, ctx}` -- every `file` handed to the two passes
  then carries it as `file.ctx` -- or `{:error, reason}` to hand the
  language to the next scanner in line. `opts` are `Project.scan_dir/3`'s
  `:scanner_opts`, plus `:files` (the language's paths) and `:next` (the
  scanners declared after this one).
  """
  @callback begin(root :: String.t(), language :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, String.t()}

  @doc "Done with `ctx` (both passes over every file are over)."
  @callback finish(ctx :: term()) :: :ok

  @doc "How this scan was carried out, for the scan report (e.g. which way a language server was reached)."
  @callback describe(ctx :: term()) :: String.t()

  @doc """
  The files this scan didn't read itself after all, and why, as
  `[%{"path" => path, "reason" => text}]` -- e.g. `Scanner.Lsp` handing a
  file whose server-side text differs from the disk to the next scanner
  (`begin/3`'s `opts[:next]`).
  """
  @callback fallbacks(ctx :: term()) :: [%{String.t() => String.t()}]

  @optional_callbacks begin: 3, finish: 1, describe: 1, fallbacks: 1

  @typedoc """
  One definition as a scanner found it. `visibility` is `"public"` for a
  function the REPL can call from outside its module and `"private"` for
  one it can't (Elixir's `defp`): a private node still shows up in the
  reference list, but `row/add` won't make a calc row for it. Macros are
  not definitions here -- no scanner reports them.
  """
  @type definition :: %{
          module: String.t(),
          name: String.t(),
          anykey: term(),
          visibility: String.t(),
          span: non_neg_integer() | nil,
          body_hash: String.t() | nil
        }

  @doc """
  Register `defs` as the node rows of sheet `sheet_id`: an existing node
  with the same (module, name, anykey) keeps its id and its `effect`
  classification (spec §7.3's minimal rule), anything else gets a fresh id.
  A node that used to be on this sheet but isn't among `defs` any more
  (deleted, or renamed past what the minimal rule can follow) is removed,
  with every link touching it. Returns `{book, node_ids}` for this sheet.
  """
  @spec put_defs(Book.t(), String.t(), [definition()]) :: {Book.t(), node_ids()}
  def put_defs(book, sheet_id, defs) do
    {book, node_ids} =
      Enum.reduce(defs, {book, %{}}, fn def, {book, node_ids} ->
        id = Book.find_node_by_natural_key(book, def.module, def.name, def.anykey) || XipeTotec.Id.ulid()
        prior = Book.get(book, :nodes, id) || %{}

        row = %{
          sheet: sheet_id,
          module: def.module,
          name: def.name,
          anykey: def.anykey,
          visibility: Map.get(def, :visibility),
          span: def.span,
          body_hash: def.body_hash,
          status: "live",
          effect: prior[:effect] || "unknown",
          effect_source: prior[:effect_source],
          # what a person declared with arity/set (default arguments) stays, like effect
          arities: prior[:arities]
        }

        {Book.put(book, :nodes, id, row), Map.put(node_ids, {def.module, def.name, def.anykey}, id)}
      end)

    kept = MapSet.new(Map.values(node_ids))
    removed = for {id, row} <- book.nodes, row.sheet == sheet_id, not MapSet.member?(kept, id), into: MapSet.new(), do: id
    book = Enum.reduce(removed, book, &Book.delete(&2, :nodes, &1))

    book =
      Enum.reduce(book.links, book, fn {id, row}, book ->
        if MapSet.member?(removed, row.node) or MapSet.member?(removed, row.ref),
          do: Book.delete(book, :links, id),
          else: book
      end)

    {book, node_ids}
  end

  @doc """
  Record `links` (`%{node:, ref:}` caller/callee node id pairs, found in one
  file) and drop the links of `own_node_ids` -- the nodes whose calls were
  actually looked at in that file -- that weren't found again. A node left
  out of `own_node_ids` (its module couldn't be looked at) keeps its links.
  """
  @spec put_links(Book.t(), [%{node: String.t(), ref: String.t()}], [String.t()]) :: Book.t()
  def put_links(book, links, own_node_ids) do
    fresh =
      Map.new(links, fn link ->
        row = %{node: link.node, role: "to", ref: link.ref, clause: nil, guard: nil}
        {Book.link_id(row.node, row.role, row.ref, row.clause), row}
      end)

    book = Enum.reduce(fresh, book, fn {id, row}, book -> Book.put(book, :links, id, row) end)
    own = MapSet.new(own_node_ids)

    stale = for {id, row} <- book.links, MapSet.member?(own, row.node), not Map.has_key?(fresh, id), do: id
    Enum.reduce(stale, book, &Book.delete(&2, :links, &1))
  end

  @doc """
  The node id for `{module, name, anykey}`: this pass's `node_ids` first,
  then the book -- and for an integer anykey (an arity), a node of that
  module and name whose declared `arities` (`arity/set`) include it: a call
  `scale(x)` to `def scale(x, k \\\\ 2)` is `scale/1` (crux 2026-10-08).
  """
  @spec node_for(Book.t(), node_ids(), {String.t(), String.t(), term()}) :: String.t() | nil
  def node_for(book, node_ids, {module, name, anykey} = key) do
    Map.get(node_ids, key) || Book.find_node_by_natural_key(book, module, name, anykey) ||
      by_declared_arity(book, module, name, anykey)
  end

  defp by_declared_arity(book, module, name, arity) when is_integer(arity) do
    Enum.find_value(book.nodes, fn {id, row} ->
      if row.module == module and row.name == name and is_list(row[:arities]) and arity in row[:arities], do: id
    end)
  end

  defp by_declared_arity(_book, _module, _name, _arity), do: nil

  @doc """
  A call that matched no node, but whose module and name have one with
  another arity -- most likely a function with default arguments called
  without them, before its arities were declared (`arity/set`). -> a note
  for scan/run's `arity_misses` | nil. Calls to other projects' modules,
  and to names with no node at all, are not ours to report.
  """
  @spec arity_miss(Book.t(), {String.t(), String.t(), term()}, String.t() | nil) :: map() | nil
  def arity_miss(book, {module, name, arity}, caller_module) when is_integer(arity) do
    Enum.find_value(book.nodes, fn {id, row} ->
      if row.module == module and row.name == name and is_integer(row.anykey) and row.anykey != arity,
        do: %{module: caller_module, node: id, label: "#{module}.#{name}", called: arity, anykey: row.anykey}
    end)
  end

  def arity_miss(_book, _key, _caller_module), do: nil
end
