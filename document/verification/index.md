# Files

Every file of the repository, one line: what it is, its record when it has one, and the decisions it is home to or takes part in. The
decisions are listed in [decisions.md](decisions.md).

## Entry points and settings

| File | What | Decisions |
|---|---|---|
| `main.exs` | The CLI (`xipe …`): every command, the `xipe start` server, the prompt of the dialogues; loads `lib/` with `Code.require_file` (not a Mix project). | D-workspace, D-session-record, D-git-provenance, D-effect-classes (`--include-writes`) |
| `info.json` | Xipe Totec's own registered languages, their extensions, REPLs and build tools (`xipe refresh`). In git: a fresh checkout scans without a refresh. | D-surface-table, D-language-adapter |
| `defaults.json` | Every project's default settings (`env.*`, `eval.*`). | D-project-config |
| `pipelines.json` | Methods made of stages (`eval/run`, `row/update`). | D-pipeline |
| `project_env.json` | How a project's environment is got: marker → command, format, watched files. | D-project-env |
| `flake.nix`, `flake.lock` | The development shell (Elixir 1.18, OTP 27, cowboy, erlexec) and the `xipe` command. | — |
| `nix/relay-packages.nix` | The Hex packages fetched for the dev shell (cowlib, ranch, cowboy, erlexec). | — |
| `nix/dev-tools.nix` | Tools on the dev shell's PATH (elixir-ls …). | — |
| `.gitignore` | `tables/` (per-machine data with absolute paths). | D-workspace |
| `README.md` | What it is for and how to run it. | — |

## Base: the Book and its model

| File | What | Decisions |
|---|---|---|
| [`lib/core.exs`](lib-core.exs.md) | Pure functions over the Book: rows, effects, arities, the reference graph, the plan, folding results. | **D-referential-transparency, D-named-rows-only, D-plan-run-apply, D-reference-values, D-effect-classes, D-effect-approval, D-arity-set** |
| `lib/book.exs` | The Book: six tables (`sheets`, `nodes`, `calls`, `links`, `runs`, `providers`), each `id => latest row`, and lookups by natural key. | D-identity |
| `lib/id.exs` | ULIDs for row ids. | D-identity |
| [`lib/identity.exs`](lib-identity.exs.md) | The rescan rule: an id is reused only on an exact natural key. | **D-identity, D-anykey-shape, D-node-marks** |
| [`lib/store.exs`](lib-store.exs.md) | `book.jsonl`: append-only, locked, caught up, failures as results. | **D-store** |
| [`lib/git_ctx.exs`](lib-git_ctx.exs.md) | The commit, its time and `dirty`, recorded on evaluated rows. | **D-git-provenance** |
| [`lib/address.exs`](lib-address.exs.md) | Addresses: columns as filters. | **D-address** |
| [`lib/graph_query.exs`](lib-graph_query.exs.md) | `graph/neighbors`, `graph/export` over the static links. | **D-references-list** |

## Scanning

