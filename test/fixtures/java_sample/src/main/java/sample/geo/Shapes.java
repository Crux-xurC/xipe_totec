package sample.geo;

import sample.Point;
import static sample.Calc.add;

/** Another package: imports, a static import, a nested class. */
public final class Shapes {
    private Shapes() {}

    public static double dist(Point a, Point b) { return Math.hypot(a.x() - b.x(), a.y() - b.y()); }

    public static int twiceAdd(int a) { return add(a, a); }

    public static String describe(Point p) { return Inner.label(p) + " " + sample.Calc.half(p.x()); }

    public static class Inner {
        public static String label(Point p) { return "(" + p.x() + ", " + p.y() + ")"; }
    }

    static class Hidden {
        public static int peek() { return 1; }
    }
}
