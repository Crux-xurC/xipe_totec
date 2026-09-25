defmodule XipeTotec.Lsp.Transport do
  @moduledoc """
  How `Scanner.Lsp` talks to a language server -- the scan-side counterpart
  of `Repl.Sender` (Old.md §21.4, 2026-09-25). `Scanner.Lsp` only builds
  JSON-RPC requests and reads their results; where the server lives is a
  transport's business:

    * `Lsp.Transport.Relay` -- tezcatl's `/lsp` WebSocket relay, which
      already runs the server, answers `initialize` from its cache and
      multiplexes it between the editor and any other consumer (spec §11's
      "利用者が構成した多重化プロキシ")
    * a stdio transport starting the server itself, for CLI use without
      tezcatl -- planned

  A connection is used from the process that opened it only (the caller
  receives the transport's messages), one request at a time.
  """

  @type conn :: term()

  @doc """
  Connect for `language`'s server on the project at `root`. `file` is an
  absolute path of one of the project's files of that language (the relay
  finds the project root from it). `config` is transport-specific.
  """
  @callback connect(root :: String.t(), language :: String.t(), file :: String.t(), config :: map()) ::
              {:ok, conn()} | {:error, String.t()}

  @doc "Send a request and wait for its result (`{:error, text}` for an LSP error response, a timeout or a lost connection)."
  @callback request(conn(), method :: String.t(), params :: map(), timeout()) :: {:ok, term()} | {:error, String.t()}

  @doc "Send a notification (no reply)."
  @callback notify(conn(), method :: String.t(), params :: map()) :: :ok

  @callback close(conn()) :: :ok
end
