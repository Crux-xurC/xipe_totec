package sample;

/** An interface's static method is a row; its default method is an instance method. */
public interface Ops {
    static int triple(int x) { return Calc.add(x, Calc.add(x, x)); }

    default int inst() { return 0; }
}
