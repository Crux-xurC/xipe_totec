using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace Sample;

/// What the seam is for: overloads of one count, async, generics, out, optional and params parameters.
public static class Calls
{
    public static string Over(int x) => "int " + x;

    public static string Over(string s) => "string " + s;

    public static string Over(double d) => "double " + d;

    public static long Wide(long x) => x * 2;

    public static async Task<int> LaterAsync(int x) { await Task.Delay(1); return x + 1; }

    public static async Task Done() { await Task.Yield(); }

    public static ValueTask<string> Soon(string s) => new ValueTask<string>(s);

    public static T Id<T>(T x) => x;

    public static List<T> Twice<T>(T x) => new List<T> { x, x };

    public static T Make<T>() where T : new() => new T();

    public static int Out(int x, out int doubled) { doubled = x * 2; return x; }

    public static int Opt(int a, int b = 10) => a + b;

    public static int Params(params int[] xs) { var s = 0; foreach (var x in xs) { s += x; } return s; }

    public static int Use() => Over(1).Length + Opt(1) + Params(1, 2, 3);

    public static Bag Fill(string name, int n) => new Bag(name, new List<int>(Enumerable.Range(0, n)));

    public static Tag Mark(string text) => new Tag { Text = text };

    public static object Anon(int n) => new { N = n, S = n.ToString() };
}

/// A positional record holding a list: compared element by element.
public record Bag(string Name, List<int> Items);

/// A record whose state is set outside a primary constructor: not written as a call.
public record Tag
{
    public string Text { get; init; } = "";
}
