Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Scanner do
  @moduledoc """
  The scan-side counterpart of the REPL adapter (Old.md §21.3): turns one
  project file into `node` rows (the cards) and `link` rows (static calls
  between them). Which implementation reads a file is the language's
  choice -- the language its surface-table row names declares one in
  `Repl.Language.scanner/0`, and `Project.scan_dir/2` uses it.

  Implementations: `Scanner.Elixir` (Elixir's own parser and compiler
  tracer -- spec §11.1's basic behavior). A language server-backed one
  (spec §11.1's main path) is planned (§21.4).

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
end
