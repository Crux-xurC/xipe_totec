Code.require_file("lib/id.exs", __DIR__)
Code.require_file("lib/book.exs", __DIR__)
Code.require_file("lib/store.exs", __DIR__)
Code.require_file("lib/identity.exs", __DIR__)
Code.require_file("lib/core.exs", __DIR__)
Code.require_file("lib/scanner.exs", __DIR__)
Code.require_file("lib/project.exs", __DIR__)
Code.require_file("lib/address.exs", __DIR__)
Code.require_file("lib/protocol.exs", __DIR__)
Code.require_file("lib/dispatch.exs", __DIR__)
Code.require_file("lib/serve_project.exs", __DIR__)
Code.require_file("lib/serve_socket.exs", __DIR__)

defmodule XipeTotec.CLI do
  @moduledoc false

  alias XipeTotec.{Book, Project, Store}
  alias XipeTotec.Serve.Project, as: ServeProject

  @store_file "book.jsonl"
  @default_serve_port 4200

  def main(args) do
    case args do
      [] -> help()
      ["help"] -> help()
      ["version"] -> IO.puts("xipe 0.1.0-dev")
      ["scan", dir] -> scan(dir)
      ["scan"] -> scan(".")
      ["show"] -> show()
      ["serve" | rest] -> serve(rest)
      [cmd | _] -> unknown(cmd)
    end
  end

  defp help do
    IO.puts("""
    xipe -- Xipe Totec CLI (scaffold; most of §15 is not implemented yet)

      xipe scan [<dir>]        scan every .ex file under <dir> (default: .), update ./#{@store_file}
      xipe show                print a summary of the current book (from ./#{@store_file})
      xipe serve [<dir>] [--port N]
                                §16.1 WebSocket (localhost) entry over <dir>'s ./#{@store_file}
                                (default port #{@default_serve_port}, or $XIPE_TOTEC_PORT)
      xipe version              show version
      xipe help                 show this message
    """)
  end

  defp scan(dir) do
    old_book = Store.load(@store_file)
    {new_book, paths} = Project.scan_dir(old_book, dir)
    Project.persist_scan(@store_file, old_book, new_book)

    IO.puts(
      "xipe: scanned #{length(paths)} file(s) under #{dir} -- " <>
        "#{map_size(new_book.sheets)} sheet(s), #{map_size(new_book.nodes)} node(s), " <>
        "#{map_size(new_book.links)} link(s)"
    )
  end

  defp show do
    book = Store.load(@store_file)

    for {id, row} <- book.sheets do
      IO.puts("sheet #{id}  #{row.path}")
    end

    for {id, row} <- book.nodes do
      IO.puts("node  #{id}  #{row.module}.#{row.name}/#{row.arity}  effect=#{row.effect}")
    end

    for {_id, row} <- book.links do
      IO.puts("link  #{row.node} --#{row.role}--> #{row.ref}")
    end

    if book == Book.new() do
      IO.puts("(empty -- run `xipe scan` first)")
    end
  end

  defp serve(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [port: :integer])
    root = Path.expand(List.first(positional) || ".")
    store_file = Path.join(root, @store_file)
    port = opts[:port] || String.to_integer(System.get_env("XIPE_TOTEC_PORT") || Integer.to_string(@default_serve_port))

    {:ok, _} = Application.ensure_all_started(:cowboy)
    {:ok, _} = ServeProject.start_link(%{root: root, store_file: store_file})

    dispatch = :cowboy_router.compile([{:_, [{"/", XipeTotec.Serve.Socket, []}]}])

    case :cowboy.start_clear(
           :xipe_totec_serve,
           %{socket_opts: [{:ip, {127, 0, 0, 1}}, {:port, port}]},
           %{env: %{dispatch: dispatch}}
         ) do
      {:ok, _} ->
        IO.puts("xipe serve: ws://127.0.0.1:#{port}/  root=#{root}  store=#{store_file}")
        Process.sleep(:infinity)

      {:error, :eaddrinuse} ->
        IO.puts(:stderr, "xipe serve: 127.0.0.1:#{port} は使用中です (--port か $XIPE_TOTEC_PORT で変更可)")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "xipe serve: リスナ起動に失敗: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp unknown(cmd) do
    IO.puts(:stderr, "xipe: unknown command #{inspect(cmd)}")
    System.halt(1)
  end
end

XipeTotec.CLI.main(System.argv())
