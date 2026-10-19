# Extending Xipe Totec

**The question this document answers**: someone who wants to add a language or a command to Xipe Totec (and the AI they work with) —
what do they start from, and what behaviour must they meet?

Xipe Totec is a tool for functional-language projects and also a base on which anyone can put languages and commands. This document is
modelled on the steps actually taken when OCaml and Haskell were added on 2026-09-27
([D-ocaml-adapter](verification/lib-repl-language-ocaml.exs.md#d-ocaml-adapter),
[D-haskell-adapter](verification/lib-repl-language-haskell.exs.md#d-haskell-adapter)). What it says was checked against the code of the
time; if you find a disagreement, trust the code and fix this.

---

## 0. For people working with an AI

Have the AI read this document and `CLAUDE.md` first, and hold it to three things:

1. **Check the real REPL before implementing** (§2.2). A REPL's behaviour written from knowledge is wrong. For OCaml, "loading the
   compiler libraries makes type errors unreadable", and for Haskell, "`-fdefer-type-errors` works only on `let` bindings", were found only
   by checking; written from knowledge, neither would have worked
2. **Do not touch the real environment**. Xipe Totec keeps its state (`tables/`, `info.json`) relative to `__DIR__`, so to try something,
   copy it to a work directory first (`CLAUDE.md`, "trying it for real"). Pass embody with `XIPE_TOTEC_EMBODY_DIR`
3. **Write down what was decided**. When the implementation fills a gap in the spec ("left out means `id`" …), write the decision in the
   record of its main file (`document/verification/`, an anchor `d-<name>`) and a row in `document/verification/decisions.md`: what was
   checked, what was decided, what is left. Commit and push only when asked

---

## 1. Promises not to break

Adding a language or a command does not change these. If one needs to change, that is a change of design, not an extension: talk first.

| Promise | What | Records |
|---|---|---|
| Only the named calc rows are evaluated | Upstream and downstream rows are never evaluated by themselves. The Book is a record in time | [D-named-rows-only](verification/lib-core.exs.md#d-named-rows-only) |
| The Book is only appended to | `Store.persist_diff/4` appends the difference to `book.jsonl`; nothing is rewritten | [D-store](verification/lib-store.exs.md#d-store) |
| Side-effect classes are trusted only when the user set them | A function without `effect/set` is not evaluated; `writes` only with `--include-writes` | [D-effect-classes](verification/lib-core.exs.md#d-effect-classes), README P1 |
| The output contract | Between `XT_BEGIN_<id>` … `XT_END_<id>`: `repr=`, `type=`, `compare=`, `display=`; or `XT_ERROR_<id> timeout` / `crash <one line>`. The same in every language | [D-markers](verification/lib-repl-eval-scan.exs.md#d-markers), embody's `ReadMe.md` |
| The three words of `repr` | `exact` (evaluating its source gives the value back), `binary`, `unsupported`. Core reads them (embedding into `⟦id⟧`, comparing with the previous value), so their meaning does not change by language | [D-repr](verification/lib-repl-eval_template.exs.md#d-repr) |
| Loading runs none of the target's side effects | A script's top level, `main`, … | [D-source-sanitize](verification/lib-repl-source_sanitize.exs.md#d-source-sanitize) |
| Evaluating does not go to the network | localhost only; build tools get `--offline` or the like | spec §16.1, [D-haskell-adapter](verification/lib-repl-language-haskell.exs.md#d-haskell-adapter) |
| tezcatl does not interpret text for people | tezcatl sends one line by `input` and shows the answer's `dialogue.text` as it is | [D-envelope](verification/lib-protocol.exs.md#d-envelope), tezcatl's D-xipe-dialogue |

---

## 2. Adding a language

### 2.1 The parts to add

| Part | Where | Behaviour asked | Model |
|---|---|---|---|
| The language's declaration | `lib/repl/language/<language>.exs` (the file name is the language's name; the `Repl.Language` behaviour) | `extensions/0`, `repl/0`, `build_tools/0`, `scanner/0`, `adapter/0`, `launch_opts/3` (`{how to start, cleanup}`) | `ocaml.exs`, `haskell.exs` |
| launch | `lib/repl/<language>/launch.exs` | `build/1` returns a JSON-able message: `argv`, `env`, `cwd`, `files`, `ready_pattern` (the banner, `nil` if none), `ready_probe` (input that makes it print `XT_READY`; split the marker in the source so it is not mistaken for the input's echo), `exit_input`, `interruptible` | `ocaml/launch.exs` |
| eval_template | `lib/repl/<language>/eval_template.exs` | `build(entry)` returns the input text for one entry. `entry` has `call_id`, `module`, `name`, `args` (references resolved), `limits` (`timeout` in ms, `max_heap_words`), `basis` (`{:exact, previous}` …). The variable bound is `xt_` + `call_id` (anything but letters, digits and `_` becomes `_`, as Core's `binding_name/1`) | `ocaml/eval_template.exs` |
| Eval.Scan | `lib/repl/eval/scan/<transport>/<REPL>.exs` | `clean/1` removes the `XT_EXIT` line from the output. Over a pipe, delegating to iex's is enough | `scan/direct/ocaml.exs` |
| FieldDrip | `lib/repl/eval/field_drip/<language>.exs` | Reads the body's `key=value` lines. If the output contract is kept, delegating to Elixir's is enough | `field_drip/ocaml.exs` |
| Scanner | `lib/scanner/<language>.exs` (the `XipeTotec.Scanner` behaviour) | `scan_defs/3` (definitions → nodes) and `scan_links_report/3` (calls). §2.5 | `scanner/ocaml.exs` |
| embody | a separate repository, `~/my_app/embody/embody.<extension>` | Always returns one entry in the output contract's form. §2.4 | `embody.ml`, `embody.hs` |
| How the target's environment is got (a project layer, not a language; also for tools other than Nix) | one line in `project_env.json` (`marker`, `command`, `format` `env` or `nix`, `watch` if needed), kept in the same form as tezcatl's `project_env.json`. For any other tool, write a script that prints the `env` format (`{"NAME": "value" \| null}`) | It runs at the target's root and prints only JSON; a failure is an exit code and stderr | `how-to-use.md` §4.3, [D-project-env](verification/lib-project_env.exs.md#d-project-env) |

What each `Repl.Language` callback means is in `lib/repl/language.exs`'s moduledoc. The four parts (launch, eval_template, Eval.Scan,
FieldDrip) are chosen by `Runner` from the surface table's language and handed to `Repl.Evaluator`. `Evaluator`, `Session` and `Core` know no
language: do not touch them ([D-language-adapter](verification/lib-repl-language.exs.md#d-language-adapter)).

### 2.2 Before implementing: check the REPL

In a work directory, put a small target gathering what to check (a file with top-level side effects, an unexported function, an infinite
structure, a value that cannot be shown, a loop that allocates nothing, a function that throws), connect the REPL by a pipe and check.
Write and read with Python's `subprocess` or Xipe Totec's `Repl.Sender.Direct`. What to check:

| Item | What to look at | OCaml | Haskell |
|---|---|---|---|
| Start | Whether a banner or prompt appears over the pipe; whether `ready_probe`'s output arrives without a flush | `ocaml -init <file>`; the prompt `# ` appears (harmless) | `ghci -v0` prints nothing |
| Loading | Whether the target's files load without running top-level side effects; dependency order | `mod_use` of copies with the effects blanked; retry on failure | just `:load` the files (`main` is not run) |
| Evaluation and display | Whether type and value come as one line of text; whether reading back can be judged | `Toploop.use_input`'s display `val x : type = value`; evaluate again and `=` | `Read`, `Show`, `Typeable`; whether an instance exists is deferred to run time inside a `let` |
| Failure | Whether exceptions, type errors and syntax errors come back in one line instead of waiting for input | the call is passed as a string, so an unclosed argument does not hang | a syntax error comes back as `Variable not in scope` |
| Time limit | Whether an infinite loop (one that allocates nothing too) stops | `Unix.setitimer` (SIGALRM) | `System.Timeout.timeout` |
| SIGINT | Whether only the evaluation stops and the REPL reads on (`interruptible`) | `Interrupted.` | `Interrupted.` |

Write what the check found, as this table filled in, in the record of the language's declaration (`document/verification/`).

### 2.3 Behaviour asked (evaluation)

`Repl.Evaluator` repeats "write, then wait for a marker" for each entry; past the deadline (`timeout` + 2 s, 7 s in all by default) it takes
the REPL as stuck, sends SIGINT, then SIGKILL if that does not work, and makes the rest `aborted`
([D-hang-handling](verification/lib-repl-evaluator.exs.md#d-hang-handling)). So:

- **Every entry must end in a marker before the deadline** — whether it is a type error, a syntax error, a missing instance, an exception or
  an infinite loop. If the REPL starts waiting for more input (an unclosed bracket …), that entry and every one after it are lost. OCaml
  passes the call as a string, and Haskell binds it with `let` before sending the line that runs it, to prevent this
- **Print one entry's result in one write**: other output landing in between makes it unreadable
- **Later entries of the same pass can refer to an earlier result as `xt_<id>`**: Core embeds a reference evaluated in the same pass as that
  variable name
- **Wrap arguments in parentheses**, so an embedded value such as `-1` or `Some 2` does not change how the expression binds
- `compare` evaluates the previous value (when `exact`) and compares. A language that cannot handle a `binary` previous value does not
  compare (`none`)
- A language that cannot have a memory limit need not (a stuck REPL is killed). OCaml and Haskell have none
- **Starting waits `eval.boot_timeout`** (default 15 s, per project — [D-project-config](verification/lib-project_config.exs.md#d-project-config)).
  With a build before the start (dune, cabal), a first build over it makes the start fail (`work_history/課題.md` §3)

### 2.4 Writing embody

embody is a fixed module that knows no target. It is loaded into the REPL, takes the line (or lines) the caller sends, and prints in the
output contract's form. `~/my_app/embody/ReadMe.md` has the shared contract and each language's content
([D-embody](verification/lib-repl-embody.exs.md#d-embody)). The points when writing one:

- **Depend on no target**. Which function to evaluate arrives as text; interpreting it is left to the REPL itself (OCaml's `Toploop`,
  GHCi). Depending on the target at compile time does not work: it would have to be rebuilt per target
- **Write it within the language's standard environment** (OCaml: the toplevel itself + `unix`; Haskell: `base`). Depending on an outside
  package fails to load where the target's environment does not have it
- Values that cannot be fully shown (infinite structures, functions, cycles) still come back, with a finite display and `repr=unsupported`.
  Only values that read back are `exact`
- After adding one, write the "Files" table and the language's section of `embody/ReadMe.md`, and commit to embody's repository (separate
  from Xipe Totec's; Xipe Totec finds it with `lib/repl/embody.exs`)

Some languages hardly need embody (Racket, which has a round trip in its standard). Even then, something must build the output contract
(for Elixir, `lib/repl/eval_template.exs` does).

### 2.5 Writing a Scanner

A Scanner takes definitions (the functions that become cards) and call relations (links) from a file
([D-scanners](verification/lib-scanner-lsp.exs.md#d-scanners)).

- **Definitions**: `%{module:, name:, anykey:, visibility:, span:, body_hash:}`. `(module, name, anykey)` is the natural key: the same
  function keeps its id across rescans ([D-identity](verification/lib-identity.exs.md#d-identity)). `anykey` tells functions of the same
  name in the same module apart (Elixir: the arity; a currying language: `nil`); as an integer it is also the number of arguments (`row/add`
  checks it). `visibility` is whether the REPL can call it (`private`: `row/add` refuses)
- **Call relations**: what is needed is the dependencies between the functions of a file (crux). OCaml and Haskell estimate them from the
  text, with comments and strings blanked. Where a compiler or language server gives them exactly, that is fine (Elixir: the compiler's
  tracer; `Scanner.Lsp`: `callHierarchy`). To use a language server, write a thin dialect over `Scanner.Lsp` (`scanner/lsp/elixir.exs`); a
  server without `callHierarchy` (ocamllsp) gives no call relations
- Declare the Scanners with `scanner/0` (several in order of preference; the first whose `begin/3` accepts)

### 2.6 Build tools

A build tool does not change the REPL, only how it starts. Declaring marker files with `build_tools/0` (`dune-project`, `*.cabal` …)
makes `xipe table generate` fill the surface table's `build_tool` column, which reaches `launch_opts/3` as its second argument.

| Language | Build tool | How the start changes |
|---|---|---|
| Elixir | mix | `iex -S mix` |
| OCaml | dune | dependency libraries read from `dune ocaml top` (without the lines of its own `.cma`); aliases made for wrapped libraries |
| Haskell | cabal, stack | `ghci` started under `cabal exec --offline --` (after `cabal build --offline all`) / `stack exec --` |

In every case Xipe Totec loads the project's own code from source (without side effects). Leaving everything to the build tool's REPL
(`cabal repl` …) is not taken: embody cannot be added, components cannot load together.

### 2.7 Registering, testing, writing down

1. `xipe refresh -a` (reads `lib/repl/language/*.exs` and `lib/repl/eval/scan/<transport>/*.exs`, writes `info.json`). A file put there is
   not used until then (P4)
2. Update the expected list of registered languages and REPLs in `test/info_test.exs`
3. Unit tests `test/<language>_adapter_test.exs` (run without the language's system): the template's form, how it starts, the Scanner's
   definitions and calls. In `./test/run.sh`
4. Live tests `test/live/repl_<language>_test.exs`: excluded when the system is not on PATH (`ExUnit.start(exclude: …)`). Values and types,
   references, failures (exception, type error, syntax error, timeout), comparing with the previous value, no side effects on loading,
   SIGINT. If the target is written to (`_build/` …), copy the fixture to a temp directory first
5. A fixture `test/fixtures/<language>_sample/`. **Watch out for tests that evaluate the repository `.` itself**: a fixture adds a language to
   Xipe Totec itself, and the language of `runner_test`'s "rows with no file" can no longer be decided (they name `language:` explicitly)
6. Go through the CLI on a work copy: `choice project` → `table generate` → `scan` → `do row/add … -- eval` → `eval` again
   (`compare=same`)
7. Documents: the record of the declaration (`document/verification/`), the language's section in `how-to-use.md` §9, "How far it works now"
   in the README, what is left in `document/scope.md`

---

## 3. Adding a command

### 3.0 Before adding: what may be added

Xipe Totec is **what uses the target's environment, gathered** — language servers, REPLs (crux, 2026-10-11). Looking at what it fetches is
each tool's job (the CLI, tezcatl's tables); query commands like SQL are not added. Looking at things simply, without opening a full
environment each time, may still be possible. The same direction as README's P7 (the input experience is the client's) and P9 (states as
columns). See [D-method-criteria](verification/lib-methods.exs.md#d-method-criteria).

Only these four may be added:

1. **What uses the target's environment** (REPL, language server, build)
2. **What writes the Book** (only Xipe Totec keeps it consistent)
3. **Reading something whole** (choosing by a list of ids at most). **New information comes as columns, not commands** (`row/list`'s columns …)
4. **The minimum to look at it simply**. First see whether what exists (`show`, `search`, `eval/status`) is enough; if not, add to the CLI
   side (no new method)

Narrowing, sorting, following and reshaping are the receiver's (tezcatl's table filters and sorts; `jq`, `grep` in a terminal). The query
methods that exist (`card/get`, `card/search`, `node/resolve`, `row/depends`, `row/check`, `graph/*`) are not removed, but no more are added.
The same for `search`: no new kinds of turns. **Tables and columns may be added** (crux, 2026-10-12) — giving information in a clear shape is
Xipe Totec's job, and the whole reads (3) and `search` (4) use the same tables. How each idea was handled: `document/scope.md` ("Work not
started") and `../tezcatl/work_history/ja/コマンドの案.md` §2.

### 3.1 Where to add it

| Kind | Where | What comes with it |
|---|---|---|
| Only reads the Book | one clause in `Dispatch.handle/4` + `Methods` with `route: :dispatch, writes: false` | All of: the CLI (`xipe do`), the WebSocket, the window (a line starting with the method's name); the `help` list |
| Changes the Book (no REPL) | the same, `writes: true` | The same; on the server, `notify/rowChanged` broadcasts and the CLI's warning during a session |
| A combination using the REPL | stages in `pipelines.json` (a new stage in `Pipeline`'s `stage_handlers/0`) + `Methods` with `route: :pipeline, repl: true` | Synchronous on the CLI. On the server the stages before `"eval"` run at once, `"eval"` waits in the pass queue |
| A dialogue over several turns | `lib/dialogue/<name>.exs` (the `Dialogue` behaviour) + registered in `InOut.programs/0` | The CLI (write its entrance yourself), the WebSocket, the window |
| A table to look at, a column rewritable by hand | one table in `lib/tables.exs`'s `all/0` (name, mark, columns, how rows are read), or one line in `writes` (the method that writes that column) | `search`'s turns, `roster`, `dialogue rewrite` (how the value is asked comes from that method's `params`) |
| A per-project setting | `@keys` in `lib/project_config.exs` (choices, or a number with a range) and `@builtin`; the default in `defaults.json` | The list and checks of `xipe config`, `config/set`, `dialogue update`. Users read it with `ProjectConfig.load/1` |
| A file to point a person at | write the file's path last inside the parentheses of a printed line (`(eval.timeout, /…/project.json)`) | It stays in `tables/logging_buffer.txt`, and `dialogue update` offers it by number (`.json` only) |
| CLI only (does not touch the Book) | `main/1` in `main.exs`, and the table in `lib/help.exs` | — |

### 3.2 Behaviour asked

- **`Dispatch.handle/4` is pure** (takes a Book, returns a Book; the only I/O is `scan/run` reading files). It returns `{:ok, book, result
  map}` or `{:error, book, %{"code" => …, "message" => …}}`; on failure the Book does not change
- **params are JSON-shaped** (string keys). The CLI's `key=value` become strings or lists through `CommandLine` (`[..]` is always a list, a
  value with a comma is a list too)
- **Always list it in `Methods`**. Declare its arguments as data in `params` (name, kind `:node`/`:call`/`:value`/`:choice`/`:number`/
  `:flag`/`:address`, required, list). The argument text `help` shows (`args`) is made from them, and `dialogue do` asks for the required ones
  in that order. `summary` (one line) is printed by `help` as it is, and tezcatl's users register it in the dictionary for completion. No `:`
  in a command name. `test/methods_test.exs` checks the table against `Dispatch`'s clauses both ways, and `test/help_test.exs` that every
  implemented method has a summary
- What uses the REPL does not go into `Dispatch` (the server's GenServer would stop for the evaluation): use `Pipeline`'s `"eval"` stage
- Dialogue programs: `start`/`answer` return one of `{:hold, state, text}`, `{:done, text, commands}`, `{:pass, state, line}`. To read the
  Book, `start/2` / `answer/3` (a read-only `ctx`). Only commands change the Book. How a line is read: `parse_answer/1` (none:
  `%{"text" => line}`). Examples: `Dialogue.Depends`, `Dialogue.Search`, `Dialogue.Do`, `Dialogue.Rewrite` (after the column it hands over to
  `Dialogue.Do` — borrowing another dialogue's body). For a dialogue that only runs one method, first see whether `dialogue do` is enough
  ([D-dialogue-core](verification/lib-in_out.exs.md#d-dialogue-core))

### 3.3 Entrances

- **CLI**: usable as `xipe do <method> …`, so a subcommand of its own is often not needed. To make one: `main/1` in `main.exs` and
  `@commands` in `lib/help.exs` (`window: true` makes it usable in the window too)
- **The window**: how a line is read is `lib/input.exs` (written as on the CLI; a line starting with a method's name is `do` left out). To
  make a CLI subcommand usable in the window, add a clause there
- **WebSocket**: listed in `Methods`, it is usable as it is

### 3.4 Tests and writing down

`test/dispatch_test.exs` (or a test of its own); `methods_test` and `help_test` passing; `test/serve_input_test.exs` when used from the
window. The method table in `how-to-use.md` §3.2, the README's method table, the record (`document/verification/`).

---

## 4. Documents and code to refer to

| To know | Look at |
|---|---|
| What it is for, what it is not | README |
| What is called in what order | `document/internals.md` |
| Every decision, and why | `document/verification/decisions.md` and the records it links |
| How the languages were added, and what was checked | [D-ocaml-adapter](verification/lib-repl-language-ocaml.exs.md#d-ocaml-adapter), [D-haskell-adapter](verification/lib-repl-language-haskell.exs.md#d-haskell-adapter), [D-embody](verification/lib-repl-embody.exs.md#d-embody) |
| The REPL adapter's detailed contract (the marker protocol, hangs) | `document/repl-adapter-guide.md` |
| embody's output contract and each language's content | `~/my_app/embody/ReadMe.md` |
| The core of evaluation | `lib/repl/evaluator.exs` (each entry's round trip and deadline), `lib/runner.exs` (sorting by language) |
| What is open now | `document/scope.md` ("Work not started"), `work_history/課題.md` (to 2026-10-10) |
| What was planned next | `work_history/next_step.md` (adding languages paused on 2026-09-27) |
