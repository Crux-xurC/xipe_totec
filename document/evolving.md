# Evolving: languages beyond Elixir, OCaml, Haskell and Python

Where Xipe Totec's languages are going: what is decided, in what order, what each language needs, and what is set aside and why. The
promise for today is [`scope.md`](scope.md); how to add a language is [`extending.md`](extending.md) and
[`repl-adapter-guide.md`](repl-adapter-guide.md); a language's decisions, once implemented, go to its file record in
[`verification/`](verification/index.md). This document says where things stand, and shrinks as languages are done.

Started 2026-11-16 (crux); replaces a Japanese working note of the same day. Where the estimates below and the checks on real REPLs
(§5) disagree, the checks are right.

## 1. Why widen at all

README.full.md's P1 ("assume referential transparency") and "for functional-language projects" came from a belief that a REPL can only serve
functional languages. It cannot do everything in other languages, but what it can do is worth having (crux, 2026-11-16). P1 is read as
"side effects are separated with `effect/set`", not as a precondition on the language.

## 2. Common ideas

Nothing new in the design: every plan sits on the existing division of work.

1. **A language is not its REPL (the REPL is a window).** The surface table has language, REPL and build tool as separate columns.
   C# files can be evaluated in `fsi`, Java files in Scala's REPL; several languages can share one REPL (`info.json`'s `language_repls`)
2. **embody is per REPL.** `embody.ml` is for OCaml's toplevel, `embody.hs` for GHCi, `embody.py` for `python -i`; a new REPL adds one
   `embody.<ext>`, keeping embody's principles (independent of the target, the standard environment only, one write per record, a time
   limit per entry, `exact` only for values that read back, `xt_<id>` bindings)
3. **A driver where there is no usable REPL.** A small program, embody itself, reads one entry at a time from stdin, evaluates it and
   prints the same markers. Over a pipe it looks like a REPL, so `Sender.Direct` and the Evaluator do not change (Go, PHP)
4. **Two stages: the map, then evaluation.** The *map* is the scan: cards, links, `search`, `graph/*`, the surface table. It needs no
   REPL and is worth having on its own for taking over a codebase. A language (or a part of one) may stop at the map
5. **Targets are top-level functions callable with literals.** Instance methods and code needing dependency injection are outside
   `row/add`, as Elixir's `defp` is, and shown by the visibility column
6. **Arguments are written as literals of the REPL's language.** A C# function evaluated in `fsi` takes an array as `[|1;2|]`. The same
   kind of effort as Nanahuatzin's "values are written as the back end's literals"
