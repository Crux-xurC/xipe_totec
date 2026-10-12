Code.require_file("methods.exs", __DIR__)

defmodule XipeTotec.Help do
  @moduledoc """
  What `help` prints: one line per
  command, `<command>: <what it does>  <how its arguments are written>`.
  The CLI (`xipe help`) and the dialogue window (`input` `help`,
  `XipeTotec.Input`) both print from here, so the two never drift apart.

  The line shape is for people first and for tezcatl's dictionary second:
  tezcatl never interprets it -- a person yanks the lines they want and the
  dictionary panel stores each as a word (everything before the first
  `:`) and its note (the rest). So a command name never contains `:`, and
  every line is one command -- no headings, no wrapped continuation lines.

  Two tables feed it: the CLI commands below (name, arguments, one-line
  summary, the longer text `help <command>` prints, and whether the
  dialogue window accepts it), then every implemented method from
  `XipeTotec.Methods` (its `args`/`summary`). The `"eval"` pseudo-method
  is left out of the list: the `eval` command above it covers it, and
  `do eval ...` still reaches it.

  `where` is `:cli` (everything) or `:window` (only what the dialogue
  window runs; the rest needs a terminal of its own -- it selects or
  starts projects, or rewrites xipe_totec's own files).
  """

  alias XipeTotec.Methods

  @type where :: :cli | :window

  @commands [
    %{
      name: "help",
      args: "[<command>]",
      summary: "list the commands (with <command>, describe it)",
      window: true,
      detail: """
      Every command below that takes an optional <dir> acts on the selected project
      (`xipe choice project`) -- or, while `xipe start` runs, on the project it serves --
      when <dir> is omitted; a given <dir> must already be registered. Each project's
      book lives in tables/project/<id>_<name>/book.jsonl.

      In tezcatl's dialogue window a line is what follows `xipe` in a terminal (a
      leading `xipe` is allowed), and a line starting with a method name is a
      `do` command list.
      """
    },
    %{name: "version", args: "", summary: "print the version", window: true, detail: nil},
    %{
      name: "choice project",
      args: "<path>",
      summary: "register a project (the first time) and select it",
      window: false,
      detail: """
      register <path> if new (generating its surface table) and make it the selected
      project (tables/selection.json)
      """
    },
    %{
      name: "table generate",
      args: "[<path>]",
      summary: "regenerate the file -> language/REPL/build tool table",
      window: false,
      detail: """
      regenerate <path>'s surface table (registering it if new) and save it to
      tables/project/<id>_<name>/table -- each language's build tool is detected here --
      and resolve its environment again (flake.nix)
      """
    },
    %{
      name: "scan",
      args: "[<dir>]",
      summary: "read the sources and update the cards and links",
      window: true,
      detail: "scan the project's source files and update its book (the window: no <dir>)\n"
    },
    %{
      name: "show",
      args: "[<dir>]",
      summary: "show the sheets, functions, links and calc rows",
      window: true,
      detail: "print the project's sheets, nodes, links and calc rows (with values) (the window: no <dir>)\n"
    },
    %{
      name: "eval",
      args: "[<dir>] [id...] [--mix] [--include-writes]",
      summary: "evaluate calc rows in the REPL (all of them without an id)",
      window: true,
      detail: """
      launch the project's REPL and (re)evaluate the given calc-row ids (default: every
      call in the book); persists results back and prints an outcome line per call.
      --mix launches via `iex -S mix` instead of the default scripts-mode (`iex`, loading
      every scanned .ex/.exs file via -r). --include-writes also schedules
      writes/unknown-effect rows (still requires each one's node to have an explicit
      `effect/set` first). The window takes ids and --include-writes only.
      """
    },
    %{
      name: "do",
      args: "[--dir <dir>] <method> [key=value...] [-- <method> [key=value...]]...",
      summary: "run methods in order (the methods are listed below)",
      window: true,
      detail: """
      run one or more methods (the method lines of `help`) or the "eval" pseudo-method
      (params include_writes=true opts in writes/unknown-effect rows), chained in one
      command list -- see XipeTotec.Runner's moduledoc. A later command can reference an
      earlier one's result with "$<index>.<path>" (a number indexes a list), or as a
      cell reference with "⟦$<index>.<path>⟧", e.g.:
        xipe do node/resolve module=Calc name=add arity=2 \\
             -- effect/set 'id=$0.id' effect=pure \\
             -- row/add 'node=$0.id' args=1,2 \\
             -- eval 'call_ids=[$2.id]' \\
             -- row/check on=error,changed
      row/check fails (exit 1) when a row is in one of its `on` states: error
      (default), changed, unevaluated.
      Values: [..] is always a list ([] empty, [10] one element, [1,2] two); any other
      value containing a comma is a list too (args=1,2); everything else stays a plain
      string. The window takes no --dir, and `do` may be left out; without `do` a
      step may also be the window's `scan` or `eval [id...] [--include-writes]`
      (`scan -- node/resolve ... -- eval ...`). With `do` the line is exactly the CLI's.
      """
    },
    %{
      name: "search",
      args: "[<turn>]",
      summary: "start a dialogue that narrows the tables down (-h for usage)",
      window: true,
      detail: """
      narrow things down over several turns (Dialogue.Search): -s the
      surface table, -e the eval_table (calc rows with their function and path).
        -s|-e <column> <value> [<out>]   rows whose <column> is <value>; their <out>
                                         (default id) values become the held list
        -s|-e <column> list <out>        the same for every value in the held list
        -s|-e view <column> [<col>...]   show the rows matching the held list
        get id [-n]                      keep the list's n-th value (from 1) as x
        quit dialogue                    end it
      Any other line runs as an ordinary command, a word x replaced by the kept id.
      Values: exact, ~<value> substring, - empty. A <turn> given here is the first one.
      """
    },
    %{
      name: "quit dialogue",
      args: "",
      summary: "end the held dialogue (search etc.)",
      window: true,
      detail: nil
    },
    %{
      name: "dialogue depends",
      args: "[<dir>] <call_id>",
      summary: "walk the upstream dependencies and decide in a dialogue where to supply a value and evaluate",
      window: true,
      detail: """
      interactive dependency-chain negotiation: walks <call_id>'s upstream ⟦id⟧
      chain deepest-first, asking at each step whether to hand-supply that step's value
      (skipping real evaluation for it and everything deeper) and run everything from
      there up through <call_id> for real. At a prompt, answer "y <literal>"
      (target-language source text) or "n"; declining every step does nothing.
      The window takes <call_id> only.
      """
    },
    %{
      name: "dialogue do",
      args: "<method> [key=value...]",
      summary: "put a method call together by being asked for what the line didn't give, then run it",
      window: true,
      detail: """
      asks for every required parameter of <method> that the line didn't give, one at a
      time, then runs the call. An answer is the whole line as it is -- no quotes
      removed, no commas read -- so a value the one-line form can't carry ([1,2,3] as one
      argument, "a b") is typed unchanged. A function is answered by its id or its name
      (Calc.add/2). A list: a line holding only { opens it, one element per line, a line
      holding only } closes it. A method that writes shows the call and waits for y/n.
      quit dialogue ends it without running anything.
      """
    },
    %{
      name: "dialogue rewrite",
      args: "[<table> [<row> [<column>]]]",
      summary: "change one value of a table by hand, without evaluating: asked for the table, the row, the column, the new value",
      window: true,
      detail: """
      asks, in turn, for whatever the line didn't give: the table (-e, as in search), the
      row (its id; the row is shown), the column, and the new value -- a line of its own,
      taken as it is. Only the columns roster lists as rewritable can be changed (args,
      result, prev, effect); each is written by its own method (row/set-args,
      row/set-result, row/set-prev, effect/set), shown before it runs, on y. Nothing is
      evaluated: evaluate afterwards with eval. effect belongs to the row's function, so
      every row of that function is affected. quit dialogue ends it without changing
      anything.
      """
    },
    %{
      name: "start",
      args: "[<dir>] [--port N] [--lsp <url>] [--fs-root <dir>]",
      summary: "stay up as the WebSocket entry (serve is an alias)",
      window: false,
      detail: """
      run the WebSocket (localhost) server over the project's book (default port
      4200, or $XIPE_TOTEC_PORT) and record it as the running session
      (tables/session.json): while it runs, every other command without a <dir> acts on
      its project instead of the selected one. An unregistered <dir> is registered (the
      selection is left alone). --lsp is tezcatl's /lsp relay URL and --fs-root the
      directory tezcatl's paths are relative to; both are optional
      ($XIPE_TOTEC_LSP_RELAY / $XIPE_TOTEC_LSP_FS_ROOT, else derived from the
      TEZCATL_RELAY_PORT / TEZCATL_FS_ROOT a tezcatl-spawned xipe inherits). tezcatl
      starts it without a <dir> -- on the selected project -- passing --port, --lsp and
      --fs-root. `xipe serve ...` is the same command.
      """
    },
    %{
      name: "config",
      args: "[<dir>] [key=value...]",
      summary: "show or change a project's settings",
      window: false,
      detail: """
      show or set the project's own settings (its project.json): env.path=prepend|replace
      (how the environment a flake.nix gives, resolved with nix print-dev-env, meets
      xipe's own PATH) and env.refresh=auto|manual (a changed flake is resolved again on
      the next scan/eval, or only on `xipe table generate`)
      """
    },
    %{
      name: "refresh",
      args: "-l|-r|-a",
      summary: "update xipe_totec's own info.json (languages, REPL adapters)",
      window: false,
      detail: """
      re-scan xipe_totec's own adapter modules and update ./info.json: -l (--languages)
      lib/repl/language/*.exs (names + extensions), -r (--repls)
      lib/repl/eval/scan/<transport>/*.exs, -a (--all) both. A file being present is not
      proof it works -- this only records what's there, run it after
      adding/removing an adapter module yourself.
      """
    }
  ]

  @doc "What `version` prints."
  @spec version() :: String.t()
  def version, do: "xipe 0.1.0-dev"

  @doc "The CLI command names the dialogue window runs (`XipeTotec.Input`)."
  @spec window_commands() :: [String.t()]
  def window_commands, do: for(%{window: true, name: name} <- @commands, do: name)

  @doc "The CLI command names that need a terminal (the window refuses them)."
  @spec cli_only_commands() :: [String.t()]
  def cli_only_commands, do: for(%{window: false, name: name} <- @commands, do: name)

  @doc "One line per command, `<command>: <summary>  <args>`."
  @spec lines(where()) :: [String.t()]
  def lines(where) do
    commands = for c <- @commands, where == :cli or c.window, do: line(c.name, c.summary, c.args)

    methods =
      for {name, spec} <- Enum.sort(Methods.all()),
          spec.route != :not_implemented,
          name != "eval",
          do: line(name, spec.summary, spec.args)

    commands ++ methods
  end

  @doc "`lines/1` as one text, newline-terminated."
  @spec text(where()) :: String.t()
  def text(where), do: Enum.map_join(lines(where), "", &(&1 <> "\n"))

  @doc """
  `help <name>`: the command's usage line and its longer text, or a
  method's params and summary. `:error` for a name neither table has (or,
  for `:window`, a command the window doesn't run).
  """
  @spec detail(String.t(), where()) :: {:ok, String.t()} | :error
  def detail(name, where) do
    case Enum.find(@commands, &(&1.name == name)) do
      %{window: false} when where == :window ->
        {:ok, "#{name} is a terminal command, run as xipe #{name} (not available in the dialogue window)\n"}

      %{} = c ->
        usage = String.trim_trailing("#{prefix(where)}#{c.name} #{c.args}")
        {:ok, "#{usage}\n#{c.summary}\n" <> (c.detail || "")}

      nil ->
        method_detail(name)
    end
  end

  defp method_detail(name) do
    case Methods.get(name) do
      %{route: :not_implemented} ->
        {:ok, "#{name}: not implemented\n"}

      %{} = spec ->
        kind = [if(spec.writes, do: "write", else: "read"), if(spec.repl, do: "REPL")] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
        {:ok, String.trim_trailing("#{name} #{spec.args}") <> "\n#{spec.summary}  (#{kind})\n"}

      nil ->
        :error
    end
  end

  defp prefix(:cli), do: "xipe "
  defp prefix(:window), do: ""

  defp line(name, summary, ""), do: "#{name}: #{summary}"
  defp line(name, summary, args), do: "#{name}: #{summary}  #{args}"
end
