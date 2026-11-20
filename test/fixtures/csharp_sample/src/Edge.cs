// What a text scanner trips on: a file-scoped namespace, braces inside strings,
// chars, comments and #if branches, and generic methods.
namespace Sample.Edge;

public static class Text
{
    // a brace in a comment {
    /* and } in a block */
    public static string Holes(int x) => $"{(x > 0 ? "}" : "{")} {{ {Calc.Add(x, 1)} }}";

    public static string Verbatim() => @"a "" } {" + $@"{"{"}";

    public static string Raw(int x) => $$"""{{x}} } {""" + """
        { "quoted" }
        """;

    public static char Open() => '{';

#if XIPE_TOTEC_NEVER
    public static int Branch() {
        return 1;
#else
    public static int Branch() {
        return 2;
#endif
    }

    public static int After() => Branch() + 1;
}

public static class Generic
{
    // T is inferred from the argument: callable as Sample.Edge.Generic.First([|1; 2|])
    public static T First<T>(T[] xs) => xs[0];

    // T appears in no argument: F# cannot infer it, the call does not compile
    public static T Zero<T>() where T : struct => default;
}
