# How it works

**The question this document answers**: for each use, what is called in what order, and which program does each step.

Xipe Totec's parts are not related intricately enough to need a document of structure; what characterises it is that **every use runs along
nearly one path**. So this document writes that path out per use. **The only branch by language is "which four modules are handed to the
Evaluator" (§11)**; everywhere else every use passes the same modules in the same order (the branches a use has of its own — §3's "is it
`eval`", "does it go through `Pipeline`" — are another axis).

Why each step has its shape is in the decision records (`document/verification/`, linked where relevant). This document gives only the path,
no history or alternatives.

---

## 0. The three foundations every use stands on

| Module | File | Role |
|---|---|---|
| `XipeTotec.Book` | `lib/book.exs` | the current state in memory: six tables (`sheets`, `nodes`, `calls`, `links`, `runs`, `providers`), each `id => latest row` |
| `XipeTotec.Core` | `lib/core.exs` | pure functions over the Book (the reference graph, cycles, `plan_recalc`, `apply_results` …); no I/O at all |
| `XipeTotec.Store` | `lib/store.exs` | append-only `book.jsonl`: `load/1` rebuilds the Book, `persist_diff/4` appends only the difference (I/O, under a lock) |

(`Book` and `Core` are pure; `Store` does file I/O.) Every CLI command keeps to "read the old Book with `Store.load` → do something → write the
difference to the new Book with `Store.persist_diff`".

