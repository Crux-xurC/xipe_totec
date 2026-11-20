# `lib/repl/language/scala.exs`

Scala 3's declaration: extensions `scala`, `sc`, REPL `scala` (Scala 3's REPL, `dotty.tools.repl.Main`) with `embody.scala`, build
tools `sbt` (`build.sbt`) and `scala-cli` (`project.scala`), scanner `Scanner.Scala`; `launch_opts/3` checks for an sbt server on the
build, writes the start script (the build tool's part, then the REPL) into a temp dir, and names the scripts whose copies to load. The
adapter is `lib/repl/scala/launch.exs`, `lib/repl/scala/build_tool.exs` (one module per build tool), `lib/repl/scala/eval_template.exs`
and the iex scan / field_drip it delegates to (`lib/repl/eval/scan/direct/scala.exs`, `lib/repl/eval/field_drip/scala.exs`); the scanner
`lib/scanner/scala.exs` with `lib/scanner/scala/scan.scala`.

**Decisions homed here**: [D-scala-adapter](#d-scala-adapter)
**Takes part in**: D-anykey-shape ([`lib/identity.exs`](lib-identity.exs.md)), D-embody ([`lib/repl/embody.exs`](lib-repl-embody.exs.md)),
D-language-adapter ([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md)),
D-restart-after-timeout ([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md))

<a id="d-scala-adapter"></a>

## D-scala-adapter — Scala 3 in its own REPL with `embody.scala`; the build tool's class path; read by Scala's own parser

**Decided** (2026-11-20, crux: Scala before C# and Java, the window's own language first — `evolving.md` §2, 7; checked with Scala
3.3.6, sbt 1.12.4, scala-cli 1.12.5, JDK 21 and 27):

- **Scala 3 only.** Scala 2's REPL is another program (not checked). In an sbt build, a project of another Scala version is left out
  of the REPL (its files on the map only; the build's log names it)
- **The REPL is the project's own Scala version** (a compiler cannot read newer TASTy): the build tool gives the compiler's jars and
  the run-time class path, and the REPL is `java -cp <compiler, library, target> dotty.tools.repl.Main -usejavacp` (the target on the
  JVM's class path too, so embody's ScriptEngine sees its types). Without a build tool (scripts alone), or when the build did not run,
  it is `scala` on `PATH` — the pinned one, which is also the route when Scala's REPL becomes Java's window (`evolving.md` §4.6): a Java
  project has no Scala version
- **The class path from the build tool, one module per tool** (`Repl.Scala.BuildTool`, writing `java`, `jars` and `cp` into the temp
  dir), so mill (and maven and gradle for Java) are one more module:
  - **sbt** (1.4 or later; before it, no `print`: outside the scope): one `sbt -batch -error` run defines temporary tasks with `set` and
    `print`s them — output for machines, nothing written to the build's files. Every project's Scala version first (settings: printed
    even when a build fails), then the JVM sbt ran on, the compiler jars of the newest Scala 3 project, and the class path of all the
    Scala 3 projects together (`ScopeFilter(inProjects(…))`, chosen in the run with `Def.taskDyn`). `-error` hides sbt's own parse
    errors: a run that fails printing nothing is run once more without it, into the log. Reading `show scalaInstance`'s text is the
    fallback only if this stops working, kept in one place with tests of its own (not needed so far)
  - **scala-cli**: `compile --print-class-path` (`--server=false`); the Scala version from the `scala3-library_3` jar in it; the
    compiler's jars the same way, from a one-line project in the temp dir depending on `scala3-compiler` of that version
- **Nothing is fetched**: sbt under `COURSIER_MODE=offline`, scala-cli with `--offline`. A dependency, a Scala version or sbt itself
  not in the cache fails at once naming the module, and the rows `crash` with it (as F#'s `NU1101`): "build once yourself"
- **The build writes into the project** as an IDE's build does — sbt's `target/` (with `project/target/` and `target/streams/`),
  scala-cli's `.scala-build/` and `.bsp/` — accepted as F#'s `obj/`: a build on a copy loses incremental compilation, and every pass
  would compile the whole project again
- **An sbt server running on the build stops it**: sbt takes no lock against a second instance, and a compile beside the user's sbt
  shell made the shell's compile fail (checked). When the REPL is started, `project/target/active.json` is read; if the socket it names
  answers (a file left by a killed server names one that does not), sbt is not started and the rows `crash` naming the server ("close
  the sbt shell, or Metals' sbt connection, and evaluate again")
- **One entry is three REPL inputs**, each a complete line: `Embody.start("<id>", <ms>, <basis>)` / `val xt_<id> = Embody.call(() =>
  pkg.Obj.f((a), (b))((c)))` / `Embody.finish("<id>", "pkg.Obj", "f", List(2, 1))`. The REPL compiles the call; one that does not
  compile leaves `xt_<id>` unbound and the compiler's message on the output, and `finish` reports a `crash` with what reflection tells,
  in Scala's terms: no such object (with the build's first error, an sbt server, projects left out, scripts that did not load), no such
  function, `private`, how many arguments it takes, its signature. The REPL waits silently for the rest of an unclosed bracket, string
  or comment (checked: with the arguments in parentheses only these lexical causes wait), so `EvalTemplate.check/1` refuses such an
  argument — brackets, `"…"`, `"""…"""`, an interpolation's `${…}`, a char, a backquoted name, `//`, `/*` — and `Embody.fail` reports it
- **Calls, `anykey` and the shape** ([D-anykey-shape](lib-identity.exs.md#d-anykey-shape)): the arguments are split into the node's
  parameter lists by its shape, each in parentheses (`[2, 1]`: `f((a), (b))((c))`; `[0]`: `f()`; `[]`: `f`, a `def` without lists); a
  name that is not an identifier, or a keyword, in backticks. `anykey` is the parameters' types as written, lists kept apart
  (`(Int)(Int)`, `(Int)(using Ordering[Int])`), so overloads are nodes of their own and an address picks one (`anykey=(String)`). The
  types are written out again from the parser's tree in one form (crux, 2026-11-20): `List[ Int ]` and `List[Int]`, `Map[String,Int]`
  and `Map[String, Int]` are one key, so spacing does not move an id; what only type resolution could tell (`Int` against `scala.Int`)
  stays as written (`scope.md`). A `using` list is in `anykey` and out of the shape: the caller does not write it
- **repr**: `exact` when `embody.scala`'s literal writer covers the value and the compiler's ScriptEngine (in the compiler's jar,
  nothing more) reads the text back to an equal value: the primitives with their forms (`1L`, `(1: Short)`, `1.5f`, `'c'`,
  `Double.NaN`), strings, `BigInt` / `BigDecimal`, `Option`, `Either`, tuples, `List`, `Vector`, `Set`, `Map`, arrays, mutable
  `ArrayBuffer` / `ListBuffer` / `HashMap` / `HashSet`, case classes (`sample.Point(2.0, 3.0)`, qualified), Scala 3 and Java enums
  (`sample.Color.Red`), objects. Otherwise `binary` through Java serialization when it reads back equal (base64 of the bytes); otherwise
  `unsupported` (functions, `LazyList`, a class without equality). `type=` is the running value's (`List[Int]`, `(Int, String)`,
  `sample.Point`): erasure leaves the static type unknown
- **Time**: `call` runs the call and the value's display on a thread of its own and waits for the limit; the JVM cannot stop a running
  thread (`Thread.stop` is gone), so at the limit the thread is interrupted (a sleep or a wait ends) and left, and the entry is a
  `timeout`; the launch declares `restart_after_timeout` ([D-restart-after-timeout](lib-repl-evaluator.exs.md#d-restart-after-timeout))
  and `interruptible: false` (SIGINT ends Scala's REPL). The definition's echo after `val xt_<id> = …` runs `toString` again outside
  the limit, but only on a value whose display already finished within it (else the binding is `null`)
- **Scripts (`.sc`)**: as F#'s `.fsx` — loaded as copies holding only their definitions (`Embody.Load.write`, Scala's parser in the
  REPL), each inside an object named by its path without `.sc` (`` object `scripts/tool` ``; a script at the root, `tool`), ending in
  `Embody.markLoaded`. The script's module in the Book is that path (`scripts/tool`, nested `scripts/tool.Text`): two scripts of one
  file name in different directories are two modules, in the Book and in the REPL (crux, 2026-11-20). Kept: `def`s, `val`s that run
  nothing (a literal, a name or chain of names, a tuple or standard collection of those, a lambda), classes, traits, objects, enums,
  types, givens, extensions, imports. `println(…)`, `val n = f()` do not run; a script whose functions use such a value does not
  compile, and its rows `crash` naming it. `//> using dep` is left out as F#'s `#r "nuget: …"`: nothing is fetched
- **The start**: the start script checks that `embody.scala` exists and speaks the adapter's protocol (`val protocol = 2` since 2026-11-20, when the helper entry `registerType` came for Java's seam; else it
  ends at once naming where it looked, or that embody must be updated — Xipe Totec and embody are updated together), runs the build
  tool's part once per pass, and starts the REPL. Over stdin: `:load` of `embody.scala`, `Embody.setup(<log>)`, the scripts'
  copies, then `Embody.ready()` — embody prints the ready marker, so a REPL without embody never looks ready
- **Scanning**: `Scanner.Scala.begin/3` runs `lib/scanner/scala/scan.scala` once over every Scala file, **with the project's own
  compiler** (crux, 2026-11-20; P10): the build tool's `compiler_script/3` gives it without building (sbt's temporary tasks without the
  class path; scala-cli's `export --json` for the version, then its compiler), offline; the jars are kept per project and the times of
  its build files, and `scan.scala` is compiled once per compiler, under the temp dir. When the build tool cannot give it — no build
  tool, an sbt server running on the build, a tool that fails — the `scala` on the project environment's `PATH` (the pinned one) reads
  it, and the scan's description says why. A node is a `def` in an `object` (nested too) or directly in a package;
  `module` the object's full name, the package for a top-level `def` (`""` in the empty package), a script's file name for its own
  `def`s; `private` for `private` / `protected` / `private[…]`, or inside such an object; the `shape` the counts of the lists without
  `using`. Methods of classes and traits, extension methods (`extension (x: Int) def double`: called as `x.double`), `val`s and local
  functions are not nodes. **One key defined in two places** (an object of one name in two sbt projects, an overload written twice) is
  not merged silently: each file's scan reports it in `link_failures`, naming both places (P9); the card is the first one's. Links: every name or chain of names a body uses
  that is a node, looked up through the enclosing objects and packages innermost first, then the `import`s, then as written; every
  overload of the name is linked

**Why**: a REPL is first made to serve its own language (`evolving.md` §2, 7); Scala's REPL then becomes Java's window with a seam.
The build tool is the only one that knows the class path and the compiler of the project's version; asking it for machine output in
one run (temporary tasks) is cheaper and steadier than parsing its text. Taking the compiler's ScriptEngine and parser from the REPL's
own class path keeps embody within the standard environment (embody's principle 2) and makes `exact` mean what it means elsewhere ("the
text evaluates back to the value"). Refusing to run beside an sbt server protects the user's own build, a stronger care than F#'s
`obj/` because sbt takes no lock at all.

**Alternatives**: `sbt console` as the REPL (control codes in its prompt over a pipe, and sbt again on every new session; checked);
the pinned `scala` for every project (cannot read newer TASTy); building on a copy in the temp dir (loses incremental compilation);
`-Xrepl-disable-display` to silence the echo (hides `println`, `System.out` and `System.err` too; checked); evaluating the call as a
string in ScriptEngine (does not see the REPL's bindings `xt_<id>`; checked); Metals for the scan (needs a running build server; not
checked); `show scalaInstance`'s text (the fallback, not needed); checking the arguments' syntax with the compiler's parser before
sending (a lexical check suffices: only lexical causes wait); a script's object named as scala-cli does, by its file name alone (two
scripts of one name would be one key in the Book and one object in the REPL, the second shadowing the first); `anykey` as the source
writes it (spacing would move ids); the pinned parser for every scan (a newer syntax would not parse; P10).

**Files**: `lib/repl/language/scala.exs`, `lib/repl/scala/launch.exs`, `lib/repl/scala/build_tool.exs`,
`lib/repl/scala/eval_template.exs`, `lib/repl/eval/scan/direct/scala.exs`, `lib/repl/eval/field_drip/scala.exs`, `lib/scanner/scala.exs`,
`lib/scanner/scala/scan.scala`, embody's `embody.scala`; tests `test/scala_adapter_test.exs`, `test/live/repl_scala_test.exs`; fixtures
`test/fixtures/scala_sample/` (sbt, scripts), `test/fixtures/scala_cli_sample/`.

## The REPL as checked (`extending.md` §2.2), 2026-11-20, Scala 3.3.6 (xipe_totec's nixpkgs pin, JDK 21)

| Item | Scala 3's REPL |
|---|---|
| Start | Over a pipe: JLine warns that it makes a dumb terminal, then the banner and `scala> `. 1.5 s (warm). A definition's echo (`val x: T = v`) comes in ANSI colours, **after** the line has run; `-color:never` does not remove them; `-Xrepl-disable-display` hides `println`, `System.out` and `System.err` too. On JDK 27 it runs with warnings about `sun.misc.Unsafe` |
| The class path and the version | A compiler cannot read newer TASTy: the REPL must be the project's version. sbt: 4.0–4.5 s warm for the tasks above, 51 s the first time (231 MB fetched); scala-cli: 1.9 s, its compiler 1.2 s; mill (later): `show <module>.runClasspath` (JSON), 1.3 s warm |
| Writing into the target | sbt `project/target/` and `target/streams/` even with `target` elsewhere; scala-cli `.scala-build/`, `.bsp/`; mill `out/` |
| An sbt already running | No lock: `sbt -batch` beside a shell starts its own JVM; compiling at once made **the shell's** compile fail (`error writing …/target/…`). A killed shell leaves `active.json`. Metals with Bloop not checked |
| Fetching nothing | sbt `COURSIER_MODE=offline` and scala-cli `--offline`: the cache does not grow; a missing dependency 3.7 s / 0.08 s, a missing Scala version, a never-run sbt (3.9 s) fail naming the module |
| Multi-project sbt | `set` tasks live in the current project (the root); `ScopeFilter(inProjects(…))` gathers the others; a 2.12 project gathered fails offline (its compiler bridge); one that fails to resolve fails the whole step unless left out |
| Loading | Nothing runs when the class path is loaded, nor `@main`. **An `object`'s body runs at its first use.** `:load` of a `.sc` runs its top level |
| Parsing | The compiler's parser works inside the REPL and in `scala <file>` (0.3 s, the scan 2.5 s with the JVM): `def`s with their lists, `private`, spans, nested objects, statements of objects and scripts (`blockStatSeq`). A number is an `untpd.Number`, not a `Literal` |
| Evaluation and display | Calls, curried calls, top-level `def`s, case classes; `val xt_a = …` is seen by later lines. `toString` is not a literal (`Point(2,3)` without its package, `(1,1)` without quotes, `[I@…`). ScriptEngine reads a literal back in 0.04–0.7 s with the target on the JVM's class path; it does not see the REPL's bindings. In Scala, collections are functions (`PartialFunction`) |
| Failure | A type error, `private`, an unknown name: the compiler's diagnostic; an exception: `java.lang.X: message` and stack lines; the REPL reads on. **An unclosed call waits silently and joins the next line**; with the arguments in parentheses only an unclosed bracket, `"""`, a `//` or a `/*` (nested) comment wait |
| Time limit | `Thread.stop` is `UnsupportedOperationException` (JDK 21); `interrupt` ends a sleep or a wait only |
| SIGINT | The REPL ends: `interruptible: false` |

## Notes

- Verified: `test/scala_adapter_test.exs` (18 tests), `test/live/repl_scala_test.exs` (10 tests, with sbt 1.12.4, scala-cli 1.12.5 and
  Scala 3.3.6 from xipe_totec's nixpkgs pin, caches filled once: the scan, values of every kind, curried and parameterless calls,
  overloads, scripts' functions with their top level not run, compare, the failures, an unclosed argument, a script that does not
  compile, a timeout and the new session, a failing build, an sbt server on the build, a scala-cli project, scripts of one name in two
directories, the scan with the project's compiler and without a build tool), and the CLI end to end on
  a copy with its own `tables/` (`refresh -l -r`, `choice project`, `scan`, `node/resolve` of an overload by `anykey`, `effect/set`,
  `row/add` refusing a private function and a wrong count per parameter list, `eval` twice: `same`; without embody the start ends at
  once naming where it looked), 2026-11-20
- The build is done once per pass; a new session after a `timeout` only starts the REPL again (1.5 s)
- Two projects of an sbt build depending on different versions of one library both land on the joined class path; the first wins (not
  checked)
- Java comes on top of this adapter, with a seam (`embody.java`) for values and failure reasons in Java's terms, through the pinned
  `scala` ([`evolving.md`](../evolving.md) §4.6)
