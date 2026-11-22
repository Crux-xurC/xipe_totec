# `lib/mcp/server.exs`

`xipe mcp`: Xipe Totec as an MCP server over stdio for an AI agent. A client of the running `xipe start` through
`lib/mcp/upstream.exs` (a WebSocket, as tezcatl's relay is), with about ten tools in `lib/mcp/tools.exs`. The concerns these decisions
answer, and how it reaches people without Nix (D-mcp-distribution), are in [`../mcp.md`](../mcp.md).

**Decisions homed here**: [D-mcp-bridge](#d-mcp-bridge), [D-mcp-eval-wait](#d-mcp-eval-wait), [D-mcp-tools](#d-mcp-tools),
[D-mcp-effects](#d-mcp-effects), [D-mcp-expectations](#d-mcp-expectations), [D-mcp-shared-book](#d-mcp-shared-book)
**Takes part in**: D-effect-approval ([`lib/core.exs`](lib-core.exs.md)), D-session-record ([`lib/session.exs`](lib-session.exs.md)),
D-method-criteria ([`lib/methods.exs`](lib-methods.exs.md))

**Files**: `lib/mcp/server.exs` (MCP's messages, stdout, tasks), `lib/mcp/upstream.exs` (the connection, `initialize`, completed passes),
`lib/mcp/tools.exs` (the tools and their schemas; pure but for the functions given), `main.exs` (`mcp`), `lib/help.exs`; tests
`test/mcp_test.exs` (tools over a fake server, the messages). Tried by hand 2026-11-21 against a real `xipe start` on a copy (the
agent's row, its proposal refused to evaluate, a person's approval, the value; a proposal over a person's class refused, during a
scan as well), and on a Scala (sbt) project: 26 functions scanned, an overloaded name refused with its candidates, rows with a
reference, a case class literal (`sample.Point(0, 0)`: the window's own literal, as `get_function` says), an exception and a timeout;
a pass outlasting the wait followed with `evaluation_status` from `starting` to its results; the body of an approved function
edited, rescanned, `changed`, not evaluated.

<a id="d-mcp-bridge"></a>

## D-mcp-bridge — a separate stdio process, a client of `xipe start`

**Decided** 2026-11-21 (crux); **built** 2026-11-21: `xipe mcp` (`lib/mcp/server.exs`, `lib/mcp/upstream.exs`). The server is found by
`--port` or the live session (`tables/session.json`) when a call needs it, so `xipe start` may come later; each connection sends
`initialize` first, as every client of `Serve.Socket` does. Standard output is taken once for MCP; every other process and the logger
write to standard error. Tool calls run in tasks of their own (a long `evaluate` does not hold `ping`); input ending waits for them.

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

**Decided** 2026-11-21 (crux); **built** 2026-11-21: `evaluate` (`wait_seconds`, 0–55, 20 by default) and `evaluation_status`. The
bridge keeps the last 200 `notify/passCompleted` by `pass_id`; a pass that ended before it connected is said to be unknown, with
`list_rows` to read the values. A pass not ended is looked up in `eval/status`, which names the server's pass from its start
(`"phase": "starting"` while its environment, build and REPL start come first; D-passes).

- **Start** takes the rows and a wait `N` (seconds, bounded by the client's time limit). The bridge starts the pass and waits for its
  `notify/passCompleted`: done within `N`, the results come back in the same answer; otherwise the `pass_id` (and `started` / `queued`)
- **Status** takes a `pass_id`: still running or queued, or the results
- Elixir's quick passes finish in one call; Java, Scala and C#'s long starts go through status

**Why**: one answer per call where the pass is quick, and no call held past the client's limit where it is not. **Alternatives**:
waiting with MCP's progress notifications (not every client shows or honours them; a long build still meets the limit); start and
status only (every pass, even a quick one, takes two calls).

<a id="d-mcp-tools"></a>

## D-mcp-tools — about ten tools, functions named by address

**Decided** 2026-11-21 (crux); **built** 2026-11-21 (`lib/mcp/tools.exs`): `scan`, `search_functions`, `get_function`,
`function_neighbors`, `add_row`, `set_row_args`, `list_rows`, `check_rows` (2026-11-22), `evaluate`, `evaluation_status`, `propose_class`. A function is named by
its id, its label exactly as `card/list` gives it (every language's form: `Calc.add/2`, `N.T.M(int, int)`), or `Module.name` when only
one function has it. `search_functions` and `list_rows`' `function` narrow `card/list` / `row/list` in the bridge (narrowing is the
receiver's, D-method-criteria), since `card/search` matches addresses exactly. `get_function` gives the language and the window's
language (`arguments_written_in`) from `info.json`.

| Tool | Method(s) |
|---|---|
| scan | `scan/run` (said to run code for Elixir and sbt, concern 2) |
| search functions | `card/search`, with a limit |
| a function's card | `card/get` (with its language and the language its arguments are written in) |
| a function's neighbours | `graph/neighbors` |
| add a row | `row/add` (`origin: "agent"`) |
| change a row's arguments | `row/set-args` |
| list rows | `row/list` |
| check which rows erred, changed or were never evaluated | `row/check` (its `check_failed` read as the answer, not an error; 2026-11-22) |
| start an evaluation | `eval` ([D-mcp-eval-wait](#d-mcp-eval-wait)) |
| an evaluation's status and results | `eval/status` and the pass's results |
| propose a class, with its reason | `effect/propose` ([D-mcp-effects](#d-mcp-effects)) |

- A function is named by its address (`Calc.add/2`, through `node/resolve`) as well as by id; rows by id (given back by `row/add`)
- Not offered: `effect/set`, `include_writes`, `row/set-prev`, `row/set-result` ([D-mcp-expectations](#d-mcp-expectations)), `graph/export`, `card/list` (sizes, concern 12), `config/set`, `row/remove`, `edit/apply`,
  `trace/*`, the dialogue
- `row/remove` is not a tool, even for the agent's own rows (crux, 2026-11-22, `mcp.md` concern 24): removing rows is editing the
  Book, a person's work in an editor of rows (tezcatl's table, an editor of CSV-like tables). An agent meant to remove rows does it
  through that editor's own connection, which calls `row/remove` of the running `xipe start`, not by editing `book.jsonl`.
  `add_row`'s description says rows are removed by a person
- A project without functions answers "not scanned yet -- call scan first" wherever a function is searched or named (2026-11-22,
  concern 23), not an empty result
- `row/check` is offered as `check_rows` (2026-11-22, concern 24): it reads the rows' last evaluation and writes nothing, so the
  agent checks for regressions without writing expectations (D-mcp-expectations stands)
- What a description promises is what the answer holds: `get_function` gives the place of the source (path, line), not its text
  (amended 2026-11-22, concern 25)
- Every tool has a JSON Schema for its input; the descriptions say what runs (concerns 1, 2, 5) and in which language arguments are
  written (concern 11)

**Why**: a model chooses well among few tools; an address is what it already knows from the source. **Alternatives**: one tool per
method (31); one generic "call a method" tool (no schema per method, the guard of D-mcp-effects left to the description).

<a id="d-mcp-effects"></a>

## D-mcp-effects — the agent proposes a class; a person approves it; `include_writes` is not offered

**Decided** 2026-11-21 (crux); **built** 2026-11-21: Xipe Totec's side is [D-effect-approval](lib-core.exs.md#d-effect-approval);
the bridge's, `propose_class` and an `evaluate` without `include_writes`.

- An agent's classification is recorded with `effect_source: "agent"` (the column exists: `Core.put_node/3` defaults it to `nil`,
  `Core.set_effect/3`, behind `effect/set`, writes `"user"`). The evaluator goes on trusting `"user"` only (`Core.filter_by_effect/3`), so a proposed class evaluates nothing
- A person approves proposals in tezcatl or the CLI, many at once (the idea "`effect/set` for many at once" in
  [`scope.md`](../scope.md) becomes needed): approving writes `effect_source: "user"`
- **Each proposal carries its reason**, recorded with it (one short line: "no file or network I/O, depends on its arguments only"); the
  approval view shows class, reason and the function's source together, so approving is a check, not a click
- **An approval holds for the body it was given for.** The approval records the node's `body_hash`; when a rescan finds another body,
  the class falls back to a proposal (`effect_source` no longer `"user"`) and the function is not evaluated until a person approves
  it again (P2: what is evaluated is what a person looked at). Today this is not so (concern 21): a needed change in
  `Scanner.put_defs/3`, for people's own classes as well as the agent's
- `include_writes` is not a parameter of any MCP tool: rows classified `writes` (or `unknown`) are never evaluated through MCP
- Xipe Totec's part is **built** (2026-11-21, [D-effect-approval](lib-core.exs.md#d-effect-approval)): methods of their
  own, `effect/propose` (the bridge's) and `effect/approve` (a person's, many at once), and `effect_hash`, the body an approval was
  given for. An approval view in tezcatl (class, reason and source together) is not made; the CLI and `search -e` show the columns

**Why**: it keeps P1 and D-effect-classes as they are — a class is trusted because a person set it — while the agent takes over the
first, tedious classification of a project's functions. **Alternatives**: the agent calls `effect/set` (the guard is gone); no
classification by the agent (the person classifies every function before the agent can evaluate anything).

<a id="d-mcp-expectations"></a>

## D-mcp-expectations — the agent does not write expectations

**Decided** 2026-11-21 (crux); **built** 2026-11-21: no tool reaches `row/set-prev` or `row/set-result`.

- `row/set-prev` and `row/set-result` are not MCP tools. The rows' expectations come from evaluations (the latest result, D-compare-basis)
  or from a person (`prev_source` / `result_source` `"user"`, written by `Core.set_prev/3` and `Core.set_result/3`)
- If they are ever offered, the same way as classes: written with source `"agent"`, not used as the basis of `compare` until a person
  approves them

**Why**: a regression is caught because the expectation did not come from the code under change; an agent that edits the code and
also sets the expected value can make any change look `same`. **Alternatives**: offering them with a note in the description (the
guard left to the model).

<a id="d-mcp-shared-book"></a>

## D-mcp-shared-book — the agent and the person share one Book; rows tell whose they are

**Decided** 2026-11-21 (crux); **built** 2026-11-21: the bridge connects to the `xipe start` a person's tezcatl uses; `add_row` sends
`origin: "agent"`.

- The bridge connects to the same `xipe start` a person's tezcatl uses: the person watches the agent's rows appear and change in the
  table (the point of the tool, and of showing it)
- Rows the agent adds carry `origin: "agent"` (`row/add`'s `origin`, **built** 2026-11-21; `"manual"` by default); the eval table shows it
- Passes are already one at a time, so the two meet only in editing rows; no lock is added

**Why**: seeing an agent's work in the table is what the agent gets from Xipe Totec and the person from the agent. **Alternatives**: a
Book of the agent's own (a second project or server; the person does not see the work as it happens); locks on rows.
