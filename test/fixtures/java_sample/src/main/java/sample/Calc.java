package sample;

import java.io.IOException;
import java.util.*;
import java.util.concurrent.CompletableFuture;

public final class Calc {
    private Calc() {}
    public static int add(int a, int b) { return a + b; }
    public static int add(int a, int b, int c) { return add(add(a, b), c); }
    public static double half(double x) { return x / 2; }
    public static int[] range(int n) { int[] r = new int[n]; for (int i = 0; i < n; i++) r[i] = i; return r; }
    public static List<Integer> rangeList(int n) { List<Integer> l = new ArrayList<>(); for (int i = 0; i < n; i++) l.add(i); return l; }
    public static Map<String, Integer> counts(String s) { Map<String, Integer> m = new HashMap<>(); for (char c : s.toCharArray()) m.merge(String.valueOf(c), 1, Integer::sum); return m; }
    public static Optional<String> maybe(boolean yes) { return yes ? Optional.of("yes") : Optional.empty(); }
    public static int boom(int x) { throw new IllegalStateException("boom: " + x); }
    public static int checked(int x) throws IOException { throw new IOException("io: " + x); }
    public static int spin() { long i = 0; while (true) { i++; } }
    public static String over(int x) { return "int " + x; }
    public static String over(String s) { return "string " + s; }
    public static String over(double d) { return "double " + d; }
    public static long wide(long x) { return x * 2; }
    public static int sum(int... xs) { int s = 0; for (int x : xs) s += x; return s; }
    public static <T> T id(T x) { return x; }
    public static <T> List<T> twice(T x) { return List.of(x, x); }
    public static <T> T make() { return null; }
    public static CompletableFuture<Integer> later(int x) { return CompletableFuture.supplyAsync(() -> x + 1); }
    public static Point mid(Point a, Point b) { return new Point((a.x() + b.x()) / 2, (a.y() + b.y()) / 2); }
    public static Bag fill(String name, int n) { return new Bag(name, rangeList(n)); }
    public static Tag mark(String t) { Tag g = new Tag(); g.text = t; return g; }
    public static Color next(Color c) { return c == Color.RED ? Color.BLUE : Color.RED; }
    public static Runnable task() { return () -> {}; }
    static int hidden(int x) { return x; }
    private static int secret(int x) { return x; }
    public int step(int by) { return by + 1; }
}
