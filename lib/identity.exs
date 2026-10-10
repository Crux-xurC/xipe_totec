Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Identity do
  @moduledoc """
  The rescan identity rule: an existing id is reused only on an *exact*
  natural-key match (a sheet's path; a node's module, name and anykey).
  A renamed or moved function, or one that was absent during a scan, gets a
  new id and its calc rows stay with the old one.
  """

  alias XipeTotec.Book

  @spec sheet_id(Book.t(), String.t()) :: String.t() | nil
  def sheet_id(book, path), do: Book.find_sheet_by_path(book, path)

  @spec node_id(Book.t(), String.t(), String.t(), non_neg_integer()) :: String.t() | nil
  def node_id(book, module, name, anykey), do: Book.find_node_by_natural_key(book, module, name, anykey)
end
