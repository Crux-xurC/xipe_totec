defmodule XipeTotec.Session do
  @moduledoc """
  The record a running `xipe start` leaves behind (2026-09-25), so every
  other command can tell a session is up and act in its context instead of
  on the project `xipe choice project` selected: which project it serves,
  on which port, and -- when it was started by tezcatl -- where tezcatl's
  `/lsp` relay is and which directory tezcatl's paths are relative to.

  One file, `tables/session.json` (machine-local, git-ignored like the rest
  of `tables/`). `xipe start` writes it once it is listening and removes it
  on a normal shutdown. A record whose process is gone (killed, crashed,
  Ctrl-C) is not a session: `read/1` treats it as absent, so a stale file
  never has to be cleaned up by hand. "Gone" is judged by the process's
  start time (`os_started`, from `ps`), not just by whether the pid exists:
  after a reboot or a long while the pid may belong to some other program,
  which would otherwise pass for the session (2026-10-06).

  Record keys (JSON, string keys): `os_pid`, `os_started` (the process's
  start time as `ps -o lstart=` prints it, or `nil` without `ps`), `port`,
  `project` (registry id), `root` (project path), `lsp` (tezcatl's `/lsp`
  WebSocket URL, or `nil`), `fs_root` (tezcatl's file root, or `nil`),
  `started_at`.
  """

  @default_path Path.expand("../tables/session.json", __DIR__)

  @type record :: %{String.t() => term()}

  @spec default_path() :: Path.t()
  def default_path, do: @default_path

  @doc "The live session's record, or `:none` (no file, unreadable, or its process is gone)."
  @spec read(Path.t()) :: {:ok, record()} | :none
  def read(path \\ @default_path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"os_pid" => _} = record} <- JSON.decode(text),
         true <- same_process?(record) do
      {:ok, record}
    else
      _ -> :none
    end
  end

  @doc "Write `record` as this OS process's session (`os_pid` and `started_at` are filled in)."
  @spec write(record(), Path.t()) :: :ok
  def write(record, path \\ @default_path) do
    record =
      Map.merge(record, %{
        "os_pid" => System.pid(),
        "os_started" => started(System.pid()),
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(record) <> "\n")
  end

  @doc "Remove the record -- only if it is this OS process's own (never another session's)."
  @spec clear(Path.t()) :: :ok
  def clear(path \\ @default_path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"os_pid" => pid}} <- JSON.decode(text),
         true <- pid == System.pid() do
      File.rm(path)
    end

    :ok
  end

  # the recorded process is still the one running under that pid: the same
  # start time. A record written before os_started existed falls back to
  # "the pid exists".
  defp same_process?(%{"os_pid" => pid, "os_started" => started}) when is_binary(started),
    do: started(pid) == started

  defp same_process?(%{"os_pid" => pid}), do: alive?(pid)

  # when `pid` started, as ps prints it (C locale, so the text does not
  # depend on the environment), or nil (no such process, no ps)
  defp started(pid) when is_binary(pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", pid], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {out, 0} -> if String.trim(out) == "", do: nil, else: String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp started(_pid), do: nil

  # `kill -0` delivers nothing; it only asks whether the pid exists and may
  # be signalled.
  defp alive?(pid) when is_binary(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  defp alive?(_pid), do: false
end
