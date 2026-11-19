// a script whose function uses a value its top level computes: its copy does not compile
val n = 1 + 1
def plusN(a: Int): Int = a + n
