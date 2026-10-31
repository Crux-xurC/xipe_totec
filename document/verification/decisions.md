# Decisions

Every decision in force, by layer: its name, what it decides in one line, its home record (in this directory), and its public source
when it has one (a commit by hash, the README's principles, `document/scope.md`; "—" otherwise). Then the proposals that were withdrawn,
and what replaced them.

## Evaluation model

| Decision | What | Home | Source |
|---|---|---|---|
| D-referential-transparency | the functions evaluated are taken as referentially transparent; a row made again gives the same value. It is asked of the function evaluated, not of where its arguments came from | [`lib/core.exs`](lib-core.exs.md) | README P1 |
| D-named-rows-only | only the calc rows named in a request are evaluated: no downstream, no upstream, no call embedded for a reference; rows not evaluated (`skipped`) are not written to the Book | [`lib/core.exs`](lib-core.exs.md) | — |
| D-plan-run-apply | Core plans (pure) → the Evaluator runs (side effects) → Core applies the results (pure). Core knows no language syntax: an entry carries module/name/arity and arguments as text. Values crossing into Core are JSON-safe (ISO 8601 strings, `repr`/`compare` as strings, `bin` as base64) | [`lib/core.exs`](lib-core.exs.md) | — |
| D-reference-values | a `⟦id⟧` becomes the referenced row's `result` text only when it is `exact`; a row evaluated earlier in the same pass is passed as its session variable `xt_<id>`; anything else (unevaluated, `binary`, `unsupported`) cannot be passed, and the row is `skipped` with the reason | [`lib/core.exs`](lib-core.exs.md) | — |
| D-effect-classes | side-effect classes (`pure`/`reads`/`writes`) are trusted only when a person set them (`effect/set`); unclassified rows are not evaluated; `writes` (and `unknown`) only with `include_writes`; a row left out says why (`not_run`) | [`lib/core.exs`](lib-core.exs.md) | README P1 |
| D-arity-set | how many arguments a function with default arguments accepts is decided by a person (`arity/set`); the scanner only shows it when a call misses | [`lib/core.exs`](lib-core.exs.md) | — |
| D-one-pass-one-repl | one evaluation (a pass) starts its own REPL and closes it; nothing — session, bindings — is carried to the next pass; there is no `lost` state | [`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md) | — |
| D-hang-handling | every entry has one fixed deadline (its timeout + a padding); past it the session is interrupted (SIGINT, when the adapter says `interruptible`) then killed with its whole process group, that entry is `session_hung` and the rest of the pass `aborted` | [`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md) | — |
| D-languages-per-pass | the rows of one request are grouped by language, one REPL per language, run in parallel; a reference across languages is not evaluated (`not_run`) | [`lib/runner.exs`](lib-runner.exs.md) | — |
| D-compare-basis | the basis of `compare` is the latest result (or `prev` when a person set it); values are compared as terms inside the target, floats within a fixed tolerance; `none`/`same`/`changed`/`skipped` | [`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md) | — |
| D-repr | `repr` (`exact`/`binary`/`unsupported`) is decided inside the target: values holding pid/port/reference/fun → `unsupported`; an `inspect` that reads back equal (and has no newline) → `exact`; else `binary`. The three words are Core's and mean the same in every language | [`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md) | — |
| D-closed-args | a call whose arguments do not parse is not sent to the REPL; the error is made on Xipe Totec's side | [`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md) | — |

## REPL connection

| Decision | What | Home | Source |
|---|---|---|---|
| D-text-repl | evaluation automates what a person does at a REPL: write the call to its standard input, read the printed result. No distributed Erlang, no PTY | [`lib/repl/sender.exs`](lib-repl-sender.exs.md) | — |
| D-markers | fixed markers, the same in every language: `XT_BEGIN_<id>`/`XT_END_<id>` around a `key=value` body printed in one write, `XT_ERROR_<id> timeout\|crash …\|max_heap`, `XT_EXIT <status>`, `XT_READY`, `XT_CALLED_<id>`; everything else on the output is ignored | [`lib/repl/eval/scan.exs`](lib-repl-eval-scan.exs.md) | — |
| D-sender-contract | a Sender pushes one kind of message (`{handle, {:data, binary}}`; the process's end becomes the text `XT_EXIT <status>`), and has `write`, `interrupt` and `kill`; it starts the REPL in its own process group (erlexec) | [`lib/repl/sender_direct.exs`](lib-repl-sender_direct.exs.md) | — |
| D-ready-probe | a REPL is ready after two steps: its banner (`ready_pattern`, may be none), then the answer `XT_READY` to a probe expression (`ready_probe`) | [`lib/repl/session.exs`](lib-repl-session.exs.md) | — |
| D-language-adapter | per language, four swappable modules (launch, eval_template, Eval.Scan by transport × REPL, FieldDrip) and one declaration (`Repl.Language`: extensions, REPL, build tools, scanner, launch options); the Evaluator knows no language | [`lib/repl/language.exs`](lib-repl-language.exs.md) | — |
| D-source-sanitize | loading the target in scripts-mode runs no top-level code: only `defmodule` parts are compiled, at their original paths and lines | [`lib/repl/source_sanitize.exs`](lib-repl-source_sanitize.exs.md) | — |
| D-embody | for languages without a read-back of their own (OCaml, Haskell), every call is wrapped in `embody`, a fixed module that knows no target and always returns one marker record; it is a separate repository | [`lib/repl/embody.exs`](lib-repl-embody.exs.md) | embody `ReadMe.md` |
| D-ocaml-adapter | the plain `ocaml` toplevel + `embody.ml` (its own `Toploop`); files loaded with top-level effects blanked, retried after their dependencies; dune: dependencies from `dune ocaml top`, own code from source, wrapped libraries by aliases | [`lib/repl/language/ocaml.exs`](lib-repl-language-ocaml.exs.md) | — |
| D-haskell-adapter | GHCi + `embody.hs`, one entry as `let` bindings so `-fdefer-type-errors` applies; cabal / stack only lend the environment (`cabal exec`, `stack exec`) | [`lib/repl/language/haskell.exs`](lib-repl-language-haskell.exs.md) | — |

## Scanning and the Book

| Decision | What | Home | Source |
|---|---|---|---|
| D-identity | IDs are surrogate keys (ULIDs), names natural keys; a rescan keeps an ID only on an exact match of (path, module, name, arity/anykey); a function gone is a tombstone, and does not come back | [`lib/identity.exs`](lib-identity.exs.md) | README P3, `scope.md` |
| D-scanners | a file is read by its language's Scanners in order of preference: Elixir through a language server (tezcatl's `/lsp`, else elixir-ls started by itself) then its own parser; OCaml and Haskell from text (no ocamllsp, no HLS). Cards follow the disk | [`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md) | README |
| D-references-list | the list of who calls a function comes from the static links (`:links`, `graph/neighbors`) after a full scan; rewriting the source (renames) is the editor's | [`lib/graph_query.exs`](lib-graph_query.exs.md) | — |
| D-address | an address is a set of columns matched as a filter (`file`, `module`, `name`, `arity`/`anykey`, `row` …); one match is the target, several are candidates; a value that is neither number nor string is refused | [`lib/address.exs`](lib-address.exs.md) | — |
| D-card-shape | `card/get` returns a card (node + calls + links) whatever the address names, a row included; `card/list` returns every function with its file and line | [`lib/dispatch.exs`](lib-dispatch.exs.md) | e70e1d1 |
| D-store | the Book is append-only JSON Lines; a torn last line is skipped and the next write starts on a new line; writes take a lock that records its owner; the server catches up with the CLI's writes before each request and before writing; failures are results, not exceptions | [`lib/store.exs`](lib-store.exs.md) | 3b39709 |
| D-show-failed | a row whose evaluation failed is shown as the failure and its reason, with the previous value apart; the value is not erased | [`lib/show.exs`](lib-show.exs.md) | — |
| D-git-provenance | each evaluated row records the commit, its time and whether the tree was dirty | [`lib/git_ctx.exs`](lib-git_ctx.exs.md) | README P2 |

## Commands

| Decision | What | Home | Source |
|---|---|---|---|
| D-command-list | input → command list → action: a command list is data in the wire shape (`[{method, params}]`), `$<n>.<path>` refers to an earlier result at run time, failures do not stop the list; the pseudo-method `eval` is the one operation that uses a REPL; a written but empty `call_ids` is refused | [`lib/runner.exs`](lib-runner.exs.md) | — |
| D-pipeline | combinations of commands are data (`pipelines.json`): `eval/run` = `eval`, `row/update` = `edit` then `eval` of that row alone | [`lib/pipeline.exs`](lib-pipeline.exs.md) | — |
| D-cli-values | in `xipe do`, `[...]` is always a list, a bare value with commas is a list, anything else a string; `row/add` makes a row only for a node that exists, with the right number of arguments | [`lib/command_line.exs`](lib-command_line.exs.md) | — |
| D-method-criteria | methods are added only for: using the target's environment, writing the Book, reading something whole, the minimum to look at it simply; new information comes as columns. Narrowing, sorting and following are the receiver's | [`lib/methods.exs`](lib-methods.exs.md) | `scope.md` (2026-10-11/12), f59d4d8 |

## Dialogues and the window

| Decision | What | Home | Source |
|---|---|---|---|
| D-dialogue-core | a dialogue is a log of `:in` and `:out` entries; a dialogue program answers each `:in` with the next text and two bits (hold, via REPL); programs do not write the Book (commands do); `:pass` runs a line as a command while holding; one list of programs for CLI and server | [`lib/in_out.exs`](lib-in_out.exs.md) | — |
| D-envelope | WebSocket answers carry `from` (reserved, `null`) and `dialogue` (`hold`, `via_repl`, `text`) besides JSON-RPC's `result`/`error`; text for people is for showing, never for parsing | [`lib/protocol.exs`](lib-protocol.exs.md) | — |
| D-depends | dependency-chain negotiation: from the deepest step up, "put a value here and evaluate from there up?"; `y <value>` sets it and evaluates the named rows, `n` moves up, nothing happens when the chain is used up | [`lib/dialogue/depends.exs`](lib-dialogue-depends.exs.md) | — |
| D-search | `search` narrows the declared tables (surface table, `eval_table`) over turns, writes nothing, and passes other commands through while it holds | [`lib/dialogue/search.exs`](lib-dialogue-search.exs.md) | f59d4d8 |
| D-dialogue-do | `dialogue do`, `dialogue rewrite` and `dialogue update` ask for what is missing, take each answer as the line typed, and wait for y/n before writing | [`lib/dialogue/do.exs`](lib-dialogue-do.exs.md) | f59d4d8, adbce04, 901166d |
| D-input-line | the window sends a line uninterpreted (`input`); Xipe Totec reads it as the CLI would, refuses commands that need a terminal, answers with the CLI's lines, and waits for an evaluation before the next command of the line | [`lib/serve_input.exs`](lib-serve_input.exs.md) | — |
| D-help-table | `help` is one `command: description  arguments` a line, from one table for CLI and window | [`lib/help.exs`](lib-help.exs.md) | — |

## Server and passes

| Decision | What | Home | Source |
|---|---|---|---|
| D-serve-project | one GenServer per project holds the Book; passes run in another process, one at a time per project, in order; a request that raises is answered `internal_error` and the server goes on | [`lib/serve_project.exs`](lib-serve_project.exs.md) | — |
| D-passes | a running pass is recorded in `passes/` (with its OS pid and start time); rows in it cannot be changed (`row_in_pass`); `eval/status` shows it; `eval/cancel` stops it from CLI or server and records nothing | [`lib/passes.exs`](lib-passes.exs.md) | f59d4d8 |
| D-session-record | `xipe start` records its session (pid and OS start time); a command without `<dir>` targets the session's project, else the chosen one | [`lib/session.exs`](lib-session.exs.md) | — |

## Projects and languages

| Decision | What | Home | Source |
|---|---|---|---|
| D-workspace | per-project data lives in `tables/project/<id>_<name>/` (nothing is written into the target); a 3-digit ID, never reused, matched by `project.json`'s `path`; a project is chosen explicitly, never registered by another command | [`lib/workspace.exs`](lib-workspace.exs.md) | — |
| D-surface-table | the file → language/REPL/build tool table is made again whole (no diffs); languages declare their extensions, and only `xipe refresh` puts them into `info.json`; an extension two languages claim gets no language | [`lib/surface_table.exs`](lib-surface_table.exs.md) | — |
| D-project-env | a project's environment is got by the command `project_env.json` declares for the marker at its root (`env` or `nix` format, as tezcatl's D-project-env), cached with a hash of its watched files | [`lib/project_env.exs`](lib-project_env.exs.md) | 0bb3e88 |
| D-project-config | per-project settings in `project.json` over `defaults.json` (`env.path`, `env.refresh`, `eval.timeout`, `eval.boot_timeout`); read at the start of a pass; a default is never rewritten from a dialogue | [`lib/project_config.exs`](lib-project_config.exs.md) | 901166d, 44b4c9c |
| D-log-buffer | the lines said are kept (100, one file for every project, CLI and server), so a dialogue can point back at a file a line named | [`lib/log_buffer.exs`](lib-log_buffer.exs.md) | 901166d |

## Withdrawn

| Proposal | Withdrawn | Replaced by | Source |
|---|---|---|---|
| distributed Erlang to the target (`--sname`, cookies, `:erpc.call`), a binding-holding process in the target | 2026-09-18 | D-text-repl | — |
| heartbeat markers (`XT_HEARTBEAT`) to tell a hang from a long computation | 2026-09-22 | D-hang-handling (a fixed deadline, process-group signals) | — |
| evaluating the affected set (everything downstream of a change, by `dep_hash`) | 2026-09-26 | D-named-rows-only | — |
| evaluating unresolvable upstream rows automatically in the same pass | 2026-09-26 | D-named-rows-only | — |
| embedding the call of a pure `unsupported` reference (`:inline_call`) | 2026-09-26 | D-named-rows-only, D-reference-values | — |
| a resident REPL across passes; the `lost` state | 2026-09-26 | D-one-pass-one-repl | — |
| linked editing (`edit/propose`, `edit/apply`) | 2026-09-22 | D-references-list | — |
| a `:files` table inside the Book | 2026-09-23 | D-surface-table, D-workspace (`tables/`) | — |
| `book.jsonl` relative to the working directory | 2026-09-24 | D-workspace | — |
| extensions declared by FieldDrip modules (`extensions/0` there) | 2026-09-24 | D-language-adapter (`Repl.Language`) | — |
| wrapping each REPL start in `nix develop` | 2026-09-23 | D-project-env | — |
| embody as three files (`embody.yaml`, `write.hs`) naming the target | 2026-09-24 | D-embody | — |
| a fourth `repr` value; a result-side template column in `calls` | 2026-09-24 | D-embody (observation rows, `cut`) | — |
| human formatting of cards in the CLI | 2026-09-22 | P7 (the client's job) | — |
| `mix.start` for Mix projects | 2026-10-09 | — (ports are set in JSON) | — |

## Not yet decided

Kept in `document/scope.md` ("Work not started"): the doctest export's fresh path and its priority, the trace table
(frozen), converting values across languages, `observeIO` for Haskell, `binary` and float tolerance for OCaml,
choosing a language per row by hand, routing CLI writes through a running server.
