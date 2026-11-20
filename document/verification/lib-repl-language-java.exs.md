# `lib/repl/language/java.exs`

Java's declaration: extension `java`, REPL `scala` (Scala 3's REPL, Scala's window) with `embody.scala` and Java's seam `embody.java`,
build tool maven (`pom.xml`), scanner `Scanner.Java`; `launch_opts/3` writes the start script into a temp dir. The adapter is
`lib/repl/java/launch.exs` and `lib/repl/java/eval_template.exs`, both on Scala's (`lib/repl/scala/`), with Scala's scan
(`lib/repl/eval/scan/direct/scala.exs`) and `lib/repl/eval/field_drip/java.exs`; the scanner `lib/scanner/java.exs` with
`lib/scanner/java/scan.java`.

**Decisions homed here**: [D-java-adapter](#d-java-adapter)
**Takes part in**: D-scala-adapter ([`lib/repl/language/scala.exs`](lib-repl-language-scala.exs.md)), D-anykey-shape and D-node-marks
([`lib/identity.exs`](lib-identity.exs.md)), D-embody ([`lib/repl/embody.exs`](lib-repl-embody.exs.md)), D-language-adapter
([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md)),
D-restart-after-timeout ([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md))

<a id="d-java-adapter"></a>

## D-java-adapter — Java in Scala's REPL, through a seam `embody.java`; read by the JDK's own parser

**Decided** (2026-11-20, crux: the second case of the window's own language first, then the other language through a seam,
[`evolving.md`](../evolving.md) §2, 7 and §4.6, where the checks on the real REPL and the eight rules are; checked with maven 3.9.12,
OpenJDK 21.0.10 and Scala 3.3.6):

- **The window is Scala's.** Java has no REPL that evaluates one call over a pipe and goes on, so a Java call is compiled by Scala 3's
  REPL with `embody.scala`, as a Scala call of Java's static method: `pkg.Type.method((a), (b))`, the arguments Scala expressions
  (`Array(1, 2)`, `"text"`, `sample.Point(1.0, 2.0)` — a Java constructor called without `new`). The three inputs, the time limit, not
  interruptible, `restart_after_timeout` and `check/1` are Scala's (`Repl.Scala.EvalTemplate.build/2` with Java's call;
  `Repl.Scala.Launch.build/1` with the seam registered after `Embody.setup`)
- **The seam, `embody.java`** (embody's repository; the class `embodyjava.embody`, named as its file so `javac embody.java` compiles it as
  it is), brings Java's meaning to Scala on the side that receives the result: `await` gives a `CompletableFuture`'s, `CompletionStage`'s
  or `Future`'s value; public records are written as their canonical constructor's call (`sample.Point(2.0, 3.0)`), `java.util` lists,
  sets, maps and `Optional` as their constructors with a boxed element type written (`java.util.ArrayList[java.lang.Integer](java.util.List.of[java.lang.Integer](0, 1))`:
  Scala would type `List.of(0, 1)` as a list of `Int`, which does not fit a `List<Integer>` parameter); `embody.scala` reads the text back
  itself (it evaluates it) and compares part by part (a record's components, a list's elements; floats within 1e-9); a call that did not
  compile is told in Java's terms (package-private, private, an instance method, a field, the public static overloads' counts and
  signatures). It is registered through `embody.scala`'s language-neutral helper entry (`Embody.registerType`, protocol 2) and works by
  reflection: no reference to the target
