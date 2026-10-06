Code.require_file("session.exs", __DIR__)

defmodule XipeTotec.Passes do
  @moduledoc """
  The passes being evaluated right now, as files (2026-10-06, Old.md §51):
  what `eval/status` shows, and what keeps a row that is being evaluated
  from being changed under it.

  A pass's result is folded into the row it was evaluated for. If the row's
  args changed meanwhile, the value would be recorded against args it was
  never computed from (課題 X-3). Rather than detect that afterwards, the
  change is refused while the pass runs: `row/update`, `row/set-result` and
  `row/remove` on a row of a running pass answer `row_in_pass` (crux:
  close it by structure). The CLI writes book.jsonl itself, also while a
  server runs (課題 §2), so the record is a file both see, not the server's
  memory.

  One file per pass and language group (`Runner` runs each language's rows
  in its own REPL, side by side), `<project_dir>/passes/<pass_id>-<language>.json`,
  written by the process that runs that group and removed when it ends:

      {"pass_id", "language", "call_ids", "started_at", "os_pid", "os_started",
       "current": {"call_id", "phase", "since"} | null}

  `phase` is `"calling"` from the moment the call is sent, and
  `"classifying"` once the call has returned and its value is being judged
  (repr, compare) -- an adapter that says so (`XT_CALLED_<id>`, Elixir's
  `EvalTemplate`). A file whose process is gone (killed, crashed) is not a
  running pass: `running/1` drops it, so nothing is left locked.

  Without a `project_dir` (tests, a bare `Runner.run/4`) nothing is
  written and nothing is locked.
  """

  alias XipeTotec.Session

  @type handle :: Path.t() | nil

  @doc "Records a pass group as running; the handle for `progress/3` and `finish/1`."
  @spec start(Path.t() | nil, String.t(), String.t(), [String.t()]) :: handle()
  def start(nil, _pass_id, _language, _call_ids), do: nil

  def start(project_dir, pass_id, language, call_ids) do
    path = Path.join(dir(project_dir), "#{pass_id}-#{safe(language)}.json")

    record =
      Session.owner()
      |> Map.merge(%{
        "pass_id" => pass_id,
        "language" => language,
        "call_ids" => call_ids,
        "started_at" => now(),
        "current" => nil
      })

    write(path, record)
    path
  end

  @doc "The row the group is on now, and its phase (`\"calling\"` / `\"classifying\"`)."
  @spec progress(handle(), String.t(), String.t()) :: :ok
  def progress(nil, _call_id, _phase), do: :ok

  def progress(path, call_id, phase) do
    case read(path) do
      {:ok, record} -> write(path, Map.put(record, "current", %{"call_id" => call_id, "phase" => phase, "since" => now()}))
      :error -> :ok
    end
  end

  @doc "The group is over: its record goes."
  @spec finish(handle()) :: :ok
  def finish(nil), do: :ok

  def finish(path) do
    File.rm(path)
    :ok
  end

  @doc """
  Removes every record of `pass_id` (a server whose pass process died
  without `finish/1`: the OS process lives on, so the records would look
  alive).
  """
  @spec clear(Path.t() | nil, String.t()) :: :ok
  def clear(nil, _pass_id), do: :ok

  def clear(project_dir, pass_id) do
    project_dir |> dir() |> Path.join("#{pass_id}-*.json") |> Path.wildcard() |> Enum.each(&File.rm/1)
    :ok
  end

  @doc "The running pass groups, oldest first. Records whose process is gone are removed."
  @spec running(Path.t() | nil) :: [map()]
  def running(nil), do: []

  def running(project_dir) do
    project_dir
    |> dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read(path) do
        {:ok, record} ->
          if Session.same_process?(record) do
            [record]
          else
            File.rm(path)
            []
          end

        :error ->
          []
      end
    end)
    |> Enum.sort_by(& &1["started_at"])
  end

  @doc """
  `nil` when `call_id` may be changed, else the error to answer with: the
  row is in a running pass.
  """
  @spec refuse(Path.t() | nil, String.t()) :: map() | nil
  def refuse(project_dir, call_id) do
    case Enum.find(running(project_dir), &(call_id in (&1["call_ids"] || []))) do
      nil ->
        nil

      record ->
        %{
          "code" => "row_in_pass",
          "message" =>
            "row #{call_id} is being evaluated (pass #{record["pass_id"]}) -- change it after the pass ends (eval/status shows what is running)"
        }
    end
  end

  defp dir(project_dir), do: Path.join(project_dir, "passes")

  defp safe(language), do: String.replace(to_string(language), ~r/[^A-Za-z0-9_]/, "_")

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = record} <- JSON.decode(text) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  # a whole file or none: a reader never sees half a record
  defp write(path, record) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(record) <> "\n")
    File.rename!(tmp, path)
    :ok
  end
end
