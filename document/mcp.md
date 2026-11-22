# Xipe Totec as an MCP server

How an AI agent uses Xipe Totec through the Model Context Protocol (MCP): `xipe mcp`, a server over stdio that an MCP client starts, and
that passes its tools to the running `xipe start` ([D-serve-project](verification/lib-serve_project.exs.md#d-serve-project)). This
document keeps the concerns that shaped it and how it is distributed; the decisions in force are in the record of
[`lib/mcp/server.exs`](verification/lib-mcp-server.exs.md) and in [D-effect-approval](verification/lib-core.exs.md#d-effect-approval).

Decided 2026-11-21 (crux), from a review of the concerns (the list below); built the same day, the distribution without Nix
([D-mcp-distribution](#d-mcp-distribution)) included.

## Using it

1. Start Xipe Totec on the project as usual (`xipe start <dir>`, or tezcatl's xipe window). The agent works in the same Book: its rows
   appear in the person's table, marked `origin` `agent`
2. Register `xipe mcp` with the MCP client as a stdio server. For Claude Code, in the project's `.mcp.json`:

   ```json
   { "mcpServers": { "xipe-totec": { "command": "elixir", "args": ["<xipe_totec>/main.exs", "mcp"] } } }
   ```

   `elixir` as Xipe Totec's devShell gives it (it needs `gun` on `ERL_LIBS`): start the client inside `nix develop <xipe_totec>`, or
   `"command": "nix"`, `"args": ["develop", "<xipe_totec>", "-c", "elixir", "<xipe_totec>/main.exs", "mcp"]` (the devShell's banner
   goes to standard error, so it does not disturb MCP). `--port N` names the
   server's port; without it, the running session's (`tables/session.json`)
3. The agent proposes classes with reasons (`propose_class`); a person reads them (`effect_source` `agent`, `effect_reason` in the eval
   and card tables) and approves: `xipe do effect/approve 'ids=[<node>, …]'`, or in tezcatl `matrix get xipe_classes:all`, the rows
   selected and `matrix approve` (class, reason and source side by side; tezcatl's D-xipe-approval). Nothing the agent does evaluates a function a person has
   not classified, and a function whose body changed waits for a person again

The tools: `scan`, `search_functions`, `get_function`, `function_neighbors`, `add_row`, `set_row_args`, `list_rows`, `evaluate`,
`evaluation_status`, `propose_class`, `check_rows` ([D-mcp-tools](verification/lib-mcp-server.exs.md#d-mcp-tools)).

## The concerns, as found

What makes an agent different from a person at the CLI or in tezcatl's window. Each is answered by a decision below, or left as a note.

**Safety and authority**

1. **Evaluation runs the target's code.** A calc row's arguments are source text of the REPL's language, and the function runs for real
   (P1). The only guard is [D-effect-classes](verification/lib-core.exs.md#d-effect-classes): a class is trusted only when a person set it.
   An agent able to call `effect/set` or pass `include_writes` would remove that guard → [D-mcp-effects](verification/lib-mcp-server.exs.md#d-mcp-effects)
2. **Building and scanning run the target's code too.** Before a pass, the build (`mix compile`, `dotnet build`, `mvn`, `sbt`) runs the
   project's build definitions and plugins. Scanning is not "only reading" in every language:
   - **Elixir**: the scanner compiles each `defmodule` (`Code.compile_quoted/2`, `lib/scanner/elixir.exs`) to trace its links, and a
     module body runs at compile time (`@x File.read!(…)`, macros, `use`). elixir-ls, when used, compiles the project
   - **Scala**: an sbt project's scan starts sbt, which runs `build.sbt`
   - F#, Java, Go and PHP are read by their own parsers (`scan.fsx`, `scan.java`, `scan.go`, `scan.php`): nothing of the project runs.
     OCaml, Haskell, Python, JavaScript / TypeScript are read as text or through their language server

   An MCP tool's description must not call `scan` "read-only"
3. **Writes into the target project**: `obj/`, `target/`, `.scala-build/`, `_build/` …, as an IDE's build does
4. **No authentication** on the WebSocket (localhost, an Origin check only, `XIPE_TOTEC_ALLOWED_ORIGINS`). Harmless for an MCP server over
   stdio on the same machine; a server over HTTP would need authentication → [D-mcp-bridge](verification/lib-mcp-server.exs.md#d-mcp-bridge) (stdio only)
5. **Prompt injection**: values, exception messages, build errors and source text come from the target project and reach the model as
   they are. Nothing of Xipe Totec can tell them apart; the client and the person keep this in mind (a note in the tools' descriptions)

**Fit with MCP**

6. **Transport**: Xipe Totec speaks its own JSON-RPC-like protocol over a WebSocket and broadcasts `notify/*` to every session; MCP is
   stdio (or Streamable HTTP) with tools and resources → [D-mcp-bridge](verification/lib-mcp-server.exs.md#d-mcp-bridge)
7. **Evaluation is asynchronous**: `eval` answers at once with a `pass_id`; the result comes later as `notify/passCompleted`. A tool call
   expects one answer within the client's time limit, while a REPL's start and build take seconds (Java, Scala, C#: often over ten)
   → [D-mcp-eval-wait](verification/lib-mcp-server.exs.md#d-mcp-eval-wait)
8. **The dialogue is for people**: its replies and `input` are human text (tezcatl never parses them either). The agent gets `Dispatch`'s
   structured methods, not the dialogue → [D-mcp-tools](verification/lib-mcp-server.exs.md#d-mcp-tools)
9. **31 methods** are too many tools for a model to choose among → [D-mcp-tools](verification/lib-mcp-server.exs.md#d-mcp-tools)
10. **Ids**: nodes and rows are ULIDs, carried from one call to the next → [D-mcp-tools](verification/lib-mcp-server.exs.md#d-mcp-tools) (functions named by address)
11. **The language arguments are written in**: C#'s in F#, Java's in Scala (the window's language). A model writes C# or Java by habit →
    said in `row/add`'s and `row/set-args`'s descriptions, with the node's language and window in `card/get`'s answer
12. **Output size**: `graph/export` and `card/list` give every node (tezcatl itself: 1664) → [D-mcp-tools](verification/lib-mcp-server.exs.md#d-mcp-tools) (not offered;
    search and neighbours instead, with a limit)

**State and concurrency**

13. **One server per project**: `xipe start` serves one project on one port; the chosen project is one per machine
    (`tables/selection.json`). A person in tezcatl and an agent on the same Book mix their edits → [D-mcp-shared-book](verification/lib-mcp-server.exs.md#d-mcp-shared-book)
14. **State fixed under `__DIR__`** (`tables/`, `session.json`); no environment variable moves it (the without-Nix build has
    `XIPE_TOTEC_HOME`, upstream does not). A note: the bridge uses whatever `xipe start` it is given
15. **One pass at a time, a new REPL per pass** ([D-one-pass-one-repl](verification/lib-repl-evaluator.exs.md#d-one-pass-one-repl)):
    an agent trying small changes waits for a start each time. Kept: it is what makes a row made again give the same value
16. **Unclassified rows are not evaluated**: a node's `effect` is `unknown` until set → [D-mcp-effects](verification/lib-mcp-server.exs.md#d-mcp-effects) (the agent
    proposes, a person approves)
17. **Cards follow the files on disk**: after the agent edits a file, a rescan is needed (`scan` is one of the tools)
18. **Standard output** must carry only MCP's messages over stdio; the CLI path prints → [D-mcp-bridge](verification/lib-mcp-server.exs.md#d-mcp-bridge) (the bridge owns
    stdout; Xipe Totec's output stays in its own process)
19. **Distribution**: upstream needs Nix; people without it get the without-Nix build, which has fallen behind more than once →
    [D-mcp-distribution](#d-mcp-distribution)

**Trust in what the agent writes**

20. **Expectations written by the agent**: `row/set-prev` (the value the next evaluation is compared with) and `row/set-result` (a
    result typed by hand) would let an agent make a wrong value the expectation and get `compare: same`. Catching regressions, the core
    of the tool, would break silently → [D-mcp-expectations](verification/lib-mcp-server.exs.md#d-mcp-expectations)
21. **A function changed after its class was approved**: the agent edits files (concern 17), so a function approved `pure` may later
    write. Today a rescan keeps a node's `effect` and `effect_source` whatever its body became: `Scanner.put_defs/3` carries them over
    for the same `(module, name, anykey)` and does not compare `body_hash` → [D-mcp-effects](verification/lib-mcp-server.exs.md#d-mcp-effects) (a changed body asks
    again; **built** 2026-11-21, [D-effect-approval](verification/lib-core.exs.md#d-effect-approval))
22. **Approval without looking**: a list of bare classes invites approving them all unread → [D-mcp-effects](verification/lib-mcp-server.exs.md#d-mcp-effects) (each
    proposal carries its reason)

## Found in use (rehearsal, 2026-11-22)

A rehearsal of the demo by crux (tezcatlipoca 0.2.0, Claude Code, a Python project: two functions evaluated from the deepest up, 4
rows and 19 boundary rows). What the agent ran into, and where each went. The tools' descriptions (`lib/mcp/tools.exs`) were
amended the same day for every point that a sentence settles; the rest are in [`scope.md`](scope.md).

23. **Searching before a scan answers 0 silently**: `search_functions` on a project with no cards gives `total: 0`, as a search
    that matched nothing does → a project without functions answers "not scanned yet -- call scan first" wherever a function is
    searched or named (built the same day)
24. **Fewer operations than the CLI**: no `row/remove`, `row/set-prev`, `row/set-result`. The agent cannot clear its own rows, nor
    build a regression check with expectations → the expectations stay out ([D-mcp-expectations](verification/lib-mcp-server.exs.md#d-mcp-expectations));
    `row/check` was not passed though it only reads: now `check_rows` (built the same day), the regression check without
    expectations written by the agent. Removing rows stays a person's, in an editor of rows (crux: withdrawn as an MCP tool, in
    [`scope.md`](scope.md)); `add_row` says so
25. **`get_function` gives no source text**: the shared note said "source text in the answer", and none is in it; the agent read the
    file with `sed` to judge the class → the description says it gives the place (path, line), not the text. Giving the body (what
    the approving person sees) is an idea in [`scope.md`](scope.md): the server holds a function's first line, not its end
26. **The Book moved away under a running server**: `book.jsonl` moved while `xipe start` ran; the server kept its rows and classes
    in memory and `list_rows` went on answering them. The person restarted the server → outside the scope, a row in
    [`scope.md`](scope.md) (what happens, and that restarting is the way); noticing it is an idea there
27. **No way to wait for an approval**: after `propose_class`, `evaluate` answers `not_run`; nothing tells the agent when a person
    approves → `propose_class`' description tells the agent to end its turn and ask; a notification or a wait is an idea in
    [`scope.md`](scope.md)
28. **Wording**: an expected exception (`ValueError` on a boundary value) is `status: "crash"` in `evaluate` and `eval_error` in
    `list_rows` → `evaluate`'s description says what `crash` covers (the word is the evaluator's everywhere, the CLI's and
    tezcatl's too, so it is kept). `function_neighbors` gives static links only → its description says so







<a id="d-mcp-distribution"></a>

## D-mcp-distribution — through the without-Nix build, with its upstream commit checked

- People without Nix get the MCP server from `xipe_totec_without_nix` (`bin/xipe mcp`; in tezcatlipoca's tarball, `xipe_totec/bin/xipe
  mcp`). **Built** 2026-11-21: synced from this repository and tried with the release (scan, rows, a proposal, a person's approval
  with the CLI, an evaluation), standard output carrying MCP alone
- Falling behind upstream has happened more than once (22 commits at 2026-11-21), so it is a matter of the procedure, not of one sync:
  the without-Nix repository records the upstream commit it was made from (`sync/UPSTREAM`) and its tree (`sync/UPSTREAM_TREE`);
  tezcatlipoca's `build.sh` stops when a locked commit's tree is not upstream's published `main` (by tree: the published tezcatl is
  another history with the same trees), and the without-Nix repositories' CI says so on every push

**Why**: one distribution for people without Nix, and a lag found before an announcement rather than after. **Alternatives**: a
separate MCP package (a third copy to keep in step).
