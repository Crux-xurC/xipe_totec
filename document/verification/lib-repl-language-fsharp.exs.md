# `lib/repl/language/fsharp.exs`

F#'s declaration: extensions `fs`, `fsx`, REPL `fsi` (F# Interactive) with `embody.fsx`, build tool `dotnet` (`*.fsproj`, `*.sln`,
`*.slnx`), scanner `Scanner.FSharp`; `launch_opts/3` writes the start script (build, the scripts' definitions-only copies, then fsi) and
the init file into a temp dir, and names the copies to load. The adapter is `lib/repl/fsharp/launch.exs`,
`lib/repl/fsharp/eval_template.exs` and the iex scan / field_drip it delegates to (`lib/repl/eval/scan/direct/fsi.exs`,
`lib/repl/eval/field_drip/fsharp.exs`); the scanner `lib/scanner/fsharp.exs` with `lib/scanner/fsharp/scan.fsx`.

**Decisions homed here**: [D-fsharp-adapter](#d-fsharp-adapter)
**Takes part in**: D-embody ([`lib/repl/embody.exs`](lib-repl-embody.exs.md)), D-language-adapter
([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md)),
D-restart-after-timeout ([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md))

<a id="d-fsharp-adapter"></a>

## D-fsharp-adapter — F# in F# Interactive with `embody.fsx`; read by F#'s own parser

**Decided** (2026-11-20, crux: F# before C#, C# then on top of it through a seam; checked with the .NET 8 SDK 8.0.419):

- **A project is built, its scripts cut down.** Every `*.fsproj` (outside `bin/`, `obj/`, hidden directories) is built with `dotnet build
  <project> -o <temp>/out --source <empty dir> --nologo -v q --disable-build-servers` and its assembly `#r`-ed. Each `.fsx` is loaded as
  a copy holding only its definitions (`embody.fsx`'s `Embody.Load`, F#'s parser): `let` functions, `let` values that run nothing (a
  literal, a name or a chain of names, a tuple, list or array of those, a lambda), types, exceptions, `open`, module abbreviations, nested
  modules read the same way, hash directives but `#r "nuget: …"`. `printfn …`, `do …`, `let x = f ()` do not run — what Elixir's
  scripts-mode does with `defmodule`. The copies keep the scripts' paths under `<temp>/fsx/`, so `#load "other.fsx"` loads the other copy.
  A `.fs` file no project builds is on the map only
- **Nothing is fetched, nothing of `bin/` written**: FSharp.Core comes from the SDK's own `library-packs` (checked: an empty package
  source and an empty NuGet cache build); any other package must already be in the cache. `obj/` is written into the project.
  `DOTNET_CLI_TELEMETRY_OPTOUT=1`, `DOTNET_NOLOGO`, `DOTNET_SKIP_FIRST_TIME_EXPERIENCE`, `MSBUILDDISABLENODEREUSE=1` and
  `--disable-build-servers`: no network, no MSBuild node or compiler server left behind
- **Loading**: all of it is one `sh <start script>` under `eval.boot_timeout`, in the project's environment. The init file
  (`--use`) `#load`s `embody.fsx` and `#r`s the assemblies the build produced; the copies are `#load`-ed **over stdin**, ahead of the
  ready probe, each its own submission (`Embody.trying` / `#load` + `Embody.loaded`): fsi stops reading an init file at its first error,
  and over stdin one script that does not compile leaves the others loaded. `Embody.loaded` counts a script only when fsi made its
  start-up type (`$FSI_0002_Tool$fsx`): fsi does not compile a second time a file another script `#load`-ed and failed on. The start
  script marks its work done; a second start in the pass (after a `timeout`) only starts fsi
- **One entry is three submissions**, as for C# before it: `Embody.start "<id>" <ms> <basis>;;` /
  `let xt_<id> = Embody.call (fun () -> Ns.Module.f (a) (b));;` / `Embody.finish "<id>" "Ns.Module" "f" <count>;;`. fsi cannot evaluate a
  string from inside, so the call is compiled by fsi itself; one that does not compile leaves `xt_<id>` unbound and fsi's diagnostic on
  the output, and `finish` reports a `crash` with what reflection tells, in F#'s terms: no such module (with the build's first error, or
  the scripts that did not load), `private` or `internal`, a value and not a function, how many arguments it takes, its signature
  (`add : int -> int -> int`). `EvalTemplate.check/1` refuses an argument that would leave fsi reading on (an open string, comment or
  bracket, `;;`)
- **Calls and `anykey`**: a calc row's arguments are the function's curried arguments, applied in order: `Ns.Module.f (a) (b)`, each in
  parentheses. `anykey` is their number as written — `let f a b` 2, `let f (a, b)` 1 (the tuple is one argument), `let f ()` 1 (the
  argument `()`) — though the compiled method has 2, 2 and 0 parameters; so `row/add` checks the count as for Elixir's arity, and a
  partial application is not a row. A module or function name that is not an identifier is written in double backticks (a script
  `my-tool.fsx` is the module ``` ``My-tool`` ```). `let inline` functions are called as any other (inlined at the call)
- **Static members** (2026-11-20, §4.4 of `evolving.md`, rule 6): a type's `static member` with arguments is a node of the module named
  by the type (`Sample.Conv`), each overload its own: `anykey` the parameters' types written out from the syntax tree in one form, one
  parenthesized group per curried group (`(int)`, `(string)`, `(float, int)`, `(float)(Point)`, `()`, `(int * int)` for one tuple
  parameter; `_` for a parameter without a type), the shape the count per group (`[1]`, `[2]`, `[1, 1]`, `[0]`)
  ([D-anykey-shape](lib-identity.exs.md#d-anykey-shape)). The call is a method call split by the shape, each argument in parentheses:
  `Sample.Conv.Show((1.5), (2))`, `Sample.Conv.Scale((2.0))((p))`, `Sample.Conv.Origin()`, `Sample.Conv.Sum((1, 2))`; fsi picks the
  overload by the arguments' types (`Show(1)` the `int` one, `Show("a")` the `string` one). A call that does not compile is told in
  members' terms: the type's public overloads with their signatures (`Show(int) : string; Show(float, int) : string`), the counts they
  take, a static property (a value), a member that is `private`. Static properties, instance members, constructors and operators are
  not nodes. Why: a type's static members are how F# libraries meant for C# callers are written, and how C#'s methods reach fsi; they
  are the same kind of thing as C#'s methods, so the same identity (a sequence of types) serves both. Module functions keep their
  curried count as `anykey` (no overloads, no shape)
- **repr**: `exact` for what `embody.fsx` writes as an F# literal and reads back to an equal value: the primitive types, enums by name,
  arrays, lists, `List<T>`, `Dictionary<K, V>`, options, tuples — and F#'s own **records** (`{ Sample.Point.X = 2.0; Y = 3.0 }`, the first
  field qualified by the type) and **unions** (`Sample.Shape.Rect (2.0, 3.0)`, `Sample.Shape.Empty`) with public representations. The
  text is F# source, so a later row takes it as an argument as it is. A union value's type is its union, not the case's class; a function
  value's type is `int -> int` (`unsupported`). Otherwise `binary` through System.Text.Json, or `unsupported`, as before
- **Helpers** (2026-11-20, for C#'s seam, `evolving.md` §4.4 rule 1): `embody.fsx` asks a registered `Helper` (`Embody.register`)
  only where its own writer, reader, equality and diagnosis have no answer; a covered value is written as its constructor's call
  (`Sample.Point(2.0, 3.0)`), its arguments by embody's own writer. Checked by the live test with a helper written in F#
- **`Embody.reference`** (2026-11-20): the init file names each `#r`-ed dll to embody after referencing it. fsi loads a referenced
  assembly only when a submission first uses it, so a pass whose first row does not compile found "no module" for a module that is
  there; `finish` now loads the named dlls (the same assembly fsi loads, by path) before diagnosing. Checked by the live test (a pass
  of one private function's row)
- **Time**: `call` runs the thunk on a thread of its own under `ControlledExecution.Run` with the limit; a native wait is stopped waiting
  for at the limit + 0.5 s. The launch declares `restart_after_timeout` ([D-restart-after-timeout](lib-repl-evaluator.exs.md#d-restart-after-timeout))
- **Scanning**: `Scanner.FSharp.begin/3` runs `lib/scanner/fsharp/scan.fsx` once in `dotnet fsi` over every F# file (FSharp.Compiler.Service,
  `#r "FSharp.Compiler.Service"` by name: it comes with the SDK). A node is a module-level `let` with arguments, in a module of a `.fs` or
  `.fsx` (nested ones too); `module` the module's full name (`Sample.Geo.Inner`, a script without `module` its file's name); `public`
  unless it or an enclosing module is `private` / `internal`; and a type's `static member` with arguments (above). Values, operators,
  instance members, static properties and local functions are not nodes.
  Links: every name a body uses that is a node, looked up the way F# does — the function's module and the enclosing ones innermost
  first, then the `open`s before it (also relative to the enclosing namespace), then the name as written. No `dotnet` on the project
  environment's `PATH`: the scan fails with that reason

**Why**: aiming at C# and Java first made fsi carry two languages at once (C#'s `public static` and overloads in `embody.fsx`, F#'s
values as C#'s arguments). F# is fsi's own language: the literal `exact` writes is the language's own, calls and failures are in its own
terms, and `let` functions have no overloads. F#'s parser comes with the SDK, and an F# project always has the SDK (P10), so reading
the text with it beats a text scanner for an indentation-based language (`let rec … and`, attributes, multi-line patterns). Loading
scripts as definitions only keeps "loading runs none of the target's top-level code" (README).

**Alternatives**: a text scanner in Elixir (D-scanners' precedent: no SDK to scan; not taken for F#, whose layout is by indentation);
the F# compiler service's type checking for exact links (needs the project's references: later); `#load` of the scripts as they are
(runs their top level); scripts map-only (the precedent is to load definitions); loading the copies from the init file (one failure
stops the rest); a node for every `let` value (`let addTen = add 10` is a function only by how it is written: values are left out,
`scope.md`).

**Files**: `lib/repl/language/fsharp.exs`, `lib/repl/fsharp/launch.exs`, `lib/repl/fsharp/eval_template.exs`,
`lib/repl/eval/scan/direct/fsi.exs`, `lib/repl/eval/field_drip/fsharp.exs`, `lib/scanner/fsharp.exs`, `lib/scanner/fsharp/scan.fsx`,
embody's `embody.fsx`; tests `test/fsharp_adapter_test.exs`, `test/live/repl_fsi_test.exs`; fixture `test/fixtures/fsharp_sample/`.

## The REPL as checked (`extending.md` §2.2), 2026-11-20, .NET 8 SDK 8.0.419 (`dotnet fsi`)

| Item | F# through `dotnet fsi --quiet` |
|---|---|
| Start | over a pipe: no banner, no prompt with `--quiet` (values not echoed either); about 3 s, the build of a small project about 2 s, the scripts' copies about 2 s |
| Loading | `#r` of the built dll: nothing of the project runs. `#load` of a script runs its top level (hence the copies). An init file (`--use`) stops at its first failing submission; stdin goes on |
| What the dll shows | a module is a static class (`CompilationMapping(Module)`), a nested one `Outer+Inner`; `let f a b` a method of 2 parameters with `CompilationArgumentCounts [1;1]`, `let f (a, b)` 2 parameters without it, `let f ()` none; a value a property; `private` / `internal` not public. Scripts' modules are `FSI_000N.Tool` |
| Evaluation and display | `Sample.Calc.add (1) (2)`, `addPair ((1, 2))`, `answer ()`; `let inline` works for any type; a partial application gives a closure |
| Static members (2026-11-20) | the parser gives `static member` with `MemberKind.Member` and not `IsInstance`, its argument patterns one per curried group (`Pats []` for a property); the dll has one static method per overload, a curried member with `CompilationArgumentCounts`, a tupled one-parameter member (`Sum((a, b))`) one tuple parameter. `Conv.Show((1))` / `Show(("a"))` / `Show((1.25), (1))` each pick their overload; `Scale((2.0))((p))`; `Origin()`; `Sum((1, 2))` passes the tuple as one argument |
| Failure | a type error, a private function, an unknown name: fsi's diagnostic (in the locale's language), the REPL reads on after `;;` |
| Time limit, SIGINT | as for the C# attempt: `ControlledExecution` on a thread of its own stops a loop; SIGINT prints `- Interrupt` and fsi reads on |

## Notes

- Verified: `test/fsharp_adapter_test.exs` (15 tests), `test/live/repl_fsi_test.exs` (8 tests, against the .NET 8 SDK from xipe_totec's
  nixpkgs pin: the scan, values of every kind, scripts' functions with their top level not run, compare, the failures, a timeout and the
  new session, a failing build, a package not in the cache (`NU1101` named), a script that does not compile), and the CLI end to end on a
  copy with its own `tables/` (`refresh -l`, `choice project`, `scan`, `effect/set`, `row/add` refusing a private function and a wrong
  count, `eval` twice: `same`), 2026-11-20
- A script whose definitions use a value its top level computes (`let n = f ()`) does not load: that value is not in the copy, and the
  script fails to compile as a whole. Its rows are `crash` naming the script; a script that `#load`s it fails with it
- A chain of names is kept as a value that runs nothing (`let now = System.DateTime.Now` is kept, and its property runs when the copy
  loads), as Python keeps an alias
- C# comes on top of this adapter, after Scala, with a seam (`embody.cs`) for `Task`, values and failure reasons
  ([`evolving.md`](../evolving.md) §2, 7 and §4.4); the earlier attempt (C# alone through fsi) is on a local branch `csharp-via-fsi`
