# Xipe Totec

A standalone local server and CLI that brings the structure of a spreadsheet to a functional-language project: cells with
addresses, references to addresses, and a way to evaluate again by following the references in order.

The name comes from the image of peeling a skin (a card) off the body of the source, one function at a time. Every rescan gives
new skins.

Written in Elixir. Application `:xipe_totec`, module `XipeTotec`, CLI command `xipe`. It works on its own from the command line;
[tezcatl](https://github.com/Crux-xurC/tezcatl), a browser-side development environment in a separate repository, can be its window
(see "With tezcatl" below). OCaml and Haskell evaluation use [embody](https://github.com/Crux-xurC/embody), also a separate repository.

---

## What it is for

It started from the chore of trying functions in a REPL: typing the input values by hand every time, naming file paths, and so
on. Xipe Totec keeps them as **calc rows** to be saved and used again. A calc row's argument may be a reference (`⟦id⟧`) to the
output of another calc row — lay out calc rows joined by references and evaluate them, and you see how a change upstream reaches
downstream. Only the calc rows named are evaluated; rows not named are never evaluated behind your back and added to the record
(the Book is a record in time, [D-named-rows-only](document/verification/lib-core.exs.md#d-named-rows-only)).

Evaluation automates what a person does at a REPL's terminal. It starts the target project's own REPL (`iex` for Elixir), writes
the call expression to its standard input, and reads the result printed on its standard output.

The other pillar is the **list of references**: from the static call relations a scan finds (`:links`), who calls a given function.
Rewriting the source (a rename and the like) is left to the editor and its language server; Xipe Totec goes as far as giving the list
of references ([D-references-list](document/verification/lib-graph_query.exs.md#d-references-list)).

### What it is not

- A replacement for an IDE or editor. Showing tables, moving between cells, highlighting and showing completion candidates are the
  client's job (tezcatl and the like)
- A source rewriting tool. Renames and the like are left to the editor / LSP
- A code index for LLMs (read-only context). That is the field of the existing tree-sitter MCP servers; Xipe Totec's own value is
  in *values*
- A general runtime logger or profiler
- Editing the code itself, such as conditions
- Evaluating macros, pipes or several statements as a calc row (a calc row is always one call `Module.function(args...)`; several
  steps are calc rows joined by `⟦id⟧`)
- Sandboxed evaluation (see below)

---

## Before you use it

- **It runs your code for real.** Evaluating a calc row calls the function in the target project's REPL. Nothing is sandboxed: if a
  function writes files, sends messages or deletes data, that really happens.
- **Only functions you classified are evaluated.** A function's side-effect class (`pure` / `reads` / `writes`) counts only when you
  set it with `effect/set`; unclassified functions are not evaluated, and `writes` only with `--include-writes`. If you classify a
  function wrongly, its side effects still happen.
- **Loading the target runs none of its top-level code** (scripts-mode compiles only the `defmodule` parts; OCaml and Haskell skip
  top-level expressions and `main`). A Mix project is started with `iex -S mix`, which starts its application.
- **Local only, no authentication.** `xipe start` binds to `127.0.0.1` only and has no authentication. A WebSocket handshake that
  carries an `Origin` header (a browser) is refused unless that origin is listed in `XIPE_TOTEC_ALLOWED_ORIGINS`, so web pages cannot
  drive it directly; any other local program can. Use it on a machine where you trust the local users and programs.
- **No network of its own.** Xipe Totec connects to nothing outside the machine, and build tools started for evaluation get
  `--offline` or the like where they have it. Tools that run in the target's environment may still fetch on their own (elixir-ls
  installs itself the first time it is used).
- **Its state lives in this directory.** Registered projects and their Books are kept under `tables/` next to `main.exs` (not in
  git), not in the target project. Nothing is written into the target's directory, except what its own tools write there
  (elixir-ls's `.elixir_ls/`, build output).

What is promised to work, and what happens outside the promise, is in [`document/scope.md`](document/scope.md).

---

## Requirements

- **Nix** with flakes, on `x86_64-linux`. `nix develop` gives Elixir 1.18 / OTP 27 and the Erlang packages it uses (cowboy, gun,
  erlexec). There is no build without Nix yet.
- For **OCaml** and **Haskell** projects: `ocaml` / `ghci` in the target's environment (a flake, direnv or mise declared in
  `project_env.json`, or on `PATH`), and [embody](https://github.com/Crux-xurC/embody) cloned next to this repository (or
  `XIPE_TOTEC_EMBODY_DIR` pointing at it).
- Optional: **elixir-ls** for scanning Elixir (without it, Xipe Totec's own scanner is used).

---

## Quick start

```
git clone https://github.com/Crux-xurC/xipe_totec.git
git clone https://github.com/Crux-xurC/embody.git        # only for OCaml / Haskell
cd xipe_totec
nix develop                                             # gives the `xipe` command

cp -r test/fixtures/calc_sample ~/calc                  # a small Elixir target to try on
xipe choice project ~/calc                              # 1. register and choose the project
xipe scan                                               # 2. make the functions cards
xipe show                                               # 3. look up the node id of Calc.add/2
xipe do row/add node=<id> args=[2,3] -- effect/set id=<id> effect=pure -- eval 'call_ids=[$0.id]'
                                                        # 4. make a calc row, classify the function, evaluate it: 5
xipe do card/get module=Calc name=add arity=2           # 5. take out the card with its calc row
```

[`document/how-to-use.md`](document/how-to-use.md) goes on from here.

---

## Commands

```
xipe choice project <path> # register (the first time) and choose the target project; the target when <dir> is left out
xipe table generate [<path>]
                           # make the file → language/REPL/build tool table again and save it
xipe scan [<dir>]          # walk the source files and update the Book
xipe show [<dir>]          # a summary of the Book (node ids are found here)
xipe eval [<dir>] [id...] [--mix] [--include-writes]
                           # evaluate calc rows for real (all when no id is given)
xipe do [--dir <dir>] <method> [key=value...] [-- <method> ...]
                           # run a command list of methods. A later command can refer
                           # to an earlier result with "$<number>.<path>". For example:
                           #   xipe do row/add node=n1 args=1,2 \
                           #        -- effect/set id=n1 effect=pure \
                           #        -- eval 'call_ids=$0.id'   (quoted: the shell expands $0)
xipe dialogue depends [<dir>] <call_id>
                           # negotiate a dependency chain (answer "y <value>" or "n")
xipe dialogue do <method> [key=value...]   # asks for the missing arguments, then runs it (values pass as typed)
xipe dialogue rewrite [<table> [<row> [<column>]]]   # rewrite one value of a table by hand, without evaluating (the value is asked)
xipe dialogue update [<file> [<key>]]   # change one setting (time limits …; the file, key and value are asked)
xipe search [<turn>]       # narrow a table (surface table / eval_table) by dialogue (-h for how)
xipe start [<dir>] [--port N] [--lsp <url>] [--fs-root <dir>]
                           # stay up as the WebSocket server, recorded as a session
                           # (default port 4200, or $XIPE_TOTEC_PORT). xipe serve is another name.
                           # An unregistered <dir> is registered (the chosen project does not change).
                           # --lsp/--fs-root are tezcatl's /lsp relay and file root; left out, they come
                           # from TEZCATL_RELAY_PORT/TEZCATL_FS_ROOT inherited from tezcatl.
                           # tezcatl starts it without <dir> (the target is the chosen project:
                           # xipe_totec decides, tezcatl is the window); it passes --port, --lsp, --fs-root
xipe refresh -l|-r|-a      # update xipe_totec's own info.json (languages and extensions, the REPL adapter list)
xipe help [<command>]      # one command a line (`command: description  arguments`); <command> for its description

./test/run.sh                         # every ExUnit test (starts nothing, runs alone)
elixir test/live/repl_iex_test.exs    # tests with a real iex
```

When `<dir>` is left out, the target is the project of the running `xipe start` session if there is one, else the chosen project
(an explicit `<dir>` > the session > the chosen one). The session is recorded in `tables/session.json` and removed on a normal stop
(SIGTERM); a record whose process is gone is ignored. A CLI command that changes the project a session is serving writes
`book.jsonl` directly and says so; the server takes the CLI's writes in on its next request (routing CLI writes through the server is
not implemented). A `<dir>` passed must also be registered with `xipe choice project` (nothing is registered implicitly).

In `xipe do`, a value in `[...]` is always a list (`[]` empty, `[10]` one element, `[1,2]` two). A value with commas but no brackets
(`args=1,2`) is a list too; anything else passes as a string. `row/add` makes a row only when the node exists and the number of
arguments matches the node's arity (when `anykey` is an integer).

Per-project data lives in `tables/project/<id>_<name>/` (`project.json`, `table`, `book.jsonl`, `env.json`). `tables/` is per-machine
data and not in git.

It is not a Mix project (no `mix.exs`). `main.exs` is a plain `elixir` script that loads `lib/*.exs` with `Code.require_file`. The
Hex packages it uses (cowboy, gun, erlexec …) come from `nix/relay-packages.nix`.

---

## How far it works now

As of 2026-10-31, all 50 files and 568 cases of `./test/run.sh` pass. Apart from them there are tests that start real REPLs
(`test/live/`: `iex` 12, `ocaml` 6, `ghci` 7; the OCaml and Haskell ones are skipped when their system is not on PATH).

**From the CLI, scan → making calc rows → real evaluation → persisting the results works end to end for Elixir projects.** OCaml
(`.ml`) works the same way; for dune projects the libraries depended on are loaded from `dune ocaml top`
([D-ocaml-adapter](document/verification/lib-repl-language-ocaml.exs.md#d-ocaml-adapter)). So does Haskell (`.hs`); for cabal and
stack projects GHCi is started under `cabal exec` / `stack exec` so dependency packages are visible
([D-haskell-adapter](document/verification/lib-repl-language-haskell.exs.md#d-haskell-adapter)). Both the mix layout (`iex -S mix`)
and the script layout are supported. In the script layout only the `defmodule` parts of each file are compiled, with the original
file's path and line numbers (the loading script of `Repl.SourceSanitize`; top-level side effects are not run; error positions and
`__DIR__` point at the original file).

- An evaluation result has `repr` (`exact`/`binary`/`unsupported`), a display string, and `compare` against the previous value
  (floating point with a tolerance)
- Each row is evaluated with a timeout and a max_heap guard. A stuck session gets SIGINT, then, if that does not work, SIGKILL for
  its whole process group, and the rest become `aborted`
- Arguments that are not syntactically closed are not sent to the REPL but made an error. A calc row whose references cannot be
  resolved is not evaluated and becomes `skipped`
- `xipe dialogue depends` decides by dialogue, from the deepest step of the upstream dependency chain, "put a value here by hand and
  evaluate from there up?"
- `xipe search` narrows the surface table and `eval_table` over turns of a dialogue
  ([D-search](document/verification/lib-dialogue-search.exs.md#d-search)). Both dialogues can be used from tezcatl's dialogue window
- `xipe dialogue do <method>` asks for the missing arguments one by one and runs it. Answers pass as the lines typed, so values that
  cannot be written on one line (lists containing commas, strings containing quotes) get through. A function can be answered by name
  (`Calc.add/2`)
- `xipe dialogue rewrite` rewrites one value of a table without evaluating (arguments, value, expected value, a function's class)
- A calc row's time limit and the time to wait for the REPL to start can be changed per project (`eval.timeout`, `eval.boot_timeout`;
  `xipe dialogue update` or `xipe config`). The evaluation output shows that pass's limit and the file its value came from
- A running pass can be stopped with `eval/cancel` (the REPL is stopped with its whole process group; nothing is recorded)

Evaluation also works through `xipe serve` (WebSocket). `eval` / `eval/run` / `row/update` return a `pass_id` at once, and the
evaluation runs in another process (other requests are answered meanwhile). When it ends, `notify/rowChanged` and
`notify/passCompleted` arrive. Passes run one at a time per project, in the order they came.

The methods (the same over `xipe do` and the WebSocket):

| Group | Methods | State |
|---|---|---|
| The Book and the graph | `scan/run`, `row/add`, `row/remove`, `effect/set`, `card/get`, `card/search`, `graph/neighbors`, `graph/export`, `cell/resolve` | implemented |
| Rows and nodes | `row/depends` (the upstream dependency chain), `row/set-result` (a value by hand), `row/list` (the list of calc rows), `row/check` (fails when a row meets a condition), `node/resolve` (a node's id from an address), `notify/passCompleted` (a pass's completion) | implemented |
| For the window | `input` (takes one line as it is and reads it as the CLI would; for tezcatl's dialogue window) | implemented ([D-input-line](document/verification/lib-serve_input.exs.md#d-input-line)) |
| Passes | `eval/status` (the pass being evaluated now; rows in it cannot be changed), `eval/cancel` (stop the running pass, take a waiting one out of the queue; records nothing) | implemented ([D-passes](document/verification/lib-passes.exs.md#d-passes)) |
| Lists and settings | `roster` (the tables and columns `search` can look up), `card/list` (the whole list of functions, with file, line, class and the number of calc rows), the columns `path` and `line` of `row/list`, `row/set-prev` (set the expected value by hand), `row/set-args` (change only the arguments, without evaluating), `config/set` (change one of the project's settings) | implemented |
| Arity | `arity/set` (a person decides how many arguments a function with default arguments is called with; used by `row/add` and links) | implemented ([D-arity-set](document/verification/lib-core.exs.md#d-arity-set)) |
| Evaluation | `eval`, `eval/run` | implemented. On the CLI (`xipe eval` / `xipe do ... eval`) synchronous, under `xipe serve` asynchronous (returns a `pass_id`). `eval/run` goes through `Pipeline` (`["eval"]`) |
| Through Pipeline | `row/update` | implemented. `["edit", "eval"]`: change the arguments and evaluate that row alone ([D-pipeline](document/verification/lib-pipeline.exs.md#d-pipeline)) |
| Not implemented | `cell/complete`, `provider/recheck`, `trace/*` | return a `not_implemented` error (`trace/*`, recording a running program's calls as a table, is frozen) |
| Withdrawn | `edit/propose`, `edit/apply` | writing a rename back to the source; left to the editor instead. Not the `"edit"` step of `row/update` |

Several projects can be handled. Once `xipe choice project` chooses the target, later commands read and write that project's Book
(`tables/project/<id>_<name>/book.jsonl`).

**What is in progress is more languages.** The table that decides language, REPL and build tool (`SurfaceTable`) is in place, with
Elixir (+ mix), OCaml (+ dune) and Haskell (+ stack, cabal). For the rest see [`document/scope.md`](document/scope.md) ("Work not
started").

---

## Design principles

| # | Principle |
|---|---|
| P1 | Referential transparency is assumed. Functions with side effects are told apart explicitly |
| P2 | Reproducibility comes first. Content hashes, git commits and providers are recorded |
| P3 | IDs and names are separate. The ID is a surrogate key, the name a natural key |
| P4 | Asymmetric trust. LLMs, heuristics and outside providers only *propose*; only what passes an acceptance check is taken |
| P5 | Differences are kept to the added parts. The basic structure is language-neutral; what differs per language is in the REPL adapter |
| P6 | Writing always goes in two steps: diff → apply |
| P7 | The input experience is the client's job. The server only provides the openings |
| P8 | It is complete on its own; outside providers (language servers …) are added on top |
| P9 | What cannot be decided is shown in the table. Estimates and states are shown as columns, for the user to confirm |
| P10 | It runs in the target project's environment. Evaluation, tracing and parsing happen inside the target project's REPL |

P1 in concrete form: side-effect classes (`pure`/`reads`/`writes`) are trusted only when the user set them with `effect/set`, and
unclassified functions are not evaluated. `writes` are evaluated only with `--include-writes`.

---

## Structure

```
the target project's source
        │ scan (AST extraction + links extracted by a compiler tracer)
   SurfaceTable (file → language/REPL/build tool) → Project / Scanner ── Identity
        │
       Core (pure functions: the reference graph, the recalculation plan plan_recalc, applying results apply_results)
        │
       Book (id => latest row, 6 tables) ⇄ Store (append-only JSON Lines = book.jsonl per project)
        │
   command lists  Runner ─┬─ Dispatch (the table of methods complete with the Book alone)
                          ├─ Pipeline (methods with a REPL in between; registered in pipelines.json)
                          └─ "eval" → Repl.Evaluator
                                        Launch → Sender.Direct(erlexec) → Session
                                        → EvalTemplate → iex → Eval.Parser → Core.apply_results
   dialogues     InOut / Dialogue (dialogues over several turns, e.g. Dialogue.Depends)
        │
   entrances     CLI (main.exs) / Serve.Project (GenServer) + Serve.Socket (WebSocket)
        │ WebSocket (localhost)
   tezcatl's `/xipe` (the relay, the dialogue window's `input`, the tables `row/list`/`card/get`; "With tezcatl")
```

Scanning and evaluation are chosen by language. For a language the surface table names (one registered in `info.json`), its
`Repl.Language` module declares the Scanner that reads its files (`scanner/0`, an implementation of `XipeTotec.Scanner`), the four
modules given to `Repl.Evaluator` (`launch`/`eval_template`/`Eval.Scan`/`field_drip`) and how its REPL starts (`launch_opts/2`);
`Project` (scanning) and `Runner` (evaluation) use them. There is one REPL per language (`iex` for Elixir), and the build tool only
changes how it starts. Elixir, OCaml (the plain `ocaml` toplevel + `embody.ml`,
[D-ocaml-adapter](document/verification/lib-repl-language-ocaml.exs.md#d-ocaml-adapter)) and Haskell (GHCi + `embody.hs`,
[D-haskell-adapter](document/verification/lib-repl-language-haskell.exs.md#d-haskell-adapter)) are declared. embody is a separate
repository ([Crux-xurC/embody](https://github.com/Crux-xurC/embody)).

Elixir's Scanner prefers elixir-ls (`Scanner.Lsp.Elixir`). It tries tezcatl's `/lsp` first for the language server, and starts
elixir-ls itself when that does not connect (so the CLI works alone too). When neither works it uses its own `Scanner.Elixir`. Which
one read a file (`via`: `relay`/`stdio`) is in `scanners` of `scan/run`'s result. Cards follow the files on disk (what the REPL reads
when evaluating). A file whose positions differ from the disk because the language server holds unsaved contents from an editor is
read again by the next Scanner (`Scanner.Elixir` for Elixir), and listed in `scanners.<language>.fallbacks`. Only functions become
cards (`def`/`defp`/`defdelegate` for Elixir); macros and guards do not. `XIPE_TOTEC_LSP=off` turns the language server path off (the
tests run with it). `Scanner` (extracting definitions from source) and `Eval.Scan` (finding markers in REPL output) have similar names
but are different things.

| Layer | Modules | Role |
|---|---|---|
| Base | `Book` / `Store` / `Core` / `Id` / `Identity` | the current state, append-only persistence, the pure reference graph and recalculation plan, keeping IDs across rescans |
| Scanning | `Scanner` (behaviour) / `Scanner.Lsp` (+ `Scanner.Lsp.Elixir`) / `Scanner.Elixir` / `Lsp.Transport` (+ `.Relay`, `.Stdio`) / `Project` / `SurfaceTable` | the opening that makes cards and links from files and the shared bookkeeping; the implementation through a language server (`documentSymbol`, `callHierarchy`; what differs per language is a thin dialect); Elixir's own implementation (AST extraction, compiling only `defmodule`; the fallback without a language server); how to reach a language server (tezcatl's `/lsp`, else started by itself); the two-pass walk over directories (trying each language's Scanners in order of preference and recording which was used); deciding the language of each file |
| Commands | `Runner` / `Dispatch` / `Pipeline` / `Address` / `GraphQuery` | running command lists (`$<n>.<path>` refers to an earlier result), the table of methods, resolving addresses, BFS over the call graph and export |
| Evaluation | `Repl.Evaluator` / `Launch` / `Sender(.Direct)` / `Session` / `EvalTemplate` / `SourceSanitize` / `Eval.{Scan,FieldDrip,Parser,Result}` | starting the REPL, waiting for it, sending expressions, receiving markers, SIGINT → SIGKILL on a hang |
| Dialogues | `InOut` / `Dialogue` / `Dialogue.Depends` / `Dialogue.Search` / `Dialogue.Do` / `Dialogue.Rewrite` / `Dialogue.Update` / `LogBuffer` / `Tables` / `EvalTable` | structured dialogues over several turns (listed by `InOut.programs/0`, shared by the CLI and the server); negotiating dependency chains; a dialogue that asks for arguments and runs one method (`dialogue do`; what it asks comes from `params` in `Methods`); searching, and a dialogue that rewrites one value of a table by hand (`dialogue rewrite`; the method per column is `writes` in `Tables`, and from asking the value on it is `Dialogue.Do`); a dialogue that changes one setting (`dialogue update`; the file is chosen from `LogBuffer` = the record of lines said, `tables/logging_buffer.txt`; it writes with `config/set`); the declaration of the tables search can look up (`Tables`: name, mark, columns, how rows are read, rewritable columns; `roster` returns the same list); `eval_table`, which its `-e` looks up (calc rows with their function and path beside them, for reading) |
| Input and output for people | `Input` / `Help` / `OutcomeText` / `Show` / `Serve.Input` | reading one line (written as on the CLI), the `help` table, lines of results and of `show` (shared by the CLI and the dialogue window), the `input` method |
| Server | `Protocol` / `Serve.Project` / `Serve.Socket` | the JSON-RPC wire shape, one GenServer per project, the WebSocket entrance |
| Projects | `Workspace` / `ProjectRegistry` / `ProjectConfig` / `ProjectEnv` / `Info` / `Repl.Language` | resolving which project is the target, registering it with a 3-digit ID, per-project settings (`project.json`, `xipe config`), the environment the target's tools run in (got by the declaration in `project_env.json`, written as tezcatl's is: a flake, direnv, mise …), xipe_totec's own `info.json` (languages and extensions, the adapter list) and the project chosen on this machine (`tables/selection.json`), each language's own declaration |
| Around evaluation | `Passes` / `GitCtx` / `CommandLine` | the pass being evaluated now (files under `passes/`; `eval/status`, rows being evaluated cannot be changed, [D-passes](document/verification/lib-passes.exs.md#d-passes); a request to stop, `eval/cancel`, is a file here too), the git provenance recorded with evaluated rows, reading `xipe do`'s arguments as a command list |

---

## Terms

| Term | Definition |
|---|---|
| Book | the whole target project: the set of tables (`sheets`/`nodes`/`calls`/`links`/`runs`/`providers`) |
| sheet | one file of the target project |
| card | the rows of one function. Made by scanning, and there as long as the function is in the source |
| row | the unit a card is made of. Two kinds: calc rows and link rows |
| calc row | one call of a function. Has columns such as arguments, result and previous |
| link row | a row for a function's connections: the cells it receives from, the condition, and the cells it sends to |
| reference | a reference to another calc row's result, written in a cell as `⟦ ⟧` |
| address | a set of columns naming a target (a partial-match filter without separators) |
| pass | one recalculation. Starts one REPL session, evaluates the planned calc rows in order, and closes it |
| marker | a fixed string to cut results out of REPL output (`XT_BEGIN_<id>`/`XT_END_<id>`/`XT_ERROR_<id>`/`XT_EXIT`) |
| trace table | a table of the function calls made at run time, in their order (frozen) |
| run | one unit recorded in the trace table |
| REPL adapter | the per-language part (four modules) that fits a REPL in the target project's environment to Xipe Totec's shared operations |
| boundary rule | the part that handles matching functions across a language boundary (e.g. Rustler between Elixir and Rust) |
| provider | what supplies the results of parsing and name resolution (a language server / the basic behaviour) |
| session | one run of a REPL a REPL adapter started. Has a generation number |
| tombstone | the state in which a target that disappeared is kept instead of deleted at once |
| anykey | the third of a node's match keys (module, function name, anykey). A value the language's Scanner puts in to tell apart functions of the same name in the same module: the arity for Elixir (`add/2` and `add/3` are different functions); may be empty in languages where the name alone is unique. As an integer it is also used as the number of arguments (`row/add`'s check, showing `Calc.add/2`). In addresses `arity` works as another name for it |
| visibility | a node's column. `public` is a function the REPL can call, `private` one it cannot (Elixir's `defp`). `private` nodes are in the list of references too, but `row/add` cannot make calc rows for them |
| surface_table | the target project's file tree as rows of path, depth, language, REPL and build tool |
| error value | the value a cell that could not be evaluated holds. It travels downstream through references |

---

## With tezcatl

The `/xipe` route of [tezcatl](https://github.com/Crux-xurC/tezcatl)'s relay connects the panels on the browser side
(`panels/matrix.html` …) with the Xipe Totec server. Which project is the target is decided by Xipe Totec (`xipe choice project`);
tezcatl is only its window. Normally `xipe start` is started on its own on :4200 without `<dir>` (tezcatl's `t` does not start it:
Poca's box row or a person does, as with Emacs), and the relay only connects to it by WebSocket (`mode: "connect"` in `xipe.json`).
Closing the window does not stop it. There is also `mode: "spawn"`, in which the relay starts it (it stops 45 seconds after the last
window leaves). The keys of `xipe.json` (`"."` …) are names of where to connect, not paths. Which project is open is in `project`
(`id`, `root`) of `initialize`'s result. The relay holds no state: `/xipe` does not multiplex by rewriting ids as `/lsp` does; it is a
stateless broadcast relay (tezcatl's `lib/relay/xipe_*.exs`).

Besides JSON-RPC's usual `result`/`error`, WebSocket answers carry `from` (reserved, always `null`) and `dialogue`
(`hold`/`via_repl`/`text`) ([D-envelope](document/verification/lib-protocol.exs.md#d-envelope)).

tezcatl's dialogue window (`panels/skins/xipe.html`) sends each line typed, uninterpreted, as `input` `{"text": "<line>"}`. Xipe
Totec decides what the line means (written as on the CLI, `XipeTotec.Input`), and puts the same lines as the CLI's in the answer's
`dialogue.text` (`Serve.Input`, [D-input-line](document/verification/lib-serve_input.exs.md#d-input-line)). `help` is one
"`command: description`" a line; tezcatl's users yank it into the dictionary and use it for completion.

---

## Documents

| Document | The question it answers |
|---|---|
| this README | what it was made for, what it is not, how far it works now |
| [`document/how-to-use.md`](document/how-to-use.md) | how to actually use it with the code as it is |
| [`document/scope.md`](document/scope.md) | what is promised to work, what happens outside it, what a person does there, and the work not started |
| [`document/internals.md`](document/internals.md) | for each use, what is called in what order, and which program does it |
| [`document/extending.md`](document/extending.md) | for someone adding a language or a command (and their AI): what to start from and what behaviour to meet |
| [`document/repl-adapter-guide.md`](document/repl-adapter-guide.md) | how to write an adapter for a new language or REPL (the detailed reference from when Elixir was written; the entrance is the extension guide) |
| [`document/verification/`](document/verification/README.md) | every decision in force (`decisions.md`), every file (`index.md`), and a record per file: what it does, why, the decisions homed in it, what was not chosen |

---

## License

MIT ([LICENSE](LICENSE)).
