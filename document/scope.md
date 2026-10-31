# Scope

What Xipe Totec promises to work, what it does not promise, what happens outside the promise and what a person does there; then the
work not yet done. tezcatl's scope is in its own repository
([docs/scope.md](https://github.com/Crux-xurC/tezcatl/blob/main/docs/scope.md)).

The "Records" column points at the decision records (`document/verification/`) or the code; "—" where the row itself is the record.

## How to read it (for people and AI reviewing or verifying)

- Something **inside the scope** that does not work is a bug: report it with the steps to reproduce
- Something **outside the scope** that happens as written below is not a bug. Report it only if
  1. something other than what is written happens,
  2. data (`book.jsonl`, the target project's files) is lost or broken in a way not written here, or
  3. going outside is invisible to the person (a silently different result)
- A boundary not in these tables: ask crux whether it is inside or outside before reporting it as a bug; once decided, add a row here
- When the scope changes (outside comes inside or the reverse, something planned is done), change this document. Remove a planned item
  when it is done, and add a row inside the scope for what became a promise

## Inside the scope (promised to work)

| Promise | Records |
|---|---|
| The functions evaluated are taken as **referentially transparent**: a row made again gives the same value. One pass is one REPL session, and nothing is carried to the next | [D-referential-transparency](verification/lib-core.exs.md#d-referential-transparency), [D-one-pass-one-repl](verification/lib-repl-evaluator.exs.md#d-one-pass-one-repl) |
| The target's code runs in its language's REPL. No sandbox, no transaction, no undoing of side effects; `eval/cancel` stops recording a pass but does not undo writes already made outside | README "What it is not", [D-passes](verification/lib-passes.exs.md#d-passes) |
| **Only the rows named are evaluated**; a referenced row is evaluated only when named too | [D-named-rows-only](verification/lib-core.exs.md#d-named-rows-only), `how-to-use.md` §2.6 |
| Languages: Elixir (scripts-mode, mix), OCaml (with dune), Haskell (with cabal, stack) | [D-language-adapter](verification/lib-repl-language.exs.md#d-language-adapter), `how-to-use.md` §9 |
| One calc row runs **at most 5 s and 50,000,000 heap words by default**; over them it is recorded as `timeout` / `max_heap` and the server goes on. The time can be changed per project (`eval.timeout` 100–600000 ms; `eval.boot_timeout` for the REPL's start, 1000–1800000 ms), from the next pass; each pass prints its limit and the file it came from (`eval: limit 5s per row (eval.timeout, <path>/project.json), …`) | [D-project-config](verification/lib-project_config.exs.md#d-project-config), [D-hang-handling](verification/lib-repl-evaluator.exs.md#d-hang-handling); checked with a real iex 2026-10-13 |
| Settings are changed with `dialogue update` (CLI and window), `xipe config`, `config/set`: file → key → value, the file chosen by number from five distinct files the lines said named; only the open project's `project.json` is written — choosing the defaults (`defaults.json`) does not rewrite them; y/n before writing | [D-dialogue-do](verification/lib-dialogue-do.exs.md#d-dialogue-do), [D-project-config](verification/lib-project_config.exs.md#d-project-config) |
| The lines said are kept in `tables/logging_buffer.txt` (100 lines, oldest first out; one file for every project, CLI and server alike): command results, a dialogue's text, answers to the window. A line names a file by putting its path last inside parentheses | [D-log-buffer](verification/lib-log_buffer.exs.md#d-log-buffer) |
| A value's display has no length limit (long lists and strings pass, first evaluation and again) | [D-repr](verification/lib-repl-eval_template.exs.md#d-repr); 10,000-element lists and 5,000-character strings evaluated again, 2026-10-10 |
| A row being evaluated cannot be changed (`row_in_pass`). Passes run one at a time; later ones wait their turn | [D-passes](verification/lib-passes.exs.md#d-passes), [D-serve-project](verification/lib-serve_project.exs.md#d-serve-project) |
| A running pass stops with `eval/cancel` (also while its REPL starts): the REPL is stopped with its process group, nothing of the pass is recorded; a waiting pass is taken out by `pass_id`; either CLI or server can stop a pass the other runs | [D-passes](verification/lib-passes.exs.md#d-passes); checked with a real iex 2026-10-12 |
| `dialogue do <method>` asks for each required argument the line left out, then runs it (CLI and window). Answers are taken as typed; a function can be answered by name (`Calc.add/2`); a list opens with a line holding only `{`, one element a line, and closes with `}`; a method that writes the Book waits for y/n | [D-dialogue-do](verification/lib-dialogue-do.exs.md#d-dialogue-do); checked on the CLI 2026-10-12 |
| `dialogue rewrite` changes one value of a table **without evaluating** (CLI and window): table → row (shown) → column → value. Rewritable are the columns `roster` marks `rewritable` (now `eval_table`'s `args`, `result`, `prev`, `effect`), each by its method (`row/set-args`, `row/set-result`, `row/set-prev`, `effect/set`); y/n first | [D-dialogue-do](verification/lib-dialogue-do.exs.md#d-dialogue-do); checked on the CLI 2026-10-13 |
| Methods' arguments are declared as data (name, kind, required, list); `help`'s argument text is made from them | [D-method-criteria](verification/lib-methods.exs.md#d-method-criteria) |
| `card/list` returns every function (with or without calc rows, in file order). It and each `row/list` row give the definition's place, `path` (from the project's root) and `line` (1-based), as scanned | [D-card-shape](verification/lib-dispatch.exs.md#d-card-shape); checked on the CLI 2026-10-13 |
| The tables `search` reads are declared in one place (`lib/tables.exs`); `roster` gives their names, marks and columns | [D-search](verification/lib-dialogue-search.exs.md#d-search) |
| The CLI and `xipe start` writing the same `book.jsonl` at once do not break it; the server takes in the CLI's lines before its next request | [D-store](verification/lib-store.exs.md#d-store) |
| A request that raises does not take the server down (`internal_error`); broken frames and arguments of the wrong type likewise | [D-serve-project](verification/lib-serve_project.exs.md#d-serve-project) |
| Failures that can happen come back as results, not exceptions: the Book cannot be written (a lock kept, the disk), a hand-editable file (`project.json`, `info.json`, a surface table) cannot be read, a state file cannot be written, a target file cannot be read or has a syntax error — the CLI says it in a line and exits 1, the server answers or notifies with a code and goes on (below, "The Book and state files") | [D-store](verification/lib-store.exs.md#d-store), tests `store_test`, `serve_project_test`, `project_registry_test`, `workspace_test`, `project_test` (2026-10-16) |
| Listens on localhost only; no authentication; a browser's direct connection is refused by `Origin` | [D-serve-project](verification/lib-serve_project.exs.md#d-serve-project), `lib/serve_socket.exs` |
| A project's environment is got by the declaration in `project_env.json` (marker, command, format — written as tezcatl's): the first entry whose marker is at the project's root, its command run there, read as `env` (`{"NAME": "value" \| null}`) or `nix` (`nix print-dev-env --json`, as `nix develop` takes it), saved in `env.json`. A change to the watched files or to the entry is resolved again as `env.refresh` says; a failure or no answer within `timeoutMs` is `env error`, and Xipe Totec's own or the previous environment is used | [D-project-env](verification/lib-project_env.exs.md#d-project-env); checked with Xipe Totec's own flake 2026-10-19 |
| Messages, `help` and code comments are in English (since 2026-10-10); documents are being put into English | [D-help-table](verification/lib-help.exs.md#d-help-table) |
| Xipe Totec is **what uses the target's environment**, gathered. Methods are added only for using the environment, writing the Book, reading something whole, or the minimum to look at it simply; new information comes as columns. Narrowing, sorting and following are the receiver's. No more query methods, no more kinds of `search` turns; **tables and columns may be added** | [D-method-criteria](verification/lib-methods.exs.md#d-method-criteria) |
| From the window (tezcatl): **one line, then its answer** | [D-input-line](verification/lib-serve_input.exs.md#d-input-line), `how-to-use.md` §6.2 |

## Outside the scope (not promised)

"What happens" is how the present implementation behaves; "What to do" is the remedy.

### Source and table drifting apart

| Operation outside | What happens | What to do | Records |
|---|---|---|---|
| Scanning while a function is missing from the source (a half-typed save, commented out, a moved file, a branch switch) | Its calc rows lose it (`show`: `(node gone)`, `row/list`: `linked: false`, evaluation: not run). When the function comes back it gets a new id, and its `effect` is `unknown` again. **It does not revive** | Make the rows again (they give the same value) | [D-identity](verification/lib-identity.exs.md#d-identity) |
| Adding a file | Not scanned or evaluated until `xipe table generate` | `xipe table generate` in a terminal (not from the window) | [D-surface-table](verification/lib-surface_table.exs.md#d-surface-table), `how-to-use.md` §2.2 |
| A file with a syntax error, or one that cannot be read (permissions) | `scan` is `scan_failed` (the file's name and, for a syntax error, the parser's first line — on the CLI too); evaluation is `eval_failed` (every row: scripts-mode loads every file). The Book does not change | Fix it and run again | `lib/project.exs` (2026-10-16) |
| Changing a function's name, module or argument count | Another function (as "missing" above) | Make the rows again | [D-identity](verification/lib-identity.exs.md#d-identity) (matching by body hash, renames and moved files is not implemented) |

### Evaluation

| Operation outside | What happens | What to do | Records |
|---|---|---|---|
| A function over the limit (default 5 s, at most 600 s) | `timeout` (`eval/cancel` to stop sooner) | Raise `eval.timeout` with `dialogue update` | [D-project-config](verification/lib-project_config.exs.md#d-project-config) |
| A project whose start (its build included) is over the limit (default 15 s, at most 1800 s) | `boot_failed` | Raise `eval.boot_timeout`, or build by hand first | same |
| Changing a running pass's limit | No effect (settings are read when a pass starts) | `eval/cancel`, then evaluate again | `lib/runner.exs` |
| Choosing another project's `project.json` or a JSON that is not settings (`info.json` …) in `dialogue update` | Refused, asked again | Open that project (`xipe choice project`) | `lib/dialogue/update.exs` |
| A hand-edited `project.json` that does not read as JSON, or whose groups (`eval` …) are not objects, then `config/set` / `dialogue update` | Refused, nothing written (writing back what could be read would lose the registry's `path` and the other settings). Reading settings, an unreadable file gives the defaults and a number written as a string (`"7000"`) reads as a number. Looking up the registry (`choice project`, that project's commands) refuses an unreadable `project.json` by name (below) | Fix it by hand | [D-project-config](verification/lib-project_config.exs.md#d-project-config) |
| Editing `defaults.json` by hand | Every project's defaults change (unknown keys and values out of range are skipped, falling back to the built-in values) | — | same |
| The CLI and the server writing `logging_buffer.txt` at once | A line may be lost (best effort; no command fails) | — | [D-log-buffer](verification/lib-log_buffer.exs.md#d-log-buffer) |
| `eval/cancel` of a pass run with `--include-writes` | Writes may be left half done (the pass records nothing, but what a function wrote outside stays) | Check it yourself | [D-passes](verification/lib-passes.exs.md#d-passes) |
| Stopping a running scan | No way (`eval/cancel` stops evaluation passes only) | Wait for it | `scan/cancel` is only an idea |
| The REPL falling during a pass (`System.halt` …) | Waits until the deadline (limit + 2 s), then `session_hung`; the rest of the pass `aborted` | Evaluate the rest again | [D-hang-handling](verification/lib-repl-evaluator.exs.md#d-hang-handling) (an unexpected `XT_EXIT` is not read) |
| A pass with many rows | About 170–180 ms a row (301 trivial rows ≈ 55 s, measured 2026-10-10); the results arrive together at the end | Evaluate fewer rows at a time | — |
| A Haskell function throwing an exception whose own message throws (`error (show (1 `div` 0))`), or a value whose `Show` throws on its contents | embody's `crash` line is cut. Depending on the order stdout and stderr arrive, a `crash` with GHCi's message, or the deadline then `session_hung` (the rest `aborted`) | Leave the row out, or fix the exception's message | embody `ReadMe.md` ("Haskell", crux, 2026-10-16) |
| Referring to a `binary` or `unsupported` value | Cannot be passed: `skipped` | Name the referenced row in the same command, or give a value with `dialogue depends` | [D-reference-values](verification/lib-core.exs.md#d-reference-values), `how-to-use.md` §2.6 |
| A list of integers within character codes | Shown as a charlist (`~c"\t\n"`); the value is right | Do not rely on the display | — |
| Evaluating a Mix project while its development server runs | Each pass starts the application with `iex -S mix`, so a port in use gives `boot_failed` (not checked) | Configure separate ports | — |
| References across languages | Not converted (`not_run`) | — | [D-languages-per-pass](verification/lib-runner.exs.md#d-languages-per-pass) |

### The Book and state files

| Operation outside | What happens | What to do | Records |
|---|---|---|---|
| Another process holding `book.jsonl`'s lock for more than 10 s (a CLI write suspended with Ctrl-Z), or `book.jsonl` that cannot be written (disk full, permissions) | Nothing is written. A request answers `book_not_written` (who holds it, or why it cannot be written; nothing changed). A pass ending answers `notify/passCompleted` `ok: false`, `book_not_written` (its results recorded nowhere, not even in the server). A scan records nothing. The CLI prints its results, then a line that nothing was recorded, exit code 1. The server goes on in every case | Resume the stopped process, make room; evaluate the pass again | [D-store](verification/lib-store.exs.md#d-store) (2026-10-16; before, a pass or scan ending took `xipe start` down) |
| Making a registry `project.json` unreadable as JSON | `choice project` and that project's commands refuse, naming the file. The same path is not registered again under another number (it cannot be told whether the unreadable entry is that path). Choosing another project by path refuses while an unreadable entry exists (commands of a project chosen by number look only at its own entry) | Fix it by hand (`{"path": "<the project's directory>"}`) | [D-workspace](verification/lib-workspace.exs.md#d-workspace) (crux, 2026-10-16) |
| Making `info.json` or a project's surface table (`tables/project/<id>_<name>/table`) unreadable | Refused before the command, naming the file and how to make it again. `xipe refresh` makes it from nothing (and says so); `xipe table generate` makes it without the old table | `xipe refresh -a`, `xipe table generate` | [D-surface-table](verification/lib-surface_table.exs.md#d-surface-table), `main.exs` |
| Making those files unreadable while `xipe start` runs | The next request is `internal_error` (with the file's name); the server goes on | Fix them and type again | [D-serve-project](verification/lib-serve_project.exs.md#d-serve-project) |
| A running pass's record (`passes/`) or a stop request cannot be written | That language is not evaluated (`eval_failed`, nothing evaluated) / `not_cancelled` (not stopped) | Fix the cause | [D-passes](verification/lib-passes.exs.md#d-passes) |
| `session.json` cannot be written | `xipe start` runs and says so; other `xipe` commands do not know that session (they use the chosen project) | Fix the cause and start again | [D-session-record](verification/lib-session.exs.md#d-session-record) |
| `XIPE_TOTEC_PORT` that is not a number | `xipe start` refuses in a line | Write 1–65535 | `main.exs` |

### Writing commands

| Operation outside | What happens | What to do | Records |
|---|---|---|---|
| On one line (`xipe do`, a `--` list), a one-element argument written `args=1` | `invalid_params` (passed as a string) | `args=[1]`, or `dialogue do` | [D-cli-values](verification/lib-command_line.exs.md#d-cli-values), `how-to-use.md` §3.3 |
| On one line, a value containing a comma as one element (`[1,2]` as one argument) | Cannot be written (split at the comma) | `dialogue do` (`how-to-use.md` §5.2) | [D-cli-values](verification/lib-command_line.exs.md#d-cli-values) |
| On one line, quotes as in `args=["hi"]` | The quotes go, `hi` is evaluated as a variable: crash | Wrap the quotes too (the shell's rules), or `dialogue do` | [D-cli-values](verification/lib-command_line.exs.md#d-cli-values), `how-to-use.md` §11 |
| On one line, `graph/neighbors` / `graph/export` | `invalid_params` (`address` must be an object) | `dialogue do graph/export` (answer with the function's name) | [D-address](verification/lib-address.exs.md#d-address), `how-to-use.md` §3.2 |
| Having `dialogue do` ask for an optional argument | It does not ask | Write it on the starting line | [D-dialogue-do](verification/lib-dialogue-do.exs.md#d-dialogue-do) |
| A list on one line in `dialogue do` (`{1, 2}`) | Not read as a list (it opens with a line holding only `{`) | One element a line | same |
| `config`, `choice project`, `table generate`, `refresh`, `start` from the window | Refused: "a command to run in a terminal" | Type it in a terminal (settings from the window: `dialogue update`, `config/set`) | [D-input-line](verification/lib-serve_input.exs.md#d-input-line) |

### The window and the server

| Operation outside | What happens | What to do | Records |
|---|---|---|---|
| Sending the next line without waiting for the answer | The lines run at once; a later line may not see the earlier one's results | Put lines that need an order on one line with `--` | [D-input-line](verification/lib-serve_input.exs.md#d-input-line) |
| Using a dialogue (`search`, `dialogue depends`) with two or more tezcatl windows open | The dialogue is shared: another window's line is taken as its answer | Dialogues in one window | [D-dialogue-core](verification/lib-in_out.exs.md#d-dialogue-core) |
| `show` / `row/list` with large values | Values are returned whole (one row of 50,000 elements ≈ 340 KB) | Look in tezcatl's table (it shortens cells) | decided on tezcatl's side |
| `row/remove` of a row others refer to | It goes without a warning; the referring rows' guidance is wrong | — (known, not started) | — |
| Writing with the CLI, then asking the server nothing | The server takes the lines in only at its next request (no notification) | Type something in the window / fetch the table again | [D-store](verification/lib-store.exs.md#d-store) |

### Not targeted

| Operation outside | What happens | What to do | Records |
|---|---|---|---|
| Columns `type` or `hier` in an address | Not implemented: refused as `unsupported_column`, not taken as matching everything | Write `module`, `name`, `arity` (`anykey`), `file`, `row` | [D-address](verification/lib-address.exs.md#d-address) |
| Definitions inside OCaml's nested `module … = struct` | Not read (no card) | — | `lib/scanner/ocaml.exs` |
| OCaml's and Haskell's call relations (links) | Estimated from the text (a local variable named like a top-level function counts as a call) | Do not lean on them too much | [D-scanners](verification/lib-scanner-lsp.exs.md#d-scanners) |
| A file whose `defmodule` cannot be compiled inside Xipe Totec (`use ExUnit.Case` …) | Its module's cards are made; its links cannot be traced, so the old ones stay and it is listed in `link_failures` | — | `lib/scanner/elixir.exs` |
| Learning from notifications that a row or function is gone | Notifications carry only changed rows and functions (`notify/rowChanged`, `notify/nodeChanged`); what disappeared is not sent | Fetch the table again | `lib/serve_project.exs` |
| `graph/export`'s `doctest` format | Written from the values in the table (no new evaluation, existing files not looked at) | Evaluate first | [D-references-list](verification/lib-graph_query.exs.md#d-references-list) |
| Scripts-mode files depending on each other at compile time (structs, macros, `import`) | Loaded in file-name order (the referenced file must come first) | — | [D-source-sanitize](verification/lib-repl-source_sanitize.exs.md#d-source-sanitize) |
| Languages other than Elixir, OCaml, Haskell | No `language` in the table: neither scanned nor evaluated (Clojure, Racket stopped; Java, Python by the scope decision) | — | — |
| Calc rows for `defp`, macros, guards, library functions | `defp` is in the list of references but `row/add` refuses it; macros, guards and library functions are not cards | Call them from a public function | [D-scanners](verification/lib-scanner-lsp.exs.md#d-scanners) |
| Haskell functions returning `IO` | Not run; the type is the display | — (`observeIO` not designed) | [D-haskell-adapter](verification/lib-repl-language-haskell.exs.md#d-haskell-adapter) |
| OCaml: files needing ppx, files of the same name, the `binary` repr, float tolerance in `compare`, a memory limit per row | Not supported. Long values are cut with `...` by the toplevel, so they are not `exact` (estimated) | — | [D-ocaml-adapter](verification/lib-repl-language-ocaml.exs.md#d-ocaml-adapter) |
| A target with only `shell.nix`, or without a `project_env.json` marker at its root | Runs in Xipe Totec's own environment (the target's is not read; directories above are not looked at) | Add a `flake.nix`, or a line to `project_env.json` (for `shell.nix`, a script printing the `env` format) | [D-project-env](verification/lib-project_env.exs.md#d-project-env) |
| An extension two or more languages declare; a file without an extension | `language: nil`, not read | — (a command to decide by hand is planned) | [D-surface-table](verification/lib-surface_table.exs.md#d-surface-table) |
| Several projects in one directory (a monorepo) | Everything under the given path is one project | Register each project | same |
| Using `line` of `card/list` / `row/list` after changing the source | The line is the scan's (it drifts); a function gone has empty `path` and `line` | Scan again | [D-card-shape](verification/lib-dispatch.exs.md#d-card-shape) |
| Scanning with unsaved changes in an editor | Cards follow the disk; shifted lines are detected and read again, but deleting the last function or a change inside a body is missed | Save, then scan | [D-scanners](verification/lib-scanner-lsp.exs.md#d-scanners) |
| elixir-ls's first use in a new environment | Its self-install takes more than 30 s, and that scan falls back to `Scanner.Elixir`; fast from the second | Scan again | — |
| Reading a mix project through the language server | `.elixir_ls/` appears in the target (a departure from "nothing is written into the target") | — | — |
| Elixir calling another language (a Port …) | It runs as a side effect of the function. Dependencies across languages are not in `links`, and a change on the other side is not seen as stale. Xipe Totec evaluates each language's functions separately | Check the connections with the cards, the existing `links` and SQL or the like; pass serialisable values by hand; check the real Port traffic in the target application | — |
| Changing only the arguments with `dialogue rewrite` / `row/set-args` | Not evaluated, so the value stays the old arguments' (nothing marks it stale) | `eval` (both at once: `row/update`) | `lib/dispatch.exs` |
| Rewriting the surface table (`-s`) or an `eval_table` column that is not rewritable in `dialogue rewrite` | Refused, asked again (`-s` has no rewritable column yet) | — (`surface/set` is an idea) | `lib/tables.exs` |
| Writing the new value on `dialogue rewrite`'s starting line | Refused (the value is always asked: on the line it would be split into words) | Type it when asked | `lib/input.exs` |
| Seeing a row's past values, or which rows are stale | No way (they are in `book.jsonl`) | — (planned ideas) | — |

## Work not started, and ideas to reconsider

Unimplemented work inside the scope, kept apart from optional features to reconsider only when a need becomes concrete. "Decided (not
implemented)" has its course set; "Decided, put in when needed" has its form set but waits for a need, with what happens until then;
"Ideas" have no settled form and are not part of the present promise.

### Decided (not implemented)

| What | What changes when it is in | Records |
|---|---|---|
| embody's E-A: one time limit for a whole entry (not set again at each stage); after the time settings (in since 2026-10-13) | Haskell values taking two stages or more no longer end as `session_hung` | — |
| Wording: a note about quotes in `help` for `do`, `row/add`, `row/update` | — | — |
| Values that cannot be passed (`binary` …) settled by a person — no special dialogue: `dialogue rewrite`'s `result` puts one in (the dialogue is in; whether it is enough is checked in the end-to-end tests with tezcatl) | The remedy of "referring to a `binary` or `unsupported` value" above | — |

### Decided, put in when needed

Their form is settled, but they wait until a need appears (for example, people other than the author using Xipe Totec day to day).
Until then, the "Today" column is what happens and what a person keeps in mind.

| What | Today | Records |
|---|---|---|
| When ids are left out and more than 100 rows would be evaluated, show the count and confirm the whole evaluation; default "no"; not without an explicit choice when not interactive | `xipe eval` without ids evaluates every calc row of the project at once, without asking. Name the rows to evaluate | `main.exs` `eval/1` |
| On registering, making the table, starting or evaluating: check the OCaml / Haskell embody adapter, and when missing say in English that functions of that language — pure ones included — cannot be evaluated (scanning, cards and lists still work; with the adapter, Haskell's `IO` actions are still not run) | Nothing is said before evaluating. Without embody, evaluating that language's rows fails (OCaml: every row crashes with `Unbound module Embody`). Clone embody next to Xipe Totec, or set `XIPE_TOTEC_EMBODY_DIR` | [D-embody](verification/lib-repl-embody.exs.md#d-embody), each language's `launch.exs` |
| Say clearly in the CLI's help and at start, in English, what is evaluated, its side effects, and what remains after a cancel | Said in the README ("Before you use it") only; `xipe help` and `xipe start` do not say it | `README.md`, `lib/help.exs` |

### Ideas (form not settled)

Not planned; reconsidered when a need becomes concrete. Not part of the basic scope.

| What | To decide | Records |
|---|---|---|
| `xipe do` notation: `address.module=Calc` (nested by dots), `args:=[…]` (read as JSON) | The two notations. What people type is covered by `dialogue do` (2026-10-12); what is left is one-line `--` lists and scripts, when needed | — |
| Fixing the surface table by hand (`surface/set`: a person decides the language of a file; the entrance is `dialogue rewrite` — one line in the surface table's `writes` in `lib/tables.exs` and it is asked). `surface/diff` is not made (the viewer's job) | How a value set by hand survives `table generate`. When in, "adding a file" above becomes noticeable | — |
| A row's history `row/history` (the minimum to look; past values are only in the Book, so it just returns them — comparing and narrowing are the viewer's) | Whether to show the values before and after a change of arguments together | — |
| `effect/set` for many at once | One by one, or ids chosen on the user's side | — |
| A stale mark as a `row/list` column (record `body_hash` in the row; not a `row/stale` command) | Whether changes of dependencies count | — |
| A status check `xipe status` (the minimum to look; the CLI bundles existing reads; no method added) | — | — |
| A third table for `search` reading `links` (`search -l`): no new turn kind, one more table. When in, "the functions calling this one" from the CLI and the window (today only `graph/neighbors`, not typable with `xipe do` or in the window) | The table's column names; whether to give it as a whole read too | — |
| Converting references across languages automatically | Pass values by hand; see the flow between functions with cards, links and the user's own diagrams or SQL | — |
| Examining values by type, counting by type | The user processes saved data or read results with SQL or the like | — |
| Checking each language adapter's representative and boundary values with fixtures (structs, long lists, floats, nesting) | Kept as work within checking the quality of supported languages | — |
| Matching functions across rescans by `body_hash`, renames and moved files | When in, part of "scanning while a function is missing" comes inside. Today "no revival" is the decision | [D-identity](verification/lib-identity.exs.md#d-identity) |

### Ideas withdrawn (2026-10-11, crux)

Removed by the criteria of [D-method-criteria](verification/lib-methods.exs.md#d-method-criteria); what replaces each is in the
second column.

| What | Instead |
|---|---|
| `eval/queue`, `eval/dequeue` | The queue is shown by `eval/status`; taking one out is `eval/cancel <pass_id>` |
| `row/copy` | The receiver reads the row and does `row/add` |
| `row/tag`, `row/list tag=` | Marking and narrowing are the viewer's (tezcatl's table colours and filters); to evaluate a group, give a list of ids |
| `row/stale` (as a command) | A `row/list` column (the idea above) |
| `table list` | Today's `search -s` |
| `surface/diff` | The viewer (tezcatl's `code_diff`, a terminal's `diff`) |
| `effect/set` applied by address to many | Give a list of ids (the idea above) |

To decide apart: whether the three lookups by address (`card/get`, `card/search`, `node/resolve`) become one, and whether `graph/export` moves
out.

### Known and not started, frozen

| What | State | Records |
|---|---|---|
| The Evaluator does not read an unexpected `XT_EXIT` (it waits for the deadline) | low priority | [D-hang-handling](verification/lib-repl-evaluator.exs.md#d-hang-handling) |
| No warning on `row/remove` of a row others refer to | small | — |
| A pass's record (`passes/`) is written after its REPL is ready, so a `row/update` right after a pass starts is not refused (estimated) | small | same |
| A scan's status and `scan/cancel` | Out of scope: a feature apart from a pass's status. A scan is waited for | — |
| Streaming results, more `notify/*`, `dialogue depends` run synchronously over the WebSocket | Out of scope: optional features apart from the basic evaluation path | same |
| `provider/*`, `cell/complete`, `trace/*` | Outside the basic scope; not implemented (`not_implemented`); `trace/*` frozen | same |
| The true hang (where even the inner timeout fails) is not checked on a real machine | to be decided | — |
| embody's E-B (OCaml's `compare` reads `changed`), E-D (OCaml's `sanitized`) | not started | same |
| Putting Haskell's syntax error text into the marker; `compare`'s tolerance and `eval.max_per_pass` as settings; the doctest freshness rule | not decided | — |
| Splitting files and making layers; a version without Nix | to come | — |
