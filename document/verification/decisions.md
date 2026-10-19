# Decisions

Every decision in force, by layer: its name, what it decides in one line, its home record (in this directory), and the sections of
`Old.md` (Japanese; kept locally as `work_history/旧Old.md`, not in git) it came from. Decisions after 2026-10-10 came from commits
(named by hash) and `document/範囲.md`. Then the proposals that were withdrawn, and what replaced them.

## Evaluation model

| Decision | What | Home | Earlier |
|---|---|---|---|
| D-referential-transparency | the functions evaluated are taken as referentially transparent; a row made again gives the same value. It is asked of the function evaluated, not of where its arguments came from | [`lib/core.exs`](lib-core.exs.md) | §35.1 (1–3), README P1 |
| D-named-rows-only | only the calc rows named in a request are evaluated: no downstream, no upstream, no call embedded for a reference; rows not evaluated (`skipped`) are not written to the Book | [`lib/core.exs`](lib-core.exs.md) | §36 (replaces §4.1, §35.1-5) |
| D-plan-run-apply | Core plans (pure) → the Evaluator runs (side effects) → Core applies the results (pure). Core knows no language syntax: an entry carries module/name/arity and arguments as text. Values crossing into Core are JSON-safe (ISO 8601 strings, `repr`/`compare` as strings, `bin` as base64) | [`lib/core.exs`](lib-core.exs.md) | §4.4, §28 B, §11.1 |
| D-reference-values | a `⟦id⟧` becomes the referenced row's `result` text only when it is `exact`; a row evaluated earlier in the same pass is passed as its session variable `xt_<id>`; anything else (unevaluated, `binary`, `unsupported`) cannot be passed, and the row is `skipped` with the reason | [`lib/core.exs`](lib-core.exs.md) | §4.4, §22, §51 (X-2) |
| D-effect-classes | side-effect classes (`pure`/`reads`/`writes`) are trusted only when a person set them (`effect/set`); unclassified rows are not evaluated; `writes` (and `unknown`) only with `include_writes`; a row left out says why (`not_run`) | [`lib/core.exs`](lib-core.exs.md) | §4.2, §16.2, §18, §33, README P1 |
| D-arity-set | how many arguments a function with default arguments accepts is decided by a person (`arity/set`); the scanner only shows it when a call misses | [`lib/core.exs`](lib-core.exs.md) | §53 |
| D-one-pass-one-repl | one evaluation (a pass) starts its own REPL and closes it; nothing — session, bindings — is carried to the next pass; there is no `lost` state | [`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md) | §35.1 (3–4), §35.2, §11.4 |
| D-hang-handling | every entry has one fixed deadline (its timeout + a padding); past it the session is interrupted (SIGINT, when the adapter says `interruptible`) then killed with its whole process group, that entry is `session_hung` and the rest of the pass `aborted` | [`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md) | §14.2, §23, §51 |
| D-languages-per-pass | the rows of one request are grouped by language, one REPL per language, run in parallel; a reference across languages is not evaluated (`not_run`) | [`lib/runner.exs`](lib-runner.exs.md) | §39 |
| D-compare-basis | the basis of `compare` is the latest result (or `prev` when a person set it); values are compared as terms inside the target, floats within a fixed tolerance; `none`/`same`/`changed`/`skipped` | [`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md) | §11.2, §14.4, §28 C |
| D-repr | `repr` (`exact`/`binary`/`unsupported`) is decided inside the target: values holding pid/port/reference/fun → `unsupported`; an `inspect` that reads back equal (and has no newline) → `exact`; else `binary`. The three words are Core's and mean the same in every language | [`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md) | §28 C, §10.3, §10.5, §11.1, §30.3 |
| D-closed-args | a call whose arguments do not parse is not sent to the REPL; the error is made on Xipe Totec's side | [`lib/repl/eval_template.exs`](lib-repl-eval_template.exs.md) | §14.2 |

## REPL connection

