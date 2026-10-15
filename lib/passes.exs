Code.require_file("session.exs", __DIR__)

defmodule XipeTotec.Passes do
  @moduledoc """
  The passes being evaluated right now, as files:
  what `eval/status` shows, and what keeps a row that is being evaluated
  from being changed under it.

  A pass's result is folded into the row it was evaluated for. If the row's
  args changed meanwhile, the value would be recorded against args it was
  never computed from. Rather than detect that afterwards, the
  change is refused while the pass runs: `row/update`, `row/set-result` and
  `row/remove` on a row of a running pass answer `row_in_pass`. The CLI writes book.jsonl itself, also while a
  server runs, so the record is a file both see, not the server's
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

  ## Stopping a pass

  `eval/cancel` asks a running pass to stop by leaving a file next to its
  records, `<project_dir>/passes/<pass_id>.cancel` (`request_cancel/2`). The
  process that runs the pass looks for it while it waits on its REPL
  (`cancel_requested?/2`, `Repl.Evaluator`'s `:cancelled?`), kills the REPL's
  process group -- what a hung session gets -- and ends the pass with
  `cancelled_error/0`, recording nothing. A file, like the records: the one
  asking may be another OS process (the CLI stopping a server's pass, or the
  other way round).

  Without a `project_dir` (tests, a bare `Runner.run/4`) nothing is
  written and nothing is locked.
  """

  alias XipeTotec.Session

  @type handle :: Path.t() | nil

  @doc "Records a pass group as running; the handle for `progress/3` and `finish/1`."
  # -> {:ok, handle} | {:error, message}: a group whose record cannot be
  # written does not run (the record is also what keeps its rows from being
  # changed while it runs -- row_in_pass)
  @spec start(Path.t() | nil, String.t(), String.t(), [String.t()]) :: {:ok, handle()} | {:error, String.t()}
  def start(nil, _pass_id, _language, _call_ids), do: {:ok, nil}

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

    case write(path, record) do
      :ok -> {:ok, path}
      {:error, _} = e -> e
    end
  end

  @doc "The row the group is on now, and its phase (`\"calling\"` / `\"classifying\"`)."
  @spec progress(handle(), String.t(), String.t()) :: :ok
  def progress(nil, _call_id, _phase), do: :ok

  def progress(path, call_id, phase) do
    case read(path) do
      # what it is doing now is shown on a best-effort basis: the record itself stays
      {:ok, record} -> with({:error, _} <- write(path, Map.put(record, "current", %{"call_id" => call_id, "phase" => phase, "since" => now()})), do: :ok)
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
    cancel_done(project_dir, pass_id)
  end

  @doc "Asks the pass `pass_id` to stop (see moduledoc). The pass ends itself, a moment later."
  @spec request_cancel(Path.t() | nil, String.t()) :: :ok | {:error, String.t()}
  def request_cancel(nil, _pass_id), do: :ok

  def request_cancel(project_dir, pass_id) do
    file = cancel_file(project_dir, pass_id)

    with :ok <- File.mkdir_p(dir(project_dir)),
         :ok <- File.write(file, "") do
      :ok
    else
      {:error, why} -> {:error, "#{file} could not be written: #{:file.format_error(why)} -- the pass was not asked to stop"}
    end
  end

  @doc "Whether `pass_id` was asked to stop."
  @spec cancel_requested?(Path.t() | nil, String.t()) :: boolean()
  def cancel_requested?(nil, _pass_id), do: false
  def cancel_requested?(project_dir, pass_id), do: File.exists?(cancel_file(project_dir, pass_id))

  @doc "The pass is over (stopped or not): a request to stop it goes."
  @spec cancel_done(Path.t() | nil, String.t()) :: :ok
  def cancel_done(nil, _pass_id), do: :ok

  def cancel_done(project_dir, pass_id) do
    File.rm(cancel_file(project_dir, pass_id))
    :ok
  end

  @doc "What a stopped pass (or a pass taken out of a server's queue) is answered with."
  @spec cancelled_error() :: map()
  def cancelled_error,
    do: %{"code" => "cancelled", "message" => "the pass was stopped (eval/cancel). Nothing was recorded -- evaluate again"}

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

  defp cancel_file(project_dir, pass_id), do: Path.join(dir(project_dir), "#{safe(pass_id)}.cancel")

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
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, JSON.encode!(record) <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, why} ->
        File.rm(tmp)
        {:error, "#{path} could not be written: #{:file.format_error(why)}"}
    end
  end
end
