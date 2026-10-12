defmodule XipeTotec.LogBuffer do
  @moduledoc """
  What xipe_totec said lately, as a file: `tables/logging_buffer.txt`, one
  file for every project and for the CLI and the server alike. Each line a
  command printed is added at the end; past #{100} lines the oldest go.

  It is how a dialogue can point back at something that was said without
  the server having to remember it -- a CLI call is a process of its own,
  so the only memory both share is what was written down. `recent_files/2`
  reads it for the files lines named: a line names a file by putting its
  path last inside parentheses, as the limits line of a pass does --

      eval: limit 5s per row (eval.timeout, /…/tables/project/001_calc/project.json)

  Only a path (with a `/`) ending in `.json` counts, so other parenthesized
  remarks are not taken for files. `dialogue update` offers the latest five
  distinct ones, numbered.

  Writing is best effort: a line lost to two writers at once, or a file
  that can't be written, never fails the command that spoke. With `nil` for
  the file (tests, a bare `Runner`) nothing is written or read.
  """

  @max_lines 100
  @default_file Path.expand("../tables/logging_buffer.txt", __DIR__)

  @doc "xipe_totec's own buffer."
  @spec default_file() :: Path.t()
  def default_file, do: @default_file

  @doc "Adds `text`'s lines (or the given lines) at the end, dropping the oldest past #{@max_lines}."
  @spec append(Path.t() | nil, String.t() | [String.t()] | nil) :: :ok
  def append(nil, _text), do: :ok
  def append(_file, nil), do: :ok
  def append(file, text) when is_binary(text), do: append(file, String.split(text, "\n"))

  def append(file, lines) when is_list(lines) do
    case Enum.reject(lines, &(String.trim(&1) == "")) do
      [] ->
        :ok

      new ->
        try do
          kept = Enum.take(lines(file) ++ new, -@max_lines)
          File.mkdir_p!(Path.dirname(file))
          tmp = file <> ".tmp-#{System.unique_integer([:positive])}"
          File.write!(tmp, Enum.map_join(kept, "", &(&1 <> "\n")))
          File.rename!(tmp, file)
          :ok
        rescue
          _ -> :ok
        end
    end
  end

  @doc "The buffer's lines, oldest first."
  @spec lines(Path.t() | nil) :: [String.t()]
  def lines(nil), do: []

  def lines(file) do
    case File.read(file) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, _} -> []
    end
  end

  @doc "The files the lines named (see moduledoc), latest first, each once, at most `n`."
  @spec recent_files(Path.t() | nil, pos_integer()) :: [Path.t()]
  def recent_files(file, n \\ 5) do
    file
    |> lines()
    |> Enum.reverse()
    |> Enum.flat_map(&(&1 |> files_in() |> Enum.reverse()))
    |> Enum.uniq()
    |> Enum.take(n)
  end

  # the last thing in each (...) of the line, when it is a path to a .json
  defp files_in(line) do
    for [_, inside] <- Regex.scan(~r/\(([^()]*)\)/, line),
        word = inside |> String.split(", ") |> List.last() |> String.trim(),
        String.contains?(word, "/") and String.ends_with?(word, ".json"),
        do: word
  end
end
