package sample

case class Point(x: Double, y: Double)

enum Color { case Red, Green, Blue }

object Calc {
  // an object's body runs when the object is first used, as a static initialiser
  println("Calc initialised")

  def add(a: Int, b: Int): Int = a + b
  def add3(a: Int, b: Int, c: Int): Int = add(add(a, b), c)
  def curried(a: Int)(b: Int): Int = a * b
  def answer(): Int = 42
  def half(x: Double): Double = x / 2
  def range(n: Int): Array[Int] = Array.range(0, n)
  def rangeList(n: Int): List[Int] = List.range(0, n)
  def pair(n: Int): (Int, String) = (n, n.toString)
  def counts(s: String): Map[String, Int] = s.groupBy(_.toString).map((k, v) => k -> v.length)
  def greet(name: String): String = s"hello, $name {not a brace}"
  def maybe(b: Boolean): Option[String] = if b then Some("yes") else None
  def overload(a: Int): Int = a + 1
  def overload(a: String): String = a + "!"
  def adder(n: Int): Int => Int = _ + n
  def boom(n: Int): Int = throw new IllegalStateException(s"boom $n")
  def spin(n: Int): Int = { var i = 0; while (true) { i += 1 }; i }
  private def secret(a: Int): Int = a + 100
  def callsSecret(a: Int): Int = secret(a)
}

object Geo {
  def mid(p: Point, q: Point): Point = Point((p.x + q.x) / 2, (p.y + q.y) / 2)
  def next(c: Color): Color = Color.fromOrdinal((c.ordinal + 1) % Color.values.length)
  object Inner {
    def label(s: String): String = s.toUpperCase
  }
}

def twice(x: Double): Double = x * 2
