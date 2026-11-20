# `lib/repl/language/csharp.exs`

C#'s declaration: extension `cs`, REPL `fsi` (F# Interactive, F#'s window) with `embody.fsx` and C#'s seam `embody.cs`, build tool
`dotnet` (`*.csproj`, `*.sln`, `*.slnx`), scanner `Scanner.CSharp`; `launch_opts/3` writes the start script, the init file and the
seam's project into a temp dir. The adapter is `lib/repl/csharp/launch.exs` and `lib/repl/csharp/eval_template.exs`, both on F#'s
(`lib/repl/fsharp/`), with fsi's scan (`lib/repl/eval/scan/direct/fsi.exs`) and `lib/repl/eval/field_drip/csharp.exs`; the scanner
`lib/scanner/csharp.exs`.

**Decisions homed here**: [D-csharp-adapter](#d-csharp-adapter)
**Takes part in**: D-fsharp-adapter ([`lib/repl/language/fsharp.exs`](lib-repl-language-fsharp.exs.md)), D-anykey-shape and
D-node-marks ([`lib/identity.exs`](lib-identity.exs.md)), D-embody ([`lib/repl/embody.exs`](lib-repl-embody.exs.md)),
D-language-adapter ([`lib/repl/language.exs`](lib-repl-language.exs.md)), D-scanners ([`lib/scanner/lsp.exs`](lib-scanner-lsp.exs.md)),
D-restart-after-timeout ([`lib/repl/evaluator.exs`](lib-repl-evaluator.exs.md))

<a id="d-csharp-adapter"></a>

## D-csharp-adapter — C# in F# Interactive, through a seam `embody.cs`

**Decided** (2026-11-20, crux: the window's own language first, then the other language through a seam, [`evolving.md`](../evolving.md)
§2, 7 and §4.4, where the checks on the real REPL and the six rules are; checked with the .NET 8 SDK 8.0.419):

- **The window is F#'s.** C# text cannot be evaluated in the SDK (Roslyn's scripting is not in it), so a C# call is compiled by F#
  Interactive with `embody.fsx`, as an F# call of C#'s static method: `Ns.Type.Method((a), (b))`, the arguments F# expressions
  (`[|1; 2|]`, `"text"`, `Sample.Geo.Point(1.0, 2.0)`). The three submissions, the time limit, `restart_after_timeout`, `check/1` and the
  launch message are F#'s (`Repl.FSharp.EvalTemplate.build/2` with C#'s call; `Repl.FSharp.Launch.build/1`)
- **The seam, `embody.cs`** (embody's repository), brings C#'s meaning to F# on the side that receives the result: `Seam.Await` gives a
  `Task`'s / `ValueTask`'s value; a public positional record whose properties are its primary constructor's parameters is written as
  that constructor's call (`Sample.Geo.Point(2.0, 3.0)`), read back and compared property by property (a `List` inside element by
  element) through `embody.fsx`'s language-neutral helper entry; a call that did not compile is told in C#'s terms (an instance method,
  `internal`, a property, the public static overloads' counts and C# signatures). It works by reflection and references no target
- **Starting**: one `sh <start script>` under `eval.boot_timeout`. The script first checks `embody.fsx` and `embody.cs`, and that
  `embody.cs` speaks this adapter's protocol (`public const int Protocol = 1;`, `EmbodyCs.Seam.Protocol`); otherwise the start ends at
  once naming the file and what to do (clone or `git pull` embody), as Scala's does. Then, once per pass: the seam is built as a class
  library of its own (`<temp>/seam/EmbodyCs.csproj` compiling `embody.cs`) into `<temp>/seam_out`, every `*.csproj` of the target
  (outside `bin/`, `obj/`, hidden directories) into `<temp>/out`, both from an empty package source, `--disable-build-servers`; the init
  file gets `#r` and `Embody.reference` for every dll the builds produced (a call failing before any other has run still finds the
  types) and `Embody.registerType typeof<EmbodyCs.Seam>`. Nothing is fetched; `obj/` is written into the target, nothing else
- **Scanning**: `Scanner.CSharp` reads the text (comments, strings, chars, `#if` branches blanked; namespaces, types and methods by their
  braces). Every method is a node; `public` only for a `public static` method of a type public all the way out and not generic.
  `anykey` is the parameters' types written out from the tokens in one form (`(int, int)`, `(string, out int)`, `(params int[])`), so
  overloads are nodes of their own; the shape is the arguments a caller writes (`out` left out, optional ones counted, `params` one)
  ([D-anykey-shape](lib-identity.exs.md#d-anykey-shape)). Marks ([D-node-marks](lib-identity.exs.md#d-node-marks)): `async` for a
  method returning `Task` / `ValueTask` (the call inside `EmbodyCs.Seam.Await(…)`, so a later row gets the `T`), `typed` for an overload
  whose count another one shares (each argument given its parameter's F# type where C#'s has one without doubt: `((null) : string)`,
  `double` `float`, `List<int>` `System.Collections.Generic.List<int>`; a project's type or a type parameter left to fsi). A refusal for a
  method whose type parameter appears in no parameter (`Make<T>()`: F# would call it as `Make<obj>()`, a wrong value without an error)
- **Links**: a call `Name(…)`, `Type.Name(…)`, `Ns.Type.Name(…)`, `this.Name(…)` to a project method, the type found as C# looks it up
  (enclosing types and namespaces, `using`, `using static`); the overloads of the call's argument count (all of them when several share
  it), else every overload of the name. Calls on a value (`list.Add(…)`) are not links: the scan does not know a variable's type

**Why**: C# is not fsi's language, so whatever is C#'s — awaiting, records, the reasons in C#'s terms — lives in one C# file built
beside the target, and `embody.fsx` stays F#'s alone with one neutral entry (a value described as a constructor's call). The first
attempt (C# alone through fsi, `csharp-via-fsi`) made `embody.fsx` carry two languages at once. The decisions the scanner can make (an
overload to type, a method to await, a method to refuse) are made there, from the declaration, and reach the template as marks.

**Alternatives**: C# text evaluated by Roslyn's scripting (not in the SDK; a package to fetch); the F# compiler service inside fsi to
evaluate a string (a second compiler session per REPL); `embody.fsx` knowing C# (the first attempt); awaiting a `Task` when one comes
back, without a mark (the binding's type would be `Task<T>`, not `T`); annotating every argument (a project's type written as the
source has it may not resolve in fsi); csharp-ls through `Scanner.Lsp` (needs the .NET 10 SDK and a loaded solution). Reading C# with
Roslyn's parser from the SDK inside fsi is a proposed revision, not decided ([`evolving.md`](../evolving.md) §4.4).

**Files**: `lib/repl/language/csharp.exs`, `lib/repl/csharp/launch.exs`, `lib/repl/csharp/eval_template.exs`,
`lib/repl/eval/field_drip/csharp.exs`, `lib/scanner/csharp.exs`, embody's `embody.cs` and `embody.fsx`; tests
`test/csharp_adapter_test.exs`, `test/scanner_csharp_test.exs`, `test/live/repl_csharp_test.exs`; fixture `test/fixtures/csharp_sample/`.

## Notes

- Verified 2026-11-20: `test/csharp_adapter_test.exs` (12 tests), `test/scanner_csharp_test.exs` (10), `test/live/repl_csharp_test.exs`
  (4, through the launch, against the .NET 8 SDK from xipe_totec's nixpkgs pin: values, overloads by count and by type, `Task<T>` /
  `Task` / `ValueTask<T>`, optional and `params`, references within the pass, records as later rows' arguments with `same` and
  `changed`, a nominal record `binary`, an anonymous type `unsupported`, the failures in C#'s terms with the first row failing, an
  `embody.cs` of another protocol); and the CLI on a copy with its own `tables/` (`refresh -l -r`, `choice project`, `scan` — 49 nodes,
  overloads labelled by their types —, `effect/set`, `row/add` refusing `Make()` with its reason, `eval`: `Over(string)` with `null`
  picks the string overload, `LaterAsync(41)` is `42`; only `obj/` written into the target)
- The seam and the target are built at every pass (about 2 s each for the fixture): the temp dir is the pass's
- A C# value fsi shows in F#'s terms: a value tuple is `struct (4, "4")`, a `List<int>` `ResizeArray [0; 1]`, an `out` parameter comes
  back in a tuple (`Out(3)` is `(3, 6)`); `type=` is F#'s name (`int64`, `float`) where F# has one
- The arguments of a row are F#: C#'s `new Point(1, 2)` is written `Sample.Geo.Point(1.0, 2.0)`; a `xipe do` line cannot carry an
  argument containing `,` (D-cli-values)
