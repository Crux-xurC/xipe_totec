using System;

namespace Sample.Geo;

public record Point(double X, double Y);

public record Circle(double R);

public enum Color { Red, Green, Blue }

/* static helpers; one generic class and a nested one */
public static class Shapes
{
    public static Point Mid(Point a, Point b) => new Point((a.X + b.X) / 2, (a.Y + b.Y) / 2);

    public static double Area(Circle c) => Math.PI * c.R * c.R;

    public static Color Next(Color c) => c == Color.Blue ? Color.Red : c + 1;

    public static string Describe(Point p)
    {
        var s = @"a ""verbatim"" { string";
        var raw = """
            raw { text } with "quotes"
            """;
        return Inner.Label(p) + s.Length + raw.Length;
    }

    public static class Inner
    {
        public static string Label(Point p) => $"({p.X}, {p.Y})";
    }
}

public class Box<T>
{
    public static Box<T> Of(T value) => new Box<T>(value);

    public Box(T value) { Value = value; }

    public T Value { get; }

    public T Get() { return Value; }
}
