# REPL adapter guide (adding a language or REPL)

> **The entrance is `document/extending.md`.** This guide is the detailed reference written while Elixir was implemented (2026-09-18 to
> 09-26). OCaml and Haskell came later ([D-ocaml-adapter](verification/lib-repl-language-ocaml.exs.md#d-ocaml-adapter),
> [D-haskell-adapter](verification/lib-repl-language-haskell.exs.md#d-haskell-adapter)) and added a third part, **embody**, a fixed module
> loaded into the target's REPL (a separate repository, [embody](https://github.com/Crux-xurC/embody)). The candidate checklists at the end were drafted before any of
> them was implemented; for OCaml and Haskell the real forms (the plain `ocaml` toplevel, not `utop`; GHCi entries bound with `let` …) are
> in those records.

Readers: whoever writes a REPL adapter for a language other than Elixir (the candidates considered: Haskell/GHCi, OCaml, Clojure, Racket …),
person or AI, without knowing the conversations that led here.

Elixir's adapter is complete and checked end to end on a real `iex` (start → readiness → evaluation → compare → parsing → leaving). Every
item below has working code under `lib/repl/`; read it first when adding a language.

## The design this rests on (do not change)

Xipe Totec automates what a person does by typing expressions into the target's REPL ([D-text-repl](verification/lib-repl-sender.exs.md#d-text-repl)).
The whole is split into **per-language computing modules** (pure: they only build JSON data and code text) and **a generic execution layer**
(it only reads and runs them, knowing no language). **To add a language, write only the computing side (and, if needed, an embody loaded into
the REPL). The generic layer — `lib/repl/sender.exs`, `sender_direct.exs`, `session.exs`, `eval/scan.exs`, `eval/field_drip.exs`,
`eval/parser.exs`, `eval/result.exs`, `evaluator.exs` — is not touched.**

`XipeTotec.Repl.Evaluator` (`lib/repl/evaluator.exs`) is the outermost part of that layer: it drives a `Core.plan_recalc/3` plan through one
session and folds it with `Core.apply_results/3`. It takes the four computing modules as options (`:launch_module`, `:eval_template_module`,
`:scan_module`, `:field_drip_module`), defaulting to Elixir's — the caller passes concrete modules and nothing inside decides a language. The
caller is `Runner`, which picks them from the language the surface table names
([D-language-adapter](verification/lib-repl-language.exs.md#d-language-adapter)).

## The layer deciding languages (`tables/`, `info.json`)

Apart from writing the computing modules, there is a layer deciding which language and build tool a project uses
([D-surface-table](verification/lib-surface_table.exs.md#d-surface-table)). A new language connects to it:

- **`XipeTotec.Repl.Language`** (`lib/repl/language.exs`): each language's self-declaration, one module per language in
  `lib/repl/language/<name>.exs`, the file name being the language's name (`elixir.exs` → `"elixir"`). It declares `extensions/0`, `repl/0`
  (the surface table's `repl` column), `build_tools/0` (by priority, `[%{"name", "markers"}]`), `scanner/0`, `adapter/0`, `launch_opts/3`.
  **A new language writes this file besides the four computing modules**
- **`XipeTotec.Info`** (`lib/info.exs`): Xipe Totec's own `info.json`. `xipe refresh -l` loads `lib/repl/language/*.exs`, calls the
  declarations and writes `languages`, `extensions` (extension → the languages declaring it), `language_repls`, `build_tools`. **A file put
  there does nothing until `xipe refresh -l` registers it** (P4)
- **`XipeTotec.SurfaceTable`** (`lib/surface_table.exs`): the project's file tree with `language`, `repl`, `build_tool`. An extension one
  language declares is that language; none, or **two or more, is `nil`** (P9)
- **embody** is not a callback: each language's launch loads it in its init (OCaml's `-init` file, Haskell's `-ghci-script`), found by
  `lib/repl/embody.exs` (`XIPE_TOTEC_EMBODY_DIR`, else the `embody/` beside). A project's environment (Nix …) is a project layer, not a
  language: `project_env.json` ([D-project-env](verification/lib-project_env.exs.md#d-project-env))

## Layout

```
lib/repl/
  launch.exs              (XipeTotec.Repl.Launch)              -- computing: the start message (Elixir)
  sender.exs              (XipeTotec.Repl.Sender)              -- generic: the delivery behaviour
  sender_direct.exs       (XipeTotec.Repl.Sender.Direct)       -- execution: over a plain pipe
  session.exs             (XipeTotec.Repl.Session)             -- generic: readiness, leaving
  language.exs            (XipeTotec.Repl.Language)            -- the behaviour of a declaration
  language/{elixir,ocaml,haskell}.exs                          -- computing: each language's declaration
  eval_template.exs       (XipeTotec.Repl.EvalTemplate)        -- computing: Elixir's call + safety wrapper
                                                                  + repr/compare + markers, all in one
  ocaml/{launch,eval_template}.exs, haskell/{launch,eval_template}.exs
  embody.exs              (XipeTotec.Repl.Embody)              -- where embody is
  evaluator.exs           (XipeTotec.Repl.Evaluator)           -- generic: one plan through one session
  source_sanitize.exs     (XipeTotec.Repl.SourceSanitize)      -- Elixir only (see the note): defmodule-only
                                                                  loaders for scripts-mode
  eval/
    scan.exs              (XipeTotec.Repl.Eval.Scan)           -- generic: finding markers
    field_drip.exs        (XipeTotec.Repl.Eval.FieldDrip)      -- the behaviour
    result.exs            (XipeTotec.Repl.Eval.Result)         -- generic: to an Evaluator result
    parser.exs            (XipeTotec.Repl.Eval.Parser)         -- generic: the above in one step
    scan/direct/{iex,ocaml,ghci}.exs                           -- computing: per REPL over a plain pipe
    scan/pty/             (empty: for a PTY Sender, when there is one)
    field_drip/{elixir,ocaml,haskell}.exs                      -- computing: reading the body
```

**A note on `source_sanitize.exs`**: outside the four computing modules — an Elixir-only helper used by Elixir's `launch_opts/3` for
scripts-mode. It reads the AST and loads only the `defmodule` parts, so the files' top-level side effects do not run
([D-source-sanitize](verification/lib-repl-source_sanitize.exs.md#d-source-sanitize)). Which files can be loaded safely, and how, differs by
language (an AST filter is not always possible): OCaml blanks top-level effects in copies (embody's `load_all`), GHCi runs nothing on `:load`.

To add a language or REPL, write only that language's version of the files marked **computing**. Do not touch **generic** or **execution**.

**Why `Scan` has two axes (transport × REPL) while the others have one**: the noise `Scan` removes (a PTY's echo, ANSI) is mostly a transport
property, but a REPL may have quirks of its own, so both axes are directories. The other three depend on the language or REPL only.

## What does not change (the same in every language)

- **The markers** ([D-markers](verification/lib-repl-eval-scan.exs.md#d-markers)): `XT_BEGIN_<call_id>` (success, the body follows),
  `XT_END_<call_id>` (its end), `XT_ERROR_<call_id> crash <reason>` / `timeout` / `max_heap` (a failure instead; `max_heap` is a kill for the
  memory limit, told apart from a crash), `XT_CALLED_<call_id>` (optional: the call returned, judging starts), `XT_READY` (the answer to the
  ready probe), `XT_EXIT <status>` (the process ended; made by the Sender, not by the computing side). These strings never change
- **The body's `key=value` format**: between `XT_BEGIN` and `XT_END`, one per line: `repr=<exact|binary|unsupported>`, `type=<type>`,
  `compare=<none|skipped|changed|same>`, `display=<text>`, and `bin_base64=<base64>` for `repr=binary` (`FieldDrip.Elixir`). **`display=`
  must be one line** (Elixir: `inspect(…, width: :infinity)` and newlines written as `\n`); otherwise the line parser breaks
- **The body in one write** (Elixir joins the lines and calls `IO.puts/1` once): printing line by line lets another process's output land in
  between. Only the target side's discipline prevents this
- **JSON-safe values**: what a launch module returns is strings, numbers, booleans, null and maps/lists of them — no atoms, no tuples
- **Push only, one message shape**: always `{handle, {:data, binary()}}` (`lib/repl/sender.exs`); the computing side has no part in it
- **The `Repl.Sender` behaviour** (`send/1`, `write/2`, `kill/1`, `interrupt/1`) knows no language. If a new language seems to need a new
  callback, the premise of this guide is broken: stop and think first (`interrupt/1` was added for that reason — a SIGINT to the process
  group is something every language needs)
- **Judging happens inside the target's session**: `repr` and `compare` handle values that may be the target's own types, so they are judged
  and printed in the REPL under evaluation, not in Xipe Totec's process

## The launch message (fields)

A function returning a `%{String.t() => term()}` shaped like Elixir's `Repl.Launch.build/1` (`lib/repl/launch.exs`):

| Field | Type | Meaning | Elixir's default |
|---|---|---|---|
| `kind` | string | always `"repl/launch"` | `"repl/launch"` |
| `argv` | [string] | the REPL's command (a list, not a shell string) | `["iex", "-S", "mix"]` |
| `env` | map | variables to add (the project's environment is merged in by the Runner) | `%{}` |
| `cwd` | string | the target project's root | (the caller's) |
| `files` | [string] | sources to load one by one (see below) | `[]` |
| `ready_pattern` | string \| null | a substring of the banner marking the start (version-free); `null` for a REPL without one | `"Interactive Elixir"` |
| `ready_probe` | string \| null | sent after the banner; makes the REPL print `XT_READY`. Split the marker in the source, so a REPL echoing input is not mistaken for the answer | `"IO.puts(\"XT_\" <> \"READY\")\n"` |
| `exit_input` | string | text to send for a normal end | `"System.halt()\n"` |
| `interruptible` | boolean | whether `Sender.interrupt/1` (SIGINT to the process group) really reaches a handler in this REPL (see below) | `true` (checked) |

The eval_template is not in the launch message: `XipeTotec.Repl.EvalTemplate` builds it per entry from the plan; a new language writes its own
module for it (below). How long the REPL may take to be ready is the project's `eval.boot_timeout` (default 15 s).

### Using `files`

If the language has a way to load a whole project at start (Elixir's `-S mix`), use it as `argv`'s default and leave `files` empty. Without
one (Elixir's scripts-mode), put the files in `files`; the Sender decides how they reach the start (`Sender.Direct.with_files/2` inserts
`-r <file>` for iex — so OCaml and Haskell put their files in their init script instead). **The computing side does not need to know how** —
`files` is plain data.

## What an eval_template needs

`lib/repl/eval_template.exs` is Elixir's: `build/1` turns a plan entry into code text run inside the target's session
([D-repr](verification/lib-repl-eval_template.exs.md#d-repr), [D-compare-basis](verification/lib-repl-eval_template.exs.md#d-compare-basis),
[D-closed-args](verification/lib-repl-eval_template.exs.md#d-closed-args)). What it needs:

1. **Building the call**: from the qualified name (module/name) and the arguments, already text, the language's call syntax (wrap each
   argument in parentheses so an embedded value does not change binding)
2. **Printing to stdout** (Elixir: `IO.puts/1`)
3. **Catching exceptions**: an evaluation that raises must **always print `XT_ERROR_<call_id> crash <reason>` before ending**. Elixir runs the
   call in a `spawn_monitor` child and catches its `:DOWN`; without a process mechanism, a plain try/catch. Without it a failure cannot be told
   from a timeout
4. **Time and memory limits**: Elixir uses `spawn_monitor` + `Process.flag(:max_heap_size, …)` + `receive … after`. Rebuild with the language's
   own means; a language without a memory limit may go without (a stuck REPL is killed)
5. **The `repr` strategy**: Elixir's is (a) a pid/port/reference/fun anywhere inside → `unsupported`; (b) otherwise `inspect` → evaluate back
   → equal → `exact`; (c) otherwise the language's serialisation → `binary` (`bin_base64=`). **Without a value → text → value mechanism, do not
   copy these three steps — rethink them** (that is what embody is for)
6. **`type=`**: the value's type as a string
7. **`compare`**: the plan passes `entry.basis` (`{:exact, previous text}` | `{:binary, previous base64}` | `:none`). Rebuild the previous value
   **inside the session** and compare; `:none` gives `compare=none`. Elixir compares terms recursively (maps, lists, tuples, structs as maps),
   floats within `1.0e-9` relative or absolute. A new value that is `unsupported` gives `compare=skipped`. **The words are strings**: `none`,
   `skipped`, `changed`, `same`
8. **Always bind the result to a session variable** (`xt_<call_id>`), whatever its `repr`: a later entry of the same pass refers to it
   (`:in_plan`). The session lasts one pass, so the binding does too. Keep the binding, the judging and the printing in one top-level statement
   where the language's scoping needs it (Elixir's first attempt lost the binding inside a `case`)
9. **Why inside the target**: the values may be the target's own types, so judging and printing finish in the session under evaluation
10. **Check the call before sending it**: an unclosed argument (`[1, 2`) makes most REPLs wait for more input and swallow everything sent
    after it — this entry's rest, the next entries — and no marker ever comes (only the Evaluator's deadline ends it). Elixir parses the call
    with `Code.string_to_quoted/1` first and, if it fails, sends only a one-line diagnostic built on Xipe Totec's side (`build_syntax_error/3`),
    never the broken fragment. Elixir also passes the call as a string compiled inside the child, so a compile error in the arguments is an
    ordinary `crash`. If the language has a parser API, do the same; if not, at least never mix the broken fragment into the rest of the
    template, or OCaml's way: pass the call as a string the toplevel evaluates

## Deciding `interruptible`

There is no heartbeat (removed 2026-09-22). Liveness is generic: past the deadline, `Sender.interrupt/1` sends SIGINT to the REPL's process
group, and after a short grace without `XT_EXIT`, `Sender.kill/1` sends SIGKILL to the group
([D-hang-handling](verification/lib-repl-evaluator.exs.md#d-hang-handling)). **The target writes no code for this.** The computing side
decides one thing: **when SIGINT reaches this REPL, does it stop the evaluation and return to its prompt, or (no handler) just exit?** The first
is `interruptible: true`; the second, or unknown, `false`. `false` breaks nothing — the Evaluator skips the interrupt and kills directly; it
only loses a gentler chance to end.

Elixir is `true` (`@default_interruptible`), checked 2026-09-22: SIGINT to an `iex` started by erlexec with `{group, 0}` over a plain pipe
(`:exec.kill(ospid, 2)` with the positive ospid; erlexec delivers to the group) brought up BEAM's `BREAK: (a)bort (A)bort with dump
(c)ontinue …` menu, as Ctrl-C in a terminal does. No PTY needed. OCaml and GHCi are `true` too (`Interrupted.`).

## What a field_drip needs

`lib/repl/eval/field_drip/elixir.exs` implements the `FieldDrip` behaviour (`parse(body) :: map()`). The body format is fixed for all of Xipe
Totec, so the implementation is "split into lines, split each at the first `=`". As long as the eval_template prints that format, a field_drip
need not change by language (OCaml's and Haskell's delegate to Elixir's). It decides no language: the caller passes the module to
`Repl.Eval.Parser.step/5`.

## What a scan module needs

`lib/repl/eval/scan/direct/iex.exs` is Elixir over a plain pipe. **Two axes: `lib/repl/eval/scan/<transport>/<repl>.exs`.** A new REPL over a
plain pipe adds `lib/repl/eval/scan/direct/<repl>.exs`; a new transport (a PTY) adds a Sender and `lib/repl/eval/scan/<transport>/`. A plain
pipe has no echo or ANSI (checked), so `clean/1` only finds and removes `XT_EXIT`. A PTY would need echo and ANSI removal here.

## Checklist for a new language

Before writing the computing modules, find out (or have an AI find out — then check it on the real REPL, `extending.md` §2.2):

1. The default start command; a mode that loads the whole project
2. How to load single files from the command line (for projects without a build tool)
3. A version-free string printed when it is ready — or, since the two-step readiness ([D-ready-probe](verification/lib-repl-session.exs.md#d-ready-probe)),
   an expression that prints `XT_READY` (a REPL without a stable banner sets `ready_pattern` to `null`)
4. The REPL's own command to quit
5. The call syntax (from a qualified name and arguments)
6. The function that prints to stdout
7. The syntax to catch an exception and still always print the end marker
8. Whether there is a round trip value → text → value; if not, how `repr` is judged instead (embody)
9. How float tolerance is handled
10. Whether SIGINT stops the evaluation and returns to the prompt, or ends the process (`interruptible`; `false` if unknown is safe)
11. Whether the REPL works over a plain pipe (no PTY), or needs a real tty (then a PTY transport first)

The answers become the launch module (`argv`, `ready_pattern`, `ready_probe`, `exit_input`, `interruptible`), the eval_template module, the
field_drip, and (for a PTY) the scan module. An item that cannot be answered is a place where Xipe Totec's design does not fit the language as
it is: talk to crux before implementing.

## Drafts for candidate languages (2026-09-22, from knowledge, not checked)

Drafted before any of these was installed here. **For OCaml and Haskell the implemented forms differ** — see their records: the plain `ocaml`
toplevel through its own `Toploop` (not `utop`), embody for `repr`; GHCi with `-v0`, every stage bound with `let` under
`-fdefer-type-errors`, embody for `repr`; both `interruptible: true`. What follows keeps the two Lisps, still unimplemented. Check each item on
the real REPL before starting.

### Clojure

1. **Start**: `clojure` (`clj`) or `lein repl`; `deps.edn` / `project.clj` give the classpath
2. **Loading files**: `(load-file "file.clj")` or `(require 'namespace :reload)` after the start
3. **Ready**: the prompt `user=>` (may change with the namespace); JVM logs come first, so pick a substring that cannot be confused — or use the
   `XT_READY` probe
4. **Quit**: `(System/exit 0)` or EOF
5. **Call**: prefix `(f x y)`; qualified `(namespace/f x y)`
6. **Print**: `println`, `print`
7. **Catch**: `(try … (catch Exception e …))`
8. **Round trip**: `pr-str` / `read-string` (EDN) — Clojure's data structures read back as written, close to Elixir's `inspect` /
   `Code.eval_string`. Arbitrary Java objects are not EDN: `unsupported`
9. **Floats**: a tolerance written by hand
10. **SIGINT**: a raw SIGINT to the JVM usually ends it through its shutdown hooks; whether the REPL can stop only the evaluation is unknown —
    likely `false`
11. **Plain pipe**: should work; the JVM start is slow (a longer `eval.boot_timeout`)

**Where the design needs thought**: the closest to Elixir (8 exists in the standard library); 10 probably `false`.

### Racket

1. **Start**: `racket -i`; little standard support for loading a whole project (`raco` is for building and packages)
2. **Loading files**: `racket -i -t file.rkt`, or `(enter! (file "file.rkt"))` after the start (`racket/enter`)
3. **Ready**: the prompt is just `>` — easily confused; suppress the banner (`-q`) and use the `XT_READY` probe
4. **Quit**: `(exit)` or EOF
5. **Call**: prefix `(f x y)`; qualification goes through `require`, not a plain `ns/name` join
6. **Print**: `display`, `printf`
7. **Catch**: `(with-handlers ([exn:fail? (lambda (e) …)]) …)`
8. **Round trip**: `~s` (write) and `read` are standard: close to Clojure (S-expressions read back)
9. **Floats**: by hand
10. **SIGINT**: `break-enabled?` / `exn:break` turn it into a catchable exception; whether `racket -i` enables break by default is unknown
11. **Plain pipe**: to be checked; `racket -i` has no line editing by default, which may suit a pipe

**Where the design needs thought**: 3 (the prompt `>`). Otherwise close to Clojure; it looks the cheapest of the candidates.

### Across the candidates

- **8 (the round trip)** was the structural wall for OCaml and Haskell, solved by embody; Clojure and Racket have it in their standard
  libraries (data written as S-expressions reads back)
- **10 (`interruptible`) is no blocker**: liveness is the generic layer's (signal + fixed deadline + kill); a SIGINT handler only makes the end
  gentler. No language needs a lightweight concurrency mechanism any more
- All of it is a draft from knowledge; check one item at a time where the language's system is available (the target's own `nix develop` …)

## The live tests to model on

`test/live/repl_iex_test.exs` (not in `test/run.sh`; run as `elixir test/live/repl_iex_test.exs`) checks Elixir's whole path; `repl_ocaml_test.exs`
and `repl_haskell_test.exs` do the same for theirs. For a new language, write the same kind once its system is available: start → readiness →
evaluation (success, an `:in_plan` reference, `unsupported`, an exception, a timeout, an unclosed call) → compare (`same`, `changed`) → leaving.
A small sample project without outside dependencies, like `test/fixtures/calc_sample/calc.exs`, makes checking easy.
