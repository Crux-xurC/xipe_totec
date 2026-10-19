# How to use

**The question this document answers**: with the code as it is, how is Xipe Totec actually used?

Only how commands are typed and how what comes back is read. Why things have their shape: the decision records
(`document/verification/`); what is called in what order inside: `internals.md`; what is promised and what is open: `scope.md`. The output
examples were made for real against `test/fixtures/calc_sample/calc.exs` (ids change with every run).

---

## 1. Getting ready

```
cd ~/my_app/xipe_totec
nix develop
```

The development shell defines the `xipe` function (`elixir $XIPE_TOTEC_DIR/main.exs "$@"`). It does not `cd`, so `xipe` can be typed from any
directory; relative arguments are read from where you typed.

The shell holds:

| What | For |
|---|---|
| Elixir 1.18 / OTP 27 | Xipe Totec itself, and the targets' `iex` |
| cowboy, gun, erlexec | the WebSocket server, connecting to tezcatl's `/lsp`, starting REPLs |
| elixir-ls | the language server scanning uses (started by Xipe Totec itself when tezcatl is not there) |

The languages are only those registered in `info.json`: today Elixir (`.ex`/`.exs`), OCaml (`.ml`), Haskell (`.hs`). Evaluating OCaml or
Haskell needs `ocaml` / `ghci` in the target's environment (a flake in `project_env.json` …, §4.3) or on PATH, and each language's `embody`
(a separate repository, `~/my_app/embody`, §9.1). Type `xipe refresh -l` only after adding a language to `lib/repl/language/` (§9).

---

## 2. The basic flow

As an example, the target is a directory `~/work/calc` holding only this `calc.exs`:

```elixir
defmodule Calc do
  def add(a, b), do: a + b
  def mul(a, b), do: a * b
  def square(x), do: mul(x, x)
  def wide_list, do: Enum.to_list(1..100)
end
```

### 2.1 Choosing the project

```
$ xipe choice project ~/work/calc
xipe choice project: 001  /home/user/work/calc  (new)
```

The first time it is registered and given a 3-digit id (`001`). From then on, every command without `<dir>` acts on this project. Switching to
another project is the same command. Xipe Totec writes nothing into the target project's directory (where the data is: §8).

### 2.2 Scanning

```
$ xipe scan
scan/run  ok  %{"link_failures" => [], "links" => 1, "nodes" => 6, "paths" => ["calc.exs"],
  "scanners" => %{"elixir" => %{"scanner" => "XipeTotec.Scanner.Lsp.Elixir", "skipped" => [], "via" => "stdio"}}, "sheets" => 1}
xipe: 1 command(s), 1 ok
```

Each function becomes a **card** (a node), and calls between functions become **links**.

- Only `def`, `defp` and `defdelegate` become cards; macros do not. `defp` is in the list of references as `visibility: "private"`, but no
  calc row can be made for it
- `mix.exs` and what is under `deps/` and `_build/` are not read
- Only the files in the saved file → language table (the surface table, §8) are read. If files in the table are gone from disk, the table is
  made again and saved before reading. **A file added later is not read until `xipe table generate`** (evaluation uses the same table)
- `scanners.elixir.via` says how it was read: `relay` is tezcatl's `/lsp`, `stdio` an elixir-ls started here. When neither works, Xipe Totec's
  own parser (`Scanner.Elixir`) reads it
- A file whose unsaved changes in an editor make the language server differ from the disk is read again with the own parser and listed in
  `fallbacks`. Cards always follow the disk

After changing the source, type `xipe scan` again. A function with the same module, name and arity keeps its id, and so does its side-effect
class (§2.4). Changing a function's name or arity makes another card.

### 2.3 Looking inside

```
$ xipe show
project 001  /home/user/work/calc
sheet 01M3D3Z0Z4Q895NNZVKHQF83GF  calc.exs
node  01M3D3Z10ZNS03HPV3Q9GGJZHT  Calc.add/2  effect=unknown
node  01M3D3Z10Z05FB7JYD4GH74Y9V  Calc.square/1  effect=unknown
...
link  01M3D3Z10Z05FB7JYD4GH74Y9V --to--> 01M3D3Z10ZPB9S7SKXVKSBA135
row   01M3D3ZDR9MW08P2VZ6Q73E2RE  Calc.add/2  args=["1", "2"]  3  compare=none
```