**One Book per project** ([D-workspace](verification/lib-workspace.exs.md#d-workspace)): `book.jsonl` is
`tables/project/<id>_<name>/book.jsonl`, and which one is read and written is decided at the start of each command by
`XipeTotec.Workspace.resolve/3` (§10). `"book.jsonl"` below means that per-project file, and `dir` the project's absolute path.

---

## 1. `xipe scan [<dir>]` — scan the source into the Book

```
main.exs (scan)
  → Workspace.resolve(<dir> or nil)                         … §10; ends here if none is chosen or registered
  → the project's environment (ProjectEnv.resolve)           … for a language server the scan starts itself
  → run_commands(project, [%{"method" => "scan/run", "params" => %{}}])
      1. Store.load("book.jsonl")                           … the old Book
      2. XipeTotec.Runner.run/4                              … runs the command list
           → XipeTotec.Dispatch.handle(book, "scan/run", %{}, %{root: dir, project_dir: …})
               → XipeTotec.Project.scan_dir(book, dir, …)
                   1. the saved surface table (SurfaceTable.rows/3; made again and saved when empty or its paths are gone),
                      the paths of rows of registered languages
                   2. per language, its scanners in order (Repl.Language.scanner/0): the first whose begin/3 accepts reads
                      that language's files — Elixir: elixir-ls through tezcatl's /lsp or started here, else its own parser
                   3. pass 1 over every file: definitions → nodes; an existing id is kept on the natural key
                      (module, name, anykey), else a new one
                   4. pass 2, after every file's pass 1: calls → links (callHierarchy, or the compiler tracer compiling only
                      defmodule forms, or text for OCaml / Haskell)
                   5. nodes, sheets and links no longer found are removed
      3. Store.persist_diff("book.jsonl", old, new, …)        … only the difference is appended
      4. the result lines to stdout (which scanner read each language, fallbacks, link_failures, arity_misses)
```

**Programs**: `main.exs` → `Runner` → `Dispatch` → `Project` (→ `SurfaceTable`) → the scanners → `Store`. `Core` does not appear: a scan
resolves no references and evaluates nothing ([D-scanners](verification/lib-scanner-lsp.exs.md#d-scanners),
[D-identity](verification/lib-identity.exs.md#d-identity)).

---

## 2. `xipe show` — just show the Book

```
main.exs (show)
  → Workspace.resolve(<dir> or nil)
  → Store.load("book.jsonl")
  → Show.lines: sheets, nodes, links, and the calc rows through row/list, one per line
```

It does not go through `Runner`: it changes nothing and starts nothing (the Runner mediates what changes the Book or starts an outside
process) ([D-show-failed](verification/lib-show.exs.md#d-show-failed)).

---

## 3. `xipe do [--dir <dir>] <method> [key=value...] [-- <method> ...]` — a general command list

`xipe scan` and `xipe eval` are in fact "a command list of one command" on top of this; `xipe do` uses it directly
([D-command-list](verification/lib-runner.exs.md#d-command-list)).

```
main.exs (do)
  1. a leading "--dir <path>" is taken out, and Workspace.resolve decides the project (none: the chosen one, §10)
  2. the rest is split on "--"; in each group the first word is the method and the rest are "key=value" pairs
     (XipeTotec.CommandLine: [..] is always a list; anything else with a comma too)
     → the command list [%{"method" =>, "params" =>}, ...] (the shape of the wire messages, §7)
  3. run_commands(dir, commands)
      → XipeTotec.Runner.run(book, dir, commands, opts)
          from the first, one at a time (Enum.reduce):
            a. "$<n>.<path>" references are resolved from the earlier commands' results ("$0.id" → command 0's "id")
            b. method "eval" → §5 (not through Dispatch)
               a method pipelines.json lists → Pipeline.run/4
               anything else → Dispatch.handle(book, method, params, ctx)
            c. the result (ok?, result, error) is kept as one outcome; the Book goes on to the next
  4. Store.persist_diff of the difference to the final Book
  5. each outcome as a line
```

**There are two branches here**:

1. `"eval"` or not decides between `Dispatch` (a pure change of the Book) and the `Evaluator` (live REPL I/O)
2. A method other than `"eval"` that `XipeTotec.Pipeline.handles?/1` knows (`pipelines.json`) goes to `Pipeline.run/4`, else to
   `Dispatch.handle/4`. Registered today: `eval/run` (`["eval"]`) and `row/update` (`["edit", "eval"]`). The `"eval"` stage is the Runner's own
   `"eval"` (passed as `ctx.eval`): the one operation that uses a REPL. The server runs the stages before `"eval"` at once and queues only the
   `"eval"` stage (`Pipeline.prepare/4`) ([D-pipeline](verification/lib-pipeline.exs.md#d-pipeline))

No other branch: `Dispatch.handle/4` only looks a method up and calls the matching pure (or thin I/O) function of `Core`, `Project`,
`Address`, `GraphQuery`. Methods not implemented (`cell/complete`, `edit/*`, `trace/*`, `provider/recheck`) answer `not_implemented`
without raising; `eval/run` and `row/update` are there too only as a fallback for a caller that reaches `Dispatch` directly.

---

## 4. `xipe eval [<dir>] [id...] [--mix] [--include-writes]` — a special case of §3

```
main.exs (eval)
  → a first argument that is an existing directory is <dir>; otherwise every argument is a call id
  → Workspace.resolve decides the project (§10)
  → the ids (none given: every call of the Book)
  → the command list [%{"method" => "eval", "params" => %{"call_ids" => ids, "include_writes" => ...}}]
  → run_commands(dir, [it], ctx: GitCtx.read(dir))
```

`--include-writes` goes into `params["include_writes"]`; the Runner's `"eval"` passes it to `Core.plan_recalc/3` (§6). Without it, rows of
`writes` / `unknown` functions are left out by `filter_by_effect/3`.

Rows asked for but not evaluated (effect unclassified, `writes` without `--include-writes`, a cycle, the node gone) get their reason from
`Core.exclusion_reason/3` after the evaluation, as `"not_run"`; the CLI prints `not run  <reason>`
([D-effect-classes](verification/lib-core.exs.md#d-effect-classes)).

`GitCtx.read/1` runs `git rev-parse HEAD`, `git show -s --format=%cI HEAD`, `git status --porcelain` for `commit`, `commit_at`, `dirty` (no git:
all `nil`, evaluation goes on) ([D-git-provenance](verification/lib-git_ctx.exs.md#d-git-provenance)). Then it joins §3, and as the method is
`"eval"`, §5.

---

## 5. Inside the `"eval"` command — the round trip to the REPL

The step with the most steps: from the Runner's `"eval"` into `XipeTotec.Repl.Evaluator.run_pass/3`, once per language group.

```
Runner ("eval")
  a. the rows are grouped by language: call → node → sheet → path → the saved surface table's language (§11);
     a reference across languages is not_run; one group per language, in parallel when several
     ([D-languages-per-pass](verification/lib-runner.exs.md#d-languages-per-pass))
  b. per group: the language's module (Info.language_module/3) gives adapter/0 (the four modules) and launch_opts/3 (how to start;
     for Elixir, mix-mode by the build_tool column, else scripts-mode with SourceSanitize's loaders); the project's environment
     (ProjectEnv) and settings (eval.timeout, eval.boot_timeout) are read; the group is recorded in passes/ (D-passes)

Evaluator.run_pass(book, pass_id, opts)
  1. Core.plan_recalc(book, pass_id, call_ids: ..., include_writes: ...)     … pure, §6
       → the entries (module/name/args/inputs/basis/limits) and plan.skipped
     no entries: return the skipped ones only (no REPL is started). Skipped rows are reported, not written to the Book

  2. adapter = the four modules (the only place a language matters, §11):
       :launch_module, :eval_template_module, :scan_module, :field_drip_module

  3. adapter.launch.build(cwd: ..., ...) → a JSON-able message
       %{"argv", "env", "cwd", "files", "ready_pattern", "ready_probe", "exit_input", "interruptible"}

  4. sender.send(message)      (default XipeTotec.Repl.Sender.Direct)
       → :exec.run(argv, [..., {:group, 0}, ...]): the OS process in its own process group; a handle (a GenServer pid) is returned

  5. XipeTotec.Repl.Session.await_ready(sender, handle, message, eval.boot_timeout, cancelled?)
       → wait for ready_pattern (the banner; skipped when nil), then write ready_probe and wait for "XT_READY" (skipped when nil);
         one timeout for both. An "XT_EXIT" first is a failed start (boot_failed, with the REPL's last lines)

  6. for each entry in order:
       a. adapter.eval_template.build(entry)
            → for Elixir: the call (module.name(args)) is checked to parse (Code.string_to_quoted/1). **If it does not, nothing of it is sent**:
              only a diagnostic built here is printed (build_syntax_error/3). If it does: the call as a string compiled in a child process
              + the safety wrapper (spawn_monitor, max_heap, timeout) + repr (a → b → c) + compare (against the basis) + the markers, the
              block printed with one IO.puts  ([D-closed-args](verification/lib-repl-eval_template.exs.md#d-closed-args), [D-repr](verification/lib-repl-eval_template.exs.md#d-repr))
       b. sender.write(handle, that text)                               … to the REPL's stdin; :progress "calling"
       c. Repl.Eval.Parser.step/5 in a loop until the result:
            adapter.scan.clean/1 (the transport's noise, the XT_EXIT marker) → the generic Scan.scan/2 (XT_BEGIN_<id> / XT_END_<id> or
            XT_ERROR_<id>) → adapter.field_drip.parse/1 (the key=value body) → Result.success / error, the shape Core.apply_results/3
            expects. XT_CALLED_<id> on the way → :progress "classifying".
            **An XT_EXIT before the entry ends has no special handling** (clean/1 sees it but wait_result does not read it): nothing more
            arrives, and d.'s deadline makes it session_hung (the label is not exact, but it is safe)
       d. a fixed deadline, set once when the entry is sent: entry.limits.timeout (eval.timeout) + 2 s (@default_deadline_padding_ms) —
          **not a silence window reset by output** (an unclosed expression makes the REPL swallow everything after it)
          past it (end_hung_session/4):
            → if message["interruptible"]: sender.interrupt/1 (SIGINT to the group), up to 2 s (@default_interrupt_grace_ms) for XT_EXIT
            → no XT_EXIT in that time (or not interruptible): sender.kill/1 (SIGKILL to the group)
            → this entry is {:error, "session_hung"} (with "the call returned; judging its value did not finish" after XT_CALLED), every
              later entry :aborted (even when the interrupt worked: the same session does not go on)
       e. cancelled? (eval/cancel) is asked before each entry and every 200 ms while waiting: yes → kill the group,
          {:error, :cancelled}, nothing of the pass recorded

  7. when nothing hung: Session.close(sender, handle, exit_input)
       → write exit_input and wait for XT_EXIT (graceful); otherwise sender.kill(handle), then wait for XT_EXIT

  8. Core.apply_results(book, ctx, results)                             … pure, §6
       → the new Book (the calc rows' result, repr, compare, state …)

Runner, after every group: the results folded once, the limits and env status added, the passes/ records removed
```

**Only the named calls are evaluated** ([D-named-rows-only](verification/lib-core.exs.md#d-named-rows-only)): the plan holds exactly the
`call_ids` given; neither the rows downstream nor the rows referenced upstream are added (the Book is a record in time of what commands
asked). A REPL lives for one pass, so no binding crosses passes ([D-one-pass-one-repl](verification/lib-repl-evaluator.exs.md#d-one-pass-one-repl)).

**The skip path** (`Core.plan_recalc/3`): a call whose reference cannot be passed (§6: a referenced row without a passable value that is not
named in the same pass, or that was left out by its effect) does not go into `plan.entries` but into `plan.skipped` (`{:skipped, ref}`). It
never reaches a REPL and is not written to the Book.

**The marker protocol** ([D-markers](verification/lib-repl-eval-scan.exs.md#d-markers)):

| Marker | Meaning |
|---|---|
| `XT_BEGIN_<id>` / `XT_END_<id>` | a success; between them the body `repr=` / `type=` / `compare=` / `display=` / (`bin_base64=`) |
| `XT_ERROR_<id> timeout` | the entry's own timeout |
| `XT_ERROR_<id> max_heap` | killed for exceeding max_heap (a `:DOWN` with `:killed`) |
| `XT_ERROR_<id> crash <reason>` | any other exception |
| `XT_CALLED_<id>` | the call returned; judging its value starts |
| `XT_READY` | the answer to the ready probe |
| `XT_EXIT <status>` | the session ended; made by the Sender (not the target's text) |

These strings do not change with the target language (`document/repl-adapter-guide.md`, "What does not change").

---

## 6. Inside `Core.plan_recalc` / `Core.apply_results` (steps 1 and 8 of §5)

**`plan_recalc`** (pure, `lib/core.exs`):

```
1. reference_graph(book)           … the ⟦id⟧ tokens in each call's args (a regex)
2. cyclic_ids(graph)               … the call ids in a cycle (left out)
3. the requested calls that exist and are not in a cycle
4. filter_by_effect(book, requested) … only effect_source == "user" with pure / reads (+ writes if asked);
                                       an unclassified node never runs
5. drop_unresolvable                 … rows with a reference that cannot be passed → skipped (repeated until nothing more falls)
6. topo_sort(the rest, the graph without cycles)
7. build_entry/3 for each:
     → each ⟦ref⟧ in args by resolve_ref/3:
          evaluated earlier in this plan      → :in_plan (the binding's name, xt_<id>)
          outside the plan, repr exact        → its text embedded as it is
          anything else                       → :binding (→ skipped in 5.)
     → the basis (what compare compares with):
          call.prev_source == "user" and call.prev not empty → {:exact, call.prev}  (a person's expectation, row/set-prev)
          else call.repr == "exact"                          → {:exact, call.result}
          else call.repr == "binary"                         → {:binary, call.bin}
          else                                               → :none
```

([D-reference-values](verification/lib-core.exs.md#d-reference-values), [D-compare-basis](verification/lib-repl-eval_template.exs.md#d-compare-basis))

**`apply_results`** (pure, `lib/core.exs`): folds the Evaluator's results one by one, by the outcome's tag (`{:ok, %{...}}` / `:timeout` /
`:max_heap` / `{:error, reason}` / `{:skipped, id}` / `:aborted`). `:ok` updates result, repr, compare … and moves the value before it into
`prev`; a failure keeps `result` and sets `state: "eval_error"`; `{:skipped, id}` and `:aborted` change nothing (not evaluated, not recorded)
([D-plan-run-apply](verification/lib-core.exs.md#d-plan-run-apply)).

---

## 7. `xipe start` (`xipe serve`) — the WebSocket server, and one request

```
main.exs (start)
  1. XipeTotec.Serve.Project.start_link(%{root:, store_file:, …})     … the GenServer
       init/1 → Store.load(store_file) into its state (from then on only this process holds the Book)
  2. cowboy.start_clear routes "/" to XipeTotec.Serve.Socket; tables/session.json is written (D-session-record)

a client (tezcatl's relay) connects →
  Serve.Socket.init: a browser's Origin is refused; websocket_init → Serve.Project.attach(self())   … the session registered

{"method": "initialize", ...} from the client →
  answered by Serve.Socket itself (not passed to Serve.Project: initialize / subscribe are session bookkeeping, not Book operations);
  the socket then holds initialized: true (and state.dialogue = nil, below)

{"method": "row/add", "params": {...}, "id": N} →
  Serve.Socket.websocket_handle
    → Serve.Project.request_dialogue(state.dialogue, method, params)     … GenServer.call
        (every ordinary request takes this path: one connection, one dialogue — the socket holds `dialogue` and passes it each call)
        → first, the lines the CLI appended since the last read are taken in and broadcast (D-store)
        → InOut.handle(dialogue, book, root, %{method, params}, ...)
            → not for a dialogue program: passed through to Pipeline.run/4 or Dispatch.handle/4 (§3's two branches)
        → a change: Store.persist_diff(store_file, old, new, …) under the lock, after catching up again
        → notify/rowChanged, notify/nodeChanged to every attached session (Protocol.encode_notify)
        → a request that raises: internal_error, the Book and the dialogue unchanged (D-serve-project)
  → Serve.Socket answers that client with the envelope (below)

disconnecting → Serve.Socket.terminate → Serve.Project.detach(self())
```

**Evaluation and scanning run off the GenServer**: `eval`, `eval/run`, `row/update` are answered at once with a `pass_id`; the pass runs
`Runner.run/4` in a process of its own over a snapshot; at the end its results are folded into the Book as it is then, saved, broadcast, and
`notify/passCompleted` follows. One pass at a time per project, in order. `scan/run` also runs in its own process; its reply waits for it
([D-serve-project](verification/lib-serve_project.exs.md#d-serve-project)).

**The envelope** ([D-envelope](verification/lib-protocol.exs.md#d-envelope)): the usual `{"jsonrpc", "id", "result" | "error"}` plus two
top-level fields, `"from"` (reserved, always `null`) and `"dialogue": {"hold", "via_repl", "text"}`. `dialogue.hold` true: the dialogue goes
on (the next `:in` is awaited; the socket holds it); false: a one-shot answer or the dialogue's end.

**`input`** ([D-input-line](verification/lib-serve_input.exs.md#d-input-line)): the method tezcatl's dialogue window sends each typed line
with. `Serve.Socket` takes it and hands it to `Serve.Input.start/3`:

```
Serve.Input.start(line, state.dialogue)
  a dialogue is held → Dialogue.answer_params(mod, line) → Project.request_dialogue(…, "dialogue/answer", …)
  otherwise XipeTotec.Input.parse(line)             … pure; read as the CLI reads it
    {:text, _} (help, version), :show, {:error, _}  → answered at once (dialogue.text)
    {:commands, list}  → in a process of its own, one by one:
        Runner.substitute_command/2 resolves $<n>
        → Project.request_dialogue(nil, method, params, watch: self(), defer_commands: true)
        → a method that starts a dialogue (dialogue/…): when a question comes back, the line ends there (the dialogue held, the question the
          reply). When it ends at once with commands (dialogue do given everything), they run next in its place
        → an evaluation (a repl method): a pass_id comes back → wait for {:xipe_pass_done, pass_id, outcome}
        → all done: {:xipe_input_done, …} to the socket → the reply (OutcomeText's lines in dialogue.text)
```

The waiting is done by that process; the socket's connection does not wait (it answers other requests).

While a dialogue is held, a line becomes its answer through `Dialogue.line_request/2` (or `quit dialogue` → `dialogue/quit`), passed to `InOut`
with `defer_commands: true`. When a turn returns "run this line as an ordinary command" (`{:pass, …}`, a command typed inside a search) or
"finished: run these commands" (`dialogue depends`'s `y <value>`), `InOut` does not run them but puts them on `outcome.run`, and `Serve.Input`
runs them in the same kind of process as above (through the pass queue). The CLI runs the same with `Runner.run/4` inside its own prompt.

**`eval/cancel`** ([D-passes](verification/lib-passes.exs.md#d-passes)): stops an evaluation pass. The request is a file
(`<project_dir>/passes/<pass_id>.cancel`, `XipeTotec.Passes`) the pass's process looks for while it waits on the REPL (the Evaluator's
`:cancelled?`: before starting, while starting, per entry, every 0.2 s while waiting). Found: `Sender.kill/1` stops the process group and it
returns `{:error, :cancelled}` — nothing of the pass enters the Book.

```
Serve.Project ("eval/cancel")
  a pass_id in the queue      → taken out → notify/passCompleted (error.code "cancelled"), the waiting line told
  the pass it runs itself     → Passes.request_cancel (put even before its record is written)
  anything else               → Dispatch.handle("eval/cancel") … finds it in passes/ and leaves the request (a CLI's pass)
the side running it (Runner → Evaluator)
  finds the request → kills the REPL → the Runner ends with the "cancelled" error → removes the request file
  → on the server: the usual completion, notify/passCompleted (ok: false), the next pass starts
```

The CLI's `xipe do eval/cancel` goes through `Dispatch` only (it does not see the server's queue).

---

## 8. `xipe dialogue depends [<dir>] <call_id>` — dependency-chain negotiation

```
main.exs (dialogue depends)
  1. Store.load("book.jsonl")                          … the old Book
  2. Core.upstream_chain(book, [call_id])              … pure: reference_graph followed forward, topo_sort
     → call_id itself + its upstream ⟦id⟧ dependencies, deepest first
  3. a label per id (Core.call_label/2: "Module.name/anykey", or "Module.name"), as [%{"id", "label"}, ...]
     (Dialogue.Depends itself never touches the Book)
  4. the CLI's prompt drives it turn by turn (InOut.handle/6), reading stdin and writing stdout
     (from tezcatl's window the same program advances one `input` line at a time — §7)

  each turn of Dialogue.Depends:
    a. from the deepest, a question with ";; wN <label>"
    b. "y <literal>" → row/set-result on that step, then eval (include_writes: true) of every step above it, the target included; done
    c. "n" → one step up (that step is neither evaluated nor kept)
    d. the chain used up (every step "n", or no upstream at all): done, no commands — no fallback to evaluating the target directly
       (that is xipe eval)

  5. Store.persist_diff of the difference to the final Book
  6. each outcome as a line; System.halt(1) on failure
```

([D-depends](verification/lib-dialogue-depends.exs.md#d-depends))

### 8.1 The other dialogues — `xipe search`, `xipe dialogue do`, `dialogue rewrite`, `dialogue update`

On the CLI all are run by `main.exs`'s dialogue loop (prompts `search> `, `do> `, `rewrite> `, `update> `): read a line →
`Dialogue.line_request/2` → `InOut.handle/6` → print the text → run what the turn returned (`outcome.run`: a line or commands) with
`Runner.run/4` → save the Book; until the dialogue ends.

```
Dialogue.Search    the tables are XipeTotec.Tables' (name, mark, columns, how rows are read). It holds the list and x;
                   any other line runs as an ordinary command ({:pass, …})
Dialogue.Do        what it asks comes from XipeTotec.Methods' params (name, kind, required, list): the required ones the line left out, in
                   order. Answers are the line as typed; a function by id or by name (Address.resolve); a list opens with a { line and closes
                   with a } line; args checked when it closes (Dispatch.check_args/5). When complete, the call is shown, and a method that
                   writes waits for y → {:done, …, [command]}
Dialogue.Rewrite   table → row (shown) → column. The column's method comes from Tables' writes (args → row/set-args, result →
                   row/set-result, prev → row/set-prev, effect → effect/set). With the column decided, it enters Dialogue.Do.start/2 with the
                   row's id given, and later answers go to Do
Dialogue.Update    file → key → value. The files are LogBuffer.recent_files/2 (the .json paths last inside parentheses in
                   tables/logging_buffer.txt, the latest five) + this project's project.json. The value is checked by ProjectConfig.check/2,
                   then it enters Dialogue.Do.start/2 (config/set)
```

([D-search](verification/lib-dialogue-search.exs.md#d-search), [D-dialogue-do](verification/lib-dialogue-do.exs.md#d-dialogue-do))

The settings (`ProjectConfig`) are the project's `project.json` over `defaults.json`. The Runner reads them when a pass starts and passes
`eval.timeout` as each row's limit (the Evaluator's `:timeout_ms`) and `eval.boot_timeout` as the time to wait for the start. The result
carries `"limits"` with the values and the files they came from, and `OutcomeText` makes one line of it — that line stays in
`logging_buffer.txt`, so the next `dialogue update` can choose that file. What is written there: the CLI's printed lines and dialogue texts, and
the server's `Serve.Input` answers ([D-log-buffer](verification/lib-log_buffer.exs.md#d-log-buffer)).

No dialogue writes the Book itself. The one who receives its final commands does (the CLI's Runner, the server's `Serve.Input`).

---

## 9. `xipe refresh -l|-r|-a` — Xipe Totec's own `info.json`

Independent of every use above: Xipe Totec's own bookkeeping (no target project's Book is touched).

```
main.exs (refresh)
  1. the flags (-l/--languages, -r/--repls, -a/--all); none is a usage error
  2. Info.load()                       … the info.json there
  3. as asked, Info.refresh_languages/1 and Info.refresh_repls/1:
       refresh_languages: loads lib/repl/language/*.exs and calls each module's extensions/0, repl/0, build_tools/0 →
                          languages, extensions (extension → the languages declaring it), language_repls, build_tools
       refresh_repls:     lib/repl/eval/scan/<transport>/*.exs as transport + REPL pairs
  4. Info.save/2                       … info.json written whole
```

`info.json` is found from Xipe Totec's own `__DIR__`. Every file Xipe Totec reads and writes for itself (`info.json`, `pipelines.json`,
`project_env.json`, `defaults.json`, `tables/`) is found this way; nothing depends on the working directory (so the `xipe` command does not
`cd`, and relative arguments are read from the caller's directory).

The content is derived automatically, but **the command itself must be run on purpose** (P4: a file in `language/` does not make a working
language) ([D-surface-table](verification/lib-surface_table.exs.md#d-surface-table)).

---

## 10. `xipe choice project` / `xipe table generate` — deciding the project

```
xipe choice project <path>
  → Workspace.choose(path)
      1. ProjectRegistry.find(path)                 … matched by project.json's path
         not registered → Workspace.generate_table(path):
             ProjectRegistry.register(path)           … a 3-digit id, tables/project/<id>_<name>/project.json
             SurfaceTable.generate(path, the old table) … ids kept by path
             SurfaceTable.save(rows, …/table)
             the project's environment resolved (ProjectEnv, force)
         registered without a table → generate_table only
      2. the id written to tables/selection.json's "project"

xipe table generate [<path>]      (no <path>: the chosen project)
  → Workspace.generate_table(path)                  … as above; registers if not registered; resolves the environment again

every other command (scan, show, eval, do, dialogue …, start)
  → Workspace.resolve(<dir> or nil)
      with <dir> → ProjectRegistry.find; not registered is an error (nothing is registered implicitly)
      without    → the running session's project (tables/session.json), else tables/selection.json's "project"; none chosen is an error
  → %{id, path, dir, store_file, table_file}
```

A project's files are under `tables/project/<id>_<name>/`: `project.json` (the match key and the settings), `table` (the surface table),
`book.jsonl` (the Book), `env.json` (the environment's cache), `passes/` (running passes). `tables/` is in `.gitignore` (per-machine data with
absolute paths) ([D-workspace](verification/lib-workspace.exs.md#d-workspace)).

**The saved `table` is what is read**: scanning (§1) and the Runner's preparation (§5) use `SurfaceTable.rows/3`. An empty table, or one whose
paths are no longer on disk, is made again (ids kept by path) and saved first. A file added later is not in until `xipe table generate`. A
caller without a `table_file` (tests) makes one in place. Each row's `language` comes from `info.json`'s `extensions`, its `repl` from its
language's REPL, its `build_tool` from the first of its language's build tools whose marker matches at the root.

---

## 11. Where language makes a difference (summary)

**The branch by language is on the evaluation side**: the four modules handed to the Evaluator (`launch_module`, `eval_template_module`,
`scan_module`, `field_drip_module`) and how the REPL starts are chosen by the Runner from the declaration (`adapter/0`, `launch_opts/3`) of the
`Repl.Language` module the surface table names. One REPL per language; a build tool only changes how it starts. Declared: Elixir, OCaml,
Haskell. Haskell starts GHCi with a `-ghci-script` that `:load`s `embody.hs` and the target; OCaml starts `ocaml -init <a temp file>`, which
loads `embody.ml` and the target's files; neither uses `message["files"]` (`Sender.Direct` makes it iex's `-r`). The Evaluator's own defaults
(Elixir's) remain only for direct calls that bypass the Runner (tests) ([D-language-adapter](verification/lib-repl-language.exs.md#d-language-adapter)).

On the scanning side, each language declares its scanners (`scanner/0`, in order): Elixir has `Scanner.Lsp.Elixir` (elixir-ls through tezcatl's
`/lsp`, `Lsp.Transport.Relay`, else started here, `Lsp.Transport.Stdio`) and `Scanner.Elixir` (its own parser and the compiler tracer); OCaml
and Haskell are read as text ([D-scanners](verification/lib-scanner-lsp.exs.md#d-scanners)). `Project.sheets/2` leaves out `mix.exs`, `deps/`
and `_build/` whatever the language.

`Core`, `Book`, `Store`, `Dispatch`, `Pipeline`, `Session`, `Repl.Eval.Parser`, `Repl.Eval.Scan` (the generic marker finding) and
`Repl.Evaluator` depend on no target language.

**"scan" has two meanings**: `Scanner` / `scan/run` / `xipe scan` extract definitions from the source; `Repl.Eval.Scan` / `:scan_module` find
markers in the REPL's output. Different things.