| File | What | Decisions |
|---|---|---|
| `lib/project.exs` | `scan_dir`: the two-pass walk — each language's scanners by preference, definitions then links — and what disappeared is removed. | D-scanners, D-identity |
| `lib/scanner.exs` | The scanner behaviour and the shared bookkeeping (`put_defs` carries effects and arities over, `node_for` matches calls). | D-scanners, D-arity-set |
| [`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md) | A scanner over a language server (`documentSymbol`, `callHierarchy`), and its dialect behaviour. | **D-scanners** |
| `lib/scanner/lsp/elixir.exs` | Elixir's dialect (elixir-ls). | D-scanners |
| `lib/scanner/elixir.exs` | Elixir's own parser and compiler tracer (the fallback); counts default arguments for `arity/set`'s hint. | D-scanners, D-source-sanitize, D-arity-set |
| `lib/scanner/ocaml.exs` | OCaml read as text. | D-scanners |
| `lib/scanner/haskell.exs` | Haskell read as text. | D-scanners |
| `lib/scanner/python.exs` | Python read as text (module names from paths). | D-scanners, D-python-adapter |
| `lib/scanner/fsharp.exs`, `lib/scanner/fsharp/scan.fsx` | F# read by F#'s own parser (FSharp.Compiler.Service in `dotnet fsi`, once per scan); names resolved as F# looks them up. | D-scanners, D-fsharp-adapter |
| `lib/scanner/scala.exs`, `lib/scanner/scala/scan.scala` | Scala read by the Scala 3 compiler's parser (`scala`, once per scan); `anykey` the parameters' types, the shape per list; names resolved through objects, packages, imports. | D-scanners, D-scala-adapter, D-anykey-shape |
| `lib/scanner/csharp.exs` | C# read as text (comments, strings, `#if` branches blanked; namespaces, types and methods by their braces); `anykey` the parameters' types, the shape, the marks (`async`, `typed`) and a refusal (a type parameter in no parameter). | D-scanners, D-csharp-adapter, D-anykey-shape, D-node-marks |
| `lib/scanner/java.exs`, `lib/scanner/java/scan.java` | Java read by the JDK's own parser (`java scan.java`, once per scan; nothing compiled); `anykey` the parameters' types, the shape, the marks (`async`, `varargs`, `typed`), a refusal (a type parameter in no parameter); names resolved through the package, imports and static imports. | D-scanners, D-java-adapter, D-anykey-shape, D-node-marks |
| `lib/scanner/javascript.exs` | JavaScript and TypeScript read as text (modules are paths; IIFE bodies as the top level; ES imports, `require`). | D-scanners, D-map-only-language |
| `lib/scanner/go.exs`, `lib/scanner/go/scan.go` | Go read by its own parser (`go run scan.go`, once per scan; nothing of the project compiled); packages by import path, functions and methods, `vendor/` left out, build-tag variants reported; links through imports and receivers. Map-only. | D-scanners, D-map-only-language |
| `lib/scanner/php.exs`, `lib/scanner/php/scan.php` | PHP read by its own lexer (`token_get_all` with `TOKEN_PARSE`, once per scan; nothing run); classes' methods and namespaces' functions, `vendor/` left out, guarded helpers reported; links as PHP resolves names. Map-only. | D-scanners, D-map-only-language |
| `lib/lsp/transport.exs` | How a language server is reached: the behaviour. | D-scanners |
| `lib/lsp/transport/relay.exs` | Through tezcatl's `/lsp` relay. | D-scanners |
| `lib/lsp/transport/stdio.exs` | Started by Xipe Totec itself, in the project's environment. | D-scanners, D-project-env |
| [`lib/surface_table.exs`](lib-surface_table.exs.md) | The file → language / REPL / build tool table. | **D-surface-table** |
| `lib/info.exs` | `info.json`: reading it, `xipe refresh`, a language's module by name. | D-surface-table, D-language-adapter |

## Evaluation

| File | What | Decisions |
|---|---|---|
| [`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md) | One pass: one REPL, entry by entry, deadlines, cancel. | **D-one-pass-one-repl, D-hang-handling** |
| [`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md) | Elixir's text for one entry: the call in a child, `repr`, `compare`, markers. | **D-repr, D-compare-basis, D-closed-args** |
| `lib/repl/launch.exs` | Elixir's launch message (`iex`, banner, probe, `System.halt()`, interruptible). | D-ready-probe, D-language-adapter |
| [`lib/repl/sender.exs`](lib-repl-sender.exs.md) | The Sender behaviour. | **D-text-repl** |
| [`lib/repl/sender_direct.exs`](lib-repl-sender_direct.exs.md) | The bundled Sender (erlexec, a process group). | **D-sender-contract** |
| [`lib/repl/session.exs`](lib-repl-session.exs.md) | Waiting until a REPL is ready; closing it. | **D-ready-probe** |
| [`lib/repl/source_sanitize.exs`](lib-repl-source_sanitize.exs.md) | Loading scripts without their top-level code. | **D-source-sanitize** |
| [`lib/repl/language.exs`](lib-repl-language.exs.md) | A language's declaration (the behaviour); a map-only language leaves the REPL out. | **D-language-adapter, D-map-only-language** |
| `lib/repl/language/javascript.exs`, `lib/repl/language/typescript.exs` | JavaScript (`js` `mjs` `cjs` `jsx`), TypeScript (`ts` `tsx` `mts` `cts`): map-only, `Scanner.JavaScript`, pnpm / yarn / bun / npm. | D-map-only-language |
| `lib/repl/language/go.exs`, `lib/repl/language/php.exs` | Go (`go`, go.mod) and PHP (`php`, composer.json): map-only, `Scanner.Go` and `Scanner.Php` (their own parsers). | D-map-only-language |
| `lib/repl/language/elixir.exs` | Elixir: `ex`/`exs`, `iex`, `mix`, its scanners and adapter. | D-language-adapter, D-source-sanitize |
| [`lib/repl/language/ocaml.exs`](lib-repl-language-ocaml.exs.md) | OCaml: `ml`, `ocaml` + embody, `dune`. | **D-ocaml-adapter** |
| [`lib/repl/language/haskell.exs`](lib-repl-language-haskell.exs.md) | Haskell: `hs`, GHCi + embody, `stack` / `cabal`. | **D-haskell-adapter** |
| [`lib/repl/language/python.exs`](lib-repl-language-python.exs.md) | Python: `py`, `python -i` + embody, `uv` / `poetry` / `pip`. | **D-python-adapter** |
| `lib/repl/ocaml/launch.exs`, `lib/repl/ocaml/eval_template.exs` | OCaml's launch message and one entry (`Embody.run …`). | D-ocaml-adapter |
| `lib/repl/haskell/launch.exs`, `lib/repl/haskell/eval_template.exs` | Haskell's launch message and one entry (five `let`s and `Embody.run`). | D-haskell-adapter |
| `lib/repl/python/launch.exs`, `lib/repl/python/eval_template.exs` | Python's launch message, init file and one entry (`_xt_embody.run(…)`). | D-python-adapter |
| [`lib/repl/language/fsharp.exs`](lib-repl-language-fsharp.exs.md) | F#: `fs`, `fsx`, `dotnet fsi` + embody, `dotnet`. | **D-fsharp-adapter** |
| `lib/repl/fsharp/launch.exs`, `lib/repl/fsharp/eval_template.exs` | F#'s start script (build, scripts' definitions-only copies), init file and one entry (three fsi submissions). | D-fsharp-adapter |
| [`lib/repl/language/scala.exs`](lib-repl-language-scala.exs.md) | Scala 3: `scala`, `sc`, Scala's REPL + embody, `sbt`, `scala-cli`; the sbt server check. | **D-scala-adapter** |
| `lib/repl/scala/launch.exs`, `lib/repl/scala/build_tool.exs`, `lib/repl/scala/eval_template.exs` | Scala's start script (the build tool's class path and compiler, then the REPL), one module per build tool, one entry (three REPL inputs, the args split by the shape). | D-scala-adapter |
| [`lib/repl/language/csharp.exs`](lib-repl-language-csharp.exs.md) | C#: `cs`, `dotnet fsi` (F#'s window) + `embody.fsx` + C#'s seam `embody.cs`, `dotnet`. | **D-csharp-adapter** |
| `lib/repl/csharp/launch.exs`, `lib/repl/csharp/eval_template.exs` | C#'s start script (embody and its protocol checked, the seam and the target built, `#r` + `Embody.reference`, the seam registered) and one entry on F#'s (the call awaited and typed by the node's marks). | D-csharp-adapter, D-node-marks |
| [`lib/repl/language/java.exs`](lib-repl-language-java.exs.md) | Java: `java`, Scala's REPL (Scala's window) + `embody.scala` + Java's seam `embody.java`, maven. | **D-java-adapter** |
| `lib/repl/java/launch.exs`, `lib/repl/java/eval_template.exs` | Java's start script (both embody files and their protocols checked, the seam compiled, maven offline, Scala's home, the REPL on the JVM's class path) and one entry on Scala's (awaited, spread and typed by the node's marks). | D-java-adapter, D-node-marks |
| [`lib/repl/embody.exs`](lib-repl-embody.exs.md) | Where embody is. | **D-embody** |
| [`lib/repl/eval/scan.exs`](lib-repl-eval-scan.exs.md) | Finding one id's markers in a cleaned buffer. | **D-markers** |
| `lib/repl/eval/scan/direct/{iex,ocaml,ghci,python,fsi,scala}.exs` | Per transport and REPL: `XT_EXIT` removed (the others delegate to iex's). | D-markers, D-language-adapter |
| `lib/repl/eval/field_drip.exs`, `lib/repl/eval/field_drip/{elixir,ocaml,haskell,python,fsharp,csharp,scala,java}.exs` | Reading the `key=value` body (the others delegate to Elixir's). | D-markers |
| `lib/repl/eval/result.exs` | A parsed body or error as a result for Core. | D-plan-run-apply |
| `lib/repl/eval/parser.exs` | clean → scan → field_drip → result, in one step. | D-markers |

## Commands

| File | What | Decisions |
|---|---|---|
| [`lib/runner.exs`](lib-runner.exs.md) | Command lists; `eval` by language. | **D-command-list, D-languages-per-pass** |
| [`lib/pipeline.exs`](lib-pipeline.exs.md) | Methods made of stages. | **D-pipeline** |
| [`lib/dispatch.exs`](lib-dispatch.exs.md) | The methods on the Book alone. | **D-card-shape** |
| [`lib/methods.exs`](lib-methods.exs.md) | Every method declared once. | **D-method-criteria** |
| [`lib/command_line.exs`](lib-command_line.exs.md) | `xipe do`'s arguments to a command list. | **D-cli-values** |
| `lib/card_table.exs` | `card/list`'s view: every function with its file and line. | D-card-shape |
| `lib/eval_table.exs` | The `eval_table` view: calc rows with their function and path. | D-search |
| `lib/tables.exs` | The tables `search` and `roster` know, their columns and rewritable columns (`writes`). | D-search, D-dialogue-do |
| `lib/passes.exs` | [record](lib-passes.exs.md): running passes as files, `row_in_pass`, `eval/status`, `eval/cancel`. | **D-passes** |

## Dialogues and the window

| File | What | Decisions |
|---|---|---|
| [`lib/in_out.exs`](lib-in_out.exs.md) | The dialogue core. | **D-dialogue-core** |
| `lib/dialogue.exs` | The contract of a dialogue program. | D-dialogue-core |
| [`lib/dialogue/depends.exs`](lib-dialogue-depends.exs.md) | Negotiating a dependency chain. | **D-depends** |
| [`lib/dialogue/search.exs`](lib-dialogue-search.exs.md) | `search`. | **D-search** |
| [`lib/dialogue/do.exs`](lib-dialogue-do.exs.md) | `dialogue do`. | **D-dialogue-do** |
| `lib/dialogue/rewrite.exs` | `dialogue rewrite`: table → row → column, then `dialogue do`. | D-dialogue-do |
| `lib/dialogue/update.exs` | `dialogue update`: file → key, then `dialogue do` for `config/set`. | D-dialogue-do, D-log-buffer |
| [`lib/serve_input.exs`](lib-serve_input.exs.md) | The window's `input`. | **D-input-line** |
| `lib/input.exs` | Reading one window line (pure). | D-input-line |
| [`lib/help.exs`](lib-help.exs.md) | `help`'s table. | **D-help-table** |
| `lib/outcome_text.exs` | The lines of results (CLI and window alike), the limits line, the env status. | D-input-line, D-log-buffer |
| [`lib/show.exs`](lib-show.exs.md) | `show`'s lines. | **D-show-failed** |
| [`lib/log_buffer.exs`](lib-log_buffer.exs.md) | The lines said, kept. | **D-log-buffer** |

## Server and projects

| File | What | Decisions |
|---|---|---|
| [`lib/serve_project.exs`](lib-serve_project.exs.md) | One GenServer per project. | **D-serve-project** |
| `lib/serve_socket.exs` | The WebSocket: one dialogue slot per connection, the reply envelope, `Origin` refused. | D-envelope, D-serve-project |
| [`lib/protocol.exs`](lib-protocol.exs.md) | The wire shape. | **D-envelope** |
| [`lib/session.exs`](lib-session.exs.md) | `session.json`. | **D-session-record** |
| [`lib/mcp/server.exs`](lib-mcp-server.exs.md) | `xipe mcp`: MCP over stdio for an AI agent. | **D-mcp-bridge, D-mcp-eval-wait, D-mcp-tools, D-mcp-effects, D-mcp-expectations, D-mcp-shared-book** |
| `lib/mcp/upstream.exs` | The bridge's WebSocket to `xipe start`; completed passes by id. | D-mcp-bridge, D-mcp-eval-wait |
| `lib/mcp/tools.exs` | The bridge's tools and their schemas. | D-mcp-tools, D-mcp-effects, D-mcp-expectations |
| [`lib/workspace.exs`](lib-workspace.exs.md) | Which project, and where its files are. | **D-workspace** |
| `lib/project_registry.exs` | 3-digit ids matched by `project.json`. | D-workspace |
| [`lib/project_config.exs`](lib-project_config.exs.md) | Per-project settings. | **D-project-config** |
| [`lib/project_env.exs`](lib-project_env.exs.md) | The project's environment. | **D-project-env** |

## Tests

`./test/run.sh` runs every `test/*_test.exs` (each a plain `elixir` script, `XIPE_TOTEC_LSP=off`, starting nothing). `test/live/` starts real
REPLs and is run by hand. Each test file is named after what it tests (`core_test.exs` → `lib/core.exs`); the records name the ones that
guard their decisions.

| File | What |
|---|---|
| `test/run.sh` | Runs the suite. |
| `test/live/repl_iex_test.exs`, `repl_ocaml_test.exs`, `repl_haskell_test.exs`, `repl_python_test.exs` | Against real `iex`, `ocaml` (+ dune), `ghci` (+ cabal, stack), `python3`; skipped when the tool is not on PATH. |
| `test/live/repl_csharp_test.exs` | C# through `dotnet fsi` with embody's seam `embody.cs`, through C#'s launch; an `embody.cs` of another protocol; skipped without `dotnet`. |
| `test/live/repl_java_test.exs` | Java through Scala's REPL with embody's seam `embody.java`, through Java's launch (maven offline); a failing build, a timeout, an `embody.java` of another protocol; skipped without `java`, `javac`, `mvn`, `scala`. |
| `test/live/scan_map_test.exs` | Go's and PHP's maps by their own parsers (`go`, `php`), each skipped without its tool. |
| `test/fixtures/calc_sample/` | A small script-mode Elixir project (also used by tezcatl's E2E). |
| `test/fixtures/ocaml_sample/`, `test/fixtures/ocaml_dune/` | OCaml: plain files with top-level effects; a dune project with a wrapped library. |
| `test/fixtures/haskell_sample/` | Haskell: an export list hiding a function, a module importing another, a `main`. |
| `test/fixtures/python_sample/` | Python: a top level that writes files, a src-layout package with relative and aliased imports. |
| `test/fixtures/js_sample/` | JavaScript / TypeScript: ES imports of every form, `require`, a directory's `index`, a declaration file, an IIFE-wrapped file. |
| `test/fixtures/fake_lsp_server.exs` | A language server stand-in for the stdio transport. |

## Documents

| File | What |
|---|---|
| [`document/scope.md`](../scope.md) | What is promised to work, what happens outside it, what a person does, and the work not done — citing these records. |
| [`document/how-to-use.md`](../how-to-use.md), [`internals.md`](../internals.md), [`extending.md`](../extending.md), [`repl-adapter-guide.md`](../repl-adapter-guide.md) | How to use it; what is called in what order; adding a language or a command; writing a REPL adapter. |
| [`document/mcp.md`](../mcp.md) | Xipe Totec as an MCP server: the concerns found and the decisions taken before building it (planned). |
| `document/verification/` | This directory. |
