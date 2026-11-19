// Xipe Totec's scan of Scala files, read by the Scala 3 compiler's own parser (run by `scala`, whose
// class path carries the compiler). Arguments: the project's root, then the files (relative to it).
// One JSON line per file: {"path", "defs": [...]} or {"path", "error"}. See lib/scanner/scala.exs.

import dotty.tools.dotc.ast.untpd
import dotty.tools.dotc.core.Contexts.{Context, ContextBase}
import dotty.tools.dotc.core.Flags
import dotty.tools.dotc.parsing.Parsers.Parser
import dotty.tools.dotc.reporting.StoreReporter
import dotty.tools.dotc.util.SourceFile

object XtScan {
  final case class Def(module: String, name: String, anykey: String, shape: List[Int], public: Boolean, line: Int,
                       hash: String, scopes: List[String], opens: List[String], refs: List[String])

  def json(s: String): String = {
    val b = new StringBuilder("\"")
    s.foreach {
      case '"' => b.append("\\\"")
      case '\\' => b.append("\\\\")
      case '\n' => b.append("\\n")
      case '\r' => b.append("\\r")
      case '\t' => b.append("\\t")
      case c if c < ' ' => b.append(f"\\u${c.toInt}%04x")
      case c => b.append(c)
    }
    b.append('"').toString
  }

  def jsonList(xs: List[String]): String = xs.map(json).mkString("[", ",", "]")

  def md5(s: String): String =
    java.security.MessageDigest.getInstance("MD5").digest(s.getBytes("UTF-8")).map(b => f"${b & 0xff}%02x").mkString

  def join(a: String, b: String): String = if (a.isEmpty) b else if (b.isEmpty) a else a + "." + b

  // `a.b.c` as text, when the tree is a chain of names
  def chain(t: untpd.Tree): Option[String] = t match {
    case untpd.Ident(n) => Some(n.toString)
    case untpd.Select(q, n) => chain(q).map(_ + "." + n.toString)
    case _ => None
  }

  def isPrivate(mods: untpd.Modifiers): Boolean =
    mods.is(Flags.Private) || mods.is(Flags.Protected) || mods.hasPrivateWithin

