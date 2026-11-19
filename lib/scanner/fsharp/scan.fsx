// scan.fsx -- Scanner.FSharp's reader: F#'s own parser (FSharp.Compiler.Service, which comes with the
// .NET SDK) run inside `dotnet fsi`, one JSON line per file on stdout.
//
//     dotnet fsi --quiet --exec scan.fsx <root> <relative path>...
//
// Per file: {"path", "error" (the parser's first error, or null), "defs": [...]}. A def is a module-level
// `let` with arguments: {"module", "name", "args" (curried, as written: `let f a b` 2, `let f (a, b)` and
// `let f ()` 1), "public", "line", "endLine", "hash" (of its text), "scopes" (the enclosing modules and
// namespaces, innermost first), "opens" (the `open`s before it, in its module and the enclosing ones,
// latest first), "refs" (every name its body uses, `f` or `A.B.f`)}. Names are resolved by the caller.
// Values (`let x = …`), members of types, operators and local functions are not defs.

#r "FSharp.Compiler.Service"

open System
open System.Collections
open System.Security.Cryptography
open System.Text
open System.Text.Json
open FSharp.Compiler.CodeAnalysis
open FSharp.Compiler.Syntax
open FSharp.Compiler.Text
open Microsoft.FSharp.Reflection

type Def =
    { module_: string; name: string; args: int; ``public``: bool; line: int; endLine: int; hash: string
      scopes: string list; opens: string list; refs: string list }

let checker = FSharpChecker.Create()

let joinIds (ids: Ident list) = ids |> List.map (fun i -> i.idText) |> String.concat "."

// every `f` / `A.B.f` an expression uses, found by walking the syntax tree's own types
let refsOf (root: obj) =
    let found = Generic.List<string>()
    let rec walk (o: obj) =
        match o with
        | null -> ()
        | :? SynExpr as e when (match e with SynExpr.Ident _ | SynExpr.LongIdent _ -> true | _ -> false) ->
            match e with
            | SynExpr.Ident id -> found.Add id.idText
            | SynExpr.LongIdent(longDotId = SynLongIdent(id = ids)) -> found.Add(joinIds ids)
            | _ -> ()
        | :? string | :? range -> ()
        | _ ->
            let t = o.GetType()
            if t.IsArray then for x in (o :?> IEnumerable) do walk x
            elif FSharpType.IsUnion(t, true) && (t.Namespace = "FSharp.Compiler.Syntax" || t.Namespace = "Microsoft.FSharp.Collections" || t.Namespace = "Microsoft.FSharp.Core") then
                let _, fields = FSharpValue.GetUnionFields(o, t, true)
                for f in fields do walk f
            elif FSharpType.IsRecord(t, true) && t.Namespace = "FSharp.Compiler.Syntax" then
                for f in FSharpValue.GetRecordFields(o, true) do walk f
            elif FSharpType.IsTuple t then
                for f in FSharpValue.GetTupleFields o do walk f
    walk root
    found |> Seq.distinct |> List.ofSeq

let hashOf (source: string) (r: range) (lines: string[]) =
    let text =
        [ for l in r.StartLine .. r.EndLine -> lines.[l - 1] ] |> String.concat "\n"
    Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes text)).ToLowerInvariant()

let isPublic (a: SynAccess option) = match a with None | Some(SynAccess.Public _) -> true | _ -> false

let rec decls (lines: string[]) (scopes: string list) (opens: string list) (pub: bool) (ds: SynModuleDecl list) (acc: Def list) =
    match ds with
    | [] -> acc
    | d :: rest ->
        match d with
        | SynModuleDecl.Open(target = SynOpenDeclTarget.ModuleOrNamespace(longId = SynLongIdent(id = ids))) ->
            decls lines scopes (joinIds ids :: opens) pub rest acc
        | SynModuleDecl.Let(bindings = bs) ->
            let defs =
                bs
                |> List.choose (fun b ->
                    match b with
                    | SynBinding(accessibility = acc0; headPat = SynPat.LongIdent(longDotId = SynLongIdent(id = ids); argPats = SynArgPats.Pats(_ :: _ as ps); accessibility = acc1); expr = body; range = r) ->
                        let name = (List.last ids).idText
                        let name = if name.StartsWith "|" then "(" + name + ")" else name
                        if name.StartsWith "op_" then None
                        else
                            Some
                                { module_ = List.head scopes; name = name; args = ps.Length
                                  ``public`` = pub && isPublic acc0 && isPublic acc1
                                  line = r.StartLine; endLine = r.EndLine; hash = hashOf "" r lines
                                  scopes = scopes; opens = opens; refs = refsOf body }
                    | _ -> None)
            decls lines scopes opens pub rest (List.rev defs @ acc)
        | SynModuleDecl.NestedModule(moduleInfo = SynComponentInfo(longId = ids; accessibility = a); decls = inner) ->
            let name = List.head scopes + "." + joinIds ids
            let acc = decls lines (name :: scopes) opens (pub && isPublic a) inner acc
            decls lines scopes opens pub rest acc
        | _ -> decls lines scopes opens pub rest acc

let scanFile (root: string) (rel: string) =
    let path = IO.Path.Combine(root, rel)
    let source = IO.File.ReadAllText path
    let lines = source.Replace("\r\n", "\n").Split('\n')
    let opts = { FSharpParsingOptions.Default with SourceFiles = [| path |] }
    let res = checker.ParseFile(path, SourceText.ofString source, opts) |> Async.RunSynchronously
    let error =
        res.Diagnostics
        |> Array.tryFind (fun d -> d.Severity = FSharp.Compiler.Diagnostics.FSharpDiagnosticSeverity.Error)
        |> Option.map (fun d -> sprintf "%s(%d,%d): %s" rel d.StartLine (d.StartColumn + 1) d.Message)
    let defs =
        match error, res.ParseTree with
        | None, ParsedInput.ImplFile(ParsedImplFileInput(contents = modules)) ->
            modules
            |> List.collect (fun (SynModuleOrNamespace(longId = ids; kind = kind; decls = ds; accessibility = a)) ->
                let name = joinIds ids
                // a namespace's parents are scopes too: `namespace A.B` sees `A`
                let scopes =
                    let parts = ids |> List.map (fun i -> i.idText)
                    [ for k in parts.Length .. -1 .. 1 -> String.Join(".", parts |> List.take k) ]
                let scopes = if scopes.IsEmpty then [ "" ] else scopes
                let pub = kind.IsModule |> not || isPublic a
                decls lines scopes [] pub ds [] |> List.rev)
        | _ -> []
    {| path = rel; error = Option.toObj error; defs = defs |}

let options = JsonSerializerOptions(PropertyNamingPolicy = null)

match fsi.CommandLineArgs |> List.ofArray with
| _ :: root :: paths ->
    for rel in paths do
        let line =
            try JsonSerializer.Serialize(scanFile root rel, options)
            with e -> JsonSerializer.Serialize({| path = rel; error = e.Message; defs = [||] |}, options)
        Console.Out.WriteLine line
| _ -> eprintfn "usage: scan.fsx <root> <relative path>..."
