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
| `README.md`, `CLAUDE.md` | What it is for and how to run it; where to start for a session with no memory. | — |

## Base: the Book and its model

| File | What | Decisions |
|---|---|---|
| [`lib/core.exs`](lib-core.exs.md) | Pure functions over the Book: rows, effects, arities, the reference graph, the plan, folding results. | **D-referential-transparency, D-named-rows-only, D-plan-run-apply, D-reference-values, D-effect-classes, D-arity-set** |
| `lib/book.exs` | The Book: six tables (`sheets`, `nodes`, `calls`, `links`, `runs`, `providers`), each `id => latest row`, and lookups by natural key. | D-identity |
| `lib/id.exs` | ULIDs for row ids. | D-identity |
| [`lib/identity.exs`](lib-identity.exs.md) | The rescan rule: an id is reused only on an exact natural key. | **D-identity** |
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
| [`lib/repl/language.exs`](lib-repl-language.exs.md) | A language's declaration (the behaviour). | **D-language-adapter** |
| `lib/repl/language/elixir.exs` | Elixir: `ex`/`exs`, `iex`, `mix`, its scanners and adapter. | D-language-adapter, D-source-sanitize |
| [`lib/repl/language/ocaml.exs`](lib-repl-language-ocaml.exs.md) | OCaml: `ml`, `ocaml` + embody, `dune`. | **D-ocaml-adapter** |
| [`lib/repl/language/haskell.exs`](lib-repl-language-haskell.exs.md) | Haskell: `hs`, GHCi + embody, `stack` / `cabal`. | **D-haskell-adapter** |
| `lib/repl/ocaml/launch.exs`, `lib/repl/ocaml/eval_template.exs` | OCaml's launch message and one entry (`Embody.run …`). | D-ocaml-adapter |
| `lib/repl/haskell/launch.exs`, `lib/repl/haskell/eval_template.exs` | Haskell's launch message and one entry (five `let`s and `Embody.run`). | D-haskell-adapter |
| [`lib/repl/embody.exs`](lib-repl-embody.exs.md) | Where embody is. | **D-embody** |
| [`lib/repl/eval/scan.exs`](lib-repl-eval-scan.exs.md) | Finding one id's markers in a cleaned buffer. | **D-markers** |
| `lib/repl/eval/scan/direct/{iex,ocaml,ghci}.exs` | Per transport and REPL: `XT_EXIT` removed (OCaml and GHCi delegate to iex's). | D-markers, D-language-adapter |
| `lib/repl/eval/field_drip.exs`, `lib/repl/eval/field_drip/{elixir,ocaml,haskell}.exs` | Reading the `key=value` body (the others delegate to Elixir's). | D-markers |
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
| `test/live/repl_iex_test.exs`, `repl_ocaml_test.exs`, `repl_haskell_test.exs` | Against real `iex`, `ocaml` (+ dune), `ghci` (+ cabal, stack); skipped when the tool is not on PATH. |
| `test/fixtures/calc_sample/` | A small script-mode Elixir project (also used by tezcatl's E2E). |
| `test/fixtures/ocaml_sample/`, `test/fixtures/ocaml_dune/` | OCaml: plain files with top-level effects; a dune project with a wrapped library. |
| `test/fixtures/haskell_sample/` | Haskell: an export list hiding a function, a module importing another, a `main`. |
| `test/fixtures/fake_lsp_server.exs` | A language server stand-in for the stdio transport. |

## Documents

| File | What |
|---|---|
| `document/範囲.md` | What is promised to work, what happens outside it, what a person does (Japanese; to be put into English, citing these records). |
| `document/How_to_use.md`, `動作原理.md`, `拡張の手引き.md`, `repl-adapter-guide.md` | Use, the order things are called in, extending, writing a REPL adapter (Japanese; to follow). |
| `document/verification/` | This directory. |
| `work_history/課題.md`, `next_step.md`, `xipe_totec_spec_v0.4.html` | The record to 2026-10-10 (Japanese): open issues, plans, the draft spec. Not added to. |
