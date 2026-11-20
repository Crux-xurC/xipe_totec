// scan.java -- Scanner.Java's reader: the JDK's own parser (com.sun.source through javax.tools), run with
// `java` as a single-file program -- every Java project has a JDK -- over the project's files, one JSON line
// per file on stdout. Nothing is compiled or written.
//
//     java scan.java <root> <relative path>...
//
// Per file: {"path", "error" (the parser's first error, or null), "defs": [...]}. A def is a method of a
// class, interface, enum or record (nested ones too): {"module_" (the package and the type chain,
// `sample.Outer.Inner`), "name", "anykey" (the parameters' types written out from the tree in one form,
// `(int, java.util.List<Integer>)`, `(int...)` for varargs), "shape" ([the parameter count]), "public"
// (a `public static` method of a type public all the way out; an interface's members and nested types are
// public), "line", "hash" (of its text), "async" (it returns CompletableFuture, CompletionStage or Future),
// "varargs", "unbound" (its type parameters that appear in no parameter), "scopes" (the enclosing types,
// innermost first), "package", "imports" (single-type ones), "wildcards" (on-demand ones, `a.b`),
// "statics" (static imports, `a.b.C.m` or `a.b.C.*`), "refs" (the calls in its body: {"name": `f`,
// `Calc.f`, `sample.Calc.f`, `this.f`, "argc"})}. Names are resolved by the caller. Constructors,
// initializers and lambdas are not defs.

import com.sun.source.tree.*;
import com.sun.source.util.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import javax.lang.model.element.Modifier;
import javax.tools.*;

