# Xipe Totec as an MCP server (planned)

How an AI agent is to use Xipe Totec through the Model Context Protocol (MCP), and what has been decided before any of it is built. Nothing here is implemented yet:
today the entrances are the CLI (`xipe …`) and the WebSocket of `xipe start` ([D-serve-project](verification/lib-serve_project.exs.md#d-serve-project)).
When a part is built, its decision moves to the record of its main file in `verification/` and gets a row in
[`decisions.md`](verification/decisions.md); this document then links there.

Decided 2026-11-21 (crux), from a review of the concerns (the list below).

## The concerns, as found

What makes an agent different from a person at the CLI or in tezcatl's window. Each is answered by a decision below, or left as a note.

**Safety and authority**

1. **Evaluation runs the target's code.** A calc row's arguments are source text of the REPL's language, and the function runs for real
   (P1). The only guard is [D-effect-classes](verification/lib-core.exs.md#d-effect-classes): a class is trusted only when a person set it.
   An agent able to call `effect/set` or pass `include_writes` would remove that guard → [D-mcp-effects](#d-mcp-effects)
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
   stdio on the same machine; a server over HTTP would need authentication → [D-mcp-bridge](#d-mcp-bridge) (stdio only)
5. **Prompt injection**: values, exception messages, build errors and source text come from the target project and reach the model as
   they are. Nothing of Xipe Totec can tell them apart; the client and the person keep this in mind (a note in the tools' descriptions)

**Fit with MCP**

6. **Transport**: Xipe Totec speaks its own JSON-RPC-like protocol over a WebSocket and broadcasts `notify/*` to every session; MCP is
   stdio (or Streamable HTTP) with tools and resources → [D-mcp-bridge](#d-mcp-bridge)
7. **Evaluation is asynchronous**: `eval` answers at once with a `pass_id`; the result comes later as `notify/passCompleted`. A tool call
   expects one answer within the client's time limit, while a REPL's start and build take seconds (Java, Scala, C#: often over ten)
   → [D-mcp-eval-wait](#d-mcp-eval-wait)
8. **The dialogue is for people**: its replies and `input` are human text (tezcatl never parses them either). The agent gets `Dispatch`'s
   structured methods, not the dialogue → [D-mcp-tools](#d-mcp-tools)
9. **31 methods** are too many tools for a model to choose among → [D-mcp-tools](#d-mcp-tools)
10. **Ids**: nodes and rows are ULIDs, carried from one call to the next → [D-mcp-tools](#d-mcp-tools) (functions named by address)
11. **The language arguments are written in**: C#'s in F#, Java's in Scala (the window's language). A model writes C# or Java by habit →
    said in `row/add`'s and `row/set-args`'s descriptions, with the node's language and window in `card/get`'s answer
12. **Output size**: `graph/export` and `card/list` give every node (tezcatl itself: 1664) → [D-mcp-tools](#d-mcp-tools) (not offered;
    search and neighbours instead, with a limit)

**State and concurrency**

13. **One server per project**: `xipe start` serves one project on one port; the chosen project is one per machine
    (`tables/selection.json`). A person in tezcatl and an agent on the same Book mix their edits → [D-mcp-shared-book](#d-mcp-shared-book)
14. **State fixed under `__DIR__`** (`tables/`, `session.json`); no environment variable moves it (the without-Nix build has
    `XIPE_TOTEC_HOME`, upstream does not). A note: the bridge uses whatever `xipe start` it is given
15. **One pass at a time, a new REPL per pass** ([D-one-pass-one-repl](verification/lib-repl-evaluator.exs.md#d-one-pass-one-repl)):
    an agent trying small changes waits for a start each time. Kept: it is what makes a row made again give the same value
16. **Unclassified rows are not evaluated**: a node's `effect` is `unknown` until set → [D-mcp-effects](#d-mcp-effects) (the agent
    proposes, a person approves)
17. **Cards follow the files on disk**: after the agent edits a file, a rescan is needed (`scan` is one of the tools)
18. **Standard output** must carry only MCP's messages over stdio; the CLI path prints → [D-mcp-bridge](#d-mcp-bridge) (the bridge owns
    stdout; Xipe Totec's output stays in its own process)
19. **Distribution**: upstream needs Nix; people without it get the without-Nix build, which has fallen behind more than once →
    [D-mcp-distribution](#d-mcp-distribution)

**Trust in what the agent writes**

20. **Expectations written by the agent**: `row/set-prev` (the value the next evaluation is compared with) and `row/set-result` (a
    result typed by hand) would let an agent make a wrong value the expectation and get `compare: same`. Catching regressions, the core
    of the tool, would break silently → [D-mcp-expectations](#d-mcp-expectations)
21. **A function changed after its class was approved**: the agent edits files (concern 17), so a function approved `pure` may later
    write. Today a rescan keeps a node's `effect` and `effect_source` whatever its body became: `Scanner.put_defs/3` carries them over
    for the same `(module, name, anykey)` and does not compare `body_hash` → [D-mcp-effects](#d-mcp-effects) (a changed body asks
    again)
22. **Approval without looking**: a list of bare classes invites approving them all unread → [D-mcp-effects](#d-mcp-effects) (each
    proposal carries its reason)

<a id="d-mcp-effects"></a>

## D-mcp-effects — the agent proposes a class; a person approves it; `include_writes` is not offered

- An agent's classification is recorded with `effect_source: "agent"` (the column exists: `Core.put_node/3` defaults it to `nil`,
  `Core.set_effect/3`, behind `effect/set`, writes `"user"`). The evaluator goes on trusting `"user"` only (`Core.filter_by_effect/3`), so a proposed class evaluates nothing
- A person approves proposals in tezcatl or the CLI, many at once (the idea "`effect/set` for many at once" in
  [`scope.md`](scope.md) becomes needed): approving writes `effect_source: "user"`
- **Each proposal carries its reason**, recorded with it (one short line: "no file or network I/O, depends on its arguments only"); the
  approval view shows class, reason and the function's source together, so approving is a check, not a click
- **An approval holds for the body it was given for.** The approval records the node's `body_hash`; when a rescan finds another body,
  the class falls back to a proposal (`effect_source` no longer `"user"`) and the function is not evaluated until a person approves
  it again (P2: what is evaluated is what a person looked at). Today this is not so (concern 21): a needed change in
  `Scanner.put_defs/3`, for people's own classes as well as the agent's
- `include_writes` is not a parameter of any MCP tool: rows classified `writes` (or `unknown`) are never evaluated through MCP
- Needs a change in Xipe Totec: a way to write `effect_source: "agent"` with its reason (a parameter of `effect/set` the bridge always
  sets, or a method of its own), the approval, and the `body_hash` an approval was given for

**Why**: it keeps P1 and D-effect-classes as they are — a class is trusted because a person set it — while the agent takes over the
first, tedious classification of a project's functions. **Alternatives**: the agent calls `effect/set` (the guard is gone); no
classification by the agent (the person classifies every function before the agent can evaluate anything).

<a id="d-mcp-expectations"></a>

## D-mcp-expectations — the agent does not write expectations

- `row/set-prev` and `row/set-result` are not MCP tools. The rows' expectations come from evaluations (the latest result, D-compare-basis)
  or from a person (`prev_source` / `result_source` `"user"`, written by `Core.set_prev/3` and `Core.set_result/3`)
- If they are ever offered, the same way as classes: written with source `"agent"`, not used as the basis of `compare` until a person
  approves them

**Why**: a regression is caught because the expectation did not come from the code under change; an agent that edits the code and
also sets the expected value can make any change look `same`. **Alternatives**: offering them with a note in the description (the
guard left to the model).

<a id="d-mcp-bridge"></a>

## D-mcp-bridge — a separate stdio process, a client of `xipe start`

- The MCP server is its own process, started by the MCP client over stdio. It connects to a running `xipe start` over the WebSocket, as
  tezcatl's relay does, and turns MCP tool calls into `Dispatch` methods and `notify/*` into answers
- It owns standard output (MCP's messages only); Xipe Totec's own output stays in `xipe start`'s process (concern 18)
- stdio only: no HTTP transport, so no authentication to add (concern 4)
- Xipe Totec itself changes only where a decision here needs it (D-mcp-effects' proposal and approval, `origin` for rows)

**Why**: the server stays one, with its passes, queue and cancel; the bridge holds only MCP's shape. **Alternatives**: MCP inside
`xipe start` (its stdout and process are the CLI's; one more transport in the server); the bridge running Xipe Totec through the CLI
(no notifications, one process per call).

<a id="d-mcp-eval-wait"></a>

## D-mcp-eval-wait — two tools: start (waiting up to N seconds) and status

- **Start** takes the rows and a wait `N` (seconds, bounded by the client's time limit). The bridge starts the pass and waits for its
  `notify/passCompleted`: done within `N`, the results come back in the same answer; otherwise the `pass_id` (and `started` / `queued`)
- **Status** takes a `pass_id`: still running or queued, or the results
- Elixir's quick passes finish in one call; Java, Scala and C#'s long starts go through status

**Why**: one answer per call where the pass is quick, and no call held past the client's limit where it is not. **Alternatives**:
waiting with MCP's progress notifications (not every client shows or honours them; a long build still meets the limit); start and
status only (every pass, even a quick one, takes two calls).

<a id="d-mcp-shared-book"></a>

## D-mcp-shared-book — the agent and the person share one Book; rows tell whose they are

- The bridge connects to the same `xipe start` a person's tezcatl uses: the person watches the agent's rows appear and change in the
  table (the point of the tool, and of showing it)
- Rows the agent adds carry `origin: "agent"` (the column exists, `"manual"` by default in `Core.add_call/3`); the table can narrow by it
- Passes are already one at a time, so the two meet only in editing rows; no lock is added

**Why**: seeing an agent's work in the table is what the agent gets from Xipe Totec and the person from the agent. **Alternatives**: a
Book of the agent's own (a second project or server; the person does not see the work as it happens); locks on rows.

<a id="d-mcp-tools"></a>

## D-mcp-tools — about ten tools, functions named by address

| Tool | Method(s) |
|---|---|
| scan | `scan/run` (said to run code for Elixir and sbt, concern 2) |
| search functions | `card/search`, with a limit |
| a function's card | `card/get` (with its language and the language its arguments are written in) |
| a function's neighbours | `graph/neighbors` |
| add a row | `row/add` (`origin: "agent"`) |
| change a row's arguments | `row/set-args` |
| list rows | `row/list` |
| start an evaluation | `eval` ([D-mcp-eval-wait](#d-mcp-eval-wait)) |
| an evaluation's status and results | `eval/status` and the pass's results |
| propose a class, with its reason | [D-mcp-effects](#d-mcp-effects) |

- A function is named by its address (`Calc.add/2`, through `node/resolve`) as well as by id; rows by id (given back by `row/add`)
- Not offered: `effect/set`, `include_writes`, `row/set-prev`, `row/set-result` ([D-mcp-expectations](#d-mcp-expectations)), `graph/export`, `card/list` (sizes, concern 12), `config/set`, `row/remove`, `edit/apply`,
  `trace/*`, the dialogue
- Every tool has a JSON Schema for its input; the descriptions say what runs (concerns 1, 2, 5) and in which language arguments are
  written (concern 11)

**Why**: a model chooses well among few tools; an address is what it already knows from the source. **Alternatives**: one tool per
method (31); one generic "call a method" tool (no schema per method, the guard of D-mcp-effects left to the description).

<a id="d-mcp-distribution"></a>

## D-mcp-distribution — through the without-Nix build, with its upstream commit checked

- People without Nix get the MCP server from `xipe_totec_without_nix`
- Falling behind upstream has happened more than once (19 commits at 2026-11-21), so it is a matter of the procedure, not of one sync:
  the without-Nix repository records the upstream commit it was made from (`sync/UPSTREAM` does today), and before a release the
  difference is checked (a step in its release procedure, or CI comparing `sync/UPSTREAM` with upstream's `main`)

**Why**: one distribution for people without Nix, and a lag found before an announcement rather than after. **Alternatives**: a
separate MCP package (a third copy to keep in step).