| Decision | What | Home | Earlier |
|---|---|---|---|
| D-text-repl | evaluation automates what a person does at a REPL: write the call to its standard input, read the printed result. No distributed Erlang, no PTY | [`lib/repl/sender.exs`](lib-repl-sender.exs.md) | §10 (withdraws §6, §28 D/F) |
| D-markers | fixed markers, the same in every language: `XT_BEGIN_<id>`/`XT_END_<id>` around a `key=value` body printed in one write, `XT_ERROR_<id> timeout\|crash …\|max_heap`, `XT_EXIT <status>`, `XT_READY`, `XT_CALLED_<id>`; everything else on the output is ignored | [`lib/repl/eval/scan.exs`](lib-repl-eval-scan.exs.md) | §10, §10.1, §10.4, §14.3, §35.1-6, §51 |
| D-sender-contract | a Sender pushes one kind of message (`{handle, {:data, binary}}`; the process's end becomes the text `XT_EXIT <status>`), and has `write`, `interrupt` and `kill`; it starts the REPL in its own process group (erlexec) | [`lib/repl/sender_direct.exs`](lib-repl-sender_direct.exs.md) | §10.1, §10.2, §23.1, §35.4 |
| D-ready-probe | a REPL is ready after two steps: its banner (`ready_pattern`, may be none), then the answer `XT_READY` to a probe expression (`ready_probe`) | [`lib/repl/session.exs`](lib-repl-session.exs.md) | §25.3, §35.1-6 |
| D-language-adapter | per language, four swappable modules (launch, eval_template, Eval.Scan by transport × REPL, FieldDrip) and one declaration (`Repl.Language`: extensions, REPL, build tools, scanner, launch options); the Evaluator knows no language | [`lib/repl/language.exs`](lib-repl-language.exs.md) | §10.6–10.9, §13, §34.1, §25.4 |
| D-source-sanitize | loading the target in scripts-mode runs no top-level code: only `defmodule` parts are compiled, at their original paths and lines | [`lib/repl/source_sanitize.exs`](lib-repl-source_sanitize.exs.md) | §6 (Fix F), §14.1 |
| D-embody | for languages without a read-back of their own (OCaml, Haskell), every call is wrapped in `embody`, a fixed module that knows no target and always returns one marker record; it is a separate repository | [`lib/repl/embody.exs`](lib-repl-embody.exs.md) | §30, §38, §44, embody `ReadMe.md` |
| D-ocaml-adapter | the plain `ocaml` toplevel + `embody.ml` (its own `Toploop`); files loaded with top-level effects blanked, retried after their dependencies; dune: dependencies from `dune ocaml top`, own code from source, wrapped libraries by aliases | [`lib/repl/language/ocaml.exs`](lib-repl-language-ocaml.exs.md) | §38, §42, §43 |
| D-haskell-adapter | GHCi + `embody.hs`, one entry as `let` bindings so `-fdefer-type-errors` applies; cabal / stack only lend the environment (`cabal exec`, `stack exec`) | [`lib/repl/language/haskell.exs`](lib-repl-language-haskell.exs.md) | §45, §46, §47 |

## Scanning and the Book

| Decision | What | Home | Earlier |
|---|---|---|---|
| D-identity | IDs are surrogate keys (ULIDs), names natural keys; a rescan keeps an ID only on an exact match of (path, module, name, arity/anykey); a function gone is a tombstone, and does not come back | [`lib/identity.exs`](lib-identity.exs.md) | §4.5, README P3, `範囲.md` |
| D-scanners | a file is read by its language's Scanners in order of preference: Elixir through a language server (tezcatl's `/lsp`, else elixir-ls started by itself) then its own parser; OCaml and Haskell from text (no ocamllsp, no HLS). Cards follow the disk | [`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md) | §21.4, §42.4, §46.3, README |
| D-references-list | the list of who calls a function comes from the static links (`:links`, `graph/neighbors`) after a full scan; rewriting the source (renames) is the editor's | [`lib/graph_query.exs`](lib-graph_query.exs.md) | §21, §21.1 (withdraws linked editing) |
| D-address | an address is a set of columns matched as a filter (`file`, `module`, `name`, `arity`/`anykey`, `row` …); one match is the target, several are candidates; a value that is neither number nor string is refused | [`lib/address.exs`](lib-address.exs.md) | §9, §56.1 |
| D-card-shape | `card/get` returns a card (node + calls + links) whatever the address names, a row included; `card/list` returns every function with its file and line | [`lib/dispatch.exs`](lib-dispatch.exs.md) | §20, e70e1d1 |
| D-store | the Book is append-only JSON Lines; a torn last line is skipped and the next write starts on a new line; writes take a lock that records its owner; the server catches up with the CLI's writes before each request and before writing; failures are results, not exceptions | [`lib/store.exs`](lib-store.exs.md) | §2, §49, §55, §56.2, 3b39709 |
| D-show-failed | a row whose evaluation failed is shown as the failure and its reason, with the previous value apart; the value is not erased | [`lib/show.exs`](lib-show.exs.md) | §52 |
| D-git-provenance | each evaluated row records the commit, its time and whether the tree was dirty | [`lib/git_ctx.exs`](lib-git_ctx.exs.md) | §11.6, §16.5, README P2 |

## Commands

| Decision | What | Home | Earlier |
|---|---|---|---|
| D-command-list | input → command list → action: a command list is data in the wire shape (`[{method, params}]`), `$<n>.<path>` refers to an earlier result at run time, failures do not stop the list; the pseudo-method `eval` is the one operation that uses a REPL; a written but empty `call_ids` is refused | [`lib/runner.exs`](lib-runner.exs.md) | §12, §16.5, §37.1, §54 |
| D-pipeline | combinations of commands are data (`pipelines.json`): `eval/run` = `eval`, `row/update` = `edit` then `eval` of that row alone | [`lib/pipeline.exs`](lib-pipeline.exs.md) | §15, §37 |
| D-cli-values | in `xipe do`, `[...]` is always a list, a bare value with commas is a list, anything else a string; `row/add` makes a row only for a node that exists, with the right number of arguments | [`lib/command_line.exs`](lib-command_line.exs.md) | §32 |
| D-method-criteria | methods are added only for: using the target's environment, writing the Book, reading something whole, the minimum to look at it simply; new information comes as columns. Narrowing, sorting and following are the receiver's | [`lib/methods.exs`](lib-methods.exs.md) | `範囲.md` (2026-10-11/12), f59d4d8 |

## Dialogues and the window

| Decision | What | Home | Earlier |
|---|---|---|---|
| D-dialogue-core | a dialogue is a log of `:in` and `:out` entries; a dialogue program answers each `:in` with the next text and two bits (hold, via REPL); programs do not write the Book (commands do); `:pass` runs a line as a command while holding; one list of programs for CLI and server | [`lib/in_out.exs`](lib-in_out.exs.md) | §16.4, §17, §17.1, §17.3, §41.3 |
| D-envelope | WebSocket answers carry `from` (reserved, `null`) and `dialogue` (`hold`, `via_repl`, `text`) besides JSON-RPC's `result`/`error`; text for people is for showing, never for parsing | [`lib/protocol.exs`](lib-protocol.exs.md) | §17.2, §9 |
| D-depends | dependency-chain negotiation: from the deepest step up, "put a value here and evaluate from there up?"; `y <value>` sets it and evaluates the named rows, `n` moves up, nothing happens when the chain is used up | [`lib/dialogue/depends.exs`](lib-dialogue-depends.exs.md) | §16.4, §19 |
| D-search | `search` narrows the declared tables (surface table, `eval_table`) over turns, writes nothing, and passes other commands through while it holds | [`lib/dialogue/search.exs`](lib-dialogue-search.exs.md) | §41.1, §41.2, f59d4d8 |
| D-dialogue-do | `dialogue do`, `dialogue rewrite` and `dialogue update` ask for what is missing, take each answer as the line typed, and wait for y/n before writing | [`lib/dialogue/do.exs`](lib-dialogue-do.exs.md) | f59d4d8, adbce04, 901166d |
| D-input-line | the window sends a line uninterpreted (`input`); Xipe Totec reads it as the CLI would, refuses commands that need a terminal, answers with the CLI's lines, and waits for an evaluation before the next command of the line | [`lib/serve_input.exs`](lib-serve_input.exs.md) | §40, §48 |
| D-help-table | `help` is one `command: description  arguments` a line, from one table for CLI and window | [`lib/help.exs`](lib-help.exs.md) | §40.1 |

## Server and passes

| Decision | What | Home | Earlier |
|---|---|---|---|
| D-serve-project | one GenServer per project holds the Book; passes run in another process, one at a time per project, in order; a request that raises is answered `internal_error` and the server goes on | [`lib/serve_project.exs`](lib-serve_project.exs.md) | §9, §28 E, §37.2, §56.1 |
| D-passes | a running pass is recorded in `passes/` (with its OS pid and start time); rows in it cannot be changed (`row_in_pass`); `eval/status` shows it; `eval/cancel` stops it from CLI or server and records nothing | [`lib/passes.exs`](lib-passes.exs.md) | §51 (X-3), f59d4d8 |
| D-session-record | `xipe start` records its session (pid and OS start time); a command without `<dir>` targets the session's project, else the chosen one | [`lib/session.exs`](lib-session.exs.md) | §49, §31.2 |

## Projects and languages

| Decision | What | Home | Earlier |
|---|---|---|---|
| D-workspace | per-project data lives in `tables/project/<id>_<name>/` (nothing is written into the target); a 3-digit ID, never reused, matched by `project.json`'s `path`; a project is chosen explicitly, never registered by another command | [`lib/workspace.exs`](lib-workspace.exs.md) | §24.1, §24.6, §31 |
| D-surface-table | the file → language/REPL/build tool table is made again whole (no diffs); languages declare their extensions, and only `xipe refresh` puts them into `info.json`; an extension two languages claim gets no language | [`lib/surface_table.exs`](lib-surface_table.exs.md) | §24.3–24.5, §25.4, §26, §34 |
| D-project-env | a project's environment is got by the command `project_env.json` declares for the marker at its root (`env` or `nix` format, as tezcatl's D-project-env), cached with a hash of its watched files | [`lib/project_env.exs`](lib-project_env.exs.md) | §25.6, 0bb3e88 |
| D-project-config | per-project settings in `project.json` over `defaults.json` (`env.path`, `env.refresh`, `eval.timeout`, `eval.boot_timeout`); read at the start of a pass; a default is never rewritten from a dialogue | [`lib/project_config.exs`](lib-project_config.exs.md) | §5, 901166d, 44b4c9c |
| D-log-buffer | the lines said are kept (100, one file for every project, CLI and server), so a dialogue can point back at a file a line named | [`lib/log_buffer.exs`](lib-log_buffer.exs.md) | 901166d |

## Withdrawn

| Proposal | Withdrawn | Replaced by | Earlier |
|---|---|---|---|
| distributed Erlang to the target (`--sname`, cookies, `:erpc.call`), a binding-holding process in the target | 2026-09-18 | D-text-repl | §6, §28 D/F, §10 |
| heartbeat markers (`XT_HEARTBEAT`) to tell a hang from a long computation | 2026-09-22 | D-hang-handling (a fixed deadline, process-group signals) | §10, §10.10, §23 |
| evaluating the affected set (everything downstream of a change, by `dep_hash`) | 2026-09-26 | D-named-rows-only | §4.1, §36 |
| evaluating unresolvable upstream rows automatically in the same pass | 2026-09-26 | D-named-rows-only | §35.1-5, §36 |
| embedding the call of a pure `unsupported` reference (`:inline_call`) | 2026-09-26 | D-named-rows-only, D-reference-values | §4.4, §28 B, §36 |
| a resident REPL across passes; the `lost` state | 2026-09-26 | D-one-pass-one-repl | §28 A, §35.2 |
| linked editing (`edit/propose`, `edit/apply`) | 2026-09-22 | D-references-list | §21 |
| a `:files` table inside the Book | 2026-09-23 | D-surface-table, D-workspace (`tables/`) | §21.3, §24.1 |
| `book.jsonl` relative to the working directory | 2026-09-24 | D-workspace | §24.1, §27-5, §31 |
| extensions declared by FieldDrip modules (`extensions/0` there) | 2026-09-24 | D-language-adapter (`Repl.Language`) | §24.5, §34.1 |
| wrapping each REPL start in `nix develop` | 2026-09-23 | D-project-env | §25.2, §25.6 |
| embody as three files (`embody.yaml`, `write.hs`) naming the target | 2026-09-24 | D-embody | §30.2 |
| a fourth `repr` value; a result-side template column in `calls` | 2026-09-24 | D-embody (observation rows, `cut`) | §30.2 |
| human formatting of cards in the CLI | 2026-09-22 | P7 (the client's job) | §20 |
| `mix.start` for Mix projects | 2026-10-09 | — (ports are set in JSON) | §55 |

## Not yet decided

Kept in `work_history/課題.md` and `document/範囲.md` ("予定"): the doctest export's fresh path and its priority (§9), the trace table
(frozen), converting values across languages (`next_step.md` §2.6), `observeIO` for Haskell, `binary` and float tolerance for OCaml,
choosing a language per row by hand, routing CLI writes through a running server.