public class scan {
    static String json(String s) {
        if (s == null) return "null";
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> { if (c < ' ') b.append(String.format("\\u%04x", (int) c)); else b.append(c); }
            }
        }
        return b.append('"').toString();
    }

    static String jsonList(Collection<String> xs) {
        StringJoiner j = new StringJoiner(",", "[", "]");
        for (String x : xs) j.add(json(x));
        return j.toString();
    }

    static String sha(String text) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8));
        StringBuilder b = new StringBuilder();
        for (byte x : d) b.append(String.format("%02x", x));
        return b.toString();
    }

    // a type written out again from its tree in one form: `List< Integer >` and `List<Integer>` give the same
    // text; annotations dropped. What only the compiler could tell (`List` against `java.util.List`) stays as written.
    static String typeText(Tree t) {
        if (t == null) return "";
        return switch (t) {
            case AnnotatedTypeTree a -> typeText(a.getUnderlyingType());
            case ParameterizedTypeTree p -> typeText(p.getType()) + "<" + String.join(", ", p.getTypeArguments().stream().map(scan::typeText).toList()) + ">";
            case ArrayTypeTree a -> typeText(a.getType()) + "[]";
            case WildcardTree w -> switch (w.getKind()) {
                case EXTENDS_WILDCARD -> "? extends " + typeText(w.getBound());
                case SUPER_WILDCARD -> "? super " + typeText(w.getBound());
                default -> "?";
            };
            case MemberSelectTree m -> typeText(m.getExpression()) + "." + m.getIdentifier();
            default -> t.toString().replaceAll("\\s+", "");
        };
    }

    // `a`, `a.b.c` as text when the tree is a chain of names
    static String chain(ExpressionTree e) {
        return switch (e) {
            case IdentifierTree i -> i.getName().toString();
            case MemberSelectTree m -> { String q = chain(m.getExpression()); yield q == null ? null : q + "." + m.getIdentifier(); }
            default -> null;
        };
    }

    record Ref(String name, int argc) {}

    public static void main(String[] args) throws Exception {
        Path root = Path.of(args[0]);
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        for (int k = 1; k < args.length; k++) {
            String rel = args[k];
            String line;
            try {
                line = scanFile(compiler, root, rel);
            } catch (Throwable e) {
                line = "{\"path\":" + json(rel) + ",\"error\":" + json(e.toString()) + ",\"defs\":[]}";
            }
            System.out.println(line);
        }
    }

    static String scanFile(JavaCompiler compiler, Path root, String rel) throws Exception {
        Path path = root.resolve(rel);
        String source = Files.readString(path);
        DiagnosticCollector<JavaFileObject> diags = new DiagnosticCollector<>();
        StandardJavaFileManager fm = compiler.getStandardFileManager(diags, null, StandardCharsets.UTF_8);
        JavacTask task = (JavacTask) compiler.getTask(null, fm, diags, List.of("-proc:none"), null, fm.getJavaFileObjects(path));
        Iterable<? extends CompilationUnitTree> units = task.parse();
        for (Diagnostic<? extends JavaFileObject> d : diags.getDiagnostics()) {
            if (d.getKind() == Diagnostic.Kind.ERROR)
                return "{\"path\":" + json(rel) + ",\"error\":" + json(rel + ":" + d.getLineNumber() + ": " + d.getMessage(Locale.ROOT)) + ",\"defs\":[]}";
        }
        SourcePositions pos = Trees.instance(task).getSourcePositions();
        List<String> defs = new ArrayList<>();
        for (CompilationUnitTree cu : units) {
            String pkg = cu.getPackageName() == null ? "" : cu.getPackageName().toString();
            List<String> imports = new ArrayList<>(), wildcards = new ArrayList<>(), statics = new ArrayList<>();
            for (ImportTree i : cu.getImports()) {
                String q = typeText(i.getQualifiedIdentifier());
                if (i.isStatic()) statics.add(q);
                else if (q.endsWith(".*")) wildcards.add(q.substring(0, q.length() - 2));
                else imports.add(q);
            }
            for (Tree t : cu.getTypeDecls()) {
                if (t instanceof ClassTree ct) walk(ct, pkg, List.of(), true, false, cu, pos, source, imports, wildcards, statics, defs);
            }
        }
        return "{\"path\":" + json(rel) + ",\"error\":null,\"defs\":[" + String.join(",", defs) + "]}";
    }

    // `outer`: the enclosing types' names, innermost first; `pub`: public all the way out so far
    static void walk(ClassTree ct, String pkg, List<String> outer, boolean pub, boolean inInterface, CompilationUnitTree cu, SourcePositions pos,
                     String source, List<String> imports, List<String> wildcards, List<String> statics, List<String> defs) throws Exception {
        String name = ct.getSimpleName().toString();
        String module = (outer.isEmpty() ? (pkg.isEmpty() ? "" : pkg + ".") : outer.get(0) + ".") + name;
        List<String> scopes = new ArrayList<>();
        scopes.add(module);
        scopes.addAll(outer);
        boolean isInterface = ct.getKind() == Tree.Kind.INTERFACE || ct.getKind() == Tree.Kind.ANNOTATION_TYPE;
        boolean typePublic = pub && (inInterface || ct.getModifiers().getFlags().contains(Modifier.PUBLIC));
        for (Tree m : ct.getMembers()) {
            if (m instanceof ClassTree inner) {
                walk(inner, pkg, scopes, typePublic, isInterface, cu, pos, source, imports, wildcards, statics, defs);
            } else if (m instanceof MethodTree mt && !mt.getName().contentEquals("<init>")) {
                Set<Modifier> flags = mt.getModifiers().getFlags();
                boolean isStatic = flags.contains(Modifier.STATIC);
                boolean isPublic = flags.contains(Modifier.PUBLIC) || (isInterface && !flags.contains(Modifier.PRIVATE));
                List<? extends VariableTree> ps = mt.getParameters();
                boolean varargs = !ps.isEmpty() && (((com.sun.source.tree.VariableTree) ps.get(ps.size() - 1)).getModifiers() != null)
                    && source.substring((int) pos.getStartPosition(cu, ps.get(ps.size() - 1)), (int) pos.getEndPosition(cu, ps.get(ps.size() - 1))).contains("...");
                List<String> types = new ArrayList<>();
                for (int i = 0; i < ps.size(); i++) {
                    String t = typeText(ps.get(i).getType());
                    if (varargs && i == ps.size() - 1 && t.endsWith("[]")) t = t.substring(0, t.length() - 2) + "...";
                    types.add(t);
                }
                // type parameters that no parameter's type names
                Set<String> used = new HashSet<>();
                for (VariableTree p : ps) {
                    new TreeScanner<Void, Void>() {
                        @Override public Void visitIdentifier(IdentifierTree id, Void v) { used.add(id.getName().toString()); return null; }
                    }.scan(p.getType(), null);
                }
                List<String> unbound = new ArrayList<>();
                for (TypeParameterTree tp : mt.getTypeParameters()) if (!used.contains(tp.getName().toString())) unbound.add(tp.getName().toString());
                String ret = typeText(mt.getReturnType());
                String base = ret.replaceAll("<.*", "");
                boolean async = base.matches("(java\\.util\\.concurrent\\.)?(CompletableFuture|CompletionStage|Future)");
                // the calls in the body
                List<Ref> refs = new ArrayList<>();
                if (mt.getBody() != null) {
                    new TreeScanner<Void, Void>() {
                        @Override public Void visitMethodInvocation(MethodInvocationTree mi, Void v) {
                            String n = chain(mi.getMethodSelect());
                            if (n != null) refs.add(new Ref(n, mi.getArguments().size()));
                            return super.visitMethodInvocation(mi, v);
                        }
                    }.scan(mt.getBody(), null);
                }
                long start = pos.getStartPosition(cu, mt), end = pos.getEndPosition(cu, mt);
                String text = start >= 0 && end >= start ? source.substring((int) start, (int) end) : mt.toString();
                int line = (int) cu.getLineMap().getLineNumber(start);
                StringJoiner rj = new StringJoiner(",", "[", "]");
                for (Ref r : refs) rj.add("{\"name\":" + json(r.name()) + ",\"argc\":" + r.argc() + "}");
                defs.add("{\"module_\":" + json(module) + ",\"name\":" + json(mt.getName().toString())
                    + ",\"anykey\":" + json("(" + String.join(", ", types) + ")") + ",\"shape\":[" + ps.size() + "]"
                    + ",\"public\":" + (typePublic && isPublic && isStatic) + ",\"line\":" + line + ",\"hash\":" + json(sha(text))
                    + ",\"async\":" + async + ",\"varargs\":" + varargs + ",\"unbound\":" + jsonList(unbound)
                    + ",\"scopes\":" + jsonList(scopes) + ",\"package\":" + json(pkg) + ",\"imports\":" + jsonList(imports)
                    + ",\"wildcards\":" + jsonList(wildcards) + ",\"statics\":" + jsonList(statics) + ",\"refs\":" + rj + "}");
            }
        }
    }
}
