Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Identity do
  @moduledoc """
  Minimal rescan identity rule (spec §7.3, Old.md §4.5, fix E): reuse
  an existing id only on an *exact* natural-key match. The fuller §7.3
  table (name-changed-but-body-same, body-changed-but-name-same,
  moved-file, needs_review) is out of scope for this build -- without even
  this minimal rule, every rescan would mint fresh ids for every function
  and every existing calc row would immediately become ref_error, which is
  why this can't wait for the fuller version.

  `XipeTotec.Scanner.scan_defs/3` already applies this rule inline via
  `Book.find_node_by_natural_key/4`; this module exists so the *policy* has
  one obvious, citable home, separate from the AST-walking mechanics.
  """

  alias XipeTotec.Book

  @spec sheet_id(Book.t(), String.t()) :: String.t() | nil
  def sheet_id(book, path), do: Book.find_sheet_by_path(book, path)

  @spec node_id(Book.t(), String.t(), String.t(), non_neg_integer()) :: String.t() | nil
  def node_id(book, module, name, arity), do: Book.find_node_by_natural_key(book, module, name, arity)
end