- **Starting**: one `sh <start script>` under `eval.boot_timeout`. The script first checks `embody.scala` (Scala's adapter's protocol)
  and `embody.java` (`public static final int PROTOCOL = 1;`); otherwise the start ends at once naming the file and what to do. Then,
  once per pass: the seam compiled alone with `javac` into the temp dir; with a `pom.xml`, `mvn -o -q -B compile
  dependency:build-classpath -Dmdep.outputFile=target/xipe_totec.cp` (every module writes its class path into its own `target/`,
  collected and removed; the classes are every module's `target/classes`; a failed build is written to the log as `XT_BUILD_ERROR` with
  maven's first error naming a file, and the rows crash naming it); the `scala` on `PATH` asked for its home (`scala -e`). The REPL is
  `java -cp "<home>/lib/*:<seam>:<classes>:<cp>" dotty.tools.repl.Main -usejavacp`: the target on the JVM's class path, so the read-back
  sees its types. Nothing is fetched (`-o`); maven writes `target/` into the project, as an IDE's build does. A gradle build is named,
  not read
- **Scanning**: `Scanner.Java.begin/3` runs `lib/scanner/java/scan.java` once with `java` as a single-file program (the JDK's own
  parser, `com.sun.source` through `javax.tools`: nothing compiled or written). Every method of a class, interface, enum or record is a
  node; `public` only for a `public static` method of a type public all the way out (an interface's members and nested types are
  public). `anykey` is the parameters' types written out from the tree in one form (`(int, int)`, `(List<Integer>)`, `(int...)`); the
  shape the parameter count, a varargs parameter one ([D-anykey-shape](lib-identity.exs.md#d-anykey-shape)). Marks
  ([D-node-marks](lib-identity.exs.md#d-node-marks)): `async` (the call inside `embodyjava.embody.await(…)`), `varargs` (the last
  argument, an array, passed as `(…)*`), `typed` for an overload whose count another one shares (each argument given its parameter's
  Scala type where Java's has one without doubt: `((null): String)`, `long` `Long`, `int[]` `Array[Int]`, `List<Integer>`
  `java.util.List[java.lang.Integer]`; a project's type or a type parameter left to Scala). A refusal for a method whose type parameter
  appears in no parameter (`<T> T make()`: Scala calls it as `make[Nothing]()`, a `NullPointerException` that says nothing of why)
- **Links**: a call whose name is a chain of names (`f(…)`, `Calc.f(…)`, `sample.Calc.f(…)`, `this.f(…)`), found as Java looks it up —
  a bare name in the enclosing types, then the static imports; a qualified one nested in an enclosing type, in the same package, through
  a single-type or an on-demand import, then as written. The overloads of the call's argument count (all of them when several share
  it), else every overload of the name. Calls on a value are not links

**Why**: Java is not Scala's language, so whatever is Java's — awaiting, records and `java.util` values written as Scala, the reasons
in Java's terms — lives in one Java file, and `embody.scala` stays Scala's alone with one neutral entry; reading back is already
`embody.scala`'s own (it evaluates the text), so the seam only writes and takes apart. The JDK comes with every Java project (P10) and
carries Java's own parser, as the SDK carries F#'s and the compiler Scala's: no text scanner, no language server to install.

**Alternatives**: jshell as the window (its state and output are not a pipe's, and the C# / F# pattern is a window with its own
language); `scala -classpath <cp>` (the class path reaches the REPL only, not the JVM, so the read-back does not see the target);
Java's collections written as Scala's (a later row's argument would not have the parameter's type); `appendOutput` of the dependency
plugin for one class path file (checked: two modules gave one entry); a text scanner (C#'s is one; its revision is proposed, §4.4);
jdtls through `Scanner.Lsp`; gradle now (a daemon; offline only through an init script: later, as mill for Scala).

**Files**: `lib/repl/language/java.exs`, `lib/repl/java/launch.exs`, `lib/repl/java/eval_template.exs`,
`lib/repl/eval/field_drip/java.exs`, `lib/scanner/java.exs`, `lib/scanner/java/scan.java`, embody's `embody.java` and `embody.scala`;
tests `test/java_adapter_test.exs`, `test/scanner_java_test.exs`, `test/live/repl_java_test.exs`; fixture `test/fixtures/java_sample/`.

## Notes

- Verified 2026-11-20: `test/java_adapter_test.exs` (10 tests), `test/scanner_java_test.exs` (4), `test/live/repl_java_test.exs` (7,
  through the launch, against the JDK, maven and Scala 3 from xipe_totec's nixpkgs pin: the scan and links, values of every kind,
  overloads by count and by type, varargs, a future awaited, references within the pass, records and a record holding a `List` as later
  rows' arguments with `same` and `changed`, a `Serializable` class `binary`, a lambda `unsupported`, the failures in Java's terms with a
  package-private method first, a failing build named, a timeout and the new session, an `embody.java` of another protocol); and the CLI
  on a copy with its own `tables/` (`refresh -l -r`, `choice project`, `scan` — 36 nodes —, `effect/set`, `row/add` refusing `make()`
  with its reason and a private method, `eval`: `over(null)` the `String` overload, `later(41)` `42`, `sum(Array(5))`, an interface's
  static method; only maven's `target/` written into the target)
- Maven's own plugins (compiler, resources, dependency) must be in its local repository once: a project built online once has them
- The REPL runs on the `java` on `PATH`; it must be able to run the project's release (an older JVM cannot load newer classes)
- A Java `double` in a record is compared within 1e-9 by `embody.scala` (Java's own `equals` compares it exactly)
- The seam, maven's build and Scala's home are found at every pass (the temp dir is the pass's): about 1.4 s for maven offline on the
  fixture and 1.4 s for `scala -e`