`row` is a calc row (§2.5): id, function, arguments, the current value (`-` if never evaluated), `compare`. A row whose last evaluation failed
shows the failure and its reason instead of the value, and the previous value (`(error: timeout)  previous=0  state=eval_error`; the value in
the table is the previous evaluation's). A row whose function is gone from the source shows `(node gone)`.

The commands that follow use the node ids shown here. Instead of copying an id, `node/resolve` can look it up from the function's address and
pass it on with `$0.id` (§3.3).

### 2.4 Classifying side effects

**A function not classified is not evaluated.** Before evaluating, give each function a class once.

```
$ xipe do effect/set id=01M3D3Z10ZNS03HPV3Q9GGJZHT effect=pure
```

| effect | Meaning | Evaluated? |
|---|---|---|
| `pure` | no side effects | yes |
| `reads` | only reads the outside | yes |
| `writes` | writes to the outside | only with `--include-writes` |
| `unknown` | not known (the default) | as `writes` |

Evaluation does not run in a sandbox: evaluating a `writes` function really writes.

**A function with default arguments** (`def scale(x, k \\ 2)`) is one card, for its defined arity (`scale/2`). To make a `scale(3)` row, decide
once how many arguments it can be called with (it is never decided automatically):

```
$ xipe do arity/set id=<node> arities=[1,2]
```

Before that, when `row/add` refuses, Xipe Totec's own parser suggests it ("has default arguments, callable as 1..2"). `scan`'s result lists in
`arity_misses` the calls that relied on defaults and did not become links (decide it and scan again, and they do). The node shows as
`scale/1..2`, a row as the count it calls (`scale/1`). To go back: `arities=[2]` (the defined count alone).

### 2.5 Making a calc row and evaluating it

A calc row is "one call of a function": its arguments are kept, and it can be evaluated again any number of times.

```
$ xipe do row/add node=01M3D3Z10ZNS03HPV3Q9GGJZHT args=1,2 -- eval 'call_ids=[$0.id]'
row/add  ok  %{"id" => "01M3D3ZDR9MW08P2VZ6Q73E2RE", "row" => %{...}}
  eval call 01M3D3ZDR9MW08P2VZ6Q73E2RE  ok       repr=exact  3  compare=none
xipe: 2 command(s), 2 ok
```

- Arguments are written as the target language's source (`1`, `"abc"`, `:ok` …). If their number does not match the function's arity,
  `row/add` refuses
- `$0.id` is the `id` of the result of command 0 of the same list (`row/add`). **The shell expands `$0`, so always wrap it in single quotes**
  (otherwise it becomes `bash.id`, and nothing is evaluated: `unknown call id`)
- Classifying, adding and evaluating fit on one line (§3.3)

To evaluate the rows again all at once, `xipe eval`; for particular rows, list their ids.

```
$ xipe eval
$ xipe eval 01M3D3ZDR9MW08P2VZ6Q73E2RE
```

### 2.6 Referring to another row's result

Writing `⟦<calc row id>⟧` in an argument puts that row's result there, like a cell reference in a spreadsheet.

```
$ xipe do row/add node=<square's id> 'args=[3]'                  # → 9 (call this row R1)
$ xipe do row/add node=<square's id> 'args=[⟦R1⟧]'              # → square(9) = 81
```

**Only the rows named are evaluated.** Evaluating R1 does not evaluate R2, which refers to it (R2 keeps its old value). To evaluate along a
chain of dependencies, name the rows together:

```
$ xipe eval <R1> <R2>        # R1 first, then R2 with its result
```

- Rows named together are evaluated in reference order (the referenced first), and every one is recorded
- When the referenced row is not named, its value in the table is used if it can be written as source (`repr=exact`)
- When the referenced row's value cannot be passed from the table (never evaluated, or `repr=binary` / `unsupported`), the row cannot be
  evaluated unless the referenced row is named too: it is `skipped` with the reason, and nothing is recorded. If you do not want to evaluate
  the referenced row again, `xipe dialogue depends <the row's id>` puts a value in its place and evaluates (§5). `binary` is a value "that can
  be stored as bytes but not written as source" (e.g. a struct with fields hidden by `@derive {Inspect, only: …}`); its display does not read
  back, so it is not embedded
- The same when the referenced row cannot be evaluated because of its class (unclassified, `writes` without `--include-writes`)
- Rows in a reference cycle are not evaluated

The Book is a record in time, holding only the evaluations commands asked for. Rows not named are never evaluated behind your back.

Xipe Totec checks functions one at a time and sees a chain of dependencies by evaluating rows in turn. If the function evaluated is
referentially transparent, its result is a valid record even when the value it was given cannot be reproduced (the referenced function is not
pure) ([D-referential-transparency](verification/lib-core.exs.md#d-referential-transparency)).

Rows made in the same `xipe do` can be referred to as `⟦$<n>.id⟧` (§3.3).

### 2.7 Changing the source and seeing the difference

Each evaluation compares with the previous value and leaves the result in the `compare` column.

```
(mul rewritten as a * b + 1)
$ xipe scan
$ xipe eval
  eval call 01M3D3ZDR9MW08P2VZ6Q73E2RE  ok       repr=exact  3    compare=same
  eval call 01M3D3ZFCV7ZRHV9TSRVETQEE9  ok       repr=exact  10   compare=changed
  eval call 01M3D3ZXG3XMTYHP4WHCN736VZ  ok       repr=exact  101  compare=changed
```

`xipe scan` alone evaluates nothing again. To update the values, type `xipe eval`.

---

## 3. Commands

### 3.1 The list

Without `<dir>`, the target is the project of the running `xipe start` session if there is one, else the project chosen with
`xipe choice project`: an explicit `<dir>` > the session > the chosen one. A `<dir>` passed must be registered.

| Command | What it does |
|---|---|
| `xipe choice project <path>` | register (the first time) and choose a project |
| `xipe table generate [<path>]` | make the file → language table (the surface table) again; type it after adding files |
| `xipe scan [<dir>]` | read the source, update cards and links |
| `xipe show [<dir>]` | list sheets, cards, links and calc rows |
| `xipe eval [<dir>] [id...] [--mix] [--include-writes]` | evaluate calc rows (no ids: all) |
| `xipe do [--dir <dir>] <method> [key=value...] [-- <method> ...]` | run methods in a list (§3.2) |
| `xipe dialogue depends [<dir>] <call_id>` | evaluate a dependency chain by dialogue (§5) |
| `xipe search [<turn>]`, `xipe dialogue do`, `xipe dialogue rewrite`, `xipe dialogue update` | the dialogues of §5.1–5.4 |
| `xipe start [<dir>] [--port N] [--lsp <url>] [--fs-root <dir>]` | stay up as the WebSocket server (§6); `xipe serve` is another name |
| `xipe config [<dir>] [key=value...]` | show or change the project's settings (§4.3) |
| `xipe refresh -l\|-r\|-a` | update Xipe Totec's own `info.json` (§9) |
| `xipe help [<command>]` / `xipe version` | `help` is one command a line (`command: description  arguments`); with `<command>`, its description |

If any command of a list fails, the exit code is 1.

### 3.2 Methods usable in `xipe do`

| method | params | What it does |
|---|---|---|
| `scan/run` | none | the same as `xipe scan` |
| `row/add` | `node` `args` | make a calc row; the result's `id` is the new row's |
| `row/remove` | `id` | remove a calc row |
| `effect/set` | `id` (node) `effect` | classify side effects |
| `arity/set` | `id` (node) `arities` | decide the argument counts a function with default arguments accepts (§2.4) |
| `row/set-result` | `id` `result` | write a result by hand, without evaluating (as a literal of the target language) |
| `row/set-prev` | `id` `prev` | write the previous value (what the next evaluation compares with = the expected value) by hand, without evaluating; the next evaluation replaces it again |
| `row/set-args` | `id` `args` | change only a row's arguments (checked as `row/add`). **Does not evaluate** — the value stays the old arguments', so `eval` afterwards |
| `eval` | `call_ids` (none: all) `include_writes=true` | evaluate |
| `card/get` / `card/search` | an address (below) | take out a card (the function + its calc rows + links) |
| `card/list` | — | every function (card) whole (`cards`). Each has `id`, `label`, `module`, `name`, `anykey`, `effect`, `visibility`, `path` (from the project's root), `line` (where the definition starts, 1-based), `rows` (the number of calc rows). In file order (`path`, `line`); functions without calc rows are in too. Narrowing and sorting are the receiver's |
| `cell/resolve` | `ref` (as `⟦id⟧`) | that row's current value, repr, state |
| `row/depends` | `call_ids` | the row and the upstream rows its references reach, deepest first |
| `row/list` | `call_ids` (none: all) | the list of calc rows (function, arguments, value, repr, state, compare) — the same as `xipe show`'s `row` lines. Each row's `path` and `line` are its function's file (from the project's root) and line (1-based; both `null` if the function is gone, `line` alone `null` if the Scanner could not get a position). `linked` says whether its function still exists (`false`: cut by a scan that lost the function; `state` stays the last evaluation's, so it may read `ok` while cut — make the row again) |
| `node/resolve` | an address (below) | decide the one function the address matches and return its `id`: none is `not_found`, two or more `ambiguous` (with candidates) |
| `row/check` | `call_ids` (none: all) `on` (default `error`) | fail when a row is in an `on` state (§3.4) |
| `row/update` | `id` `args` | change a row's arguments (checked as `row/add`) and evaluate **that row alone** |
| `eval/run` | `call_ids` (none: all) `include_writes=true` | the same as `eval` (spec §16's name) |
| `eval/status` | none | the passes being evaluated: language, elapsed time, the number of rows, the row being evaluated now and its phase (below). On the server, waiting passes too |
| `eval/cancel` | `pass_id` (may be left out when one pass runs) | stop a running pass (below). On the server, also take a waiting pass out by `pass_id` |
| `config/set` | `key` `value` | change one setting of the open project (§4.1; what `dialogue update` runs at its end), written to its `project.json` |
| `roster` | none | the tables `search` can look up: name, the mark written in a turn (`-s`, `-e`), columns, the columns `dialogue rewrite` can rewrite |

**Stopping a pass (`eval/cancel`).** The running pass's REPL is stopped with its process group, and **nothing** of the pass is recorded (not
even rows that had finished). A referentially transparent function gives the same value when evaluated again; only what was classified
`writes` and evaluated with `--include-writes` may have half-done writes. It stops within a moment (checked every 0.2 s), also while the REPL
is starting.

```
$ xipe do eval/cancel
eval/cancel  ok  pass 01M4R8F0… is being stopped (nothing of it is recorded)
```

- The stopped side ends with `eval  error  cancelled: …` (on the server, `notify/passCompleted`'s `error.code` is `cancelled`)
- `pass_id` is shown by `eval/status`. With one pass running it may be left out; with two or more, write it
- A pass waiting on the server leaves the queue with `eval/cancel pass_id=<id>` (`status` `dequeued`); a running one is `cancelling`
- It works from another terminal (the request is a file in `passes/` too). With nothing running: `no_pass`
- A scan cannot be stopped (`scope.md`)

**Rows being evaluated cannot be changed.** While a pass runs, `row/update`, `row/set-result` and `row/remove` on its rows are refused as
`row_in_pass` (try again when it ends), so a value is never written against arguments it was not computed from. The same from another
terminal, whether the CLI or the server is evaluating (the running pass is a file in `tables/project/<id>_<name>/passes/`, and both look at it)
([D-passes](verification/lib-passes.exs.md#d-passes)).

```
$ xipe do eval/status
eval/status  ok
  running  pass 01M48MJ7ARMHHTZYCYFVSQR9SP  elixir  2s  2 row(s) (not changeable until it ends)
    now  01M48MHW725HG4ERTCN0YY1R3S  S.slow/1  calling  2s
```

The phase is `calling` (the call was sent) or `classifying` (the call returned; its value is being judged — repr, compare). A row stopped by
the deadline after `classifying` is recorded as `session_hung (the call returned; …)` (the call itself had finished). Only Elixir reports the
phase; OCaml and Haskell stay `calling`.

An address narrows by a combination of columns: `file` (a relative path), `module`, `name`, `arity` (or `anykey`), `row` (a calc row's id)
([D-address](verification/lib-address.exs.md#d-address)).

```
$ xipe do card/get module=Calc name=square arity=1
$ xipe do card/get row=01M3D3ZFCV7ZRHV9TSRVETQEE9      # the card the calc row belongs to
```

`graph/neighbors` and `graph/export` (following call relations; writing them as mermaid/dot/json/doctest) need an object as `address`, so one
`xipe do` line cannot write them: use `dialogue do graph/export` (answer with the function's name, §5.2) or the WebSocket (§6).
`cell/complete`, `trace/*` and `provider/recheck` are not implemented and answer `not_implemented`.

### 3.3 Writing `xipe do`

Commands are separated by `--` and run from the first; a later command can refer to an earlier one's result as `$<n>.<key>` (counting from 0).

```
$ xipe do effect/set id=<node> effect=pure \
       -- row/add node=<node> args=2,3 \
       -- eval 'call_ids=[$1.id]'
```

`<key>` can go inside with `.`; a number is a position in a list (`$0.matches.0.id`). A missing key is empty (`nil`). Looking up an id from an
address and using it:

```
$ xipe do node/resolve module=Calc name=square arity=1 \
       -- effect/set 'id=$0.id' effect=pure \
       -- row/add 'node=$0.id' 'args=[3]' \
       -- row/add 'node=$0.id' 'args=[⟦$2.id⟧]' \
       -- eval 'call_ids=[$2.id,$3.id]'
```

How values are written ([D-cli-values](verification/lib-command_line.exs.md#d-cli-values)):

| Written | Passed |
|---|---|
| `[]` | an empty list (`args` of a function without arguments) |
| `[10]` | a one-element list |
| `[1,2]` or `1,2` | a two-element list |
| anything else | one string |

Watch out:

- `$<n>.<key>` is replaced only when it is the whole value, or written as `⟦$<n>.<key>⟧` (it becomes `⟦<id>⟧`). `'args=[$0.id + 1]'` is not
  replaced
- List elements are split at commas only, so a list such as `[1,2,3]` cannot be passed **as one argument** on one line — use
  `dialogue do` (§5.2), which takes a list one element a line
- Wrap values containing `$`, `⟦⟧` or `[]` in single quotes
- A `call_ids` that is written but empty (a `$n.…` into a failed command) is refused, nothing evaluated; leaving `call_ids` out means every row

### 3.4 Detecting changes with `row/check`

`row/check` fails when a row is in one of the states `on` names. A failure in a list makes the exit code 1, so after an evaluation it lets a
script detect changes and failures.

| `on` | Rows that fail |
|---|---|
| `error` (default) | `state` is not `ok` (crash, timeout, max_heap) |
| `changed` | `compare=changed` |
| `unevaluated` | never evaluated |

```
$ xipe do eval -- row/check on=error,changed
row/check  error  check_failed: 2 of 11 row(s): 01M3D6ZW... Calc.square/1 changed; ...
```

It looks at each row's current value, so rows not evaluated by that list (left out as `not run` for being unclassified …) are judged by their
previous evaluation.

---

## 4. Inside evaluation, and reading the results

### 4.1 How it evaluates

Each evaluation (a pass) starts the target project's REPL anew, sends the calc rows one by one, and closes it at the end. How it starts is
decided by the build tool recorded in the surface table (the `build_tool` column):

| `build_tool` | Start |
|---|---|
| `mix` (a `mix.exs` at the root) | `iex -S mix` (dependencies and configuration loaded) |
| none | `iex -r` of temporary files holding only the `defmodule` parts of the `.ex`/`.exs` files in the table (top-level code is not run) |

The build tool is decided once, at `xipe table generate` (and the first `xipe choice project`), and recorded in the table. After adding a
`mix.exs`, type `xipe table generate`. The order of preference comes from each language's declaration (§9).

`--mix` starts `iex -S mix` whatever the `build_tool`.

The REPL is kept for one evaluation (pass) only and closed when it ends; no state or variable is carried over
([D-one-pass-one-repl](verification/lib-repl-evaluator.exs.md#d-one-pass-one-repl)). That it has started is checked by sending
`IO.puts("XT_" <> "READY")` after the banner and getting `XT_READY` back.

Each calc row runs in a process of its own with a timeout (default 5 s) and a max_heap limit. If the REPL has not started (`XT_READY` back)
within 15 s by default, the pass is `boot_failed`. Both times can be changed per project (`eval.timeout`, `eval.boot_timeout`, §4.3, §5.4);
the evaluation output's `eval: limit …` line shows the pass's limits and the file each came from. A REPL that exits while starting (the
target's code does not compile …) is `boot_failed` too, and the error carries the last 30 lines it printed (with the compile error's file and
line).

### 4.2 Reading the output

```
  eval call <id>  ok       repr=exact  81  compare=same
  eval call <id>  crash    {:badarith, [...]}  compare=skipped
  eval call <id>  not run  effect not classified -- `effect/set id=... effect=pure` (or reads) to evaluate
```

| Shown | Meaning |
|---|---|
| `ok` | evaluated |
| `crash` | fell with an exception (with the reason) |
| `timeout` / `max_heap` | stopped by a guard |
| `skipped` | not evaluated: a referenced value cannot be passed (name the referenced row too). Not recorded in the table |
| `aborted` | the session wedged in the same pass, and it was cut off |
| `not run <reason>` | left out when planning (unclassified, `writes`, a reference cycle, the card gone …) |

`repr` says how the value was stored ([D-repr](verification/lib-repl-eval_template.exs.md#d-repr)):

| repr | Meaning |
|---|---|
| `exact` | evaluating the display text gives the same value back (numbers, strings, lists …); it can be embedded downstream as it is |
| `binary` | the display does not give it back, so it is stored as binary too (`:erlang.term_to_binary`) |
| `unsupported` | holds a pid, a function, a reference …: cannot be stored. Only the display text is kept |

`compare` compares with the previous value (`same` / `changed`; `none` the first time; `skipped` when they cannot be compared). Floats are
compared within a tolerance. The previous value moves to the `prev` column at each evaluation.

A calc row also records the git commit, its time and whether there were uncommitted changes (`dirty`) when it was evaluated.

---

### 4.3 The target project's environment (`project_env.json`)

How the target's environment is got is written in Xipe Totec's `project_env.json`, in the same form as tezcatl's `project_env.json` (tezcatl's
D-project-env): someone without Nix only rewrites or adds a line ([D-project-env](verification/lib-project_env.exs.md#d-project-env)).

```json
{ "timeoutMs": 120000,
  "entries": [
    { "marker": "flake.nix", "command": ["nix", "print-dev-env", "--json"], "format": "nix", "watch": ["flake.nix", "flake.lock"] },
    { "marker": ".envrc",    "command": ["direnv", "export", "json"],       "format": "env" },
    { "marker": "mise.toml", "command": ["mise", "env", "--json"],          "format": "env" } ] }
```

The first entry whose `marker` file is at the target's root is used, and its `command` runs there. `iex` and a language server Xipe Totec starts
itself (elixir-ls) run in the environment it gives. It is not run every time: taken out once, saved in `tables/project/<id>_<name>/env.json`,
and used from then on. A language server through tezcatl's relay gets its environment the same way from tezcatl's `project_env.json`.

- Two `format`s: `env` (`{"NAME": "value" | null}`; null removes the variable; direnv, mise, a script of your own; values as they are) and
  `nix` (`nix print-dev-env --json`; like `nix develop`, without `HOME`, `TMPDIR` …; `PATH` and `XDG_DATA_DIRS` as `env.path` says)
- It is taken again at `xipe choice project` (the first time) and `xipe table generate`, and when it changed with `env.refresh=auto`. Whether it
  changed is judged by a hash of the `watch` files (default: the `marker`) and of how the entry is written (`watch` is read by Xipe Totec
  only; tezcatl asks once and keeps it until `env reload`)
- The flake's `shellHook` is not run: variables it `export`s are not included
- A target without a `marker` at its root runs in Xipe Totec's own environment (unlike tezcatl, directories above are not looked at: the root
  is the one a person registered)
- The time limit is `timeoutMs` (default 120 s); past it, `error`, and Xipe Totec's own or the previous environment is used
- The scan's and evaluation's `env` (in `xipe scan`'s output) is one of `cached` (the saved one used), `resolved` (taken again), `stale`,
  `error`; `stale` and `error` also warn when evaluating

Settings are per project (`project.json`), shown and changed with `xipe config` or `xipe dialogue update` (§5.4; also from the window). Keys not
set have the defaults (Xipe Totec's `defaults.json`). In the list, the parentheses give what a value may be and the file the current value comes
from ([D-project-config](verification/lib-project_config.exs.md#d-project-config)).

```
$ xipe config
project 002  /home/user/work/fcalc
env.path=prepend  (prepend|replace, /…/xipe_totec/defaults.json)
env.refresh=auto  (auto|manual, /…/xipe_totec/defaults.json)
eval.boot_timeout=15000  (1000..1800000 ms, /…/xipe_totec/defaults.json)
eval.timeout=5000  (100..600000 ms, /…/xipe_totec/defaults.json)
$ xipe config env.refresh=manual eval.timeout=20000
```

| Setting | Value | Meaning |
|---|---|---|
| `env.path` | `prepend` (default) | a `nix` environment's `PATH` goes before Xipe Totec's own: the target's tools come first, and nearby commands such as `git` still work (an `env` environment's values are taken as they are) |
| | `replace` | the `nix` environment's `PATH` alone: commands not in the flake cannot be used (elixir-ls uses `git` the first time, so without `git` in the flake it does not start) |
| `env.refresh` | `auto` (default) | when the `watch` files (`flake.nix`, `flake.lock` for a flake) changed, taken again at the next scan or evaluation (that one is a few seconds slower) |
| | `manual` | taken again only at `xipe table generate`; until then the old environment is used, with a warning |
| `eval.timeout` | ms (default 5000, 100–600000) | how long one calc row may run; over it the row is `timeout`. Applies from the next pass |
| `eval.boot_timeout` | ms (default 15000, 1000–1800000) | how long a pass waits for its REPL to be ready (a build included); over it, `boot_failed` |

elixir-ls started for the first time in a new environment compiles itself, which takes time. That scan may give up waiting and switch to the
own parser (`Scanner.Elixir`); from the second time it reads with elixir-ls.

## 5. Dependency-chain negotiation (`xipe dialogue depends`)

For rows joined by references: put a value by hand somewhere upstream and evaluate only from there down. Suited to an upstream that is heavy,
has side effects, or is not written yet ([D-depends](verification/lib-dialogue-depends.exs.md#d-depends)).

```
$ xipe dialogue depends 01M3D3ZXG3XMTYHP4WHCN736VZ
;; w1 Calc.square/1
Supply a value for 01M3D3ZFCV7ZRHV9TSRVETQEE9 and evaluate? (y/n)
> y 4
Supplying a value for 01M3D3ZFCV7ZRHV9TSRVETQEE9 (Calc.square/1) and evaluating from there up to the given row.
row/set-result  ok  %{"id" => "01M3D3ZFCV7ZRHV9TSRVETQEE9", "result" => "4"}
  eval call 01M3D3ZXG3XMTYHP4WHCN736VZ  ok       repr=exact  17  compare=changed
```

- The deepest step is asked first. `y <value>` (a literal of the target language) puts the value on that step and evaluates from there to the
  row named, and ends. `n` moves one step up
- Answering `n` to every step runs nothing
- The steps evaluated include `writes` (if classified)
- From tezcatl's window, start with `dialogue depends <call_id>` and answer `y <value>` / `n` on the next line
- `quit dialogue` stops it midway

### 5.1 Searching (`xipe search`)

A dialogue narrowing tables in turn. It keeps the list (and `x`) within one process, so `xipe search` enters a prompt (`search>`) where turns are
typed; the first turn may follow `xipe search` on the same line. In tezcatl's window, start with `search`, one line a turn
([D-search](verification/lib-dialogue-search.exs.md#d-search)).

```
$ xipe search -s path lib/calc.ex path
1 hit(s). (path: [lib/calc.ex])
search> -e path list id
2 hit(s). (id: [01M3…, 01M3…])
search> get id -2
took the id of element 2 of the result: 01M3… (write x for it from now on)
search> eval x
  eval call 01M3…  ok       repr=exact  9  compare=none
search> -e view id id name args result
…
End the search? y/n
search> y
```

| Turn | What it does |
|---|---|
| `-s\|-e <column> <value> [<out>]` | the `<out>` values (default `id`) of the rows whose `<column>` is `<value>` become the held list |
| `-s\|-e <column> list <out>` | looks up `<column>` for each value of the held list (the list is replaced) |
| `-s\|-e view <column> [<shown>...]` | shows the rows matching the list's values, then asks whether to end (`y` ends, `n` goes on) |
| `get id [-n]` | keeps the list's n-th value (from 1) as `x`; none: `No match data` |
| `quit dialogue` | ends it |
| anything else | runs as an ordinary command (the dialogue goes on); `x` (also `id=x`, `call_ids=[x]`, `⟦x⟧`) is replaced by the kept id |

- `-s` is the surface table (columns `id path depth language repl build_tool`); `-e` is the `eval_table` (calc rows with their function and
  `path` beside them; `-h` shows the columns). The tables and columns are also listed by `xipe do roster`
- Values match exactly. `~<value>` is a substring match (`-e args ~⟦<id>⟧ id`: the rows referring to that row), `-` an empty cell
  (`-e module -`: rows whose function is gone). Numbers compare as text. Over 10 hits: the first 10 and the count
- The search itself changes nothing. Only the ordinary commands typed inside it do

### 5.2 Running a method by being asked (`xipe dialogue do`)

A dialogue that builds `xipe do <method> …` by asking for the arguments one at a time. Values one line cannot carry (lists containing commas,
strings with spaces or quotes, tuples) are passed **as typed**, and no function id needs copying
([D-dialogue-do](verification/lib-dialogue-do.exs.md#d-dialogue-do)).

```
$ xipe dialogue do row/add
node? (a function: its id, or its name as Calc.add/2)
do> Calc.average/1
args? (a list of 1: { alone to open, one per line, } alone to close)
do> {
args: open -- one per line, } alone to close
do> [1, 2, 3]
  1: [1, 2, 3]
do> }
row/add
  args = {
    [1, 2, 3]
  }
  node = 01M4R8BV…  (Calc.average/1)
Run it? (y/n)
do> y
Running row/add.
row/add  ok  …
```

- Only the arguments the method **requires that the line did not give** are asked (`xipe dialogue do effect/set id=Calc.add/2` asks only
  `effect`). Optional arguments are not asked: write them on the starting line
- An answer is the line as it is (no splitting into words, no quotes removed, no commas read)
- **A function** is answered by its id or the name shown: `Calc.add/2`, or `Module.name` in a language without argument counts. When two or
  more functions share the name, the candidates are listed and it asks again. `node=Calc.add/2` on the starting line works too
- **A list** opens with a line holding only `{`, one element a line, and closes with a line holding only `}`. Only whole lines `{` and `}` open
  and close, so an element may be `{1, 2}` or `%{a: 1}`. `{` then `}` is the empty list. A calc row's `args` are counted when the list closes,
  and asked again if they do not fit
- Choices and numbers: a wrong answer asks the same again
- When everything is there, the call is shown as "argument = value". **A method that writes the Book waits for `y` (run) or `n` (drop)**; one
  that only reads runs at once
- `quit dialogue` stops without running anything
- In tezcatl's window, start with `dialogue do <method> …`; one line is one answer

### 5.3 Rewriting a table's value by hand (`xipe dialogue rewrite`)

A dialogue that changes one value of a table **without evaluating**. It asks table → row → column → value. For setting an expectation (`prev`),
putting a value by hand (`result`), changing only the arguments (`args`), changing a function's class (`effect`).

```
$ xipe dialogue rewrite
row? (its id in the eval_table)
rewrite> 01M4R9XA…
id=01M4R9XA…  node=01M4R8BV…  module=Calc  name=average  …  args=[1, 2, 3]  result=2.0  …
column? (args | effect | prev | result)
rewrite> prev
prev? (the line is taken as it is)
rewrite> 3.0
row/set-prev
  id = 01M4R9XA…  (Calc.average/1)
  prev = 3.0
Run it? (y/n)
rewrite> y
Running row/set-prev.
row/set-prev  ok  …
$ xipe eval 01M4R9XA…
  eval call 01M4R9XA…  ok  repr=exact  2.0  compare=changed
```

- Table, row and column may be on the starting line (`xipe dialogue rewrite -e <row id> prev`) and are then not asked. **The value is always
  asked** (on the line it would be split into words, so it is taken as one whole line)
- The table is `search`'s mark (`-e`) or its name (`eval`). While only one table has rewritable columns, it is not asked
- Answering the row shows it with every column (to see what is about to change)
- Rewritable are only the columns `xipe do roster` marks `rewritable`: `args`, `result`, `prev`, `effect`. Others (`compare`, `repr` …) are set by
  evaluation or scanning, and refused
- Each column runs one existing method: `args` → `row/set-args`, `result` → `row/set-result`, `prev` → `row/set-prev`, `effect` → `effect/set`.
  The call is shown first and `y/n` awaited; the method's checks (the argument count, rows in a running pass cannot change) still apply
- **Nothing is evaluated.** After changing `args`, the value stays the old arguments'; `eval` later (to change and evaluate at once:
  `row/update`)
- `effect` is the function's, not the row's: it applies to every row of the function, and that is said before the value is asked
- Values go in as in `dialogue do` (§5.2): the line as it is; a list (`args`) between `{` and `}` lines
- The surface table (`-s`) has no rewritable column yet (`surface/set`, deciding a language by hand, is an idea)
- `quit dialogue` stops without changing anything

### 5.4 Changing a setting (`xipe dialogue update`)

A dialogue that changes one setting of the open project, asking file → key → value. The time limit of a calc row (`eval.timeout`) and the time
to wait for the REPL to start (`eval.boot_timeout`) are changed here.

Each evaluation prints a line with the pass's limits and the file each value came from.

```
$ xipe eval
  eval: limit 5s per row (eval.timeout, /…/xipe_totec/defaults.json), 15s to boot (eval.boot_timeout, /…/xipe_totec/defaults.json)
  eval call 01M4R8BX…  timeout  compare=skipped
$ xipe dialogue update
  1  /…/xipe_totec/defaults.json  (the defaults)
  2  /…/tables/project/001_calc/project.json  (this project's settings)
file? (1-2)
update> 1
/…/defaults.json holds the defaults, which are every project's: the change is written to /…/001_calc/project.json
  env.path = prepend  (prepend|replace)  default
  env.refresh = auto  (auto|manual)  default
  eval.boot_timeout = 15000  (1000..1800000 ms)  default
  eval.timeout = 5000  (100..600000 ms)  default
key?
update> eval.timeout
eval.timeout? (100..600000 ms)
update> 20000
to be written to /…/001_calc/project.json
config/set
  key = eval.timeout
  value = 20000
Run it? (y/n)
update> y
config/set  ok  eval.timeout=20000 (eval.timeout, /…/001_calc/project.json)
```

- **The file**: the settings files that appeared in lines Xipe Totec printed lately, up to five distinct ones, newest first, numbered; answer
  `1`–`5` (or the path). The open project's `project.json` is always among them; with only one, it is not asked
- Two make sense to choose: this project's `project.json` and the defaults, `defaults.json`. **Choosing the defaults does not rewrite them**
  (they are every project's) — it says the value will be written to this project's `project.json` and goes on. Another project's file is
  refused (open it with `xipe choice project` first)
- **The key**: every setting is shown with its current value, what it may be, and whether this project set it or it is the default
- **The value** is checked as typed; a wrong one says why and is asked again. Times are whole ms (`eval.timeout` 100–600000,
  `eval.boot_timeout` 1000–1800000)
- The call is shown and `y/n` awaited before writing. **A changed limit applies from the next pass** (not to a running one; stop it with
  `eval/cancel`)
- File and key may be on the starting line (`xipe dialogue update 2 eval.timeout`); the value is always asked
- The lines said are kept in `tables/logging_buffer.txt` (100 lines; one file for every project, CLI and server alike); answers to the window
  are in it too ([D-log-buffer](verification/lib-log_buffer.exs.md#d-log-buffer))
- `xipe config [key=value]` still works (one line, for scripts); its list gives what a value may be and where it came from

---

## 6. The resident server (`xipe start`)

```
$ xipe start --port 4200
xipe start: ws://127.0.0.1:4200/  root=/home/user/work/calc  store=.../tables/project/001_calc/book.jsonl
xipe start: lsp relay ws://127.0.0.1:4100/lsp  fs_root=-
```

- Listens on `127.0.0.1` only; no authentication
- The port is `--port`, else `$XIPE_TOTEC_PORT`, else 4200
- While it runs, `tables/session.json` records it, and other CLI commands act on its project. A second start is refused. Stopped with
  SIGTERM, the record goes (a record left by `kill -9` or Ctrl-C is ignored)
- Changes the CLI writes during the session are taken in by the server at its next request (writes to `book.jsonl` take turns under a lock);
  the CLI says that it writes `book.jsonl` directly ([D-store](verification/lib-store.exs.md#d-store))

### 6.1 The protocol

Over a WebSocket (path `/`), JSON-RPC 2.0 text, one message a frame. Send `initialize` first; requests before it are refused as
`not_initialized`.

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
← {"jsonrpc":"2.0","id":1,"result":{"capabilities":{},"project":{"id":"001","root":"/home/user/work/calc"}}}

→ {"jsonrpc":"2.0","id":2,"method":"row/add","params":{"node":"01M3...","args":["20","22"]}}
← {"jsonrpc":"2.0","id":2,"result":{"id":"01M3...","row":{...}},"from":null,"dialogue":{"hold":false,"via_repl":false,"text":null}}
← {"jsonrpc":"2.0","method":"notify/rowChanged","params":{"id":"01M3...","columns":[...],"row":{...}}}
```

- Methods and params are those of §3.2; `graph/neighbors` and `graph/export` work here too
  (`{"address":{"module":"Calc","name":"square"},"depth":1,"direction":"both"}`; `graph/export` with `"format":"mermaid"` …)
- `eval`, `eval/run`, `row/update` answer at once with `{"pass_id":...,"status":"started"}` (`"queued"` when another runs) and evaluate in the
  background. When done, every connected client gets `notify/rowChanged` per changed row and finally `notify/passCompleted` (with the results).
  `row/update`'s change of arguments is applied at once (the answer's `row` and a `notify/rowChanged`); only the evaluation runs in the
  background
- `scan/run` answers when it is done; other requests are answered meanwhile
- `notify/rowChanged` and `notify/nodeChanged` arrive whenever rows or cards change
- Answers carry, besides JSON-RPC's usual fields, `from` (always `null`) and `dialogue`
  ([D-envelope](verification/lib-protocol.exs.md#d-envelope))

### 6.2 `input` — sending one line as it is (tezcatl's dialogue window)

`{"method":"input","params":{"text":"<the line typed>"}}`. What the line means is decided by Xipe Totec; tezcatl's window sends every line this
way and does not interpret it ([D-input-line](verification/lib-serve_input.exs.md#d-input-line)).

- A line is written as what follows `xipe` in a terminal (a leading `xipe` is allowed): `help [<command>]`, `version`, `show`, `scan`,
  `eval [id...] [--include-writes]`, `do <method> ... [-- <method> ...]`. A line starting with a method's name is read as `do` left out. Quotes
  (`'id=$0.id'`) are removed as by a shell
- **Wrap string arguments with their quotes**: as above, `"` is removed too, so `args=["hi"]` becomes `args=[hi]` (the variable `hi`) and
  crashes with `undefined variable "hi"`. Write `'args=["hi"]'` (as when typing to a shell)
- **One line is one `input`**. Lines sent one after another run at the same time (each in its own process). To use an earlier line's results
  (functions added by `scan`, a row from `row/add`, an evaluated value) in the next, wait for the answer, or join them with `--` on one line
- Commands that need a terminal (`choice project`, `table generate`, `start`, `config`, `refresh`) are refused as `input_error`
  (`dialogue depends`, `dialogue do`, `dialogue rewrite`, `dialogue update` and `search` work from the window; settings from the window:
  `dialogue update` or `config/set`)
- The answer's `dialogue.text` holds the same lines the CLI prints; for commands, `result.outcomes` also has each command's `method`, `ok`,
  `result`, `error`. A line that cannot be read is `input_error`
- A line containing an evaluation (`eval`, `eval/run`, `row/update`) waits for it to end before the next command, and answers once when
  everything is done (`... -- eval ... -- row/check` means what it means on the CLI). Meanwhile the connection answers other requests
- While a dialogue (a dependency-chain negotiation …) is held, the next line is its answer

```
→ {"jsonrpc":"2.0","id":3,"method":"input","params":{"text":"help"}}
← {"jsonrpc":"2.0","id":3,"result":{},"from":null,
   "dialogue":{"hold":false,"via_repl":false,"text":"help: list the commands (…)  [<command>]\n…\nrow/add: make a calc row  node=<node id> args=[...]\n…"}}
```

One line of `help` is "the command before the first `:`, then the description and the arguments". In tezcatl, yank these lines and press `p` in
the dictionary panel, and the commands become completion candidates.

### 6.3 Using it from tezcatl

Normally `xipe start` is started without `<dir>` on :4200, as a process apart from tezcatl. tezcatl's `t` does not start it (since
2026-10-19, `t` starts only tezcatl's pages and relay). Started from a row of Poca's box, it stops when Poca closes. By hand, for example:

```
nix develop ~/my_app/xipe_totec --command elixir main.exs start --port 4200 \
  --lsp ws://127.0.0.1:4100/lsp --fs-root ~/my_app
```

tezcatl's relay only connects to it, so closing tezcatl's windows does not stop it. The target is the chosen project; with none chosen it ends
at once (said in its log). Xipe Totec decides the target; tezcatl is only the window. Choose it first with `xipe choice project`.

When connecting with tezcatl (the example above, a row of Poca's box, the relay under `xipe.json`'s `mode: "spawn"`), pass `--port`, `--lsp`
(the URL of tezcatl's `/lsp` relay) and `--fs-root` (tezcatl's file root). Scanning then shares tezcatl's language servers. Started by hand,
pass them yourself or set the environment variables (§10). Without tezcatl it works the same, starting elixir-ls itself.

---

## 7. The flow in daily use (summary)

```
xipe choice project ~/work/calc          # once
xipe scan                                # whenever the source changes
xipe show                                # the node ids and the rows' values
xipe do effect/set id=<node> effect=pure # once per function
xipe do row/add node=<node> args=1,2     # keep a call you want to try
xipe eval                                # any number of times; see changes in compare
```

---

## 8. Where the data is

Everything is inside Xipe Totec's directory; nothing is written into the target project. `tables/` is per-machine data and not in git.

| File | Content |
|---|---|
| `info.json` | the registered languages and extensions, each language's REPL and build tools by priority, the REPL adapters |
| `pipelines.json` | the methods made of stages (normally not touched) |
| `project_env.json` | how a target's environment is got (marker, command, format, watch; written as tezcatl's, §4.3) |
| `defaults.json` (at Xipe Totec's root, in git) | the default settings: keys a project did not set come from here |
| `tables/project/<id>_<name>/project.json` | the target project's absolute path (the match key) and its settings (§4.3) |
| `tables/project/<id>_<name>/env.json` | the environment variables taken by `project_env.json`'s entry, which marker, and the hash (§4.3) |
| `tables/project/<id>_<name>/table` | the file → language table (language, REPL, build tool); scanning and evaluation read it |
| `tables/project/<id>_<name>/book.jsonl` | the Book: append-only JSON Lines; the last line of an id is its current value |
| `tables/project/<id>_<name>/passes/` | the passes being evaluated (one file per language; removed when done; `eval/status`, rows in a pass cannot change) |
| `tables/selection.json` | the chosen project (written by `xipe choice project`) |
| `tables/session.json` | the record of a running `xipe start` |
| `tables/logging_buffer.txt` | the lines Xipe Totec printed (100; one for every project; `dialogue update` reads it to offer files) |

`book.jsonl` is only appended to, never rewritten. A broken line (a crash while writing …) is skipped when loading
([D-store](verification/lib-store.exs.md#d-store)).

elixir-ls, however, makes `.elixir_ls/` in a Mix project's directory.

---

## 9. After adding a language (`xipe refresh`)

```
xipe refresh -l     # reads lib/repl/language/*.exs, writes language names, extensions, REPLs and build tools to info.json
xipe refresh -r     # reads lib/repl/eval/scan/<transport>/*.exs, writes the REPL adapters
xipe refresh -a     # both
```

It does not run by itself. After adding or removing a module, or changing a declaration (the build tools' priority …), type it yourself; then
`xipe table generate` in the target project puts it into the table. How to write one: `extending.md` and `repl-adapter-guide.md`. When a
project has two or more registered languages, the rows are split by their function's language (the surface table's `language`) and evaluated in
parallel, one REPL per language. A row referring by `⟦id⟧` to a row of another language is not evaluated: `not run` with the reason (values are
written per language and not converted yet) ([D-languages-per-pass](verification/lib-runner.exs.md#d-languages-per-pass)).

### 9.1 OCaml (2026-09-27)

([D-ocaml-adapter](verification/lib-repl-language-ocaml.exs.md#d-ocaml-adapter))

- Evaluation uses the plain `ocaml` toplevel. It loads `embody.ml` (a separate repository, `~/my_app/embody/`; by default next to Xipe Totec,
  changed with `XIPE_TOTEC_EMBODY_DIR`; without it every row crashes with `Unbound module Embody`) and always wraps each row's call in it. The
  target's `.ml` files load one file one module (`geometry.ml` is `Geometry`). Top-level expressions and `let ()` / `let _` are not run. The order
  of dependencies between files is found by loading again what failed
- A row's arguments are written in OCaml (`args=[Geometry.Circle 2.]`). The call is `M.f (a) (b)` (parentheses per argument); with no arguments,
  the value itself (`M.origin`); a function taking `unit`: `args=[()]`
- `repr`: the displayed value evaluated again and equal by `=` is `exact`. Functions (`<fun>`), cycles (`<cycle>`), inline records and others that
  do not read back are `unsupported`. No `binary`. `type` is OCaml's own type (`Geometry.shape list`)
- Results: an exception is `crash  Exception: Failure "hd".`, a type error OCaml's own words, a timeout `timeout` (SIGALRM per row). No memory
  limit: a wedged toplevel is killed
- Scanning (`Scanner.Ocaml`) reads text: top-level `let` / `let rec` / `and` at the start of a line are functions (`anykey` empty; the later of
  the same name wins). Nested modules are not read yet. Calls are estimated from `Mod.name` and names of the same file
- **dune projects** (`dune-project` at the root): libraries depended on (`str`, outside packages visible on `OCAMLPATH`) are loaded from
  `dune ocaml top`; the project's own code from source (without side effects). Code written from outside a library (`Mylib.Words.count`) works
  (aliases made from the `dune` file's `(library (name mylib))`). dune builds the project at each evaluation (`_build/` appears in the target).
  dune and the dependencies must be in the target's environment (a flake)
- Not supported: files needing ppx (the source is read as it is), two files of the same name, several libraries in one `dune` file (no aliases).
  The language server (ocamllsp) is not used (no `callHierarchy`)

### 9.2 Haskell (2026-09-27)

([D-haskell-adapter](verification/lib-repl-language-haskell.exs.md#d-haskell-adapter))

- Evaluation uses GHCi (`ghci -v0 -fdefer-type-errors …`). It `:load`s `embody.hs` (`~/my_app/embody/`) and the target's `.hs`, and brings each
  module into scope as `*M`: unexported functions can be called as `M.f`. `main` is not run
- A module comes from each file's `module X` line (none: `Main`). For `Geo.Shape` in `src/Geo/Shape.hs`, `src` goes on the search path. Two or more
  `Main` files cannot load together, so then no `Main` is loaded
- A row's arguments are written in Haskell (`args=["x"]`, `args=[[] :: [Int]]`). The call is `M.f (a) (b)`; with no arguments, the value itself
- `repr`: with `Read`, `Show` and `Eq`, a `show` that reads back equal is `exact` (`Map` too). With `Show` only, `unsupported` with `show` cut at
  2,000 characters (infinite lists come back). Without `Show`, `unsupported` with the type as the display (functions `Int -> Int`; `IO [Char]` is
  not run). `type` is the value's type (`[Shape]`, `Map [Char] Int`)
- Failures: exceptions and type errors are `crash` with GHC's words. A syntax error in the call is `crash … Variable not in scope: xt_<id>` (the
  real syntax error is in the REPL's output). A timeout is `timeout`
- Scanning (`Scanner.Haskell`) reads text: top-level definitions at the start of a line (several clauses are one; type signatures, operators
  and declarations left out). Calls from `M.f` (aliases of `import … as N` too), names of the same module, and names imported unqualified
- **cabal and stack projects** (`*.cabal` / `cabal.project`, `stack.yaml` at the root): GHCi starts under `cabal exec --offline --` (after
  `cabal build --offline all`) / `stack exec --`, so dependency packages are visible. The project's own modules — library, executables, tests —
  are read from source. Dependency packages must already be usable (nix's `ghcWithPackages`, a build beforehand …; with `--offline` nothing is
  fetched while evaluating). `dist-newstyle/` / `.stack-work/` appear in the target
- Not supported: running functions that return `IO`

---

## 10. Environment variables

| Variable | Meaning |
|---|---|
| `XIPE_TOTEC_PORT` | `xipe start`'s default port |
| `XIPE_TOTEC_LSP=off` | scan with the own parser, without a language server (the tests run so) |
| `XIPE_TOTEC_LSP_RELAY` | the URL of tezcatl's `/lsp` relay (as `--lsp`) |
| `XIPE_TOTEC_LSP_FS_ROOT` | tezcatl's file root (as `--fs-root`) |
| `TEZCATL_RELAY_PORT` / `TEZCATL_FS_ROOT` | inherited when started by tezcatl; used when the two above are not set |
| `XIPE_TOTEC_EMBODY_DIR` | where embody is (default: `embody/` next to Xipe Totec) |
| `XIPE_TOTEC_ALLOWED_ORIGINS` | `Origin`s the WebSocket accepts (browsers are refused otherwise) |

---

## 11. Common stumbles

| Symptom | Cause and remedy |
|---|---|
| `no project selected` | type `xipe choice project <path>` first |
| `<dir> is not a registered project` | to pass `<dir>`, register it first with `xipe choice project <dir>` |
| `not run  effect not classified` | not classified with `effect/set`. §2.4 |
| `not run  effect=writes -- pass --include-writes` | `xipe eval --include-writes` (in `xipe do`: `eval include_writes=true`) |
| `eval call bash.id  not run  unknown call id` | `$0.id` not wrapped in quotes. §3.3 |
| `crash ... undefined variable "hi"` (meant as a string) | the `"` was removed when the words were read. Wrap it with its quotes: `'args=["hi"]'` (in a terminal and in the window alike; §3.3, §6.2). `dialogue do row/add` passes it as typed (§5.2) |
| A list meant as one argument is split at its commas (`args=[1,2,3]` becomes three arguments) | not writable on one line. `xipe dialogue do row/add` (§5.2): between `{` and `}` lines, one element a line |
| An evaluation that does not end, or that you do not want to wait for | `xipe do eval/cancel` (§3.2), from another terminal or the window too |
| `timeout` (a heavy function) | the per-row limit (default 5 s, §4.1); raise `eval.timeout` with `xipe dialogue update` (§5.4) |
| In the window, a function or row added by the previous line is "not there" | the previous line has not finished (lines run at the same time). Wait for its answer or join with `--` (§6.2) |
| `row/add: ... takes 1 arg(s), got 3` | the number of arguments does not match. Mind that a list cannot be one argument on one line (§3.3) |
| `row/add: ... is private` | a `defp` function cannot have calc rows |
| `skipped  upstream ... has no value that can be written into the call` | the referenced value is not in the table (never evaluated), cannot be written as source (`binary`, `unsupported`), or the referenced row cannot be evaluated. Name the referenced id too, or put a value with `dialogue depends` (§2.6) |
| `row_in_pass: row ... is being evaluated` | that row is being evaluated; change it when done. What runs: `xipe do eval/status` (§3.2) |
| Line numbers in a `crash`'s stack trace are off | for a target without `mix.exs`, they are the line numbers of the extracted temporary file |
| `boot_failed: the REPL exited before it was ready` | `iex` exited while starting; usually the target's code does not compile. The output that follows gives the file and line |
| `boot_failed` (`:timeout`) | the REPL did not start in time (default 15 s). Raise `eval.boot_timeout` (§5.4), or for a Mix project run `mix compile` once beforehand |
| `xipe start: a session is already running` | it already runs. To stop it, send SIGTERM to the pid in the record |
| CLI changes do not appear in the server's table | the server takes them in at its next request, but tezcatl's table does not change by itself: fetch again with `matrix update` |
| Scanning is slow | the first time waits for elixir-ls to start. To hurry: `XIPE_TOTEC_LSP=off` |
| `env stale (flake.nix)` | with `env.refresh=manual`, a `watch` file (the flake) changed. Take it again with `xipe table generate` (§4.3) |
| `env error (flake.nix)` | `project_env.json`'s command failed (an evaluation error in the flake, `flake.nix` untracked in git, a timeout …; the message ends with the command's last stderr line). The parentheses give the marker. Xipe Totec's own or the previous environment is used |
| A mix project starts in scripts-mode | the build tool is what was decided when the table was made: type `xipe table generate` |
| `stdio: language server exited (status 1)` (`env.path=replace`) | the flake's `PATH` lacks a command elixir-ls needs (`git` …). Add it to the flake, or use `prepend` |
