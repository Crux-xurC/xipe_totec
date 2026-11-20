using System;
using System.Collections.Generic;
using Sample.Geo;
using static Sample.Geo.Shapes;

namespace Sample
{
    /// Plain static functions: what a calc row calls.
    public static class Calc
    {
        // a static constructor runs on first use, not when the assembly loads
        static Calc() { Loaded = true; }

        public static bool Loaded;

        public static int Add(int a, int b) => a + b;

        public static int Add(int a, int b, int c) { return Add(Add(a, b), c); }

        public static double Half(double x) => x / 2;

        public static int[] Range(int n)
        {
            var r = new int[n];
            for (int i = 0; i < n; i++) { r[i] = i; }
            return r;
        }

        public static List<int> RangeList(int n) => new List<int>(Range(n));

        public static (int, string) Pair(int n) => (n, n.ToString());

        public static Dictionary<string, int> Counts(string s)
        {
            var d = new Dictionary<string, int>();
            foreach (var c in s) { var k = c.ToString(); d[k] = d.GetValueOrDefault(k) + 1; }
            return d;
        }

        public static string Greet(string name) => $"hello, {name} {{not a brace}}";

        public static string? Maybe(bool yes) => yes ? "yes" : null;

        public static double UnitArea() => Area(new Circle(1.0));

        public static int Boom(int x) => throw new InvalidOperationException("boom: " + x);

        public static int Spin() { long i = 0; while (true) { i++; } }

        public static Func<int, int> Adder(int n) => x => x + n;

        internal static int Hidden(int x) => x;

        private static int Secret(int x) => Hidden(x) + 1;
    }

    /// An instance method: on the map, not a calc row.
    public class Counter
    {
        private int n;

        public int Step(int by) { n += by; return Bump(n); }

        private static int Bump(int x) => x + 1;
    }
}