7. **The window's own language first, then the other language through a seam** (decided 2026-11-20, crux). A REPL is first made to
   serve its own language (F# in `fsi`, Scala in Scala's REPL), and its embody stays that language's alone. The language it is a window
   for (C#, Java) comes after, adding a **seam**: a small project in that language, built in the pass's temp dir next to the target's
   build (never written into the target) and loaded into the REPL with it; it works by reflection, so it needs no reference to the
   target (C#'s, 2026-11-20). The seam works only **on the side
   that receives the result**: it brings the language's meaning to the window's language — values (records, futures awaited), and
   failure reasons in the language's own terms. The arguments stay the window's literals. `anykey` is the parameters' types and the
   argument count a node's shape ([D-anykey-shape](verification/lib-identity.exs.md#d-anykey-shape)); type arguments are not decided for either pair

## 3. Where each language stands

| Language | Window (REPL) | embody | Stage | State |
|---|---|---|---|---|
| Python | `python -i` | `embody.py` | map + evaluation | **done** 2026-11-16 ([D-python-adapter](verification/lib-repl-language-python.exs.md#d-python-adapter)); applied to toolz 2026-11-17 |
| Rust through Rustler | iex (as today) | an opt-in convention on the Elixir side | map (Elixir side) + evaluation | works today without a new adapter (§5); the convention is not made |
| JavaScript / TypeScript | — | — | **map only** (decided 2026-11-17, §4.1) | **done** 2026-11-17 ([D-map-only-language](verification/lib-repl-language.exs.md#d-map-only-language)) |
| Go | — | — | **map only** (decided 2026-11-20, §4.3) | **done** 2026-11-20 ([D-map-only-language](verification/lib-repl-language.exs.md#d-map-only-language)), read by Go's own parser; a driver left to the users (§8) |
| F# | `dotnet fsi` | `embody.fsx` | map + evaluation | **done** 2026-11-20 ([D-fsharp-adapter](verification/lib-repl-language-fsharp.exs.md#d-fsharp-adapter)) |
| Scala | Scala's REPL | `embody.scala` | map + evaluation | **done** 2026-11-20 ([D-scala-adapter](verification/lib-repl-language-scala.exs.md#d-scala-adapter)); sbt and scala-cli, mill later |
| C# (F# as the window, a seam `embody.cs`) | `dotnet fsi` | `embody.fsx` + `embody.cs` | map + evaluation | **done** 2026-11-20 ([D-csharp-adapter](verification/lib-repl-language-csharp.exs.md#d-csharp-adapter)); reading C# by Roslyn's parser is a proposed revision (§4.4) |
| Java (Scala as the window, a seam `embody.java`) | Scala's REPL | `embody.scala` + `embody.java` | map + evaluation | **done** 2026-11-20 ([D-java-adapter](verification/lib-repl-language-java.exs.md#d-java-adapter)); maven, gradle later |
| PHP | — | — | **map only** (decided 2026-11-20, §4.7) | **done** 2026-11-20 ([D-map-only-language](verification/lib-repl-language.exs.md#d-map-only-language)), read by PHP's own lexer; a driver left to the users (§8) |
| Rust alone | — | — | — | **set aside** (§6), left to the users (§8) |
| TypeScript's logic evaluated | — | — | — | **set aside** (§6) |

### Order

Cheapest checks first; each step makes the pattern the next one uses. Changed 2026-11-20 (crux): a window's own language comes before
the language it is a window for (§2, 7) — aiming at C# and Java first made one embody carry two languages at once. Both windows' own
languages come first: Scala before C#, so the two seams are made knowing both windows (and the running `xipe start` is restarted once,
after Scala).

1. Rust through Rustler: already evaluates (§5). Add embody's opt-in convention (§4.2) when a project needs `ResourceArc`'s contents
2. Python: done
3. JavaScript / TypeScript, map only: done; the pattern for Java's and PHP's maps
4. F#: done — `embody.fsx` F#'s own
5. Scala: done — `embody.scala` Scala's own; the second window
6. C#: done — on F#'s adapter, with a seam `embody.cs` (§4.4): the first pair of a language and another language's REPL
7. Java: done — on Scala's adapter, with a seam `embody.java` (§4.6): the same pattern
8. PHP and Go: done as maps (crux, 2026-11-20: the map completes Xipe Totec for now; their drivers, like Rust alone, are
   left to the users, §8)

## 4. Per language

### 4.1 JavaScript / TypeScript — the map only

**Decided 2026-11-17 (crux): scan and links, no evaluation.** JavaScript and TypeScript are mostly the language of the surface (UI); the
logic worth evaluating lives elsewhere. Evaluating it would need, for loading without the top level, TypeScript's compiler API taken from
the target — a special case no other language has, and a distortion of Xipe Totec's side not worth accepting for it. The checks of
2026-11-16 (§5) stay as the record of what evaluation would meet.

- Declaration: language `javascript` (`js`, `mjs`, `cjs`) and `typescript` (`ts`, `tsx`?), no REPL; build tools npm, pnpm, yarn
  (`package.json` and each lock file)
- Scan: typescript-language-server (checked: `documentSymbol` and `callHierarchy`) as a `Scanner.Lsp` dialect, and/or a text scanner
  like Python's for when no server is installed (D-scanners)
- Nodes: top-level functions and `export`ed ones (`function f`, `export function f`, `const f = (…) =>`); whether class methods and
  object members become nodes is decided when the scanner is made
- Done 2026-11-17 as D-map-only-language: a declaration without a REPL; `row/add` refuses, `eval` leaves `not_run`. The text scanner
  came first; typescript-language-server as a `Scanner.Lsp` dialect is left for later
- tezcatl's own code mapped: 1664 nodes, 1218 links with its Elixir; its `lib/` is wrapped in one function per file, which the scanner
  reads through

### 4.2 Rust through Rustler

- No new adapter: a Rust function exported as a NIF is an Elixir function of a Mix project, evaluated by `iex -S mix` (`mix compile`
  calls cargo)
- Values returned through `NifStruct` / `NifMap` are Elixir structs and maps: `exact` as they are
- The hole is `ResourceArc`, seen as `#Reference<…>` and `unsupported`. Filled by an **opt-in convention**: embody's body stays on the
  Elixir side (embody's principles 1 and 2); when the NIF module exports functions of agreed names (`embody_show/1`, `embody_dump/1`,
  `embody_load/1`, found at run time with `function_exported?`), they are used; otherwise `unsupported` as today. On the Rust side, a
  small derive or macro the target chooses to add (`Debug` for the display, serde for `bin_base64`) — the same shape as Haskell's embody
  stepping down when `Read` / `Show` instances are missing
- A NIF cannot be interrupted: a run that does not end is `session_hung`, the rest `aborted`, the REPL killed (§5) — the session thrown
  away without changing the generic layer, recorded as `session_hung`, not `timeout`. `max_heap_size` does not count native memory
- Whether Rust's own side gets cards too (rust-analyzer), matched with the Elixir side at the boundary, is not decided

### 4.3 Go — the map (a driver left to the users)

**Decided** 2026-11-20 (crux): Go stops at the map, which completes Xipe Totec's languages for now; evaluating Go (the driver below) is
left to the users (§8). The map is read by **Go's own parser** (`go/parser`, `go/ast` from the standard library: `lib/scanner/go/scan.go`
run once per scan with `go run` from its own directory, no module, nothing fetched — every Go project has `go`, P10), not gopls (a
server) nor a text scanner. A package is its import path (the nearest `go.mod`'s `module` and the directory); functions and methods
(`T.M`) are cards, `anykey` `nil` (no overloads); `vendor/`, `testdata/`, `init` and `_` left out; a name two files of a package define
(build-tag variants) is one card, the first file's, each file told. Links: the own package, an import by its name or alias, the
receiver's methods ([D-map-only-language](verification/lib-repl-language.exs.md#d-map-only-language), `Scanner.Go`).

What a driver would be (2026-11-16, kept for whoever adds evaluation):


- Declaration: language `go`, build tool go (`go.mod`), the REPL a driver `embody.go`: for each entry it generates a temporary `main`
  with the bindings so far and runs `go run` (1.8 s the first time, 0.07–0.2 s with a warm cache). yaegi is not used (§5)
- Re-running: earlier entries run again each time. Fine for `pure` and `reads`; `writes` must not run again — `exact` values carried as
  their `%#v` literals instead of re-running
- Unexported functions: `-overlay` of `go build` / `go run` can add a file to the package without writing into the target (to check)
- repr: `%#v` (`&T{…}` is a literal that reads back); `reflect.DeepEqual`. Functions and channels `unsupported`; a struct with
  unexported fields cannot be rebuilt outside its package (`binary` by rebuilding inside the package, or `unsupported`)
- Failures: `defer` / `recover` per entry; `(value, error)` returns need a convention (the number of results from gopls)
- `init()` runs every time (unavoidable while the package is imported)
- Scan: gopls as a `Scanner.Lsp` dialect

### 4.4 C# — F# as the window, through a seam

Decided 2026-11-20 (crux), on top of F#'s adapter ([D-fsharp-adapter](verification/lib-repl-language-fsharp.exs.md#d-fsharp-adapter)),
the first case of §2, 7:

- Declaration: language `csharp` (`cs`), REPL `fsi`, build tool dotnet (`*.csproj`, `*.sln`): the project built and `#r`-ed as F#'s is
- The seam: `embody.cs`, a small C# project **built in the temp dir** next to the target's build (never written into the project),
  `#r`-ed into fsi with the target's assemblies (it works by reflection: no reference to them, rule 1 below). Its one job is to bring C#'s meaning to F# **on the side that
  receives the result**: a `Task` awaited (`async` methods), values (C# records, anonymous types, what F# cannot read back), and failure
  reasons in C#'s terms (`public static`, overloads). `out` / `ref` are left to F#
- Calls: `Ns.Class.Method(a, b)`; the arguments stay F# expressions (C# text cannot be evaluated: Roslyn's scripting is not in the SDK)
- `anykey` (crux, 2026-11-20, [D-anykey-shape](verification/lib-identity.exs.md#d-anykey-shape)): always the sequence of the parameters' types, so overloads are nodes of their
  own, also when they share a parameter count (the first attempt made them one node, the first). The argument count is the node's
  shape (`[2]` for `Method(a, b)`), and `row/add` checks the arguments against it. **The first work of C#** (crux, 2026-11-20): the
  attempt on `csharp-via-fsi` still has the parameter count as `anykey`; it moves to the sequence of types, and F#'s static members of
  types with it, on the shape that Scala's adapter put in. The types are written out from the syntax tree in one form, as Scala's
- Not decided: type arguments (a generic method whose type appears in no argument)
- The first attempt (C# alone through fsi, a text scanner, 2026-11-19) is on the branch `csharp-via-fsi`; its scanner and tests can be
  taken from there

Checked 2026-11-20 for the seam (.NET 8 SDK 8.0.419 from xipe_totec's pin; a C# target with records, `async`, overloads, generics,
`out`, optional and `params` parameters, and a seam project `XtSeam` beside it):

| Item | What happened |
|---|---|
| Building the seam | A C# class library in the temp dir referencing the target's `Target.dll` by `HintPath`, built with an empty package source: 1.7 s, nothing fetched; its `obj/` in the temp dir only. Both dlls `#r`-ed into fsi |
| Overloads of one parameter count | F# picks by the arguments' types: `Over(1)` the `int` one, `Over("a")` the `string` one, `Over(1.0)` the `double` one; `int` widens to `long` (`Wide(1)`). `Over(null)` silently picks the `string` one |
| `async` | `Seam.Settle` (`GetAwaiter().GetResult()`, then `Result`) gives `Task<int>`'s value; a plain `Task` gives `null` |
| Records | `ToString` `Point { X = 2, Y = 3 }`; F# builds one with its constructor (`Sample.Point(2.0, 3.0)`) and `=` compares values. A record holding a `List<int>` is not `=` to an equal one (the list by reference). An anonymous type prints `{ N = 1, S = 1 }` |
| Generic methods | `Id(1)` infers `int`; `Twice("a")` gives a `List<string>`. **`Make<T>()`, whose type parameter is in no parameter, called without a type argument is silently `Make<obj>()`**: a wrong value, no error |
| `out`, optional, `params` | `Out(3)` returns the tuple `(3, 6)` (the caller does not write the `out` argument); `Opt(1)` and `Opt(1, 2)`; `Params(1, 2, 3)` and `Params([|1; 2|])` |
| Failures | A C# exception is its own text (`System.ArgumentException: bad a (Parameter 'a')`); a C# value tuple shows as F#'s `struct (3, "3")` |

Decided 2026-11-20 (crux), from these checks:

1. **Reading a C# value back is `embody.cs`'s work.** It writes a record as an F# expression of its primary constructor
   (`Sample.Point(2.0, 3.0)`, a later row takes it as it is), reads that text back itself, compares by the properties (a `List` inside
   element by element), and says why a call failed in C#'s terms (not `public static`, an instance method, the overloads' C#
   signatures). `embody.fsx` gets one language-neutral entry and nothing of C#: before judging a value its own writer does not cover,
   it asks a helper registered at the start (`embody.cs` registers itself), and it hands the helper its own reader and writer for the
   nested values (numbers, strings, lists inside a record). The seam works by reflection, so it needs no reference to the target: one
   small project built in the pass's temp dir (§2, 7 said "referencing the target"; not needed)
2. **Overloads of one parameter count**: the call gives each argument its parameter's type, from `anykey`, C#'s type names mapped to
   F#'s (`Over((null : string))`; `double` is `float`, `long` `int64`, `List<int>` `List<int>`, `int[]` `int[]`). Other calls as they are
3. **A type parameter in no parameter** (`Make<T>()`): `row/add` refuses the method with the reason until type arguments are decided
   (called without one it would run as `obj`, silently: P9). A method whose type parameters all appear in its parameters is called as
   it is
4. **The shape**: an `out` parameter is not written by the caller (out of the shape; in `anykey` as `out int`); optional parameters as
   Elixir's default arguments (the shape counts all of them, `arity/set` allows fewer); a `params` array counts as one
5. **`async`**: the scanner marks a method returning `Task`, `Task<T>`, `ValueTask` or `ValueTask<T>`, and the call is wrapped in
   `Seam.Await(…)`, typed: a later row gets the `T`
6. **F#'s static members of types become nodes**, with the sequence of types as `anykey` (as C#'s methods); F#'s module functions keep
   their curried count

The work, in order (one commit each where it stands alone):

1. **F#'s static members** (done 2026-11-20): `scan.fsx` reads `static member` of types (and their overloads) as nodes, `anykey` the parameters' types
   from the syntax tree in one form, the shape one list (tupled) per parameter group; the call `Ns.Type.Member((a), (b))`. Tests on the
   F# fixture, the live fsi test
2. **C#'s scanner on main** (done 2026-11-20; the marks and the refusal reach the node through
   [D-node-marks](verification/lib-identity.exs.md#d-node-marks); an expression body holding braces, `=> new List<T> { x, x };`, was lost
   by the branch's scanner and is read now): `Scanner.CSharp` taken from `csharp-via-fsi`, `anykey` the parameters' types (normalized from its tokens:
   spacing does not move an id; `int` against `System.Int32` stays as written), the shape (rule 4), marks for `async` (rule 5) and for a
   type parameter in no parameter (rule 3, `row/add` refuses). Unit tests on the fixture, extended with records, `async`, overloads of
   one count, generics, `out`, optional, `params`
3. **`embody.fsx`'s helper entry** (rule 1), language-neutral; embody's ReadMe (done 2026-11-20: `Embody.register` takes a `Helper`
   of `Func`s over .NET's own types. embody's reader keeps its place in the text and is private to the script, so instead of handing it
   over, the helper describes a value as its constructor's call — `Head`, the parameter types `Parts`, `Split` a value into its
   arguments, `Make` one from them — and embody.fsx writes, reads back and compares the arguments itself, with a covered value inside
   another written the same way; `Diagnose` answers first for a call that did not compile. The same division as rule 1: the knowledge
   of C# in the helper, the F# literals in embody.fsx)
4. **`embody.cs`** (done 2026-11-20; embody's ReadMe "C# through F# Interactive"; `embody.fsx` gained `registerType`, and
   `reference` so a call that fails before any other has run still finds the dll's types — F#'s adapter writes it too; checked by
   `test/live/repl_csharp_test.exs`, which builds the seam and the fixture by hand until 5): `Await`, the helper (records, anonymous types `unsupported` with their display, equality by properties), the
   diagnosis in C#'s terms; built in the temp dir with an empty package source; the protocol as `embody.scala`'s
5. **C#'s declaration and launch on F#'s** (done 2026-11-20: `lib/repl/language/csharp.exs`, `lib/repl/csharp/launch.exs` and
   `eval_template.exs` on F#'s `build`, F#'s `assembly_name`; the start script checks `embody.fsx`, `embody.cs` and its
   `EmbodyCs.Seam.Protocol` first and ends at once naming them, as Scala's; `#r` and `Embody.reference` for every dll, the seam's too.
   Rule 2 needs to know that another overload shares the count, which only the scanner sees: it marks such overloads `"typed"`
   (D-node-marks), and the template annotates an argument when C#'s type has an F# name without doubt — a project's type or a type
   parameter is left to fsi. Checked by the live test through the launch and on a copy through the CLI): `csharp` (`cs`), REPL `fsi`, build tool dotnet (`*.csproj`, `*.sln`, `*.slnx`): the target
   and the seam built, both `#r`-ed, the seam registered; the call template with the type annotations of rule 2 and `Seam.Await` of
   rule 5; `info.json` (`refresh -l -r`)
6. **Tests and the record** (done 2026-11-20: [D-csharp-adapter](verification/lib-repl-language-csharp.exs.md#d-csharp-adapter)): `test/csharp_adapter_test.exs`, `test/live/repl_csharp_test.exs` (or the fsi one), the CLI on a copy;
   D-csharp-adapter in `verification/`, `scope.md`, `how-to-use.md` §9, README, this §3; the live tests of the other languages before
   committing

Then Java (§4.6) the same way on Scala's adapter.

**Proposed revision: C# read by its own compiler's parser** (raised 2026-11-20, not decided; crux leaves it to whoever works on C#
when it is needed). `Scanner.CSharp` reads the text (taken from `csharp-via-fsi`); the branch's version lost every method after a
brace in an expression body until it was fixed on main, and more such misses are likely in a language this rich (attributes, raw
strings, `#if`, local functions, primary constructors). The .NET SDK carries C#'s own compiler (Roslyn,
`Microsoft.CodeAnalysis.CSharp.dll` under the SDK's directory), and a C# target needs the SDK anyway (P10), so C# could be read as F#
is: a script run once in `dotnet fsi`, `#r`-ing Roslyn from the SDK, parsing every file and writing one JSON line per file (`anykey`,
shape, marks, refusal as now, from the syntax tree). Not checked: whether fsi loads the SDK's Roslyn without a version conflict (fsi
itself uses some of the same assemblies), and how long a parse of a large solution takes. If taken: the text scanner stays for the map
without an SDK, or goes (D-scanners: one reader per language, preferred first); `test/scanner_csharp_test.exs`'s cases are the bar the
new reader must pass.

### 4.5 Scala — the window's own language

**Done 2026-11-20** as [D-scala-adapter](verification/lib-repl-language-scala.exs.md#d-scala-adapter): Scala 3 only; the REPL at the
project's own Scala version, its compiler and class path from sbt (temporary tasks `set` and `print`ed in one run) or scala-cli, one
module per build tool; nothing fetched; the build writing into the project as an IDE's; sbt not started while an sbt server runs on the
build; one entry as three REPL inputs, the arguments split by the node's shape
([D-anykey-shape](verification/lib-identity.exs.md#d-anykey-shape)); scripts as definitions-only copies. The checks on the real REPL
(`extending.md` §2.2), the decisions of 2026-11-20 and what was not chosen are in that record.

Left for later: mill (one more `Repl.Scala.BuildTool` module: `show <module>.runClasspath` prints JSON, checked); Scala 2; two projects
of one sbt build depending on different versions of a library (not checked).

For Java (§4.6): a Java project has no Scala version, so its REPL is the pinned `scala` on `PATH` (Scala 3.3.6 today) — the second of
the two routes. That route's ScriptEngine sees only the compiler's own class path, not the target's (checked): reading Java values back
needs the target on the JVM's class path there too.

### 4.6 Java — Scala as the window, through a seam

Decided 2026-11-20 (crux), on top of Scala's adapter, the second case of §2, 7:

- Declaration: language `java`, REPL `scala`, build tools maven (`pom.xml`), gradle (`build.gradle*`): the class path from the build,
  given to the REPL as Scala's
- The seam: `embody.java`, a small Java source compiled in the temp dir against the target's class path (never written into the
  project) and put on the REPL's class path. It works on the side that receives the result: values (records, `Optional`,
  `CompletableFuture` awaited, Java collections as Scala's; `Serializable` through Java serialization as `binary`), and failure reasons in
  Java's terms (not `static`, overloads, checked exceptions)
- Calls: static methods `com.foo.Bar.baz(1, 2)`; the arguments stay Scala expressions
- `anykey` the parameters' types, the argument count the shape, as C#'s ([D-anykey-shape](verification/lib-identity.exs.md#d-anykey-shape)). Not decided: type arguments, with C#'s
- Time: as Scala's. Scan: jdtls, or a text scanner; the map alone is worth having

Checked 2026-11-20 for the seam (maven 3.9.12, OpenJDK 21.0.10, Scala 3.3.6 from xipe_totec's pin; a Java target with overloads,
varargs, generics, a record holding a `List`, `Optional`, `CompletableFuture`, an enum, a checked exception, package-private, private
and instance methods):

| Item | What happened |
|---|---|
| Building | `mvn -o -q -B compile dependency:build-classpath -Dmdep.outputFile=…`: 1.4 s offline, once maven's own plugins are in `~/.m2` (28 MB, filled once online); `target/` written into the project, as sbt's is |
| The REPL | No Scala version comes from a Java project: the `scala` on `PATH`. `scala -classpath <cp>` gives the class path to the REPL only, so embody's read-back (the compiler's ScriptEngine, `-usejavacp`) does not see the target. `scala -e 'print(System.getProperty("scala.home"))'` (1.4 s) gives its home: `java -cp "<home>/lib/*:<cp>" dotty.tools.repl.Main -usejavacp` sees it, as Scala's sbt start does |
| Overloads of one count | Scala picks by the arguments' types: `over(1)` the `int` one, `over("a")` the `String` one, `over(1.0)` the `double` one; `wide(1)` widens. `over(null)` silently picks the `String` one (as F#) |
| varargs | `sum(1, 2, 3)`, `sum()`, and an array as `sum(Array(1, 2)*)` |
| Generic methods | `id(5)` infers; `twice("a")` gives a `java.util.List[String]`. **`<T> T make()`, whose type parameter is in no parameter, called without a type argument is `make[Nothing]()`: a `NullPointerException` ("Cannot throw exception because "null" is null")**, not a wrong value; `make[String]()` works |
| Futures | `later(1).get()` gives the value |
| Records | `sample.Point(1.0, 2.0)` (a Java constructor called without `new`) works, and the read-back of that text gives an equal record. Java's `equals` compares `double` components exactly (embody's floats compare within 1e-9) |
| Java collections | embody's writer covers Java enums (`sample.Color.RED`) and arrays, not `java.util` collections or `Optional`. Written as their constructors they read back equal: `java.util.ArrayList[Integer](java.util.List.of[Integer](0, 1))`, `java.util.Optional.of("yes")`, `java.util.Optional.empty()`, `java.util.HashMap[String, Integer](java.util.Map.ofEntries(java.util.Map.entry("a", 1), …))`. **A boxed element type must be written**: `java.util.ArrayList(java.util.List.of(0, 1))` is an `ArrayList[Int]` to Scala and does not fit a `List<Integer>` parameter; an empty `java.util.ArrayList()` fits by inference |
| Failures | an exception, checked or not, is its own text (`java.io.IOException: io: 1`; Scala does not check them). Package-private: "cannot be accessed … can only be accessed from package sample"; private and instance methods: "not a member of object sample.Calc"; a wrong count: the overloads with Scala's types. `embody.scala`'s diagnosis looks for a Scala `object` (`sample.Calc$`) and says "no object sample.Calc" for a Java class |
| Reading the source | the JDK's own parser (`com.sun.source` through `javax.tools`, `java Scan.java`, single-file launch, no build): 0.5 s for the fixture; each method's parameter types (the tree's text: `int[]`, `List<Integer>`, `T`), varargs, type parameters, modifiers (public, static, package-private, private), the return type |

**Decided** 2026-11-20 (crux, all as proposed):

1. **`embody.java` writes, `embody.scala` reads back.** Reading back is `embody.scala`'s own already (it evaluates the text), so the seam
   only writes and takes apart. `embody.scala` gets one language-neutral entry, as `embody.fsx`'s: a helper registered at the start
   (`Embody.registerType(classOf[…])`), asked only where its own writer, equality and diagnosis have no answer, given its own writer for
   the values inside. `embody.java` writes a public record as its canonical constructor's call (`sample.Point(1.0, 2.0)`), `java.util`
   lists, sets, maps and `Optional` as their constructors with the element type written when it is a boxed one, and gives a record's
   components for equality (doubles within 1e-9, a `List` inside element by element); the rest `binary` (`Serializable`) or
   `unsupported`, as embody judges now. Compiled with `javac` in the temp dir (only the JDK; no reference to the target) and put on the
   REPL's class path. (§4.6 above said "Java collections as Scala's": written as Java's own instead, so a later row's argument has
   the parameter's type)
2. **Overloads of one count**: marked `typed` by the scanner, as C#'s; each argument given its parameter's Scala type where Java's has
   one without doubt (`((null): String)`, `int` `Int`, `long` `Long`, `int[]` `Array[Int]`, `Integer` `java.lang.Integer`,
   `List<Integer>` `java.util.List[java.lang.Integer]`); a project's type or a type parameter left to Scala
3. **A type parameter in no parameter** (`<T> T make()`): refused by `row/add` with the reason, as C#'s (Scala calls it `make[Nothing]()`,
   a `NullPointerException` that says nothing of why)
4. **varargs** (`int... xs`): one argument in the shape, written as a Scala array (`Array(1, 2)`), the call passing it as `(…)*` (a mark
   `varargs`)
5. **Futures**: a method returning `CompletableFuture`, `CompletionStage` or `Future` marked `async`, the call inside the seam's
   `await(…)` (the value, under embody's time limit)
6. **Scanning by the JDK's own parser** (`scan.java` run once per scan with `java`, as F# by its SDK's and Scala by its compiler's):
   every method a node, `public` only for a `public static` method of a type public all the way out (nested `static` classes and
   interfaces' static methods too); `anykey` the parameter types from the tree; links from calls resolved through the package, imports
   and static imports. Not a text scanner (C#'s is one; its revision to Roslyn is proposed, §4.4); not jdtls (a server to install)
7. **maven first**: every module of a `pom.xml` build compiled offline, its classes and dependencies on the class path; `target/`
   written into the project. Gradle (a daemon; offline only through an init script) later, as mill for Scala
8. **The REPL**: the `scala` on `PATH` (the pinned 3.3.6), its home from `scala -e`, started `java -cp "<home>/lib/*:<seam>:<classes>:<cp>"
   dotty.tools.repl.Main -usejavacp` with the `java` on `PATH` (it must run the project's release); the protocol of `embody.scala` and
   `embody.java` checked first, as C#'s

The work, in order:

Done 2026-11-20, all five (D-java-adapter): `embody.scala` speaks protocol 2 (the helper entry), Scala's adapter with it; the seam's
class is `embodyjava.embody` (a public class must be named as its file, so `javac embody.java` compiles it as it is); maven's class path
per module into its own `target/` (`appendOutput` gave one entry for two modules).

1. **`embody.scala`'s helper entry** (rule 1), language-neutral, as `embody.fsx`'s: `Embody.registerType(classOf[…])` binding public
   static methods (`covers`, `write`, `parts`, `diagnose`); asked where the writer, `equal` and the diagnosis have no answer; embody's
   ReadMe; checked by the Scala live test with a helper written in Java
2. **`embody.java`**: `Protocol`, `await`, the writer (records, `java.util` collections, `Optional`), `parts`, the diagnosis in Java's
   terms; compiled with `javac` alone
3. **Java's scanner**: `lib/scanner/java/scan.java` (the JDK's parser) and `Scanner.Java`: nodes, `anykey`, the shape, marks (`async`,
   `typed`, `varargs`), the refusal (rule 3), links; unit tests on a fixture `test/fixtures/java_sample/`
4. **Java's declaration, maven and launch on Scala's**: `java` (`java`), REPL `scala`, build tool maven (`pom.xml`); the start script
   (embody checked, the seam compiled, `mvn -o` compile and class path, `scala -e` for the home, the REPL); the call template on Scala's
   with the marks; `info.json`
5. **Tests and the record**: `test/java_adapter_test.exs`, `test/live/repl_java_test.exs`, the CLI on a copy; D-java-adapter in
   `verification/`, `scope.md`, `how-to-use.md` §9, README, this §3; the live tests of the other languages before committing

### 4.7 PHP — the map (a driver left to the users)

**Decided** 2026-11-20 (crux): PHP stops at the map; evaluating it (the driver below) is left to the users (§8). The map is read by
**PHP's own lexer** (`token_get_all` with `TOKEN_PARSE`, so PHP's parser checks each file: `lib/scanner/php/scan.php` run once per scan
with `php`; nothing of the project is loaded or run), not phpactor (no call hierarchy) nor a text scanner. A class's methods (module the
class's full name, `App\Geo\Shapes`) and functions (module the namespace, `\` for the global one) are cards, `anykey` `nil`; closures,
arrow functions and anonymous classes' methods left out; `vendor/` left out; a function two files define (a guarded helper) is one card,
the first file's, each file told. Links as PHP resolves names, without case: `use`, `use function`, the namespace, the global fallback,
`self::`, `static::`, `parent::`, `$this->` ([D-map-only-language](verification/lib-repl-language.exs.md#d-map-only-language),
`Scanner.Php`).

What a driver would be (2026-11-16, kept for whoever adds evaluation):


- Declaration: language `php`, a driver `embody.php`, build tool composer (`composer.json`)
- Driver: reads stdin and `eval()`s; catches `ParseError` and `Throwable`; `register_shutdown_function` prints the marker on a fatal
  error. `php -a` is not used (unstable over a pipe)
- repr: `var_export()` → `eval` → `==` for `exact`; `serialize` for `binary`; closures `unsupported`
- Loading: composer's autoload (PSR-4) classes have no side effects; old procedural code (top-level work, chains of `include`) is
  hard to evaluate: the map only there
- Time: `set_time_limit` counts CPU only (`sleep` not counted); running out of time or memory is fatal and ends the driver;
  `interruptible: false`
- Scan: phpactor has no `callHierarchy` (`documentSymbol` works): links from references, or try intelephense

## 5. Checked on real REPLs (2026-11-16)

`extending.md` §2.2's items, checked by connecting each real REPL over a pipe (its own process group, as `Sender.Direct` does). Rustler
was taken through scan, `row/add` and `eval` with Xipe Totec itself; the others with a small Python driver sending one-line forms of the
templates above.

Versions: Python 3.13.12, Node 24.14.0, Go 1.27.4, PHP 8.5.12, OpenJDK 27 (jshell), Scala 3.9.0 (JDK 21), dotnet SDK 8.0.427 (fsi),
rustc 1.99.1 and evcxr 0.22.0, Rustler 0.36 with Elixir 1.18.4 / OTP 27. Language servers: pyright 1.1.414,
typescript-language-server 5.1.3, gopls 0.24.0, rust-analyzer 2026-11-09, csharp-ls 0.28.0 (needs .NET 10), jdtls 1.63.0, phpactor.

| Language | Start | Loading | Evaluation and repr | Failure | Time limit | SIGINT | Map (language server) |
|---|---|---|---|---|---|---|---|
| Rust through Rustler | `iex -S mix` as today; `mix compile` calls cargo (7 s) | unchanged | NIF results and `NifStruct` `exact`; `ResourceArc` is `#Reference<…>`, `unsupported` | a panic is a crash `{:nif_panicked, …}` (**its message is lost**) | a NIF that does not end: `session_hung`, the rest `aborted`, the REPL killed | unchanged (true) | the Elixir side's cards only |
| Python | `python -i -q -u`, probe 0.1 s; prompts mixed into the output | `ast` keeping definitions only: the top level does not run | literal → `exact`; cycles, `itertools.count`, instances via pickle → `binary`; functions `unsupported` | exceptions, multi-line messages, an unclosed call (compiled from a string): one-line crashes | SIGALRM stops `while True: pass`; **a loop in C code (`sum(itertools.count())`) is stopped by neither SIGALRM nor SIGINT** | true | pyright: both |
| JavaScript | `node -i`, 0.05 s; `> ` and `undefined` mixed in | **`import` runs the top level** (no standard JS parser to keep definitions only); **unexported functions cannot be called** | `util.inspect` → `vm` → `isDeepStrictEqual` `exact`; Map, cycles via `v8.serialize` `binary`; functions, generators, **class instances** (prototype lost) `unsupported` | `name: message` one-line crash; an unclosed call is `vm`'s SyntaxError | `vm`'s timeout works inside imported functions too; async via `Promise.race` (the work goes on behind) | true | typescript-language-server: yes |
| TypeScript | as JS | Node's type stripping refuses `enum`; `--experimental-transform-types` or tsx reads it | as JS | as JS | as JS | as JS | as JS |
| Go (driver) | `go run` per entry: 1.8 s first, 0.07–0.2 s warm | **`init()` runs every time** | `%#v`; **`&T{…}` reads back**; functions `(func…)(0x…)`; **structs with unexported fields cannot be rebuilt outside the package** | `recover` → one-line crash; an unclosed call is a compile error (no hang) | the driver killing its child: certain | as the driver is made | gopls: yes |
| Go (yaegi) | — | **cannot load modules** (GOPATH layout only) | `%#v` gives anonymous struct types and renames unexported fields | — | — | — | — |
| C# (fsi) | `dotnet fsi --quiet` 0.65 s; dll via `#r`, build 2 s | static constructors on first use | `Ns.Class.Method(a, b)` callable; `%A` shows a record's `List` by its type name only; **System.Text.Json drops tuples' contents** (`IncludeFields` needed); a record with a `List` is not `=` (reference) | try/with one-line crash; `;;`-terminated, an unclosed call does not hang | `Task.Wait` records the timeout, the thread runs on | **true: `- Interrupt`, bindings kept** (the estimate "false" was wrong) | csharp-ls: yes (.NET 10 SDK) |
| Java (Scala) | `scala repl` 2.6 s (compiler fetched at first use; a JDK mismatch is `UnsupportedClassVersionError`) | static initialisers on first use | calls, bindings, `toString`, Java List → Scala List work | try/catch one-line crash; **an unclosed call waits silently and joins the next line** | none | **false: the REPL ends** | jdtls: yes |
| Java (jshell) | 0.9 s | as Scala | records round-trip through Java serialization; plain classes' `equals` is identity | **an unclosed call waits silently** (no `...>`) | none | **false: jshell ends** | as above |
| PHP (driver) | the driver's `XT_READY` | autoloaded classes: no side effects; procedural files run their top level on include | `var_export` → `eval` `exact`; objects with private state via `serialize` `binary`; closures `unsupported` | Throwable, ParseError one-line crash; a private method is an Error | `set_time_limit` CPU only (**`sleep` not counted**); timeouts and memory are **fatal, the driver ends** (a shutdown function can still print) | **false** | **phpactor has no `callHierarchy`** |
| Rust alone (evcxr) | 2 s; 0.2–1.3 s an entry | — | bindings carry over; binding a `Result<_, Box<dyn Any>>` breaks evcxr's generated code (`use std::any::Any` needed) | evcxr catches panics, state kept; **an unclosed call waits silently** | — | stops, but **the evaluating child process ends and every binding is lost** | rust-analyzer: yes |

What follows from it:

- **Unclosed calls**: Python, JS, PHP, C# (`;;`), Go do not hang. Scala, jshell and evcxr wait silently: pass the call as a string and
  evaluate it inside (Scala's `scala.tools.repl`, jshell's `jdk.jshell` API — not checked), or check the syntax before sending
- **Languages whose evaluation cannot be stopped**: with Rustler, today's `session_hung` → `aborted` → kill already throws the session
  away without touching the generic layer. C# and Java follow the same road by staying silent; the record is `session_hung`, not
  `timeout`, and comes at the deadline (timeout plus margin)
- **interruptible**: Python, JS, C# (`fsi`) true; Scala, jshell, PHP false; evcxr stops but loses its bindings — treat as false
- **Go**: the driver is fast and its time limit certain; yaegi is not used
- **C#'s repr**: JSON round trips drop tuples and fields silently: check serialize → deserialize → serialize before calling a value
  `exact` or `binary`, with `IncludeFields = true`
- **PHP's map**: no `callHierarchy` in phpactor: build links from references, or try intelephense
- Risks kept from the estimates: a driver re-running entries must never re-run `writes`; the targets are functions callable with
  literals — code tangled with state, I/O or dependency injection falls to the map

## 6. Set aside

| What | Why | Revisit when |
|---|---|---|
| **Rust alone** (not through Rustler) | evcxr is slow (2 s, then 0.2–1.3 s an entry), an unclosed call waits silently, and SIGINT loses every binding; a driver like Go's pays Rust's compile time on every entry. Only a lib crate's `pub` functions can be called; `Debug` output does not read back, so `exact` needs serde or `PartialEq` within one pass; `catch_unwind` does nothing under `panic = "abort"` | a project needs Rust's own functions evaluated, not through Rustler. The map (rust-analyzer) can come first, as for Java |
| **Evaluating TypeScript's (and JavaScript's) logic** | Loading a module without its top level needs a parser; Node has none for JS, and TypeScript's compiler API would have to be taken from the target — a special case on Xipe Totec's side, for the language of the surface. Unexported functions would also need a rewritten copy to be callable. Not worth the distortion (crux, 2026-11-17) | logic worth evaluating is found living in JS/TS in a target. What it would meet is §5's JavaScript and TypeScript rows |
| Compiling a whole pass as one program | The Evaluator writes one entry and waits for its marker (D-text-repl); compiling a pass would change the generic layer. Not taken while drivers suffice | a language where neither a REPL nor a driver works |

## 7. Working on a language (for people and AI)

One language at a time; checks recorded before code.

1. Read: this document, `extending.md`, `repl-adapter-guide.md`, embody's `ReadMe.full.md`, the existing adapters (`lib/repl/language/`,
   `lib/repl/ocaml/`, `lib/repl/haskell/`, `lib/repl/python/`, `lib/repl/fsharp/`, `lib/repl/scala/`)
2. Before implementing, check `extending.md` §2.2 on the real REPL and keep the result as a table in the language's record in
   `verification/`. Where this document's estimates disagree, trust the real REPL
3. Do not touch the generic layer (`sender*.exs`, `session.exs`, `evaluator.exs`, `eval/*.exs`). If it seems needed, stop and ask crux
   (§6, the last row)
4. A live test `test/live/repl_<repl>_test.exs` in Elixir's pattern: start → ready → evaluate (success, an `:in_plan` reference,
   `unsupported`, an exception, a timeout, an unclosed call) → compare (`same`, `changed`) → quit. A small sample project with no
   outside dependencies under `test/fixtures/`
5. A new embody goes into the embody repository, with its language table and section (loading, the evaluation contract, versions
   checked, limits)
6. New decisions get a `D-…` name and a record; `scope.md`'s language row is updated, and this document's §3
7. A new declaration takes effect after `xipe refresh -l`; registering is part of the work
8. Try it on a project not written for it, on a copy of Xipe Totec with its own `tables/` (a running `xipe start` makes the CLI use
   its project, whatever `xipe choice project` chose)

## 8. Left to the users

Xipe Totec's languages are complete for now (crux, 2026-11-20): Elixir, OCaml, Haskell, Python, F#, C#, Scala and Java mapped and
evaluated; JavaScript, TypeScript, Go and PHP mapped. What is left is open work for whoever needs it, each with what was found:

| What | Where it stands | Start from |
|---|---|---|
| Evaluating Go | a driver `embody.go` (a temporary `main` per entry, `go run`); re-running earlier entries, unexported functions, `(value, error)` | §4.3, §5 |
| Evaluating PHP | a driver `embody.php` (`eval()` over stdin, `register_shutdown_function` for fatal errors) | §4.7, §5 |
| Rust alone | evcxr too slow and fragile over a pipe; a driver pays Rust's compile time per entry | §6, §5 |
| Rust through Rustler, `ResourceArc` | evaluates today as Elixir; an opt-in convention for a resource's contents is designed, not made | §4.2 |
| Evaluating TypeScript's and JavaScript's logic | set aside: loading without the top level needs a parser Node lacks | §6 |
| Java with gradle | maven only; gradle needs its daemon and an init script to stay offline | §4.6 |
| C# read by Roslyn's parser | a proposed revision of the text scanner | §4.4 |
| Type arguments of a generic method whose type parameter is in no parameter | refused by `row/add` in C# and Java | D-anykey-shape |

Each follows §7 above: checks on the real tool recorded before code, the generic layer left alone, embody's principles kept.