  def scanFile(rel: String, source: String, script: Boolean): Either[String, List[Def]] = {
    given ctx: Context = (new ContextBase).initialCtx.fresh.setReporter(new StoreReporter(null))
    val src = SourceFile.virtual(rel, source)
    val parser = new Parser(src)
    val trees: List[untpd.Tree] = if (script) parser.blockStatSeq() else List(parser.parse())
    ctx.reporter.removeBufferedMessages.find(_.level >= dotty.tools.dotc.interfaces.Diagnostic.ERROR) match {
      case Some(d) => Left(s"$rel:${if (d.pos.exists) d.pos.line + 1 else 0}: ${d.message}")
      case None =>
        val defs = List.newBuilder[Def]

        def text(t: untpd.Tree): String =
          if (t.span.exists) source.substring(t.span.start, t.span.end) else ""

        // a type written out again from its tree in one form: `List[ Int ]` and `List[Int]` give the same text.
        // What only type resolution could tell (`Int` against `scala.Int`) stays as written.
        def typeText(t: untpd.Tree): String = t match {
          case untpd.Ident(n) => n.toString
          case untpd.Select(q, n) => typeText(q) + "." + n.toString
          case untpd.AppliedTypeTree(tc, args) => typeText(tc) + args.map(typeText).mkString("[", ", ", "]")
          case untpd.ByNameTypeTree(r) => "=> " + typeText(r)
          case untpd.Function(args, body) =>
            val from = args match {
              case List(a) if !a.isInstanceOf[untpd.Tuple] && !a.isInstanceOf[untpd.Function] => typeText(a)
              case _ => args.map(typeText).mkString("(", ", ", ")")
            }
            from + " => " + typeText(body)
          case untpd.Tuple(ts) => ts.map(typeText).mkString("(", ", ", ")")
          case untpd.Parens(inner) => typeText(inner)
          case untpd.PostfixOp(inner, op) => typeText(inner) + op.name.toString
          case untpd.InfixOp(l, op, r) => typeText(l) + " " + op.name.toString + " " + typeText(r)
          case untpd.SingletonTypeTree(r) => typeText(r) + ".type"
          case untpd.Annotated(arg, _) => typeText(arg)
          case _ => text(t).replaceAll("\\s+", "")
        }

        def refsOf(t: untpd.Tree): List[String] = {
          val found = scala.collection.mutable.LinkedHashSet.empty[String]
          new untpd.UntypedTreeTraverser {
            override def traverse(tree: untpd.Tree)(using Context): Unit = {
              tree match {
                case s: untpd.Select => chain(s).foreach(found += _)
                case untpd.Ident(n) => found += n.toString
                case _ => ()
              }
              traverseChildren(tree)
            }
          }.traverse(t)
          found.toList
        }

        def defOf(d: untpd.DefDef, module: String, scopes: List[String], opens: List[String], hidden: Boolean): Unit = {
          val name = d.name.toString
          if (name != "<init>") {
            val clauses = d.paramss.filter(c => c.isEmpty || c.head.isInstanceOf[untpd.ValDef]).map(_.asInstanceOf[List[untpd.ValDef]])
            val anykey = clauses.map { c =>
              val using = c.nonEmpty && (c.head.mods.is(Flags.Given) || c.head.mods.is(Flags.Implicit))
              (if (using) "(using " else "(") + c.map(p => typeText(p.tpt)).mkString(", ") + ")"
            }.mkString
            val shape = clauses.filterNot(c => c.nonEmpty && (c.head.mods.is(Flags.Given) || c.head.mods.is(Flags.Implicit))).map(_.size)
            defs += Def(module, name, anykey, shape, !(hidden || isPrivate(d.mods)), src.offsetToLine(d.span.start) + 1,
              md5(text(d)), scopes, opens, refsOf(d.rhs) ++ d.paramss.flatten.collect { case v: untpd.ValDef => refsOf(v.rhs) }.flatten)
          }
        }

        // `owner`: the module (package or object chain) the statements are in
        def walk(stats: List[untpd.Tree], owner: String, scopes: List[String], opens0: List[String], hidden: Boolean): Unit = {
          var opens = opens0
          stats.foreach {
            case untpd.PackageDef(pid, inner) =>
              val p = chain(pid).filter(_ != "<empty>").getOrElse("")
              val pkg = join(owner, p)
              walk(inner, pkg, if (pkg.isEmpty) scopes else pkg :: scopes, opens, hidden)
            case i: untpd.Import =>
              chain(i.expr).foreach(e => opens = e :: opens)
            case m: untpd.ModuleDef =>
              val mod = join(owner, m.name.toString)
              walk(m.impl.body, mod, mod :: scopes, opens, hidden || isPrivate(m.mods))
            case d: untpd.DefDef =>
              defOf(d, owner, scopes, opens, hidden)
            case _ => ()
          }
        }

        if (script) {
          // a script's module is its path without `.sc` (`scripts/tool`): two scripts of one file name in
          // different directories stay apart; the REPL's object is named so too (`embody.scala`'s Load)
          val obj = rel.stripSuffix(".sc")
          walk(trees, obj, List(obj), Nil, hidden = false)
        } else walk(trees, "", Nil, Nil, hidden = false)
        Right(defs.result())
    }
  }

  def main(args: Array[String]): Unit = {
    val root = args.head
    for (rel <- args.tail) {
      val line =
        try {
          val source = new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(root, rel)), "UTF-8")
          scanFile(rel, source, rel.endsWith(".sc")) match {
            case Left(err) => s"""{"path":${json(rel)},"error":${json(err)}}"""
            case Right(ds) =>
              val items = ds.map { d =>
                s"""{"module_":${json(d.module)},"name":${json(d.name)},"anykey":${json(d.anykey)},"shape":${d.shape.mkString("[", ",", "]")},""" +
                  s""""public":${d.public},"line":${d.line},"hash":${json(d.hash)},"scopes":${jsonList(d.scopes)},""" +
                  s""""opens":${jsonList(d.opens)},"refs":${jsonList(d.refs)}}"""
              }
              s"""{"path":${json(rel)},"defs":${items.mkString("[", ",", "]")}}"""
          }
        } catch { case e: Throwable => s"""{"path":${json(rel)},"error":${json(e.getClass.getName + ": " + e.getMessage)}}""" }
      println(line)
    }
  }
}
