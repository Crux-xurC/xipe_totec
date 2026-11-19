// a script: its top level must never run when it is loaded for evaluation
java.nio.file.Files.writeString(java.nio.file.Paths.get("TOP_LEVEL_RAN"), "tool.sc")
println("tool.sc's top level ran")
//> using dep com.lihaoyi::os-lib:0.11.4
val factor = 3
val computed = sq(2)
def sq(a: Int): Int = a * a
def scale(a: Int): Int = a * factor
object Text {
  def shout(s: String): String = s.toUpperCase + "!"
}
